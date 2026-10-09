---
title: gpty v0.5.6
date: 2026-10-09
---

v0.5.6 is the control-surface release: one gPTY instance owns the socket, the CLI starts a GUI only
when the command needs one, and a CLI from a different release says which side is stale instead of
failing obscurely. Plugin concepts reach the engine they were validated against, `daemon status
--json` answers JSON on every path, and a pane's agent-state observers are told each state exactly
once.

<!--more-->

![gPTY v0.5.6](/images/v0.5.6_1.png)

## One instance owns the endpoint

Two gPTY windows used to be able to end up on the same control socket. `serve()` unlinked an
existing socket after checking only that it *was* a socket owned by your UID — never that anything
was still listening — so a second instance took the path and orphaned the first: both windows stayed
up, every CLI command went to the newcomer, and the older workspace became unreachable with no
message anywhere. Measured on the v0.5.5 download: two `gpty-gui` processes, two listeners bound to
`/run/user/1000/gpty.sock`, the older one's inode unlinked.

The bind now probes the path first and refuses when a server answers, so a restart after a crash
still works (a leftover file nothing is listening on is replaced) while a live workspace is never
taken over. The same rule covers the event socket and, on Windows, the named pipe, which previously
spun on a taken name rather than refusing it. A checkout that cannot serve asks itself to quit
through the existing shutdown flag and says why in a toast — a window without a pane API is worse
than no window.

## The CLI starts a GUI only when that is the work

`gpty list-panes` used to *launch the GUI it was trying to query*: every command that was not
handled early routed through `daemon::ensure_running()`, which spawns a GUI whenever its one-second
`version` probe fails. So `daemon status` could create the daemon it then reported as running, and
`daemon stop` opened a window in order to stop it.

The policy is now deliberate per command. `new-pane` and `layout load` still auto-start the
workspace — a fresh GUI can satisfy them — and `--no-daemon` refuses even those. Every other command
answers `no gpty GUI is running (start one with \`gpty daemon start\`)` and exits 1. `daemon start`
is the explicit spawner, `daemon stop` with nothing running is a no-op, and the MCP server never
auto-starts a GUI: its `daemon-start` tool is the bootstrap, and other tool calls that find none say
so.

The same download that surfaced that bug surfaced a second one: an older `gpty` on `PATH`, built
from a checkout two months behind, shadowed the bundle's CLI and answered `unrecognized subcommand
'plugin'` while the running GUI was the new release. Nothing compared the two. Every command that
talks to a GUI now checks what it reports — IPC protocol first, then version, direction-aware — and
prints one stderr warning naming both sides and the remedy. The check rides on probes the CLI
already makes, a command that has not probed does one best-effort check that can never fail or gate
it, and the protocol version itself now has a single definition shared by both sides.

## Plugin concepts reach the engine

A plugin's `[[concepts]]` were validated against the engine's own parser at install, counted in the
review dialog — and then dropped: the store record carried profiles only. They now travel the path
profiles use. The install record keeps the validated entries, a new static accessor shapes the
enabled ones, and the concept manager merges them **between the shipped defaults and your own
rules**, which is the order builtins/plugin/user already used for profiles. A name a shipped default
or an earlier plugin holds is not stolen — the plugin yields with a ` (n)` suffix, so uninstall and
re-install give the bare name back — and a user toggle or edit *overlays* the plugin's rule by name,
which is what makes the Settings toggle, edit and delete work on installed content.

## The smaller repairs

**An agent-state observer is told each value once, whichever path carried it.** Two cumulative
bugs: the terminal's slow poll compared the engine's tiered state against a shadow that started
empty, so the first poll after the workspace's entry delivery re-announced the spawn state as if it
were a change; and the entry scan broadcast the current state to every observer, so attaching a
second follower re-told the first, and a follower that joined while a change was in flight heard the
change and then the same value again. The poll now records the delivery and reports only deltas
against it, and each observer carries `[source, last state]`: the scan's entry goes to the new pane
alone, a change reaches only panes already settled for that source, and a repeat of a held value is
dropped. Three contract tests pin it.

**`gpty daemon status --json` answers JSON on every path.** The running case printed the raw
`version` response, but the not-running, busy, refused and auth paths printed prose — a script that
probed with `--json` got unparseable output exactly when the probe mattered. Those paths now answer
the shaped vocabulary the MCP tool already used (`{"status": "not running"}`, `{"status": "busy"}`,
`{"status": "error", "error": …}`) while keeping exit 1.

**Declared-only manifest sections say so.** A plugin's `[[events]]`, `[[link_handlers]]`, and
`build`/`startup` are declarations gPTY never dispatches or runs; the install review now reads as the
declarations they are instead of implying delivery at some later point.

**And the five first-party plugin repos validate with the shipped validator.** With v0.5.5's release
carrying `gpty plugin validate`, each repo's CI installs the CLI from that pinned commit and runs
the same `parse_manifest` the install path runs, keeping only the `id`-equals-repo assertion the
validator cannot make.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.6).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#056--2026-10-09).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
