---
title: gpty v0.8.5
date: 2026-11-17
---

v0.8.5 is a release-repair patch. It changes no application behaviour: it exists because
v0.8.4 could not be tagged at all, and because its macOS archive shipped before its FFmpeg alias
fix reached the transport.

<!--more-->

![A fresh launch on v0.8.5](/images/v0.8.5_1.png)

**A tag that could not be created.** The `tag` ruleset carried GitHub's `creation` rule with no
bypass actors. That rule restricts ref creation to bypass actors, so with none configured nobody
could create a tag — administrator included — and pushing `v0.8.4` was rejected with "Cannot
create ref due to creations being restricted". `scripts/check-github-settings` asserted the same
wrong rule set, so the gate reported OK while the policy it guarded made every release impossible.
The ruleset now keeps `deletion`, `non_fast_forward`, `update` and `required_signatures` — a tag
must be signed and cannot be moved or deleted — and the check compares against exactly that set, so
drift in either direction fails.

**One real file per FFmpeg library.** v0.8.4's macOS zip held three real ~9.29 MB copies of every
FFmpeg library, and the unversioned one was not even a copy of the others. Two things hid it: the
artifact transport that carries the libraries between jobs dereferences symlinks, and FFmpeg ships
the unversioned `libavcodec.dylib` as a real file, which the bundler dutifully lipo'd into a second
canonical copy. `scripts/bundle-media` now derives each `<name>.<major>.dylib` and `<name>.dylib`
alias as a symlink from the canonical `<name>.<major>.<minor>.<patch>.dylib` and re-derives them
after the transported tree lands in the bundle, so the archive is one real file plus two symlinks
whichever way the libraries arrive.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.8.5).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.8.5.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
