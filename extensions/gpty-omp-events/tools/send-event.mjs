// Send one event through the extension's real transport, from inside a gpty
// pane.
//
// Dev/CI tool, not part of the extension's surface (the package is private, so
// nothing here is published): `scripts/smoke_pane_api.py` runs it inside a pane,
// where the per-PTY `GPTY_EVENT_*` variables exist, and then asserts the pane
// reports Tier 1 `working`. That single assertion spans the whole chain on
// whichever platform runs it — pane environment, the extension's transport
// (Unix socket or Windows named pipe, both `net.connect(path)`), the
// capability-authenticated submission, the translation to the generic
// vocabulary, the GDScript drain, and the agent state it sets.
//
//   node extensions/gpty-omp-events/tools/send-event.mjs [wire-event-name]
//
// It lives outside `test/` on purpose: the runner discovers everything under
// that directory, and a tool that needs a gpty pane would fail the suite.
//
// Exit codes: 0 dispatched, 2 not activated (the pane is not a gpty pane, or
// the event channel is not configured). The extension's transport is
// fire-and-forget — it never awaits a reply, because a dead event channel must
// not affect the agent session — so "dispatched" is all this tool can report;
// the smoke asserts acceptance through `pane-status`.

import { createEventForwarder, readConfiguration } from "../src/transport.js";

const name = process.argv[2] ?? "omp.agent.started";

const config = readConfiguration();
if (!config) {
  console.error(
    "not activated: GPTY_EVENT_PROTOCOL=1, GPTY_EVENT_SOCKET, GPTY_TERMINAL_SESSION_ID " +
      "and GPTY_EVENT_CAPABILITY must all be set",
  );
  process.exit(2);
}

const forwarder = createEventForwarder(config, { timeoutMs: 2000 });
await forwarder.enqueue({ name, emitted_at_ms: Date.now() }, "smoke");
console.log(`dispatched ${name} via ${config.socketPath}`);
