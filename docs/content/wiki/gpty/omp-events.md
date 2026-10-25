# OMP Events

OMP Events is gPTY's observability channel: a second local socket that carries semantic events about agent sessions, turns, and tools. It is separate from workspace control on purpose — a terminal capability may append events, and nothing else.

## Why a second socket

The control socket is authority: create a pane, inject input, kill a pane, read a pane. An agent extension that only wants to say "a turn started" should not hold that. So the event channel is a different listener with a different method set and its own credential:

| | Control socket | Event socket |
|---|---|---|
| Purpose | Drive the workspace | Report what an agent is doing |
| Callers | CLI, MCP, scripts | A pane's program, subscribers |
| Credential | Same-UID peer, optional secret | Per-PTY event capability |
| Endpoint | `gpty.sock` / `\\.\pipe\gpty` | `gpty-events.sock` / `\\.\pipe\gpty-events` |

The event listener does not honour `GPTY_SOCKET` or `GPTY_SECRET`. It runs on the same transport server as the control socket, but registers exactly three methods.

## Methods

| Method | Gate | Purpose |
|---|---|---|
| `ompEvent` | Per-PTY capability, protocol version, bounded payload | Submit one event |
| `subscribe` | None (read-only) | Reserve a poll cursor; at most 64 live subscriptions |
| `eventsPoll` | Subscription id | Drain queued events; default 64, clamped to 256 |

There is no push transport in this protocol version: subscribers poll. A subscription that stops polling is released after 120 seconds and its queued events with it, so an abandoned client cannot exhaust the 64 slots.

## The credential

Every PTY is started with four variables:

| Variable | Value |
|---|---|
| `GPTY_TERMINAL_SESSION_ID` | Ephemeral session id for this PTY |
| `GPTY_EVENT_CAPABILITY` | Unguessable per-PTY secret |
| `GPTY_EVENT_SOCKET` | Absolute event socket path |
| `GPTY_EVENT_PROTOCOL` | `1` |

A submission names the terminal session and presents the capability, which is compared in constant time. The capability is not reused across panes and is unregistered when the pane goes away. Setting only some of the four variables does nothing.

## Vocabulary

Wire names are the adapter's; the trust boundary translates them into an adapter-neutral vocabulary, so Reasoning and agent state consume one contract:

| Wire event | Generic name | Carries |
|---|---|---|
| `omp.session.bound` | `session.bound` | Session identity reason |
| `omp.session.shutdown` | `session.shutdown` | Timestamp |
| `omp.agent.started` | `agent.started` | Timestamp |
| `omp.agent.settled` | `agent.settled` | Timestamp |
| `omp.turn.started` | `turn.started` | Turn index, times |
| `omp.turn.finished` | `turn.finished` | Turn index, time |
| `omp.tool.started` | `tool.call` | Tool name, call id |
| `omp.tool.finished` | `tool.finished` | Call id, error flag |
| `omp.reasoning.delta` | `thinking.delta` | Reasoning text, ≤8 KiB |
| `gpty.state.declared` | `state.declared` | One of the five agent states |

The socket also carries gPTY's own workspace events: pane spawn, pane kill, and concept matches. Plugin manifests subscribe to those by the names `pane.spawned`, `pane.killed`, and `concept.matched`; a notify-only concept produces a concept match with no content attached.

## What is forwarded, and what is not

The extension is a separately installable component and its payload is untrusted, so translation is a field allowlist, not a passthrough. Each allowed field has a type and a cap — identifiers up to 128 bytes, a session reason up to 64 bytes, thinking text up to 8 KiB — and anything not listed is dropped, including fields a future extension version invents. A declaration naming an unknown state is rejected rather than silently ignored, and an oversized reasoning delta is rejected rather than truncated.

Prompts, answer text, tool arguments and results, provider objects, session file paths, environment variables, and credentials are never forwarded. The event channel is metadata about a workspace, not a copy of the conversation.

## The bundled extension

`@gpty/omp-events` is the OMP extension that speaks this protocol. It is not loaded automatically; the user links it:

```bash
omp plugin link /absolute/path/to/gpty/extensions/gpty-omp-events
```

It is dormant unless all four variables are present, registers no tools or commands, and forwards from OMP's extension event hooks. Reasoning deltas are coalesced for up to 16 ms and sent as events of at most 8 KiB of UTF-8, split on code-point boundaries rather than truncated, which keeps a token-rate stream under the queue budget. The transport is one code path on both platforms: `net.connect(path)` opens a Unix domain socket for a socket path and a named pipe for a pipe path, with validation differing per platform.

## What consumes it

The Reasoning pane projects the event stream into its view; it needs the extension and the event socket to receive anything. Tier 1 agent state also reads these events: agent start becomes `working`, settled becomes `completed`, a failed tool call becomes `needs-attention`, and an explicit declaration passes its value through. See [[agent-state]] for the merge rules.

## What the channel cannot do

It cannot create panes, inject input, read pane output, change settings, or shut gPTY down. There is no method for any of it. Reading the fan-out is open to same-UID processes — the channel is not confidential from your own user — while submitting is gated by the per-PTY capability.

## Related

- [[agent-state]]
- [[reasoning]]
- [[ipc]]
- [[control-api]]
- [[gpty]]
