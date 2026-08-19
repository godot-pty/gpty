# gpty-ai

Pluggable AI backends for gpty's **Inspector** pane.

## Why this crate

Inspector is a private, tool-free, iterative Q&A session. It is not the
user's terminal-hosted OMP TUI and does not scrape PTY output. Concept
captures may still call `receive_content` when the user enables a concept
that targets `inspector`; that opt-in is off in the shipped defaults.

Network / harness I/O lives here on tokio — Godot only polls envelopes.

## Backends

| Kind | Status | Notes |
|------|--------|-------|
| `mock` | Ready | Deterministic local pass-through; used by CI / offline tests |
| `omp` | Ready | One long-lived, tool-free OMP RPC process per Inspector session |
| OpenAI-compatible HTTP | Planned | Same session API |
| Other harnesses (ACP, `omp -p`) | Planned | Thin adapters |

### Oh-My-Pi surfaces

| Surface | Inspector | Terminal OMP + extension |
|---------|-----------|--------------------------|
| `omp --mode rpc --no-session --no-tools --no-extensions --no-skills --no-rules` | Primary — private Q&A | — |
| Documented extension events (`@gpty/omp-events`) | — | Reasoning pane via `gpty-events.sock` |
| gpty MCP (`mcp.json`) | Orthogonal | Workspace control; not the event socket |

Env: `GPTY_OMP` = absolute path to `omp` (validated like `GPTY_GUI`).

## Session API

Each `GptyAi` bridge owns one private in-memory session. There is no
process-global subscriber bus. The JSON-string FFI is:

- `session_open(config_json)`
- `session_prompt(prompt_json)`
- `session_poll(poll_json)`
- `session_cancel(control_json)`
- `session_close(control_json)`
- `list_backends()`

Polled events carry `session_id`, `turn_id`, `run_id`, `sequence`, `channel`,
and a tagged `event` payload. OMP keeps one tool-free RPC process alive
across sequential prompts.

## Security

- Capture text is **untrusted** — truncated (`MAX_CAPTURE_BYTES`) and fenced in the user message.
- Inspector omp runs with `--no-tools` (no shell/edit from the analysis turn).
- Extension UI requests are auto-cancelled (headless).
- API keys stay in omp's own auth store / env — never in layout JSON or concept payloads.

## Known limitations

This crate powers **Inspector only**. Terminal-hosted OMP observability
(Reasoning pane, `@gpty/omp-events`, `gpty-events.sock`) lives in
`gpty-gdext` and the shipped extension — not here.

### Inspector (in scope for `gpty-ai`)

| Limitation | Detail |
|------------|--------|
| One active turn | A second `session_prompt` while a turn is running is rejected until the current turn finishes or is cancelled. |
| In-memory sessions | Inspector history is RAM-only for the pane lifetime. Closing the pane tears down the OMP child (`session_close`). Nothing is written to layout/profile JSON. |
| Capture size | Concept/capture text is truncated to `MAX_CAPTURE_BYTES` before prompt construction. |
| Tool-free OMP | Inspector spawns `omp --mode rpc` with `--no-tools --no-extensions --no-skills --no-rules`. No shell/edit from analysis turns. |
| Prompt timeout | Default 120 s per prompt (`PROMPT_TIMEOUT`). Cancellation is cooperative via `tokio::select!` on stdout reads; very slow OMP responses may still run until timeout. |
| RPC framing | Protocol v2 `rpc_chunk` frames are reassembled with a 64 MiB cap. Oversized or interleaved chunk streams fail the turn. |
| Single backend process | One long-lived OMP RPC process per Inspector session, shared across sequential prompts — not the user's terminal OMP TUI. |
| `GPTY_OMP` only | Binary path override applies to Inspector's private OMP child, not to OMP launched in terminal panes. |

### Reasoning / terminal OMP (out of scope — documented for operators)

These surfaces share OMP but **do not** use `gpty-ai`:

| Limitation | Detail |
|------------|--------|
| Passive projection only | Reasoning never starts jobs, accepts concept captures, or scrapes the TUI. Events must come from the explicitly linked `@gpty/omp-events` extension. |
| Session-scoped accordion | Turn history is in-memory for the current OMP session only (max **16** turns, **64 KiB** UTF-8 per turn). Changing `source_attachment_id`, closing the pane, or binding a new `omp_session_id` clears it. |
| Turn boundary | One accordion fold per `omp.agent.started`. Empty turns still get a stub fold. Repeated `agent.started` without deltas reuses the current empty live fold. |
| Freeze on settle | `omp.reasoning.delta` after `omp.agent.settled` is ignored — the live turn is frozen. |
| Extension required | `omp plugin link …/gpty-omp-events` is one-time; **restart omp** after linking so the extension loads. Verify `echo $GPTY_EVENT_PROTOCOL` prints `1` in the terminal pane. |
| Reconnect semantics | Exiting and relaunching OMP in the same terminal sends a new `omp.session.bound`. Stale shutdown events and extension sequence resets are filtered in `gpty-gdext`; status should return to “Attached” without requiring a prompt. |
| **Unix-only event socket** | The Reasoning path requires `gpty-events.sock` (`omp_events.rs`). **Linux/macOS only** — gpty does not inject `GPTY_EVENT_*` or listen for `ompEvent` on Windows; `drain_agent_events()` returns `[]`. Terminals and Inspector still work on Windows. |
| No disk persistence | Thinking text, OMP session IDs, and `GPTY_EVENT_*` values are never saved to layout/profile JSON. A future SQLite `HistoryStore` may persist the same turn-record shape. |

Planned backends (OpenAI-compatible HTTP, ACP, other harnesses) are not implemented yet.
