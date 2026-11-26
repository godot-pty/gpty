---
title: "Roadmap details - CORE"
weight: 900
build:
  list: never
---

Every CORE row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## CORE-1

**Daemon mode** - CLI lifecycle management for the GUI. `gpty daemon start\|stop\|status` starts,
stops, or checks the running GUI process.

Commits: d17bac7

## CORE-2

**Stable pane `attachment_id`** - persisted companion links across save/restore (not ephemeral
labels like `T1`)

Commits: d17bac7

## CORE-3

**SQLite + FTS5 history backend** - wire the existing `HistoryStore` (SQLite + FTS5, tested but
unused in production) into pane lifecycle and session restore. Scrollback is currently lost on
restart; this makes it persistent and full-text searchable, and backs `paneRead` across restarts.

Commits: d17bac7

## CORE-4

**Scrollback store visibility** - the size is on screen now: Settings → Terminal carries a read-only
"On disk:" row showing what scrollback costs, with the store's path as its tooltip. The number comes
from a new static FFI call, `GptyTerminal.history_store_stats()` →
`gpty_core::history::store_size_on_disk()`, which sums the SQLite file and the `-wal`/`-shm`
siblings beside it - SQLite's own accounting, not a guess. That is the only honest source: the store
is bounded by rows *and* bytes, so the footprint cannot be derived from `History lines` (it depends
on how long the lines actually were). Measured live on this machine: `{"bytes":61111896,…}` = 56 938
496 (db) + 32 768 (shm) + 4 140 632 (wal) exactly, with the 0600 modes from the previous item
visible on the same files. The row refreshes on `NOTIFICATION_VISIBILITY_CHANGED`, because the panel
outlives a visit and scrollback keeps growing; a `_history_stats_provider` seam keeps the GUT tests
deterministic (the real store grows while the suite runs - every pane has a writer thread). Tests:
`format_bytes` across the units, the row's presence and tooltip against the real provider, and the
row's text tracking the provider's answer; Rust-side,
`store_size_on_disk_counts_the_store_and_its_siblings` pins the sum (and that a store with no rows
yet counts zero).

Commits: d17bac7

## CORE-5

**`daemon stop` skips teardown, and the quit that fixes it crashed** - both closed. Root cause of
the crash, found under gdb: Godot unloads the GDExtension at exit, and this extension owns threads
that live in it (tokio workers, one PTY reader and one history writer per pane); a worker was still
executing when the mapping went away, so it faulted on a freed code page (`SIGSEGV` in
`tokio-rt-worker`, stack pointing at an unmapped address). `pin_library()` now pins the mapping at
`InitStage::Core` with `RTLD_NODELETE`, and the shutdown handler answers the client and raises a
flag that GDScript polls, so the quit runs through the scene tree. Verified live, 3/3: `daemon stop`
answers `{"shutting_down": true}` with rc 0, no segfault, and the teardown that `process::exit`
skipped now runs - `settings.json` and `workspaces.json` written and the pane's last output line in
`history.db`. Leaving the library pinned costs nothing (the process is ending) and removes the whole
class: no exit path can fault in unmapped code.

Commits: d17bac7

## CORE-6

**Store corruption handling** - a store is user-editable and can be half-written, and a value of the
wrong type used to *raise* inside the loader (`int([1,2])`, assigning an Array to an `int` `_cfg_*`
variable, calling `.get()` on a String, passing a String to a typed parameter), which aborted it at
that line: every key after the bad one was dropped, and the next save wrote the reduced state back
over the file, making the loss permanent. Every loader now reads through typed accessors on
`BasePersistenceManager` (`_as_int`/`_as_float`/`_as_bool`/`_as_string`/`_as_array`/`_as_dict`), so
a bad value costs that value and nothing else: `settings.json` (all keys, including the
`window_position`/`window_size` pairs and the hex colours), `workspaces.json` (container, `active`,
and each entry's `layout`), `profiles.json` (the concept loader was already shape-checked). Two
defects fell out of writing the tests: an empty workspace list made `clampi(active, 0, size - 1)` a
(0, -1) range - an error of its own, on exactly the store a fresh install has - and a workspace
whose `layout` is not a list took the whole set down with it at the typed parameter.
`godot/tests/unit/test_store_corruption.gd` (8 cases) covers defaults, floats-as-ints, a pair with
one bad member, junk entries beside good ones, and the empty list. Verified live: booting with a
hand-corrupted `workspaces.json` (two good workspaces, one junk entry, one wrong-typed layout) and
`settings.json` (bad `cursor_shape`/`history_lines`/`window_position` beside good keys) loads the
two workspaces and every trailing key, logs no script errors, and the save on quit keeps them.
(Deferred from v0.5.3.)

Commits: d17bac7

## CORE-7

**Input writes can block the drain loop** - the terminal task wrote user input and emulator replies
straight to the PTY master, so a child that stopped reading stdin (a flood, a `tail -f`) filled the
kernel's ~4 KiB input buffer and blocked the task inside `write_all` - which stopped it draining PTY
*output*, so the pane froze, and an abort could not land either because the task was inside a
synchronous write. Input now goes to a per-PTY writer thread through an unbounded FIFO (input is
small and user-driven), which coalesces whatever is queued before each write and logs a write error
instead of returning it - the task only queues.
`writing_to_a_child_that_does_not_read_does_not_block` writes 1 MiB to a child that never reads
(from a helper thread, so a regression fails rather than hangs); verified live too: 64 KiB into a
pane flooding `yes` returned in 7 ms and the pane's output kept flowing before and after, where the
old path froze it. A pane killed while its writer is mid-write leaves the grandchild alive for a
couple of seconds until the slave side closes and the write fails; that is self-healing and no worse
than the old blocked task, but killing the pane's process group would be tidier (its own item
below).

Commits: d17bac7

## CORE-8

**Duplicate `attachment_id`** - every pane enters a workspace through `_attach_pane_into`, which
runs `_ensure_unique_attachment_id`, but the *pane settings* apply runs after that: typing an id
another pane already had (or restoring it from a file) left two panes sharing a public id, and
id-targeted IPC then resolved to whichever the search hit first. The panel now announces
`settings_applied(body)` and the workspace re-checks there, redrawing the pane list because it shows
the id. `godot/tests/unit/test_pane_id_uniqueness.gd` drives the panel's real apply path
(`_apply_to_target` with a gather func returning the other pane's id) and asserts both halves: the
collision is renamed away, and `_find_pane_by_label` still resolves each pane under the id it now
carries. Falsified by removing the connection: the id collides and resolution returns the wrong
body. (Deferred from v0.5.3.)

Commits: d17bac7

## CORE-9

**History store write path** - `TermGrid::store_line` called `HistoryStore::append` per output line
while holding the grid mutex, so a flooding pane held the lock the UI renders under for ~30 µs per
line and was itself capped at 33 k lines/s (a `yes` pane moved 1 MB/s), and the store had no byte
cap - 10 000 rows of 16 KiB lines is 160 MB of SQLite and FTS index. Now a pane owns a
`PaneHistory`: `push` queues the line (no lock, no SQLite on the terminal path) and a per-pane
writer thread commits batches - a batch grows to `FLUSH_ROWS` (512) or commits after
`FLUSH_INTERVAL` (200 ms) of quiet, then trims the store. Two caps bound retention: rows
(`history_lines`) and bytes (`RETAINED_BYTES_PER_ROW` = 1 KiB per retained row, min 1 MiB; the row
cap alone let a pane hold hundreds of MB of long lines), and the pending queue is bounded by the
same window - a line the queue drops under flood is one `enforce_cap` deletes on the next commit, so
the retained scrollback stays contiguous rather than opening gaps. Measured: the pane's ceiling went
from ~1 MB/s to 31 MB/s of `yes` output (≈900 k lines/s) with GUI RSS flat (219 MiB across 12 s of
flood); the store's own rate measured in isolation is 33 k rows/s per line → 111 k rows/s in 512-row
transactions (84 k with trimming; larger transactions do not help - the FTS5 index write is the
floor, which is why the writer stays off the terminal path instead of being batched in it).
Write-behind is visible only as staleness: a search can miss the last 200 ms of output. The tail is
protected on quits - `TerminalPane._exit_tree` calls a new `flush_history` FFI (probed on a
`--quit-after` run: it fires for every pane, with `pending` already 0 because the writer commits on
the first notification, so it is a safety net for a burst that lands mid-commit) - but an exit that
runs no teardown (`SIGKILL`, `daemon stop`'s `process::exit`) still loses whatever is queued; the
GDExtension class's own `exit_tree` virtual does NOT fire (probed: 0 firings), so the hook has to
live in GDScript. `append_batch_commits_every_row_in_order`, `byte_cap_trims_oldest_rows`,
`a_full_queue_drops_only_past_the_retention_window`,
`pushed_lines_reach_the_store_and_a_flush_waits_for_them`, `the_writer_commits_on_its_interval`, and
`a_reopened_pane_reads_back_what_the_writer_committed` cover it. (Deferred from v0.5.3.)

Commits: d17bac7

## CORE-10

**A locked history store drops the batch it was committing** - `HistoryStore::open` sets a 5 s
`busy_timeout` and the per-pane writer logs `history append failed (N rows): {e}` and drops the
batch when that expires (`crates/gpty-core/src/history.rs`; the bounded wait itself was added
earlier in v0.5.5, after a Windows run dropped rows the same way). It is not theoretical:
`windows-smoke` on `f60cbf0` failed with
`[gpty_core::history] history append failed (2 rows): database is locked` raised *during*
`test_click_activates_non_terminal_pane` - GUT counts the engine error as a test failure, and
`gut-check` then calls the entire run untrustworthy. The trigger was concurrency: that commit's
bracketed-paste file ran two panes per test (startup + the one it configures), doubling the store's
writer/flush burst in its window; the file now leaves one pane, which removes the amplification but
not the policy behind it. Every pane owns a connection to the *same* file (WAL, so writers serialize
on the write lock) and SQLite's busy handler does not queue fairly, so a writer can starve past 5 s
on a loaded runner. Fix direction, to be chosen with measurements: a process-wide write mutex around
commits (every pane lives in one process, so intra-process collisions disappear by construction and
holding it only across a commit cannot deadlock), and/or a bounded retry with jitter before the drop
- the drop stays the last resort, because a pane's writer must never block forever. The writer's
warn line is the signal to re-measure; a dropped batch costs scrollback rows, not integrity.
**Closed** with the first direction and no retry: one process-wide write guard per file
(`history.rs::write_guard`, a `static Mutex<()>` taken inside
`append`/`append_batch`/`enforce_cap`/`clear`/`prune_missing_panes`), so this process's writers
never race for SQLite's write lock at all and the 5 s busy timeout is left as the backstop for
*another process* on the same file. A retry would have been the second layer over a cause that is
intra-process by construction - every pane lives in one process - and the measurement says there is
nothing to retry *for*: a throwaway probe over one file (N writer threads, 300×16-row batches each)
went from **7 dropped batches at 8 writers and 15 at 16** (`database is locked` - the same message
`windows-smoke` showed) to **zero at both**, while committing *faster* (32.8k rows/s at 8 writers
against 26.1k, a dropped batch being wasted work) and within ~5% of a single writer (34.3k). Pinned
by `in_process_commits_serialize_on_one_file`, which fails on a bypassed guard (a commit that must
wait for it lands immediately) and passes with it; both stores are pre-opened in the test so only
the commit - not `open`'s DDL - can block. A poisoned guard logs once and proceeds unserialized
rather than skipping the write: the alternative loses the rows outright.

Commits: d17bac7

## CORE-11

**`PaneType`'s serde spelling disagrees with the GUI keys** - the enum is
`#[serde(rename_all = "kebab-case")]`, so `NewPaneParams.type` serializes as
`code-viewer`/`cli-view` while `PaneTypes.ALL`, `new-pane.rs`'s `VALID_TYPES`, the GDScript dispatch
and every wire example use `code_viewer`/`cli_view` (the pinned wire test in
`crates/gpty-ipc/src/types.rs` asserts the kebab spelling for the struct). Nothing breaks today
because the CLI builds its `params` with `serde_json::json!` strings and the GUI reads a Dictionary
- but a future caller that serializes the struct (the v0.10.1 Rust-side param validation is exactly
such a caller) produces a pane type the GUI rejects as unknown. Found while adding `cli_view` to the
enum. Fix: align the serde spelling with the GUI keys (and update the pinned test in the same
commit), or drop serde from the field if the struct is a test helper only. **Closed** by removing
the second spelling rather than correcting it: `PaneType` derives no serde naming at all -
`Serialize` writes `as_str()` and `Deserialize` goes through `parse()`, so the emitted set and the
accepted set are one definition and the kebab form (or any future attribute) cannot come back. The
same sweep removed the other three copies of the vocabulary: `pane_types()` in the manifest
validator and `valid_types()` in `new-pane` are derived from the new `PaneType::ALL` (which also
feeds the unknown-value error message), and the seam is now *read* rather than restated -
`pane_types_match_the_gui_registry_key_for_key` parses `PaneTypes.ALL` out of `pane_types.gd` with
`include_str!` and asserts key-for-key equality with the derivation, which the old count-only pair
of tests (`test_pane_types_all_has_six_entries` + a literal list) could not do: a `code_viewer` →
`codeviewer` rename on either side passed both. Mutating one spelling fails four tests, one of them
with the parsed registry as the right-hand side. The legacy `observer` alias survives where it
belongs: `FromStr` (so saved layouts still parse) and `new-pane`'s translation with its deprecation
warning.

Commits: d17bac7, 6cecfd6

## CORE-12

**God-object split** - closed on measurement: the seams that were real are extracted, and the rest
is cohesive-by-topic. (a) The `GptyTerminal` `#[func]` surface is filed by facet: `lib.rs` keeps the
class, the grid helpers and the session lifecycle (1690 -> 1003 lines), and `grid_api.rs` (287),
`history_api.rs` (158), `capture_api.rs` (183) and `bridge_api.rs` (109) carry the rest as
`#[godot_api(secondary)]` impl blocks - gdext's supported way to implement one class across files -
moving 305 doc lines and 47 exports losslessly, with `scripts/check-ffi-surface` re-spined to
attribute a `#[func]` to the class its enclosing impl block names (the old "first struct in the
file" rule silently dropped all 36 moved methods the moment the split landed, which is how it was
found) and to report a `#[func]` outside such a block. (b) `terminal_manager.gd`'s 247-line
divider-drag state machine became `tile_drag.gd` (868 -> 654 lines) behind thin delegators, so the
drag tests did not move - a self-contained machine over the tile list, the one block whose
extraction removes coupling rather than relocating it. (c) Refused, with reasons: the workspace
block-management / persistence / polling / palette regions each read the same
`_workspaces`/`_tm`/`_grid`/`_sidebar`/`_active` cluster, so a split re-injects half the owner or
adds a back-reference that only adds indirection (measured region-by-region, the largest single
candidate is 335 lines of pure glue), and `TerminalPane`'s renderer is a `Control` virtual -
extracting `_draw` is a delegation layer with no cohesion gain and no automated coverage
(manual-only per the testing docs).

Commits: d17bac7

## CORE-13

**Scrollback's last line survives a pane close, and the parallel test is no longer a race** - the CI
run for `d52e5ad` failed only
`history::tests::pushed_lines_reach_the_store_and_a_flush_waits_for_them` on the parallel
`cargo test --workspace` (serial passed; left 50, right 51). Two faults: the writer could take an
empty queue, then see `closed` after a push+close and break with that line still queued; and
`PaneHistory::drop` returned without waiting for the writer, while the test polled for up to 5 s.
Local scheduling hid both; CI's parallel runner hit the break. The writer now re-drains a closed
queue before breaking (once closed is observed, no later push is accepted), and Drop joins the
writer so the test asserts the store directly instead of polling. Verified: 20 repeated runs, both
CI test commands (serial + parallel), fmt and clippy.

Commits: 700273d

## CORE-14

**A damaged history store is a dead end: every pane warns on every launch and no scrollback is ever persisted again** - reported
2026-11-10 from a launch log: four
`Could not open history store for pane <id>: file is not a database` warnings
(`crates/gpty-gdext/src/lib.rs:334`, one per restored pane), while `user://history.db` was
56,938,496 bytes whose every 4096-byte page begins with a b-tree page type byte and which contains
no SQLite header and no `CREATE TABLE` anywhere - `sqlite3 .recover` fails with the same
`file is not a database`, so the schema page is gone and that file's scrollback is unrecoverable.
Nothing in the process could have written it (every history write goes through rusqlite), which is
exactly why the code has to survive it: `HistoryStore::open` treated `SQLITE_NOTADB` as a per-pane
warning and moved on, so persistence was dead for every pane until the user deleted the file by
hand. `open` now reads an unreadable store as a repairable condition:
`NotADatabase`/`DatabaseCorrupt` moves the file and its `-wal`/`-shm` siblings to
`history.db.corrupt` (siblings first, so a stale WAL cannot replay the damaged file's frames into
the replacement), a fresh store takes the path, and the whole open runs under the write guard so the
four panes restoring at startup cannot move the replacement each other just created - one warning,
one quarantine copy, bounded by the fixed name. Any other code (`SQLITE_CANTOPEN`, busy, read-only)
moves nothing, because the file is not what is broken. Verified live in a sandbox with the reported
file planted: one warning, `history.db.corrupt` byte-identical at 56,938,496 bytes, a fresh
`user_version=2` store, and output from two panes in it; tests
`an_unreadable_store_is_moved_aside_and_replaced`, `recovery_moves_the_wal_siblings_with_the_store`,
`a_store_that_cannot_be_opened_is_not_moved`, `concurrent_opens_of_a_damaged_store_replace_it_once`.

Commits: 88b9b06

## CORE-15

**A damaged vault index is the same dead end, one store over** - found 2026-11-10 while fixing **A
damaged history store is a dead end: every pane warns on every launch and no scrollback is ever
persisted again**: `VaultStore::open` (`crates/gpty-core/src/vault.rs:1432`) had the shape
`HistoryStore::open` had and none of the recovery - `Connection::open`, `busy_timeout`, a
`user_version` read, the pragmas - and its six call sites in `crates/gpty-gdext/src/vault_api.rs`
(`:125`, `:180`, `:233`, `:286`, `:365`, `:439`) each logged `vault index open failed (<db>): <e>`
and answered `vault index unavailable: file is not a database`, so a damaged `<state>/vaults.db`
left the Wiki pane's note list, search, link graph and backlinks dead until the user deleted the
file by hand. The database is a *cache of the vault* (`VaultStore`'s own doc says so, and
`index_vault` re-reads every note into it), so recovery loses nothing. Fixed: `VaultStore::open` now
routes through `gpty_core::store::open_with_recovery`, the one helper the scrollback store uses -
the process-wide write guard for the whole open, `NotADatabase`/`DatabaseCorrupt` read as
repairable, `<path>` and its `-wal`/`-shm` siblings moved to `<path>.corrupt` (siblings first, one
fixed name) and the caller's open retried, every other code left alone; `store.rs` also owns
`write_guard` and `restrict_to_owner`, and `history.rs`/`vault.rs` import them (no re-exports). A
recovered index is empty by construction and the next `index_vault` pass rebuilds it. Tests:
`a_damaged_index_is_moved_aside_and_rebuilt_from_the_vault` (two-note vault indexed, store
overwritten with `not a database`, reopen leaves a byte-identical `vaults.db.corrupt`, reindex
restores 2 notes, a live search hit and the `[[b]]` backlink),
`recovery_moves_the_wal_siblings_with_the_store` (now in `store.rs`), and the history store's three
recovery tests unchanged. Live: `scripts/smoke_pane_api.py`'s vault section overwrites
`state_dir()/vaults.db` and requires the next `gpty vault search` to answer the note and
`vaults.db.corrupt` to hold those bytes - recorded as
`FAIL [vault]: ... 'error: rpc error -32603: vault index unavailable: file is not a database'`
before the fix and PASS after. All six `vault_api.rs` sites and `vault_ipc.rs:134`'s `open_store`
inherit it with no call-site edits.

Commits: 88b9b06, aea17ed

## CORE-16

**The PTY input queue is unbounded, so a pane whose child stops reading grows the process** - fixed
2026-11-15 (build 0.8.4). Two bounded stages replace the unbounded ones: `STDIN_QUEUE_CAP` (256
messages) in `crates/gpty-core/src/engine.rs` and `WRITER_QUEUE_CHUNKS` (16 chunks) in
`crates/gpty-core/src/pty.rs`. `PtyHandle::send` answers `WouldBlock` instead of blocking a tokio
worker, and the task retries with a 1 ms async sleep, so a pane close can still abort it and drop
the handle that kills the child; `GptyTerminal.send_text`/`send_line` now return `bool`,
`TerminalPane._send_*` propagate it, `inject` answers a `refused` error when the queue is full and
`broadcast` reports a `refused` count. Test
`a_child_that_stops_reading_refuses_input_instead_of_growing_the_queue`: a `stty raw` child that
never reads refuses the 64 KiB injects within the 288-call loop and accepts at most 256 + 16 + 2; it
passed in 0.07 s. The unbounded build accepted all 288 sends before any refusal.

Commits: 29d3538, d1ccbbb

## CORE-17

**The unbounded-queue control asserted the kernel's appetite, not the queue cap** - found 2026-11-21
(build 0.8.6) when the pre-push gate failed twice and 2 of 8 serial suite runs failed on
`a_child_that_stops_reading_refuses_input_instead_of_growing_the_queue` with `accepted 288 calls`
(once above the writer-queue bound). Cause (`gate-lies`): the send loop yielded between calls, so
the terminal task handed chunks to the writer thread, and a raw-mode Linux master write absorbs
megabytes into the tty flip buffers before it blocks - the instrumented run showed only `READY` in
the grid and no write or backpressure error, i.e. all 288 x 64 KiB were swallowed by the kernel (a
fresh probe blocks after ~11 KiB, so saturation depends on the flip-buffer state the earlier output
left behind). A cumulative accepted count therefore measured kernel appetite while the queue never
filled. The burst is now sent without yielding, so nothing drains the ingress between calls and
`STDIN_QUEUE_CAP` is what refuses; the assertion is the cap itself. 20 serial suite runs and the
parallel pass are green.

Commits: 9696358

## CORE-18

**The motion tests sampled tweens by wall clock and read a freed ghost** - found 2026-11-21 by
windows-smoke run 44919008575 (build 0.8.6): `test_a_slide_close_exits_toward_the_split_edge`
awaited 150 ms against a 200 ms slide; on the runner the timer overshot the tween, the ghost was
freed, the `is_instance_valid` assert recorded a failure and the next line read `w.position` -
`Invalid access to property ... 'previously freed'` as a script error. Cause (`gate-lies`): a fixed
wait assumes the frame budget - one stalled frame expires the timer and the tween together - and GUT
continues after a failed assert. The transition tests now poll `PaneTransitions.playing()` to the
end state, sample the slide ghost and the crossfade's outbound half frame by frame while the
instance is alive (the unchanged rects distinguish out from back), and wait for the ghost's own free
because `_finish` clears the entry a frame before `queue_free` lands. GUT: 127 scripts, 1613 tests,
all passed.

Commits: 365dbed

## CORE-19

**Executable validation rejects system binaries in user namespaces and containers** - closed
2026-11-19. Cause (`platform-parity`): three copies of the owner check assumed host UID semantics,
so a spawn refused an owner the kernel reports as `/proc/sys/fs/overflowuid` (65534) while
`geteuid()` is the user. One rule now answers "may this file run": `pty::validate_executable_file` -
absolute, regular, not group/other-writable, owned by this user, root, or the overflow UID **only
where that UID is outside `/proc/self/uid_map`**, so a host with the identity map `0 0 4294967295`
accepts nothing new and an unreadable `/proc` fails closed - and
`pty::validate_untrusted_executable` adds the no-writable-ancestor walk for a path saved
tile/profile data chose. `transport::validate_gui_binary` and `resolve_omp_binary` now call the file
rule instead of their own copies, which also closes the package-manager case those copies refused (a
root-owned `/usr/bin/gpty-gui` or `/usr/bin/omp`); the user-chosen `GPTY_GUI`/`GPTY_OMP` keep only
the file rule because macOS's `/Applications` is group-writable and must not be refused. Tests:
`pty::tests::executable_owner_rule_admits_this_user_root_and_only_the_unmapped_overflow_uid`,
`pty::tests::a_uid_map_is_read_as_ranges_and_an_unreadable_one_is_not_evidence`,
`transport::tests::socket_validation::gui_binary_in_a_group_writable_directory_is_the_users_choice`,
`binary::tests::the_file_rule_is_shared_with_the_pane_spawn_gate`, and
`crates/gpty-core/tests/userns_executable.rs`, which re-execs itself under `unshare -Ur` and prints
the proof it asserts (`user namespace: euid 0, /usr/bin/sh owned by uid 65534`). Measured: before,
`unshare -Ur cargo test -p gpty-core --lib pty::tests::validate_executable_refuses_paths_another_user_controls -- --exact`
failed on `validate_executable("/bin/sh")`, and `unshare -Ur ./scripts/gut-check` aborted at its
first terminal fixture with
`Cannot start the pane's shell: executable belongs to another user (uid 65534): /bin/bash`, which
gut-check reports as a run it will not judge; after, that `cargo test` passes, all 21 `pty::tests`
pass inside the namespace (PTY spawn tests included), and `unshare -Ur ./scripts/gut-check` runs the
whole GUT suite there - 122 scripts, 1552 tests, 1552 passing, `All tests passed!`, exit 0, where
the same command previously aborted at its first terminal fixture. `Cause: platform-parity` - the
class's control now includes the self-hosting namespace test.

Commits: 80eebf6, 88389e4

## CORE-20

**A Windows absolute program path skipped executable validation** - found 2026-11-19 while unifying
the owner rule: `pty::validate_executable` waved through any program without a `/`, so
`C:\Tools\evil.exe` from a saved tile/profile was never stat'ed - `validate_program`'s separator
test knew about `\` and then handed the path to the function that did not. Fixed in the same commit:
the separator decision is `path_like(program, windows)`, used by `validate_program` and by
`validate_executable_for`, whose platform argument lets
`a_windows_absolute_program_is_not_treated_as_a_bare_name` assert the Microsoft spelling on every
platform (`path_like`'s own cases pin that a backslash stays an ordinary name byte on Unix). Limit:
not exercised on a real Windows host this session - `rust-windows` compiles the test
(`cargo check --workspace --tests`) and it runs on any Windows `cargo test -p gpty-core`.

Commits: 88389e4

## CORE-21

**Input reports success after the PTY writer thread exits** - closed 2026-11-25:
`write_with_backpressure` now takes the task's ingress receiver and returns whether the bytes
reached the writer; a non-`WouldBlock` error logs, calls `stdin_rx.close()`, and returns `false`, so
`PtyTerminalHandle::send_text`/`send_line` answer `false` from then on (tokio `try_send` answers
`Closed`) instead of promising delivery to a dead writer. The task stops writing user input and
emulator replies once the writer is gone, while the select loop keeps draining the read side and any
buffered `Resize`/`FlushCapture`/`AcknowledgeCapture` messages, so the exit code and a final capture
still land. The `inject`/`broadcast` refusal sentences and the GDExtension docs name the dead writer
as a cause. Reproduced before the fix with a scratch probe: a `BrokenPipe` write left the ingress
open and the next `send_text` answered `true`. Tests:
`a_terminal_write_error_closes_the_input_gate`,
`a_wouldblock_write_is_retried_and_keeps_the_input_gate_open`. Residual: a message accepted into the
ingress before the failed write is still lost (there is no per-message ack); every later send is
refused.

Commits: 9696358, 5b4a01d

## CORE-22

**The `send_line` doc says it appends a newline, while the PTY writes a carriage return** - found
2026-11-25 while documenting the refused-input contract: `crates/gpty-gdext/src/lib.rs` said
"appends `\n`", while `PtyHandle::write_line` pushes `b'\r'` (`crates/gpty-core/src/pty.rs`) and
both `crates/gpty-gdext/README.md` and `pitfalls.md` say `\r` is Enter. Fix: the lib.rs sentence
says `\r` (CR = Enter). No test: a doc claim whose authority is the code.

Commits: 5b4a01d

## CORE-23

**Hot-path timers are opt-in and bounded** - nothing times the work the app is asked about: pane
spawn, grid feed, the draw batch, IPC dispatch and the vault index. Fix: a small registry (Rust
`Instant` for engine paths, `Time.get_ticks_usec()` for GDScript paths) that records count, total
and max per named span, is off unless enabled in Settings → Performance or by an environment
variable, keeps a ring of recent samples, and logs only span names and microseconds at `debug`. A
disabled timer must compile to a branch, not a clock read, so enabling it is the only way frame
pacing can change.

## CORE-24

**Power draw is read where the OS exposes it, and says "unavailable" everywhere else** - a number
invented from CPU time would be worse than no number. Fix: one trait with a platform source per OS -
Linux `/sys/class/powercap/*/energy_uj` when readable and `/sys/class/power_supply/BAT*/power_now`
as the fallback, Windows ETW's Energy Estimation provider, macOS `powermetrics` only when an
already-privileged helper is present (otherwise unavailable) - with the source name and sample age
shown beside the value. When no source is readable the pane prints "not available on this system",
never an estimate.

## CORE-25

**A message queued in the writer-error window still answers delivered** - the v0.8.7 fix closes the
input gate only when the task processes the next queued message, so a `send_text` between the writer
thread's fatal write and that observation still returns true and the message is then dropped; on
Unix the read side closes with the writer and the task usually ends first, but ConPTY's 500 ms
`EXIT_DRAIN_QUIET_MS` keeps the window observable. Fix: `PtyHandle` owns
`writer_alive: Arc<AtomicBool>` (true at spawn), the writer thread stores false on a fatal
`write_all`/`flush` error, `PtyTerminalHandle` clones it, and `send_line`/`send_text` check it
before `try_send` and return false; keep `stdin_rx.close()` as the fallback and expose
`pub(crate) fn writer_alive()` for tests. Tests: a `#[cfg(windows)]` live test spawns a child, polls
the flag false while `task_finished()` is still false, then asserts the send is refused; a
`#[cfg(unix)]` unit test sets the flag false on a constructed handle and asserts the refusal; the
two existing gate tests stay green. The Unix end-to-end race is not asserted because it is
unobservable.

## CORE-26

**`gptyd` extraction spike** - move `WorkspaceEngine` + `IpcServer` + event socket into a standalone
Rust daemon; the Godot app becomes a rendering client over the same JSON-RPC (Godot-headless mode is
the interim only, not the destination). PTYs survive GUI close.

## CORE-27

**Grid wire protocol** - `term_get_diff` / `term_input` over the socket, reusing `TermGrid`'s packed
flat arrays as the wire format.

## CORE-28

**Attach/reattach** - GUI close leaves the daemon running; reopen attaches to the live workspace;
`gpty attach` over SSH; `HistoryStore` serves pane read and scrollback across restarts.

## CORE-29

**A `game` pane type, registered on both sides of the vocabulary seam** - `game` joins
`PaneTypes.ALL` and the `PaneType` enum in `gpty-core`, spelled by `PaneType::as_str()` like every
other type, so `new-pane`, the plugin-manifest validator's closed set and the did-you-mean list pick
it up from the enumeration, and the key-for-key test between the Rust enum and `pane_types.gd` fails
on a one-sided rename. `sanitize_tile` accepts a `game` setting only from a closed set of built-in
game ids (the layout-trust rule: a file never names code), and an unknown id restores as the game
picker with a notice. Tests: the vocabulary test covers `game`; a tile with an unknown or
path-shaped id restores as the picker; the chosen game round-trips through a saved layout.

## CORE-30

**High scores live in a user-owned store** - A `GameScoreStore` on the `BasePersistenceManager`
pattern (typed reads, size caps, owner-only mode) keyed by game id. A layout, profile or IPC call
can carry the chosen game id but never a score or a saved game state, so a shared file cannot plant
a record. Tests: a corrupt or oversized entry costs only itself; a profile carrying a `score` field
has it stripped on restore; an unknown game id in the store is ignored.

## CORE-31

**A game pane holds no daemon state** - With the v0.10.0 daemon a game is GUI-local: it owns no PTY,
a reattached window restores the pane at the game's start screen (not mid-game), and only scores
persist. State it in AGENTS.md beside the pane-type rules. Tests: a `game` tile restores through
layout restore and through reattach without a PTY and without error.
