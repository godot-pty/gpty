# Changelog

Log all notable changes to the project. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.4] — 2026-09-12

### Added

- **Visual Concept Graph.** Settings → Concepts → "Open Visual Editor" opens a full-window `GraphEdit` overlay that authors rules as chains: trigger → condition* → action (capture & route, or notify-only). A port holds one wire, so a rule can neither fork nor merge. `ConceptGraphModel` (pure, unit-tested) builds the canvas from the merged concepts and compiles it back — the compiled key set is closed (`entry_for_path`), so a node cannot smuggle a legacy `cmd` back in — writes a rule equal to its shipped default as *no* user entry (so defaults keep tracking updates), tombstones a deleted shipped rule exactly like the manual dialog, and keeps content-invalid rules as drafts with an error instead of compiling them. Layout lives in the `graph` sibling key of `user://concepts.json` (sanitized positions plus draft nodes), so `concepts` stays the single content store and a manual-dialog edit cannot drift. Verified with 23 model unit tests, 9 engine condition tests, 423/423 GUT and a live smoke against the real GUI + GDExtension (open → splice a condition through the connection handlers → save → only the edited rule written → engine readback; 4/4 edges rendered as connections, zero auto-layout overlaps); that pass caught two defects, a rebuild that removed GraphEdit's internal children (`connections_layer is missing`) and auto-layout spacing that let the action overlap a condition.
- **A rule's rank on the canvas is its precedence.** `ConceptGraphModel.rule_order` derives the order from the triggers' positions (top-to-bottom, then left-to-right, then by name) and `layout()` writes it as the graph block's `order` — rule names only, no content. `ConceptManager._merge_concepts` puts the named rules first, in that order, and everything the canvas does not name after them, so a newly shipped default can never quietly outrank an arrangement the user made; a store without an `order` key keeps the shipped merge order exactly (defaults first, then user entries in file order), so nothing changes for anyone who never opened the editor. Each trigger's title shows its rank (`1. Trigger - name`), refreshed on rebuild, on revalidate and *during* a drag, and the editor's "Fit" re-rows with `tidy_positions` instead of Godot's `arrange_nodes()`, which laid nodes out by connection shape and would have silently reshuffled precedence.
- **Concept conditions.** The concept vocabulary gains `conditions: [regex, …]` — ANDed with the trigger on the same line, capped at 8 × 1024 bytes; a malformed condition rejects the whole concept rather than being dropped, because dropping one would widen matching. `GptyTerminal.validate_regex()` exposes the engine's dialect so the editor cannot author a regex GDScript's PCRE2 accepts but the Rust engine silently discards.
- **`gpty state <value>` declares a pane's agent state.** A tier-2 `gpty_state` OSC cannot survive ConPTY — a sequence its VT engine does not implement never reaches the pane (measured: a DECSET 2004 from the same fixture arrives while every declaration fails) — so the declaration path is the CLI now: it reads the credentials a pane injects (`GPTY_EVENT_SOCKET`, `GPTY_TERMINAL_SESSION_ID`, `GPTY_EVENT_CAPABILITY`, the only credential a pane's child holds) and submits `gpty.state.declared` on the event socket, capability-gated instead of spoofable and display-only like the OSC. `seq` became optional for a producer born per declaration, the new event is allowlisted (`state` only, with an unknown value refused as -32602 before the session lookup), and it is deliberately not an MCP tool. Verified live through the pane-API smoke (`<cli> state needs-attention` → `paneStatus` reports that state at tier 1); it also runs in the Windows smoke job, where it is the only program-facing declaration path.
- **Bracketed paste.** The grid now reports DECSET 2004 (`TermGrid::bracketed_paste`, exposed as `is_bracketed_paste()`) and `TerminalPane.build_paste_payload` wraps a paste in `ESC[200~`/`ESC[201~` when the child asked for it, keeping the bytes untouched. When it did not, the guard runs the other way: C0 controls and DEL are dropped — escape sequences above all, and a bare CR, which the PTY turns into Enter — while newlines and tabs survive, because a multi-line paste into a plain shell is a normal thing to want. Verified live: `is_bracketed_paste()` follows a real child's own output, and `test_paste_payload.gd` drives the real Ctrl+Shift+V branch through a stub-FFI probe (9 cases).
- **Scrollback footprint, on screen.** Settings → Terminal carries a read-only "On disk:" row showing what scrollback costs, with the store's path as its tooltip, fed by a new `GptyTerminal.history_store_stats()` → `gpty_core::history::store_size_on_disk()` that sums the SQLite file and the `-wal`/`-shm` siblings beside it (measured live: 56 938 496 + 32 768 + 4 140 632 = 61 111 896 bytes). The row refreshes on `NOTIFICATION_VISIBILITY_CHANGED`, because the panel outlives a visit and scrollback keeps growing.
- **Core warnings reach Godot's console.** `diagnostics.rs` installs a `log` logger at `InitStage::Core` that forwards `warn`-and-above records whose target starts with `gpty` to `godot_warn!`/`godot_error!`; until now nothing installed a logger, so every core `log::warn!`/`log::error!` (a failed history append, a PTY read error, a poisoned lock, a refused capture) was dropped in the GUI and only the CLI saw them. Dependency targets (`alacritty_terminal`, `rusqlite`, `portable-pty`) and `info`/`debug` stay out, which is what keeps the console readable.
- **The code viewer and file tree are gated.** Reads go through a type check and a cap: `FileAccess.file_exists` is false for directories, `/dev/zero`, FIFOs and symlinks to FIFOs (and `get_size` is -1 for anything non-regular), so non-regular paths are refused before `open`, and the read is capped at `MAX_FILE_BYTES` (1 MiB) with a visible truncation notice and a hand-rolled UTF-8 cut, so a sequence torn by the cap is dropped instead of rendered as U+FFFD. The file tree asks for confirmation before `OS.shell_open`, showing the exact path, and refuses non-absolute and non-regular paths — only an absolute local path becomes the `file://` URI the sink constructs itself, so a downloaded `.desktop` file cannot be *run* by the mime handler.
- **Release bundles ship the CLI beside the GUI.** Each platform job now builds the CLI and the export job stages it into the bundle; the export is renamed `gpty-gui` (`gpty-gui.exe` on Windows; the macOS preset keeps `gPTY.app`) while the CLI owns the name `gpty`, so both are on PATH and auto-spawn finds a sibling named `gpty-gui` or `gpty-editor` — an extracted bundle starts its own GUI on demand, and a release build reaches its socket in ~0.4 s, inside the CLI's 5 s default timeout. The macOS CLI is lipo'd universal to match the app export, and a discovered candidate must be a private regular file. Every bundle also carries the app icon now (`godot/icon.png` for Linux and `res://icon.png`, `godot/icon.ico` for Windows, `.icns` on macOS) instead of Godot's default splash.

### Changed

- **gPTY is GPL-3.0-or-later, with section-7 exceptions for plugins and data.** `LICENSE` is the verbatim GPLv3 text and the new `LICENSE-EXCEPTIONS.md` states the additional permissions: plugins, pane types, extensions and adapters may be licensed under any terms (Apache-2.0, MIT, proprietary), and configuration or data files carry no copyleft — user-authored files are the user's own, and the shipped `godot/*.json` defaults are Apache-2.0 — with the as-is / no-warranty / no-vetting terms for both. The core stays copyleft. Every crate manifest and the AUR recipe declare `license = "GPL-3.0-or-later"` (SPDX cannot express the exception, so `LICENSE-EXCEPTIONS.md` is the canonical statement), the release archives carry `LICENSE` and `LICENSE-EXCEPTIONS.md` next to the binaries (GPLv3 sections 4 and 6), and the docs site renders both, with the Docs workflow rebuilding when either file changes. CONTRIBUTING gains the inbound=outbound statement the GPLv3 lacks.
- **The docs site publishes the security policy.** SECURITY.md is mirrored into `assets/repo` and rendered at `/docs/security/`, and the shortcode gained link rewrites for `[SECURITY.md]`/`[AGENTS.md]`, which every page carried as broken relative links before. The policy itself reads the supported version as `> 0.5`, replaces the Pre-x label with the rule that fixes land on `main` and ship in the next release (with a backport exception for severe issues), moves the technical-detail list (versions, attacker control, reproduction) to the private channel, retitles the public fallback issue "Security Request" with its no-details rule, and targets a first assessment in ~30 days.
- **Concept matching no longer multiplies with the concept library.** The per-concept loop paid each regex's own prologue on every line (~20 ns per concept), so a 128-concept library spent 2.7 µs on a line that matched nothing. `ConceptMatcher` now puts one combined `RegexSet` pass in front of the ordered loop, so the common case (nothing matches) never pays the per-concept multiplier and only a gate hit runs the loop that decides capture-vs-notify; conditions and precedence are unchanged, and `matcher_agrees_with_match_line_on_every_pair` pins the equivalence across condition-fails, disabled, notify and capture cases. On a flooded pane (1 KiB lines) the measured rate was 79.9 MB/s with no concepts, 79.7 with the shipped set and **5.8** at the parser's ceiling (128 concepts × 1024-byte trigger × 8 × 1024-byte conditions) before, 81.1 / 73.9 / **73.3** after (12.6× at the ceiling); 30-byte lines went from 8.6 to 44.9 MB/s with 128 typical triggers (5.2×), within ~10 % of no concepts at all. The engine also takes the concept read lock once per output batch instead of once per line, and a poisoned `RwLock` now follows the `Mutex` policy (skip the work, report the first occurrence) instead of panicking the pane's task. `crates/gpty-core/examples/concept_probe.rs` keeps the measurements.
- **Scrollback commits off the terminal path.** `TermGrid::store_line` called `HistoryStore::append` per output line while holding the grid mutex, so a flooding pane held the lock the UI renders under for ~30 µs per line and was itself capped at 33 k lines/s (a `yes` pane moved 1 MB/s), and the store had no byte cap — 10 000 rows of 16 KiB lines is 160 MB of SQLite and FTS index. A pane now owns a `PaneHistory`: `push` queues the line with no lock and no SQLite on the terminal path, and a per-pane writer thread commits batches (`FLUSH_ROWS` = 512, or 200 ms of quiet) and trims. Retention is bounded by rows (`history_lines`) and bytes (`RETAINED_BYTES_PER_ROW` = 1 KiB per retained row, min 1 MiB). Measured: the pane's ceiling went from ~1 MB/s to 31 MB/s of `yes` output (≈900 k lines/s) with GUI RSS flat at 219 MiB across 12 s of flood; the store alone commits 33 k rows/s per-line → 111 k rows/s in 512-row transactions (84 k with trimming — the FTS5 index write is the floor). Write-behind is visible only as staleness (a search can miss the last 200 ms of output), `TerminalPane._exit_tree` flushes the tail on a normal quit, and an exit that runs no teardown (`SIGKILL`) still loses whatever is queued.
- **Reasoning deltas are coalesced, and abandoned event subscriptions are released.** `_append_live_text`/`_refresh_turn_layout` now use `MarkdownView.set_markdown` — at most one re-parse per 75 ms per view — instead of `render_now`, which re-parsed the whole accumulated turn and every other turn for every token; a new `rendered` signal re-syncs fold heights once the coalesced text lands, and a settling turn still finalizes synchronously. On the event socket, `SUBSCRIPTION_IDLE` (120 s without an `eventsPoll`) releases the slot and its queued events on the next subscribe/emit, so the 64-slot cap cannot be exhausted by abandoned clients. The OMP translation boundary is a per-event field allowlist built field-by-field with caps instead of a rename-and-pass-through, so prompts, answers, tool arguments/results or a future extension field cannot ride along (unit-tested with a hostile payload; a live probe showed a `tool.finished` carrying `prompt`/`tool_args`/`answer` accepted with only the allowlisted `is_error` reaching the terminal's tier-1 state).
- **Dividers follow the pointer in pixels.** While a divider is dragged, the tiles on the line move their wrappers by the raw pixel delta — the far side grows, the near side shifts — with no tile mutation and no `tiles_resized` per motion, so nothing reflows until the release. The press snapshots the line's tiles, their committed offsets, one unit in pixels and the unit travel limits, so `MIN_TILE` and the grid edges are enforced mid-drag in pixels and the preview can never show a position the commit refuses; the release rounds the previewed travel to whole units, applies it to the tile model and relayouts once. The preview is absolute from the press (backtracking restores the layout), and an edge with no tile on its far side — the window border — no longer starts a phantom drag. Verified with 16 GUT drag tests plus a live run at 29 px/unit: a 40 px drag previewed the divider to 910 px (31.38 units, deliberately off a boundary) with the model untouched, then committed the span 30→31 at 899 px, an 11 px snap within half a unit.
- **Windows is a tested platform now, not an inferred one.** The GDScript suite runs there: every test that spawns a pane takes its program from `SettingsManager.default_shell_command()`, and the two tests that need exact bytes from a *child* build their command line through the new `godot/tests/helpers/shell_fixtures.gd` (POSIX `printf '%b'` with octal escapes, Windows PowerShell `[Console]::Write` with `[char]N`). The new `windows-smoke` job (windows-latest) boots the GUI headless and drives the CLI against it over named pipes using `scripts/smoke_pane_api.py` — one harness for every platform, since only the transport differs — covering the control-pipe round trip, the named-pipe event listener (`subscribe`/`eventsPoll`, spawn and killed events), the pane lifecycle, inject → pane-wait → pane-read, scrollback, broadcast, `pane-run` exit codes and kill-pane. The `@gpty/omp-events` extension's named-pipe path is tested (`\\.\pipe\` accepted from the path alone) and its real forwarder is observed live inside a pane, so one assertion spans env injection → transport → capability check → translation → GDScript drain → agent state. `scripts/gut-check` also learned to accept a pending-only run while failing a `[Risky]` test (one that ran without asserting), so a Windows-only gap cannot hide a suite that stopped asserting; one test still pends there with its reason in the source, because the fake CLI adapter is a POSIX shell script.
- **Peer credentials are checked wherever the platform has an API, and every arm fails closed.** The BSDs share macOS's `getpeereid`, illumos/Solaris use `getpeerucred` + `ucred_geteuid`, and Windows — which had no check at all — identifies the client with `GetNamedPipeClientProcessId`, reads that process's token user SID (`TOKEN_USER` via `GetTokenInformation`) and compares it with gPTY's own through `EqualSid`; a lookup error fails closed and the accept loop rejects a mismatched pipe client before spawning its handler. The BSD arm is compiled in CI (`x86_64-unknown-freebsd` is now a check), the illumos and NetBSD arms are compile-probed against real libc targets, the same-UID acceptance path has an explicit test instead of being implied by the round-trip tests, and SECURITY.md lists the three platforms that still answer "match" (AIX, Haiku, QNX — file permissions remain their only gate).
- **The control socket prefers a private state directory over the shared `/tmp` fallback.** The chain now tries the per-user runtime directories as before (`$XDG_RUNTIME_DIR`, `/run/user/<uid>` on Linux, `$TMPDIR` on macOS), then a private `$XDG_STATE_HOME/gpty` or `$HOME/.local/state/gpty` — created 0700, or tightened from a lax umask when it is already ours — and only then `/tmp/gpty-<uid>.sock`, whose predictable path in a world-writable directory is a squatting vector (denial of service only: the socket's owner and mode are validated before use). `fallback_socket_path()` is the one place that choice lives, shared by Linux, macOS and the other Unix targets, and the event socket derives from it. The fallback's pre-creation TOCTOU is closed with it: only a stale *socket* owned by this user is removed, anything else fails the bind closed and is left exactly as found.
- **Store files are owner-only under an unguessable name.** The temp file every `user://` store writes through was built at a predictable `<store>.tmp`, and `FileAccess.open(..., WRITE)` follows a symlink — measured: a link planted at that name turned a victim file into the store's JSON. The temp name is now 64 random bits (`Crypto.generate_random_bytes`), which cannot be pre-planted, and the file is created 0600 before the rename (the rename also replaces the target itself instead of writing through a link at the store path); the non-atomic fallback sets the mode too. The scrollback database and its `-wal`/`-shm` siblings — created with the process umask, measured 0644 — are chmodded to 0600 from `HistoryStore::open`, which also tightens a store written before this change.
- **The release supply chain is pinned and verifiable.** The release publishes a `SHA256SUMS` asset generated with flat names so a line matches the published file, with verification steps in the release body for Linux, macOS and Windows, and `fail_on_unmatched_files` makes a missing artifact fail the job instead of shipping an incomplete release. Every release asset carries a build-provenance attestation (`gh attestation verify <asset> --repo godot-pty/gpty`); every third-party action across the three workflows is pinned to a commit SHA, including the two moving refs `dtolnay/rust-toolchain@stable` and `rustsec/audit-check@v2`; and CI's Godot editor/templates and Hugo downloads are checksum-verified, so a swapped artifact fails the job. CI and the release export are pinned to Godot 4.7.2 (the engine the local suite was already exercised against), `scripts/build` refuses to export when the export templates do not match the editor, and `docs/setup.sh` validates and JSON-quotes remote release metadata so a malformed API response is skipped with a warning instead of injecting dropdown entries or a `javascript:` href.
- **The test gates read the shipped code, not a copy of it.** The GUT gate is now `scripts/gut-check`, which owns the GUT command (so run and guard cannot drift) and judges the output instead of the exit code: godot parse/script-error lines fail it, the Run Summary must be present and end in `All tests passed!`, the reported script count must equal the `test_*.gd` files the gdirs hold, and every collected script must contribute at least one test. It reproduced a parse error that made GUT break into the debugger, run 4 of 40 scripts, print no Run Summary and exit 0 in 1.3 s — the old step printed PASS off that exit code. The three named seams now have tests that read both sides instead of reimplementing one: MCP tool → IPC method → dispatch, pane targeting by id and legacy label (driven against a real `Workspace`), and `paneRead`'s "screen plus scrollback" claim, which now fills a pane with 120 lines (≈5 screens) and requires the oldest marker as well as the newest.

### Fixed

- **A pane's output queue is bounded.** `pty_rx` was an unbounded channel, so a pane whose output outran the terminal task grew the process: measured ~70 MiB/s added to the GUI (194 → 1248 MiB in 15 s) and ~110 MiB/s in a bare `gpty-core` harness (2.2 GiB after 20 s). `pty::OUTPUT_QUEUE_CHUNKS` (256 × 4 KiB = 1 MiB per pane) applies backpressure — a full queue stops the reads, the kernel PTY buffer fills and the child's `write` blocks — and dropping chunks was never an option because the bytes carry ANSI state. After: GUI RSS flat at 216 MiB across 15 s of `yes` (delta 0), the harness flat at 30 MiB, the drain rate unchanged (29.5 k → 31.1 k lines/s), and the pane recovers — a 300 000-line `seq` finished, the prompt returned, `kill-pane` reaped the child.
- **Input no longer blocks the drain loop.** Input and emulator replies went straight to the PTY master, so a child that stopped reading stdin (a flood, a `tail -f`) filled the kernel's ~4 KiB input buffer and blocked the task inside `write_all` — which stopped it draining PTY *output*, so the pane froze and an abort could not land either. Input now goes to a per-PTY writer thread through an unbounded FIFO, which coalesces whatever is queued before each write and logs a write error instead of returning it. Verified live: 64 KiB into a pane flooding `yes` returned in 7 ms with the pane's output still flowing, where the old path froze it.
- **Killing a pane kills its process group.** `PtyHandle::drop` killed only the shell, and the kernel's SIGHUP on session-leader exit reaches only the *foreground* group, so a background job under job control or a process that ignores SIGHUP was orphaned until its own writes failed. The drop path now SIGKILLs the child's process group first (the child is a session leader, so pgid == pid, and the group is not ours), pinned by `dropping_a_pane_kills_its_process_group`, which starts a SIGHUP-immune grandchild and probes it until ESRCH.
- **A bare program name is judged by the file it resolves to.** `validate_executable` never saw a PATH-resolved name, so a saved tile that also set `PATH` chose which file the name ran. `pty::validate_program` resolves a bare name through the `PATH` the child will actually inherit (the tile's own `shell_env` value when set, otherwise the user's) and holds the first match to the existing rule — regular file, not group/other-writable, owner check, no writable ancestor — and it runs before anything is spawned, so it covers every pane. A name that resolves nowhere is passed through, so the spawn fails exactly as it always did, and an empty `PATH` entry (which `execvp` reads as the working directory) is refused instead of handing `validate_executable` a relative path it would treat as another bare name.
- **Store corruption costs one value, not the rest.** A store is user-editable and can be half-written, and a value of the wrong type *raised* inside the loader (`int([1,2])`, an Array assigned to an `int`, `.get()` on a String, a String passed to a typed parameter), which aborted it at that line: every key after the bad one was dropped, and the next save wrote the reduced state back over the file, making the loss permanent. Every loader now reads through typed accessors on `BasePersistenceManager` (`_as_int`/`_as_float`/`_as_bool`/`_as_string`/`_as_array`/`_as_dict`) across `settings.json`, `workspaces.json` and `profiles.json`. Two defects fell out of writing the tests: an empty workspace list made `clampi(active, 0, size - 1)` a (0, -1) range — on exactly the store a fresh install has — and a workspace whose `layout` is not a list took the whole set down at the typed parameter. Verified live by booting with hand-corrupted stores and confirming the trailing keys survive and the save on quit keeps them.
- **Platform shell defaults.** The first-run shell default was `/bin/bash` everywhere, which `validate_executable` refuses on Windows (not absolute there), so **every pane of a fresh Windows install failed to start**; the Terminal tab's "Reset tab to defaults", the shell field and its placeholder and `TerminalPane`'s shell export hard-coded it too, so a reset left every later pane with no terminal. All of them now use `SettingsManager.default_shell_command()` (`%COMSPEC%`, falling back to `cmd.exe`), and `PaneTypes.shell_run_args()` picks `/c` for the cmd family and `-c` otherwise instead of always passing `-c`, which `cmd.exe` rejects.
- **A pane's exit is reported even when the pty stays open.** The task only learned of an exit from the pty read side closing, and ConPTY keeps that pipe open after the child exits, so the Windows smoke's `pane-run` step sat at `running: true, exit_code: null` for 15 s. The task now also polls the child every 200 ms and, once it has exited, drains until the pty has been silent for 500 ms before ending — output re-arms the window, so ending early cannot truncate what the pty still held. The case is reachable on Linux too (a SIGHUP-immune descendant holding the pty), which is what the new test uses: it fails after a 10 s timeout without the child poll, and passes in 0.63 s with it.
- **`daemon stop` answers, and quitting no longer crashes.** The handler called `process::exit(0)` before the reply was written, so the CLI and the MCP tool reported `invalid response: empty response` and exit 1; it now answers `{"shutting_down": true}` and quits through the scene tree, which also runs the teardown `process::exit` skipped — verified 3/3 with `settings.json` and `workspaces.json` written and the pane's last output line in `history.db`. The crash behind it was found under gdb: Godot unloads the GDExtension at exit while this extension owns threads that live in it (tokio workers, one PTY reader and one history writer per pane), and a worker still executing in the unmapped mapping faulted on a freed code page. `pin_library()` now pins the module at `InitStage::Core` — `RTLD_NODELETE` on Unix, `GetModuleHandleExW` with `GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS` on Windows, which carried the same class of risk at exit.
- **`gpty mcp` bounds its input.** `lines()` buffered a request of any length; a line over 65536 bytes is now refused with -32600 "Request exceeds 65536 bytes", the remainder of that line is discarded so the next request starts at a message boundary, and the stream keeps working.
- **Pane activation and the IPC vocabulary.** `focusPane` called `grab_focus()` unconditionally, so focusing a read-only pane raised an engine error and activated nothing while still answering `success: true`; the activation rule (record `last_body` in the body's own workspace, take keyboard focus for a terminal, release it otherwise) is now `Workspace.activate_pane()`, shared by the click path, the sidebar row and IPC. The same seam test found `paneWait` registered but absent from the dispatcher (it is handled by the workspace's per-frame loop, which the test now models) and dead GDScript arms for `version`/`shutdown`, which the Rust server answers locally.
- **The code viewer's comment toggle.** `CodeEdit.add_comment_string` does not exist on Godot 4, so the call raised a script error that aborted `load_file` before `_refresh_view()` for `.rs/.gd/.py/.c` files, leaving the pane on the previous file's view; it is `add_comment_delimiter` now, with a regression assertion on the view toggle.
- **A pane id stays unique when the pane settings rename it.** Every pane enters a workspace through `_attach_pane_into`, which runs `_ensure_unique_attachment_id`, but the *pane settings* apply runs after that: typing an id another pane already had (or restoring it from a file) left two panes sharing a public id, and id-targeted IPC then resolved to whichever the search hit first. The panel now announces `settings_applied(body)` and the workspace re-checks there, redrawing the pane list because it shows the id.
- **The v0.5.3 macOS bundle's metadata.** `CFBundleShortVersionString`/`CFBundleVersion` reported the stale `config/version` (0.1.0) rather than the release, and the category was Godot's `Games` default; the release workflow now stamps `config/version` from the tag before importing the project, and `application/app_category` is `Utilities` (`public.app-category.utilities`).

[0.5.4]: https://github.com/godot-pty/gpty/compare/v0.5.3...v0.5.4

## [0.5.3] — 2026-09-10

### Added

- `single_line` concepts mean **notify-only**: a trigger match is published on the event socket (`{type: concept, event: matched, mode: single_line, name, source}`) and nothing else happens — no capture, no routing, no output taken from the pane. The Settings → Concepts editor offers the mode again, and hides the target and stop-condition fields for it. A missing or unknown `capture_mode` still captures. Metadata only: the matched line is never published.
- **Terminal mouse reporting.** A pane forwards clicks, drags and wheel events to a child that enabled mouse tracking (`DECSET 1000`/`1002`/`1003`, encoded as SGR when `1006` is on and in the legacy X10 form otherwise, from the same cell mapping selection uses), so `nvim`'s mouse mode, `lazygit` and herdr's pop-ups work inside a pane instead of only seeing the pane's own selection. Only the events the enabled mode covers are forwarded — with tracking off nothing changes — and holding `Shift` keeps text selection reachable while an app has grabbed the mouse.

### Changed

- The pane titlebar on/off toggle moved from Settings → System to Settings → Appearance, next to the Title bar colour and the other chrome colours it belongs with. Nothing was missing — the setting and its checkbox existed, but a user looking for a titlebar setting looks at the pane or the chrome colours, not at System.
- The shipped recommended layout is now named **Agent Workspace** (it opens Terminal + Inspector + Reasoning). v0.5.0's notes promised that rename; the data file still said "OMP Workspace", so the de-OMP repositioning never actually reached a fresh install.
- **Rendering no longer costs the frame under load.** Text is drawn as one `draw_string` per run of cells that share font, color and underline state instead of one per cell (a full-screen repaint measured ~20 % cheaper), and a pane whose own grid fetch plus repaint exceeds a 4 ms per-frame budget looks at the grid less often — geometrically, down to ~10 Hz — instead of rebuilding its canvas every frame. That is what a flooding PTY (`cat /dev/urandom`, `yes`) used to do to the whole UI thread; a pane that keeps up is never throttled, and neither is a view you are scrolling yourself.
- Idle panes no longer repaint at all (the repaint is gated on the grid generation) and the per-frame per-pane FFI polls and focus walk moved off the frame.
- The pane search opens with `Ctrl+Shift+F`; plain `Ctrl+F` reaches the PTY again, as the docs always claimed (vim/less page-forward).

### Fixed

- **Pane edges could not be dragged.** Three defects stacked up: the resize handler ran on the wrapper's `gui_input` while the pane body fills the wrapper and consumes the mouse (so the 4 px edge test was unreachable — the cursor only flashed because the body's default arrow overwrote it); the drag passed the delta since the *previous* motion event to a routine that recomputes from the press (mouse motion arrives in 1-3 px steps that round to zero cells, so a slow drag moved nothing); and a partially applied move broke the neighbour lookup, which reverted the pane being dragged and left the grid not adding up. Each edge now has a 6 px strip that owns the resize cursor and starts the drag, and the move is recomputed from the press on every event, so the divider follows the pointer live and stops at the minimum pane size.
- **The layout grid is finer, and its unit has one definition.** A pane's geometry is measured in abstract grid units, and one unit *is* the drag's step: at 12 units a divider jumped ~83 px per cell, which is what made resizing feel jarring; it is 60 now, near a tmux character cell. The unit also lived in two places — `PaneTypes` owns it and `workspace.gd`, the sanitizer and the drag math read that one constant. A copy that drifted (the layout dividing by 12 while tiles were in 60) sized every restored pane several times the grid and drew it outside the visible area, so this is now a single definition with a test that asserts restored panes' on-screen rects, not just their spans.
- **A divider moves every pane on the far side of it.** Neighbours were matched by *identical* extents, which is only true in an evenly split layout: in the shipped Agent Workspace layout (one full-height pane beside two stacked ones) the tall pane's edge had no neighbour at all, so dragging it did nothing — while grabbing the neighbouring panes' edge happened to work, which is why resizing felt random. A divider is treated as a *line* now: every tile whose edge lies on it moves, on both sides and across its full length, so the result no longer depends on which part of it the user happened to grab. A single pane's edges go inert (arrow cursor, no drag) — there is no divider to move.
- **Saved layouts keep their shares across the finer grid.** A layout written before the change is in 12 units; the payload states its unit, and when it does not, the unit is inferred from the tiling (a layout always fills its grid). Either way the geometry is scaled to the current grid on restore — without that, a restored half-width pane would have come back one fifth of the screen.
- Window titlebar controls used the wrong glyphs — maximize showed a keypad, restore a phone, and the window-mode picker a folder. They now render arrows-out / arrows-in / monitor (codepoints verified against the bundled font).
- **Captures survive their pane.** Closing, swapping or resetting a pane mid-capture, or letting the child exit, used to drop the buffered output (the terminal task was aborted past its finalize path, and nothing polls a dead pane's queue); the capture is now finalized and routed like any other. A notify-only concept can also no longer sit in front of a capture concept and starve it, and the shell's post-SIGWINCH repaint is no longer buffered into an active capture (where it appeared as a duplicated prompt).
- `pane-status`/`pane-run` report the exit code even when the child closes its pty a moment before it becomes reapable, instead of reporting nothing for a command that did exit.
- The Inspector's OMP session serves a turn on a fresh child when the previous one's pipes are already closed (the liveness probe has the same window as the exit-code race above), instead of failing a turn nothing ever received.
- A `cli` adapter that exits non-zero reports what it wrote to **stderr**. The drain is a separate task, so a summary taken the instant the child exits could come back empty and lose the adapter's own account of the failure; the exit path now gives the drain a bounded moment to reach EOF first.
- The position-swap popup resolves its targets when a row is clicked, so a pane killed while the popup is open no longer swaps the wrong pair or indexes past the end.
- Scrollback rows belonging to panes that no longer exist are reclaimed; the store stops growing with every pane id the workspace ever had.
- Search: the first `Enter` advances past the matches already on screen, and scrollback search accepts what a user actually types (`main.rs`, `error: x`) instead of failing as a raw FTS5 query.
- Keyboard focus moves to a surviving pane when the active one closes, instead of typing reaching nothing until the user clicks another pane.
- Settings are written through a sibling temp file and renamed into place, so a failed write can no longer truncate the store; an unsupported max-FPS value is shown instead of deselecting the control.
- Attachment ids stay unique when panes are attached, and disabling every concept takes effect immediately.
- The PTY reader and writer are opened before the child is spawned (a failure no longer leaves an unreachable shell), the shell is reaped if the reader thread cannot start, and emulator replies are written with the grid lock released so a child that stops reading cannot stall the pane's renderer.
- Scrollback persistence failures are reported instead of silently dropped.
- Input: numpad keys send their characters unless the app enabled keypad mode; modified `~`-terminated keys emit the correct CSI form; key auto-repeat no longer reaches the paste and search chords twice; a stored grid size is applied only before a tile is laid out.
- The cursor hides when the application hides it and follows the viewport when scrolling back.
- Inspector reliability: a turn's output no longer leaks into the next turn; dropped events are reported instead of silently truncating the answer; an untouched adapter argv is not re-split; adapter frames are capped while reading; the adapter's stderr is drained so it cannot deadlock; the OMP child is re-spawned rather than written into.
- IPC: the Windows event pipe sets the first-instance flag only for the first instance; a request without an id is treated as a notification instead of id 0.
- MCP `pane-*`/`concept-*` tools resolve to their IPC methods again, and `pane-read` returns scrollback as documented rather than only the viewport.

### Security

- **Workspace Trust shows what it will run.** The dialog named a category — "a different program, pass extra arguments, or set a different environment" — without naming the values, so approving it was a guess. It now lists the program, the argv, and each `environment:` entry, escaped and capped (the content comes from the file, not from us). `layoutLoad` over the control socket refuses an untrusted profile outright, since a CLI or MCP caller cannot answer a dialog.

- **Concept definitions can no longer execute commands.** A concept is data: a regex trigger, a stop condition, and a routing target. Until now it could also carry a command template that was written into a target pane's PTY — reachable from terminal output (any program that printed a matching line) and from a Ctrl+click on a matching line, both with no authentication, no consent prompt, and no notice. A third-party `concepts.json` was therefore arbitrary code execution with an attacker-chosen trigger, aimed at whatever pane matched, repeatable and silent; the click path shipped in v0.5.2. Removed: `command_template`, `substitute_template`, `shell_quote`, `matching_commands`, the engine's event-injection branch and the pub-sub channel that existed only to carry it, `match_concepts_on_line`, the Ctrl+click handler, and the concept label plumbing (`TerminalConfig.labels`, `labels_json`, `_concept_labels`). Legacy `cmd` keys in a user file are ignored on parse and stripped on save; the Settings → Concepts dialog no longer collects one. See [SECURITY.md](SECURITY.md) for the threat model behind the change.
- **Workspace Trust now covers everything that executes in a restored pane.** The gate compared only the legacy `shell` key, while restore consumed `command` > `shell` and passed `shell_args` and `shell_env` through untouched. A downloaded profile could therefore spawn `/bin/bash -c "curl … | sh"` (argv) or add a `command` override with no prompt at all — the argv half was the live one. The env half turned out to be unreachable: `_restore_into` applies tile settings before `apply_to_terminal`, which overwrites `shell_env` with the user's global, so a restored tile's env never reaches a child. That ordering also silently discards a user's own per-pane env on every restore; it is tracked with the v0.5.5 env model, where it must be fixed (fixing it alone would hand file-supplied env back to the attacker). `PaneTypes.tile_spawns_untrusted` checks program, argv, and environment against the user's defaults, and the workspace-restore path uses the same predicate.
- **Startup-evaluation environment variables are refused from configuration.** `PROMPT_COMMAND`, `BASH_ENV`, `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, `PERL5OPT`, `PERL5LIB`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`, `LESSOPEN`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, and `PAGER` are now blocked at the spawn choke point alongside the dynamic-loader keys: a shell or the next tool runs what they contain, so a layout carrying one could otherwise get code execution without naming a command. (The restored-tile path turned out to be unreachable — see the Workspace Trust entry above — but these keys still arrive through the user's own global `shell_env`, and this list is the floor the v0.5.5 env model builds on.) Users can still set them from inside a shell.
- **The Inspector's child process no longer inherits workspace-control credentials.** The OMP and adapter children were spawned with the GUI's full environment, including `GPTY_SECRET`/`GPTY_SOCKET` (and, for a GUI started inside a pane, that pane's event capability). Both backends now strip `gpty_core::pty::STRIPPED_INHERITED_ENV_KEYS`.
- **Grid geometry from saved layouts is bounded.** `start_shell`/`resize_grid` clamped dimensions only from below and `sanitize_tile` never bounded a stored `rows`/`cols`, so a crafted tile allocated a 10¹²-cell grid at spawn. Both boundaries clamp at 500 × 2000.
- **Search results are capped.** A one-character pattern over 100 000 scrollback lines materialised every match on each keystroke and re-walked them every frame; the grid search now stops at 10 000.
- **MCP `tools/call` is restricted to advertised tools.** Any name was mapped to an IPC method, reaching methods that were never published as tools (including `shutdown`).
- **CI runs least-privilege.** `ci.yml` declares `permissions: contents: read` instead of inheriting the repository default token scope, which was handed to a third-party audit action.
- Added [SECURITY.md](SECURITY.md): threat model, reporting process, hardening that must not be weakened, and known limitations.
- **The Inspector's prompt cannot be escaped by its own content.** Untrusted capture is wrapped in a fence one backtick longer than the longest run inside it (capped) and `concept`/`pane` metadata is flattened to a single line, so a capture that prints ``` can no longer land as instructions.
- **Restored programs are validated beyond their own mode.** An absolute `command`/`shell` from a layout or profile must be a regular file owned by this user (or root), not group/other-writable, and its parent chain must not be shared-writable without the sticky bit — a downloaded profile can no longer run a binary another user could have replaced. The Inspector's adapter argv is held to the same rule.
- **Control credentials are refused from untrusted pane environments** (`GPTY_SECRET`/`GPTY_SOCKET` alongside the pane-marker and event-channel keys), and the control socket compares its secret without short-circuiting.
- **An unterminated OSC sequence is force-closed at 64 KiB.** vte's `std` build keeps OSC bytes in an unbounded buffer, so a program that emitted `ESC ]` without a terminator grew the parser's memory and left it stuck inside the string, swallowing every later line.

[0.5.3]: https://github.com/godot-pty/gpty/compare/v0.5.2...v0.5.3

## [0.5.2] — 2026-09-09

### Added

- Agent-state detection — a display-only `AgentState` (idle/working/needs-attention/completed/failed) per terminal with tiered detection: Tier 1 accepts capability-authenticated events (authoritative: `agent.started` → working, `agent.settled` → completed, tool errors → needs-attention, session end → idle); Tier 2 accepts the published `gpty_state=<value>` OSC declaration (whitelisted, single-shot, rate-limited, alt-screen/capture-replay/resize suppressed); Tier 3 adds conservative failure regex patterns with 60 s TTL decay and non-zero shell exits. The state and its detection tier surface through `pane-status` (`agent_state`, `agent_state_tier`).
- Generic event vocabulary — the event socket translates the OMP extension's wire names to adapter-neutral names at the trust boundary (`session.bound`, `agent.started`, `agent.settled`, `turn.started`, `turn.finished`, `tool.call`, `tool.finished`, `thinking.delta`); Reasoning and Tier 1 agent-state detection consume the generic contract.
- Windows event listener — the OMP event socket now serves on Windows as a named pipe (`\\.\pipe\gpty-events`) with per-PTY `GPTY_EVENT_*` injection on every platform; capability entropy comes from `getrandom` instead of `/dev/urandom`. The shipped extension still needs a named-pipe transport to use it there (ecosystem follow-up), but Reasoning is no longer fail-closed at the gPTY layer.
- CLI backend for Inspector — a `cli` backend beside `mock`/`omp`: runs a configured adapter command (argv, never shell-evaluated) as a subprocess NDJSON bridge — one JSON request line per prompt in, `thinking`/`delta`/`done`/`error`/`status` frames out. Cancelling kills the child (`kill_on_drop`, no orphans); the next prompt respawns. Inspector pane settings gain a Command row; the command persists in the layout state (sanitized like shell args).
- Titlebar agent-state badges — a Phosphor badge on each terminal titlebar mirrors the agent state: spinner (Working), check (Completed), warning (Failed), pulsing amber (NeedsAttention); hidden while Idle. Display only.
- Settings panel polish — per-tab "Reset tab to defaults" buttons (full-width, centered) replace the all-tabs reset; the color scheme row gains a reset button; every UI color gains an individual reset; Appearance color pickers gain OK/Cancel (Cancel restores the pre-open color); the Edit/Add Concept dialog opens at 90% of the settings menu width.

### Changed

- UI chrome colors (wrapper background/border, pane titlebars, sidebar, window titlebar) now live-apply to existing panes when changed — no app restart required.
- Color row labels share a fixed-width column so all color pickers align.
- The settings panel is wider and its tab font slightly smaller so all six tabs always fit without clipping into the overflow dropdown.

### Fixed

- Pane settings popup could render but ignore every click: Godot 4 GUI input picking uses reverse tree order and ignores `z_index`, so later-added workspace grids ate the popup's input. Overlays now move to the end of the tree when opened; the same fix covers the global settings panel and command palette. The palette also had its first toggle inverted (created visible, first press hid it).
- Pane settings popup stayed open over a killed/swapped pane and every interaction then errored on the freed body. The popup now closes on kill and type-swap and self-closes whenever its target is torn down.
- Restarted terminals showed a growing pile of old prompt lines ("as if Enter was pressed"): the plain-text parser committed a history row on every bare carriage return, and shells reprint the prompt on each resize. Bare CR no longer commits, and scrollback restore collapses runs of identical rows.

[0.5.2]: https://github.com/godot-pty/gpty/compare/v0.5.1...v0.5.2


## [0.5.1] — 2026-09-09

### Added

- Persistent scrollback — the SQLite+FTS5 history store is wired into pane lifecycle, keyed by stable `attachment_id` (schema v2; pre-v2 rows dropped as unrecoverable). The newest `history_lines` rows are restored into each pane's scrollback on restart and back `pane-read` across restarts.
- `history_lines` setting — caps persisted scrollback per pane (default 10 000, clamped 100–100 000) in Settings → Terminal.
- History search — the terminal search bar gains a Live/History scope toggle; History mode runs FTS5 queries against the pane's persisted scrollback and lists matching lines (click copies to clipboard).
- Workspaces — named pane sets (up to 8) with keep-alive panes: switching hides/shows grids instead of killing PTYs, so background commands keep running. Add/switch/close/rename via the sidebar's Workspaces section (`Ctrl+PageUp`/`Ctrl+PageDown` to switch); saved to `user://workspaces.json`, with one-shot migration of the legacy `layout.json` (replaces the `LayoutManager` autoload). Concept captures and agent events keep routing from hidden workspaces.
- Sidebar polish — content margins (right ≈ scrollbar width), measured section heights that never truncate rows, icon+text action buttons (Settings/Reset/Search), and active-row accents across the workspaces, profiles, and panes sections.
- Profile rename — double-click a user profile in the sidebar to rename it inline (persisted, dedupe-suffixed like profile creation).
- Live pane-API smoke — `scripts/smoke-pane-api` boots the GUI headless with sandboxed user data and drives new-pane, pane-status, inject, pane-wait, pane-read, broadcast, pane-run (exit code), and kill-pane end-to-end, plus the event socket's `subscribe`/`eventsPoll` fan-out; wired into `ci-check` and the CI `gut-tests` job.

### Changed

- History retention trims the oldest rows beyond `history_lines` amortized over every 100 committed lines.
- `start_shell` no longer attaches a history store keyed by the per-node `id` counter (rows collided across panes and orphaned across restarts).
- `pane-run` executes commands through the configured shell (`<shell> -c <command>`) — compound commands (`&&`, pipes, globs) now work; the command is passed as a sanitized argument (`shell_args`), never as the program itself. Empty commands are rejected.
- Clicking any pane makes it the active pane — the status bar and sidebar accent follow. Only terminals take keyboard focus; read-only panes (Reasoning, code viewer, file tree) swallow keys, so typing no longer reaches a terminal you just left.
- New workspaces start as a blank slate instead of auto-spawning a terminal.

### Fixed

- Pane API unreachable: `pane-read`, `pane-status`, `pane-run`, `pane-wait`, and `broadcast` were never registered on the GUI IPC server, so every CLI call returned `Unknown method`.
- Targeted pane API calls always failed with "not found": `paneRead`/`paneStatus`/`paneWait` guarded on `has_method("_terminal")`, but `_terminal` is a property, not a method. Guards now check `is TerminalPane`.
- Toasts rendered half-hidden under the status bar — they now float above it.
- The docs site could bake Hugo's own README as the project overview — the deploy now extracts only the `hugo` binary and smoke-checks the baked overview.

[0.5.1]: https://github.com/godot-pty/gpty/compare/v0.5.0...v0.5.1

## [0.5.0] — 2026-09-03

### Added

- ADE repositioning — gpty is now positioned as a graphical Agent Development Environment: a PTY foundation with a public, agent-facing API. README, docs site, and CLI copy updated; the shipped "OMP Workspace" profile is now "Agent Workspace" (attachment ids unchanged).
- Ecosystem presets — built-in profiles for herdr, lazygit, nvim, claude, and OMP, backed by per-tile `command` support in profile restore (every command routed through `sanitize_shell`).
- Pane env markers — `GPTY_ENV=1` and `GPTY_PANE_ID` injected as trusted runtime vars at spawn (blocked from untrusted env), so agents inside a pane can prove where they are.
- Stable public pane IDs — every pane gets a persisted `attachment_id` (auto-generated when absent); `new-pane` returns it and `list-panes` reports `id` plus the display `label`. Targeting accepts either.
- Pane API — `pane-read` (plain-text screen plus scrollback), `pane-status` (pid, running, exit code, idle time; no argument lists every pane), `pane-run` (spawn a command), and `pane-wait` (waitForOutput: server-held wait on a Rust `regex` scan of recent output, up to 60 s).
- Event subscriptions — `subscribe` / `eventsPoll` on the event socket for concept matches and pane spawn/kill, with bounded per-subscriber queues.
- Broadcast and pane tags — panes carry sanitized tags; `broadcast` injects text into every tagged terminal pane. MCP tools grow from 14 to 19.
- Agent skill — `skills/gpty/SKILL.md` (shipped with the CLI via `gpty --skill`) teaches coding agents the full control surface, guarded by `GPTY_ENV=1`.
- In-app update checker — startup GitHub-release check with a `check_updates` setting; notify-only and silent on failure.
- About tab — Settings shows the live app version, the pinned IPC protocol version, and the repo URL; the status bar shows the version as well.

### Changed

- The IPC `version` response is sourced from the crate (`CARGO_PKG_VERSION`) instead of a hardcoded literal.
- The palette command list lives in one place (`PaneTypes.build_palette_commands()`).
- Remote `tag_name` values are validated as semver before any display.
- Docs baseURL points at the current org; origin-story page and re-sequenced overview added.

### Fixed

- OMP `rpc_chunk` base64 decoding hardened (`as_chunks` handling).
- README build instructions corrected (`cargo build -p gpty`).
- MCP tool enumeration in the agent guide matches the shipped tools.

[0.5.0]: https://github.com/godot-pty/gpty/compare/v0.4.0...v0.5.0

## [0.4.0] — 2026-08-19

### Added

- Inspector pane — private, tool-free, iterative OMP Q&A via a session-owned `GptyAi` (`session_open` / `session_prompt` / `session_poll` / `session_cancel` / `session_close`). It does not attach to a terminal-hosted OMP TUI. Set pane `backend` to `omp` (optional `GPTY_OMP`).
- Reasoning pane — passive projection of documented OMP reasoning from one terminal, selected by `source_attachment_id`. Never starts jobs or accepts concept captures.
- OMP event channel — second local socket (`gpty-events.sock`) accepting only `ompEvent`, authenticated with a per-PTY capability injected at spawn. Shipped `@gpty/omp-events` extension is dormant unless all four `GPTY_EVENT_*` variables are present.
- Shipped "OMP Workspace" profile (Terminal + Inspector + Reasoning). Built-in profiles are not written to the user store and cannot be deleted from the sidebar.
- Stable pane `attachment_id` for companion links across save/restore (not ephemeral labels like `T1`).
- Safe Markdown rendering — CommonMark/GFM is converted to sanitized Godot BBCode in Rust, Inspector/Reasoning streams are render-debounced, and Markdown files in code-viewer panes support rendered/source toggling.

### Changed

- Legacy `observer` layouts migrate before type validation: `stream=thinking` becomes Reasoning, otherwise Inspector. CLI `--pane-type observer` warns and creates Inspector. Legacy observer-target *concepts* are disabled at merge/save time rather than migrated.
- Concepts that target Inspector (`git_log`, `cargo_check`) ship disabled so captured terminal output is not sent to a model without explicit opt-in; Inspector panes additionally gate captures behind `accept_concept_captures` (default off).
- Child PTYs no longer inherit `GPTY_SECRET`, `GPTY_SOCKET`, or `GPTY_GUI`. Untrusted env cannot set `GPTY_EVENT_*` / session ids.
- Pane labels reuse the highest closed number only: `max(existing)+1` — closing the newest pane recycles its number, middle gaps are never filled.
- Reasoning turn caps are user settings (Settings → Reasoning): max turns (1–64) and max turn bytes (4 KiB–1 MiB), clamped and persisted.
- Toast notifications for unrouted captures name the source pane (`…from T1`).

### Fixed

- Concept routing now requires receivers to advertise capability and confirm delivery before captured bytes are acknowledged; Reasoning panes and failed Inspector starts fall through to another receiver or flush safely back to the terminal.
- Resize no longer triggers concept captures or toasts: `Resize` is not treated as user input for `stop_on_input`, and post-resize shell redraws are suppressed for 750 ms. Alternate-screen output (full-screen TUI redraws) is never concept-matched.
- Terminal resize hardening: transient collapsed pane sizes during split/spawn churn can no longer collapse the grid (cell-dimension floors at event and apply time); redundant SIGWINCH is skipped when dimensions are unchanged; grid growth keeps the visible text and cursor anchored (xterm-style) without ever deleting rows from alternate- or primary-screen TUIs.
- Terminal emulator answers application queries: DSR cursor-position reports and mode reports generated by the emulator are forwarded to the child PTY. Full-screen TUIs that query the cursor after SIGWINCH (e.g. the OMP TUI) now re-render in place instead of re-anchoring their transcript.
- Reasoning accordion: width is viewport-aware (scrollbar accounted for, no right-edge clipping), truncation at the turn cap re-closes Markdown code fences, and auto-follow no longer yanks the view during a deliberate scroll-up.
- Code-viewer panes clear stale content when a configured file path is invalid, and rendered Markdown documents open at the top.

[0.4.0]: https://github.com/godot-pty/gpty/compare/v0.3.2...v0.4.0

## [0.3.2] — 2026-08-13

### Added

- IPC hardening — optional `GPTY_SECRET` shared-secret authentication for the IPC channel; mismatched or missing secrets are rejected with `-32001`
- IPC hardening — request-size cap (64 KiB, `-32600` on overflow) and connection cap (16 concurrent, 30 s timeout) on the IPC server
- Workspace cleanup script — `scripts/clean` removes stale IPC sockets (skipping live listeners), Godot import caches, and standalone `dist/` outputs; `--dry-run` preview and `--all` deep mode; user data never touched
- Standalone app builder — `scripts/build` produces a runnable application bundle for the host platform

### Security

- Concept command injection fixed — `{payload}`/`{N}` template values are shell-quoted (POSIX single quotes) before injection, and substitution is single-pass so payload text cannot trigger nested substitutions. Existing user templates that pre-quote values (`echo '{payload}'`) must drop their own quotes.
- Concept cost bounded — concept count (128), trigger/command lengths, action counts, and `stop_timeout_ms` are capped at parse time; output lines over 16 KiB are never regex-matched; capture buffers finalize early past 4 MiB.
- PTY env sanitized — dynamic-loader variables (`LD_PRELOAD`, `LD_AUDIT`, `LD_LIBRARY_PATH`, `DYLD_*`) and malformed keys are dropped from pane/profile envs at spawn.
- `GPTY_SOCKET`/`GPTY_GUI` hijacking mitigated — the CLI/MCP refuse insecure socket files (wrong owner or open permissions) before sending anything, and `GPTY_GUI` auto-spawn validates the binary.
- Layout restore hardened — malformed tile data (wrong types, unknown pane types, out-of-range grid geometry) is skipped or clamped instead of crashing; code viewer and file tree pane paths must be absolute.

### Changed

- Default IPC socket path moved from `/tmp/gpty.sock` to a per-user runtime directory (`$XDG_RUNTIME_DIR/gpty.sock`, fallbacks `/run/user/<uid>/gpty.sock` and `/tmp/gpty-<uid>.sock`; macOS `$TMPDIR`); the socket file is chmod 0600 and cross-UID peers are rejected on Linux/macOS
- `gpty daemon` auto-spawn no longer launches a second GUI when the running one requires authentication; `daemon status` reports the auth state
- App name displayed as gPTY across the UI, docs, and tooling
- Documentation overhaul — MCP integration section in the root README, accurate GDExtension API tables, IPC architecture and method docs, and a test-coverage guide with explicit gaps; the superseded CLI architecture plan was consolidated into the crate READMEs
- Test suite expansion — capture lifecycle extracted into a unit-testable `CaptureSession`, CLI commands round-trip against a mock IPC server, concept routing extracted into a GUT-testable `ConceptRouter`, gdext IPC tests serialized with per-test sockets, and a GDExtension FFI smoke test (135 GUT tests total)

### Fixed

- Keyboard — printable keys no longer collide with special-key scancodes in the Godot→evdev mapping (`z`/`Z` sent a keypad-multiply sequence, `;` `<` `=` `>` `?` `@` sent F1–F6, `` ` `` sent keypad-enter); they now reach the shell as themselves
- Terminal shortcuts documented — `Ctrl+V` is passed through to the shell as a literal `^V` (readline quoted-insert, vim visual-block); paste remains `Ctrl+Shift+V`
- Shortcut decoupling — `Ctrl+Shift+C` is now copy-only (silent no-op without a selection); code-viewer spawn moved to `Ctrl+Shift+D`. The dual copy-or-spawn binding is gone.
- Text selection survives modifier presses — pressing Shift/Ctrl/Alt no longer clears the current selection
- Global settings apply to every terminal, and the titlebar setting is honored in all spawn and restore paths
- Cursor blink toggle redraws the terminal immediately
- Concept editor no longer crashes when opened with an empty workspace (no terminal panes) — the Add Concept button is disabled until a terminal exists

[0.3.2]: https://github.com/godot-pty/gpty/compare/v0.3.1...v0.3.2

## [0.3.1] — 2026-08-12

### Added

- `gpty concept list` / `gpty concept toggle` CLI subcommands for managing concept automations
- `concept-list` / `concept-toggle` MCP tools exposing concept management to AI agents
- Pre-push CI gate — git hooks (pre-commit, commit-msg, pre-push) and the local `scripts/ci-check` runner
- Windows compile check in CI — a `rust-windows` job on windows-latest, so platform-specific errors surface on push, not at tag time

### Changed

- MCP tool schemas tightened; nested `daemon` and `layout` subcommands flattened into prefixed tools; `mcp.json` added at the repo root for coding-harness auto-discovery
- Documentation restructured — crate READMEs nested under Overview in the docs sidebar, dev setup consolidated into CONTRIBUTING.md, gPTY naming made consistent

### Fixed

- Windows release build — the IPC server now serves per-connection named-pipe instances (`connect()` per instance) instead of the nonexistent `accept()`; fixes the v0.3.0 Windows build failure
- Concept startup race — concepts pushed via `ClassDB.instantiate` on the first frame instead of a dummy `GptyTerminal` whose `#[func]` calls silently no-op'd
- Concept capture — `UntilStop` mode triggers from PTY output rather than stdin echo; capture-only concepts with an empty `cmd` are honored
- Concept enable/disable toggle applies state correctly
- Concepts cross the gdext FFI boundary as JSON strings, bypassing the `Array[Dictionary]` marshaling bug
- Terminal copy/paste — `Ctrl+Shift+V` paste restored, `Ctrl+Shift+C` copy exempt from the ShortcutManager intercept, code viewer spawn moved to `Ctrl+Shift+C`
- MCP kebab-case tool names mapped to camelCase IPC methods; daemon tools handled locally
- Pane resize cascade — no-op `resize_grid` skipped when dimensions are unchanged, removing the scroll-through-history artifact when panes close

[0.3.1]: https://github.com/godot-pty/gpty/releases/tag/v0.3.1

## [0.3.0] — 2026-08-09

### Added

- CLI binary (`gpty`) for pane control over JSON-RPC IPC via Unix socket / named pipe
- IPC bridge: Rust `IpcServer` ↔ GDScript polling via `drain_ipc_requests`/`respond_ipc`
- `gpty new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject` subcommands
- `gpty layout save/load/list` for named workspace profiles
- MCP server (`gpty mcp`) — Model Context Protocol over stdio for AI tool integration (tools/list, tools/call, initialize)
- Daemon mode (`gpty daemon start/stop/status`) — CLI auto-spawns GUI if not running via `GPTY_GUI`
- JSON Schema generation (`gpty schema`) for AI tool discovery (`--format json-schema` and `--format mcp`)
- `gpty-ipc` crate: shared IPC protocol, client, server, and platform transport
- `gpty --version` reports protocol version

### Changed

- Reset button moved from between Settings and Profiles to below the pane list, with red destructive styling
- Settings and Reset buttons decouple Phosphor icon rendering from ASCII text using Label+HBox pattern
- "New:" pane button label renamed to "Add Pane:" with updated styling

[0.3.0]: https://github.com/godot-pty/gpty/releases/tag/v0.3.0

## [0.2.0] — 2026-08-08

### Added

- Three-mode window system: OS decorated, borderless windowed, fullscreen — all with custom titlebar in non-OS modes
- Per-pane titlebar buttons: minimize, position-swap (shows popup to swap with another pane), type-swap (changes pane type), settings, close
- Sidebar pane rows with full action button set matching the titlebar
- Bottom status bar showing active pane info, FPS/ms, and window mode indicator
- "Show titlebar" toggle in Settings → System to hide per-pane titlebars
- Window mode dropdown in sidebar and Settings panel, synced via shared `WINDOW_MODE_LABELS`
- Auto-spawn one terminal on first launch (no saved layout)
- Workspace Trust dialog: warns before restoring layouts saved with a different shell

### Changed

- System tab moved to first position in Settings panel
- Window mode dropdown labels unified to "OS" / "Windowed" / "Windowless"
- FPS/metrics moved from sidebar to bottom status bar
- Sidebar "Add Pane" dropdown replaced with 4 icon buttons per pane type + "+16" bulk spawn via command palette
- Titlebar mode-toggle button removed; mode switching via sidebar/settings dropdown only
- `_toggle_borderless` shortcut (Ctrl+Shift+F11) and `_toggle_custom_window_mode` removed

### Fixed

- Layout persistence: save on `_exit_tree()` instead of unreliable `WM_CLOSE_REQUEST`
- Window mode persisted correctly on restart (was silently defaulting to 0)
- Settings persisted on exit (were not saved in `_exit_tree`)
- Window mode application order: always reset to `WINDOW_MODE_WINDOWED` before applying target mode
- Titlebar Phosphor icon rendering via `Label` child nodes
- Profile trust dialog no longer shows redundant "replace layout?" confirmation
- `as` keyword renamed to `adj_saved` in terminal_manager.gd
- Titlebar drag-to-move: background and label `mouse_filter` set to `IGNORE`

[0.2.0]: https://github.com/godot-pty/gpty/releases/tag/v0.2.0

## [0.1.0] — 2026-07-21

### Added

- Multi-PTY terminal emulator with tiling grid GUI
- `gpty-core` library: PTY spawning (`portable-pty`), ANSI parsing (`vte`), terminal grid (`alacritty_terminal`), concept pub-sub engine
- `gpty-gdext` GDExtension: `GptyTerminal` GodotClass with damage-tracked grid rendering
- `gpty-cli` binary: mock, `--pty`, and `--term` demo modes
- Tiling grid: split vertically/horizontally, kill, expand, and nested `SplitContainer` layout
- Pane types: terminal, code viewer (`CodeEdit`), file tree (`Tree`), observer
- Concept engine: regex triggers → labelled actions with `{payload}`/`{N}` variable substitution
- Concept capture: `UntilStop` mode buffers command output and routes to receiver panes with bidirectional handshake; prompt restoration on acknowledge
- Default concepts shipped (`concepts.default.json`) with enable/disable toggle and deep-merge migration from user overrides
- Settings persistence: cursor shape/blink/thickness, scroll sensitivity, default dimensions, font family/size, UI theme colors, color palette schemes — all auto-saved to `user://settings.json`
- Profile manager: named layout snapshots saved to `user://profiles.json`
- Layout auto-save/restore via `user://layout.json`
- Scrollback with `scroll_up`/`scroll_down`, scrollback indicator, and `Ctrl+F` regex search
- Wrapped text selection for copy/paste
- Toast notification system (info, warn, error) with replace-on-new behavior
- Centralized icon system (`icons.gd`) using Phosphor icon font
- Keyboard shortcuts: `Ctrl+N` (spawn), `Ctrl+W` (close), `Ctrl+B` (sidebar), `Ctrl+P` (command palette), `Ctrl+Shift+R` (reset)
- `Alt+Arrow` geographic pane focus navigation
- Sidebar: pane list with focus, minimize/maximize, swap, kill, and profile save/load
- Command palette with fuzzy command matching
- Title bar per pane with label prefix and action buttons
- Scrollback history stored in SQLite
- Standalone export presets (Linux, macOS, Windows) with CI release workflow
- 60 Rust tests (core + integration) and 40+ GDScript unit/integration tests

[0.1.0]: https://github.com/godot-pty/gpty/releases/tag/v0.1.0
