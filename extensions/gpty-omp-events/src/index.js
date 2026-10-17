import { Buffer } from "node:buffer";

import { createEventForwarder, readConfiguration } from "./transport.js";

const MAX_NAME_LENGTH = 256;
/**
 * Largest reasoning chunk, in **UTF-8 bytes** — the Rust side checks
 * `text.len()`, so a JavaScript `.length` cap would pass a multi-byte chunk
 * the server then rejects wholesale. 7 KiB rather than the socket's 8 KiB
 * cap leaves room for JSON escaping (quotes, backslashes, newlines) in the
 * 16 KiB request envelope.
 */
const MAX_THINKING_DELTA_LENGTH = 7 * 1024;
/** Longest reasoning text buffered before it is sent, in wall-clock time. */
const REASONING_FLUSH_MS = 16;
const REASONING_EVENT_TYPES = new Set(["thinking_delta", "reasoning_delta", "thinking"]);

/**
 * Split `text` into chunks of at most `maxBytes` UTF-8 bytes without cutting a
 * code point (or a surrogate pair) in half. A delta larger than the socket's
 * cap used to be truncated with an ellipsis, losing the rest of the model's
 * thought; splitting keeps every character and stays inside the boundary.
 */
export function splitReasoningDelta(text, maxBytes = MAX_THINKING_DELTA_LENGTH) {
  const chunks = [];
  let chunk = "";
  let bytes = 0;
  for (const character of text) {
    const size = Buffer.byteLength(character, "utf8");
    if (bytes > 0 && bytes + size > maxBytes) {
      chunks.push(chunk);
      chunk = "";
      bytes = 0;
    }
    chunk += character;
    bytes += size;
  }
  if (chunk !== "") chunks.push(chunk);
  return chunks;
}

function reasoningDelta(update) {
  if (!update || !REASONING_EVENT_TYPES.has(update.type)) return null;
  if (typeof update.delta === "string") return update.delta;
  if (typeof update.text === "string") return update.text;
  return null;
}

function text(value, maxLength = MAX_NAME_LENGTH) {
  if (typeof value !== "string") return "";
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 1)}…`;
}

function integer(value) {
  return Number.isSafeInteger(value) ? value : undefined;
}

function sessionId(ctx) {
  try {
    return text(ctx.sessionManager.getSessionId());
  } catch {
    return "";
  }
}

function semantic(name, fields = {}) {
  return { name, emitted_at_ms: Date.now(), ...fields };
}

export function registerGptyEvents(pi, options = {}) {
  const config = options.config ?? readConfiguration(options.env);
  if (!config) return false;

  const forwarder = options.forwarder ?? createEventForwarder(config, options.transportOptions);
  const flushMs = Math.max(0, options.reasoningFlushMs ?? REASONING_FLUSH_MS);

  const emit = (ctx, event) => {
    try {
      void forwarder.enqueue(event, sessionId(ctx)).catch(() => {});
    } catch {
      // Observability must never alter an omp session.
    }
  };

  // Reasoning deltas arrive at token rate. One event (one socket round trip)
  // per token loaded the forwarder's bounded outbox and the GUI's queue, and
  // dropping either lost text mid-sentence. Concatenate until the flush
  // deadline, then send whole chunks; the pane appends text, so the grouping
  // is invisible to it. `flushReasoning` is also called before every event
  // that changes or ends a turn, so a tail can never land after the start of
  // the next turn (or the next session).
  let pendingReasoning = "";
  let pendingCtx = null;
  let pendingTimer = null;

  const flushReasoning = () => {
    if (pendingTimer != null) {
      clearTimeout(pendingTimer);
      pendingTimer = null;
    }
    const ctx = pendingCtx;
    const text = pendingReasoning;
    pendingReasoning = "";
    pendingCtx = null;
    if (ctx == null || text === "") return;
    for (const chunk of splitReasoningDelta(text)) {
      emit(ctx, semantic("omp.reasoning.delta", { text: chunk }));
    }
  };

  const pushReasoning = (ctx, delta) => {
    pendingReasoning += delta;
    pendingCtx = ctx;
    // A delta larger than one event is sent at once (split on code points),
    // rather than truncated.
    if (Buffer.byteLength(pendingReasoning, "utf8") >= MAX_THINKING_DELTA_LENGTH) {
      flushReasoning();
      return;
    }
    if (pendingTimer == null) {
      pendingTimer = setTimeout(flushReasoning, flushMs);
    }
  };

  pi.on("session_start", (_event, ctx) => {
    flushReasoning();
    emit(ctx, semantic("omp.session.bound", { reason: "start" }));
  });
  pi.on("session_switch", (event, ctx) => {
    flushReasoning();
    emit(ctx, semantic("omp.session.bound", { reason: text(event.reason, 32) || "switch" }));
  });
  pi.on("session_branch", (_event, ctx) => {
    flushReasoning();
    emit(ctx, semantic("omp.session.bound", { reason: "branch" }));
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    flushReasoning();
    try {
      await forwarder.enqueue(semantic("omp.session.shutdown"), sessionId(ctx));
    } catch {
      // Best-effort shutdown notification.
    }
  });

  pi.on("agent_start", (_event, ctx) => {
    flushReasoning();
    emit(ctx, semantic("omp.agent.started"));
  });
  pi.on("agent_end", (event, ctx) => {
    flushReasoning();
    if (event.willContinue !== true) emit(ctx, semantic("omp.agent.settled"));
  });
  pi.on("turn_start", (event, ctx) => {
    flushReasoning();
    emit(
      ctx,
      semantic("omp.turn.started", {
        turn_index: integer(event.turnIndex),
        started_at_ms: integer(event.timestamp),
      }),
    );
  });
  pi.on("turn_end", (event, ctx) => {
    flushReasoning();
    emit(ctx, semantic("omp.turn.finished", { turn_index: integer(event.turnIndex) }));
  });

  pi.on("tool_execution_start", (event, ctx) => {
    emit(
      ctx,
      semantic("omp.tool.started", {
        tool_call_id: text(event.toolCallId),
        tool_name: text(event.toolName),
      }),
    );
  });
  pi.on("tool_execution_update", () => {});
  pi.on("tool_execution_end", (event, ctx) => {
    emit(
      ctx,
      semantic("omp.tool.finished", {
        tool_call_id: text(event.toolCallId),
        tool_name: text(event.toolName),
        is_error: event.isError === true,
      }),
    );
  });

  pi.on("message_update", (event, ctx) => {
    const update = event.assistantMessageEvent;
    const delta = reasoningDelta(update);
    if (delta == null || delta === "") return;
    pushReasoning(ctx, delta);
  });

  return true;
}

export default function gptyOmpEvents(pi) {
  registerGptyEvents(pi);
}
