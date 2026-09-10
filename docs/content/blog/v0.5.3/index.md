---
title: gpty v0.5.3
date: 2026-09-10
draft: true
---

v0.5.3 is the audit release: a security pass over the whole codebase, one capability removed on
purpose, and a set of hardening fixes that came out of it.

<!--more-->

<!-- Release step: drop `draft: true`, fill in the performance/mouse sections for this release,
     add the home screenshot (/images/v0.5.3_1.png) and the standard download footer. -->

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
  `["-c", "curl … | sh"]` or set `PROMPT_COMMAND`, and the gate that was supposed to ask you
  wouldn't. The predicate now covers program, arguments, and environment, and both restore paths
  use one implementation.
- **Environment variables that make a shell run what they contain** — `PROMPT_COMMAND`, `BASH_ENV`,
  `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, and the interpreter/tool equivalents (`PERL5OPT`,
  `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`, `LESSOPEN`, `GIT_SSH_COMMAND`, …) — are now refused
  from configuration, next to the dynamic-loader keys that were already blocked. This was a
  code-execution path that never named a command.
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
scrollback, unsigned artifacts, and the fact that a flooded pane can still push the render loop
hard.

That list is the point. A threat model that only lists strengths is marketing; the limitations
section is where the honest engineering lives.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.3).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#053--2026-09-10).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
