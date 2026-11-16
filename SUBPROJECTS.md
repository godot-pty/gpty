# Subprojects

gPTY is one project with several public repositories. This page records each
codebase's status and intent, so an OSPS review and a contributor can see what
ships in a release and what is installed separately. The machine-readable copy
is `project.repositories` in [security-insights.yml](security-insights.yml).

## Shipped in a release

| Repository | Status | Intent |
| --- | --- | --- |
| [gpty](https://github.com/godot-pty/gpty) | Active; GPL-3.0-or-later | The core application: the Rust crates, the Godot frontend, the CLI and the MCP server. Every release archive is built here. |

The core release also bundles the in-tree `extensions/gpty-omp-events` (MIT,
the OMP event bridge) and the vendored `godot/addons/gut` (MIT, test-only).
Neither is a separate project repository. Third-party components and their
licences are in [LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md).

## Published separately (plugin catalog and data)

These repositories ship plugin profiles or data. A plugin profile is installed
by the user with `gpty plugin install <owner>/<repo>`; the inventory is read by
the plugin catalog. None is compiled into the core release.

| Repository | Status | Intent |
| --- | --- | --- |
| [gpty-omp](https://github.com/godot-pty/gpty-omp) | Active; Apache-2.0 | An OMP profile: a full-grid terminal running `omp`. |
| [gpty-herdr](https://github.com/godot-pty/gpty-herdr) | Active; Apache-2.0 | A Herdr profile: a full-grid terminal running `herdr`. |
| [gpty-lazygit](https://github.com/godot-pty/gpty-lazygit) | Active; Apache-2.0 | A lazygit profile: a full-grid terminal running `lazygit`. |
| [gpty-neovim](https://github.com/godot-pty/gpty-neovim) | Active; Apache-2.0 | A Neovim profile: a full-grid terminal running `nvim`. |
| [gpty-claude](https://github.com/godot-pty/gpty-claude) | Active; Apache-2.0 | A Claude profile: a full-grid terminal running `claude`. |
| [gpty-agent-workspace](https://github.com/godot-pty/gpty-agent-workspace) | Active; Apache-2.0 | The published twin of the built-in Agent Workspace profile. |
| [gpty-knowledge-base](https://github.com/godot-pty/gpty-knowledge-base) | Active; Apache-2.0 | The published twin of the built-in Knowledge Base profile. |
| [gpty-plugins](https://github.com/godot-pty/gpty-plugins) | Active; Apache-2.0 | The plugin inventory (`registry.json`) and its validator (`validate.py`). Not compiled into the core release. |

## Adding a repository

A new repository joins the list above and `project.repositories` in
[security-insights.yml](security-insights.yml) in the same change that creates
it. A repository that stops shipping is marked archived in both places rather
than removed from the history.
