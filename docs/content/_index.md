---
title: gPTY
toc: false
---

[gPTY](https://godot-pty.github.io/gpty/) is a graphical Agent Development Environment (ADE) — a PTY foundation with a public, agent-facing API — built on Godot and Rust. Spawn terminals, drive them over JSON-RPC/MCP, and let agents observe output without scraping a TUI.

![gpty terminal grid](/images/v0.3.0_1.png)

{{< cards >}}
  {{< card link="/gpty/docs" title="Documentation" icon="book-open" subtitle="Learn how gPTY works, from the PTY engine to the public agent API." >}}
  {{< card link="/gpty/blog" title="Blog" icon="pencil" subtitle="Release notes, tips, and development updates." >}}
  {{< card link="https://github.com/godot-pty/gpty" title="GitHub" icon="github" subtitle="Star, fork, or open an issue on GitHub." >}}
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
    subtitle="RegEx triggers on PTY output inject commands or capture output into adjacent panes — no polling required."
    icon="sparkles"
  >}}
  {{< hextra/feature-card
    title="Agent Observability"
    subtitle="Reasoning and Inspector panes surface agent lifecycle events and private Q&A without orchestrating agent state."
    icon="bookmark"
  >}}
{{< /hextra/feature-grid >}}
