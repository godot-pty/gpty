---
name: gpty-windows-ci-triage
description: "Triage a red gPTY Windows CI job (the windows job): pull the right log, classify the failure, decide rerun vs fix."
---

# Triage a red gPTY Windows job

One `windows` job now runs the compile check, the `gpty-ipc` and DACL tests, the
headless smoke, the renderer smoke and GUT; a failure in any of them is still
the same job. The macOS compile job (`macos`) is separate.

1. Identify the failing jobs and steps:
   `gh run list --workflow=CI --limit 1 --json databaseId`
   `gh run view <run> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | "\(.databaseId) \(.name)"'`
   `gh run view <run> --job <job> --log-failed`
2. Read the failing **step**, not the last line. The smoke prints `FAIL [step]: <what> (got: {...})` with the payload (`pane_tail`, `idle_ms`, `command`, `status`), and `Smoke.run` prints the last 50 ANSI-stripped lines of a failed command.
3. Classify:

| Symptom | Class | Action |
|---|---|---|
| A pane shows no output at all, `idle_ms` ≈ the whole budget, no error; the program writes an OSC (`ESC ]0;`) | ConPTY buffers an unterminated OSC before gpty sees it | Not a gPTY bug. The guard is unit-tested in `crates/gpty-core/src/escstring.rs`; the smoke skips that arm on Windows. Do not re-add an end-to-end OSC assertion through ConPTY. |
| `cargo build ... exited 101` | Real cargo error, in the `Build CLI and extension` step | Read that step's log; fix the code, or rerun once if it is registry/network/vcpkg. |
| `Build media dependencies` runs ~26 min (warm: 2 s) | vcpkg is rebuilding FFmpeg because the runner image's vcpkg moved past the cached `installed` tree | Expected once per image bump. The repo prefix cache (`dist/ffmpeg/windows-x86_64`) short-circuits it on the next run; a cold prefix is the only slow case. The merged `windows` job caps at 60 min so a rebuild can finish instead of cancelling. |
| `Build media dependencies` fails with `failed to git show versions/baseline.json` or `no version database entry for ffmpeg` | The runner's vcpkg checkout is older than the registry and cannot resolve a manifest `builtin-baseline` commit | Do not pin `builtin-baseline`; use the checkout's classic `vcpkg install ffmpeg:x64-windows`, enforce the installed FFmpeg `Version: 9.0.2`, and record the port revision in `components.txt`. |
| `spawn_refuses_a_program_another_user_could_have_written` + `Text file busy` | Linux ETXTBSY spawn race (fixed in the test: unique temp name + bounded retry) | Rerun only if it recurs elsewhere; a new test that writes then spawns needs the same treatment. |
| GUT cannot find a `class_name` | Import cache not built | The `Import project` step must precede GUT; it runs with `!cancelled()`. |
| GUT fails tests about files they never wrote (`This folder is empty` reading `""`, a note list with extra entries, `remove_tree must succeed`), or a `SCRIPT ERROR: Out of bounds get index '0'` | A fixture path was refused, so `remove_tree` deleted nothing and fixed-name fixtures inherited earlier tests' files | Read `testing.md`'s GUT bullet: `TestPaths.fresh_dir` clears the leftover, the bounds rule unifies the Windows drive separator, and `gut-check` now prints the script error's `at:` file:line. Do not "fix" the individual tests. |
| Job hangs or never finishes | A step blocking | The `windows` job caps at 60 min (`timeout-minutes`); the other jobs cap at 30-45. `Smoke.run` caps at 30 min per command; a cancelled run with a long step is that cap doing its job, so find the step time, not a retry. |
| **Green job, but slow**: `Build CLI and extension` back at ~150 s (warm should be ~28 s), or `Build media dependencies` back at ~105 s on Linux (warm ~0 s) | Cache miss or eviction, not a code change | Read the `Cache cargo` / `Cache FFmpeg` step for `Cache not found for input keys` (a miss right after a `Cargo.lock`, `scripts/media-deps` or `components.txt` change is expected). `gh api repos/godot-pty/gpty/actions/caches --jq '.actions_caches[] \| [.key, (.size_in_bytes/1048576\|floor)] \| @tsv'` lists what exists and its MB. The merged Windows job uses one `-cargo-` key for the compile, tests and smoke, so a restored target can be reused by every step. |

4. Rerun only the failed jobs: `gh run rerun <run> --failed`. Never add retries to mask a deterministic failure; fix the step.
5. When the cause is a harness bug, fix the assertion first (so the failure explains itself next time), then the cause.
