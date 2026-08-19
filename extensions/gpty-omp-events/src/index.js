import { createEventForwarder, readConfiguration } from "./transport.js";

const MAX_NAME_LENGTH = 256;
const MAX_THINKING_DELTA_LENGTH = 8 * 1024;
const REASONING_EVENT_TYPES = new Set(["thinking_delta", "reasoning_delta", "thinking"]);

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

  const emit = (ctx, event) => {
    try {
      void forwarder.enqueue(event, sessionId(ctx)).catch(() => {});
    } catch {
      // Observability must never alter an omp session.
    }
  };

  pi.on("session_start", (_event, ctx) => {
    emit(ctx, semantic("omp.session.bound", { reason: "start" }));
  });
  pi.on("session_switch", (event, ctx) => {
    emit(ctx, semantic("omp.session.bound", { reason: text(event.reason, 32) || "switch" }));
  });
  pi.on("session_branch", (_event, ctx) => {
    emit(ctx, semantic("omp.session.bound", { reason: "branch" }));
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    try {
      await forwarder.enqueue(semantic("omp.session.shutdown"), sessionId(ctx));
    } catch {
      // Best-effort shutdown notification.
    }
  });

  pi.on("agent_start", (_event, ctx) => {
    emit(ctx, semantic("omp.agent.started"));
  });
  pi.on("agent_end", (event, ctx) => {
    if (event.willContinue !== true) emit(ctx, semantic("omp.agent.settled"));
  });
  pi.on("turn_start", (event, ctx) => {
    emit(
      ctx,
      semantic("omp.turn.started", {
        turn_index: integer(event.turnIndex),
        started_at_ms: integer(event.timestamp),
      }),
    );
  });
  pi.on("turn_end", (event, ctx) => {
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
    emit(
      ctx,
      semantic("omp.reasoning.delta", {
        content_index: integer(update.contentIndex),
        text: text(delta, MAX_THINKING_DELTA_LENGTH),
      }),
    );
  });

  return true;
}

export default function gptyOmpEvents(pi) {
  registerGptyEvents(pi);
}
