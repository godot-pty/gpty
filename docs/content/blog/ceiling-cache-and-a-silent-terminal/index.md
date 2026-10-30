---
title: A ceiling, a cache, and a terminal that swallowed its output
date: 2026-10-30
---

A window can now hold at most 96 live panes, CI finishes in about 40% less
time, and one Windows test failure turned out not to be a bug at all. None of
the three was visible from reading the code — each one needed a measurement
first, and two of the three were things the pipeline was telling us wrongly.
This is the write-up of an uplift that started as security hardening and
ended mostly as an exercise in diagnostics.

<!--more-->

## A ceiling that came from a measurement

The v0.7.1 queue carried a row saying a program that can reach the control
socket could create panes without limit, and that a layout file could do the
same from disk. That was true, and unmeasured: the row asked for numbers
before anyone picked one. So we booted the real GUI headless in a sandbox,
looped `new-pane` over the socket, and read `/proc/<pid>/status` while it ran.

A pane costs about 6 MB in its child shell, and the GUI grows by under 1 MB
per pane (279 MB with 64 panes, 323 MB with 128). A single workspace tops out
at 64 tiles on its own — the divider's minimum tile size stops the split — and
a *file* was worse, because its tiles never pass the split at all:

| Profile tiles | Before | Now |
|---:|---|---|
| 64 | 64 panes, `layout load` 2.6 s | unchanged — under the ceiling |
| 128 | 128 panes, `layout load` overran a caller's 5 s timeout | 96 panes |
| 300 | 300 panes, 1.49 GB, `list-panes` 3–5 s | 96 panes, 892 MB, `layout load` 4.0 s, `list-panes` 16 ms | The limit is one
constant (`Workspace.MAX_LIVE_PANES`), counted across every workspace —
a hidden workspace's pane keeps its PTY, its process and its grid, so a
per-workspace allowance would just multiply by the number of tabs. One
decision produces the refusal text, and everything that can create a pane
prints it: the socket's error, the toast, and a restore that reports
"Restored 96 of 300 panes" instead of pretending.

Creating panes is not free, and measuring turned that up too: the first pane
arrives in about 15 ms, the call took roughly 500 ms by 30 panes and about a
second at 64. That cost grows with the live pane count rather than staying
flat, and it is queued as its own fix.

## The build that rebuilt everything

CI had a green-looking cache and a red-looking bill. Timing every job of a
green run showed where the time actually went, and two of the three biggest
items were not cost but defects:

| Job | Before | After | What was wrong |
|---|---:|---:|---|
| windows-smoke (the critical path) | 413 s | 255 s | rebuilt every dependency — 150 s — *after a cache hit*; now 28 s |
| gut-tests | 295 s | 198 s | built FFmpeg from source every run, 105 s; now 0 s |
| rust-tests | 204 s | 106 s | the same FFmpeg build, 112 s; now 0 s |
| cargo-audit | 182 s | 9 s | 173 s of it compiled the audit tool; it ran for 3 s |
| rust-windows | 110 s | 82 s | its cache was check-shaped instead of build-shaped |
| **Wall clock** | **413 s** | **255 s** | |

The Windows one is the interesting defect. `windows-smoke` builds the CLI and
the extension; `rust-windows` only type-checks the Windows target. They shared
one cargo cache key, so whichever job wrote the cache first decided its
*shape* — and a `cargo check` target contains `.rmeta` files but no machine
code. A check-shaped cache can never satisfy a `cargo build`, and because a
cache is only written when it is missing, the build-shaped snapshot was never
written at all. Every run paid for a full compile while the log said "Cache
restored successfully". Splitting the key by shape (`-cargo-build-` and
`-cargo-check-`) took that step from 150 s to 28 s.

The FFmpeg entry is the same story in a different costume: two jobs linked a
pinned, minimal FFmpeg that both rebuilt from source each run, because the
built prefix — 11 MB — was never cached. It is now, keyed on the build script
and the component list, and the script's own `.stamp` (version, components
checksum, platform, assembler) still decides whether it can skip. A stale
cache costs a rebuild; it cannot cost correctness.

`cargo-audit` compiled from crates.io on every run. The pinned binary is now
cached under its version, and a miss still builds it with `--locked`, so a hit
is exactly the artifact the job would have made.

## The terminal that swallowed its own output

Three `windows-smoke` runs failed on one step with a pane that showed nothing:
the command echoed, then 60 seconds of silence, then a timeout. `idle_ms`
read 60.5 s, 60.6 s and 61.4 s across a typed one-liner, a typed `-File` call
and an argv launch — three different ways to start the same program, all
silent. The same pane had just run cmd built-ins normally.

It was not the launch. On Windows the child's output does not reach gPTY
directly: ConPTY's console host parses it first and re-emits VT. And the
console host is itself a parser with an escape-string buffer — an *unterminated*
OSC is exactly what it buffers, so the introducer, the 92 KiB flood behind it
and the marker after it never arrive. The grid received zero bytes, which is
indistinguishable, from the outside, from a program that never started.

That is a real behaviour, not only a test problem: on Windows a program that
opens a title string and never closes it makes its pane look frozen, where on
a Unix PTY the bytes reach gPTY and the 64 KiB guard closes the string and
carries on. The guard is still exercised end to end on Unix and in Rust unit
tests (`escstring::tests`, every split and chunk size); on Windows the smoke
now says it skips the flood, and proves a real program launched through the
shell actually runs and prints — a control the earlier runs never had.

## The flake that was a race

The same week, the parallel Rust suite failed on two of three consecutive runs
with `Text file busy` — always the *control* spawn of a test that writes an
executable and then runs it. The kernel answers `ETXTBSY` while any process
holds the file open for writing; libtest's threads fork for other tests in the
same binary, and a fork can hold a duplicate of the write descriptor for a
moment after the test's own write closed. The test now uses a nanosecond-stamped
temp name and retries that one error, bounded, around the control spawn only.
The refusal case — the rule under test — is untouched, and the product still
reports what it reports.

## What a failure must say

Every fix above began by making the failure legible, and that is the part
worth keeping:

- A failed command in the live smoke now reports its last 50 lines with colour
  stripped, instead of the last 300 characters — which, for a failed build, was
  a wall of `cargo::metadata=` and no error line at all.
- The smoke's subprocess calls have a 30-minute watchdog, and the CI jobs have
  a 30-minute ceiling, so a hung Godot fails in minutes rather than at the
  six-hour job cap.
- The Windows build is its own step, so a cargo error fails where its output
  is visible rather than inside a summary line.
- The Windows GUT suite runs even when the smoke fails (`!cancelled()`), so one
  red step no longer costs the run its second, independent signal.
- The flood test's first assertion is the flood's own shape, not a marker
  line: a marker printed before 131 KiB of output has scrolled out of the read
  window before the first poll lands — measured, after trying it the other way.

## What is left

`windows-smoke`'s GUT step, at 131 s, is now the largest single piece; cutting
it further needs the GUT gate to run and judge one directory at a time. The
Linux Godot download is seven seconds and one network dependency that failed
once. And `new-pane` still slows as the window fills. Each is recorded with
its numbers rather than remembered as a hunch.

None of this was in the diff the day started with.
