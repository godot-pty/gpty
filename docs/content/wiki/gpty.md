# gPTY

gPTY is a desktop workspace built on Rust and Godot: a tiling grid of terminal panes and specialty panes, driven by a public control API, with a small engine that routes output between panes. The name is Godot + PTY; the capitals are for reading, the binary is `gpty`.

It is a terminal emulator, but the point is the workspace around it. A terminal is one pane among several, and every pane is addressable from a shell, a script, or an agent over the same API. The grid, the visual panes, and the control surface are the product; the shell inside a terminal is still just a shell.

## Why this exists

Most terminals are a window around one PTY. Multiplexers add sessions and panes inside a character grid. gPTY starts from a different question: what if the panes were real GUI surfaces, and what if the workspace itself were an API?

That choice buys things a terminal multiplexer cannot easily do: a media pane that decodes video, a wiki pane that draws its own link graph, a code viewer, a file tree, a Markdown preview. It also keeps the terminal honest — the grid, scrollback, colors, selection, and full-screen programs behave like a terminal, because the engine is built on `alacritty_terminal` and `portable-pty` rather than a new emulator.

It does not try to be an IDE, a browser, or an agent runtime. The design goal is to be a good host: panes for programs, a public API for orchestrators, and a display layer that never pretends to be in charge of them.

## The layers

gPTY is explicit about where its responsibility ends. The model is a stack from the operating system up to the ecosystem:

| Layer | Owner | Examples |
|---|---|---|
| L4 | Ecosystem | Agent CLIs and apps: Claude Code, codex, opencode, OMP, vim, btop |
| L3 | Ecosystem, open market | Orchestration: agent waits, pane states, plugin workflows |
| L2 | gPTY | Control surface: JSON-RPC socket, CLI, MCP, event socket |
| L1 | gPTY | PTY foundation: lifecycle, grid, capture, history, security |
| L0 | Operating system | `/dev/ptmx`, ConPTY, sockets |

gPTY owns L0–L2 and ships a thin built-in L3 — concept routing, Inspector sessions, profile restore. It does not absorb an orchestrator's state machine into core. A tool like herdr can run inside a pane today and drive the public API as a guest; cloning its session manager is not the plan.

The same boundary shows up in the agent features: gPTY **observes and displays** agent state, it never manages it. There is no agent runtime, no wait/block state machine, and no action taken on your behalf because an agent looked busy. Panes expose primitives (`paneStatus`, `paneWait`, events); an orchestrator builds the policy.

## The feature map

| Area | What you get | Start at |
|---|---|---|
| Terminals | PTY-backed shells, grid, colors, selection, scrollback, search | [[terminal-pane]] |
| Layout | 60-unit tiling grid, splits, drag, named layouts | [[layout]] |
| Workspaces | Tabs of independent pane sets, each with a default directory | [[workspace]] |
| Profiles | Named tile sets, including the shipped Agent Workspace | [[profile]] |
| Other panes | Code viewer, file tree, wiki, media, CLI view, Inspector, Reasoning | [[pane]] |
| Automation | JSON-RPC, CLI, MCP, pane states, tags, broadcast | [[control-api]] |
| Concepts | Regex triggers that route captured output to a viewing pane | [[concepts]] |
| Knowledge base | Markdown vaults with search, wikilinks, backlinks, a link graph | [[vault]] |
| Plugins | Manifest-based add-ons, reviewed before install, run as you | [[plugins]] |
| Trust | Consent gates for restored programs and plugin installs | [[workspace-trust]] |

## What it deliberately is not

- **Not an orchestrator.** Concept routing and agent-state badges are display paths. gPTY does not decide when an agent is done or start the next task.
- **Not an IDE.** The code viewer reads; it does not edit. A full editor is a different product.
- **Not a browser host.** There is no webview pane and no general plugin UI runtime; `cli_view` streams a command's stdout and is the v1 plugin surface. Native third-party GDScript/Rust panes are outside the v1 trust model.
- **Not a clone of a terminal multiplexer.** It can run tmux, Zellij, or herdr inside a pane. It is not trying to replace their session model.
- **Not a zero-config promise.** Layouts, profiles, and plugins are files, and files are untrusted; the app asks before it runs something they name.

## Status and licensing

gPTY is a side project in active development; the current release line is 0.7. The core is GPL-3.0-or-later, with a section 7 permission that keeps plugins, extensions, adapters, and data files free of copyleft. Plugins can be MIT or Apache-2.0 and ship alongside the app.

The codebase was built with heavy LLM assistance under human review. That is worth knowing when you read it: the architecture is deliberate, but some corners are less polished than a mature emulator's.

## Related

- [[getting-started]]
- [[architecture]]
- [[pane]]
- [[control-api]]
- [[terminal-foundations]]
- [[vault]]
