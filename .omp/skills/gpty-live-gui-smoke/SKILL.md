---
name: gpty-live-gui-smoke
description: "Verify a gpty change against the real app: launch the GUI headless in a sandbox, drive it with the gpty CLI, sample RSS, check shutdown/persistence, time an interaction in a windowed run, and get a backtrace if it crashes."
---

# gPTY live GUI smoke

Use when a change must be proven against the running app (PTY behaviour, IPC surface,
scrollback, flood/RSS, pane lifecycle, shutdown) rather than in unit tests.
`scripts/smoke-pane-api` covers the published pane API; this recipe is for *ad-hoc* claims.

## Recipe

```bash
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
export XDG_DATA_HOME="$TMP/data"          # sandbox user:// (history.db, settings, workspaces)
export GPTY_SOCKET="$TMP/gpty.sock"       # sandbox both sockets (event socket derives from it)
export GPTY_SECRET="smoke-secret"         # every client must present it

( cd "$ROOT" && cargo build -p gpty-gdext -p gpty --quiet )
mkdir -p "$ROOT/godot/bin"
ln -sf ../../target/debug/libgpty_gdext.so "$ROOT/godot/bin/libgpty_gdext.linux.x86_64.so"

( cd "$ROOT" && exec godot --headless --path godot >"$TMP/godot.log" 2>&1 ) &
for _ in $(seq 1 60); do "$ROOT/target/debug/gpty" daemon status --json >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1.5                                  # first frame + IPC poll settle

GPTY="$ROOT/target/debug/gpty"
ID="$("$GPTY" new-pane -t terminal --json | jq -r '.result.pane_id')"
"$GPTY" inject "$ID" --text 'echo MARKER' --json >/dev/null
"$GPTY" pane-wait "$ID" --pattern 'MARKER' --timeout-ms 15000 --json   # {"result":{"matched":true}}
"$GPTY" pane-read "$ID" --lines 50 --json | jq -r '.result.text'
"$GPTY" kill-pane "$ID" --json >/dev/null
```

RSS sampling off the **real** Godot pid (the `&` above is a subshell — `$!` is not Godot):

```bash
GODOT_PID="$(pgrep -f 'godot --headless --path godot' | head -1)"
rss_mib() { awk '/VmRSS/{printf "%d", $2/1024}' "/proc/$GODOT_PID/status"; }
```

## Shutdown / exit claims

Anything touching quit, teardown, or persistence must be checked on all three axes, because
each one can fail independently: the **reply** (`daemon stop --json` → rc 0 and a result, not
`invalid response: empty response`), the **teardown** (`$XDG_DATA_HOME/godot/app_userdata/gPTY/`
gains `settings.json` and `workspaces.json`), and the **buffered data** (the pane's last line is
in `history.db` via `sqlite3`). `process::exit` passes the first and fails the other two.

Watch the shell's own stderr line too — a crashing GUI prints `Segmentation fault (core dumped)`
*after* the exit status is reported, so grep for it; `wait` gives you the CLI's exit code, not
the GUI's.

## Getting a backtrace from a crash

`gdb` in batch mode, with the trigger driven from a second shell:

```bash
cat > "$TMP/gdb.cmds" <<'EOF'
set pagination off
set confirm off
run
thread apply all bt 14
info threads
quit
EOF
( cd "$ROOT" && exec gdb -batch -x "$TMP/gdb.cmds" --args godot --headless --path godot >"$TMP/gdb.log" 2>&1 ) &
# then poll `gpty daemon status`, do the pane work, trigger the quit, wait for gdb
```

Frames in `?? ()` at a `0x7fff…` address, on a thread named `tokio-rt-worker` (or any gpty
thread), mean the thread was executing code from an **unmapped** library — i.e. Godot unloaded
the GDExtension while our threads lived in it. The extension pins itself with `RTLD_NODELETE`
(`pin_library`, `InitStage::Core`); if that ever gets removed or a new platform is not covered,
this is what it looks like.

## Timing an interaction

"Switching workspaces is slow" becomes a number here. The cost is synchronous GDScript plus
the frame it delays, so headless cannot measure it (no draw, no compositor round-trip), and one
repetition is not a number (measured 2026-11-09: the first switch after launch was 551 ms, every
later one 63-75 ms).

1. **Keep the reporter's layout, sandbox the rest.** Copy their store under a private
   `XDG_DATA_HOME` (`cp -r ~/.local/share/godot/app_userdata/gPTY …`) and delete `history.db`
   from the copy - a store copied while the live app holds it can answer `file is not a database`,
   and since v0.8.1 the sandbox then moves that copy aside as `history.db.corrupt` (one warning,
   but it buries real ones and the copied scrollback is unusable anyway).
2. **Isolate both sockets** with `GPTY_SOCKET` (the event socket derives from it); otherwise the
   live GUI owns the default path and this instance quits at startup.
3. **Run it in a window:** `env -u WAYLAND_DISPLAY DISPLAY=:0 godot --path godot
   --display-driver x11 --position 60,60`.
4. **Prefer the committed bench; add a probe only for a question it cannot answer.**
   `godot/tests/bench/switch_bench.gd` (`-s`, windowed, `--disable-vsync`) measures a workspace
   switch: `SWITCH_CMD_A`/`SWITCH_CMD_B` are the two payloads, `SWITCH_REPS` the repetitions,
   `SWITCH_WINDOW` the window, and it prints `sync_us frame_us fetch_ms draw_ms backoff_ms` per
   switch plus `apply_mode_us` and a median. A question no harness covers gets an env-gated
   coroutine called from `workspace.gd::_ready()` (`if OS.get_environment("GPTY_BENCH") != "":
   _bench.call_deferred()`), deleted before committing - a timing probe outside a committed
   harness has no output to pin.
5. **Attribute before theorising.** Time the call with `Time.get_ticks_usec()` marks around each
   step (and each sub-step), then the frame after it with `await get_tree().process_frame` four
   times and divide. Print one line per repetition and repeat at least three times, alternating
   direction - the 74 ms workspace switch was `_update_workspace_ui` 35 ms +
   `_refresh_profile_buttons` 17 ms + `_list()` 10 ms, with the panes at 0.1 ms. To measure the
   *before* side once the change is committed, `git stash push -- <paths>` is a no-op: check the
   old files out (`git checkout <pre-change-commit> -- <paths>`), run the same bench, restore
   with `git checkout HEAD -- <paths>`. A harness warm-up must end on the state the measured loop
   starts from, and a same-target switch must fail the run rather than reprint the previous
   timing (measured 2026-11-11: a warm-up ending on workspace 1 made rep 1 record the warm-up's
   numbers).
6. **Seed content through the pane**, not the layout: `body._terminal.send_text("lazygit\n")` (or
   a redraw loop) puts a real TUI in the pane the report is about; wait a few seconds, then
   measure. `_fetch_ms`/`_draw_ms` are already recorded per pane and shown in the status bar, so
   frame cost needs no new instrumentation.
7. **Typing latency is the pane's refresh cadence, not the key path.** A key writes to the PTY on
   the UI thread; the echo is painted at the pane's next grid sync (`TerminalPane._process`, gated
   by `_sync_interval + _sync_backoff`). An env-gated coroutine that pushes `InputEventKey`
   events needs `keycode` **and** `physical_keycode` **and** `unicode` (plain letters reach the
   PTY through `_key_to_text`, which reads `unicode`; a keycode alone sends nothing), then counts
   `_last_grid_gen` changes per 300 ms: a streaming pane in the flood back-off measured 2-3
   refreshes per 300 ms with `_sync_backoff` pegged at 93.9 ms, and 14-19 once input exempts it.
   Print `_sync_backoff`, `_fetch_ms`, `_draw_ms` and `Engine.get_frames_per_second()` beside the
   count, and toggle the other pane (btop vs an idle shell) between phases to separate the two.
8. **Quit explicitly** (`get_tree().quit()`), or `timeout` kills the run and you get exit 124.

## Gotchas (each cost a debugging round)

- **Never `pkill -f 'godot --headless --path godot'`** while `./scripts/ci-check` may be running:
  the pane-API smoke launches the same command line, so a broad pkill kills CI's GUI and the
  run fails with `ConnectionRefusedError` in `scripts/smoke_event_client.py`. Kill by pid.
- **Sandboxed data lands in `$XDG_DATA_HOME/godot/app_userdata/gPTY/`** — `history.db`
  (+ `-wal`/`-shm`), `settings.json`, `workspaces.json`, `profiles.json`. Inspect with `sqlite3`
  (the WAL holds recent rows; a plain `cat` shows nothing).
- **A size or layout claim needs a window.** `godot --headless` leaves the root viewport at 0×0, so
  every tile is 0×0 and a terminal pane starts at its configured fallback grid (24×80) — on a build
  where the fix is present. Measured 2026-11-08: the headless `new-pane` answered `stty size` with
  `24 80` while the same build in a window answered `60 205`. Launch `godot --path godot` (or use
  `scripts/ui-capture`) for pane size, `_apply_layout`, capture or UI claims; headless is for IPC,
  PTY and output claims that do not depend on geometry. Detail: `pitfalls.md`.
- **Core warnings do reach the log** (since v0.5.4): `diagnostics.rs` forwards `warn`+ from
  targets starting with `gpty` to Godot's console as `WARNING: [gpty_core::…] …`. An `info`/`debug`
  line from a core crate still will not appear — raise it to `warn` if you need to see it.
- **SIGTERM/SIGKILL run no teardown**, and the GDExtension class's `exit_tree` virtual never
  fires: only Godot's own quit path (`--quit-after <frames>`) and the pane's GDScript
  `_exit_tree` hooks run. A pane's `_terminal` child has already left the tree by then, so hook
  without an `is_inside_tree()` guard.
- The GUI is single-instance per socket; two sandboxes can run side by side because both sockets
  and `user://` are redirected — but only one may use the default socket path.
- **A probe that prints nothing may be filtered, not absent**: check the level (`log::info!` is
  dropped) before concluding the code path did not run.

## Cheaper alternatives first

- `scripts/smoke-pane-api` — published pane API end to end (already in `ci-check`).
- `cargo run --release -p gpty-core --example flood_probe -- <seconds>` — pane throughput, store
  lag, RSS, no GUI needed.
- `godot --headless --path godot -s res://tests/bench/draw_bench.gd` — render cost
  (`BENCH_FLOOD=1` for the flood variant).
- `godot --path godot --disable-vsync -s res://tests/bench/switch_bench.gd` — workspace-switch
  cost (windowed; payloads via `SWITCH_CMD_A`/`SWITCH_CMD_B`, window via `SWITCH_WINDOW`).
