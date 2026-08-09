---
title: gpty
toc: false
---

## Multi-PTY Emulator

**gpty** is a tiling grid terminal emulator built with Rust and Godot. Run multiple PTY sessions side by side, capture command output via regex concepts, and manage layouts with profiles.

![gpty terminal grid](/images/v0.1.0_1.png)

{{< cards >}}
  {{< card link="/gpty/docs" title="Documentation" icon="book-open" subtitle="Learn how gpty works, from the PTY engine to the Godot GUI." >}}
  {{< card link="/gpty/blog" title="Blog" icon="pencil" subtitle="Release notes, tips, and development updates." >}}
  {{< card link="https://github.com/gpty/gpty" title="GitHub" icon="github" subtitle="Star, fork, or open an issue on GitHub." >}}
{{< /cards >}}

## Features

&nbsp;

{{< hextra/feature-grid >}}
  {{< hextra/feature-card
    title="Multi-PTY Grid"
    subtitle="Tile multiple terminals in a resizable grid. Split, swap, and kill panes with keyboard shortcuts."
    icon="terminal"
  >}}
  {{< hextra/feature-card
    title="Concept Capture"
    subtitle="Define regex patterns to detect commands and automatically capture their output."
    icon="sparkles"
  >}}
  {{< hextra/feature-card
    title="Profiles"
    subtitle="Save and restore terminal layouts as named profiles. Switch contexts instantly."
    icon="bookmark"
  >}}
{{< /hextra/feature-grid >}}
