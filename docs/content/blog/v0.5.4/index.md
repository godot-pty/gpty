---
title: gpty v0.5.4
date: 2026-09-12
---

v0.5.4 is the release where concepts became visible: a GraphEdit canvas that authors the same
`concepts.json` the engine already ran, conditions that narrow a match instead of widening it, and an
ordering rule — the canvas order *is* the precedence order. Under that sits the platform half: a
Windows runtime smoke that exercises the real pipeline, a security pass over the control socket and
the persistence stores, and the backpressure that stops a flooding pane growing the process or
freezing the window. The license changed as well: GPL-3.0-or-later, with section 7 exceptions that
keep plugins and data files free.

<!--more-->

![gPTY v0.5.4](/images/v0.5.4_1.png)

## The canvas is the rule list

Settings → Concepts → "Open Visual Editor" opens a full-window GraphEdit overlay. A rule is a chain —
trigger → condition* → action, where the action is either capture-and-route or notify-only — and each
port holds one wire, so a rule cannot fork or merge. That is not arbitrary: a compiled entry's
identity is the trigger's name, so one trigger is one rule, and a shared condition or action would
compile two entries under one name.

![The visual concept editor: five rules as chains, each trigger titled with its rank](/images/v0.5.4_2.png)

The canvas is not a second content store. `concepts` stays the single store; the new `graph` sibling
key in `user://concepts.json` holds only the canvas's own state — node positions, drafts (so
unfinished work survives a close), and the rule order described below. `ConceptGraphModel` is pure
logic with 23 unit tests: it builds the canvas from the merged concepts, validates and compiles it
back, writes a rule equal to its shipped
default as *no* user entry (so defaults keep tracking updates), tombstones a deleted shipped rule
exactly like the manual dialog, and keeps a content-invalid rule as a draft rather than compiling it.
`entry_for_path` compiles a closed key set, so a node cannot smuggle a legacy `cmd` back into the file.

**The order you see is the order that runs.** Precedence used to be "shipped defaults first, then user
entries in file order", so dragging a rule reordered nothing — the canvas only looked like a priority
list. The graph block now carries `order` (rule names, top-to-bottom), derived from the rules' trigger
positions — top-to-bottom, then left-to-right, then by name — and `ConceptManager._merge_concepts`
puts the named rules first, with everything the canvas does not name behind them. A newly shipped
default can never quietly outrank an arrangement the user made, and a store with no `order` key keeps
exactly the shipped merge order. Each trigger's title carries its rank, and "Fit" re-rows through the
new `tidy_positions` instead of Godot's `arrange_nodes()`, which lays nodes out by connection shape
and would have silently reshuffled precedence. The live smoke against a real GUI and GDExtension
caught two defects first: rebuilding the canvas removed GraphEdit's internal children, and auto-layout
spacing let an action node overlap a condition.

## Conditions narrow the match, never widen it

A concept may now carry `conditions: [regex, …]`: extra predicates over the same line the trigger
matched, all of which must match before the concept fires. They can only narrow — a concept whose
conditions fail falls through to the next concept, and precedence is unchanged. Parsing rejects the
**whole concept** when a condition is not a string, is empty or oversized, does not compile, or the
list exceeds 8, because dropping a single condition would widen matching, the dangerous direction.
GDScript's `RegEx` is PCRE2 and accepts look-around the Rust regex crate rejects — and
`concepts_from_json` silently drops such a concept — so `GptyTerminal.validate_regex()` exposes the
engine's own dialect to the editor.

**And the matcher stopped paying per concept.** Matching cost is lines × concepts × regex, and the
per-concept loop paid each regex's own prologue on every line — about 20 ns per concept, so a
128-concept library spent 2.7 µs on a line that matched nothing. A flooded pane lost most of its
throughput to it: 5.8 MB/s against 79.9 with no concepts at the parser's ceiling (128 concepts, each a
1024-byte trigger plus eight 1024-byte conditions), and 8.6 against 47.3 for 128 typical triggers on
30-byte lines. `ConceptMatcher` now puts one combined `RegexSet` pass in front of the loop: the common
case — nothing matches — is answered by a single scan, and only a gate hit pays for the ordered loop
that decides capture-versus-notify. The gate cannot change a verdict — it is built from the same
triggers, conditions are still evaluated by the loop, and a test pins the equivalence — and the pane
flood went to 73.3 MB/s at the ceiling (12.6×), 44.9 on 30-byte lines (5.2×), 81.1 with the shipped
set. The probe that measured it is kept (`cargo run --release -p gpty-core --example concept_probe`),
with its results in the file's header.

## Windows runs the whole product now

The `windows-smoke` job (`windows-latest`) boots the GUI headless and drives the CLI against it: the
CLI and GDExtension are built for Windows, Godot 4.7.2's editor is downloaded with its SHA512 pinned
from the release's `SHA512-SUMS.txt`, and `scripts/smoke_pane_api.py` — one harness for every
platform, since only the transport differs (Unix socket versus named pipe, `open()` on both) — runs
the full flow: control round trip, the named-pipe event listener (`subscribe`/`eventsPoll`), pane
lifecycle, inject → pane-wait → pane-read, scrollback, broadcast, `pane-run`'s exit code, and
kill-pane. The GDScript suite runs on Windows too. Getting there was not cosmetic: 14 test files
pinned `/bin/sh`, which `validate_executable` refuses on Windows (a leading `/` is not absolute
there), the failed spawn logs an engine error, and GUT counts engine errors as failures.

Writing the job found real bugs. The first-run shell default was `/bin/bash` on every platform, so
every pane of a fresh Windows install came up with no terminal; it now answers `%COMSPEC%` (falling
back to `cmd.exe`), and `pane-run` now sends `/c` to the cmd family instead of `-c`. "Reset tab to
defaults" hard-coded `/bin/bash` in four places, and because `SettingsManager` is an autoload that
reset leaked into later test files. And a pane's exit was never reported when the pty stayed open —
the task only learned of an exit from the read side closing, which ConPTY keeps open after the child
exits. It now polls the child every 200 ms and drains until the pty has been silent for 500 ms, a fix
testable on Linux with a SIGHUP-immune descendant holding the pty.

**The extension is pinned, and the shutdown that needed it works.** Godot unloads a GDExtension at
exit, and this one owns threads that live inside it — tokio workers, one PTY reader and one history
writer per pane. Under gdb the crash was a `tokio-rt-worker` faulting on a freed code page after
Godot's own exit messages. `pin_library()` now holds the mapping (`RTLD_NODELETE` on Unix,
`GetModuleHandleExW` with `PIN | FROM_ADDRESS` on Windows) at `InitStage::Core`, before anything can
spawn a thread; `daemon stop` answers the client, raises a flag GDScript polls, and exits from a
scheduled task so the quit runs through the scene tree. Verified live 3/3 where the previous code
segfaulted.

**Tier 2 agent state on Windows.** ConPTY re-renders its own model rather than relaying the child's VT
stream, so a sequence its engine does not implement never reaches the pane — measured: a DECSET 2004
from the same PowerShell fixture arrives while every `gpty_state` OSC declaration fails. `gpty state
<value>` is the declaration path on every platform: it reads the credentials a pane injects and
submits `gpty.state.declared` on the event socket, capability-gated rather than spoofable and
display-only like the OSC. Recovering the OSC means owning `CreatePseudoConsole` with passthrough
mode; that is queued on the roadmap, not smuggled into this release.

## The control surface and the stores got a security pass

**Peer credentials fail closed everywhere an API exists.** Linux and macOS already checked the peer's
user; Windows had no check at all. The accept loop now identifies a pipe client with
`GetNamedPipeClientProcessId`, opens that process, reads its token's user SID (`TOKEN_USER` through
`GetTokenInformation`) and compares it with gpty's own via `EqualSid`, rejecting before the handler is
spawned. The BSDs share macOS's `getpeereid`, and illumos/Solaris answer through `getpeerucred`; AIX,
Haiku and QNX keep the documented fail-open, which `SECURITY.md` states. Each new arm is verified
where it can run — FreeBSD compiles in CI, Windows through the xwin/clang-cl check, and illumos and
NetBSD were compile-probed against real libc targets.

**The socket no longer falls back to a shared directory first.** The chain used to end at
`/tmp/gpty-<uid>.sock` — ownership and mode are validated, so nobody can read or spoof traffic, but
another user can hold the name and deny the control surface. It now tries the per-user runtime
directories and then a private directory of our own (`$XDG_STATE_HOME/gpty` or
`$HOME/.local/state/gpty`), created `0700` or tightened from a lax umask, before the shared temp path.
The event socket derives from the same path, so it moves too, and a squatted path is a denial of
service rather than a way in. The pre-creation TOCTOU in the `/tmp` fallback is closed: only a stale
*socket* owned by this user is removed.

**The stores are owner-only, and their writes are unguessable.** SQLite created the history database
— and the `-wal`/`-shm` siblings — with the process umask, measured at `0644` here, so every line any
pane ever printed was readable by any account that could open `user://`. SQLite has no mode setting,
so `history::restrict_to_owner` chmods all three at open, unconditionally, which also tightens a
store written before this change the next time it is opened. Every `user://` store goes through
`BasePersistenceManager._write_file`, whose temp file was the predictable `<store>.tmp` — and
`FileAccess.open(..., WRITE)` follows a symlink, measured: with a link planted at that name, the next
save wrote the store's JSON into the victim file. GDScript has no `O_EXCL`, so the name is the
protection: the suffix is now 64 random bits, the file is created `0600` before the rename, and the
rename replaces the target itself rather than writing through a link at the store path.

**The control surface answers, and refuses what it should.** `gpty mcp` read stdin with `lines()`,
which buffers a request of any length; a line over 65536 bytes — the control socket's own cap — is now
refused with `-32600 "Request exceeds 65536 bytes"` and discarded so the next request starts at a
message boundary. An idle event subscription is released after 120 s without an `eventsPoll`, so 64
abandoned clients cannot exhaust the slot cap permanently, and the extension's translated events are
allowlisted to the fields AGENTS.md documents. A bare program name is judged by the file it resolves
to: `validate_program` resolves it through the `PATH` the child will actually inherit and holds the
first match to the existing rule — regular file, not group/other-writable, owner check, no writable
ancestor.

## A flooding pane stops taking everything with it

**Output has a queue, so the process has a bound.** `pty_rx` was unbounded, so a pane whose output
outran the terminal task grew the process until it died: a `yes` pane added ~70 MiB/s to the GUI (194
→ 1248 MiB in 15 s) and 2.2 GiB in 20 s in a bare `gpty-core` harness. The reader thread now sends on
a queue bounded at 256 × 4 KiB = 1 MiB per pane and blocks while it is full, so the kernel's PTY
buffer fills and the child's `write` blocks in turn — the backpressure a terminal emulator has always
applied. Dropping chunks was never an option: these bytes carry ANSI state, not independent records.
Measured after: RSS flat at 216 MiB across 15 s of `yes` in the GUI, with the drain rate unchanged
(29.5k → 31.1k lines/s — the ceiling is the consumer, not the channel).

**Input no longer blocks the drain loop.** The task wrote user input and emulator replies straight to
the PTY master, so a child that stopped reading stdin filled the kernel's ~4 KiB input buffer and the
task blocked inside `write_all` — which stopped it draining PTY *output*, so the pane froze, and an
abort could not land either because abort only takes effect at an await point. Input now goes to a
per-PTY writer thread through an unbounded FIFO, which coalesces whatever is queued before each write
and logs a write error instead of returning it. Verified live: 64 KiB injected into a pane flooding
`yes` returned in 7 ms with output flowing before and after.

**Scrollback is committed off the terminal path.** `TermGrid::store_line` called `HistoryStore::append`
per output line while holding the grid mutex — the lock the UI thread renders under — so a flooding
pane held the UI up for ~30 µs per line and was itself capped at 33k lines/s (a `yes` pane moved
~1 MB/s), and the store had no byte cap at all. A pane now owns a `PaneHistory`: `push` queues the
line with no lock and no SQLite on the terminal path, and a per-pane writer thread commits batches —
512 rows, or 200 ms of quiet — then trims the store, bounded by rows (`history_lines`) and by text
bytes (1 KiB per retained row, minimum 1 MiB). Measured: the pane's ceiling went from ~1 MB/s to
31 MB/s of `yes` output with GUI RSS flat at 219 MiB. The cost is staleness — a search can miss the
last 200 ms — so the tail is flushed on a normal exit, and Settings → Terminal now carries a read-only
"On disk:" row sourced from SQLite's own accounting: the database plus its `-wal`/`-shm` siblings,
measured live as 61 111 896 = 56 938 496 + 32 768 + 4 140 632 exactly.

**Killing a pane kills its work.** `PtyHandle::drop` killed only the shell, and a shell's descendants
do not always follow it: the kernel's SIGHUP on session-leader exit reaches the *foreground* group, so
a background job under job control — what an interactive pane produces — or a process that ignores
SIGHUP is orphaned. The drop path now SIGKILLs the child's process group first (the child is a session
leader, so pgid == pid), then the child.

## The smaller repairs

**A divider drag is pixel-smooth.** It used to move in whole grid units (~17 px on a 1000 px pane),
and every motion event mutated the tile model and emitted `tiles_resized`, so the grid relayouted and
every terminal reflowed on each 1–3 px mouse step. A drag now previews in pixels and commits in units:
each motion moves the wrappers by the raw delta, touching neither the tile model nor `tiles_resized`,
and the release rounds the previewed travel to whole units and relayouts exactly once, with `MIN_TILE`
enforced mid-drag in pixels so the preview can never show a position the commit refuses.

**A paste is now bracketed, or guarded.** A paste went to the PTY verbatim: every newline submitted a
line, and any control byte in the clipboard was injected raw — a pasted `ESC[201~` closed the
application's own paste bracket, a `^C` interrupted. The grid now reports DECSET 2004, and
`TerminalPane.build_paste_payload` wraps the text in `ESC[200~`/`ESC[201~` when the child asked for
it. When it did not ask, C0 controls and DEL are dropped — escape sequences above all, and a bare CR,
which the PTY turns into Enter — while newlines and tabs survive.

**And the quieter fixes.** The code viewer read any absolute path with `get_as_text()`, so a layout path
or a typo could be a multi-GB file slurped whole on the GUI thread; reads are capped at 1 MiB with a
truncation notice, and non-regular paths are refused before `open`. The file tree asks before
`OS.shell_open`, because a downloaded `.desktop` file is *run* by the mime handler rather than
displayed. `log::warn!` records that were invisible in the GUI reach Godot's console through a bridge
at `InitStage::Core`; reasoning deltas render at most once per 75 ms per view; and every store loader
reads through typed accessors, so a wrongly typed value costs that value instead of raising mid-load
and letting the next save write the reduced state back over the file.

## GPL-3.0-or-later, with the plugin door open

gpty is now licensed **GPL-3.0-or-later**. `LICENSE` is the verbatim GPLv3 text, and
[LICENSE-EXCEPTIONS.md](https://github.com/godot-pty/gpty/blob/main/LICENSE-EXCEPTIONS.md) states the
section 7 additional permissions: plugins, pane types, extensions and adapters may be licensed under
any terms — Apache-2.0, MIT, proprietary — and configuration or data files carry no copyleft, so
user-authored files are the user's own and the shipped `godot/*.json` defaults are Apache-2.0. Both
permissions carry the as-is, no-warranty, no-vetting terms. The core stays copyleft: modified gpty
source is still conveyed under the GPLv3. SPDX cannot express an exception, so
`LICENSE-EXCEPTIONS.md` is the canonical statement; the crates and the AUR `PKGBUILD` declare
`GPL-3.0-or-later`, and CONTRIBUTING gains the inbound=outbound statement the GPLv3 lacks. There is a
single copyright holder, so no third-party consent was required. The release archives now carry
`LICENSE` and `LICENSE-EXCEPTIONS.md` next to the binaries (GPLv3 sections 4 and 6), and the docs site
renders the license text and the exceptions.

The bundles changed too: each platform job now builds the **CLI** into the archive beside the GUI
export — renamed `gpty-gui` on Linux and Windows, while macOS keeps the preset-owned `gPTY.app` — so
`gpty new-pane`, `pane-read` and `gpty mcp` no longer need a Rust toolchain, and every bundle ships a
real application icon and a `SHA256SUMS` asset. CI and the release export are pinned to
Godot 4.7.2, and the build fails fast when the export templates do not match the editor.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.4).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#054--2026-09-12).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
