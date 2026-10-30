---
name: gpty-live-gui-smoke
description: "Verify a gpty change against the real app: launch the GUI headless in a sandbox, drive it with the gpty CLI, sample RSS, check shutdown/persistence, and get a backtrace if it crashes."
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

## Gotchas (each cost a debugging round)

- **Never `pkill -f 'godot --headless --path godot'`** while `./scripts/ci-check` may be running:
  the pane-API smoke launches the same command line, so a broad pkill kills CI's GUI and the
  run fails with `ConnectionRefusedError` in `scripts/smoke_event_client.py`. Kill by pid.
- **Sandboxed data lands in `$XDG_DATA_HOME/godot/app_userdata/gPTY/`** — `history.db`
  (+ `-wal`/`-shm`), `settings.json`, `workspaces.json`, `profiles.json`. Inspect with `sqlite3`
  (the WAL holds recent rows; a plain `cat` shows nothing).
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
