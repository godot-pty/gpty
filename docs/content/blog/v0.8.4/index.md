---
title: gpty v0.8.4
date: 2026-11-16
---

v0.8.4 is about making a pane describe itself: where it starts, what it runs, and what it is called. A
terminal tile can carry a launch line that runs through your shell, a pane remembers its own
directory, and a settings value outside its declared vocabulary is refused where it is written
instead of being silently normalized.

The same pass gave the profile vocabulary one spelling - a *profile* is the named reusable tile
arrangement, a *layout* is the grid inside one workspace - and moved the public verbs from `layout` to
`profile` with no alias left behind. Under the surface it is mostly hardening: the PTY input queue and
the plugin store's reader are both bounded, and the release no longer runs project code with a write
token.

<!--more-->

![A fresh launch on v0.8.4](/images/v0.8.4_1.png)

**A launch line, not just a command name.** A terminal tile may now hold `launch`: one line, at most
1024 characters, no control characters. It is expanded when the pane's child is started, so it runs
through your shell exactly as a pane command does - `omp update && omp` works, where a bare program
name could not - and every path that starts a child goes through the same helper, so restore, spawn, a
profile activation and a restored workspace cannot disagree. A launch line wins over the pane's
`command` and `shell_args`. Pane Settings gained a **Launch command** field whose placeholder is your
shell while the line is empty, and whose caption says it takes effect at this pane's next start rather
than in the program already running. Save Profile's per-pane field became a launch line too, so typing
`lazygit` there saves a line that runs `lazygit` through the shell.

![Pane Settings with the launch command and directory rows](/images/v0.8.4_2.png)

![Save Profile's per-pane launch lines, inherited by default](/images/v0.8.4_3.png)

**A pane remembers its own directory.** Pane Settings' directory row sets where this pane's child
starts, with the workspace directory as the fallback. The choice is keyed by the workspace *and* the
pane, because a pane id alone follows a profile from one repository into another; that needed a
stable per-workspace id, so `workspaces.json` entries carry one now and a store that lacks it gets one
minted on first load.

**One word for a profile.** The sidebar's entry point is "More profiles →", the workspace-restore
dialog says the file is a set of workspaces whose panes start a different program, and the plugin
review prints "no program (geometry only)" for a profile that carries nothing to run. The public verbs
followed: `gpty profile save|load|list`, the `profile-save` / `profile-load` / `profile-list` MCP tools
and the `profileSave` / `profileLoad` / `profileList` IPC methods replace the old spelling, and the old
one is gone - **a script or agent that called `gpty layout …` or the `layout-*` tools has to switch;
there is no alias.** The four layers that have to agree moved together.

The built-in Agent Workspace stopped naming one tool: it is a terminal beside an Inspector for private
Q&A and a Reasoning pane for the agent's live commentary, wired with `agent-terminal` /
`agent-inspector` / `agent-reasoning`, and its Inspector no longer pins a backend. **A saved layout or
workspace keeps the ids it was saved with and is unaffected by the rename.** The published twin,
`godot-pty/gpty-agent-workspace`, carries the same ids, and `godot-pty/gpty-omp` 0.2.0 ships an
`OMP Workspace` profile beside its single-pane launcher.

**Refused where it is written.** A settings rule can now name a closed vocabulary, checked after its
length check: a value outside the set is refused at every source - `pane-set` and `new-pane --setting`
answer `-32602` naming the key, a saved tile drops it and the workspace reports it once, and the live
pane keeps the value it had - and `pane-settings` publishes the set so a caller can discover it
instead of guessing. A scheme with fewer than 16 colours no longer inherits the rest of the previous
one, since the palette setter assigns all 16 slots and falls back to the system default for the rest.

**Bounded, on both ends.** Input that cannot be delivered is refused instead of queued forever: a
256-message queue into the PTY engine and a 16-chunk writer queue replace the unbounded ones, so a pane
whose child stops reading can no longer grow the process without limit, and `inject` answers
`refused` while `broadcast` reports a `refused` count. The plugin store gained a 16 MiB read cap and a
forward-compatibility rule - an unknown sibling key is ignored at every level, while a missing field, a
bad shape and a cap are still refused - so a store written by a newer build stays readable by an older
CLI.

**The release train.** The project's own release process is in this release because it changed: `0.8.x`
is the integration branch, a `gpty-bot` GitHub App pushes it and opens the release pull request (it
never approves or merges), and a `main` ruleset with no bypass actors requires a pull request, a
code-owner review and the full check set. The release workflow is split so no write or OIDC privilege
is present while project code runs: a read-only job validates the tag and the versions, a read-only job
exports and uploads the archives, and only the publishing job holds the write token. A new
`scripts/check-secrets` refuses private keys and token prefixes in the git index, a scheduled gitleaks
job scans the full history, and the macOS bundle's FFmpeg is now built for 11.0 (arm64) and 10.13
(x86_64) to match the app template instead of declaring a newer macOS than the app does.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.8.4).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.8.4.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
