---
title: "Roadmap details - CLI"
weight: 900
build:
  list: never
---

Every CLI row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## CLI-1

**CLI binary (`gpty`)** - control a running GUI over JSON-RPC IPC. Supports new-pane, list-panes,
kill-pane, focus-pane, inject, and layout management. Auto-spawns the GUI daemon if it's not already
running.

Commits: d17bac7

## CLI-2

**`gpty pane-wait --socket <path>` is silently ignored** - `pane_wait.rs` builds its own client from
`transport::default_socket_path()` (the env override works, the flag does not), unlike every other
command, which routes through the `Cli.socket`/`GPTY_SOCKET` resolution in `main.rs`. Found while
driving the smoke's sandbox socket. **Closed:** the command takes the dispatched `IpcClient` like
every other one and derives its longer budget from it (`IpcClient::with_timeout` - same endpoint,
same secret, the read budget a held response needs), so the endpoint is exactly what
`--socket`/`GPTY_SOCKET`/the platform default resolved in `main.rs`; a sweep of the crate's
`IpcClient::new` sites confirms the two remaining ones are deliberate (the daemon's liveness probes,
and `state`'s event-socket client built from pane credentials). Evidence:
`pane_wait_reaches_the_resolved_socket` and `pane_wait_outlives_the_connection_budget` in
`crates/gpty-cli/src/tests.rs` - both fail against the old implementation (connection refused at the
default socket) and pass against the fix; the roundtrip harness gained `start_server_with` for a
handler that holds its response 300 ms while the dispatched client's budget is 50 ms.
`./scripts/ci-check` green.

Commits: d17bac7

## CLI-3

**CLI auto-spawn semantics: a query must not start a workspace** - reported on the v0.5.5 download:
`./gpty list-panes` *launched a GUI*. Not an accident of one command: `main.rs` routes every command
that is not handled early through `daemon::ensure_running()`, which spawns a GUI whenever its 1 s
`version` probe fails. The harness already knew the rule - `scripts/smoke_pane_api.py` passes
`--no-daemon` to its `daemon status`/`daemon stop` probes with the comment "a probe must not
auto-spawn a second GUI" - and the CLI violates it in both directions: `daemon status` can *create*
the daemon it then reports as running, `daemon stop` opens a window in order to stop it, `pane-wait`
spawns a GUI and then blocks out its full timeout against a pane that never existed, and
`list-panes`/`pane-read`/`pane-status`/`pane-run`/`inject`/`broadcast`/`kill-pane`/`focus-pane`/`layout list`/`layout save`/`concept list`/`concept toggle`
all address state a fresh GUI cannot have, so the spawn adds a window and a misleading error. Rule
to implement: **spawn only when a fresh GUI can satisfy the command.** Spawn: `daemon start`
(explicit, in its own arm - today it only prints that the auto-spawn should have handled it),
`new-pane`, `layout load <name>` ("start this saved workspace"), `plugin install` (already its own
call; the review dialog is the point). Never spawn - fail fast with
`error: no gpty GUI is running (start one with `gpty daemon start`)`, exit 1: every query
(`list-panes`, `pane-read`, `pane-status`, `pane-wait`, `layout list`, `concept list`,
`daemon status`), every pane-targeted mutation (`kill-pane`, `focus-pane`, `inject`, `broadcast`,
`pane-run`, `layout save`), `concept toggle`, and `daemon stop`. Unchanged:
`version`/`schema`/`--skill` are local-only, `state` uses the event socket, the `plugin` admin
actions touch only the store, and `mcp` never spawns (its tools share one client; an agent
bootstraps with the `daemon-start` tool) - a deliberate difference from the CLI that the docs must
state. Edge cases to pin with tests: `daemon status` never creates a socket; `daemon stop` with
nothing running is a clear no-op; two concurrent `new-pane` calls still yield one GUI (the loser
reconnects to the winner - needs the single-instance bind above); a spawn that cannot start
(headless/CI, no display) reports *why* instead of waiting out the timeout with the child's stderr
discarded; `--no-daemon` keeps meaning "never spawn" everywhere; and the `--no-daemon` error path
becomes the shared message for the never-spawn set. **Closed:** the gate is per command and
exhaustive (`main.rs::may_autospawn`): `new-pane` and `layout load` may start a GUI (as may
`plugin install`, in its own arm), everything else never does, and `--no-daemon` refuses even those.
The never-spawn set fails with the shared `no gpty GUI is running (start one with `gpty daemon
start`)`, exit 1 - `daemon::is_not_running` classifies
`ClientError::Connection(NotFound \| ConnectionRefused)` anywhere in the error chain, so a refused
insecure path keeps its own message. `daemon` moved to its own arm: `start` is the explicit spawner
(it refuses under `--no-daemon`), `stop` with nothing running is an idempotent no-op (exit 0), and
`status` can never create what it checks; MCP never auto-starts a GUI - `daemon-start` is the
bootstrap, and a tool call that finds none answers with the hint plus "call the daemon-start tool
first". Spawn mechanics hardened on the way: a GUI is started only when the probe says the endpoint
is genuinely empty (a listener that does not answer is waited out - the single-instance rule makes a
duplicate pointless), the child's stderr goes to a private O_EXCL temp file so a GUI that cannot
start reports why immediately, and a GUI that binds while a call waits is adopted (the
concurrent-`new-pane` property). Tests: policy table per command, hint classification (context
wrapping + refused-path negative), spawn-once/timeout, dead-GUI stderr, adopt-on-appear, status/stop
no-spawn - 75 CLI tests green; `scripts/ci-check` green (live smoke included); live CLI checks
against a sandbox socket for every path above. Docs: README, the manual test table,
`skills/gpty/SKILL.md`, AGENTS.md. Queued from this work: `--json` status prose on the failure
paths, and a same-frame duplicate in agent-state dispatch.

Commits: d17bac7

## CLI-4

**A stale CLI on `PATH` fails opaquely** - found 2026-09-17 on the v0.5.5 release:
`gpty plugin install …` answered `error: unrecognized subcommand 'plugin'` and `gpty version`
printed `gpty 0.5.0` while the running GUI was the freshly downloaded 0.5.5 bundle. The bundle was
correct and the cause was environmental - a `cargo install --path crates/gpty-cli` from an *older
checkout* (Sep 9, the pre-plugin build) shadowing the bundle's CLI on `PATH` - but nothing in the
product said so. The CLI already *reads* the GUI's version (the IPC `version` response:
`daemon status` prints "gpty GUI is running (v0.5.5)") and never compares it with its own
`CARGO_PKG_VERSION`, so the only signal was a clap error for a subcommand that exists in the release
the user was running. Fix: after a successful IPC connect, when the GUI's reported version differs
from the CLI's, print one stderr line naming both and the remedy (reinstall the CLI, or use the one
shipped beside the GUI). Keep it to a real mismatch - a warning on every command of a healthy
install is noise - and leave `gpty version` local-only (it cannot probe a GUI, by design). Same
pass: a line in CONTRIBUTING/README that a dev-installed CLI must be reinstalled after a version
bump; the stale binary here survived three releases because the repo directory moved
(`/mnt/App/Projects/gpty` → `…/godot-pty/gpty`) and nothing re-ran the install. **Closed:** every
command that talks to a GUI compares it with itself. The check rides on `version` responses the CLI
already reads (the spawn gate's probe, `daemon status`), and a command that has not probed runs
`daemon::warn_on_version_mismatch` first - one probe with a 500 ms budget that can never fail or
gate the work; the MCP server warns the same way at startup. One stderr line, once per process: IPC
protocol first (a GUI from before the field existed falls through to the version comparison), then a
direction-aware version line (older CLI → reinstall it; older GUI → update the GUI; unparseable
numbers → a generic "same release"). `gpty version` stays local-only by design. The protocol string
now has one definition - `gpty_ipc::protocol::PROTOCOL_VERSION`, consumed by the server's `version`
handler, the CLI's `version` output and the check, and the About tab via the new static
`get_ipc_protocol_version()` (the tab had a third hardcoded `2.0`). Docs: README and CONTRIBUTING
carry the dev-install reinstall rule the item asked for. Evidence: the line-builder test
(protocol-first, both directions, unparseable, nothing to compare), a live fake-GUI run (newer GUI →
the warning; matching pair → silent; other protocol → the protocol line), 501 GUT tests (the About
label pinned to the FFI), and `scripts/ci-check`.

Commits: d17bac7

## CLI-5

**`gpty daemon status --json` answers prose when the GUI is not running** - the running path prints
the raw `version` response envelope (parseable JSON), but the not-running, busy, and refused paths
print plain sentences (`gpty GUI is not running.`) with no JSON at all, so a script that probes with
`--json` gets unparseable output exactly when the probe matters. Give those paths a JSON shape (e.g.
`{"status": "not running"}` / `{"status": "busy"}` / `{"status": "error", "error": …}`) while
keeping exit 1; the MCP `daemon-status` tool already answers shaped objects. Found while making
`daemon status` spawn-free (v0.5.6). **Closed:** `status_answer` + `run_status` give every failing
path a shaped object under `--json` - `{"status": "not running"}` / `{"status": "busy"}` /
`{"status": "error", "error": …}` (refused paths and auth included) - with exit 1, while the running
path keeps the raw `version` response the smoke parses (`result.version`) and the plain path keeps
its sentences. The statuses are the MCP `daemon-status` vocabulary, so a script can move between
transports. Evidence: the shape test (all four failing outcomes, and running → `None`), a live run
(dead socket → `not running`; a refused path → the error naming it; plain mode unchanged; a fake GUI
→ the raw envelope with `result.version`), and `scripts/ci-check`.

Commits: d17bac7

## CLI-6

**`--json` reports a failed command as exit 0** - `format_response` printed the JSON-RPC envelope
and returned `Ok` whenever `--json` was set, so `gpty vault read <vault> missing.md --json` exited 0
with `{"error": {…}}` on stdout while the same command without the flag exited 1. Every IPC-backed
command inherited it, which defeats the machine-readable mode for a script that branches on the exit
status, and gave the CLI two answers: v0.5.6's `daemon status --json` decision was shaped JSON
**and** exit 1. Measured 2026-10 while adding the vault commands - the smoke's first assertion was a
nonzero-exit check and failed. `format_response` prints the envelope first (stdout stays parseable)
and then fails on `resp.error` in both modes, and the rule lives once in `check_error`, called by
the three custom-output paths (`list-panes`, `layout list`, the all-panes `pane-status`) instead of
each re-deciding it. The all-panes path also reports the RPC refusal itself rather than its
"listPanes returned no result" symptom. Tests: two `commands::mod` unit tests (both modes, the
shared message), two in-crate roundtrips (a `vault read` error and a `layout list` error both fail
under `--json`), and the live smoke now uses a new `cli_run` helper that parses stdout on a failed
exit and asserts **both** a nonzero status and `data.code == "not_found"` - its `cli(check=False)`
also returns the parsed envelope now instead of `{}`, so no probe loses the answer. Docs: the CLI
README's `--json` flag, the manual checklist, AGENTS, and the CHANGELOG. The MCP server is
untouched: it builds its own in-band errors.

Commits: d17bac7

## CLI-7

**`pane-status --json` (no pane) answers the pane list, not the statuses** - the command's contract
is "omit the pane for every pane's status", and the non-JSON path performed exactly that (a
`listPanes`, then a `paneStatus` per pane, printed as `{panes: [{pane_id, label, type, status}]}`),
but the JSON branch printed the raw `listPanes` envelope and returned: `gpty pane-status --json`
carried no `status` at all, so the machine-readable mode was less useful than the human one, and the
non-terminal panes the per-pane path skipped were silently absent rather than reported as having no
status. Found 2026-10 while auditing every `if json` branch for the exit-status fix above. the
aggregate moved into the API rather than being rebuilt in the CLI. `paneStatus` with no `pane_id`
now answers `{panes: [{pane_id, label, type, status}]}` for every tile - terminal rows carry the
same status document the single-pane form answers, non-terminals carry `status: null` - so one
definition serves the CLI's no-argument mode and the MCP `pane-status` tool (which dispatches
straight to `paneStatus` and previously could not answer its own no-argument form at all;
`workspace.gd` already normalizes null params to `{}`). The CLI is now a single
`call_and_format(client, "paneStatus", {})`, so `--json` prints the usual response envelope and the
non-JSON mode prints the same payload; the old N+1 fan-out is gone. The single-pane contract is
otherwise unchanged, with one honesty fix: targeting a real non-terminal pane answers "has no status
(not a terminal)" instead of "not found", which sent an agent looking for a pane `listPanes` had
just named. Tests: a GUT case drives the real `WorkspaceIpcHandlers.handle` on a workspace with a
terminal and a code_viewer (aggregate covers every tile, the terminal carries `running`, the viewer
is present with `status: null`, and both single-pane shapes still hold), and a CLI roundtrip pins
that the no-pane mode sends one empty request (a fan-out would call the unregistered `listPanes` and
fail). Docs: the CLI and IPC READMEs, `skills/gpty/SKILL.md`, and the CHANGELOG.

Commits: d17bac7

## CLI-8

**The Windows smoke's CLI occasionally exits `0xC0000374` (`STATUS_HEAP_CORRUPTION`) on `inject`** - one
occurrence so far: run 39262704860 / job 118094242727 on commit `0a6c940`, at the `gpty state`
step's first `inject` (`--text "\"…\\gpty.exe\" state needs-attention"`). The CLI printed no stdout
and no stderr, so the corruption happened during the call, not at exit; the same SHA's rerun of the
same job passed that step, and the command has passed on every earlier commit. Each CLI command is a
fresh process and makes two named-pipe connections (the best-effort `version` probe, then the
command itself), so the plausible class is a Windows named-pipe client teardown race (mio/tokio),
not a logic error in `inject`. Fix direction: keep the failure diagnosable (the smoke now tails the
`--log-file` engine log and carries the pane tail plus the hex status), then reproduce with a
Windows-only loop of throwaway `pane-status`/`inject` processes (N runs ≈ N connection teardowns)
before changing anything; if it reproduces, test the CLI's runtime shape (`process::exit` from
`#[tokio::main]` skips a clean runtime shutdown; a current-thread runtime removes worker-thread
teardown entirely) and the mio client path. Do not add a retry around the step: the crash is the
signal. it did not reproduce before changing anything - no Windows host is reachable from this
workspace - and it has not been seen again in the four windows-smoke runs after the recorded failure
(39276550729, 39305294761, 39307240548, 39308596924; 39275354197 and 39272179130 failed in GUT, not
here). The runtime-shape half was applied rather than left waiting for a second occurrence:
`crates/gpty-cli/src/main.rs` is now `#[tokio::main(flavor = "current_thread")]`. Every command is
one request in a process that exits as soon as it has an answer, and nothing in the CLI or
`gpty-ipc` uses `spawn_blocking`, `block_in_place` or `tokio::process`, so the multi-thread flavor's
workers bought no parallelism - they were the only concurrency around `process::exit`, which is
exactly what a worker torn down mid-allocation needs to corrupt the heap. It also removes the worker
pool's startup from every invocation: measured on Linux, 300 `gpty version` runs went from 1.037 s
to 0.599 s (3.46 → 2.00 ms each). The loop the item asked for is permanent now:
`scripts/smoke_pane_api.py` runs 100 throwaway `pane-status` processes right after the pane-status
checks - ≈ 200 connections, because each process opens the best-effort `version` probe and then its
command - and a nonzero exit fails with its hex status, the pane tail and the engine-log tail, with
no retry. Verified live: the Linux smoke passes with the new step, `cargo test -p gpty -p gpty-ipc`
passes, and `./scripts/ci-check --fast` is green. The mio client path was not implicated: the only
known heap-corruption class there is tokio#6369 (a `ScheduledIo` use-after-free when a named-pipe
client disconnects), fixed by mio#1760 and released in mio 0.8.11, while this tree pins mio 1.2.2 /
tokio 1.53.1. The Windows run after this commit is the first live exercise of the stress step; if it
ever reports `0xC0000374` again, that step is the amplifier, and a WER `LocalDumps` crash dump (or
Application Verifier's heap checks on the CLI) is the next evidence to collect before touching the
client path.

Commits: d17bac7

## CLI-9

**A fresh plugin install always fails after review: the destination's parent is never created** - found
on the v0.7.0 download (reproduced on HEAD with both the release CLI and a source build): every
valid id is `owner/name`, so `move_into_place` created only `<data>/plugins` and renamed the staged
clone to `plugins/<owner>/<name>`, whose parent did not exist; the rename failed with ENOENT *after*
the review had been accepted, so no content moved and no `plugins.json` record was written —
`gpty plugin list` stayed empty and the sidebar had no profile. The printed error was only
`moving … into …`, dropping the ENOENT, which is why it read as a successful install.
`move_staged_into` now creates the destination's parent, and `report_error` prints the full anyhow
cause chain (`{e:#}`). Tests: `plugin_move_creates_the_id_parent_directory` and
`plugin_move_replaces_an_existing_install`; verified by installing `godot-pty/gpty-lazygit` on the
fixed build — the store record and its `Lazygit` profile are written, and the row appears in the
sidebar. Re-testing also exposed the already-installed early return disarming the staging guard,
which leaked a full clone under `<data>/staging` on every re-install; the guard now stays armed so
Drop removes it.

Commits: 43cfc7a

## CLI-10

**Plugin commands never run the stale-binary check** - reported on the v0.7.0 download: the CLI on
`PATH` was 0.5.5 and `gpty plugin install godot-pty/gpty-herdr` failed with
`plugins.json is corrupt: record 0: unknown key 'concepts'`. The record was written by the v0.7-era
CLI (which stores concepts); the older reader rejects keys it does not know. The store was intact
and HEAD reads it (profiles/concepts are optional) — installing with HEAD succeeds at revision
`05f94806a0a5`. No build of 0.5.5 vintage can warn, but the `plugin` arm sits above the generic
dispatch and ran no `warn_on_version_mismatch`, so the reverse skew (newer CLI, older GUI) is also
silent, and a newer store then looks corrupt to the older side. Fix direction: probe before plugin
commands (bounded, best-effort, silent without a GUI), as `mcp` already does. **Closed:**
`plugin::run` runs that probe before it dispatches any action (`daemon::warn_on_version_mismatch`,
the same 500 ms best-effort check `mcp` and `main`'s generic dispatch already used - the plugin arm
sits above that dispatch, so the check rides on the surface: one rule for every action, including
the offline validator, where no GUI means one failed connect and no output). `install` now warns
before its clone and review instead of after its staging work (its `ensure_running` probe was the
only one that ran, and only on that path). The warning is stderr-only, so `plugin list --json` stays
parseable. Smoke against a stand-in GUI answering version `9.9.9` on the socket: `plugin validate`
and `plugin list --json` printed the direction-aware line and then their normal output (exit 0,
stdout parsed by a JSON reader); with the socket absent, neither printed anything. Regression test
`plugin_commands_probe_the_gui_version_first` counts `version` requests on a real IPC server - 0
with the call removed, 1 with it and the validator still succeeds - and
`daemon::reset_version_latch` clears the once-per-process latch that this parallel test binary
shares.

Commits: 43cfc7a, 11f5274

## CLI-11

**A just-written test program can fail to spawn with `ETXTBSY`** - closed 2026-10-30, after the
parallel suite failed on two of three consecutive CI runs (the control spawn in
`cli::process_tests::spawn_refuses_a_program_another_user_could_have_written`, while the serial pass
never failed). The kernel answers `ETXTBSY` while any process holds the file open for writing, and
libtest's thread pool forks for other tests: a fork on another thread can hold a dup of this file's
write descriptor for a moment after `fs::write` closed ours. Fix, per the row: the temp name carries
a nanosecond stamp as well as the pid, so no other test process can share it, and the *control*
spawn retries `Text file busy` only, twenty times at 25 ms - the rule under test is the permission
check, and a descriptor that really leaked still fails (every other error breaks the loop at once).
The refusal case is untouched, so the product still reports what it reports. Verified:
`cargo test --workspace` passes twice in a row on this machine, and the next CI run's parallel pass
is the check under load.

Commits: 3d8c503, ed28171, 6cecfd6

## CLI-12

**The verbs for a profile are called `layout`** - shipped 2026-11-15 (build 0.8.4) as one cutover,
no alias: `gpty profile save\|load\|list`, the MCP tools `profile-save` / `profile-load` /
`profile-list`, and the IPC methods `profileSave` / `profileLoad` / `profileList`. The clap group is
`Commands::Profile` with `ProfileAction`, its three doc comments are the tool descriptions ("Save
the active workspace as a profile", "Activate a saved profile in the active workspace", "List saved
profiles"), `commands/layout.rs` became `commands/profile.rs`, and `may_autospawn()` keeps its
exhaustive choice on `ProfileAction::Load`. The four layers that must agree moved together: clap,
the CLI literals, the GDExtension `gdscript_methods` allowlist (`ipc.rs`), and the `ipc_handlers.gd`
arms. The list payload was the other half of the split vocabulary: `profileList` answers
`{"profiles": [...]}` and `commands/profile.rs` reads that key, so `gpty profile list --json` no
longer prints a `layouts` field. Migrated in the same change: `commands/{schema,wire,mcp,daemon}.rs`
(annotation sets, the argument-table sample arms, the prose), `crates/gpty-ipc/README.md`'s method
table, `crates/gpty-cli/src/tests.rs` (mock method names, `profile_list_roundtrip`, the spawn-policy
table), `test_ipc_dispatch_contract.gd` (every literal and the five renamed `test_profile_*`
functions, plus the `profiles` payload assertions), the GDScript prose comments naming the method
(`profile_manager.gd`, `trusted_store.gd`, `pane_body.gd`, `workspace.gd`,
`test_profile_manager.gd`), `scripts/smoke_pane_api.py` (three live invocations and the `profiles`
reads), `scripts/record-demo` (both typed lines and the toast comment), both READMEs, `AGENTS.md`'s
tool list and flattening sentence, `SECURITY.md`, the wiki's
`layout`/`cli`/`control-api`/`ipc`/`mcp`/`workspace-trust`/`getting-started`/`wiki-pane`/`agent-workflow`/`profile`
pages, the agent guides (`testing`, `pitfalls`, `gdscript`, `security`), the overview manual
checklist rows 11-13, `crates/gpty-cli/README.md`, and the three bundled skills (`gpty`,
`gpty-omp-integration`, `gpty-public-surface`, `gpty-wiki`). Not renamed: the `Layout` term (the
arrangement inside one workspace), `user://layout.json`'s one-time legacy import, the vault graph's
`Relayout`, and `layout-apply-preset`. An older CLI now fails at the method instead of reaching a
moved one: `gpty layout list` exits 2 with `error: unrecognized subcommand 'layout'`, and a
pre-rename CLI against this GUI gets `-32601 Unknown method: layoutList`. Gates:
`cargo test -p gpty` (104 tests - the contract tests read the real registrations, the GDScript arms
and every CLI call literal), `./scripts/gut-check` (115 scripts / 1422 tests), `scripts/docs-check`
(193 files / 580 rows), and the fresh-profile smoke ran `profile list` / `profile load` over a live
socket.

Commits: b4703be, a2bfbb3
