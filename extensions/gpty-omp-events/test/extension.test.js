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

  assert.equal(sent.length, 5);
  assert.deepEqual(
    sent.map(({ event }) => event.name),
    [
      "omp.tool.started",
      "omp.tool.finished",
      "omp.reasoning.delta",
      "omp.reasoning.delta",
      "omp.session.bound",
    ],
  );
  assert.equal(sent[0].event.tool_name, "bash");
  assert.equal(sent[0].event.args, undefined);
  assert.equal(sent[1].event.result, undefined);
  assert.equal(sent[2].event.text.length, 8192);
  assert.equal(sent[2].event.content_index, 2);
  assert.equal(sent[3].event.text, "reasoning path");
  assert.equal(sent[3].event.content_index, 0);
  assert.equal(sent[4].event.previousSessionFile, undefined);
  assert.equal(sent[4].ompSessionId, "omp-after");

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
