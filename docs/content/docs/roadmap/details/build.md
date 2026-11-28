---
title: "Roadmap details - BUILD"
weight: 900
build:
  list: never
---

Every BUILD row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## BUILD-1

**Standalone export** - first CI release producing self-contained binaries for Linux, macOS, and
Windows. No Godot editor or Rust toolchain required to run - just download and launch.

Commits: d17bac7

## BUILD-2

**Release-quality CI gate** - pre-push git hooks, local `scripts/ci-check` runner, and a Windows
compile job catching platform breakage before tagging

Commits: d17bac7

## BUILD-3

**Workspace cleanup script** - `scripts/clean` removes stale sockets, import caches, and build
outputs

Commits: d17bac7

## BUILD-4

**Standalone app builder** - `scripts/build` produces a runnable bundle for the host platform

Commits: d17bac7

## BUILD-5

**Test coverage expansion** - capture lifecycle, CLI mock-server roundtrips, concept routing, gdext
FFI smoke

Commits: d17bac7

## BUILD-6

**Live pane-API smoke** - exercise the v0.5.0 surface end-to-end against a running GUI: `new-pane` →
`inject` → `pane-read` → `pane-wait` → `broadcast` over tagged panes, plus `pane-status` exit codes
from `pane-run` (Unit/GUT covered, but not smoke-tested live).

Commits: d17bac7

## BUILD-7

**Event-socket smoke** - extend the live smoke to cover `subscribe`/`eventsPoll` on
`gpty-events.sock` (pane spawn/kill events). The control-socket pane API is smoke-covered; the event
socket is not.

Commits: d17bac7

## BUILD-8

**Palette test dedup** - `test_palette.gd` now asserts against `PaneTypes.build_palette_commands()`;
the command list lives in one place.

Commits: d17bac7

## BUILD-9

**App version & build info** - Settings gains an About tab showing `gpty v<get_app_version()>`, the
pinned IPC protocol version, and the repo URL; the status bar shows the live version as the
rightmost entry. (Deferred from v0.5.0.)

Commits: d17bac7

## BUILD-10

**CI least privilege** - every job inherited the repository default token scope; `ci.yml` now
declares `permissions: contents: read`.

Commits: d17bac7

## BUILD-11

**Parallel test job in CI** - `scripts/ci-check` ran only `cargo test --test-threads=1`, and that
serialisation hid a shared-static isolation bug in `crates/gpty-gdext/src/ipc.rs` until a
multi-threaded run surfaced it; step 4.2 now runs the workspace suite with default parallelism as
well. The intermittent failures it was left open for turned out to be five distinct causes, all
fixed here: (1) a pane's exit code was probed once when the pty read side closed, and a child that
closes its fds a moment before it is reapable answers that probe with `None` -
`paneStatus`/`paneRun` then reported no exit code at all (now polled briefly); (2) the OMP session's
liveness probe has the same window, so the next prompt could land in a closed pipe and fail the turn
(now re-spawned and re-served); (3) two OMP tests share the process-global `GPTY_OMP` and clobbered
each other under the default parallel runner (now serialised by a test lock - found by the new test
added with this work); (4) `fake_adapter` reused temp-script paths across runs, so a leftover child
from a killed run made `exec` fail with ETXTBSY (paths now carry a run-unique suffix); (5) the pty
tests' wall-clock budgets assumed an idle machine and reported product bugs under load (now a shared
`wait_until` / longer drains). Result: 12/12 clean `cargo test --workspace` runs on the development
machine, where the suite previously failed roughly one run in eight.

Commits: d17bac7

## BUILD-12

**Bundle layout & build pinning** - the release ships the CLI as `gpty` and the GUI as `gpty-gui`
(with Godot's generated `gpty-gui.sh` launcher on Linux, `gpty-gui.exe` on Windows), so the GUI no
longer shadows the CLI on `PATH` and the CLI can auto-spawn a sibling GUI; every bundle carries the
app icon (Godot 4.7 embeds the PE icon itself, `application/icon` in the Windows preset), and CI and
the export preset are pinned to Godot 4.7.2 with a fast-fail check when export templates do not
match the editor. Also shipped without a roadmap item.

Commits: d17bac7

## BUILD-13

**Pin the GDExtension on Windows** - `pin_library()` now has a `cfg(windows)` branch calling
`GetModuleHandleExW` with `GET_MODULE_HANDLE_EX_FLAG_PIN \| GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS`,
naming the module by the address of the function itself (nothing depends on the DLL's file name) and
reporting a failure through the `log` bridge instead of failing silently; the `libc`/`RTLD_NODELETE`
branch is unchanged, the call site is unconditional, and a no-op stub covers platforms with neither
loader. Raw `extern "system"` + `#[link(name = "kernel32")]` rather than a new `windows-sys`
dependency. Verified by compile: `cargo check --workspace --target x86_64-pc-windows-msvc` under
`-Dwarnings` passes locally through `ci-check`'s xwin/clang-cl step (the same target and flags as
the CI `rust-windows` job). Runtime is still unverified - the Windows smoke item below is what will
exercise the pin at exit.

Commits: d17bac7

## BUILD-14

**GUT aborts can pass CI** - the gate is now `scripts/gut-check`, which owns the GUT command
(`ci-check` and the `gut-tests` CI job call it, so the run and its guard cannot drift) and judges
the output instead of the process exit code: Godot parse/script-error lines fail it, the Run Summary
must be present and end in `All tests passed!`, the script count it reports must equal the
`test_*.gd` files the gdirs hold, and every collected script must contribute at least one test. A
`test_*.gd` nested below a gdir is listed as never-run, because GUT does not recurse
(`include_subdirectories` is off) - a suite that quietly stops covering a directory is the same
failure class. Reproduced before the fix: a parse error in one collected script made GUT break into
Godot's debugger, run 4 of 40 scripts, print no Run Summary, and exit 0 in 1.3 s (the live run takes
57 s) - the old step printed PASS off that exit code. Verified after: the clean run reports
`40 scripts, 406 tests, all passed` and exits 0; the same probe exits 1 with both parse-error lines
plus "no Run Summary in the output - the run stopped before it finished"; a `test_*.gd` that does
not extend `GutTest` and a nested `test_*.gd` each fail with the offending file named and the file
counts it contradicts. CONTRIBUTING and `docs/content/docs/overview/testing.md` now point at the
script; AGENTS.md's Testing section records why the raw command is not the gate.

Commits: d17bac7

## BUILD-15

**Seam contract tests** - each of the three named seams now has a test that reads *both* sides
instead of a copy of one side (the `#[func]` surface it starts from was already enforced by
`scripts/check-ffi-surface`, which `ci-check` runs). (a) **MCP tool → IPC method → dispatch**:
`crates/gpty-cli/src/commands/mcp.rs` no longer carries a hand-written method list; it parses the
real registrations out of `crates/gpty-gdext/src/ipc.rs`, the real dispatch arms out of
`ipc_handlers.gd`, the `method ==` requests `workspace.gd` intercepts before dispatching
(`paneWait`), and every `client.call`/`call_and_format` literal under `src/commands/`, then asserts
one vocabulary with the advertised MCP tools. It found the drift it was written for: `paneWait` was
registered but missing from the dispatcher (handled in the workspace's per-frame loop, which the
test now models) and `version`/`shutdown` carried dead GDScript arms for two methods the Rust server
answers locally - both arms deleted, so the partition is exact (registered = locally answered ⊎
GDScript-handled) and every registered method must be named by a CLI call site. (b) **Pane targeting
by id and legacy label**: the old `godot/tests/unit/test_ipc_routing.gd` reimplemented
`_find_pane_by_label`, the `listPanes` response and the error envelope inside the test and asserted
on those copies (its own header admitted it), so it could not fail when the shipped handlers
changed; it is deleted, and `godot/tests/integration/test_ipc_dispatch_contract.gd` drives
`WorkspaceIpcHandlers.handle` against a real `Workspace` - every id `listPanes` reports must address
the pane IPC resolves, a `T<n>` label must land on the labelled pane, terminal-only methods
(`paneRead`, `inject`) must refuse a non-terminal, an unknown method answers -32601, and
`layoutLoad` must refuse an untrusted profile while restoring a trusted one. It caught a real
defect: `focusPane` called `grab_focus()` unconditionally, so focusing a read-only pane raised an
engine error and activated nothing while still answering `success: true`; the activation rule
(record `last_body` in the body's own workspace, take keyboard focus for a terminal, release it
otherwise) is now `Workspace.activate_pane()`, shared by the click path, the sidebar row and IPC.
(c) **`paneRead`'s "screen plus scrollback" claim**: the smoke step only read back a marker that was
still on screen; it now fills the pane with 120 lines (≈5 screens) and requires the oldest marker as
well as the newest, so the documented claim is verified through CLI → socket → GDScript → grid where
output timing is real (the grid-side half stays pinned by `plain_text_includes_scrollback`). Docs:
`docs/content/docs/overview/testing.md` no longer claims `Workspace` cannot be instantiated headless
(three test files do) or that real PTY spawning is `#[ignore]` (nothing is); AGENTS.md records the
seam-test rule and `activate_pane`.

Commits: d17bac7

## BUILD-16

**Windows runtime smoke** - the `windows-smoke` job (`windows-latest`) now boots the GUI headless
and drives the CLI against it: the CLI and the GDExtension are built for Windows, Godot 4.7.2's
Windows editor is downloaded with its SHA512 pinned from the release's `SHA512-SUMS.txt`, and
`scripts/smoke_pane_api.py` - one harness for every platform, since only the transport differs (Unix
socket vs named pipe, `open()` on both) - runs the full flow: control-pipe round trip, the
**named-pipe event listener** (`subscribe`/`eventsPoll`, spawn and killed events), pane lifecycle,
inject → pane-wait → pane-read, scrollback, broadcast, `pane-run` exit code, kill-pane. GUT stayed
Linux-only at that point (`cfg_shell_command = "/bin/sh"` in the suite); it runs on Windows now -
see the next item. Writing the job surfaced two real Windows defects, both fixed here: the first-run
shell default was `/bin/bash` everywhere, which `validate_executable` refuses on Windows (not
absolute there) so **every pane of a fresh Windows install failed to start** - the default is now
`%COMSPEC%` (falling back to `cmd.exe`) through `SettingsManager.default_shell_command()`; and
`pane-run` always passed `-c`, which `cmd.exe` rejects - `PaneTypes.shell_run_args()` now picks `/c`
for the cmd family and `-c` otherwise (unit-tested; `pane-run` on Linux is unaffected). The harness
itself is verified on Linux (full PASS, and `GODOT=/bin/true` reports `FAIL [launch]` with the log
tail, exit 1); the Windows leg is observed by CI, which is the point of the job. `ci-check` step 5.5
runs the same file with `python3`, and the bash smoke + its Unix-only event client are gone.

Commits: d17bac7

## BUILD-17

**GUT on Windows** - the suite runs on both platforms now. Every test that spawns a pane takes its
program from `SettingsManager.default_shell_command()` (a literal `/bin/sh` is refused by
`validate_executable` on Windows and the failed spawn is an engine error, which GUT counts as a test
failure - so this was the blocker, not cosmetics), and the two tests that need exact bytes from a
*child* build their command line through the new `godot/tests/helpers/shell_fixtures.gd`: POSIX gets
`printf '%b'` with octal escapes, Windows gets PowerShell `[Console]::Write` with `[char]N`, and the
helper holds the child alive where the point of the bytes is a terminal mode that a returned prompt
would reset. `paneRun`'s `-c`/`/c` assertion and the inspector adapter probe went cross-platform too
(`OS.get_temp_dir()` instead of `/tmp`; a non-regular file is now refused on every platform, and the
world-writable case stays Unix-only inside the same test). The gate learned the difference between
the two non-passing kinds: `scripts/gut-check` prints every `[Pending]` test with its reason and
accepts a pending-only run (counted from GUT's own summary sentence, because GUT prints each pending
test twice), while `[Risky]` - a test that ran without asserting - fails it, so a Windows-only gap
cannot hide a suite that stopped asserting. The `windows-smoke` job runs the same gate under Git
Bash after its import step; the Linux path is unchanged and verified locally (40 scripts, 404 tests,
all passed). One test still pends on Windows with its reason in the source: the fake CLI adapter is
a POSIX shell script.

Commits: d17bac7

## BUILD-18

**gpty-ai's fake-`omp` fixture collides under parallel tests** - the parallel gate (`ci-check` step
4.2, `cargo test --workspace` with default threads) failed once with
`omp_session_respawns_after_child_exits` reporting "failed to spawn omp …: Text file busy": the
script path's uniqueness source was the clock's nanosecond fraction
(`gpty_fake_omp_{pid}_{subsec_nanos}.sh`), which a coarse clock repeats - exactly the
shared-temp-path class the parallel gate exists to catch. Fixed: `fake_script_path(kind)` builds the
path from pid + nanos + a process-global `AtomicU64` counter, so two creations in the same process
can never collide, and both fake-omp tests use it. Verified: `cargo test --workspace` (the gate
itself) 3/3 green with the fix; five solo `-p gpty-ai` runs before it were green, so the race only
showed under load. Found while the gate blocked the plugin-manifest commit.

Commits: d17bac7

## BUILD-19

**Parallel-safety audit (triggered by the fake-`omp` flake)** - swept the whole workspace for the
class the parallel gate catches: process-global env mutation, shared statics, fixed temp paths,
panic-path cleanup. Confirmed clean: transport's `EnvVar`/`EnvVars` lock, gdext ipc tests
(`#[serial]` + `clear_state()`), `omp_events` `QUEUES` + `reset()`, per-test-name socket/db paths
(`gpty-cli/tests.rs`, `daemon.rs`, `history.rs`, `ipc.rs`, `server.rs`), the smoke harness's
`mkdtemp`, the extension tests' mocked `fsModule`, the GDScript mock-store teardown, read-only
statics, `engine.rs`'s remove-before-use, and the spawn test's cleanup-before-assert. Two stragglers
fixed: (a) `client_authenticates_with_secret` mutated `GPTY_SECRET` raw, outside any lock - the
guard is now a shared `crate::test_env` module (`gpty-ipc/src/test_env.rs`, `LazyLock` +
restore-on-drop, panic-safe) used by both `transport.rs` and `client.rs`, and the test drops the
guard instead of `remove_var`; (b) two `pty.rs` tests left a world-writable `0777` file/dir in
`/tmp` until after their asserts - verdicts are now captured, permissions restored and paths removed
first, then asserted (the pattern the sibling test already used).
`cargo test -p gpty-ipc -p gpty-core` green.

Commits: d17bac7

## BUILD-20

**AUR package rework** - the bundle now ships the CLI as `gpty` and the GUI as `gpty-gui`, so
`dist/aur/PKGBUILD` must install both
(`/usr/lib/gpty/{gpty,gpty-gui,gpty-gui.pck,libgpty_gdext.linux.x86_64.so}`, with `gpty` and
`gpty-gui` on PATH), point the desktop entry at `Exec=gpty-gui`, install `godot/icon.png` as
`/usr/share/icons/hicolor/256x256/apps/gpty.png` with `Icon=gpty`, bump `pkgver`/`pkgrel`, and take
the tarball hash from the release's `SHA256SUMS` asset. Validate with `makepkg` before uploading; it
cannot be done before the tag because no `gpty-gui` asset exists until then. (Deferred from v0.5.4.)
**Closed post-tag:** pkgver 0.5.4 with the tarball hash taken from the release's `SHA256SUMS` asset
(and verified against it by downloading the published tarball: digest identical); the recipe
installs both halves - `gpty` (CLI) and `gpty-gui` (GUI) with `gpty-gui.pck` and the GDExtension
library - under `/usr/lib/gpty/`, with absolute symlinks for both on `PATH`; the desktop entry
launches `Exec=gpty-gui` with `Icon=gpty`; the shipped `godot/icon.png` is 494x494, so a 256x256
`dist/aur/gpty.png` derived from it installs at `hicolor/256x256/apps/gpty.png`; both license files
install under `/usr/share/licenses/gpty-bin/` straight from the tarball, so the recipe fetches
nothing from the source tree. `makepkg -f` builds `gpty-bin 0.5.4-1` with the source checksums
verified, and the packaged CLI reports `gpty 0.5.4` run out of the built package.

Commits: d17bac7

## BUILD-21

**`test_a_follower_is_primed_on_attach_and_told_every_change` flakes on `windows-smoke`** - one run
of `7c0f4f4` failed with `["idle"] expected to equal ["needs-attention"]` (491 tests, 1 failing) and
the same commit passed on the next rerun, while the two runs before it passed that step too. The
test sets the state through the FFI (`body._terminal.set_agent_state(...)`) and waits for the
follower's `seen` list to grow, so the observed `idle` was appended *after* the transition: either
the follower was re-primed with the tracker's current state (a source re-resolve appending a
duplicate late), or the transition did not reach it inside `_wait_until`'s 3 s budget and the last
value came from the priming alone. Both live in the dispatch chain (`TerminalPane._poll_agent_state`
on its slow cadence → `workspace._dispatch_agent_state` → `_prime_new_pane_observers`), which the
test observes only through the follower's own list. Fix direction: wait for the *value* rather than
the list size, with a budget sized for the slow poll on a loaded runner, and - if the investigation
shows a re-prime after a change - pin that separately, because a pane re-pointed at the same source
must not receive a stale duplicate. Evidence: windows-smoke in runs 35288934335 and 35289527651,
failing assertion in `test_agent_state_contract.gd`. **Closed:** the duplicate was the source's, not
the test's timing: `TerminalPane._poll_agent_state` compared the tracker against a shadow that
started empty, so the first slow poll after the entry prime re-announced the spawn state as a change
- every observer (and the badge) heard `idle` twice, which satisfied a size-based wait and then
failed the value assertion (run 35289527651 attempt 1:
`["idle"] expected to equal ["needs-attention"]`, failing at `test_agent_state_contract.gd:99`; the
other cited run's windows-smoke failure was the second-instance smoke step, not this flake). Fixed
at the source: `on_agent_state_changed` records the delivery in `_badge_state`, the poll reports
only deltas against it, and its first read before any delivery is adopted silently so the entry
prime stays the single delivery of the spawn state - true in either order, since the prime scan and
the poll can meet in the same frame. The test waits for the *value* (5 s, many 0.25 s slow polls)
and pins the exact sequence `["idle", "needs-attention"]` (one entry delivery + one change).
Evidence: a forced-ordering repro showed `["idle","idle"]` before the fix and `["idle"]` after;
`scripts/gut-check` green (48 scripts, 491 tests).

Commits: d17bac7

## BUILD-22

**A GUT run collides with a live gpty instance and dies without a summary** - the tests spawn real
`GptyTerminal` panes, each of which binds the shared control and event sockets, so running the gate
while a GUI is up makes the bind fail: every pane-spawning test logs
`another gpty instance is already listening on /run/user/1000/gpty-events.sock` (and the same for
`gpty.sock`), the instance's shutdown flag is set, and the process quits mid-suite - measured
2026-10-14, `gut-check`'s command against the default runtime dir stopped after 12 scripts with no
Run Summary (exit 1, which reads as a crash, not as "close the app"), while the identical command
with `XDG_RUNTIME_DIR` pointed at a 0700 temp dir ran all 27 unit scripts / 346 tests. Hit again
2026-10-15 on a single-file run (`-gtest=res://tests/unit/test_wiki_pane.gd`): same bind failure,
same mid-suite exit, and the sandboxed runtime dir was again the only way through (50 scripts / 555
tests). Fix direction: sandbox the runtime dir (and/or `GPTY_SOCKET`) for the test process in
`scripts/gut-check` and the GUT command, so a developer's running workspace can never collide with
the suite. `scripts/gut-check` hands the run a private endpoint and profile - one 0700 temp
directory the trap removes, with `GPTY_SOCKET` aimed into it,
`XDG_RUNTIME_DIR`/`XDG_DATA_HOME`/`XDG_STATE_HOME` set to it, and `GPTY_SECRET` cleared.
`GPTY_SOCKET` alone moves *both* listeners, because the event path is derived from the control one
(`default_event_socket_path()`), and on Windows that same variable carries the pipe name - so the
fix is not Unix-only. Verified against the reported failure itself (2026-10-16: the developer's GUI
held `/run/user/1000/gpty{,-events}.sock`): `./scripts/gut-check` ran green - 50 scripts, 560 tests
- where the same command had stopped after 12 scripts with two bind refusals and no Run Summary, and
`./scripts/ci-check` (what the pre-push hook runs) passed end to end with no hand-set environment,
the live GUI still answering the CLI. AGENTS.md records the rule on the gate bullet.

Commits: d17bac7

## BUILD-23

**A GUT run on Windows still touches the real user profile** - (the Unix half landed 2026-10-16; the
record is at the end of this item) the same class of leak one level down: a bare `Workspace` built
in a test runs `_init_workspaces`, which reads the *real* user data directory (`WorkspaceStore` is
mocked through `_read_file`/`_write_file`, but the legacy `import_legacy_layout()` path reaches the
file directly), so the pane set a test sees depends on the machine it runs on - measured 2026-10
while writing `test_pane_close_guard.gd`: a fresh workspace came up with one terminal tile restored
from a real `layout.json`, and the same assertions saw zero on a machine without one, which is why
that file asserts only on the panes it spawns. Fix direction: sandbox `XDG_DATA_HOME`/`APPDATA`
**and `XDG_STATE_HOME`/`LOCALAPPDATA`** for the test process in `scripts/gut-check` (the smoke
already does exactly this), or make the legacy import go through the same mocked readers. The state
directory belongs in that sandbox for the same reason: `vault_index` has always written probe-vault
rows into the developer's real `vaults.db`, and the recovery-copy tests (2026-10) now write
`state_dir()/scratch` files there too - they clean up in `after_each` and their keys carry the run's
ticks so a leaked copy is unreachable, but a crash mid-test still leaves a file in the developer's
own state directory (the 2026-10 prune narrows this: a copy whose probe vault is gone is reclaimed
by the next write anywhere, and the vaults are removed in `after_each` - but a run that dies
*before* its teardown leaves the vault and its copy together, so the sandbox is still what closes
this), and on Windows `XDG_STATE_HOME` does nothing at all (`state_dir()` reads `%LOCALAPPDATA%`).
**Narrowed (2026-10-16):** `scripts/gut-check` now sandboxes `XDG_DATA_HOME`/`XDG_STATE_HOME`
alongside the endpoint (`XDG_RUNTIME_DIR` + `GPTY_SOCKET`), so on Linux/macOS a suite run writes no
probe vault, no vault-index rows, no recovery copies and reads no `layout.json` from the real
profile - the machine-dependent `Workspace` restore this item was found with is gone there
(verified: a full run left the real data directory's entries and `vaults.db`'s mtime unchanged, and
the queued half this item's own note mentions - the recovery copies - rides the same sandbox).
Windows keeps the whole problem for Godot's `user://`: it resolves through the Known Folder API,
which no environment variable redirects (the live smoke documents the same limit and works around it
with a backup/restore of the real files - practical for the two stores it seeds, not for a suite
that writes a probe vault per test). The Rust state dir *is* env-based (`state_dir()` reads
`%LOCALAPPDATA%`), so a Windows run can take that half too. What remains: (a) route the legacy
`import_legacy_layout()` read through the mocked `_read_file`/`_write_file`, so a bare `Workspace`
in a test never sees a real `layout.json` on any platform, and (b) give the gdext-level `user://`
writes (probe vaults, settings churn) either an FFI-level test root or the smoke's backup/restore
discipline. the FFI-level test root, with one seam instead of two.
`BasePersistenceManager.resolve_store_path` translates every `user://` store path
(`_read_file`/`_write_file`) into `GPTY_TEST_USER_DIR` when that variable names an absolute
directory (empty/relative values are ignored, so a typo cannot send stores somewhere the app cannot
find again), and the gdext `history_db_path` resolves the scrollback database through the same
variable - pinned by `history_db_path_honors_only_an_absolute_test_root` and by
`test_the_test_user_root_redirects_the_history_store`, which drives the real FFI.
`scripts/gut-check` exports it on every platform (on Unix it overlaps the XDG sandbox on purpose:
the normal Linux gate exercises the seam), adds `LOCALAPPDATA`/`APPDATA` on Windows (via
`cygpath -w`; the Rust state/data dirs read them directly); the smoke passes `--log-file` for its
engine log, while GUT leaves Godot's file logging off (so there is none to move). Test-created paths
go through the new `TestPaths.user_path` helper (which asks the same `user_root_override()`),
replacing every `ProjectSettings.globalize_path("user://…")`; the live smoke uses the same seam, so
its concept/plugin backup-and-restore code is gone. The (a) half needed no change:
`import_legacy_layout()` has read through the mocked `_read_file` since the storage refactor
(`test_legacy_layout_import` pins it), and the seam means even an unmocked read reaches only the
sandbox. Verified: a pane-spawning GUT subset left `history.db` in the sandbox and no store outside
it; the full gate green (57 scripts / 737 tests); `cargo test -p gpty-core --lib` 259 passed and the
gdext history test passed; `ci-check --fast` green; the live smoke `PASS` on Linux with the real
`concepts.json`/`workspaces.json`/`layout.json`/`settings.json` mtimes unchanged. The Windows half
is the same code path the `windows-smoke` job now runs (GUT under Git Bash + the smoke).

Commits: d17bac7

## BUILD-24

**The release workflow's build jobs inherit their token scope instead of declaring it** - **re-read**,
and the live exposure is smaller than first reported. `release.yml` has no top-level `permissions:`;
only `export-release` declares one (contents, `id-token` and attestations write), while `ci.yml`
declared one and `docs.yml` declared one only on its single job. The audit could not check the
repository default; checked now through the API: default workflow permissions are **`read`** and
workflows cannot approve pull requests, so today the build jobs hold a read-only token and nothing
is exposed - the missing block is a latent trap (a flipped default, a transferred or forked
repository) rather than a live hole. Fix: `permissions: contents: read` at the top of `release.yml`,
writes only on the job that needs them; the `lint-workflows` job is the place to keep it from
regressing if it can express the rule. Also recorded, so it is not re-derived later: every
third-party action is pinned to a full SHA, and each SHA resolves into its action's tagged history
(compare API), except `dtolnay/rust-toolchain`, which reports "diverged" - expected, since that
action's `stable` revision is a commit its maintainer regenerates (authored by him on 2026-09-03,
"toolchain: stable"), so no pin is an impostor. **Not a code change, owner action:** `main` has no
branch protection and the repository has no rulesets (API: not protected, zero rulesets), and a
pushed `v*` tag starts a workflow that holds `id-token` and attestation write and creates the
release; a tag ruleset limiting who can create `v*` tags is the cheap guard and is tracked as its
own row below. **Fixed 2026-10-24:** GitHub's code scanning listed four findings on `release.yml` -
the workflow and its `build-linux`, `build-macos`, `bundle-macos` and `build-windows` jobs.
`permissions: contents: read` is now the top of both `release.yml` and `docs.yml`; code scanning
flagged `release.yml` alone because `docs.yml`'s one job carried its own block, but `docs.yml`
needed the same top-level block: a second job added there would have inherited the repository
default. `export-release` keeps exactly its three writes, which replace the workflow scope for that
job. Guard: `scripts/lint-workflows` validates the YAML and refuses any workflow without a top-level
`permissions` block, and `ci.yml` and `scripts/ci-check` both call that one script so the rule
cannot drift from its enforcement. Verified: the script names `release.yml` and `docs.yml` and exits
1 on the pre-fix tree, passes on this one, and `ci-check --fast` is green.

Commits: d17bac7, 6b45e50

## BUILD-25

**The Linux release's CLI ships non-executable** - measured on the v0.7.0 download: `gpty` is 0644
while `gpty-gui` is 0755, so `./gpty version` fails with `Permission denied (os error 13)` and the
bundle cannot provide a working CLI at all. The Linux packaging job copies the CLI out of
`actions/download-artifact`, which does not preserve file modes; the GUI is exported in that same
job, so it keeps `+x`. The job now `chmod 0755` s the CLI before tarring. Verified: the defect is
reproduced on the v0.7.0 tar contents and the workflow change passes the fast CI workflow lint; the
next release's tar is the end-to-end proof.

Commits: 43cfc7a

## BUILD-26

**CI's dependency audit failed with a permissions error instead of naming the advisory** - found
2026-10-24 on the first red run after RUSTSEC-2026-0386 (tokio 1.53.1, unsound: the `AsyncFd`
constructors violate I/O safety) entered the advisory database on 2026-10-13. Two faults stacked:
the pinned `rustsec/audit-check` publishes its finding as a Check Run, which needs `checks: write`,
and the least-privilege sweep (`01b26e7`) left this job with only the inherited `contents: read` -
so a clean audit never called the API (the job had been green for six weeks) and the first real
finding died with "Resource not accessible by integration" one line after "Found 1 unsound", never
printing the advisory. Granting the scope would not have been enough either: a fork PR's token is
read-only, so the action can never create a check there. Fix: the job installs `cargo-audit` with
`cargo install --locked --version 0.22.2` and runs `cargo audit --deny warnings` directly - no
token, no write scope, works on forks, and the advisory text is the failure. The version is pinned
because `taiki-e/install-action` has no cargo-audit entry and an unpinned tool could change its
policy under a green build; the cost is a couple of minutes on a job that runs in parallel anyway.
`scripts/ci-check` uses the same flag, because plain `cargo audit` treats `unsound` as an allowed
warning: the local gate passed on exactly the tree that turned CI red, which is how a red CI arrived
with no local warning. `Cargo.lock` moves tokio 1.53.1 to 1.54.1 (patched from 1.53.3); nothing in
`crates/` calls `AsyncFd`, so the unsound path was never reachable here. Tests: the audit is clean
under the new flag, and the local full suite now rejects any warning CI would reject.

Commits: 701b2b8

## BUILD-27

**A release offers three downloads, not thirty-six files** - closed 2026-11-01 by v0.7.1's published
asset list. v0.7.0 published 36 assets: the three platform archives plus every GDExtension and
pinned FFmpeg library copied out of the build artifacts (`dist/gdextension/*`), which each archive
already contains. Nothing consumed them (`update_checker.gd` reads a version string and nothing
else), they made the Releases page look like a build-artifact dump, and they made the project's only
install signal meaningless: v0.7.0's "73 downloads" were 7 real bundles. `export-release` no longer
stages or uploads them, so a release is the three archives plus `SHA256SUMS`, and the checksum,
attestation and upload lists cannot disagree about the asset set. No repository test covers a
release job; the check is the next tag's asset list (the three platform archives, `SHA256SUMS`, and
`install.sh` once that row has shipped) and the same three bundles still containing their libraries.
**Verified on the v0.7.1 release:** `gh release view v0.7.1 --json assets` reports exactly **4** -
`gpty-v0.7.1-linux-x86_64.tar.gz` (46 372 269 B), `gpty-v0.7.1-windows-x86_64.zip` (57 781 760 B),
`gpty-v0.7.1-macos.zip` (95 010 805 B) and `SHA256SUMS` (283 B) - where v0.7.0 published 36;
`sha256sum -c SHA256SUMS` passes for all three archives; every archive carries `LICENSE` and
`LICENSE-EXCEPTIONS.md`; both Linux binaries are `-rwxr-xr-x` and the shipped CLI prints
`gpty 0.7.1` / `protocol: 2.0`; and the SLSA provenance attestation's subject digest for the Linux
tarball (`c7cb951c67809fa52a97cead7dc06de7fa02684eb55b655df0cdc82a37a72513`) equals that file's
sha256.

Commits: 7d82adb, 69a133f

## BUILD-28

**The MCP registry entry names a package that can be installed** - the official registry
(`server.json` + `mcp-publisher`) is where MCP-client users browse for servers, and gPTY ships an
MCP server (`gpty mcp`, 22 tools). `server.json` declares `io.github.godot-pty/gpty`, version-synced
with `crates/gpty-cli`, as a `cargo` package, with `packageArguments` `mcp` so a client runs
`gpty mcp` rather than a bare `gpty`; the crates.io ownership token is visible text in
`crates/gpty-cli/README.md` (crates.io strips HTML comments, so the hidden-comment form the docs use
for PyPI/NuGet does not verify). `scripts/mcp-registry check` validates it offline in `ci-check`.
Published 2026-10-26 (run `40373452936`) after `gpty 0.7.0` reached crates.io: read back from
`registry.modelcontextprotocol.io/v0/servers?search=io.github.godot-pty`, the entry is
`active`/`isLatest` and stores the descriptor as written - cargo package `gpty` 0.7.0, the `mcp`
positional argument, the website at `gpty.dev`. Later releases publish themselves:
`.github/workflows/mcp-registry.yml` runs on `release: published` over OIDC (no secret), refusing to
run when `server.json` does not name the released version or the crate is missing from crates.io.

Commits: c44dcd4, c05a913, 0632b4e, 6cecfd6

## BUILD-29

**The knowledge base ships inside release builds** - the vault at `docs/content/wiki` was
repository-only, so a downloaded bundle had no copy of it. `scripts/build-wiki` now packs the notes
into `godot/knowledge.json` (52 notes, content hash), the exporter includes it, and `KnowledgeStore`
seeds it into `user://knowledge/` under the content hash on first use; the built-in **Knowledge
Base** profile opens that copy with the wiki pane through the `@knowledge` token, so no machine path
is stored. A changed bundle seeds a new hash directory instead of overwriting local edits; the
source vault stays authoritative (`scripts/build-wiki --check` in CI, `scripts/build`, and the
release export). Tests: GUT bundle/seed/index/graph, pane-token and shipped-profile tests.

Commits: eadd81a, 6cecfd6

## BUILD-30

**The MCP registry workflow never fires on its own, so every release's registry entry is a manual step** - found
2026-11-01 while cutting v0.7.1: `mcp-registry.yml` triggers on `release: [published]`, but
`release.yml` creates the release with the workflow's `GITHUB_TOKEN`, and GitHub does not start a
run for an event the default token produced - so that trigger cannot fire for any release this
repository publishes. v0.7.1's entry exists only because `gh workflow run mcp-registry.yml` was run
by hand after the crates were live, and the job's own guard (refuse when the crate is missing from
crates.io) means it could not have succeeded at release time anyway, since the crates.io publish is
manual too. Shipped 2026-11-01: the trigger is `workflow_run` on the Release workflow's completion
(`types: [completed]`), gated on a run whose `conclusion` is `success`; that run was started by the
tag push, so the token-suppression rule that killed `release: [published]` does not apply. The
`workflow_run` payload carries no release object, so a first step resolves one from
`github.event.workflow_run.head_branch` — measured on this repository's live runs, v0.7.1 and v0.7.0
each report that tag as `head_branch` with `event: push` — refuses a value that is not a `v*` tag,
fetches `releases/tags/<tag>`, and stops as `publish=false` for a prerelease (a job `if` cannot
query the API). Checkout is pinned to `steps.release.outputs.tag`, so `scripts/mcp-registry check`
reads the released tree's `server.json` rather than the default branch's; a dispatched run keeps its
selected ref and, having no tag, skips the version comparison exactly as before. The descriptor and
crates.io guards are unchanged, so a version whose crates are not live still fails with its named
reason, and the registry stays a separate workflow, so an outage cannot block the artifacts.
Verified locally: `scripts/lint-workflows` passes and the resolve step's three branches were run
against the live API — `v0.7.1` gave `publish=true`/`tag=v0.7.1`, a prerelease payload gave
`publish=false`, and `head_branch=main` gave its named refusal. End-to-end proof is the next tag:
v0.7.2's registry publish must appear with no manual dispatch. A release created outside the Release
workflow now needs the dispatch path, which the workflow's header states.

Commits: 3f129fe, 39085e9

## BUILD-31

**The local Windows cross-check compiles without `--tests`, so a test-only Windows breakage passes here and fails in CI** - found
2026-11-01 by the new `Run gpty-ipc tests` step's first run (`41327889612`): `gpty-ipc`'s test build
had never been compiled on Windows, and `-Dwarnings` failed the job on `test_env::EnvVars`, a
Unix-only guard that was dead code there (unused import plus `never constructed`).
`scripts/ci-check`'s "windows cross-check" runs
`cargo check --workspace --target x86_64-pc-windows-msvc`, which never builds a `--tests` profile,
so every crate's Windows test build is unverified locally - this class of breakage has to reach
GitHub to be seen. Shipped 2026-11-01: the step runs
`cargo check --workspace --tests --target x86_64-pc-windows-msvc` with the same env and
`-Dwarnings`, and CI's native `rust-windows` job runs the same command, so the full workspace's
Windows test profiles are checked on both sides. The new profile surfaced three latent breakages,
all fixed by gating each item the way its users already were: `gpty-ai`'s OMP tests declared the
`TempScript` import, `drain_turn`, `OMP_ENV_LOCK` and `fake_script_path` unconditionally while only
`#[cfg(unix)]` tests use them; `gpty-core`'s engine tests did the same with `Action` and
`wait_for_state`; and `gpty-gdext`'s refused-bind test binds a `tokio::net::UnixListener`, which
does not exist on Windows, so it is `#[cfg(unix)]`. The step also stopped depending on a cached
FFmpeg build-script output — it points `PKG_CONFIG_ALLOW_CROSS=1`/`PKG_CONFIG_PATH` at the host
media prefix `media-deps` already builds, because `cargo check` never links (the real Windows build
and link stay the native job), and it warns when that prefix is missing. Verified with a positive
control: a temporary `#[cfg(all(test, windows))]` module with an unused import passed the old
command and failed the new one in about a second; with it removed the workspace check is clean.

Commits: 8e7d570, 39085e9

## BUILD-32

**No ruleset limits who can create a `v*` tag, which starts the release workflow** - carried from
the row above; not a code change. The API reports `main` unprotected with zero rulesets, while
pushing a `v*` tag runs `export-release`, which holds `contents: write`, `id-token: write` and
`attestations: write` and creates the release, so anyone who can push a tag can publish a release
under the project's identity. Created 2026-11-02 and validated: ruleset `tag` (id 26369813, target
tag, enforcement active) blocks tag creation, update and deletion, blocks non-fast-forward pushes,
and requires signed tags; it covers `~ALL` tags and bypasses only `OrganizationAdmin` (always). The
security goal holds - nobody but an org admin can create a tag, and an admin's push is exactly the
release path. Decided 2026-11-02: `required_signatures` stays and signed tags become the release
procedure - the release skill now creates `git tag -s` and verifies with `git tag -v` before pushing
(and `git tag -f -s` when a tag must move). The clone had no `user.signingkey` configured, so the
first signed release needs a key. The remaining proposal stands: narrow
`conditions.ref_name.include` to `refs/tags/v*` if non-release tags are expected. Add a
`RepositoryRole` maintain bypass only if a non-admin maintainer is to cut releases, and if it is
added, signed tags become mandatory for them. Verification:
`gh api repos/godot-pty/gpty/rulesets/26369813` shows the active rules; no repository test can cover
it.

Commits: 6b45e50, 11f5274, 39085e9

## BUILD-33

**The default branch is protected; Branch-Protection is 6/10, with required checks and admin enforcement still open** - closed
2026-11-02. `main` now requires a pull request with one approving review (code-owner reviews
requested), blocks deletion and force-pushes, requires signed commits and conversation resolution,
and sets `strict` status checks with an empty check list. `enforce_admins` is `false`, so the
maintainer's direct push is the current trunk-based bypass; no CI/Docs/CodeQL check is required. The
first Scorecard run after the change reads **Branch-Protection 6/10** (was 0 on `a84311a`), overall
**7.7**, with "not maximal on development and all release branches"; the remaining work is the
v0.9.3 branch-protection row. Verification: the API returns the settings above; Scorecard's
published result carries the 6/10.

Commits: 39ef2cf, 6cecfd6

## BUILD-34

**Dependencies are checked for known advisories but not for source, licence or duplicate-version policy** - CI
runs `cargo-audit` on the committed `Cargo.lock` and nothing else; there is no `deny.toml`, so a git
or path dependency, a licence the release cannot ship, or a yanked crate passes. Shipped 2026-11-02:
`deny.toml` at the repository root is the policy - `[licenses]` allows the set the graph actually
uses (MIT, Apache-2.0 and its LLVM exception, BSD-2/3, ISC, MPL-2.0, Unicode-3.0, Unlicense, Zlib)
plus the project's own GPL-3.0-or-later, with two named exceptions for the WTFPL FFmpeg binding
crates (the C libraries' LGPLv3 is LICENSE-EXCEPTIONS.md's, not this file's); `[sources]` allows
only crates.io and denies unknown registries and git; `[advisories] yanked = deny`;
`[bans] multiple-versions = warn`; and `[graph] all-features = true` so the local gate and CI check
the same graph. `ci-check` gained a `cargo deny check` step (skips locally when the tool is absent,
fails under CI), and GitHub runs the pinned `EmbarkStudios/cargo-deny-action` (v2.1.1) as its own
job beside `cargo-audit`, which still owns advisories. Verified locally with a throwaway project: a
path dependency licensed BSD-4-Clause fails (`license is not explicitly allowed`) and a `file://`
git dependency fails the source rule (`detected 'git' source not explicitly allowed`); the workspace
itself reports `advisories ok, bans ok, licenses ok, sources ok`, with only duplicate-version
warnings.

Commits: d17bac7, 11f5274, 39085e9

## BUILD-35

**One full gate run leaves 1092 files and directories in `/tmp`, and nothing removes them** - measured
2026-10-31: `ls -d /tmp/gpty-ipc-* /tmp/gpty-plugin-store-*` returned 156 sockets and 936
directories, naming exactly 26 process ids (`gpty-ipc-<kind>-<pid>.sock`, six kinds;
`gpty-plugin-store-<pid>-<case>`, 36 cases) - the serial and parallel `cargo test` passes of one
day's gate runs. Nothing breaks today (the sockets are empty files, the directories a few KiB), but
the count only grows, a bound but never-unlinked `UnixListener` keeps its inode until reboot, and a
full `/tmp` eventually fails a spawn. Fix: one helper that creates a path under
`std::env::temp_dir()` and removes it on drop (a guard struct, or `tempfile::TempDir` if that
dev-dependency is acceptable), used by every test that binds a socket or builds a store, plus an
explicit unlink in the few tests that keep a listener open to prove a behaviour. The fuzz media
target has the same exposure: it writes `gpty-fuzz-media-<pid>.mkv` per input and removes it on
return, so an abort (the OOM it found) leaves one behind; its temp path belongs in the same guard.
Tests: the guard removes the path on success and on panic, and the gate asserts no new `gpty-*`
entries under `TMPDIR` after the suite (count before, count after). Shipped 2026-11-02: the guard is
`tempfile::TempDir` (the row's allowed option), now a dev-dependency of `gpty-ai`, `gpty-cli`,
`gpty-core`, `gpty-gdext`, `gpty-ipc` and `gpty-media`, and a plain dependency of the fuzz
workspace. Every test artifact is created inside one bound to the test body, so it is removed when
the test ends - on success and while a failed assertion unwinds - instead of by a hand-written
`remove_file` at the end that a panic skips. That covers the sockets (server, client, transport,
gdext), the plugin-store trees and plugin-move fixtures, the history and vault SQLite files, the
fake CLI/OMP/Godot scripts, the media fixture files (fifo, symlink, garbage), the CLI marker files,
and `flood_probe`'s database; helpers that used to hand back a bare path now hand back the guard
with it (`temp_vault`, `temp_db`, `temp_scratch`, `scratch`, `test_dir`, `start_server`, `serve_at`,
`start_test_server`, `spawn_socket`, `fake_gui`, `temp_file`), and the hand-rolled guards
(`TempScript`, the vault fixture's `Drop`) became `TempDir` owners. The few tests that keep a
listener open to prove a refusal need no separate unlink: the guard removes the socket after the
listener it owns has dropped, which is the same order a stale path is replaced in. The fuzz media
target writes its per-input MKV in one too; an abort or OOM still runs no destructor, so that one
case is libFuzzer's crash path and is documented in the target rather than papered over. The gate:
`scripts/ci-check` step 4 creates a `mktemp -d` directory and runs *both* cargo test passes with
`TMPDIR` pointing at it (an EXIT trap removes it if the run is interrupted), then step 4.3 fails
with the leftover paths if anything is still in it - an empty isolate rather than a before/after
count of `gpty-*`, so an artifact under any name is caught. Measured 2026-11-02: both passes leave
**0** entries, and a normal workspace run leaves the real `/tmp` count unchanged (429 pre-existing
entries before and after; the 1092 the row counted were accumulated across earlier days' runs). The
gate was also verified by planting a deliberately unguarded test (`std::fs::write` into
`std::env::temp_dir()`, no guard): `ci-check` failed at *temp artifacts* and named
`/tmp/gpty-gate-tmp.<rand>/gpty-leak-probe-<pid>` twice (serial and parallel passes), then passed
again once the plant was removed. Tests: `crates/gpty-ipc/tests/temp_paths.rs` (2 passed) pins
`the_guard_removes_a_bound_socket_on_success` and
`the_guard_removes_a_bound_socket_when_the_test_panics`; the `tempfile` addition costs three
packages in the lock (`tempfile`, `getrandom`, `r-efi`), all MIT/Apache-2.0, and `cargo deny`
reports the same policy as before. `testing.md` states the rule and the gate so a new test does not
have to rediscover it.

Commits: b3e653e, 39085e9, 86622a4

## BUILD-36

**No gate checks that the code a roadmap row cites still exists** - measured 2026-10-31: the chain
pages carry 45 `path:line` citations (40 distinct), and they resolve today only because a reader
checks them by hand - 5 name a repo-relative path, 34 name a bare file name that has to be matched
against the tree, and 1 is ambiguous (the `lib.rs` citation at line 250 in v0.8.md matches five
`lib.rs` files). `scripts/docs-check` validates links, anchors and row shape, but nothing inspects
the evidence inside a row, so a rename or a move turns a row's proof into an unverifiable claim with
every gate green. Existence is the honest test, not line content: tacit's staleness step measures
that the deletion of a subject a fact names is a useful signal while a changed line that merely
shares a name is not. Shipped 2026-11-02: `scripts/docs-check` indexes the repository once (skipping
`target/`, `dist/`, `godot/bin/`, `godot/.godot/`, `fuzz/target/` and the vendored addons), extracts
backticked `path:line` citations from every roadmap row, and resolves each: a token with `/` must
exist as a repo path, a bare basename must name exactly one file, and a missing or ambiguous one
fails with the fix spelled out (the ambiguity message prints the first real path). Existence only,
as the row argued: a line that moved is still evidence, a deleted subject is not. The current set
had three problems, all qualified: the v0.8.md cwd citation at lib.rs lines 250-269 now names the
gdext lib, and this row's own ambiguity example was reworded so the gate does not read its prose as
a citation. Verified with a three-row scratch table: a valid citation passed, a nonexistent file
failed with the missing-file message, and an ambiguous basename failed with the five-file message;
with the scratch removed the gate reports OK over 371 rows.

Commits: f460c31, 39085e9

## BUILD-37

**Supply-chain posture is asserted by our own rules and never read back the way an outside reviewer reads it** - the
repository pins every third-party action to a full SHA, attests every release asset and
checksum-verifies every CI download, but nothing turns those facts into a score. Run OpenSSF
Scorecard once ([ossf/scorecard](https://github.com/ossf/scorecard)) - `scorecard --local .` for the
checks that need no token, or the hosted run with a repository token for the API-backed ones - and
record the result in this row: the checks the existing work should already satisfy
(Pinned-Dependencies, Dangerous-Workflow, Token-Permissions, and Branch-Protection once the `v*` tag
ruleset row lands) read high or explain themselves, and the ones never examined (Signed-Releases
beyond attestation, Fuzzing, a dependency-update bot, Security-Policy) say what a reviewer would
still flag. Set up 2026-11-02: `.github/workflows/scorecard.yml` runs the pinned
`ossf/scorecard-action` v2.5.0 on a weekly schedule, on a push to main, on a branch-protection-rule
change and on dispatch; it uploads the SARIF through the same pinned `codeql-action/upload-sarif`
the CodeQL job uses, publishes the result to the OpenSSF API, and keeps the raw report as an
artifact. Top-level `permissions: read-all`, with only `security-events: write` and
`id-token: write` on the job; `scripts/lint-workflows` passes. The cheap item is done too:
`.github/dependabot.yml` opens one grouped weekly pull request per ecosystem (cargo, the fuzz
workspace's cargo, GitHub Actions), since SHA-pinned actions otherwise never move. The score itself
is the first run after the next push - the artifact and the public API hold it - and its flagged
checks become rows in priority order rather than edits here; that run is the baseline this row's
verification asked for. Baseline (first run, commit a84311a): **6.9**. Checks: Security-Policy 4
(the policy is detected, but Scorecard found no linked URL; the private-reporting URL is added in
this commit and the next run reads it), Signed-Releases 0, Code-Review 0, Branch-Protection 0,
CII-Best-Practices 0, Contributors 0, CI-Tests -1, Packaging -1. Deferred as structural to a
main-only, no-PR, single-maintainer repository rather than defects: Code-Review and CI-Tests need a
pull-request flow AGENTS deliberately does not use; Contributors needs multiple organizations;
CII-Best-Practices needs a badge application; Packaging needs a packaging workflow the release does
not use. The two actionable findings are queued as rows above: a branch ruleset for main, and a
signature/provenance asset on each release.

Commits: f460c31, 39085e9, 8ab21ed

## BUILD-38

**`gut-check` hung on a GDScript parse error instead of failing fast** - observed 2026-10-31 while a
`terminal_manager.gd` edit had a parse error (`Cannot infer the type of "horizontal" variable`): two
`./scripts/gut-check` runs were still alive at a 600 s cutoff, while `testing.md` records that path
as ~1.3 s (the collector breaks into Godot's debugger, exits 0, and the parse-error line is the
signal the script judges). The live smoke reported the same error at once, so the error itself is
visible; the gate's failure mode is the question. Not established: whether headless Godot waits at
the debugger break, or the runs were disturbed by the session's backgrounded shells (the sandbox is
per-run, so socket and user dirs are not shared). Fix: reproduce with a deliberate parse error under
a hard timeout, then run the collector non-interactively or give `gut-check` a watchdog that prints
the parse-error line and fails - a gate that waits hides the error it exists to report. Shipped
2026-11-02: `gut-check` owns the clock. It launches Godot in the background with its output in the
log file and streams that file with `tail -f`, then polls the process: the first `SCRIPT ERROR` /
`Parse Error` / `Failed to load script` line ends the run on the spot (the collector cannot be
judged after it), and `GUT_TIMEOUT` (validated as a whole number, default 600 s) ends it at the
deadline. Both paths escalate SIGTERM → one second → SIGKILL, because Godot does not die on SIGTERM
while a script waits - measured 2026-11-02, `timeout 300` was still alive with its Godot child after
seven minutes, which is exactly how two runs survived a 600 s cutoff. `timeout` is no longer used,
so stock macOS is bounded too; the external `STATUS 124` test became two explicit flags, so the
verdict says which path ended the run. Reproduced the row's failure first: a unit test with
`var horizontal := NotAType.new()` under `GUT_TIMEOUT=60` spent the whole 60 s and only the timeout
produced a FAIL. After: the same file fails in **2 s**, printing both parse-error lines and
`the run was aborted as soon as Godot reported a script/parse error - it cannot be judged`;
`GUT_TIMEOUT=2` on a healthy run returns in 2 s with `exceeded 2s` and leaves no Godot process; the
healthy suite passes (72 scripts, 913 tests, 134 s). `testing.md`'s GUT bullet states the
watch-the-log and SIGTERM→SIGKILL rules. The same session surfaced a separate flake, queued as its
own row below.

Commits: 7b4c782, 5b7e74e

## BUILD-39

**A documentation-only change pays for the whole suite** - measured on a green run: the code
workflow ran all eight jobs for any push (~4 minutes warm, up to ~30 when the Windows vcpkg tree
rebuilt), and `scripts/ci-check` ran nine gates - GUT and the live smoke included - for a roadmap
edit, on every pre-push. Both now make the same split: `ci.yml` ignores docs-only changes
(`docs/**`, `**/*.md`, `godot/knowledge.json`, `LICENSE`; `paths-ignore` skips only when every path
matches, so a mixed commit still runs everything), and the local gate detects the same set and runs
just `docs-check` + `build-wiki --check`. The docs-only push's gate is the Docs workflow, which now
also verifies the knowledge bundle - until this change that check existed only in the local
pre-commit hook, so a stale bundle could reach main with CI green. Local detection is conservative
and judges what is being validated: the push range from the pre-push hook (`CI_CHECK_RANGE_FROM`,
which wins over an exported `CI`), the index under `--fast`, the unpushed commits plus working tree
for a manual run, and the full suite whenever the set is empty or unknown; `CI_CHECK_FULL=1` forces
it. Verified: a docs-only commit starts no CI run and its Docs run passes; a docs-only pre-push
prints the banner and runs two gates; a code commit still runs the full local suite and all eight
jobs. Found on the way: the installed pre-push hook was a stale *copy*, so `githooks/` edits never
took effect - `scripts/install-hooks` replaced it with the symlink, and the contributing note says
so. Extended 2026-10-31 after a `scripts/docs-check` edit dragged the whole suite: the class is now
"only gates the Docs workflow runs", which adds `scripts/docs-check` and `scripts/build-wiki` to
both lists (the Docs job executes both), keeps every other script on the code side (each one builds
the app, drives Godot or runs a gate), and never splits Rust from Godot because the GDExtension is
one boundary; `./scripts/ci-check --classify` prints the changed set and the suite it selects
without running anything. Verified both ways in a scratch worktree: a docs-plus-gate-script commit
takes the two-gate path in seconds, a `crates/` commit takes the full suite.

Commits: f3d5343, f460c31

## BUILD-40

**CI spends most of its time rebuilding things it already built** - measured on a green run
(`5df60a0`, all eight jobs): wall clock 413 s, with `windows-smoke` 413 s, `gut-tests` 295 s,
`rust-tests` 204 s and `cargo-audit` 182 s. Three line items, and two of them were cache defects
rather than cost. (1) `windows-smoke` recompiled **every** dependency (150 s) *after a cache hit*:
its `target` cache shared a key with `rust-windows`, which populates it with `cargo check`
artifacts, and a check-shaped target can never satisfy a `cargo build` - a save only happens on a
miss, so the build-shaped snapshot was never written. The two jobs now use `-cargo-build-` and
`-cargo-check-` keys. (2) `gut-tests` and `rust-tests` each built the pinned FFmpeg from source
every run (~105 s and ~112 s); the 11 MB built prefix is now cached under
`hashFiles('scripts/media-deps', 'crates/gpty-media/components.txt')`, and `media-deps`'s `.stamp`
(version, components checksum, platform, assembler) still decides whether to skip, so a stale entry
costs a rebuild and never correctness. (3) `cargo-audit` spent 173 s of its 182 s job compiling
`cargo-audit` and 3 s running it; the pinned binary is cached under its version key and a miss still
builds it from crates.io with `--locked`. Measured on a rerun of the same commit (warm caches):
`windows-smoke` **268 s** (build 150 -> 28), `gut-tests` **197 s** (media deps 105 -> 0, cache
restore 2 s), `rust-tests` **93 s** (112 -> 0), `cargo-audit` **14 s** (173 -> 0), so wall clock
**413 -> 268 s** with no test removed and no pin relaxed - the FFmpeg tarball is still
SHA256-verified on a build, the audit tool's version is in its cache key, and every action SHA is
unchanged. What is left: `windows-smoke`'s GUT step (131 s) is now the largest single piece, and
splitting it would need `gut-check` to run and judge one directory at a time; the Linux Godot
download (7 s, and a network dependency that failed once) could be cached by its SHA512 while still
verifying the archive. Neither is worth the churn yet. The tell if a cache is evicted rather than
cold is the `Cache …` step's `Cache not found for input keys` line together with that step's time
coming back (`Build CLI and extension` 28 s -> 150 s, `Build media dependencies` 0 s -> 105 s);
`gh api repos/godot-pty/gpty/actions/caches` lists the live keys and sizes, and a miss right after a
`Cargo.lock` or `scripts/media-deps` change is expected rather than a fault. No alert is configured
for it: the miss is expected on every lock change, so a warning would be noise.

Commits: 6954091, 03ed949

## BUILD-41

**The README's health signals did not match the project's actual posture** - the first badge line
carried a Reddit subscriber badge (a community metric, now in the site's navbar) and no OpenSSF or
SLSA signal. Added a second centered line with the OpenSSF Best Practices badge (project 16201; the
badge read **in progress** at capture and now reads **passing**, 2026-11-02) and **SLSA Build Level
2** - the level GitHub documents for artifact attestations by themselves, which is what
`release.yml` uses (`actions/attest-build-provenance` in the same job, not the reusable-workflow
isolation that would claim L3). The SLSA badge links to a new `### Verifying releases` anchor, so
the claim points at the `gh attestation verify` instructions rather than the top of the README. The
Status section gains one paragraph naming OpenSSF Scorecard, Best Practices, SLSA L2 and the pending
LFX application, so the badges are not the only statement of intent. Evidence: both badge URLs
return 200 (`bestpractices.dev` aria-label is now `passing`; `slsa.dev` aria-label is `level 2`),
and `docs/assets/repo/README.md` is the mirrored copy.

Commits: 2ba3a60, 39ef2cf

## BUILD-42

**The release screenshot script captures a doomed second instance when a GUI is running** - fixed
2026-11-03: `scripts/ui-sandbox` creates one 0700 temp root and exports `HOME`,
`XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME`/`XDG_CACHE_HOME`/`XDG_RUNTIME_DIR`,
`GPTY_TEST_USER_DIR` and `GPTY_SOCKET`, and clears `GPTY_SECRET` plus
`BASH_ENV`/`ENV`/`PROMPT_COMMAND`/`PS1`/`PS2`/`CDPATH`/`HISTFILE` (a pane's shell no longer reads a
personal `.bashrc` into the image). `scripts/screenshot-gpty`, `scripts/ui-capture` and
`scripts/ui-capture-check` all source it, so a capture never depends on the developer's desktop
state. Verified 2026-11-03 while a real gPTY 0.7.2 GUI owned the desktop's control socket: the full
capture check (27 staged launches) ran normally, and `--state` waits for the harness's ready file so
the frame is captured after staging instead of on whatever frame the window first showed. Found
2026-10-19 while capturing the v0.6.0 screenshot.

Commits: d17bac7, 6cecfd6, 113afd7

## BUILD-43

**`ui-capture-check` refuses a state subset that leaves out `settings`** - found 2026-11-06 while
adding the `file-dialog` capture state: the usage line is
`scripts/ui-capture-check [--keep <dir>] [state...]`, but `PERTURB` is fixed to `settings`, so
naming any other state alone fails with `perturb state 'settings' is not in the state list` instead
of checking the state the caller named - the natural invocation for one new state cannot run. Fix:
default `PERTURB` to the first state in the list (or add a `--perturb` flag), so the locality half
stays meaningful for any subset. Fixed 2026-11-06: `PERTURB` defaults to `settings` when the list
has it and to the first named state otherwise (`--perturb` still overrides), and a perturbed capture
of a state with neither an overlay nor a pane no longer silently no-ops - `_perturb(state_name)`
fails with `state '<name>' has no overlay or pane to perturb`, and the check reports "no perturbed
capture produced an image" instead of restating that as "the perturbed control changed no image".
Verified on the development build: `scripts/ui-capture-check --keep <dir> file-dialog` passes (two
runs pixel-identical, only `file-dialog` changed, 11 s), `settings sidebar` still perturbs
`settings`, `empty-workspace` exits 1 with the harness's own sentence, and `bash -n` is clean.

Commits: 0681359, 5ce59b2

## BUILD-44

**The capture harness can hang forever with a blank, uncloseable window** - found 2026-11-04 by the
operator while `scripts/ui-capture-check` ran: one launch (`window-800x500`, the sixteenth of the
run) stalled during engine start-up - its log ends after the Vulkan device line, before any project
code runs - and left a blank 800x500 window whose event loop never ran, so the window ignored its
close request and the check had made no progress for 23 minutes. It does not reproduce (the same
state captures in 3 s, and nothing in the project is executing at that point), so the stall is an
engine/display start-up one; what was the harness's own defect is that nothing bounded it.
`scripts/ui-capture` now bounds each launch (`CAPTURE_TIMEOUT`, default 120 s) with TERM then KILL,
prints `produced no result in Ns - killing the launch`, and exits non-zero, which `ui-capture-check`
already reports as a failed state. Verified: a normal capture writes its PNG in about 3 s,
`CAPTURE_TIMEOUT=1` kills a launch and exits 1 with no process left behind, and the bound covers
both capture and `--audit-focus` launches (`--hold` stays unbounded on purpose: it waits for the
desktop grab).

Commits: cf9a0cc

## BUILD-45

**The focus audit stops inside the first keyboard ring** - closed 2026-11-06:
`KeyboardFocus.tab_components(controls)` maps the whole traversal - every control not yet claimed is
walked through `find_next_valid_focus()`, each walk stopping at null, at a control another component
claimed, or when it returns to its own first member (`closed`, i.e. an explicit ring) - and
`_audit_focus` prints the first component as `tab-order` and each later one as `ring[n]`/`flow[n]`,
then `components=/rings=/reached=`. Measured on `wiki-vault` with this build: 3 components, 1 closed
ring, 83 of 83 focusable controls reached (the old walk printed 5), with the pane-chrome ring and
the wiki note toolbar's flow named separately. `test_keyboard_focus.gd` pins two rings as two closed
components and a second start inside a ring adding nothing.

Commits: b499d7c, 6918477

## BUILD-46

**The colour-override census is a gate, not a convention** - closed 2026-11-05:
`scripts/check-theme-tokens` (python3, the `check-log-hygiene` mould: docstring, exit 0/1, reads
only) scans `godot/scenes/**/*.gd` and fails a line that calls `add_theme_color_override` or reads
`UiPalette.active()` at class-body level - field and `const` initializers, `@export` defaults,
inner-class fields, and a class-level lambda body, decided by an indentation stack that a `func`
opener interrupts, so an in-function read (the correct per-call read) passes. `# theme-ok: <why>` on
the line or within the three above is the reviewed exception, the way `// log-ok:` works.
`scripts/ci-check` runs it as step 3.3 in the fast suite, and `docs/content/docs/agents/gdscript.md`
names it next to the grep census. The check starts clean because the seven `settings_manager.gd`
chrome field initializers and the seven `load_settings` fallbacks now route through
`static func _chrome_default(key)`, which reads the existing `CHROME_COLOR_TOKENS` table, so that
table is the one place a setting's default token is written. No allowlist was needed for the two
sources the row anticipated: the palette's own tables are built inside functions and the contrast
test lives under `godot/tests`, so the `godot/scenes` scan is clean as it stands. Verified:
`check-theme-tokens: no cached palette colours in 57 GDScript files`, and a fixture self-test
reports the override, the indent-0 field read, an inner-class field and a class-level lambda body
while a `# theme-ok:` line and an in-function read report nothing. The gate runs only in the local
suite; closing that cloud gap is the v0.9.4 row **The static gates run only in the local pre-push
suite, never in CI**.

Commits: 017e1cb, 611b8f0, 8205717

## BUILD-47

**The screenshot script hung on a capture backend that cannot grab, and `set -e` hid it** - found
2026-11-06 while capturing this release: `scripts/screenshot-gpty` preferred ffmpeg's
`x11grab -window_id`, which on this XWayland session attaches to nothing and says nothing (measured:
no output in 30 s where ImageMagick's `import` produced the frame immediately), and the call sat
bare under `set -e`, so the `timeout` guard that was meant to bound it aborted the script instead of
letting the fallback run - a full run ended after the window wait with exit 124 and empty stderr.
Fixed 2026-11-06: the backends are a list tried under `CAPTURE_TIMEOUT` (`SCREENSHOT_TIMEOUT`,
default 20 s) inside an `if`, so a failing or timed-out backend hands over instead of aborting;
`SCREENSHOT_CAPTURE=ffmpeg\|import` pins one; and the failure names every backend tried. Verified by
capturing all six `v0.8.0_<n>.png` images on this machine (ffmpeg timed out, `import` captured).
Known, not fixed: a hard kill of the script (`timeout`, Ctrl-C at the wrong moment) still leaves the
sandboxed app running, because the `EXIT` trap does not run on `SIGTERM`; the leaked window was
killed by hand after this release's captures, and the hang that forced those kills is gone.

Commits: ae22ac5

## BUILD-48

**A CLI test depended on a process-global version-probe latch, so the parallel cargo pass failed** - found
2026-11-09 while running the full gate for the history-search keyboard work: `cargo test (parallel)`
failed in `crates/gpty-cli/src/tests.rs::plugin_commands_probe_the_gui_version_first` with
`probes == 0`. `daemon::VERSION_OBSERVED` was one process-wide `AtomicBool`, so whichever test read
a `version` response first silenced every later probe; `reset_version_latch` cleared it, but a
concurrently running test could set it again between that reset and the probe, and the assertion
(`== 1`) then saw zero. The latch is now keyed by endpoint (`Mutex<Vec<String>>`, the path every
call site already passes): production has one endpoint and still probes once, while a test's own
socket cannot be observed by another test's probe, so the test is deterministic. `VERSION_WARNED`
stays process-global - the mismatch is a property of the binaries, not of the command. Evidence:
`cargo test -p gpty --bin gpty` passes 112/112 with default parallelism three runs in a row (and
112/112 with `--test-threads=1`); the serial pass already passed, only the parallel one failed
before the fix.

Commits: 5f8e818

## BUILD-49

**Back-to-back docs pushes make the Docs workflow fail at its deploy step** - fixed 2026-11-10.
Found 2026-11-09 while closing the history-search keyboard work: three docs pushes in one session
produced two red `Docs` runs, both failing only at `Deploy to GitHub Pages` while every content step
passed (`check markdown`, the knowledge-bundle check, the Hugo build, the three render
verifications). Two distinct causes, one per failure: the newer run was refused with
`Deployment request failed … due to in progress deployment. Please cancel <sha> first or wait for it to complete`
(400), and the earlier one asks for artifact metadata immediately after `upload-pages-artifact`
reports success and gets `Found 0 artifact(s)` (runs 42688595589 on `ac5fd0a`, 42690667476 on
`71c04e8`). `gh run rerun --failed` was not a recovery path either: re-running the job uploaded a
second `github-pages` artifact into the same run, and the deploy then died with
`Multiple artifacts named "github-pages" were unexpectedly found … Artifact count is 2` (run
42690667476 on `71c04e8`); only a fresh run deployed. Fix: a workflow-level
`concurrency: group: pages, cancel-in-progress: false` queues runs instead of racing them; the
content steps and `Upload pages artifact` stay in `build` under `contents: read`, and the new
`deploy` job (`needs: build`, `timeout-minutes: 15`, `actions: read` + `contents: read` +
`pages: write` + `id-token: write`, `environment: github-pages`) holds only `actions/deploy-pages`,
so a `--failed` rerun touches it alone; a wait step polls the run's artifact list (30 × 2 s) for
exactly one `github-pages` artifact first, which is the 0.39 s case handled instead of met by luck -
run 42688595589 was the only live run when its deploy queried at 19:59:37.693 and answered
`Found 0 artifact(s)` at 19:59:37.790, the next run being created at 19:59:42. `workflow_dispatch`
was already present (added in `7d09e0c`), so no retry switch was added; both Pages actions keep
their pinned SHAs. Measured on the acceptance pair, pushed 10 s apart: run 42908063437 (`9cd8b13`)
created 21:45:11Z, build 21:45:14→21:45:28, deploy 21:45:36→21:45:49, `success`; run 42908091183
(`64866cb`) created 21:45:21Z but queued until the first finished, its build starting 21:45:52 - two
seconds after the first run ended - then deploy 21:46:09→21:46:56, `success`. No job of the two runs
overlapped, the `github-pages` deployments were recorded in order (`9cd8b13` at 21:45:28, `64866cb`
at 21:46:04), so the newer sha deployed last.

Commits: 0284b88, ba97924

## BUILD-50

**Rebuilding with a GUI open kills it with SIGBUS** - found 2026-11-13, twice in one session:
`scripts/build` copied the new `libgpty_gdext` over `godot/bin/` with `cp`, and a running
`godot --path godot` that had that library mapped died on the write
(`fish: Job 1, 'godot --path godot' terminated by signal SIGBUS (Misaligned address error)`), taking
every pane in it down. Fix: the install writes `$LIB_DST.new`, chmods it and renames it over the old
name, so a process that already mapped the library keeps its inode and no build can kill a GUI.
Verified by rebuilding with a dev GUI running.

Commits: 09c2da2

## BUILD-51

**The export still rewrites `dist/gpty` under a running export** - fixed 2026-11-13, found while
fixing **Rebuilding with a GUI open kills it with SIGBUS**: the library install was atomic, but
`scripts/build`'s Godot export wrote `dist/gpty`, `dist/gpty.pck`, the exported
`libgpty_gdext.linux.x86_64.so` and the bundled FFmpeg libraries in place, so a `dist/gpty` instance
(the accessibility probe's, a demo recording's, a user's copy) that had them mapped died with the
same SIGBUS. `scripts/build` now exports into `dist/.stage.XXXXXX` (on `dist/`'s own filesystem, so
every later `mv` is a rename), bundles the media runtime there, and installs the finished set entry
by entry through one `install_atomic` helper - a file renamed over the old name, a directory
(`dist/licenses`) renamed aside first and the old one then removed - which the `godot/bin/` install
uses too, so a failed export leaves the previous build untouched. `dist/` stays a mixed directory
(`aur/` tracked, `ffmpeg/` the pinned inputs), which is why the set is installed entry by entry
instead of swapping the directory. Verified against a sandboxed running export, its maps read with
`GPTY_ALLOW_DEBUG=1` (the app clears `PR_SET_DUMPABLE`): one pane created, then `./scripts/build`
under it - rc 0, process alive, `list-panes` still answering with that pane, all 7 files it had
mapped (`dist/gpty`, `libgpty_gdext`, the five `libav*`/`libsw*`) reading `(deleted)` in
`/proc/&lt;pid&gt;/maps` while the on-disk inodes moved (gpty 808996 → 809031, pck 808997 → 809032,
gdext 808999 → 809034), no `dist/.stage.*` left, `dist/aur` and `dist/ffmpeg` untouched; the
installed bundle then launched fresh, spawned a pane, injected and matched a marker through
`pane-wait`, and `daemon stop` exited cleanly with no error in its log. pitfalls.md carries the
trap.

Commits: af03ed0, fa51ab1

## BUILD-52

**The sandbox cleanup leaves the caller's shell without `HOME`** - fixed 2026-11-13:
`gpty_sandbox_init` records every variable it overrides or unsets (`HOME`, the five XDG paths,
`GPTY_TEST_USER_DIR`, `GPTY_SOCKET`, and the secret/prompt list), keeping the "was unset" case, and
`gpty_sandbox_cleanup` puts each back instead of unsetting it — so a shell that sandboxed and
cleaned up no longer meets `HOME: unbound variable` in the next `set -u` script (measured
2026-11-13: `./scripts/build` died at its export-template check, and the failed build is what left
`godot/bin` half-installed). Verified by a round trip that asserts `HOME` and `XDG_DATA_HOME` come
back exactly as found, including the unset case.

Commits: 3d0331a, 09c2da2

## BUILD-53

**The defect-class check is a manual release step, so a release can ship an undeclared fix** - found
2026-11-15 while wiring the check into the release; fixed in the same session:
`.github/workflows/release.yml`'s `export-release` checkout fetches full history (`fetch-depth: 0`)
and runs
`./scripts/fix-forensics --check --since "$(git describe --tags --abbrev=0 --match 'v*' HEAD^)"`
before the export, falling back to `--check` on the first release. A failure stops the export job
before any release archive is created, and the previous tag is computed, so every `v*` tag runs the
right range with no version to maintain.

Commits: d1ccbbb, bfa1803

## BUILD-54

**The capture harness compiles before autoloads, so pane-bearing states capture bare pane bodies** - found
and fixed 2026-11-16 (build 0.8.4), reproduced on `HEAD` as well as the fix build.
`godot/tests/bench/ui_capture.gd` is a `-s` SceneTree entry point, which compiles before autoloads
exist; a typed `AgentBadge` and a static `A11y.VALUE_META` pulled `agent_badge.gd` ->
`accessibility.gd` -> `PaneBody` -> the `PaneCwdStore` autoload, so the entry point failed with
`Identifier not found: PaneCwdStore` (reported at `pane_body.gd:201`). The image was still written,
with every pane body a bare `Control` (`Parameter "p_script->implicit_initializer" is null`, then
`Control (TerminalPane)` for `pane_label`), which is why `palette-commands`, `settings` and
`first-launch` captured the Getting Started guide where a terminal belongs; `ui-capture-check`
passed because it compared two equally broken images. Fixed: the badge lookup is untyped
(`get_node`) and the accessibility constant comes from `load("res://scenes/ui/accessibility.gd")` at
runtime, so the entry point's compile graph stops before a script that names an autoload;
`scripts/ui-capture` now keeps the engine log and exits 1 on `SCRIPT ERROR` or
`Failed to load script`, so a capture cannot be produced by a script that did not compile (tested
with a fake engine that prints one: exit 1). Verified: the `settings` and `palette-commands`
captures now show the restored terminal behind the overlay, and `ui-capture-check` passes both
states and the `settings` perturb.

Commits: c6d0d8f

## BUILD-55

**A release CLI is installed by linking the download, so an upgrade leaves a dangling `gpty` on PATH** - found
2026-11-15 from an OMP start-up failure,
`MCP server failed to connect: gpty [config: /…/mcp.json]: Executable not found in $PATH: "gpty"`:
`~/.local/bin/gpty` was a symlink into `/mnt/App/gpty-cli/`, a directory cleaned up months earlier,
so `ls` showed the link and `execvp` found nothing - the same message a missing binary prints.
`scripts/install-cli` owns one stable layout instead: it copies a bundle (an extracted directory or
the release `.tar.gz`) to `$GPTY_INSTALL_ROOT/<version>` (default `~/.local/opt/gpty`), repoints
`current` at it, and links `~/.local/bin/gpty` and `gpty-gui` through `current`, so an upgrade is
the same command with the newer bundle and no download path is ever a PATH entry; `--keep N` prunes
old versions (default 2), `--force` replaces a regular file or a different same-version bundle, and
`--check` prints the install, every `gpty` on PATH in order (dangling / behind / the one `execvp`
would run) and answers an MCP `initialize` through that CLI, exiting 1 when the lookup does not
reach the install. Verified 2026-11-15 in a scratch root: 0.8.3 → 0.8.2 → 0.8.0 rotated `current`
and pruned to the two newest, reinstalling the same tarball was a no-op, a 0.5.5 CLI placed earlier
on PATH made `--check` exit 1, a dangling-only PATH and a missing `bin/gpty` each exited 1, a
regular file at `bin/gpty` was refused without `--force`, and the real install
(`~/.local/bin/gpty -> ~/.local/opt/gpty/current/gpty`, 0.8.3) answered `initialize` and listed its
27 tools; `--check` then exits 0. Documented in CONTRIBUTING's CLI section, the README CLI section
and `skill://gpty-omp-integration`.

Commits: ad82705, a4248de

## BUILD-56

**`scripts/install-cli` has no syntax gate** - fixed 2026-11-16 (build 0.8.4): the installer joined
both tooling lists in `scripts/ci-check` - `run_tooling_scripts`' `bash -n` loop (the gate that
executes it) and `tooling_class_path` (the list that makes a change to it a tooling-class range
instead of a full suite that never runs it) - and the section comments now say "tooling scripts"
instead of "the measurement scripts". `docs/content/docs/agents/testing.md`'s tooling-class
paragraph lists all five scripts (it was already missing `scripts/fix-forensics`), says the shell
checks include the installer, and names the two lists that have to agree. `./scripts/ci-check` in
full prints `pass bash -n scripts/install-cli`, and `bash -n` on a copy with a planted `if then`
fails with a syntax error at that line.

Commits: 9f73b97, 3750b6f, 4abae25

## BUILD-57

**The docs module pins Go 1.26.5 and Hextra 0.12.3, so LFX lists its standard-library CVEs** - found
2026-11-16 from the LFX Security page: every open vulnerability pointed at `docs/go.mod`. Fixed
2026-11-16 (build 0.8.4): `docs/go.mod` declares `go 1.27.4` (current stable) and
`github.com/imfing/hextra v0.13.0`; `.github/workflows/docs.yml` installs Hugo 0.170.0 (extended,
SHA-256 `0930754ec22ad2dd1a252f8c31a5e57faccc9d15f1c3d381ddafcb96eeb8aef0`) instead of 0.164.0.
`hugo mod tidy` refreshed `docs/go.sum`; the site builds 206 pages on Hugo 0.170.0, the search
trigger renders, and the stale `docs/layouts/_partials/favicons.html` override was deleted so Hextra
0.13's dark-favicon script gets its `favicon-svg` id. Why: LFX scans the Go directive for
standard-library advisories; Hextra is the module's only dependency.

Commits: 54e1924

## BUILD-58

**The release flow commits straight to `main` because there is no integration branch** - found
2026-11-16 while wiring OSPS-AC-03.01: every commit landed on `main`, so the release branch was also
the development branch and a release PR had nothing to carry. Fixed 2026-11-16 (build 0.8.4):
`0.8.x` is the 0.8 integration branch; `.github/workflows/ci.yml` and `secret-scan.yml` run on `0.*`
pushes; `scripts/bot-token`, `scripts/bot-push` and `scripts/bot-pr` mint and use the `gpty-bot`
installation token without putting it in argv; and the release skill, `GOVERNANCE.md` and
`CONTRIBUTING.md` describe the release-train flow - day-to-day work on `0.8.x`, a bot-opened release
PR to `main`, a merge commit, a signed tag on `main`, and a fast-forward of `0.8.x` after the
release. The main ruleset that enforces it is the row **A direct push to `main` is still possible
because the only branch ruleset covers tags**.

Commits: 6ca4ee7

## BUILD-59

**The macOS bundle ships FFmpeg built for a newer macOS than the app declares** - fixed 2026-11-16
(build 0.8.4): the v0.8.3 macOS asset was measured by parsing its Mach-O load commands: arm64 FFmpeg
had minos 26.0.0 and x86_64 15.0.0, while the Godot app template itself is 11.0/10.13.
`scripts/media-deps` now builds FFmpeg with `-mmacosx-version-min` 11.0 (arm64) / 10.13 (x86_64) and
exports `MACOSX_DEPLOYMENT_TARGET`; `scripts/check-macos-minos` parses
`LC_BUILD_VERSION`/`LC_VERSION_MIN_MACOSX` and gates every slice in `scripts/bundle-media`; the
x86_64 preset minimum moves from 10.12 to 10.13; `macos_libs` lipos only canonical files and
recreates the alias symlinks instead of shipping three real copies per library (the v0.8.3 zip was
95.7 MB); a failed ad-hoc codesign now fails the job; the release runners are `macos-15` and
`macos-15-intel`. Tests: `check-macos-minos` exits 1 on the v0.8.3 `libavcodec` (26.0/15.0) and 0 on
the GDExtension (11.0/10.12); the next macOS release must report 10.13/11.0. **Correction
2026-11-16, measured on the published v0.8.4 archive:** the minos half is proven -
`scripts/check-macos-minos` reports 10.13/11.0 on every FFmpeg slice of `gpty-v0.8.4-macos.zip`, and
the extension at 10.12 is more permissive still - but the alias half did not reach the asset: the
zip carries three real copies of each library and grew from 95,698,840 to 96,084,344 bytes. Two
causes: `actions/upload-artifact` dereferences symlinks (visible on the `gpty-macos-ffmpeg` artifact
itself), and FFmpeg's unversioned `libavcodec.dylib` is a real file that `macos_libs` lipo'd as a
second canonical copy. The remaining work is **The macOS archive still carries three real copies of
every FFmpeg library**.

Commits: 33f1159, cbed056

## BUILD-60

**The 0.8.x integration branch runs no code gate and docs are validated only after merge** - fixed
2026-11-16 (build 0.8.4): the `integration protection` ruleset (id 27412444) blocks deletion and
non-fast-forward pushes and requires signed commits on `0.*`; `.github/workflows/ci.yml` and
`codeql.yml` now run on pull requests targeting `0.*`; the required `docs` job runs `docs-check`,
`check-capabilities` and the knowledge-bundle check; `.github/workflows/docs.yml` builds on pull
requests and `0.*` pushes with the Pages deploy guarded to `main`; the `commit-lint` job enforces
DCO and Conventional Commits on human commits. Tests: the workflow linter passes; `docs-check`,
`check-capabilities` and `build-wiki --check` pass; the next pull request to `0.8.x` shows the CI,
CodeQL and Docs runs.

Commits: 33f1159

## BUILD-61

**The platform and CI tail: Windows FFmpeg version, cache eviction, mcp-registry ref, concurrency/timeouts, artifact asserts, macOS dylib duplication and docs API rate limit** - fixed
2026-11-16 (build 0.8.4): the Windows build verifies the installed vcpkg FFmpeg version 9.0.2 before
packaging and records the actual port revision (the runner's vcpkg checkout cannot resolve a
manifest `builtin-baseline` commit, so the version is the enforced compatibility and licensing
contract); the `.stamp` skip path falls through to the vcpkg install when the vcpkg tree is missing;
`mcp-registry` refuses a dispatch outside `main`/`v*`, requires the exact `io.github.godot-pty/gpty`
server name and waits on the `release` environment; `ci`, `release`, `secret-scan` and `scorecard`
have concurrency groups; every job has a timeout; runners and toolchains are pinned (`ubuntu-24.04`,
`windows-2025`, `macos-15`, Rust 1.96.0, nightly 2026-11-01); the release staging step asserts the
expected GDExtension files; `scripts/check-macos-minos` and the dedupe are in
`scripts/bundle-media`; `docs/setup.sh` uses `GITHUB_TOKEN` when the Docs build provides it. Tests:
the workflow linter passes, the Python/bash syntax checks pass, and the API readbacks report the
pinned settings.

Commits: 33f1159, 68a34f1

## BUILD-62

**The tag ruleset forbade creating a tag, so no release could be tagged** - found and fixed
2026-11-16 while cutting v0.8.4: pushing `v0.8.4` was rejected with "Cannot create ref due to
creations being restricted". The `tag` ruleset (26369813) carried the `creation` rule with
`bypass_actors: []`, and `creation` restricts ref creation to bypass actors - with none, nobody can
create a tag, the admin included; `scripts/check-github-settings` asserted the wrong set in the
other direction (`TAG_RULES` *required* `creation`), so the gate passed while the policy it guards
made every release impossible. Fixed in the same session: the ruleset keeps
`deletion`/`non_fast_forward`/`update`/`required_signatures` - a tag must be signed and cannot be
moved or deleted - and drops `creation`, and `TAG_RULES` matches it, so the exact-set comparison
catches the drift in either direction. Verified: `./scripts/check-github-settings` prints OK over
all 30 checks and the `v0.8.4` tag pushes.

Commits: d8b8f9a, 8c58684

## BUILD-63

**The macOS archive still carries three real copies of every FFmpeg library** - found 2026-11-16
verifying the published v0.8.4 asset: `zipinfo` shows `libavcodec.dylib`, `libavcodec.63.dylib` and
`libavcodec.63.1.102.dylib` as three regular ~9.29 MB files, and the sizes differ (9,294,432 vs
9,294,384), so they are not even dereferenced copies of one file. `macos_libs` skips symlinked
source names, but FFmpeg ships the unversioned name as a real file and lipos it into a second
canonical, and `actions/upload-artifact` dereferences the `.63` alias on the way to `macos_zip`.
Fixed in code the same session, not yet proven: `scripts/bundle-media` gained `normalize_aliases`,
which derives `<name>.<major>.dylib` and `<name>.dylib` as symlinks from the canonical
`<name>.<major>.<minor>.<patch>.dylib`, replaces a real file sitting at an alias name, and runs both
at the end of `macos_libs` and in `macos_zip` after the transported tree is copied into the bundle;
the lipo loop now skips the unversioned name so it never becomes a second canonical. Verified
offline on a synthetic flattened tree - one real file, two symlinks, `libgpty_gdext.*` untouched -
and `bash -n` is clean. The proof is this release's macOS archive showing one real file and two
symlinks, now measured: **closed 2026-11-17 on the published `v0.8.5` archive** -
`zipinfo -l gpty-v0.8.5-macos.zip` shows `libavcodec.63.1.102.dylib` as the only real file with
`libavcodec.63.dylib` and `libavcodec.dylib` as `lrwxrwxrwx` (stored, 25 bytes), and all five
libraries follow the shape (5 real files, 10 links, where v0.8.4 had 15 real); the zip shrank
96,084,344 → 83,989,869 bytes, and `scripts/check-macos-minos` still reports 11.0 on every arm64
slice and 10.13 on 15 of 16 x86_64 (the extension itself is 10.12).

Commits: cbed056, 8c58684, 12020ad

## BUILD-64

**The test harness recursively deletes the working tree when a fixture path is empty** - fixed
2026-11-19: extracted `TestPaths.is_safe_user_path` and `TestPaths.remove_tree` in
`godot/tests/helpers/test_paths.gd`, which strictly validates that target paths are real absolute
paths inside `TestPaths.user_dir()` and refuses empty strings, whitespace, relative paths (`.`,
`..`), virtual schemes (`res://`, `user://`), filesystem roots (`/`, drive roots), and the
`TestPaths.user_dir()` root itself. Replaced all seven unsafe local `_remove_tree` copies
(`test_wiki_pane.gd`, `test_file_tree.gd`, `test_media_files.gd`, `test_pane_file_sinks.gd`,
`test_media_pane.gd`, `test_pane_open_request.gd`, `test_scroll_hints.gd`). Tests: 9 unit tests in
`godot/tests/unit/test_test_paths.gd` proving refusal on unsafe paths, safe non-existent path
handling, single-file deletion, and nested directory tree cleanup; all 184 tests across the 8
affected test files pass.

Commits: 80eebf6, f8d4419

## BUILD-65

**The Windows GUT gate failed because the fixture helper refused every path, not because of the runner image** - found
2026-11-20 by CI run `44648884305` (attempts 1 and 2) on `1d6f2e5`: `windows-smoke`'s GUT step fails
in `test_file_tree.gd` (`test_an_empty_folder_keeps_its_own_sentence` expects `This folder is empty`
and reads `""`, lines 81-82; then `[2] expected to equal [1]` and
`["a.txt"] expected to equal ["sub"]`), the note save/preview tests
(`the save must reach the file`), and `TestPaths.remove_tree`
(`remove_tree must succeed on fixture inside user_dir`,
`fixture directory must no longer exist after removal`); the suite then aborts with
`SCRIPT ERROR: Out of bounds get index '0' (on base: 'Array')`, which `gut-check` reports as an
untrustworthy run. Two variables moved since the last green CI (`44541260540`, `80eebf6`, image
20261103.629): the runner image is now 20261111.635, and `f8d4419` added
`godot/tests/helpers/test_paths.gd` with the `TestPaths.user_path`/`remove_tree` fixtures
`test_file_tree` and the note tests now use. The image was not the cause: `f8d4419` landed *after*
the last green Windows run, so the helper had never run on Windows, and the `:188` line in that log
is the GDScript backtrace of the expected `push_warning` from
`test_a_failed_write_leaves_the_previous_file_intact`, not a failure (the script tallied 7/13 with
the file-mode tests pending). Cause (`platform-parity`): `TestPaths.is_safe_user_path` compared
`_normalize_path(child)` with `_normalize_path(root)`; on Windows the root arrives from
`GPTY_TEST_USER_DIR` as `C:\...\user` (no `/` after the drive) and `path_join` appends `/`, and
`String.simplify_path()` keeps the drive separator exactly as written - the root normalised to
`C:/...` and every child to `C:\...`, so the prefix compare answered false for every fixture,
`remove_tree` deleted nothing, and each fixed-name fixture inherited every earlier test's files
(which is why `test_an_empty_folder_keeps_its_own_sentence` read a leftover `note.txt` and
`test_wiki_pane` read `alpha.md` where it wrote `note.md`). Fixed 2026-11-20:
`TestPaths.normalize_path` unifies the separator (`\` to `/` on Windows) and no longer trims a real
path's bytes before `simplify_path`, and `is_safe_path_under(path, root, windows)` is the one bounds
rule `is_safe_user_path` and `remove_tree` share; `TestPaths.fresh_dir` deletes a leftover fixture
before creating it, and twelve files' fixed-name fixtures use it (`test_file_tree`,
`test_wiki_pane`, `test_media_files`, `test_media_pane`, `test_pane_open_request`,
`test_pane_file_sinks`, `test_code_viewer_empty_state`, `test_vault_registry`, `test_link_weights`,
`test_gdext_ffi`, `test_layout_restore`, `test_title_bar_keyboard`); every test function that
indexes a confirmation dialog now asserts the count and returns before indexing (37 functions, 44
reads in `test_wiki_pane`, `test_workspace_cwd_trust`, `test_pane_file_sinks`, `test_palette`),
because three `dialogs[0]` reads after a failed count assert were the `SCRIPT ERROR`s
(`test_wiki_pane.gd:529/553/574`); and `gut-check` prints Godot's `at:`/backtrace lines with the
error it refuses to judge. Tests: `test_a_windows_drive_root_accepts_its_children` (the Windows
spelling pinned on Linux - it answered false before the change) and
`test_a_posix_root_compares_case_sensitively`. Measured: the same refusal reproduced on Linux by
handing the suite a root with a trailing space (`GPTY_TEST_USER_DIR="/tmp/gpty-dirty/user "`), which
the old `strip_edges()` compared away - 24 failing tests and three `SCRIPT ERROR`s before, 105/105
for that script after; the full Linux suite passes. `windows-smoke` green on this change (run
`44745805901`, job `136320671858`: 123 scripts / 1564 tests, 1545 passed and 19 pending on Windows
2025 - the documented platform gaps, none failed).

Commits: 0feae31, 931cc6b

## BUILD-66

**A test that indexes a list a failed precondition never filled still aborts the gate** - fixed
2026-11-20, both halves measured on this tree. (1) *The gate judges what it can*:
`scripts/gut-check` treated every `SCRIPT ERROR` as an abort, so one `Out of bounds get index '0'`
ended Godot and the verdict was "not trustworthy" with the rest of the suite unrun. It now aborts
only when a script/parse error appears **before the first `* <test>` line** - the collector/autoload
failure, still 2.3 s from launch to a named FAIL on a full-suite parse error, with the `at:` line -
and once a test has started the error is GUT's to attribute: the run finishes, and the verdict
splits into "not trustworthy" (a killed run, no Run Summary, a collection failure, a count that does
not add up) and "the suite ran and reported failures", which prints GUT's own failing-test block
(the region between `= Run Summary` and `Totals`, capped at 80 lines) and the first five `at:`
locations. A 64 MiB log cap bounds a repeating error now that the early kill no longer does.
Measured with `_dialogs_of` mutated to `[]`: before the guards, 105 tests ran and 31 failed with 4
located `SCRIPT ERROR`s, where the old gate killed at the first; after the guards, the same 31 fail
with their own assertion text and zero `SCRIPT ERROR`s. (2) *The shape is gone and gated*: all 44
integer indexes on a call's result across 11 `godot/tests/{unit,integration}` files hoist the call's
list, assert its size and `return` when it is short - including the eight dialog reads that only
looked guarded, where `assert_not_null(dialogs[0])` ran after the index that could abort - and
`scripts/check-test-guards` fails any line that indexes a call's result directly (127 test files,
`# guard-ok:` exemption, `ci-check` step 3.3b). Docs: `testing.md` carries the guard rule and the
split verdict, `quick-reference.md` the card, and `defect-classes.md` lists the new control under
`gate-lies`. Full gate: `./scripts/gut-check` 123 scripts / 1566 tests green,
`./scripts/ci-check --fast` green.

Commits: 0feae31, df089ac

## BUILD-67

**`docs-check` fails on ignored scratch markdown, so any commit waits for a blog draft** - found
2026-11-20 while closing the GUT gate row: the user's `TEMP/` scratch area (ignored by
`.gitignore`'s `TEMP*`, home to `gpty-blog-story` drafts and `fix-forensics` baselines) appeared
mid-session, and `scripts/docs-check`'s `markdown_files()` walks the worktree, so five drafts with
repo-relative links turned every gate run into `21 problem(s)` - and the pre-commit hook runs that
gate, so no commit could land without editing or moving someone else's files. The ignore rule and
the gate disagreed about what ships. Fixed 2026-11-20: `TEMP/` joins `docs-check`'s `SKIP_PREFIXES`
(the literal-prefix list that already skips `target/` and `godot/addons/`, and the same rule
`.gitignore`'s `TEMP*` states). Verified with the five drafts in place: `./scripts/docs-check`
green, and the fast gate green. Cause: missed-call-site.

Commits: df089ac

## BUILD-68

**An idle window costs 650-760 MB and the renderer is most of it, not the terminal** - measured
2026-11-11 on the shipped v0.8.1 Linux build (Godot 4.7.2, RTX 5070 Ti, Vulkan 1.4.357; `VmRSS` from
`/proc`, private sandbox): 647 MB with one pane idle (anon 291, file 250, shmem 106) and 655 MB
after every pane is killed, so the terminal is not where the memory is (the two runs differ by less
than the run-to-run spread); 30 000 lines pushed through a pane, past the 10 000-row `history_lines`
cap, add about 39 MB and then plateau, linearly with the cap. A bare Godot 4.7.2 Forward+ window
holding an empty `Control` is 540 MB; the same window on Compatibility (OpenGL3) is 264 MB (the
three OpenGL3 figures in this row are the ones that did not reproduce: re-measured 2026-11-13 on the
same machine - nvidia 620.70.06 and the Vulkan 1.4.363 loader had both been installed before this
capture - a v0.8.1 build measured 366 MB and a v0.8.2 build 363 MB on `--rendering-driver opengl3`,
so the 290 MB recorded here is a capture artefact rather than a stack or a code difference, and the
README now carries the reproducible row); `gpty-gui --rendering-driver opengl3` on this build is 290
MB warm and 356 MB on a cold cache, against 1076 MB on a cold Forward+ launch - about 430 MB of
first-run pipeline compilation that the driver keeps resident in that process, since runs 2 and 3
are 647 MB, so the 1 GB first launch is not a leak and should be documented rather than reported. A
post-reboot 2026-11-21 check on the Vulkan/Forward+ debug editor build (1720x1382, two panes with a
streamer and btop, grain Subtle) measured 1.09 GiB VmRSS (anon 529, file 409, shmem 175) and did not
grow between an idle single pane and the active pair (1.390 -> 1.392 GB in a clean sandbox), so the
user-visible 1.03 GB is the cold-launch/debug-build figure above, not pane growth; the shipped-build
warm figure remains the comparison. The warm gap is Vulkan host allocations (anon 291 vs 122) plus
78 MB more shmem; the rest is driver code pages shared with the desktop. `godot/project.godot` named
no `renderer/rendering_method`, so Forward+ was the implicit default on every platform and Windows
pays the same driver tax. This is a decision, not a one-line flip: Compatibility is 2.2x lighter and
the app draws a 2D canvas, but the 3D vault graph later in this release needs Forward+. Fix: run
both renderers on the same build through `scripts/ui-capture` (both themes, the effect shaders,
`draw_bench` at 90x30 and 200x60) and with an 8-pane layout, choose per platform, set it in
`project.godot` plus every export preset, and record the chosen numbers in the v0.9.0 performance
budget. If Compatibility wins, narrow **The vault graph is a physical 3D map you can push around**
to a 2D spring layout in a `SubViewport` instead of dropping it. Closed 2026-11-22: the bake-off ran
the same build on both renderers through the capture harness and the memory harness. Measured on the
shipped v0.8.5 Linux archive (same machine, `VmRSS`, MiB, warm = a launch in the sandbox): Forward+
667 MB with one pane, 669 with eight, 667 with zero, 1083 on a first launch, +52 MB for 30 000
lines; Compatibility 310 with one pane, 305 with eight, 363 on a first launch; Mobile 592 with one
pane (rejected: only 11% below Forward+). The captures (both themes, `crt`/`grain`, window opacity,
the orbital graph, an 8-pane layout) were taken on both renderers; Compatibility renders the orbital
map, the opacity veil's alpha and the effects, and only the graph's subtle bloom differs.
`draw_bench` (warm, median of three) puts a full repaint at 1.60/3.39 ms on Forward+ and 1.48/3.72
ms on Compatibility at 90x30/200x60, so there is no material repaint penalty; `effect_bench` at 4K
on both renderers measured a 237-249 us frame floor with a 0-13 us delta, so it still does not
isolate the shader and the v0.9 effect row keeps that work. Decision: Forward+ stays the default on
every platform, because the orbital graph's bloom and the v0.8.6 visual identity need it;
Compatibility is the documented opt-in (`--rendering-driver opengl3`) and 2.2x lighter warm / 3x
lighter on a first launch. `godot/project.godot` now pins `renderer/rendering_method="forward_plus"`
explicitly; no export preset carries a rendering-method key, and a future per-platform flip is one
verified project-setting override (`rendering/renderer/rendering_method.<os>`, verified on 4.7.2),
with the Windows ANGLE/WARP prerequisite owned by the Windows fallback row below. The graph's `auto`
rule changes with the decision: it now picks the orbital map on any hardware adapter (Compatibility
included) and the planar canvas only on a software rasterizer, superseding the v0.8.5 "Compatibility
resolves to planar" rule; `test_graph_mode_auto_follows_the_adapter_not_the_renderer` pins the
adapter cases. Harness: `scripts/ui-capture` and `scripts/ui-capture-check` gained `--renderer`;
`ui_capture.gd` gained `eight-panes` (4x2 via `grid_cols`/`grid_rows`), `wiki-graph-orbital` and
`window-opacity`; `scripts/measure-cost` warms the OpenGL3 arm with a discarded launch and records
the eight-pane row (the old 366 MB was a cold GL reading). README's Trade-offs table and the v0.9.0
Performance budget in `testing.md` carry the fresh figures; the budget also records the pending
frame/CPU/power/startup/input rows. Tests: the adapter test, the full GUT suite (130 scripts / 1657
tests), the full default-renderer `ui-capture-check` (59 states) and its Compatibility matrix subset
(10 states), and `measure-cost --check` (every row OK). The merged-main re-gate passed CI
45062060839 (every job, `windows-smoke` included), CodeQL, Docs and Secret scan on f15c79e.

Commits: da2fc47, 5b5d9ac, 062118f, d3a7b05, 6d29aa3

## BUILD-69

**The Windows build has no fallback above native OpenGL 3** - closed 2026-11-22. The premise was the
export-preset flags, not the build: Godot 4.7.2's official Windows template statically links ANGLE
(`EGL_STATIC`; the template carries `switching to ANGLE`, `EGL_PLATFORM_ANGLE_*` and the D3D11 WARP
device type) and compiles the D3D12 driver against the system `d3d12.dll` (the template has no
`D3D12Core.dll` reference; its loader falls back to `D3D12CreateDevice`), so
`application/export_angle=0`/`export_d3d12=0` are the enum's **Auto**, not Off: the exporter copies
optional `libEGL.<arch>.dll`/`D3D12Core.<arch>.dll` files from the template directory, the official
`.tpz` contains none, and setting them to 1 would copy nothing. The runtime chain was already Vulkan
-> D3D12 (WARP) -> native OpenGL 3 -> ANGLE by default; `godot/project.godot` now pins
`rendering_device/driver.windows="vulkan"`, `rendering_device/fallback_to_d3d12`,
`fallback_to_opengl3`, `gl_compatibility/driver.windows="opengl3"`, `fallback_to_angle` and
`fallback_to_native`, so the order is a project decision.
`scripts/smoke_pane_api.py --renderer-smoke d3d12 opengl3_angle` boots the real app without
`--headless` (120 s per launch), parses the startup `[renderer]` line, requires the named driver,
and requires the software-rasterizer warning to name a software adapter; `windows-smoke` runs it
after `Import project`. Measured locally on Linux:
`[renderer] vulkan (forward_plus) on NVIDIA GeForce RTX 5070 Ti` and
`[renderer] opengl3 (gl_compatibility) on NVIDIA GeForce RTX 5070 Ti`; the Windows run
(`windows-smoke` run 45077452383, green) reports
`d3d12 (forward_plus) on Microsoft Basic Render Driver` (WARP) for the default and the forced
`d3d12` launch, and
`opengl3_angle (gl_compatibility) on Google Inc. (Microsoft) ANGLE (Microsoft, Microsoft Basic Render Driver ...)`
for the forced ANGLE launch, with the software-rasterizer warning naming the same adapter. The
archive's file list and size are unchanged: no runtime DLLs are added. One deferral with its
evidence: the row's Intel-driver-with-no-Vulkan case is not reproducible on the attached hardware
(RTX 5070 Ti) or the CPU-only `windows-2025` runner, whose WARP adapter is the software case the row
asks to name; the forced `opengl3_angle` launch covers the GL path, and a physical Intel machine
remains unmeasured rather than claimed. The 2026-11-22 bake-off still decides the default
(Forward+), so the Windows rendering-method override stays unset; Compatibility remains the
documented opt-in (`--rendering-driver opengl3`).

Commits: 5d9c4ec, d3a7b05, 13c36ee

## BUILD-70

**A capture can break on a class reference and only a manual harness run notices** - closed
2026-11-25: `scripts/ui-capture --list` is the gate, run by `scripts/ci-check` after the Godot
import and by the Linux `gut-tests` job in `.github/workflows/ci.yml`. It is the real load, not a
static approximation: `godot -s` compiles the harness and every dependency before the autoloads
exist, so naming a project class fails exactly as it would fail a capture, and `--list` needs no
display. The list mode now judges the engine log for `SCRIPT ERROR`/`Failed to load script` and
requires at least one state; without that check Godot still printed all 85 state names and exited 0
while the typed probe's dependency failed to compile. Verified by adding `var _probe: UiMotion` to
the harness: `scripts/ui-capture --list` exited 1 and printed the compile errors; removing it
restored the 85 states and exit 0. The harness keeps its untyped/`has_method` reads (the v0.8.4
workaround); no fixture is committed, because the gate compiles the real graph.

Commits: a0e4bdd, 5b4a01d

## BUILD-71

**A capture cannot tell a pinned frame from a lucky one** - closed 2026-11-25:
`godot/tests/bench/ui_capture.gd` walks the staged tree before `frame_post_draw` and refuses a
capture while a visible `Control` carries a `UiMotion.ARRIVAL_META` record whose tween
`is_running()`; hidden nodes are skipped (they cannot change the image), and the constant is read
through a runtime `load("res://scenes/ui/ui_motion.gd")` so the harness still compiles before the
autoloads exist. `--unpinned-arrival` starts the shipped `UiMotion.arrive` on the status bar for 2 s
(a 120 ms ramp could finish in the frame before the check) after forcing `cfg_motion` to Full;
`scripts/ui-capture-check` runs that capture after its perturb verdict and requires a non-zero exit
whose message names the live arrival. `_capture` now returns whether the PNG was written and `_run`
exits 2 on false: a `quit(2)` inside `_capture` was overwritten by `_run`'s own `quit(0)`, so a
refused or failed capture reported success to the shell. Full run 2026-11-25:
`ui-capture-check: PASS (85 states)`, every state pixel-identical, only `settings` perturbed,
`PASS the live arrival was refused`.

Commits: a0e4bdd, 5b4a01d

## BUILD-72

**A performance budget is stated and gated** - the diagnostic numbers have no consequence without a
threshold. Fix: record a named build's idle frame time, full-repaint frame time at 90×30 and 200×60,
resident memory at 1, 8 and 32 panes *and the zero-pane idle figure* (the engine plus renderer
baseline - measured 2026-11-22 at 667 MB warm / 1083 MB cold on the v0.8.5 Forward+ build and 310 /
363 MB on Compatibility, so a per-pane number without it reads as if panes were the cost; the
renderer/memory/repaint rows now sit in the Performance budget table, and the
frame/CPU/power/startup/input rows plus the 10% gate are this row's remaining work), startup to
first frame, and the input-latency sample from the row above as a table in
`docs/content/docs/agents/testing.md`; the bench harness fails when a run exceeds the budget by more
than 10%. The budget is what the UI/UX claim is measured against, so a regression is a release
blocker.

## BUILD-73

**The v0.8.6 Forward+ baseline grew about 130 MB with no pane growth** - measured 2026-11-23 with
`scripts/measure-cost --record` on the v0.8.6 build: Forward+ is 798 MB with one, eight and zero
panes and 1226 MB on a first launch, against 667 / 669 / 667 and 1083 on the v0.8.5 bake-off - +131
MB warm and +143 MB cold - while OpenGL3 moved only 310 -> 321 MB (inside tolerance) and the
scrollback delta stayed +52 MB. The growth is renderer-specific and pane-independent, so it is a
startup resource, not the terminal: candidates are the 3840x2160 boot splash (33 MB decoded before
mipmaps and any GPU copy), the full-screen opacity veil (`BackBufferCopy` at the window size plus
the `WindowBg` ground), and the larger PCK (`godot/docs.json` and the v0.8.6 assets); the docs
bundle is lazy on the About tab, the effects are Off by default, and the 3D graph is not
instantiated in the default workspace. Fix: measure the v0.8.5 archive on the same machine with
`scripts/measure-cost --release-dir` to separate environment from tree, then profile the startup
allocations (the `[renderer]` line already names the driver, method and adapter) and release or
budget what the visual identity holds resident; re-record the ledger, the README table and the chart
when it moves.

## BUILD-74

**The GDScript performance sweep is a script and a page, not a memory** - shipped 2026-11-15:
`scripts/gdscript-audit` is a report-only cost-atom scanner over `godot/scenes` (function and loop
context, `--hot`, `--json`, not in `ci-check`), `godot/tests/bench/gdscript_probe.gd` measures the
idioms on the installed build (string indexing vs slicing, Dictionary defaults, `range`,
`get_string_size`, palette reads, Image reuse, audio interleave, NodePath lookup; median of 5,
headless), and `docs/content/docs/agents/gdscript-performance.md` owns the method and the
move-to-Rust rule, linked from the AGENTS.md guides table. The audit produced the fourteen open rows
here; the script is a floor, not a source of truth - it names cost atoms, and a reviewer still has
to read the hot function. Verified: `./scripts/gdscript-audit --top 20` names every queued row's
file, the probe prints all case pairs, and `./scripts/docs-check` passes. Evidence:
`TEMP/gdscript-opportunities.md`.

Commits: b11eb71

## BUILD-75

**OpenSSF Best Practices reaches passing** - verified 2026-11-02: the project 16201 badge's
`aria-label` is `openssf best practices: passing` (it read `in progress` at the v0.7.2 capture). The
README badge and the Project Health bullet already point at the project, so the badge updates
without a repository change.

Commits: 39ef2cf, 6cecfd6

## BUILD-76

**A nightly build ships the day's `main` as one rolling prerelease** - every downloadable artifact
comes from a tag, so a user who wants today's fix builds from source or waits for a release, and a
bug report cannot name the build it came from. Measured cost (run `43281605330`, v0.8.2): the
release pipeline is 37.1 job-minutes across six jobs with a 16.1 min wall, critical path
`build-macos` x86_64 at 13.7 min, and `release.yml` then carried no cache step at all - no cargo, no
`dist/ffmpeg/<platform>` prefix, no `C:\vcpkg` - while `ci.yml`'s cached jobs do comparable work in
3-6 min (the shared build now restores those caches; see **A tag release still builds every platform
cold** below). Owner's decisions (2026-11-13): **nightly in its standard sense** - one build a day
carrying whatever landed on `main` that day, not per commit and not hourly; Neovim's model
(`schedule` + `workflow_dispatch`, one rolling `nightly` prerelease) over Ghostty's per-green-commit
`tip`; and the new build must succeed before the old is replaced, so the download URL is never
absent and exactly one nightly release exists. Fix. (1) **Done 2026-11-17, pulled forward with the
cold-build row below:** `release-build.yml` holds `build-linux`, both `build-macos` arches,
`bundle-macos`, `build-windows` and `export` behind `workflow_call` plus `workflow_dispatch` (a
`version` input), and `release.yml` calls it, so the nightly path needs only a caller. This row
still goes ahead of the signature-asset and SBOM rows because they edit that same upload list. (2)
`nightly.yml` on `schedule: cron '17 5 * * *'` (off the hour; GitHub's cron queue is congested at
:00) plus `workflow_dispatch`, `concurrency: {group: nightly, cancel-in-progress: false}` (a cancel
mid-publish is the corruption Ghostty's own comment guards against), and a skip when `main`'s head
equals the release's current `--target`, so a quiet day costs one job. (3) Publish one `nightly`
**prerelease** with stable, version-free asset names (`gpty-linux-x86_64.tar.gz`), so
`releases/download/nightly/...` is a permanent URL: upload the three archives with
`gh release upload --clobber`, then `SHA256SUMS` computed over the new set, then move the tag with
`gh release edit nightly --target "$GITHUB_SHA"` and write the commit and build date into the body.
Never `gh release delete`: its recreate window is the 404 Neovim lives with, whereas `--clobber`
replaces each asset in about a second - a per-file gap on one night's swap instead of a missing
release. (4) Stamp a build identity - `option_env!("GPTY_BUILD_VERSION")` falling back to
`env!("CARGO_PKG_VERSION")` in `get_app_version` (`crates/gpty-gdext/src/bridge_api.rs:45`) and in
`gpty version` (`crates/gpty-cli/src/main.rs:478`), fed `<cargo-version>-nightly.<YYYYMMDD>+g<sha>`
so the GUI and CLI can never disagree (`daemon::warn_on_version_mismatch`) and a bug report names
its build; `godot/project.godot`'s `config/version` stays numeric because the export becomes the
macOS `CFBundleShortVersionString`. (5) **Partly done, with one correction to the plan:** a tag run
can restore only its own ref's and the default branch's caches (GitHub's cache scope), so
night-specific keys would have been a dead end - the nightly is the *writer* for the release keys
the tag restores (`cargo-release-<os>-<arch>-<lock>`, `<os>-ffmpeg-<hash>` - on Linux
`Linux-ubuntu22-ffmpeg-<hash>`, since the prefix must come from the release's own 22.04 image - and
`vcpkg-ffmpeg-<os>-9.0.2`). `release-build.yml` already gates every save on
`github.ref == 'refs/heads/main'`, so a scheduled or dispatched run on `main` fills them and a tag
run only reads; what is left here is `retention-days: 1` for the between-job artifacts (the shared
definition carries 3 for the tag path) and a budget check once the four release-target caches exist.
(6) `permissions: contents: read` at the top of `nightly.yml` with `attestations: write` and
`id-token: write` only on the publishing job, every action pinned to a commit SHA, and the
bundle-medium staging the tag path already uses, so `scripts/lint-workflows` passes. Accepted costs:
nightly pulls mix into the release badge's download count, the project's only install signal (the
Future telemetry row is the fix, not a reason to skip this), and the archives are unsigned like the
stable ones, so macOS 15+ quarantines a browser download - the docs point at `curl`/`install.sh`.
Acceptance: the nightly URL downloads and `gpty version` prints the stamped build matching `main`'s
head at that cron; `gh release list` shows exactly one `nightly` and it is a prerelease;
`/releases/latest` still resolves to the last stable, so `update_checker.gd` prompts no nightly
user; a deliberately failed platform build leaves the previous nightly downloadable (proved by a
`workflow_dispatch` run); the platform jobs exist once in the repository and both entry points
reference them; README gains a Nightly line beside the release badge; `./scripts/lint-workflows` and
`./scripts/ci-check` pass.

## BUILD-77

**A tag release still builds every platform cold, and a cold build is where the release wall time goes** - **the
fix landed 2026-11-17; what remains is the first tag run's wall time, recorded here.** Baseline
measured on the last pre-split release (run `44003327988`, v0.8.5): 38 min wall, `build-windows`
34:51 with 27:45 in `Build media dependencies` after `Cache vcpkg FFmpeg` logged `Cache not found`
at 02:30 - main's own vcpkg entry was created at 02:41 by the post-merge CI run, so that was a cold
default branch rather than a scope rule - and `build-macos` x86_64 11:00, `build-linux` 4:54,
`export` 1:46. What landed: the five platform jobs moved into `.github/workflows/release-build.yml`
(`workflow_call` from `release.yml`, `workflow_dispatch` on `main`, a `version` input), which also
closes item (1) of the nightly row; every build job restores the FFmpeg prefix (Windows under
`ci.yml`'s exact key; Linux under an image-scoped `Linux-ubuntu22-ffmpeg-*` key, because `ci.yml`
builds the prefix on 24.04 and a 24.04-built `libav*.so` needs GLIBC_2.38, which a 22.04 link cannot
take - and that prefix ships in the archive), Windows restores the vcpkg tree only when that prefix
missed, and each job restores a `cargo-release-<os>-<arch>-<lock>` target that `ci.yml` never writes
- a release-profile target restored from a debug cache is dead weight, because Cargo keeps
build-script and proc-macro artifacts under the profile directory. Every save is gated on
`github.ref == 'refs/heads/main'`: a tag-scoped entry is unreadable by the next tag (GitHub's
documented cache scope), so a tag run only restores, and `media-deps`'s `.stamp` plus Cargo's
fingerprints still decide what is rebuilt, never what is correct. Expected on the first tag after it
lands: Windows' 27:45 media-deps step becomes a ~10 MB restore and the wall falls to `build-macos`
plus export, while Linux's 1:07 and macOS's ~11 min stay cold until a run on `main` writes their
prefixes (Linux's key is image-scoped and macOS has no `ci.yml` job, so neither has a writer yet) -
`gh workflow run release-build.yml --ref main -f version=vX.Y.Z`, documented in RELEASING.md §9,
does that and is also the build-definition proof before a tag. Warm expectation for `build-macos`
x86_64: 4-6 min. Left uncached on purpose: `export`'s Godot editor and template downloads (13 s + 23
s of its 1:46), because they would need their own writer on `main` and buy well under a minute once
the wall is ~8 - revisit with the nightly path.

Shipped in `752b78a` and recorded from the first tag after it, v0.8.6 release run
`45276452554`: the build half ran 2026-11-23T22:06:52Z -> 22:35:50Z, **28m58s** wall
against 38m before the split. `build-linux` 58s, `build-macos` arm64 12m32s and x86_64
13m19s, `build-windows` 25m47s, `export` 1m29s. Windows still spent 20m39s in
`Build media dependencies` because the restored prefix supplies DLLs but not vcpkg's
headers; that residual is BUILD-99. The `publish-crates` re-run the next day is not
part of the wall.

Commits: 43283c7, 18e42af, c7bbac7

## BUILD-78

**A patch release on an archived `X.Y.x` branch cannot pass the release gate** - found 2026-11-17
when creating the `0.1.x`-`0.7.x` archive branches: `release-gate` requires the tagged commit to be
an ancestor of `main` (`git merge-base --is-ancestor HEAD FETCH_HEAD`) and the tagged tree's crate
version to equal the tag, so a `v0.7.3` cut on `0.7.x` is refused while `main` carries the active
line's version. The branches are therefore backport and reproduction bases, not release bases. Fixed
2026-11-21: `release.yml` derives `release/vX.Y` from the tag and accepts a tag reachable from
`main` or from that branch. `release/v0.1`-`release/v0.7` now exist at their last tags with the
trigger backfill; the ancestry step passed for v0.8.5 on `main` and a local `v0.7.99-test` tag on
`release/v0.7`, and an unrelated-branch tag was refused in a throwaway repository. A v0.7.3 tagged
on `release/v0.7` is the supported maintenance path; the archived tree runs its own release
workflow, which is reviewed before the tag.

Commits: 697d75f, ed7f1a9

## BUILD-79

**A PR that edits a workflow file cannot use the bot as its last pusher** - found 2026-11-21 while
normalizing the branches: `main` requires an approval after the most recent push, and the only
reviewer is the maintainer, so the branch must be pushed by `gpty-bot` before approval. The app's
grant is contents, pull-requests and metadata only, and GitHub refuses an App push that creates or
updates a workflow file (measured 2026-11-17, `.omp/skills/commit/SKILL.md`), so a workflow-changing
branch is pushed with the maintainer's credential and the approval is self-approval. Measured again
2026-11-25 on the v0.8.7 fix branch: the same commit was pushed three times, each pre-push run took
~375 s, and both SSH pushes died with `SIGPIPE` (exit 141) right after the gate; pushing the
workflow-bearing commit over HTTPS with the maintainer's `gh` token (0600 temp file,
`GIT_ASKPASS=scripts/git-askpass-token`) and then pushing the final docs commit with
`scripts/bot-push` worked, and PR #51 merged with the bot as the last pusher. Measured again
2026-11-26 on PR #58: an empty commit pushed by the bot is not a reviewable push, so the approval
submitted after it still resolved to the last pusher's own and the merge box stayed "At least 1
approving review is required"; the bot-pushed commit after the split must carry a non-workflow diff.
Fix: create
`scripts/pr` with `push` and `open`, delete `scripts/bot-push`/`scripts/bot-pr`, and split the push
whenever `git diff --name-only origin/main...HEAD -- .github/workflows` is non-empty: push the
newest workflow-touching commit `W` with the maintainer's HTTPS credential, refuse when `W == HEAD`
(a non-workflow commit must follow so the bot can be last), then push `HEAD` as the bot; no new App
grant. Acceptance: a workflow-editing PR is opened, approved by someone other than its last pusher,
and merged with no ruleset change, and the next one is one `pr push` call. Tests: a temp-repo
fixture for the split and the `W == HEAD` refusal; `--dry-run` prints the two shas and makes no
network call.

Shipped in `scripts/pr push`: it computes the newest commit in the base..HEAD range
that touches `.github/workflows`, pushes that commit with the maintainer's `gh` token
through `GIT_ASKPASS`, then pushes HEAD as the bot, and refuses when the newest commit
is the workflow one (a non-workflow commit must follow). PR #62 was pushed that way:
maintainer `3af51f8`, bot `676ffd2`, and the approval after the bot's push was
accepted. The temp-repo `selftest` covers the split and the refusal without a network;
`push --dry-run` prints the two shas.

Commits: 1a1b2dd, 18e42af, 660399d, c03364e, c7bbac7

## BUILD-80

**Shipping a session is four manual steps with one trap** - the 2026-11-24 session committed two
commits directly on `main` (the roadmap skill's step 7 did not name a branch), then created
`feat/v087-backdrop-elevation`, moved `main` back to `origin/main`, and ran `scripts/bot-push`,
`scripts/bot-pr` and `gh pr merge --auto --merge` by hand; the skill now carries the branch step,
but the sequence is still four commands whose order matters and whose failure modes (push refused on
`main`, branch behind, PR opened by the wrong credential) are documented only in prose. The
2026-11-25 merge sequence was five hand-built steps (review, `gh pr merge --auto --merge`,
`scripts/pr-wait`, `scripts/branch-prune`, then reading Docs/Scorecard/Secret scan on the merge
commit), and the four scripts are one flow. Fix: one `scripts/pr` (bash) replacing `bot-push`,
`bot-pr`, `pr-wait` and `branch-prune` - `pr push` (above),
`pr open [--key K] [--base B] [--title T] [--body-file F]`, `pr wait N`, `pr land N [--approve]`
(refuse unless `app/gpty-bot` authored the PR; `--approve` posts the maintainer approval, otherwise
require `reviewDecision == APPROVED`; enqueue `--auto --merge`, wait, prune, print the merge SHA and
the post-merge Docs/Scorecard/Secret scan conclusions), and `pr prune`; `--help` lists them and an
unknown subcommand exits 2. Delete the four scripts, update every live reference (`AGENTS.md`,
`CONTRIBUTING.md`, `RELEASING.md`, `docs/content/docs/agents/{repo-map,testing}.md`, the four
skills, and `scripts/ci-check`'s two tooling lists) and leave closed roadmap history alone.
`githooks/pre-commit` refuses `main`/`master` before `ci-check --fast`. Acceptance: a session ships
a PR with `pr push`/`pr open`/`pr land` and no hand-built `gh` sequence; the four scripts are gone;
the pre-commit guard refuses on `main` and allows a feature branch; `pr land --dry-run` refuses a
non-bot author and an unapproved PR without network.

Shipped as one `scripts/pr` with `push`, `open`, `wait`, `land`, `prune` and
`selftest`; `land` refuses a non-bot author, posts the maintainer approval with
`--approve`, enqueues with `gh pr merge --auto --merge`, waits through the merge queue,
prunes and prints the merge SHA plus the post-merge Docs/Scorecard/Secret-scan
conclusions. `bot-push`, `bot-pr`, `pr-wait` and `branch-prune` are deleted and every
live reference points at the new command; `githooks/pre-commit` refuses `main`, and
`pr selftest` runs in `scripts/tooling-smoke`.

Commits: f1bbc7e, 3153852, 18e42af, c03364e, c7bbac7

## BUILD-81

**Crates.io publishing uses a manual token, not OIDC** - the v0.7.2 record says the crates.io
publish is manual; there is no trusted-publishing configuration or `crates-io-auth-action` in the
release flow. Fix: configure [crates.io Trusted
Publishing](https://crates.io/docs/trusted-publishing) for each crate's GitHub workflow, use
`rust-lang/crates-io-auth-action` + `cargo publish`, remove the long-lived `CARGO_REGISTRY_TOKEN`,
and make the MCP registry workflow depend on the published crates instead of a manual step.
Acceptance: a dry run or the next release publishes via OIDC with no registry token secret, and the
MCP registry job succeeds.

Closed 2026-11-26. `publish-crates` in `.github/workflows/release.yml` authenticates with
`rust-lang/crates-io-auth-action@v1.0.6` under `id-token: write` and the `release` environment; the
token is that action's step output and `gh secret list` is empty, so no long-lived registry secret
exists. The v0.8.6 tag contains the job, its release run finished `publish-crates` and
`mcp-registry / publish` successfully, and crates.io serves `gpty` and `gpty-core` 0.8.6 (published
2026-11-24). The registry workflow is chained from `release.yml` with `workflow_call` and polls
crates.io instead of a manual step.

Commits: 39ef2cf, 6cecfd6, 18e42af, 97d3d90

## BUILD-82

**Releases carry attestations but no signature asset, so Scorecard's Signed-Releases reads 0** - carried
from v0.7.2 (measured on `a84311a`; still 0 in the 2026-11-04 run, overall 7.8 - the `8.0` written
here on 2026-11-04 does not reproduce against that run's per-check table and was corrected on
2026-11-10). The three archives and `SHA256SUMS` are attested through
`actions/attest-build-provenance@v4.2.2`, but the attestation lives in GitHub's attestation API, not
in the release's asset list, and Scorecard reads assets (`.intoto.jsonl`, `.sig`, `.asc`,
`.sigstore`, ...). Fix: the attest step exposes a `bundle-path` output; give it an `id`, stage the
bundle as `dist/gpty-${VERSION}.intoto.jsonl`, and add it to the `softprops/action-gh-release`
`files:` list (the bundle covers the archives and `SHA256SUMS`; keep it out of the checksum it
attests), or backfill existing releases with `gh attestation download <asset> -R godot-pty/gpty` and
rename/upload the `.intoto.jsonl`. Acceptance: the next release's asset list contains the bundle,
`gh attestation verify` still passes, and Scorecard's Signed-Releases moves off 0. Worth: scorecard
v5.6.0 weights each check by risk (Critical 10, High 7.5, Medium 5, Low 2.5) and rounds the weighted
mean to one decimal, so the table that produces 7.8 is Code-Review 0, Signed-Releases 0,
Contributors 0 and CII-Best-Practices 5, Branch-Protection 8, Vulnerabilities 9, the rest 10, with
CI-Tests and Packaging inconclusive - 765/97.5 = 7.85. Signed-Releases scores `floor(sum/5)` over
the five most recent releases with provenance 10 and a signature 8 per release, so one release
carrying the bundle is 2 (+0.15 overall, back to 8.0) and all five backfilled is 10 (+0.77, overall
8.6); this is the largest lever left.

## BUILD-83

**The fuzz workspace's committed lockfile went stale and fed a vulnerable dependency to the dependency graph** - fixed
2026-11-10. Scorecard's Vulnerabilities check read 9/10 on `RUSTSEC-2026-0459` (SQLite
CVE-2026-119375, `libsqlite3-sys` 0.6.0-0.38.x) while `cargo audit` on the root lock was green:
`fuzz/Cargo.lock` still pinned `rusqlite` 0.31.0 and `libsqlite3-sys` 0.28.0, and
`cargo metadata --locked --manifest-path fuzz/Cargo.toml` refused the file as out of sync with
`gpty-core`'s `rusqlite = "0.41"`. GitHub's dependency graph reads that lockfile, so a graph no
build ever used was scoring the repository. Cause: dependabot PR #5 ("bump rusqlite from 0.31.0 to
0.41.1 in /fuzz") was closed rather than merged on 2026-11-06, and the `fuzz-build` job resolves
without `--locked`, so the drift could never fail a run. Fix: regenerate the lock (`rusqlite`
0.41.1, `libsqlite3-sys` 0.39.1) and gate the file in both runners - `cargo metadata --locked` plus
`cargo audit --file fuzz/Cargo.lock --deny warnings` in `scripts/ci-check` and the CI `cargo-audit`
job. Verified: the old file fails that audit with "1 vulnerability found" (reproduced from a
backup), the new one passes, and `--locked` resolves. Worth: Vulnerabilities 9 to 10, overall 7.8 to
7.9 - the weighted arithmetic is in the Signed-Releases row above.

Commits: d1e0cf7

## BUILD-84

**Dependabot cannot land a shared dependency bump as one green pull request, so the two-lockfile workspace pair arrives red every week** - measured
2026-11-22 on PRs #18 and #19: both raise `rusqlite` 0.41 -> 0.43 in `crates/gpty-core/Cargo.toml`,
because the fuzz workspace reaches that manifest through its path dependencies, but each dependabot
entry regenerates only its own directory's lockfile. #18 updated `fuzz/Cargo.lock` and failed every
root `--locked` job; #19 updated the root `Cargo.lock` and failed the fuzz lockfile verify and audit
steps. `cargo metadata --locked` fails in the untouched workspace on each branch (reproduced
locally). Fixed 2026-11-22: `.github/dependabot.yml` has one cargo entry over
`directories: ["/", "/fuzz"]` whose group sets `group-by: dependency-name`, so a dependency's
manifest edit and both lockfiles land in one pull request. The two open PRs were completed by adding
the missing lockfile to each branch instead of closing them (see the merge-ratio row above).
Confirmation is the next weekly run: one per-dependency PR whose root and fuzz
`cargo metadata --locked` both pass.

Commits: 402ec47

## BUILD-85

**Insights cannot read our required reviews or required status checks, so 4 of 8 security-practice points are unearned** - measured
2026-11-10 from `https://insights.linuxfoundation.org/api/project/godot-pty-gpty`:
`securityPracticesScore` is 4 with `securityPolicyEnabled` and `branchProtectionEnabled` set, but
`branchProtectionRequiredReviews` and `branchProtectionRequiresStatusChecks` are both null even
though `GET /repos/godot-pty/gpty/branches/main/protection` reports
`required_approving_review_count: 1` and eleven required contexts. The classic protection API needs
admin to read, which is the likely reason an ingest token sees nulls; the rulesets API
(`GET /repos/{owner}/{repo}/rulesets`) is readable with plain repository read. Fix: evaluate
mirroring the review and status-check rules into a repository ruleset, confirm the two fields
populate, and keep classic protection until then - Scorecard's Branch-Protection still reads the
classic API and must stay at 8. Risk: a ruleset-only repository could lose the Scorecard point it is
meant to complement. Acceptance: `securityPracticesScore` is 8 and Branch-Protection is unchanged.
The public-readability half landed in 0.8.4: the `main protection` branch ruleset carries the
required reviews and all 12 status checks, so a non-admin token can read them through
`GET /repos/{owner}/{repo}/rules/branches/main`. The remaining acceptance is the LFX
`securityPracticesScore` re-ingest to 8, which is asynchronous.

Dropped 2026-11-27 as superseded: the LFX project API no longer carries a
`securityPracticesScore` field (`GET /api/project/godot-pty-gpty` has no such key), so
the acceptance cannot be measured. The configuration it was meant to measure is now
publicly readable without an admin token:
`GET /repos/godot-pty/gpty/rules/branches/main` returns the `pull_request` rule (one
approval, last-push approval) and `required_status_checks` (`ci-gate`, `secret-scan`,
the four `Analyze` contexts). The ruleset half landed in 0.8.4; no code change remains.

## BUILD-86

**Four of the seven closed pull requests were closed unmerged, which caps the merge-ratio signal and cost the Scorecard vulnerability point** - measured
2026-11-10: Insights reports `merged12m` 3 and `closedUnmerged12m` 4 (43 percent, 1 point of 3) with
`prMergeScore` 3 of 5. The four closures are dependabot PRs #1, #2, #4 and #5, and #5 is exactly the
fuzz lockfile bump whose closure left `libsqlite3-sys` 0.28.0 in the dependency graph. Fix: merge a
dependency PR, or let the next one supersede it as a draft; never close one after hand-applying the
same bump - a closed PR stays in the 12-month window. Worth: the two remaining development points at
70 percent merged (worse than seven merges per three closures), and no repeat of the lockfile drift.

Closed 2026-11-26: measured with `gh pr list --state closed --limit 100 --json mergedAt` - 57 closed,
44 merged and 13 closed unmerged (77 percent merged), above the 70 percent the row named. The four
Dependabot closures remain in the 12-month window, so the practice is what changed: a dependency PR
is merged or left for its grouped successor (BUILD-84), never closed after a hand-applied bump.
Scorecard `Vulnerabilities` reads 10/10 (0 existing vulnerabilities) on the 2026-11-26 run, the point
the row blamed on the stale fuzz lockfile (BUILD-83). The Insights API no longer exposes
`prMergeScore`, so the GitHub count is the reproducible measurement.

Commits: d1e0cf7, 18e42af, 97d3d90

## BUILD-87

**No SBOM ships with a release** - `release.yml` uploads the three archives and `SHA256SUMS` but
generates no bill of materials, while the bundle contains Rust crates, Godot, the pinned FFmpeg
shared libraries and fonts. OSPS QA-02.02 asks for an SBOM with compiled assets. Fix: generate SPDX
or CycloneDX over `dist/` (`syft dir:dist -o spdx-json` or `cargo cyclonedx` plus a bundle scan),
attach it to the release and `SHA256SUMS`, and attest it with `actions/attest`'s `sbom-path` (the
current `actions/attest-build-provenance@v2` only produces provenance; v4 `actions/attest` takes the
SBOM). Acceptance: the next release has the SBOM, `gh attestation verify` sees the SBOM predicate,
and the FFmpeg/font components are listed.

## BUILD-88

**`gpty-ai::omp_session_respawns_after_child_exits` flakes under the parallel gate with `omp stdout closed early`** - found
2026-11-12 while running the full `ci-check` for the profile-seeding work: one run of the parallel
Rust suite failed at `crates/gpty-ai/src/omp.rs:797` with
`second turn must survive the child exiting` and the event list ending in
`Error { message: "omp stdout closed early" }`; the test passed alone and the next full gate passed,
so it is timing/shared-fixture shaped rather than a deterministic assertion failure. The earlier
v0.5 row closed a different fake-`omp` path collision (`Text file busy`); this one is the second
turn reading a child that exited before its stdout was drained. Fix: make the fake `omp` fixture's
exit/write ordering deterministic (or bound the second-turn read) so the test states the same
contract every run. Acceptance: repeated `cargo test --workspace` (default parallelism) green,
including the fake-`omp` tests.

## BUILD-89

**Dependabot's first grouped cargo updates fail every Rust job on `getrandom` 0.3+** - fixed
2026-11-04: the direct dependency is now `getrandom = "0.4"` in `crates/gpty-gdext/Cargo.toml` and
`crates/gpty-gdext/src/omp_events.rs` calls `getrandom::fill`, the 0.3+ name.
`cargo test --workspace` and `cargo +nightly fuzz build` pass with the updated lockfile; the Windows
check and every Rust job pass in CI on the fix push. The closed #1/#4 groups are recreated by the
next weekly Dependabot run from a green base.

Commits: 74028d2, 3ec276b, 6cecfd6, 25adc85

## BUILD-90

**`check-ffi-surface` reads a comma inside a string literal as an argument separator** - `split_args`
and `balanced_args` now track single- and double-quoted literals and backslash escapes, so
`set_palette(",".join(...))` is one argument and a `)` inside a string no longer truncates the walk.
`--selftest` carries the failing-before cases - on the old walker `split_args('",".join(x)')`
returned two arguments and `balanced_args('f(")", x)', 1)` returned `"` - and
`scripts/tooling-smoke` runs it beside the real check. The pitfalls workaround is replaced by the
parser's new contract. Verified with `./scripts/check-ffi-surface --selftest`,
`./scripts/check-ffi-surface` and `./scripts/tooling-smoke`.

Commits: 9571f98, 18e42af, 9826a57

## BUILD-91

**The static gates run in the `docs` job, but the tooling scripts' own smoke does not** - updated
2026-11-24: the `docs` job (`.github/workflows/ci.yml:92-135`) now runs `check-ffi-surface`,
`check-log-hygiene`, `check-theme-tokens`, `check-test-guards`, `measure-cost --stamp` and
`render-cost-chart --check --require-current`, so the source-gate half of the original row is
closed. What remains is `run_tooling_scripts` (`scripts/ci-check:295`), called at
`scripts/ci-check:381` and `scripts/ci-check:559` but never by a workflow: a `bash -n` error in a
tooling script, a Python syntax error in a cost script, or a broken backfill plan is caught only by
the local pre-push suite. Fix: add `run_tooling_scripts` (or its GPU-free subset) to the `docs` job;
it needs bash and python3 only, both already present on the runner. Do not add a second job unless
its runtime justifies one. Tests: a deliberate `bash -n` error in `scripts/measure-cost` fails the
`docs` job; the green run's log lists the tooling checks.

Shipped: `scripts/tooling-smoke` is the extracted `bash -n`/`py_compile`/backfill/
secret-scan smoke plus `scripts/pr selftest`; `scripts/ci-check`'s
`run_tooling_scripts` calls it, and the `docs` CI job now runs it directly. The docs
job in PR #62 run `45921076617` (job `140251690374`) passed it; planting `if` in
`scripts/measure-cost` made the same script exit 1 with `bash -n scripts/measure-cost`
named.

Commits: 84be075, 18e42af, e376411, c7bbac7

## BUILD-92

**The post-merge Scorecard workflow cannot pull its pinned action image** - measured 2026-11-24 on
the first push after PR #43 merged: `Scorecard` run `45442576517` failed in `analysis` at
`Pull ghcr.io/ossf/scorecard-action:v2.6.0` with `manifest unknown` on three retries, while the same
push's `Docs` and `Secret scan` runs were green and the PR's required checks had passed. The
workflow pins `ossf/scorecard-action@23f22cd43608bae7a1f1fa2603d7314dee9538a5` with the comment
`# v2.6.0` (`.github/workflows/scorecard.yml:40`), and the action's `runs.image` names the missing
tag, so the pin resolves but the image does not. Fix: move the pin to a release whose
`ghcr.io/ossf/scorecard-action:<tag>` image is pullable (or pin the image digest in a fork), verify
the image with `docker manifest inspect` before the action runs, and record the new pin and the
green run. Do not add a retry loop around the pull: a manifest that does not exist is deterministic.
Tests: the post-merge `Scorecard` run completes; the image check fails fast with the tag named when
it is missing.

Resolved upstream: the pin is still `ossf/scorecard-action@23f22cd… # v2.6.0`, and the
workflow now completes. The first green run after the 2026-11-24 failure is
`45904273781` (2026-11-26T22:21:36Z); `45915037604` and `45917174196` followed in
about 40s. No retry loop was added: the manifest exists, so the pull is deterministic.

Commits: 9320554, 18e42af, c7bbac7

## BUILD-93

**CI caches raw `target/` trees on every OS, and the cache is the quota** - `ci.yml` has five cargo
caches that store `~/.cargo/registry` and the whole `target` directory: `rust-tests`
(`.github/workflows/ci.yml:183`), `gut-tests` (`.github/workflows/ci.yml:271`), `windows`
(`.github/workflows/ci.yml:349`), `macos` (`.github/workflows/ci.yml:481`) and `fuzz-build`
(`.github/workflows/ci.yml:626`). `rust-tests` and `gut-tests` share the exact
`${{ runner.os }}-cargo-${{ hashFiles('**/Cargo.lock') }}` key, so a target saved by one is restored
by the other; all five are keyed on a lockfile that changes on every dependency bump. A check-shaped
target cannot satisfy a build (the v0.7.2 lesson); `release-build.yml:13-25` already counts the 10
GB budget and limits saves to the default branch, which shows the pressure is known. The audit that
opened this row estimated 2-4 GB per OS; read the actual total first and record it. Fix: replace the
five cargo entries with `Swatinem/rust-cache` pinned to a full commit SHA with the version in a
trailing comment (the `github-actions` Dependabot group moves it), one distinct `key` per job
(tests, GUT, Windows build, macOS check, fuzz), and `save-if` limited to `refs/heads/main` so
PR-scoped caches stop competing for the quota; leave the FFmpeg and vcpkg entries alone. Measure the
repository total with `gh api repos/godot-pty/gpty/actions/caches --paginate` and the restore/save
time from a run before and after. Tests: a lockfile-only PR restores dependency artifacts and saves
no PR-scoped cache; the total after a week is below the recorded ceiling; `cargo test --workspace`
passes from the restored cache.

Shipped: the five raw `target/` caches are `Swatinem/rust-cache@v2.9.3` restore-only;
a new `Cache Warm` workflow is the writer on `main` (a PR/merge-scoped cache is
unreadable by the next PR) and saves one key per platform. Run `45923611984` warmed
Linux (3m09s), Windows (4m02s), macOS (3m56s) and the fuzz workspace (6m20s), writing
`v0-rust-linux-debug` 345 MB, `v0-rust-windows-debug` 340 MB, `v0-rust-macos-check`
187 MB and `v0-rust-fuzz` 351 MB. The cleanup removed every PR/merge entry and the old
`Linux-cargo` 1222 MB, `Windows-cargo` 431 MB and `Linux-fuzz` 1010 MB keys, taking the
repository from 32 entries / 9.25 GiB to **10 entries / 1.39 GiB**; the four rust keys
are main-scoped, and the old FFmpeg keys the changed `media-deps` hash retired were
deleted too. A second dispatch `45924435909` restored the exact keys
(`Restored from cache key "v0-rust-linux-debug-…" full match: true`): Linux 49s,
Windows 1m58s, macOS 39s, fuzz 1m07s, with `cargo test --workspace` passing on Linux.
A PR run restores these keys and saves nothing (`save-if: false` in
`ci.yml`). The session's release dispatch then added its release-profile caches: the
repository stood at 17 entries / 2.64 GiB, still below the 9-10 GiB baseline.

Commits: 84be075, 18e42af, e376411, c7bbac7

## BUILD-94

**The changed-path classifier is one `code` bit, so a GDScript edit pays for Rust, Windows and macOS** - the
`changes` job (`.github/workflows/ci.yml:38-77`) writes only `code`, and every job below reads it:
`rust-tests` (`.github/workflows/ci.yml:169`), `omp-events-tests` (`.github/workflows/ci.yml:234`),
`gut-tests` (`.github/workflows/ci.yml:250`), `windows` (`.github/workflows/ci.yml:332`), `macos`
(`.github/workflows/ci.yml:467`), `rust-fmt` (`.github/workflows/ci.yml:508`), `cargo-audit`
(`.github/workflows/ci.yml:526`), `cargo-deny` (`.github/workflows/ci.yml:592`) and `fuzz-build`
(`.github/workflows/ci.yml:612`). A `godot/**`-only PR therefore runs the 60-minute Windows job and
the 10x macOS job, and an `extensions/gpty-omp-events/**`-only PR runs the whole code matrix; the
only fast path is docs-only. Fix: replace `code` with `rust`, `godot` and `node` (the macOS row adds
`macos`), keeping the current default that an unclassified path sets every output true so a new
directory is never silently skipped. Gate `rust-tests`, `rust-fmt`, `cargo-audit`, `cargo-deny` and
`fuzz-build` on `rust`; `omp-events-tests` on `node`; `gut-tests` on `rust` or `godot` (GUT loads
the extension); `windows` on `rust` (a GDScript-only PR skips the Windows job on a PR, and the merge
queue runs it). On `merge_group`, set every output true and exit, so the queue is the full-suite
gate before `main`; `ci-gate` already treats a skipped job as success. Tests: record the job list
for a docs-only PR, a `godot/**`-only PR, an `extensions/gpty-omp-events/**`-only PR and the first
merge-group run; the first three must skip the jobs above, the merge-group run must run all of them,
and `ci-gate` must pass in each.

Shipped: `scripts/classify-changes` prints `rust`, `godot`, `node` and `macos` from the
one `scripts/ci-classes.env`; PR #62 run `45921076617`'s `changes` job (28 files)
printed all four true, and the merge-group run `45922481491` ran the full matrix
(`rust-tests`, `gut-tests`, `windows`, `macos`, `static`, `fuzz-build`, the audits) with
`commit-lint` skipped for the queue. The godot-only and node-only job lists are the
fixtures in `scripts/tooling-smoke` plus the one-expression `if:` per job; no extra
closed PRs were opened for them, because that spends the merge-ratio signal BUILD-86
owns.

Commits: 84be075, 18e42af, e376411, c7bbac7

## BUILD-95

**Licensing is not machine-readable** - the repo has LICENSE, LICENSE-EXCEPTIONS.md and per-crate
Cargo license fields, but no per-file SPDX metadata or REUSE lint; the bundled
`extensions/gpty-omp-events` (MIT), `godot/addons/gut` (MIT) and the data/default files (Apache-2.0)
make the boundary worth automating. Optional for this release. Fix: a `REUSE.toml` for the GPLv3
core and the permissive exceptions, SPDX headers where practical, and `reuse lint` in `ci-check` (no
headers in JSON). Acceptance: `reuse lint` passes and the license boundary is readable without
opening LICENSE-EXCEPTIONS.

## BUILD-96

**The backfill runner's archive branch has no test** - found 2026-11-13 while backfilling the cost
history: `scripts/backfill-cost-history` extracted the four archives that had no directory beside
them and skipped the two versions already in the ledger, and all nineteen measurements landed - but
the only automated exercise is `run_tooling_scripts`' planned run (`--dry-run`), which covers
argument parsing, `find` and the plan and stops before `tar -xzf`, the directory discovery that
falls back to the `.pck`'s parent, and the skip-unless-`--force` rule. Fix: a fixture under the
tooling step - a `tar.gz` wrapping a fake release directory (an executable with a `.pck` beside it),
a ledger holding that version, and a `--dry-run` run asserting the extraction, the skip message and
the version sort - kept under a second so it fits the tooling class it runs in. Worth: the script
runs by hand once per history backfill, where a silent skip reads as a release that was never
measured.

**Implemented 2026-11-27.** `scripts/backfill-cost-history` reads `GPTY_COST_LEDGER` (default the
committed ledger). `scripts/tooling-smoke` builds two archives (the canonical directory and a
`.pck`-parent fallback) and a ledger fixture, then asserts the extraction lines, the skip message,
`--force`, and the `0.9.9`/`0.10.0` version sort. The fixture passes in under a second and never
measures.

Commits: 4877268, 18e42af, f830b0d

## BUILD-97

**Half of every GUT run is fixed `create_timer(2.1)` sleeps** - measured 2026-11-02 on a green run:
72 scripts / 913 tests take 134 s, and the tree holds 31
`await get_tree().create_timer(2.1).timeout` waits across 9 test files - 65 s of wall clock, 49% of
the suite, spent on a fixed delay whose comment is usually "let the workspace's deferred concept
push land while it is still alive". The condition each one stands for is observable (a pane's spawn
reported, a deferred push landed, a profile list refreshed), so it can be a bounded predicate that
returns as soon as the condition holds instead of a sleep that always costs 2.1 s. Fix: one helper
under `godot/tests/helpers/` (`await TestWaits.until(callable, timeout)`, polling `process_frame`)
and each fixed sleep replaced by the condition it stands for, with a generous timeout so a real
failure still fails rather than hangs (the gate's stall guard is the backstop). Acceptance: the
Linux suite runs at least 40 s faster, each replaced wait fails when its condition never holds, and
three consecutive runs are green.

**Implemented 2026-11-27.** `godot/tests/helpers/test_waits.gd` supplies the bounded predicate;
`workspace.gd`'s three 2 s deferrals now use a child `Timer` that is freed with the workspace, so
teardown no longer resumes a coroutine. All 73 fixed `create_timer(2.1)` waits are gone: 69 removed,
four (the plugin-content refresh) rewritten as `TestWaits.until`. The new regression frees a
settling workspace and waits 2.2 s inside GUT. Measured: baseline 314.4 s (135/136 scripts, because
the new test file landed during that run), then 160.8 s, 155.8 s and 156.0 s, all green with 136
scripts / 1804 tests. The suite is at least 40 s faster on every run.

Commits: 73452fe, 6cecfd6, 18e42af, b028ee9

## BUILD-98

**The README links the Linux Foundation project page and carries the OpenSSF Scorecard badge** - added
2026-11-04. The LFX submission was approved: the [project
page](https://insights.linuxfoundation.org/project/godot-pty-gpty) and the health-score badge
resolve, and the crates.io packages are linked (`gpty`, `gpty-core`, `gpty-ipc`, ecosystem `cargo`).
The README now carries the official [OpenSSF Scorecard
badge](https://securityscorecards.dev/viewer/?uri=github.com/godot-pty/gpty) (7.8/10 at the
2026-11-04 run) next to SLSA 2 and OpenSSF Best Practices; the "application is in progress" wording
is gone. The generic Linux Foundation badge was replaced on 2026-11-10 with the official
health-score badge
(`https://insights.linuxfoundation.org/api/badge/health-score?project=godot-pty-gpty`, label
`Healthy`), verified against `api/project/godot-pty-gpty`: `healthScoreV2` 74 / `healthLabel`
healthy. The category split that produces 74 is Maintainer Health 20/40 (responsiveness 15/15, bus
factor 3/18 for one maintainer, company diversity 2/7), Security and Supply Chain 32/35 (open
advisories 10/10, Scorecard 7/7 at raw 7.9, security practices 4/8, dependency health 5/5) and
Development Activity 22/25 (release cadence 8/8, commits 5/5, PR merge 3/5); the only sub-signals
here that are not structural are the two Insights rows in v0.9.3 (required reviews and status
checks, and the pull-request merge ratio).

Commits: e986c20, d1e0cf7

## BUILD-99

**The Windows media-deps step rebuilds FFmpeg from source for 26 minutes whenever the vcpkg cache misses** - measured
2026-11-16 on the 0.8.x run for the v0.8.4 release commit (job 133738552552):
`Build media dependencies` ran 01:09:10 → 01:35:49 (26m39s) inside a 35-minute `windows-smoke`,
against 10m8s for the same job on the pull-request run of the same SHA. Cause read from the log:
`Cache vcpkg FFmpeg` reported `Cache not found for input keys: vcpkg-ffmpeg-Windows-9.0.2`, and at
job end
`Failed to save: Unable to reserve cache with key vcpkg-ffmpeg-Windows-9.0.2, another job may be creating this cache`
- the push and pull_request events both start `windows-smoke` for the same commit with the same key,
so neither finds the cache and vcpkg builds all seven ports including FFmpeg 9.0.2 from source. The
repo prefix cache did restore, so `media-deps` printed "FFmpeg 9.0.2 already built" from its
`.stamp` and then fell through to the install, which is why the log contradicts itself. The key
exists now (two entries, ~178 MB each, created 01:28 and 01:34), so this recurs only after an FFmpeg
version bump or a cache eviction. Fix: stop running the Windows legs twice for one commit (a
push-run gate the PR run can skip, or a shared concurrency group) and pre-warm the key on the
integration branch so a pull request never pays the cold build; also make the `media-deps` skip path
test the vcpkg tree before printing "already built". The release path no longer takes this route:
**A tag release still builds every platform cold** now restores the built
`dist/ffmpeg/windows-x86_64` prefix and consults vcpkg only when that misses, so the remaining cost
is the CI windows jobs' own.

Shipped: the Windows release job restores the vcpkg tree on every build and saves it
from main; `media-deps` checks the tree before printing "already built" and names the
install when it is missing. The v0.8.6 tag (run `45276452554`) reproduced the defect:
the prefix hit skipped the vcpkg restore, the step printed "already built" and then
spent 20m39s in `vcpkg install ffmpeg`. The post-merge dispatch on `20c74154` (run
`45924244247`, Windows job `140261792749`) restored the tree in 16s and `Build media
dependencies` completed in the same second; the save step skipped on the cache hit.
Linux and macOS are unchanged.

Commits: 8c58684, 18e42af, 3af51f8, c7bbac7

## BUILD-100

**Release builds ship unstripped, with no cross-crate inlining, and nobody recorded the size** - the
root `Cargo.toml` declares the workspace and no `[profile.release]`, so `cargo build --release` uses
Cargo's defaults (`lto = false`, `codegen-units = 16`, `strip = "none"`); measured 2026-11-24,
`dist/libgpty_gdext.linux.x86_64.so` is 13,381,112 bytes and `file` says "not stripped", and
`target/release/gpty` is 6,087,616 bytes and also not stripped. `dist/gpty` is the Godot export and
is already stripped; it is not this row's artifact, so do not claim its size as the win. Fix: add
`[profile.release]` with `opt-level = 3`, `lto = "thin"`, `strip = "symbols"` and the largest
`codegen-units` that keeps the tag build inside the existing 60-minute job timeouts - start at 1,
fall back to 4 then 16, and record the choice. Cargo fingerprints include the profile, so the first
tag run rebuilds the affected crates; measure the `.so` and CLI sizes and the `build-linux`,
`build-windows` and `build-macos` wall times before and after. Do not promise an IPC throughput win:
measure the IPC span only if the v0.9.0 timers show it. Tests: `file` reports the built `.so` as
stripped, the sizes and wall times are in the v0.9.4 changelog, `cargo test --workspace` passes, and
Godot loads the stripped extension (the pane-API smoke is the load proof).

**Implemented 2026-11-27.** `[profile.release]` now sets `opt-level = 3`, `lto = "thin"`,
`codegen-units = 1` and `strip = "symbols"`; `build-linux` asserts both release artifacts report
`stripped`. A clean release build here took 71.6 s (well inside the 1800 s fallback threshold, so
`codegen-units` stayed at 1). Sizes: `libgpty_gdext.so` 13,381,112 → 9,834,992 bytes (−26.5%) and
`gpty` 6,087,616 → 3,883,712 bytes (−36.2%); `file` reports both as stripped. Replacing
`godot/bin/libgpty_gdext.linux.x86_64.so` with the stripped library, `godot --import` and
`ui-capture --list` both succeed (85 states), so the exported `gdext_rust_init` survives. Release dispatch 46035681169: `build-linux` 158 s,
`build-windows` 422 s, `build-macos` arm64 449 s, `build-macos` x86_64 539 s, `export` 94 s; the
`build-linux` stripped assertion and the export gate both passed.

Commits: 84be075, 18e42af, b021fb4

## BUILD-101

**The dev inner loop links every crate with the system linker and keeps full debug info** - there is
no `.cargo/config.toml` and `CONTRIBUTING.md:73` documents `cargo build -p gpty-gdext` as the daily
command, so every incremental build pays the GNU `ld` link of all crates plus the gdext shim; the
audit reported 3-5 seconds in the link step, which is a figure to reproduce, not a repository
measurement. Fix: make the fast linker opt-in, not a hard dependency - document
`RUSTFLAGS="-C link-arg=-fuse-ld=mold"` on Linux and `-fuse-ld=lld` on Windows/macOS in
CONTRIBUTING, add a small `scripts/dev-linker` helper that detects `mold` then `ld.lld`, prints the
exact export, and with `--write` writes a gitignored `.cargo/config.toml`; add `.cargo/config.toml`
to `.gitignore` so a machine-specific linker is never committed. Add
`[profile.dev] split-debuginfo = "unpacked"` to the root `Cargo.toml` (macOS already defaults to it;
Windows ignores the key). Measure an edit-rebuild of `crates/gpty-gdext/src/lib.rs` before and after
with `/usr/bin/time -v` or `cargo build --timings`, and record the link time and the `.dwo` disk
cost. Tests: `scripts/dev-linker --check` fails with a clear message when neither linker exists and
passes when one does; a clean `cargo build -p gpty-gdext` works without running the helper; the
Windows check still parses the dev profile.

**Implemented 2026-11-27.** `scripts/dev-linker` detects mold then ld.lld (lld on macOS, lld-link on
Windows), prints the `RUSTFLAGS` export, and `--write` produces a gitignored `.cargo/config.toml`;
`DEV_LINKER_BIN_DIR` makes both outcomes testable. `[profile.dev] split-debuginfo = "unpacked"` is
in the root manifest. On this machine an incremental `gpty-gdext` rebuild took 0.654 s with the
system linker and 0.642 s with mold; a `gpty` rebuild took 0.416 s vs 0.436 s. The difference is
within noise at this project size, so the helper stays opt-in rather than a hard dependency. The
unpacked debug info costs 230,205,992 bytes of `.dwo` under `target/debug`.

Commits: 84be075, 18e42af, b021fb4

## BUILD-102

**Seven crate names resolve to two versions, and most are upstream pins** - measured 2026-11-24 in
`Cargo.lock`: `bitflags` 1.3.2 (from `portable-pty` 0.9 and `defmt`) against 2.13.1, `getrandom`
0.2.17 (from `redox_users` 0.5, a Redox-only path) against 0.4.3, `shlex` 1.3.0 (from `bindgen`
0.72) against 2.0.1, `syn` 2.0.119 (from `bindgen`, `defmt-macros`, `jiff-static` and
`thiserror-impl` 1) against 3.0.10, `thiserror` and `thiserror-impl` 1.0.69 (from `filedescriptor`
0.8, which `portable-pty` pulls) against 2.0.21, and `windows-sys` 0.59.0 (from `alacritty_terminal`
0.26) against 0.61.2. `indexmap`, `hashbrown` and `redox_syscall` each resolve to one version, so
the audit list that named them is stale. Fix: attribute every duplicate to its parent and bump the
parent when a released version drops the old pin (`portable-pty`, `alacritty_terminal`, `bindgen`
are the candidates); accept the build-only `syn`/`thiserror` pairs where no single version exists,
and never hand-edit a lockfile. Remove the runtime duplicates (`bitflags`, `windows-sys`) first;
measure `cargo build --release` time and the CI cache payload before and after. If no released
parent drops a pin, record the parent and version in this row and leave it, rather than replacing a
working crate for a duplicate.

**Attributed 2026-11-27.** `cargo tree --workspace --target all -i` shows: bitflags 1.3.2 ←
portable-pty 0.9.0; getrandom 0.2.17 ← dirs 7.0.0 → dirs-sys 0.5.0 → redox_users 0.5.2
(Redox-only); shlex 1.3.0 ← bindgen 0.72.1 ← ffmpeg-sys-the-third 6.0.0 (build-only); syn 2.0.119
← bindgen/defmt-macros/jiff-static/thiserror-impl 1; thiserror and thiserror-impl 1.0.69 ←
filedescriptor 0.8.3 ← portable-pty 0.9.0; windows-sys 0.59.0 ← alacritty_terminal 0.26.0.
`portable-pty` 0.9.0 and `alacritty_terminal` 0.26.0 are the latest releases, bindgen 0.73+ is not
pinned by any released ffmpeg-sys-the-third, and dirs 7.0.0 is latest: no parent bump removes a pin.
No dependency or lockfile change; the recorded skips live in BUILD-103.

Commits: 84be075, 18e42af, 96d3797

## BUILD-103

**`multiple-versions = "warn"` lets a new duplicate land with every gate green** - `deny.toml`'s
`[bans]` sets `multiple-versions = "warn"`, and `cargo-deny` is a required job
(`.github/workflows/ci.yml:592`), so the duplicates above are printed and the gate still passes.
Fix: after the attribution row lands, set `multiple-versions = "deny"` and add `[[bans.skip]]`
entries only for the pairs no released parent can remove (`syn` against `bindgen`/proc-macros,
`thiserror` against `portable-pty`, `getrandom` on the Redox-only path), each with a one-line
comment naming the parent and the condition that removes it. Keep the `cargo-deny` job in `ci-gate`;
do not silence the check globally. Tests: the committed lock passes `cargo deny check bans`;
temporarily adding a duplicate of an unskipped crate to a crate's dev-dependencies fails the check,
and the temporary change is reverted.

**Implemented 2026-11-27.** `deny.toml` sets `multiple-versions = "deny"` and
`multiple-versions-include-dev = true`; seven `[[bans.skip]]` entries pin the recorded upstream
versions with their parent/removal comments. `cargo deny check bans` is green. Proof: adding
`hashbrown = "=0.14.5"` as a dev-dependency produced `found 2 duplicate entries for crate
'hashbrown'` and exit 2; reverting the manifest and lockfile returned it to green.

Commits: 84be075, 18e42af, f830b0d, 95a0db5

## BUILD-104

**The release export prints 288 script errors and the job cannot tell them from a broken script** - found
2026-11-16 in the v0.8.4 release run (job 133747610689, steps 8-11): 85 `SCRIPT ERROR` lines during
the import pass and 203 across the three exports, of four kinds - 144 `Could not resolve class`
(`BasePersistenceManager`), 136 `Identifier ... not declared` (`GptyTerminal`), 4
`Could not find type`, 4 `Cannot infer the type of "failure" variable`. They are import-pass noise:
the exported `gpty-gui` starts with zero script errors (measured by running the 0.8.4 linux archive
headless - its only errors are the expected "another gpty instance is already listening"). The
defect is that the step passes either way, so a script that genuinely does not compile would pass
too, and a real failure is invisible in the log. Fix: fail the export on a `SCRIPT ERROR` outside a
closed set of the four expected import classes, the same shape as `scripts/ui-capture`'s own log
gate, and name that set in the step so it stays a list rather than a threshold.

**Implemented 2026-11-27.** `scripts/export-check` runs a command through `tee`, passes its exit
status, and fails on any `SCRIPT ERROR`/`Failed to load script` outside the four named import-pass
classes and the 15 dependent script names those classes make unloadable. The import and all three
export steps call it; `--check-log` fixtures cover the known lines, an unknown parse error and an
unknown failed script. The first release dispatch (run 46033110660) rejected the `Failed to load
script` lines for `workspace.gd` and the 14 dependent autoloads; 290e470 added that closed list, and
replaying the real import log through `--check-log` now exits 0. A local
`godot --headless --path godot --import` also exits 0. Release dispatch 46035681169 passed the
import and all three exports through the gate; the `export` job succeeded.

Commits: 8c58684, 18e42af, b021fb4, f830b0d, 290e470

## BUILD-105

**The macOS export leaves the Metal shader baker off** - found 2026-11-21 while reviewing the
Windows/macOS GPU paths: the macOS preset sets `shader_baker/enabled=false`
(`godot/export_presets.cfg`), and `release-build.yml` builds the app on `macos-15` and
`macos-15-intel`, so the 3D vault graph's Metal pipelines compile on the user's first open instead
of at export. That first open is the visible stutter in the same class as the cold pipeline cache
recorded in **An idle window costs 650-760 MB and the renderer is most of it, not the terminal**.
Fix: enable the baker for the macOS preset and prove the release runner has a Metal device that can
bake (it may be virtualized; if it cannot, record the blocker and leave the setting off with the
reason); bake at export, check the generated shader cache lands in the `.app`, re-sign if the baker
writes after signing, and measure the graph's first-open time and the bundle size on a real Mac.
Linux and Windows stay unchanged until their backends demonstrate the same. Tests: a release-build
check asserts the macOS bundle carries the cache and the app opens the graph without the compile
hitch; record the numbers in the v0.9.0 budget table.

**Blocked 2026-11-27.** The export job (`release-build.yml`) runs on `ubuntu-24.04` and calls
`godot --headless --path godot --export-release "macOS"`. Godot 4.7's shader baker is not supported
under `--headless`, and a Linux editor can bake Vulkan only; the Metal baker requires a macOS editor,
so the export host cannot produce the cache at all. Godot 4.7.2 issue #123266 is a second blocker:
with `application/min_macos_version_arm64` below 14.00 (the preset has 11.00), a baked build aborts
on Apple Silicon; 14.00 works, and the export-side cache must be cleared between bakes. The preset
stays off; the macOS export move and the min-version decision are tracked by BUILD-138. No size or
first-open number can be claimed from this row.

Blocked by: BUILD-138.

## BUILD-106

**The macOS runner is billed at 10x and runs on every code PR** - the `macos` job
(`.github/workflows/ci.yml:467-506`) runs `cargo check --workspace --tests` on `macos-15` with a
60-minute cap and `needs.changes.outputs.code == 'true'`, so a PR that touches only shared Rust or
GDScript pays a 10x-minute check; the job is compile-only, and the runtime smoke is the coverage row
below. Fix: after the classifier split, add a `macos` output that is true on `merge_group` and, on
PRs, only for the macOS-relevant paths - `crates/gpty-ipc/**` (the macOS peer-credential arms at
`crates/gpty-ipc/src/server.rs:465` and `crates/gpty-ipc/src/server.rs:524`),
`crates/gpty-gdext/build.rs`, `crates/gpty-media/**`, `Cargo.toml`, `Cargo.lock`,
`scripts/install-rust`, `scripts/media-deps`, `dist/ffmpeg/**` and `.github/workflows/ci.yml`; gate
both the compile job and the coverage row's smoke on it. A GDScript-only PR therefore skips macOS on
the PR and still gets it in the merge queue. Do not substitute a Linux
`cargo check --target aarch64-apple-darwin` for the whole workspace: `libsqlite3-sys` and the FFmpeg
bindings build C for the host; if a subset (`gpty-ipc`, `gpty-ai`) checks cleanly, add it as a
PR-time signal, but do not block this row on it. Measure the macOS job minutes from
`gh run view --json jobs` before and after and record them. Tests: a shared-Rust PR's run skips
`macos`; a `crates/gpty-ipc/src/server.rs` PR runs it; a merge-group run always runs it.

Shipped: `macos` reads `needs.changes.outputs.macos`; the bit is set by
`crates/gpty-ipc/**`, `crates/gpty-gdext/build.rs`, `crates/gpty-media/**`, `Cargo.toml`,
`Cargo.lock`, `rust-toolchain.toml`, `scripts/install-rust`, `scripts/media-deps` and
`dist/ffmpeg/**`, and by any unclassified path. PR #62 run `45921076617`'s `macos` job
passed in 3m23s; the merge queue always runs it. The fixture `crates/gpty-ipc/src/server.rs`
sets both `rust` and `macos`.

Commits: 84be075, 18e42af, e376411, c7bbac7

## BUILD-107

**macOS has a compile job but no GUT or smoke, so runtime behavior is only release-tested** - found
2026-11-21 while reviewing the Windows/macOS paths, narrowed 2026-11-23: `ci.yml`'s `macos` job now
runs `cargo check --workspace --tests`, but the GDScript suite and pane-API smoke still run only on
Linux and Windows (`windows`), and macOS runtime behavior is only exercised by `release-build.yml`
(build and bundle) on tags; the platform-conditional code added this session (the Windows/macOS
`RendererInfo.hint()` else branch, `DisplayServer.screen_get_scale`/`window_get_current_screen`, the
Forward+-only glow, the About renderer line) is exercised on Windows but never on Darwin. Fix: the
compile job is in place; add a `macos-smoke` job on `macos-15` that reuses the compile cache, builds
the GDExtension (arm64) and the CLI, installs Godot headless, imports the project, runs `--dir unit`
plus the platform-specific tests and the pane-API smoke, and is gated by the `macos` classifier
output (the row above), so it runs on macOS-relevant PRs and always in the merge queue instead of on
every code PR; a headed GPU/Retina check remains a separate manual/release step because the runner
may be virtualized. Tests: the job's green run on this SHA; `RendererInfo`'s else branch and the
Retina scale path appear in the log; a GDScript-only PR's run skips it and a merge-group run
includes it.

**Implemented 2026-11-27.** `scripts/install-godot` resolves `macos-arm64` from the pinned universal
archive (SHA512 added to `godot-version.json`) and puts the nested `Godot.app/Contents/MacOS`
executable on PATH. The `macos` job (75-minute cap) now installs Godot, builds the CLI/extension,
imports, runs `ui-capture --check`, the pane-API smoke, `--dir unit` and the five platform-path
tests. `scripts/classify-changes` prints `macos=false` for a GDScript path and `macos=true` for
`Cargo.toml`. The first macOS run (46033100783) found the helpers were Bash 4-only: `ui-sandbox`
used `[[ -v ]]`, `gut-check` used `declare -A` and `ui-capture-check` used `mapfile`, which macOS
`/bin/bash` 3.2 rejects. 11c21b8 replaces them with an eval set test, an indexed file list and a
read loop. The next run (46035674994) reached GUT and failed only on the one legitimate `/proc`
pending test; 7a53397 allows the documented macOS pending test (printed) while Linux still fails an
accidental skip. The next run is the proof.

Commits: 68f0558, 18e42af, f830b0d, 11c21b8, 7a53397

## BUILD-108

**`measure-cost --check` still hard-fails on a stamp older than the workspace** - found 2026-11-23
after `--stamp` was relaxed to the newest ledger build: `scripts/measure-cost`'s final `--check`
block still compares the README stamp with `crate_version()`, so a weekly Bench run on a bumped
workspace fails its stamp line even when the rows match. The published table is allowed to name the
last measured build. Fix: compare the stamp with the newest release in
`docs/data/cost-history.json`, the same rule as `--stamp`; leave row drift as the check's signal.
Tests: a version bump with an unchanged ledger leaves the stamp line green; advancing the ledger
without moving the README stamp fails.

**Implemented 2026-11-27.** `scripts/measure-cost` has one `newest_ledger_version()` used by both
`--stamp` and a new early `--check` gate; the old final `crate_version()` comparison is gone.
`--stamp` is green. With the README stamp temporarily changed to v0.0.0, `--check` exits 1 with
`measure-cost: STAMP: README names v0.0.0, newest ledger build is v0.8.6 - ...` before any launch;
the README was restored.

Commits: 7923ac2, 18e42af, f830b0d

## BUILD-109

**The harness-load gate cannot prove it would fail** - the first `ui-capture --list` gate exited 0
and printed all 85 states while a typed dependency failed to compile; the fix added the engine-log
judge, but its negative proof was a temporary `var _probe: UiMotion` that was removed, so a future
Godot change that compiles the harness differently could leave the gate green with no self-test.
Fix: `ui-capture --check` runs the clean `--list` load (no `SCRIPT ERROR`/`Failed to load script`,
at least one state) and a generated probe at `godot/tests/bench/.gate-probe.gd`
(`extends SceneTree`, `var _probe: UiMotion`, `func _initialize(): quit(0)`), run with
`--headless --path godot -s res://tests/bench/.gate-probe.gd`; it passes only if the probe prints a
script error or exits non-zero, then removes the probe in a `trap` and gitignores it (fall back to
`_gate_probe.gd` if Godot refuses the dotfile). `scripts/ci-check` and the Linux `gut-tests` job
call `--check`; `ui-capture-check` keeps `--list` for the state names. Tests: `--check` prints
"harness loads (N states)" and "negative probe refused"; a scratch legal probe fails with "the load
gate no longer detects a typed app class".

**Implemented 2026-11-27.** `scripts/ui-capture --check` runs the clean `-s` harness load (85
states), then writes the typed-field probe, requires a `SCRIPT ERROR`, and removes the probe on
exit; the dotfile falls back to `_gate_probe.gd`. `--check` prints `harness loads (85 states)` and
`negative probe refused`; a clean scratch probe exits 1 with `the load gate no longer detects a
typed app class`, and no probe file remains. `ci-check` and the Linux CI job call `--check`.

Commits: 3153852, 18e42af, f830b0d

## BUILD-110

**The local gate cannot be narrowed, reused, or asked for help** - `./scripts/ci-check --help` ran
the full 388 s gate, there is no `--only` or `--list-steps`, and the same `90984b3` tree was gated
three times (~375 s each) across two failed SSH pushes and the HTTPS retry because the pre-push hook
always reruns the suite for the same SHA. Fix: `-h\|--help` prints the header and exits 0, an
unknown argument exits 2; split the linear steps into `step_<id>` functions in an ordered `STEPS`
list
(`media fmt workflows docs capabilities secrets theme guards ffi log tests gdext gut smoke audit deny cross cost`),
add `--list-steps` and `--only <id[,id]>`; `--stamp` writes `.git/gpty-ci-check.stamp` after a full
pass on a clean tree with the tree hash, the `ci-check` and `githooks/pre-push` hashes, and the
rustc/cargo/godot versions; `--stamped` skips the gate only when all match and the tree is clean,
otherwise runs it and stamps; `--stamp-check` reports validity without running; `githooks/pre-push`
calls `--stamped`. Tests in `run_tooling_scripts`: help and unknown-option exit codes, `--only docs`
runs only docs, and the stamp accepts a matching fixture while rejecting a changed tree, ci-check
hash, hook hash, tool version or dirty tree.

**Implemented 2026-11-27.** `scripts/ci-check` has the ordered `STEPS` list, `step_<id>` functions,
`--help`, `--list-steps`, `--only`, `--fast`, and the `.git/gpty-ci-check.stamp` fingerprint over the
tree, the gate script, the pre-push hook and the rustc/cargo/Godot versions. `--stamped` skips only
a matching clean tree, `--stamp-check` reports, and `--stamp` runs the full gate and writes. The
fast gate passes in 32.9 s; `--only docs` passes without reaching `cargo test`; the stamp fixture
accepts itself and rejects every changed field and a dirty tree.

Commits: 3153852, 18e42af, f830b0d

## BUILD-111

**The roadmap is read and closed by hand, and a row read is truncated** - shipped 2026-11-26: one
`scripts/roadmap` reads and writes the ledger; `next` prints the first open row (ID, release, title,
detail path), `show <ID>` prints the index line and the full `## <ID>` section, and the evidence
bodies are wrapped at 100 columns, so a read no longer hits the 768-byte display truncation (the
longest unbreakable code span is 433 bytes). `next-id` allocates, `close <ID>` flips the status and
writes the oldest-first `Commits:` line from `Roadmap: <ID>` trailers or the row's line history,
`rearea` moves an open row between areas and rewrites the capability `row` values, `stats` counts,
and `release-check` gates a release. The title-substring commands in the original fix direction are
gone: stable IDs replaced the text match that had to stay byte-identical, and `close --text-file` is
replaced by editing the evidence section directly before closing. Writes are atomic (a sibling temp
file plus `os.replace`). Tests: `./scripts/roadmap selftest` builds a throwaway fixture and
exercises next/show/close/rearea/stats/release-check, including a commit-less close and the empty
queue; `ci-check` and the Docs workflow run it, and `docs-check` checks index/detail agreement,
titles, section order and Commits.

Commits: 3153852, 18e42af

## BUILD-112

**The capture check launches 256 Godots serially** - the full `ui-capture-check` on 2026-11-25 ran
85 states x 3 captures plus the negative control = 256 launches in 1100 s, while a 3-state subset
took 43 s; every launch is independent (its own sandbox and viewport). Fix:
`ui-capture-check --jobs N` (default 1, positive integer) with a `wait -n` pool across the two
determinism runs per state and the perturb run across states; per-state runs stay sequential, logs
keep their names, the differing list is sorted, and the negative control is last. Tests: `--jobs 4`
passes; every `first/<state>.png` from a `--keep` serial run matches the parallel run through
`scripts/ui-capture --compare`; record the wall time and keep the default at 1 until it passes on
the bake-off display.

## BUILD-113

**A tooling script's `--help` can run it, and an unknown flag is ignored** - `./scripts/ci-check --help`
ran the full gate and `python3 scripts/build-wiki --help` rewrote the bundle (both 2026-11-25);
`build-docs`, `docs-check` and `ui-capture-check` have no help path and generally treat an unknown
flag as a state or path. Fix: every script in the tooling-class list plus `build-wiki`,
`build-docs`, `docs-check` and `ui-capture-check` answers `-h\|--help` with its usage (shell scripts
print the header comment, Python scripts use argparse) and exits 0, and prints usage to stderr and
exits 2 on an unknown option; `ci-check` is the row above. Tests in `run_tooling_scripts`: loop the
same set, `--help` exits 0 and prints usage, `--definitely-not-an-option` exits 2.

**Implemented 2026-11-27.** `check-secrets`, `bot-token`, `git-askpass-token` (help only),
`install-rust`, `ui-capture`, `ui-capture-check`, `build-wiki`, `build-docs`, `docs-check`,
`tooling-smoke`, `dev-linker`, `export-check` and `ci-check` now answer `--help` with usage and exit
0; every listed script except the git prompt helper rejects an unknown option with exit 2.
`tooling-smoke` loops the contract.

Commits: 3153852, 18e42af, f830b0d

## BUILD-114

**One command installs it** - every install today is "download a 43 MiB tarball, extract it, find
`gpty-gui.sh`, remember where the folder is". Fix: `install.sh` (POSIX `sh`, `set -eu`, no
`bash`-isms, because the script is piped into a shell and may assume nothing beyond that) that
resolves the release (`latest` redirect, or `GPTY_VERSION`), downloads the archive and `SHA256SUMS`,
verifies the sum (`sha256sum -c --ignore-missing`), extracts to `~/.local/share/gpty/<version>/`,
symlinks `gpty` and `gpty-gui` into `~/.local/bin`, prints the PATH line and the shell profile to
add when that directory is not on it, and re-runs as an upgrade (same version = no-op, older =
replace the symlink, the old directory stays until `--prune`). Published as a release asset so
`https://github.com/godot-pty/gpty/releases/latest/download/install.sh` is always the script of the
release it installs, and mirrored at `gpty.dev/install.sh` from the Pages build; macOS installs
`~/Applications/gPTY.app` and the CLI beside it, and curl writes no `com.apple.quarantine` xattr,
which is why this path runs an unsigned build while a browser download of the same build does not.
Windows is `install.ps1` (extract to `%LOCALAPPDATA%\gpty`, user PATH entry) and is second priority:
winget is the better Windows answer and lives in v1.0. Verified by running it on a fresh container
against the last release and by installing twice (idempotence) and one version back (upgrade). Owner
decision 2026-10-25: next minor release.

## BUILD-115

**The CLI finds a GUI that a package manager installed** - `find_gui_binary` searches only the CLI's
own directory (`gui_candidates`, `daemon.rs:427`), the macOS `.app` under `/Applications` and
`~/Applications`, plus the explicit `GPTY_GUI` override. That covers the tarball (which ships both
halves side by side) and nothing else: winget, Homebrew, the AUR and `cargo install gpty` each put
the CLI and the GUI in unrelated directories, and Windows compares the literal name `gpty-gui`,
which never matches the shipped `gpty-gui.exe`, so `gpty daemon start` cannot find the GUI on
Windows at all. This is the prerequisite for every distribution channel below and for the registry
entry: an MCP client launches a CLI with no GUI beside it. Additionally,
`crates/gpty-ipc/src/transport.rs:366`'s `validate_gui_binary` requires
`meta.uid() == libc::geteuid()`, refusing `meta.uid() == 0`: setting `GPTY_GUI=/usr/bin/gpty-gui` or
pointing at a global install owned by root fails validation with "ignoring GPTY_GUI override". Fix:
add `PATH` to the candidate list (after the bundle siblings, which are the exact version that
shipped) and carry the platform's executable suffix in the names; accept root-owned binaries
(`owner == me \|\| owner == 0`) in `validate_gui_binary` while keeping the mode `0o022` non-writable
checks; `GPTY_GUI` stays the explicit override and `launchable` keeps rejecting relative,
world-writable and non-file candidates. Tests: PATH hit, sibling precedence, root-owned GUI
validation, and the suffixed name.

## BUILD-116

**The MCP entry installs without a Rust toolchain** - the entry names a `cargo` package, so an MCP
client can only start `gpty mcp` after rustup and a C compiler have built the CLI. An `mcpb` package
removes that: a bundle carrying the three platform CLIs plus a `manifest.json`
(`server.type: binary`, `mcp_config.command` per platform through `platform_overrides`), published
as a release asset and described in `server.json` with its `fileSha256` (the registry requires the
hash, and the bundle URL must contain "mcp"). Two constraints: the bundle carries the CLI only - the
desktop app still comes from the release archives, so the entry's text has to say so - and the CLI
must find a GUI installed elsewhere, which is the row above. Verification: install the bundle in a
client on a machine with no Rust toolchain and run `list-panes` against a running GUI.

## BUILD-117

**Self-contained air-gapped installation archive** - enterprises operating in defense, banking, and
secure enclaves run in air-gapped networks with no outbound internet access. The current
distribution relies on runtime downloads for certain documentation references, external update
checks, and system font discovery. Fix: add a `make-enterprise-bundle` target producing a 100%
self-contained offline tarball/zip containing bundled font fallbacks, complete offline documentation
and wiki assets, pre-compiled FFmpeg shared libraries, and build-time flags that hard-disable update
checking (`cfg_telemetry=false`, `update_checker` disabled). Tests: verify that booting the
enterprise bundle in an `unshare -n` network-isolated namespace starts cleanly, renders fonts and
documentation without network timeouts, and logs zero connection attempts.

## BUILD-118

**FFI fuzz testing** - fuzzing *through* the GDExtension boundary itself (the binary interface and
its Godot-side callers) and a continuous run on an external fuzzing service. The Rust-side targets
(grid `feed`, line parser, IPC decode, Markdown and vault code) are built in v0.7.1; this is what
that leaves.

## BUILD-119

**Distribution** - Homebrew tap, winget, and the AUR package's release-time update (promoted from
Future: launch blockers), on top of the GitHub release bundles. `install.sh` moved to v0.9.6 (owner
decision 2026-10-25); what is left here is the package managers that put `gpty` on `PATH` with no
terminal step, and both depend on the CLI finding a GUI that was installed somewhere else (also
v0.9.6). The AUR half is validated and blocked on registration: `dist/aur/PKGBUILD` carries
`pkgver=0.8.3` and the v0.8.3 tarball's SHA-256, and `makepkg --noconfirm` builds `gpty-bin 0.8.3-1`
(re-validated for v0.8.3 on 2026-11-14), but `ssh -T aur@aur.archlinux.org` still answers
`Permission denied (publickey)` (re-probed 2026-11-12) because the AUR has paused account
registration. Owner decision 2026-11-12: releases keep the recipe current and validated but do not
probe or push to the AUR, and do not report the failure, until this row resolves an account.

## BUILD-120

**Code signing** - macOS notarization + Windows Authenticode (promoted from Future:
SmartScreen/Gatekeeper warnings are launch-killers). **Decided 2026-10-25:** Windows goes through
the SignPath Foundation (free for qualifying open source) rather than a paid certificate; the
application is submitted and on hold until the project has published articles/posts it can point at
as evidence of use, so Windows signing waits on that. macOS notarization is held to the same point,
and it is not needed for the installer: a curl-downloaded build carries no `com.apple.quarantine`
xattr, so `install.sh` runs an unsigned build while a browser download of the same build is refused
on macOS 15+. Do not buy an EV certificate in the meantime: since 2024 EV no longer bypasses
SmartScreen (Microsoft's own guidance).

## BUILD-121

**Desktop-control agents are not part of the capture pipeline** - evaluated
`agent-sh/computer-use-linux` (2026-10-31) for release screenshots, UI-audit evidence and demo
recordings; every job is already covered without a privileged input path. Evidence captures are the
app's own viewport (`root.get_texture().get_image()`, `godot/tests/bench/draw_bench.gd:112`), which
needs no compositor, portal, XWayland or window targeting, and `scripts/record-demo` records an
X11/XWayland window with ffmpeg while driving it through the `gpty` CLI, so the tool's AT-SPI
selectors and Wayland window targeting solve nothing here, its screenshots arrive bounded to 1920 px
/ 2 MiB and possibly JPEG (a KDE Wayland grab is either the same X11 root image or a portal capture
cropped after the fact), and it has no video capture at all. Its real cost is `/dev/uinput` or the
RemoteDesktop portal plus `destructiveHint` click/drag/type, which would repeal `record-demo`'s
documented "never touches your keyboard, pointer, or input permissions". Reopening evidence: capture
has to work on a pure-Wayland session without XWayland - the one gap both scripts carry, and the fix
there is a native recorder (`wf-recorder`, KDE ScreenCast into ffmpeg), not an MCP - or a UI defect
proves the OS input path itself, where `xdotool` against the XWayland client
(`--display-driver x11`) is the one-probe tool.

## BUILD-122

**Agent-config linters are not a CI gate (agnix evaluated)** - ran `agent-sh/agnix` 0.60.2
(2026-10-31) over `.omp/skills`, `crates/gpty-cli/skills/gpty/SKILL.md`, `AGENTS.md` and `mcp.json`:
0 errors on every real config, and 28 of the 32 whole-repo findings are false positives on the Hugo
guide pages under `docs/content/docs/agents/` (CC-AG-002/CC-AG-019 read their `title`/`weight`
frontmatter as a Claude Code subagent that is missing `description`), plus CDX-AG-002 firing on
`id-token: write` in the licensing paragraph. The signal that survives is four rules, all satisfied
today: frontmatter shape, name equals directory, description within 1024 chars, body under 500 lines
and ~5000 tokens (`release` is the largest at 212 lines / ~4800 tokens). Learnings kept from it: (1)
AS-020 wants the description to say when to load the skill - 10 of ours say only what it does, which
matters only outside OMP, because OMP caches generated trigger descriptions in
`~/.omp/agent/skill-descriptions.db` and injects those instead of the file text; (2) `$1`-`$9` and
`$ARGUMENTS` are substituted into skill bodies by clients with skill arguments (OMP does it for
slash commands, Claude Code for skills), so `gpty-live-gui-smoke`'s `awk ... $2` would lose its
field if the skill ever leaves OMP; (3) the reusable artifact is the machine-readable rules catalog
(`knowledge-base/rules.json`, with severity, normative level, source URL and good/bad example per
rule) - the 26 Agent Skills rules were applied here from it without installing anything. Reopening
evidence: a skill ships for a client other than OMP, or a skill approaches the body budget - then
add a dependency-free `scripts/check-skills` instead of the linter.

## BUILD-123

**A review pass repeats its own verification work: the adjudications have nowhere to live** - measured
2026-11-08 on this tree: 24 slices through three lenses (a 12-13B local model, about 14 minutes of
GPU) produced 195 findings, 165 distinct, 77 passing mechanical grounding, and after hand
adjudication one new defect (the plugin output cap, queued in v0.9.5) - while about a dozen claims
died on a *guard* worth remembering (`MAX_CAPTURE_BYTES` bounds the capture buffer, `note_path`
rejects every non-`Normal` component, the audio resampler checks its sample arithmetic before
allocating, IPC pending queues prune on timeout, `validate_program` refuses a relative PATH hit).
None of it survives: the next pass pays the same hour of reading to reject the same claims, and a
model cannot be told which ground is already settled. If built: (1) a one-line-per-entry JSONL
ledger of *settled* claims (claim, file, symbol, verdict `open`/`fixed`/`rejected`/`accepted`, the
refuting or protecting guard, the roadmap row for an `open` or `fixed` entry, and the model plus
commit it was anchored at) checked by `scripts/check-review-ledger`: closed keys, an `open` entry's
row title must exist on a chain page, a `fixed` entry's symbol and guard token must still exist, and
`rejected` entries stay informational so an intentional refactor cannot trip it; (2) a local-only
card runner - one file and one falsifiable question per call, accept only a JSON answer whose cited
symbol and guard token exist in that file, retry once with the failure text appended, and refuse a
card whose claim hash is already settled. Not committed: raw claims, evidence prose, line numbers or
transcripts; a row stays the outcome, the ledger is the evidence a row cites, and no audit document
is added. Entries anchor to a symbol and a commit because line numbers rot - the same pass produced
a citation that `docs-check` rejects. Evidence to start it: the local profile stays in use for
triage or changelogs and a second sweep would otherwise re-verify the same guards; the gate has a
home beside `check-log-hygiene` in `ci-check` and in the gate table in
`docs/content/docs/agents/testing.md`.

## BUILD-124

**Screenshot annotation is manual, and nothing records its style** - every screenshot on a
`## Screenshots` page needs numbered boxes drawn *into* the PNG, and there is no tool: the
2026-11-24 v0.8.7 captures copied the style by sampling an existing image (2 px `#ff8080` outline,
an 80x100 box, a 20 px number) and drew it with a throwaway PIL snippet that finds its way into no
commit. The caption's `Box 1`/`Box 2` and the drawn numbers are the only link, so a recapture
silently drops or misnumbers them. Fix direction:
`scripts/annotate-capture <png> <x0,y0,x1,y1>=<n> ...` with the style as constants (and a `--list`
of a state's boxes), or a per-state sidecar `godot/tests/bench/captures/<state>.json` the capture
script applies; the `ui_capture` states already name their boxes in the chain page, so the sidecar
is the natural single source.

## BUILD-125

**`draw_bench` prints one run, so a row's number is a hand-taken median** - the v0.8.7 backdrop row
quotes `draw_us` 1432.1 flat / 1451.6 gradient as a median of three because one run moves by ±50 µs
(measured 2026-11-24: five flat runs 1389-1436, three gradient runs 1419-1471 on the RTX 5070 Ti);
the numbers only exist in the row text and the shell history. Fix: `BENCH_REPEAT=N` (or
`--repeat N`) printing per-mode min/median/max and a machine-readable line, so a quoted figure names
its statistic and a follow-up can re-take it.

## BUILD-126

**The docs-class local gate skips `check-secrets`** - the 2026-11-26 docs-class change put
workflow-YAML and docs pushes on a 4.6 s path (workflow lint, docs-check, the catalogue, the ledger,
both bundles and the cost stamp), but `check-secrets` stayed in the full/tooling section. The
required remote Secret scan catches a key on the PR, yet a docs push can pass locally and fail
remotely. Fix: run `scripts/check-secrets` in the docs branch (about a second) or state the reliance
in `testing.md`; add a fixture that plants a fake key and expects the docs path to fail.

**Implemented 2026-11-27.** The docs-class branch of `ci-check` now runs `scripts/check-secrets`
(`SELECTED=(workflows docs capabilities secrets cost)`), and `check-secrets --root DIR` scans
another work tree's index so `scripts/tooling-smoke` can plant `sk_live_…` in a fixture and require
the gate to name the rule, then pass once it is unstaged.

Commits: 5fbf5b5, 3d4b544

## BUILD-127

**The CI docs class is five copies with no drift check** - the 2026-11-26 change had to update five
copies of the docs class: the `changes` case in `.github/workflows/ci.yml`, `docs_class_path` in
`scripts/ci-check`, the class paragraph in `docs/content/docs/agents/testing.md`, and the commit and
session-wrap-up skills. The two executable lists differ only in redundant entries
(`LICENSE-EXCEPTIONS.md` is already covered by `*.md`), so a drift check is cheap. Fix:
`scripts/check-ci-classes` canonicalises the two lists (path or glob, sorted) and fails on drift;
run it from `ci-check` and the Docs workflow.

Shipped: `scripts/ci-classes.env` is the one source for `DOCS_PATTERNS`,
`TOOLING_PATTERNS` and the classifier's path lists; `scripts/ci-check` sources it and
`scripts/classify-changes` reads it, while `testing.md` and the commit/session skills
point at it instead of copying the list. The drift the row described is structurally
impossible, so no `check-ci-classes` script was added; the classifier fixtures in
`scripts/tooling-smoke` exercise the patterns.

Commits: 5fbf5b5, e376411, c7bbac7

## BUILD-128

**Four tools parse the roadmap index row** - `docs-check`, `scripts/check-capabilities`,
`scripts/render-capabilities` and `scripts/roadmap` each carry the
`| status | [ID](details/area.md#id) | **Title** |` row regex, the ID rule and the detail path; the
2026-11-26 split edited all four and the wrapper added a fifth copy of the line-length rule. Fix:
one `scripts/roadmap_lib.py` with the row parser, ID regex, detail path and wrap helper, imported by
all four; the ledger selftest parses the same fixture through it.

**Implemented 2026-11-27.** `scripts/roadmap_lib.py` owns the row parser, the ID rule,
`detail_link`, `page_names`, `areas`, `front_matter`, `COMMIT_RE`/`COMMIT_LINE`, the 768-byte cap
and the `wrap` helper; `scripts/roadmap`, `scripts/docs-check`, `scripts/check-capabilities` and
`scripts/render-capabilities` import it, and the `❌`-row labelling bug the old renderer regex
carried is gone. `scripts/tooling-smoke` compiles the module, `DOCS_PATTERNS` and the `Docs`
workflow watch it, and the ledger selftest exercises the same parser on its fixture.

Commits: 5fbf5b5, 3d4b544

## BUILD-129

**docs-check does not enforce the evidence shape it relies on** - `docs-check` proves index/detail
set equality, titles, section order and the `Commits:` line, but not a detail line over 768 bytes
(BUILD-111's 7 KB line was wrapped by a one-off script), not a `screenshots/<page>.md` no page
links, and not a chain page that has captures but no page link. A new row or screenshot page can
regress the read or the links with every gate green. Fix: a max line length for detail and
screenshot pages, a screenshot-page link/orphan check, and a selftest fixture that trips each.

**Implemented 2026-11-27.** `docs-check` reads `DOCS_ROOT` and rejects a detail or screenshot line
over 768 bytes and a screenshot page no page outside `screenshots/` links; the one real offender
(`screenshots/v0.8.md`, 779 bytes) is wrapped. `scripts/tooling-smoke`'s `docs-check evidence
fixture` builds a passing tree, then trips each rule (`line is 800 bytes (cap 768)`, `screenshot
page is not linked from any markdown page`), so a gate that stopped catching them fails the smoke.

Commits: 5fbf5b5, 3d4b544

## BUILD-130

**The ledger has no add, move or record command** - `next-id` allocates, but adding a row still
hand-places the index row at the priority position, appends the `## ID` section and wraps the body
(BUILD-111's evidence was placed and wrapped by a TEMP script); moving a row between release
sections is a manual index edit, and the original BUILD-111 `close --text-file` became "edit the
detail first". Fix: `roadmap add` (allocate, index, detail, wrap), `roadmap move <ID> <release>`
(index only; the detail stays), and `roadmap record <ID> --body-file` (replace and wrap the
evidence).

**Implemented 2026-11-27.** `roadmap add` allocates the ID, writes the `## ID` section and places
the index row (default: the working section; `--after`/`--before`, `--chain`, `--dry-run`); `move
<ID> <release>` moves an open row between sections or chains without touching the detail page;
`record --body-file [--append]` rewrites the evidence, preserving `Commits:` and refusing a retitle
or a body that carries the line itself. All three wrap at 100 columns through `roadmap_lib.wrap` and
are exercised in `roadmap selftest` on fixture copies.

Commits: 5fbf5b5, 3d4b544

## BUILD-131

**The ledger's audit is a parse, not a check** - `docs-check` proves agreement and the `Commits:`
shape and `roadmap selftest` exercises the happy path, but nothing checks that a `Commits:` hash is
reachable, that a `🚫` row states why, that a detail line is under 768 bytes, or that an ID cited in
prose exists; the selftest misses `--json`, `--dry-run`, an unknown ID and a malformed fixture. Fix:
`roadmap audit` (local; hashes, line length, ID references, dropped reason) plus those selftest
cases; `release-check --open` is the queue-view row.

**Implemented 2026-11-27.** `roadmap audit` checks every recorded hash is reachable from a ref
(skipped with a printed note on a shallow clone), no detail or screenshot line is over 768 bytes,
every ID cited in prose is a row, a 🚫/❌ row opens a reason paragraph, and each `ROADMAP.md` chain
count matches. `ci-check`'s roadmap step and the `Docs` workflow run it; the selftest trips all five
rules plus a malformed index row, and covers `--json`, `--dry-run` and an unknown ID. Measured 0.1 s
on the full ledger.

Commits: 5fbf5b5, 3d4b544

## BUILD-132

**The local gate prints its whole test log on a pass** - the 2026-11-26 full gate printed 6,567
lines (~308 KB), mostly cargo/GUT/smoke output, while a reader needs the named PASS/FAIL lines; a
failed step still needs its log. Fix: `ci-check --summary` (or `--quiet`) captures each gate's
output to a log, prints the named result and the log path, and dumps the log only for a failure;
`--verbose` keeps today's stream. The pre-push hook prints the same summary.

**Implemented 2026-11-27.** `ci-check --summary` runs each step with its output in
`/tmp/gpty-ci-check/<step>.log`, prints the named PASS/FAIL/SKIP lines and the directory, and dumps
a failing step's log; an `if`-guarded brace group keeps `FAILED` and the media/Godot caches while
letting every gate in a step report. The pre-push hook passes it (`CI_CHECK_VERBOSE=1` streams).
Measured: `--only docs` prints 13 lines instead of the gate bodies, and the full gate's 6,567-line
stream becomes one result per gate.

Commits: 5fbf5b5, 3d4b544

## BUILD-133

**A workflow push still needs a hand-built token dance** - the 2026-11-26 branch edited
`.github/workflows/*`; `bot-push` cannot push it (no `workflows` permission), the SSH push died with
SIGPIPE after the 6-minute hook, and the working path was `gh auth token` plus a temporary
`GIT_ASKPASS` and an explicit `git push https://...`. `bot-token --check` also ignores the
conventional `~/.config/gpty/gpty-bot.pem`, so `--key` was needed on every bot call. Fix:
`scripts/maintainer-push` (one command, token via askpass) and a `bot-token` default to the
conventional key path; document the two-push order.

Shipped: `scripts/bot-token` defaults to `~/.config/gpty/gpty-bot.pem` (the key it
already documented), `scripts/git-askpass-token` carries either the maintainer's
`GPTY_GIT_TOKEN_FILE` or the bot's `GPTY_BOT_TOKEN_FILE`, and `scripts/pr push` is the
one command that performs the two-push order. `scripts/bot-token --check` passes with
no environment variable set.

Commits: 5fbf5b5, c03364e, c7bbac7

## BUILD-134

**The pre-push hook treats tags and deletes as full-suite pushes** - the new-branch fallback
classifies against the merge-base with `origin/main`; a tag ref or a zero local sha has no merge
base, so the hook falls back to the full suite. Tags and branch deletes never need the app matrix.
Fix: skip refs that are not `refs/heads/*` and a zero local sha; run the docs gates (or nothing for
a delete) and say so in the hook comment.

**Implemented 2026-11-27.** `githooks/pre-push` skips non-branch refs and all-zero local shas,
keeps the merge-base and multi-ref rules, and calls `ci-check --stamped`; `CI_CHECK_BIN` is the
test seam. Fixtures prove a tag and a delete exit 0 without invoking the gate and a branch invokes
`--stamped`.

Commits: 5fbf5b5, f830b0d

## BUILD-135

**The docs CI job runs code static checks on a docs-only PR** - the `docs` job in
`.github/workflows/ci.yml` runs the FFI surface, log hygiene, theme tokens, test guards, release
versions, the MCP descriptor and the cost stamp on every PR; a docs/workflow-only diff cannot change
any of them. They are seconds, but they are code checks on an unchanged tree and blur the docs-only
promise. Fix: move them behind `needs.changes.outputs.code == 'true'` (a `static` job) or into the
code jobs; keep the docs job to docs-check, the catalogue and the bundles.

Shipped: the source checks (release versions, the MCP descriptor, FFI surface, log
hygiene, theme tokens, test guards, the cost stamp/chart) moved to a `static` job gated
`rust || godot`; `docs` keeps docs-check, the catalogue and both bundles, plus
`scripts/tooling-smoke`. PR #62 run `45921076617`'s `static` job passed in 14s, and the
docs-only close-out PR runs only `changes`, `lint-workflows`, `docs`, `commit-lint` and
`ci-gate`.

Commits: 5fbf5b5, e376411, c7bbac7

## BUILD-136

**The queue has no summary or filter view** - `ROADMAP.md` lists the chains without open counts,
`roadmap next` has no `--limit`, `--chain` or `--area`, and `release-check` fails a release without
listing its remaining rows. A reader must run `stats` or open pages to plan. Fix: generate and check
the open counts in the release-chain list from `roadmap stats`; add `next --limit/--chain/--area`
and `release-check --open`; keep the index itself one line per row.

**Implemented 2026-11-27.** `ROADMAP.md`'s release-chain list now carries each page's open count (`-
planned, 114 open`); `stats --write` writes it and `add`/`move`/`close` refresh it, so the audit
only catches a hand edit. `next` takes `--limit`, `--chain` and `--area`, and `--json` is a list;
`release-check --open` prints `N open of M row(s)` and the open rows (id and title) instead of
failing on them. The counts and the drift trip (`says 9 open`) are in `roadmap selftest`.

Commits: 5fbf5b5, 3d4b544

## BUILD-137

**`scripts/roadmap show` prints the detail page path with the index row's line number** - measured
2026-11-26 while closing the v0.9.3 rows: `show SEC-55` printed
`docs/content/docs/roadmap/details/sec.md:94` above `| ✅ | [SEC-55]...`, where 94 is the index
line on `v0.9.md` and the detail section starts at 1122. `cmd_show` takes `page, sec =
ledger.section(row)` (the detail page) and prints `rel(page.path):{row.line}`, pairing one file's
path with another file's line. Fix: print `rel(row.page.path):{row.line}` (the index row the
second line quotes) and leave the detail page path out of the header. Test: extend the `selftest`
fixture so `show TEST-1` asserts the `v0.0.md` header.

**Implemented 2026-11-27.** `show` prints `rel(row.page.path):{row.line}` above the index row it
quotes, so the header names the page its line number belongs to. The selftest computes the row's
line from the written fixture and fails if the header differs or the detail page's path is paired
with the index line.

Commits: e398461, 3d4b544

## BUILD-138

**The macOS app export is headless on Linux, so the Metal shader baker cannot run** - the
`release-build.yml` `export` job runs on `ubuntu-24.04` and calls
`godot --headless --path godot --export-release "macOS"`. Godot 4.7's shader baker is not supported
under `--headless`, and a Linux editor can bake Vulkan only; the Metal baker requires a macOS
editor, so the export host cannot produce the Metal cache at all. Godot 4.7.2 issue #123266 also
aborts a baked build on Apple Silicon when `application/min_macos_version_arm64` is below 14.00
(ours is 11.00); 14.00 works, and the export-side cache must be cleared between bakes. Fix: move
the macOS app export to a non-headless macOS job (e.g. extend `bundle-macos`), raise
`min_macos_version_arm64` to 14.00 or wait for the engine fix, clear `.godot/exported`, verify the
shader cache lands in the `.app`, re-sign after baking, and measure the graph's first-open time and
bundle size on a real Mac. Tests: a release-build dispatch carries the cache and the app opens the
graph without the compile hitch; record the numbers in the v0.9.0 budget table.

## BUILD-139

**A second `scripts/pr push` fails when its workflow commit is already on the remote** - found
2026-11-27 on PR #71: after the first split push put `f830b0d` on `build/v094-hygiene`, a later push
of `88b2104` computed the newest workflow-touching commit in `origin/main..HEAD` (`f830b0d`) and
tried to push it again with the maintainer credential; git rejected it as non-fast-forward, so the
bot push never ran. Fix: in `cmd_push`, read the remote head and skip the maintainer push when
`git merge-base --is-ancestor "$w" "$remote"`; otherwise push it as today. Add a `scripts/pr
selftest` fixture for the already-remote case (the split plan is already pure; the remote decision
is the new seam). Tests: a fixture remote containing `w` goes straight to the bot push; a remote
behind `w` still performs the maintainer push; a branch whose newest commit touches
`.github/workflows` still refuses.

**Implemented 2026-11-27.** `needs_maintainer <w> <remote>` answers the split's second half from
`git merge-base --is-ancestor`; `cmd_push` reads the remote head before the dry-run branch, fetches
the object when it is absent locally, and skips the maintainer push when the remote already carries
the workflow commit (saying why). `pr selftest` builds a bare remote and covers already-remote,
behind and empty; the dry run stays offline-capable.

Commits: 46c80ea, 3d4b544

## BUILD-140

**GUT's intermediate-state assertions race the host's frame pace** - found 2026-11-27 on PR #73 and
the three dependabot PRs: `test_scroll_hints.gd::test_a_chevron_fades_in_and_out` failed on Windows
with `[1.0] expected to be < than [1.0]` (`it arrives from transparent`, sampled after one frame
whose delta exceeded the fade),
`test_concept_graph_editor.gd::test_frame_all_eases_and_off_lands_on_the_same_transform` failed on
Windows with `the camera moved off its start` (the tween's first step landed after the single
awaited frame), and `test_wiki_pane.gd::test_a_dragged_node_keeps_its_place_across_a_build` failed
on macOS with `[683.804138183594] expected to be < than [1.0]` (the drag was placed into a live
`RigidBody3D` simulation, and the extra physics ticks before the rebuild moved the body). None of
the four PRs changed GDScript, so the assertions depended on the runner, not the code under test.

Fix: sample an arrival's start before the first frame (`UiMotion.arrive` sets it synchronously),
wait on wall time rather than a frame count before asserting an ease advanced, and settle a 3D
graph's simulation (`_settle_now`) after placing a dragged body so the physics is not a second
author of the position. Tests: the three named tests, in the full suite on Linux and `--dir unit` on
macOS.

**Corrected 2026-11-27.** The macOS value is identical on every run (`683.804138183594`, two
separate runs including the merge-queue build), so this was not the frame pace: the second live
rebuild's *source* was a fresh layout rather than the view's export on that path, and the assertion
raced the view swap. The test now asserts the handoff at its seam - `export_positions()` into the
pane's own `_build_graph_document` - which is deterministic and is the contract the test names; the
settle stays because a finished drag is the state being exported.

Commits: e08a654

## BUILD-141

**The pre-push `--stamped` gate runs the full suite on a new tree** - found 2026-11-27: the
docs-only branch's first push ran `--stamped --summary` for 242 s (Rust, GUT, smoke, audit, deny)
while its remote PR run 46079616356 skipped every heavy job, and the gate branch's first push took
243 s. `ci-check`'s `--stamped` help says "skip when the clean-tree stamp matches; else run the full
gate", so the class selection a hand run (`--classify`, `--fast`) performs is not applied to the
first push of a new tree; the commit skill's "a docs edit ... never buys the Rust, GUT and smoke
jobs" is therefore false on the hook path. Fix: when no stamp matches, classify the pushed range the
hook already passes (`CI_CHECK_RANGE_FROM`) and select the docs/tooling class, then seed the stamp
with that run; keep the full suite for a code range. Tests: extend the pre-push refs fixture in
`scripts/tooling-smoke` with a docs-class range and assert the selected steps exclude
`tests`/`gut`/`smoke`, and a code range still selects them; measure before/after on a docs push.

## BUILD-142

**A docs-only PR still pays the full matrix in the merge queue** - PR #75 (docs) ran the cheap set
on its pull_request run (46079616356: rust, gut, windows, macos, static, audit and fuzz skipped) but
its merge-group run 46080254384 set `all_true` in the `changes` job and ran Rust, GUT, Windows,
macOS, static, fuzz, cargo-audit and cargo-deny; the land wait was 954 s, and PR #76's queue run
took 1511 s. The merge queue is the remote gate, but a docs-only diff cannot affect those jobs, so
the rule DOCS-55 established for PR runs stops at the queue. Fix: in the `changes` job, classify the
`merge_group` diff (`BASE..HEAD` from the event) instead of forcing all true, or carry the PR's
class into the merge-group head; keep the full matrix for a code range. Tests: a `merge_group`
fixture exercising `scripts/classify-changes` and the job's output; measure the queue wall time for
a docs PR.

## BUILD-143

**`scripts/pr` cannot print a PR's check class, so the run is read by hand** - `scripts/pr checks
[PR] [--json]` now prints the PR head, the pull_request CI run with success/skipped/failed/pending
counts and the skipped names, and the required contexts read from the live `main protection` ruleset
matched against `gh pr checks`; it exits 0 when every required check passes, 1 when one does not
(including missing) and 2 on a read failure. `pr selftest` covers a docs-class document (10 skipped,
2/2 required), a failed `ci-gate` and a pending/missing set; the commit guide, `testing.md` and the
session wrap-up skill name the command. Measured on the merged PRs: `./scripts/pr checks 75` prints
`15 jobs: 5 success, 10 skipped, 0 failed` and `required 6/6 pass`, and `./scripts/pr checks 76
--json` reports a full run with `skipped: 0`. Verified with `bash -n scripts/pr`, `./scripts/pr
selftest`, `./scripts/tooling-smoke` and the two real PRs.

Commits: 2874b45

## BUILD-144

**`ci-check --fast` runs the whole fast set when the index is empty, and the guide says to run it before staging** - `ci-check`
now prints `--fast sees an empty index and runs the whole fast set. Stage first, or let the
pre-commit hook run it.` when `--fast` has no `CI_CHECK_RANGE_FROM` and `git diff --cached` is
empty; a hand run with a staged index still takes the docs/tooling class subset, and the pre-commit
hook runs on the staged index. The commit guide's step 1 and pre-commit bullet now name the hook as
the fast gate, and `testing.md` records the empty-index case. Measured: the two pre-staging manual
runs took 22-23 s each and ran media/fmt/clippy/cost/tooling, while a staged docs range takes the
docs subset; the clean-index run prints the note and exits 0. Verified with `bash -n
scripts/ci-check`, the clean-index `--fast` note, `./scripts/tooling-smoke`, `docs-check` and
`roadmap audit`.

Commits: 2874b45, e8b8937

## BUILD-145

**The ledger CLI cannot record and close in one call, and `show` piped to `head` reports a broken pipe** - found
2026-11-27: the session wrote four record+close pairs (two commands each) and `./scripts/roadmap
show <ID> | head` printed `roadmap: [Errno 32] Broken pipe`, because `main()` catches
`BrokenPipeError` as an `OSError` and reports a reader that closed the pipe as an error. Fix:
`roadmap close <ID> --record FILE` validates the body (the title must equal the index row, a
`Commits:` line is refused) and writes it before closing, sharing the record body loader; a
`BrokenPipeError` handler redirects stdout to devnull and exits 0. Tests: `roadmap selftest` covers
a bad-title `--record` (row stays open), a recorded body with `Commits: unrecorded`, and a 100 KB
`show` whose reader closes after one line (exit 0, no `Broken pipe`). Docs: the roadmap guide and
skill name the one-call form.
