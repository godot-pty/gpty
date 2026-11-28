# Roadmap

The source of truth for all `gPTY` features; past, present, and planned.

- GitHub Issues will be used for user-reported bugs and discussions, not roadmap tracking.
- Boundary rules and non-goals live in AGENTS.md under "ADE Architecture Boundary".
- **The roadmap is a queue, not a diary.** It is split into one page per release chain, and within a release rows are ordered by priority - the first unchecked row (⬜) of the earliest unfinished release is the immediate next implementation. Ordering is: data-loss and correctness first, then security with a reachable path, then the release's own features, then robustness and tests, then low-reachability hardening, then polish, then work that can only happen at release time. Rows are never grouped by origin or by which release deferred them (the row text says that where it matters); completed rows stay under their release as the record, and the CHANGELOG carries the user-facing summary. A defect or follow-up found while working a row is added as its own row, in priority position, with enough detail to act on later. The ID prefix names the part of the project a row targets (TERM, GUI, IPC, CLI, SEC, PLUGIN, WIKI, CONCEPT, MEDIA, AGENT, CORE, BUILD, DOCS, PROJECT); the number is allocated once and never reused. Future holds ideas and evidence-gated work that is not scheduled.
- **Every row has a stable ID** (`GUI-188`): the prefix is the area, the number is allocated once and never reused, and position on the page is priority - never the ID. The row's evidence is its `## <ID>` section on `details/<area>.md`; a closed row carries the commits that advanced it, and an unshipped row is `🚫` dropped or `❌` won't fix, with the reason in its detail.
- `scripts/roadmap` is the ledger's reader and writer: `next` (the first open row), `show <ID>` (its record), `next-id`, `add` (allocate a row with its detail section), `move <ID> <release>`, `record <ID>` (rewrite the evidence), `close`, `rearea`, `stats`, `release-check`, `audit` (hashes, line caps, cited IDs, reasons), `selftest`.

## Release chains

- [v0.1 - Core Engine](docs/content/docs/roadmap/v0.1.md) - released, 0 open
- [v0.2 - UI/UX](docs/content/docs/roadmap/v0.2.md) - released, 0 open
- [v0.3 - CLI, Windows & Hardening](docs/content/docs/roadmap/v0.3.md) - released, 0 open
- [v0.4 - Inspector & Reasoning](docs/content/docs/roadmap/v0.4.md) - released, 0 open
- [v0.5 - ADE Foundation](docs/content/docs/roadmap/v0.5.md) - released, 0 open
- [v0.6 - Knowledge Base & Wiki](docs/content/docs/roadmap/v0.6.md) - released, 0 open
- [v0.7 - Media Pane & Trust Boundary](docs/content/docs/roadmap/v0.7.md) - released, 0 open
- [v0.8 - UI/UX & Graphical Fidelity](docs/content/docs/roadmap/v0.8.md) - in progress, 16 open
- [v0.9 - Instrumentation, Fidelity & Health](docs/content/docs/roadmap/v0.9.md) - planned, 99 open
- [v0.10 - Headless Daemon & Reattach](docs/content/docs/roadmap/v0.10.md) - planned, 8 open
- [v0.11 - Game Pane](docs/content/docs/roadmap/v0.11.md) - planned, 16 open
- [v0.12 - Knowledge Base Follow-ups](docs/content/docs/roadmap/v0.12.md) - planned, 22 open
- [v0.13 - Platform & Media Depth](docs/content/docs/roadmap/v0.13.md) - planned, 6 open
- [v0.14 - Agent Backends](docs/content/docs/roadmap/v0.14.md) - planned, 20 open
- [v1.0 - Public Launch](docs/content/docs/roadmap/v1.0.md) - planned, deferred, 5 open
- [Future](docs/content/docs/roadmap/future.md) - unscheduled, 27 open
