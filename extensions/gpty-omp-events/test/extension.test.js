import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import { registerGptyEvents } from "../src/index.js";
import {
  MAX_OUTBOX_EVENTS,
  createEventForwarder,
  readConfiguration,
  validateSocket,
} from "../src/transport.js";

function fakePi() {
  const handlers = new Map();
  return {
    handlers,
    on(name, handler) {
      handlers.set(name, handler);
    },
  };
}

function context(id = "omp-1") {
  return {
    sessionManager: {
      getSessionId: () => id,
    },
  };
}

test("stays dormant unless every activation variable is valid", () => {
  const complete = {
    GPTY_EVENT_SOCKET: "/tmp/gpty.sock",
    GPTY_TERMINAL_SESSION_ID: "terminal-1",
    GPTY_EVENT_CAPABILITY: "capability",
    GPTY_EVENT_PROTOCOL: "1",
  };

  assert.deepEqual(readConfiguration(complete), {
    socketPath: "/tmp/gpty.sock",
    terminalSessionId: "terminal-1",
    capability: "capability",
  });

  for (const name of Object.keys(complete)) {
    const env = { ...complete };
    delete env[name];
    assert.equal(readConfiguration(env), null, `must require ${name}`);
  }
  assert.equal(readConfiguration({ ...complete, GPTY_EVENT_PROTOCOL: "2" }), null);

  const pi = fakePi();
  assert.equal(registerGptyEvents(pi, { env: {} }), false);
  assert.equal(pi.handlers.size, 0);
});

test("forwards only bounded semantic fields and refreshes session id", async () => {
  const pi = fakePi();
  const sent = [];
  let activeSession = "omp-before";
  const ctx = context();
  ctx.sessionManager.getSessionId = () => activeSession;

  registerGptyEvents(pi, {
    config: {
      socketPath: "/tmp/gpty.sock",
      terminalSessionId: "terminal-1",
      capability: "capability",
    },
    forwarder: {
      async enqueue(event, ompSessionId) {
        sent.push({ event, ompSessionId });
      },
    },
  });

  await pi.handlers.get("tool_execution_start")(
    {
      toolCallId: "call-1",
      toolName: "bash",
      args: { command: "printf secret" },
      intent: "prompt-derived private intent",
    },
    ctx,
  );
  await pi.handlers.get("tool_execution_end")(
    {
      toolCallId: "call-1",
      toolName: "bash",
      result: { content: "private result" },
      isError: true,
    },
    ctx,
  );
  await pi.handlers.get("message_update")(
    {
      message: { content: "answer text" },
      assistantMessageEvent: {
        type: "text_delta",
        delta: "answer text",
        partial: { provider: "private-provider-data" },
      },
    },
    ctx,
  );
  await pi.handlers.get("message_update")(
    {
      message: { content: "private answer" },
      assistantMessageEvent: {
        type: "thinking_delta",
        contentIndex: 2,
        delta: "x".repeat(9000),
        partial: { provider: "private-provider-data" },
      },
    },
    ctx,
  );
  await pi.handlers.get("message_update")(
    {
      message: { content: "private answer" },
      assistantMessageEvent: {
        type: "reasoning_delta",
        contentIndex: 0,
        text: "reasoning path",
        partial: { provider: "private-provider-data" },
      },
    },
    ctx,
  );

  activeSession = "omp-after";
  await pi.handlers.get("session_switch")(
    {
      reason: "resume",
      previousSessionFile: "/private/session/path",
    },
    ctx,
  );
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(sent.length, 6);
  assert.deepEqual(
    sent.map(({ event }) => event.name),
    [
      "omp.tool.started",
      "omp.tool.finished",
      "omp.reasoning.delta",
      "omp.reasoning.delta",
      "omp.reasoning.delta",
      "omp.session.bound",
    ],
  );
  assert.equal(sent[0].event.tool_name, "bash");
  assert.equal(sent[0].event.args, undefined);
  assert.equal(sent[1].event.result, undefined);
  // A 9000-byte delta is split at the socket's byte cap (minus the JSON
  // escaping margin), not truncated: the chunks still spell every character
  // the model sent.
  assert.equal(sent[2].event.text.length, 7168);
  assert.equal(sent[2].event.content_index, undefined);
  assert.equal(sent[2].event.text + sent[3].event.text, "x".repeat(9000));
  assert.equal(sent[2].event.text.includes("…"), false);
  // The tail was still pending when the session switched, so the switch
  // flushes it first — no old-session text can reach the new session.
  assert.equal(sent[4].event.text, "reasoning path");
  assert.equal(sent[5].previousSessionFile, undefined);
  assert.equal(sent[5].ompSessionId, "omp-after");

  const serialized = JSON.stringify(sent);
  for (const forbidden of [
    "printf secret",
    "private result",
    "answer text",
    "private-provider-data",
    "/private/session/path",
  ]) {
    assert.equal(serialized.includes(forbidden), false);
  }
});

test("coalesces a reasoning burst into one event", async () => {
  const pi = fakePi();
  const sent = [];
  registerGptyEvents(pi, {
    config: {
      socketPath: "/tmp/gpty.sock",
      terminalSessionId: "terminal-1",
      capability: "capability",
    },
    reasoningFlushMs: 5,
    forwarder: {
      async enqueue(event) {
        sent.push(event);
      },
    },
  });

  const ctx = context();
  for (let index = 0; index < 200; index += 1) {
    await pi.handlers.get("message_update")(
      {
        assistantMessageEvent: { type: "thinking_delta", delta: `token-${index} ` },
      },
      ctx,
    );
  }
  assert.equal(sent.length, 0, "nothing is sent while the flush window is open");

  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(sent.length, 1, "one event carries the whole burst");
  assert.equal(sent[0].name, "omp.reasoning.delta");
  assert.equal(
    sent[0].text,
    Array.from({ length: 200 }, (_, index) => `token-${index} `).join(""),
    "coalescing must not reorder or drop a delta",
  );
});

test("splits a multibyte delta on code-point and byte boundaries", async () => {
  const pi = fakePi();
  const sent = [];
  registerGptyEvents(pi, {
    config: {
      socketPath: "/tmp/gpty.sock",
      terminalSessionId: "terminal-1",
      capability: "capability",
    },
    forwarder: {
      async enqueue(event) {
        sent.push(event);
      },
    },
  });

  const ctx = context();
  const text = "é".repeat(5000); // 5000 code points, 10 000 UTF-8 bytes
  await pi.handlers.get("message_update")(
    { assistantMessageEvent: { type: "thinking_delta", delta: text } },
    ctx,
  );
  // A turn-ending event flushes the tail synchronously.
  await pi.handlers.get("agent_end")({ willContinue: false }, ctx);

  const chunks = sent
    .filter((event) => event.name === "omp.reasoning.delta")
    .map((event) => event.text);
  assert.equal(chunks.length, 2, "the 10 000-byte delta needs two events");
  assert.equal(chunks.join(""), text, "no character is lost or replaced");
  for (const chunk of chunks) {
    assert.ok(
      Buffer.byteLength(chunk, "utf8") <= 8 * 1024,
      "a chunk must fit the socket's byte cap",
    );
  }
  assert.equal(chunks[0].length, 3584, "the cut is on a code point, not a byte");
});

test("flushes reasoning before the turn-ending event", async () => {
  const pi = fakePi();
  const sent = [];
  registerGptyEvents(pi, {
    config: {
      socketPath: "/tmp/gpty.sock",
      terminalSessionId: "terminal-1",
      capability: "capability",
    },
    forwarder: {
      async enqueue(event) {
        sent.push(event);
      },
    },
  });

  const ctx = context();
  await pi.handlers.get("message_update")(
    { assistantMessageEvent: { type: "thinking_delta", delta: "tail" } },
    ctx,
  );
  await pi.handlers.get("agent_end")({ willContinue: false }, ctx);

  assert.deepEqual(
    sent.map((event) => event.name),
    ["omp.reasoning.delta", "omp.agent.settled"],
    "the tail must land before the pane freezes the turn",
  );
  assert.equal(sent[0].text, "tail");
});

test("uses one JSON-RPC request per connection", async () => {
  const requests = [];
  let connections = 0;

  class FakeSocket extends EventEmitter {
    setTimeout() {}
    end(data) {
      requests.push(JSON.parse(data));
      queueMicrotask(() => this.emit("close"));
    }
    destroy() {}
  }

  const forwarder = createEventForwarder(
    {
      socketPath: "/tmp/gpty.sock",
      terminalSessionId: "terminal-1",
      capability: "capability",
    },
    {
      validateSocket: () => true,
      netModule: {
        createConnection() {
          connections += 1;
          const socket = new FakeSocket();
          queueMicrotask(() => socket.emit("connect"));
          return socket;
        },
      },
    },
  );

  await Promise.all([
    forwarder.enqueue({ name: "omp.agent.started" }, "omp-1"),
    forwarder.enqueue({ name: "omp.agent.settled" }, "omp-1"),
  ]);

  assert.equal(connections, 2);
  assert.equal(requests.length, 2);
  assert.equal(requests[0].jsonrpc, "2.0");
  assert.equal(requests[0].method, "ompEvent");
  assert.equal(requests[0].params.v, 1);
  assert.equal(requests[0].params.seq, 1);
  assert.equal(requests[0].params.capability, "capability");
  assert.equal(requests[0].params.terminal_session_id, "terminal-1");
  assert.equal(requests[0].params.omp_session_id, "omp-1");
});

test("bounds the pending outbox and drops oldest entries", async () => {
  class StalledSocket extends EventEmitter {
    setTimeout() {}
    destroy() {}
  }

  const forwarder = createEventForwarder(
    {
      socketPath: "/tmp/gpty.sock",
      terminalSessionId: "terminal-1",
      capability: "capability",
    },
    {
      validateSocket: () => true,
      netModule: { createConnection: () => new StalledSocket() },
    },
  );

  let resolved = 0;
  for (let index = 0; index < MAX_OUTBOX_EVENTS + 12; index += 1) {
    void forwarder.enqueue({ name: "omp.turn.started", turn_index: index }, "omp-1").then(() => {
      resolved += 1;
    });
  }
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(resolved, 11);
});

test("validates Unix socket type, owner, and private mode", () => {
  const base = {
    platform: "linux",
    geteuid: () => 1000,
  };
  const metadata = (overrides = {}) => ({
    isSocket: () => true,
    uid: 1000,
    mode: 0o140600,
    ...overrides,
  });

  assert.equal(
    validateSocket("/tmp/gpty.sock", {
      ...base,
      fsModule: { statSync: () => metadata() },
    }),
    true,
  );
  assert.equal(
    validateSocket("/tmp/gpty.sock", {
      ...base,
      fsModule: { statSync: () => metadata({ uid: 1001 }) },
    }),
    false,
  );
  assert.equal(
    validateSocket("/tmp/gpty.sock", {
      ...base,
      fsModule: { statSync: () => metadata({ mode: 0o140660 }) },
    }),
    false,
  );
  assert.equal(
    validateSocket("/tmp/gpty.sock", {
      ...base,
      fsModule: { statSync: () => metadata({ isSocket: () => false }) },
    }),
    false,
  );
  assert.equal(validateSocket("relative.sock", { ...base, fsModule: {} }), false);
});

test("accepts a Windows named-pipe path, from the path alone", () => {
  const pipe = String.raw`\\.\pipe\gpty-events`;
  // A pipe path must not be stat'ed: on Windows that call throws for a pipe,
  // and the branch exists precisely to answer before touching the filesystem.
  const explodingFs = {
    statSync() {
      throw new Error("a named pipe must not be stat'ed");
    },
  };
  const win32 = { platform: "win32", fsModule: explodingFs };

  assert.equal(validateSocket(pipe, win32), true);
  // A path that is not a pipe is refused on Windows, whatever it is: the
  // listener is the only thing reachable there.
  assert.equal(validateSocket("C:\\gpty\\gpty-events.sock", win32), false);
  assert.equal(validateSocket("/tmp/gpty-events.sock", win32), false);
  assert.equal(validateSocket("gpty-events", win32), false);
  // `\\.\pipe\` must be the prefix, not merely a substring.
  assert.equal(validateSocket("x\\\\.\\pipe\\gpty-events", win32), false);
  assert.equal(validateSocket("\\\\.\\pipe", win32), false);
});

test("hands the platform path to the transport unchanged", async () => {
  const pipe = String.raw`\\.\pipe\gpty-events`;
  const seen = [];
  let sent = "";

  class FakeSocket extends EventEmitter {
    setTimeout() {}
    end(data) {
      sent = data;
      queueMicrotask(() => this.emit("close"));
    }
    destroy() {}
  }

  // The Windows leg of the transport is `net.connect(path)` — Node opens a
  // named pipe for a pipe path — so the one thing gpty must get right is
  // passing that path through untouched.
  const forwarder = createEventForwarder(
    { socketPath: pipe, terminalSessionId: "terminal-1", capability: "cap" },
    {
      platform: "win32",
      fsModule: { statSync: () => assert.fail("unreachable") },
      netModule: {
        createConnection(path) {
          seen.push(path);
          const socket = new FakeSocket();
          queueMicrotask(() => socket.emit("connect"));
          return socket;
        },
      },
    },
  );

  await forwarder.enqueue({ name: "omp.agent.started" }, "omp-1");

  assert.deepEqual(seen, [pipe]);
  assert.equal(JSON.parse(sent).params.capability, "cap");
});
