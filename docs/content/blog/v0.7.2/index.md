---
title: gpty v0.7.2
date: 2026-11-02
---

v0.7.2 is the build-and-CI half of the October audit. Three runtime fixes lead it - the shipped
Knowledge Base profile opens again, a Godot virtual path can no longer stand in for a real one, and
the media pane stops retaining its read buffer per open - and the rest is hygiene a reader can act on:
signed tags, a dependency policy, fuzzing, and a test gate that now says which test hung.

<!--more-->

![Screenshot](/images/v0.7.2_1.png)

**The Knowledge Base profile opens again.** A v0.7.1 install seeded its 52 bundled notes and then
listed nothing. The store's root was `user://knowledge/<hash>`, and the Rust vault index refused it
with "not an absolute path", because no Godot scheme survives into `std::path`. The fallback that
should have globalized the path was dead code: Godot 4.7 answers true to `is_absolute_path()` for
`user://` too. `BasePersistenceManager` now has one vocabulary for a path that leaves Godot -
`is_virtual_path()`, `real_path()` and `is_real_absolute_path()` - and a `res://` or `user://` value
is refused wherever a real filesystem path is required, so the next data value that crosses that
boundary cannot fail one layer later with a message about the layer.

**The media pane stops leaking its read buffer.** The new fuzzer found this ten seconds into its first
run. Every open retained 32 KiB - 8 MB over 1000 opens measured through VmRSS, 6 MB for a valid WAV.
FFmpeg's `avio_context_free` frees the context but never a caller-supplied buffer, and a seekback may
replace that buffer, so the drop now frees the pointer that is current at drop time. 1000 plain opens
hold VmRSS flat, and 2000 instrumented opens of the crafted input report no leak and no double free.

**A hung test names itself.** A GUT run wedged once in a pane-spawning test: the suite went quiet, the
gate's deadline hit, and the only thing the failure said was that the deadline had been reached. The
wedge never reproduced - the named file alone passed 20 runs, the full suite 12 - so what shipped is
the attribution the next occurrence needs. `gut-check` now watches progress as well as the clock: a
run that writes no output for two minutes is a hang rather than a slow test, and the failure names the
last test GUT started, its script, and the `-gselect` command that re-runs that file alone. A parse
error still ends the run on the spot, and the deadline still escalates to `SIGKILL` for the case where
a run keeps printing without finishing.

**The parsers that read untrusted bytes are fuzzed.** `fuzz/` is its own cargo-fuzz workspace with
seven targets - the terminal grid, the capture-side line parser, IPC request framing, vault links, the
Markdown renderer, the Inspector's frame reader and the media probe. Every pull request compiles them
so a target cannot rot, and each runs for five minutes nightly, uploading artifacts on failure. The
media target earned its place before the harness was a day old.

**Dependencies are a policy, not a wish.** `deny.toml` allows only crates.io as a source, permits the
licences the graph actually uses plus gPTY's own GPL-3.0-or-later, denies yanked crates, and warns on
duplicate versions; `cargo deny check` is a local gate step and its own CI job. Grouped weekly
dependency-update pull requests move the cargo trees and the SHA-pinned actions, which otherwise never
move. OpenSSF Scorecard runs weekly and on every push, with a baseline of 7.7.

**A release is a signed act.** The `v*` tag ruleset requires a signed tag and blocks tag creation,
update and deletion for everyone but an organization admin - the release workflow holds `contents:
write`, `id-token: write` and `attestations: write`, and a tag push starts it. `main` requires a pull
request and a review, blocks force-pushes and deletion, and requires signed commits. The release
procedure signs with `git tag -s` and verifies with `git tag -v` before pushing.

**`unsafe` is fenced by the compiler.** Five crates deny `unsafe_op_in_unsafe_fn` and
`clippy::undocumented_unsafe_blocks`; the CLI forbids unsafe code outside tests. Twenty-eight blocks
that had no comment now state their invariant.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.7.2).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.7.2.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
