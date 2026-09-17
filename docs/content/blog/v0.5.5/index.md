---
title: gpty v0.5.5
date: 2026-09-17
---

v0.5.5 is the plugin release: `gpty-plugin.toml` as a validated manifest, an install that a human
reviews before anything lands, the tool layouts moved out of gpty and into plugin repos, and a
registry the docs site renders. Alongside it, the pane surface grew the pieces plugins needed — a
`cli_view` pane that streams a program's output without a Godot SDK, an agent-state contract for
custom panes, and a consent store so Workspace Trust asks once instead of every time. Under that,
the Windows concept matcher was found dead and repaired, and a batch of correctness fixes landed:
pane-wait's socket, the history store's lock, a dead pane that claimed to be running.

<!--more-->

![gPTY v0.5.5](/images/v0.5.5_1.png)

## Plugins, reviewed before they run

A plugin is a git repo with a `gpty-plugin.toml` at its root. The manifest declares an id
(`owner/name`), a version, the platforms it supports, a minimum gpty version, and five table sections:
actions, events, link handlers, concepts and profiles. Validation holds the same posture as every
other untrusted input in gpty — size and count caps, a closed key set, argv arrays that are never
shell strings, tiles that mirror `PaneTypes.sanitize_tile` by rejecting rather than clamping — and two
of the lists are not free-form at all: `[[actions]].command` must be one of the published CLI
commands (the same derivation the 19 MCP tools come from), and `[[events]].type` must be in the
event-socket vocabulary. Every `[[concepts]]` entry is round-tripped through the engine's own parser,
so a trigger the Rust `regex` crate cannot compile — a PCRE2 lookbehind, say — rejects the manifest
instead of being silently dropped at load time. `gpty plugin validate <path>` runs the same parser
offline, which is what a plugin repo's CI should call.

![The install review for godot-pty/gpty-omp: what it declares, resolved to the revision it would pin, and what its profile would start](/images/v0.5.5_2.png)

`gpty plugin install <owner>/<repo>[@ref]` clones, validates and gates (the manifest's id must equal
the install target, your platform must be declared, the minimum version must not exceed your CLI) —
and then stops and asks. The summary goes to the running GUI, which lists every action, event, link
handler, concept and profile the plugin declares, including **the programs each profile would run**,
next to the ref you asked for and the revision it resolved to. Declining, disconnecting, or having no
GUI means nothing installs. On acceptance the content moves to `data_dir()/plugins/<id>`, per-plugin
`config`, `state` and `logs` directories appear, and the record — the validated profiles included —
lands in `plugins.json` with the revision pinned to a commit SHA. That pin is the contract: moving a
tag produces a new revision, and a new revision is re-reviewed. `list`, `enable`, `disable`,
`uninstall`, `logs` and `run <id> <action>` manage it afterwards, and an admin action tells a running
GUI to re-read the store, so the sidebar catches up before the command returns.

## The tool layouts left gpty

The shipped profiles used to include herdr, lazygit, nvim, claude and OMP. They are gone from
`profiles.default.json` — `Agent Workspace` is the only built-in now, pure geometry, so a first run
opens no dialog — and each tool has its own plugin repo under the `godot-pty` org. Installed plugins'
profiles appear in the sidebar between the built-ins and your own, with their provenance in the
tooltip and no delete or rename affordance: the profile belongs to the plugin and vanishes with it.
`layout list` and `layout load` see them, and a plugin approved at its pinned revision activates
without re-asking.

Naming had to get honest about collisions. A user profile and a plugin profile can want the same name,
and the ` (n)` suffix is now re-derived whenever a user profile takes or frees a name — previously the
collision resolved to the *plugin's* row for the rest of the session, so clicking your own row
activated the plugin's profile. While no plugin profile is installed the Profiles section shows a
"More layouts →" row that opens the registry page.

That row is also why this release has a sidebar fix: it measured 220 px in a 180 px panel, which
pushed the whole section out past the panel's right edge — where the workspace grid covers it. The
rows above it were being cut mid-word (a profile read "Agent Workspac", though the same string had fit
in v0.5.4). Row labels now clip their text out of the button's minimum width and ellipsize the
overrun, so a long name — yours to choose, for workspaces and profiles — degrades inside the panel
instead of slicing its neighbours. A test pins the invariant, and it fails without the clipping.

## `cli_view`: a pane without a PTY

A `cli_view` pane runs a program plus argv — never a shell string — and streams its merged stdout and
stderr into the pane body as plain text. No PTY, no stdin, no ANSI interpretation: nothing the child
prints can move a cursor or change what is drawn. ![A cli_view pane: a program's argv output streamed into the pane body, with the exit reported like a terminal's](/images/v0.5.5_3.png)

It is spawnable from the CLI
(`gpty new-pane --type cli_view --command prog --arg …`), the palette, and profile or plugin tiles —
which means a tile that names a program passes the Workspace Trust gate, exactly as it should, since
naming a program is what the gate is for. The child is held to the same `validate_program` rule as a
terminal's and is stripped of `GPTY_SECRET`, `GPTY_SOCKET` and the pane's event capability, because a
plugin's status command is a third-party CLI. The pane keeps the stream after the child exits and
reports the exit through the same status document as a terminal, so `pane-read` and `pane-status` work
on it unchanged. It is the v1 plugin UI: a manifest can ship a tile that renders a status command
without touching GDScript.

## Panes can observe agent state, and trust remembers

Custom panes got the contract they were missing. `PaneBody.agent_state_source_id()` names the terminal
a pane observes by stable `attachment_id`, and `on_agent_state_changed(state)` receives that
terminal's state; `workspace.gd` is the only dispatcher, delivering on real transitions and priming
every new observer — including a follower whose terminal appears later, or one re-pointed at a
different source. The titlebar badge is the first implementation and runs *through* this path rather
than beside it. It stays display-only: a Tier 2 declaration is spoofable by anything that prints and
Tier 3 is a heuristic, so state never feeds a decision, an action, a capture or IPC.

**Workspace Trust now remembers.** Approving a profile whose tiles name a program used to ask again on
every activation, and `layout load` over IPC refused such profiles outright — correctly, since a
caller cannot answer a dialog. A consent store (`user://trusted.json`) short-circuits the gate for
what was already approved: a shipped built-in at this app version, a tile whose exact spawn plan
(program and argv) an approval covers, or a plugin at its pinned revision. A new version or revision
re-prompts, content that arrived any other way keeps asking, and only the trust dialogs' confirm paths
write the record.

**And a pane's environment belongs to you, not to a file.** Restoring a layout used to apply a tile's
`saved shell_env` before the user's global settings — so per-pane env was silently discarded (a bug)
and a downloaded layout's env could reach a child (an accident). Restore now strips any `shell_env` a
tile carries, with a toast naming what was dropped, and per-pane env lives in `user://pane_env.json`
keyed by `attachment_id`, written only by the pane settings UI and overlaid last at spawn. Profiles
lose the ability to carry env by design; a profile that needs one points at your shell rc.

## Windows concept matching was dead

ConPTY renders line breaks as cursor moves rather than LFs, and gpty's discard-only line parser
committed a line only on LF — so on Windows, no output line ever reached the concept matcher. A
shipped trigger or a user-defined one could not fire there; only the terminal's own echo of typed
input (which carries CRLF) matched. The parser now commits on the cursor-move breaks ConPTY emits,
still ignores a redraw, and the live smoke asserts a routed `concept` event built from *output* on
whichever platform runs it — the Windows proof that the fixed path is the one that ships.

`gpty new-pane --pane-type code_viewer` was broken the same way, differently: `PaneType` serialized
kebab-case (`code-viewer`) while every other surface — the GUI's registry, the CLI's accepted names,
the manifest validator, the docs — used `code_viewer`, so a multi-word type reached the GUI as a key
it did not know. The enum now has one spelling in both directions, the CLI's and the validator's lists
are derived from `PaneType::ALL`, and a test parses `PaneTypes.ALL` out of the GUI source and compares
key for key. The two vocabularies cannot drift apart again.

## The smaller repairs

**A locked history store no longer drops the batch it was committing.** Two panes writing at once
could exhaust SQLite's 5 s busy timeout, and the per-pane writer logged the failure and dropped the
batch — scrollback the store's own retention window would have kept. The writer now waits for the
lock, bounded by the pane's task. Measured before the fix: 7 of 15 batches dropped under contention;
0 of 15 after.

**A pane whose terminal task died looked like a running one.** Nothing awaited the task's handle, so a
panic inside it — or a child that closed its pty and outlived the pane — left `pane-status` reporting
`running: true` with no exit code, forever, and every consumer waiting for an exit hung. Liveness is
part of the status document now (`exit_reason` is `exited`, `task_ended`, or null while running), and
it is built in core, so the pane API's promise and the tested artifact are the same bytes.

**A failed `resize_grid` desynced a pane's size permanently.** The grid and PTY are resized as one
all-or-nothing operation (a refused resize moves nothing, the PTY included), the pane keeps its own
dimensions in step with the backend, and the resize is applied from the size at debounce time instead
of a stale one. **`gpty pane-wait --socket <path>`** ignored the global flag and talked to the default
socket; it now reaches the resolved socket and the server honors pane-wait's own deadline rather than
ending a long wait early. **The concept push leaked an FFI object per push** — a fabricated
`GptyTerminal` used as a vehicle for a static call, growing ObjectDB on every concept save; the
accessors are called statically now, and the FFI surface checker covers class-name calls too (61 → 90
checked call sites). And the status bar gained a **clock** beside the version.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.5).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#055--2026-09-17).
- Plugin registry: [godot-pty.github.io/gpty/plugins](https://godot-pty.github.io/gpty/plugins/).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
