---
title: gpty v0.5.3
date: 2026-09-10
---

v0.5.3 is the audit release: a security pass over the whole codebase, one capability removed on
purpose, and the hardening that came out of it — plus the terminal work that was queued behind it.
Panes track the mouse for the apps that ask, painting text got a fifth cheaper, and a flooding pane
now slows itself down instead of spending every frame on the UI thread.

<!--more-->

![Screenshot](/images/v0.5.3_1.png)

## The mouse belongs to the app when the app asks

![The Agent Workspace profile: Agent Terminal, Inspector and Reasoning](/images/v0.5.3_2.png)

Full-screen programs have asked terminals for mouse events since `xterm`; gPTY's panes ignored the
question. Now the grid reports what the child enabled (`DECSET 1000`, `1002`, `1003`, and SGR
encoding via `1006`), and the pane forwards exactly what that mode covers: clicks always, drags
under `1002`, a button-less move under `1003`, wheels whenever the app tracks the mouse at all.
`nvim`'s `:set mouse=a`, `lazygit`'s panes, and `herdr`'s pop-ups all work inside a pane now.

Two details worth knowing:

- **Shift is the escape hatch.** While an app has the mouse, hold `Shift` to select text locally and
  copy it with `Ctrl+Shift+V` — the same convention `xterm` established, and the reason a
  full-screen app cannot trap you.
- **Nothing changes when tracking is off.** Selection, scrollback, and the wheel behave exactly as
  before in a plain shell, which is still the common case.

The reports are encoded SGR-style when the app asked for it and in the legacy X10 form otherwise,
from the same cell math selection already used. Where the legacy form cannot address a cell at all
(past 223), the event is dropped rather than pointing at a cell you did not click.

## Repainting less, and repainting cheaper

Two changes to how a busy pane spends the frame:

**Text is drawn in glyph runs.** The renderer used to issue one `draw_string` per cell — up to
~1 900 canvas commands for a full 80×24 pane, nearly all of them a single glyph in a color the
neighbour already used. Consecutive cells that share font, color, and underline state now go out as
one call. A full-screen repaint measured ~20 % cheaper, and both grid sizes render
**pixel-identical** to the old path (that diff is how a dropped underline under an underlined space
was caught before it shipped).

**A pane that cannot keep up stops trying.** When a pane's own grid work — the fetch from Rust plus
the repaint — exceeds a 4 ms budget, it looks at the grid less often, geometrically down to about
10 Hz, and returns to the normal cadence as soon as a sync finds nothing new. This is the
`cat /dev/urandom` case: the damage covers the screen every frame, and the old behaviour spent every
frame packing cells and rebuilding the canvas, which is what made the whole window stutter. Nothing
is dropped — the damage tracker coalesces everything into the newest grid state, and a pane that
keeps up is never throttled. Scrolling with the wheel or jumping from the search bar is exempt
entirely: that work is bounded by your hand, and it is the one case where the repaint rate is
visible.

Measured on a 12000-cell pane repainting its whole screen in a loop: 2.47 ms → 1.46 ms per frame,
in the same window, with a pane that fits its budget left untouched.

## Captures survive their pane

![A cat capture routed into the Code Viewer pane](/images/v0.5.3_3.png)

Concept captures had a quiet way to disappear: closing, swapping or resetting a pane mid-capture
aborted the terminal task past its finalize path, and nothing polls a pane that no longer exists.
The capture state is now shared, so a pane that goes away hands its buffered capture to the engine's
orphan queue, which the workspace keeps draining and routing. A capture can also no longer be
starved by a notify-only concept sitting in front of it, and the shell's post-resize repaint is no
longer buffered into a capture as a duplicated prompt.

## Concepts can no longer run commands

The concept engine's original pitch was "if this, then that": a regex over terminal output, and an
action. The action half could carry a command template that gpty typed into a target pane — that is
how a concept could react to a failing build and drive another pane. It was documented, it had a
field in the concept editor, and it never actually worked in a release: every pane shared the same
terminal id and every action's target list was empty, so no command could reach any pane.

One fix in this release's prep work — unique terminal ids, populated targets — quietly made that
path live for the first time. Reviewing what that meant is what killed it instead.

**A concept file was code execution with an attacker-chosen trigger.** Three properties combine
badly:

- The trigger runs against *terminal output*, which is untrusted. Anything that prints a matching
  line fires the action — a `cat`, a `git log`, a downloaded file, another tool's log.
- The action is *silent*. No prompt, no confirmation, no notice: bytes appear in a pane's shell and
  run. The only trace is the shell's own echo in scrollback.
- The target is chosen by *label*, so a concept could aim at any pane — including the one you left
  in `sudo -s` or SSH'd into production.

That makes a third-party `concepts.json` not a config file but a program: "install my concept pack"
is an arbitrary-code-execution decision that reads like a theme. Worse, the payload's timing is
environmental and repeatable — it fires whenever the chosen pattern shows up, on a schedule the
attacker picks, in whichever pane matches.

The same capability also existed behind **Ctrl+click**: clicking a line matched it against every
concept and ran the first non-empty command. That one shipped in v0.5.2, and it was no better — the
user gesture made it explicit, but it was still a blind "run whatever this file says" with no
visible affordance telling you a line was clickable.

**So it's gone, not gated.** Gating (per-concept consent, a confirmation per execution) was
considered and rejected for this release: nothing in the shipped product used the capability, the
only concepts that carried a command were user-authored, and the design space for consent belongs
with the plugin trust model rather than a config file. Concretely:

- `command_template`, the template substitution and shell-quoting helpers, the label-routing
  function, the engine's injection branch, the pub-sub channel that existed to carry it, the
  Rust click-match export, and the Ctrl+click handler are all deleted.
- `SingleLine` keeps its name and gets a different job: a **notify-only** match. The trigger fires,
  the match is published on the event socket (`{type: concept, event: matched, mode: single_line, …}`),
  and nothing else happens — no capture, no routing, no output taken from the pane. That is the mode
  for an orchestrator that wants to know a pattern appeared without stealing the output, and it is
  metadata only: the matched line is never published.
- A legacy `cmd` key in an existing user file is ignored when the file is parsed and dropped the
  next time the app saves it. Your concepts keep working; they just capture.
- The Settings → Concepts dialog no longer offers a command field.

**What remains is the part that was always safe.** A concept either captures — gpty buffers the raw
bytes and delivers them to the first pane that advertises the concept's target (the code viewer, the
Inspector), replaying them into the terminal when no pane accepts — or it notifies, which publishes a
match event and leaves the output exactly where it was. Concepts observe, route, and announce. They
never act.

## The audit

Alongside that removal, eight independent review passes went over the IPC and socket layer, the
PTY spawn and restore trust boundary, the event channel and Inspector backends, the terminal core
and parser, the rendering surface, the GDScript application shell, the CLI/MCP control surface, and
the build/CI/release pipeline. Findings were verified against the code, not accepted on pattern
match.

### Fixed in this release

- **Workspace Trust covered less than it appeared to.** The dialog existed; the check behind it
  examined only the legacy `shell` key. Restore preferred `command`, and passed `shell_args` and
  `shell_env` through untouched — so a shared profile could spawn
  `["-c", "curl … | sh"]` (or add a `command` override) and the gate that was supposed to ask
  you wouldn't. The environment half of the finding turned out to be unreachable — restore
  overwrites a tile's env with your own global before the shell starts — but the same ordering bug
  silently discards your per-pane env on every restore, and it has to be fixed together with the
  v0.5.5 env model rather than before it. The predicate now covers program and arguments on every
  restore path, the dialog names the program, the argv and each environment entry it is asking you
  to approve, and `layoutLoad` over the control socket refuses an untrusted profile outright —
  a CLI or MCP caller cannot answer a dialog, and naming a profile is not consent to what the file
  asks for.
- **Environment variables that make a shell run what they contain** — `PROMPT_COMMAND`, `BASH_ENV`,
  `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, and the interpreter/tool equivalents (`PERL5OPT`,
  `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`, `LESSOPEN`, `GIT_SSH_COMMAND`, …) — are now refused
  from configuration, next to the dynamic-loader keys that were already blocked. A shell or the
  next tool runs what they contain, so the refusal is the floor under every env source — your own
  global setting today, and whatever the v0.5.5 env model allows later.
- **The Inspector's child process inherited workspace credentials.** An adapter or OMP child got
  the GUI's environment, including `GPTY_SECRET` (control-socket authentication) and, for a GUI
  started inside a pane, that pane's event capability. Both backends now strip the same key list
  the PTY spawner uses.
- **Restored grid sizes were unbounded.** A tile with a large `rows`/`cols` allocated the cells
  before any frame was drawn; both the layout sanitizer and the FFI now clamp.
- **A one-character search could stall the UI.** Match collection is capped instead of
  materialising every hit across the whole scrollback on each keystroke.
- **MCP `tools/call` accepted any method name**, including ones that were never published as tools.
  It now rejects anything outside the advertised schema.
- **Pane edges could not be dragged.** The resize handler ran where the pane body consumed the
  mouse, the drag was measured from the wrong origin so every small step rounded away, and a
  half-applied move left the grid not adding up. Panes now resize the way a tmux divider does:
  drag the edge, the panes follow the pointer, and neither can be squeezed below its minimum.
- **CI inherited the repository's default token scope** for every job — including the one that
  hands it to a third-party audit action. `ci.yml` now declares `contents: read`.

### Recorded, not fixed

The audit also produced a list of real issues that need design work rather than a quick patch:
an unbounded PTY-output queue under flood, bare program names that bypass executable validation once
a profile sets `PATH`, pasting without bracketed-paste wrapping, one blocking SQLite write per output
line on the UI thread, unbounded file reads in the viewer panes, predictable temp-file writes, the
Windows and non-Linux peer-credential gaps in the IPC layer, and supply-chain items in CI (mutable
action tags, unverified tool downloads, unsigned artifacts). Each is now a roadmap item with the
concrete fix sketched, rather than a note in a review that nobody re-reads.

## A security policy, in writing

[SECURITY.md](https://github.com/godot-pty/gpty/blob/main/SECURITY.md) now states what gpty defends
against and what it doesn't: the trust model (same-UID processes are trusted; terminal output,
files, remote responses, and other users are not), what is deliberately absent (sandboxing, OSC 52
clipboard access, command execution from config), the hardening that must not be weakened, and the
known limitations — Windows peer verification, the shared-`/tmp` socket fallback, plaintext
scrollback, unsigned artifacts, and the two DoS items the audit left open (the unbounded PTY-output
channel and the per-line scrollback write; the render loop the audit also flagged is rate-limited
now).

That list is the point. A threat model that only lists strengths is marketing; the limitations
section is where the honest engineering lives.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.3).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#053--2026-09-10).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
