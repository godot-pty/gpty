---
title: gPTY
toc: false
---

[gPTY](https://gpty.dev/) - a PTY foundation built on Godot and Rust. Provides a tiling grid for panes (terminal, code viewer, file tree, wiki, media, and more), a concept capture engine, and a JSON-RPC/MCP control surface so AI agents and automation tools can spawn panes, inject text, and observe output on terminals without scraping a TUI.

{{< video "demo-showcase" >}}

{{< cards >}}
  {{< card link="/docs" title="Documentation" icon="book-open" subtitle="Learn how gPTY works, from the PTY engine to the public agent API." >}}
  {{< card link="/blog" title="Blog" icon="pencil" subtitle="Release notes, tips, and development updates." >}}
  {{< card link="https://github.com/godot-pty/gpty" title="GitHub" icon="github" subtitle="Star, fork, or open an issue on GitHub." >}}
  {{< card link="https://github.com/godot-pty/gpty/releases/latest" title="Download" icon="cloud-download" subtitle="Download the latest release." >}}
{{< /cards >}}

## Features

### Panes and the grid

{{< video "demo-panes" >}}

A tiling grid of real PTY panes - terminals, file trees, code viewers, wikis, media and anything
a command can stream. Split, close, and restore them where you left off, with scrollback that
survives a restart.

### The wiki vault

{{< video "demo-wiki" >}}

A vault of plain Markdown notes with full-text search, a live-preview editor, `[[wikilinks]]`,
backlinks and a link graph. The same vault is a CLI and MCP endpoint, so an agent reads what you read.

### Media

{{< video "demo-media" >}}

Audio and video play in a pane through a pinned, minimal FFmpeg backend, beside the terminals
that matter without a second window.

### Streaming panes

{{< video "demo-cli-view" >}}

`cli_view` streams any command's output into its own pane, so a plugin can add UI without a Godot SDK.

### Agents and automation

{{< video "demo-agents" >}}

One API, three doors: the same operations are a JSON-RPC socket, the `gpty` CLI and an MCP server.
Tag panes, broadcast to all of them, read their state and wait on their output - no scraping a TUI.
Agent state badges are display only; gPTY never orchestrates the agent.

### Concepts

{{< video "demo-concepts" >}}

Concepts are regex triggers on terminal output: the reply is captured and routed into an adjacent
pane, such as a code viewer or the Inspector. Display only - a concept never types into a shell.

### Plugins

Manifest-based, reviewed in the GUI before install, with a public [registry](/plugins/).
