import fs from "node:fs";
import net from "node:net";
import path from "node:path";

export const MAX_OUTBOX_EVENTS = 128;
export const MAX_EVENT_BYTES = 16 * 1024;
export const DEFAULT_TIMEOUT_MS = 250;

const REQUIRED_ENV = [
  "GPTY_EVENT_SOCKET",
  "GPTY_TERMINAL_SESSION_ID",
  "GPTY_EVENT_CAPABILITY",
];

function boundedString(value, maxLength) {
  if (typeof value !== "string") return "";
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength - 1)}…`;
}

export function readConfiguration(env = process.env) {
  if (env.GPTY_EVENT_PROTOCOL !== "1") return null;
  if (REQUIRED_ENV.some((name) => !env[name])) return null;

  return {
    socketPath: env.GPTY_EVENT_SOCKET,
    terminalSessionId: boundedString(env.GPTY_TERMINAL_SESSION_ID, 256),
    capability: boundedString(env.GPTY_EVENT_CAPABILITY, 4096),
  };
}

export function validateSocket(socketPath, options = {}) {
  const fsModule = options.fsModule ?? fs;
  const platform = options.platform ?? process.platform;
  const geteuid = options.geteuid ?? process.geteuid?.bind(process);

  if (platform === "win32") {
    return socketPath.startsWith("\\\\.\\pipe\\");
  }
  if (!path.isAbsolute(socketPath)) return false;

  try {
    const metadata = fsModule.statSync(socketPath);
    if (typeof metadata.isSocket === "function" && !metadata.isSocket()) return false;
    if (geteuid && typeof metadata.uid === "number" && metadata.uid !== geteuid()) return false;
    if (typeof metadata.mode === "number" && (metadata.mode & 0o077) !== 0) return false;
    return true;
  } catch {
    return false;
  }
}

function fitRequest(request) {
  let encoded;
  try {
    encoded = `${JSON.stringify(request)}\n`;
  } catch {
    return null;
  }
  return Buffer.byteLength(encoded) <= MAX_EVENT_BYTES ? encoded : null;
}

export function createEventForwarder(config, options = {}) {
  const netModule = options.netModule ?? net;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const validate = options.validateSocket ?? ((socketPath) => validateSocket(socketPath, options));
  const outbox = [];
  let pumping = false;
  let requestId = 0;

  function sendOne(item) {
    return new Promise((resolve) => {
      if (!validate(config.socketPath)) {
        resolve();
        return;
      }

      let settled = false;
      let socket;
      const finish = () => {
        if (settled) return;
        settled = true;
        try {
          socket?.destroy();
        } catch {
          // Transport failures must never affect the omp session.
        }
        resolve();
      };

      try {
        socket = netModule.createConnection(config.socketPath);
        socket.setTimeout?.(timeoutMs);
        socket.once?.("connect", () => {
          try {
            socket.end(item.encoded);
          } catch {
            finish();
          }
        });
        socket.once?.("timeout", finish);
        socket.once?.("error", finish);
        socket.once?.("close", finish);
      } catch {
        finish();
      }
    });
  }

  async function pump() {
    if (pumping) return;
    pumping = true;
    try {
      while (outbox.length > 0) {
        const item = outbox.shift();
        await sendOne(item);
        item.resolve();
      }
    } catch {
      while (outbox.length > 0) outbox.shift().resolve();
    } finally {
      pumping = false;
      if (outbox.length > 0) void pump();
    }
  }

  function enqueue(event, ompSessionId) {
    return new Promise((resolve) => {
      const seq = ++requestId;
      const request = {
        jsonrpc: "2.0",
        id: seq,
        method: "ompEvent",
        params: {
          v: 1,
          capability: config.capability,
          terminal_session_id: config.terminalSessionId,
          omp_session_id: boundedString(ompSessionId, 128),
          seq,
          event,
        },
      };
      const encoded = fitRequest(request);
      if (!encoded) {
        resolve();
        return;
      }

      if (outbox.length >= MAX_OUTBOX_EVENTS) {
        outbox.shift().resolve();
      }
      outbox.push({ encoded, resolve });
      void pump();
    });
  }

  return { enqueue };
}
