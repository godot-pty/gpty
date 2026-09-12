---
title: gPTY
toc: false
---

[gPTY](https://godot-pty.github.io/gpty/) - a PTY foundation built on Godot and Rust. Provides a tiling grid for panes (terminal, code, file-tree, etc.), a concept capture engine, and a JSON-RPC/MCP control surface so AI agents and automation tools can spawn panes, inject text, and observe output on terminals without scraping a TUI.

![gpty terminal grid](/images/v0.5.4_1.png)

{{< cards >}}
  {{< card link="/gpty/docs" title="Documentation" icon="book-open" subtitle="Learn how gPTY works, from the PTY engine to the public agent API." >}}
  {{< card link="/gpty/blog" title="Blog" icon="pencil" subtitle="Release notes, tips, and development updates." >}}
  {{< card link="https://github.com/godot-pty/gpty" title="GitHub" icon="github" subtitle="Star, fork, or open an issue on GitHub." >}}
  {{< card link="https://github.com/godot-pty/gpty/releases/latest" title="Download" icon="cloud-download" subtitle="Download the latest release." >}}
{{< /cards >}}

## Features

&nbsp;

{{< hextra/feature-grid >}}
  {{< hextra/feature-card
    title="PTY Foundation & Public API"
    subtitle="Spawn and manage shell sessions over a documented JSON-RPC socket, CLI, and MCP server — the same protocol AI agents use."
    icon="terminal"
  >}}
  {{< hextra/feature-card
    title="Concept Engine"
    subtitle="RegEx triggers on PTY output capture the reply and route it into adjacent panes — code viewer, Inspector — with no polling."
    icon="sparkles"
  >}}
  {{< hextra/feature-card
    title="Agent Observability"
    subtitle="Reasoning and Inspector panes surface agent lifecycle events and private Q&A without orchestrating agent state."
    icon="bookmark"
  >}}
{{< /hextra/feature-grid >}}
