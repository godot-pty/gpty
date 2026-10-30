---
name: gpty-wiki
description: "Use when adding or revising notes in gPTY's shipped knowledge base (docs/content/wiki), fixing wikilinks, or rebuilding the tracked godot/knowledge.json bundle."
---

# Updating gPTY's knowledge base

The vault at `docs/content/wiki` is the knowledge base the app ships: a plain Markdown directory the Wiki pane lists, searches, renders, and draws as a link graph. `godot/knowledge.json` is generated from it and is **tracked**, and CI fails when it is stale. So every note change has two halves: the note, then the bundle.

`docs/content/wiki` is a different tree from `docs/content/docs`: the latter is the Hugo site (front matter, roadmap tables, changelog pages). The vault has no front matter and no manifest; it states what is true now, not task status.

## Before writing

- **Search first.** `grep -rn "<term>" docs/content/wiki` works in any checkout; with a GUI running, `gpty vault search "$PWD/docs/content/wiki" "<term>"` gives stemmed hits over title and body, best-rank first (MCP: `vault-search`). Extend the note that owns the idea instead of adding a near-duplicate.
- **Pick the folder.** `foundations/` terminal and PTY theory; `gpty/` project internals; `panes/` pane types; `wiki/` vault features; `recipes/` workflows; `pane.md` at the root for the pane model.
- **The filename is the link target.** A bare `[[stem]]` resolves the note's **file stem**, case-insensitively and only when that stem is unique across the whole vault — a heading is never a target. A target containing `/` is a vault-relative path (`.md` optional). Two notes sharing a stem anywhere make every bare link to it ambiguous.
- **Renaming breaks inbound links.** A `mv` or editor rename leaves `[[stem]]` pointing at nothing; grep the vault for `[[stem` and update it, or use the pane's Rename, which offers to rewrite references.

## Writing a note

- Start with one `# Title`; that first heading is the note's title. **Do not add YAML front matter**: no `title:` key is read, and the block renders as visible body text.
- House shape: a short opening paragraph, then `##` sections, then a `## Related` list of wikilinks. Backlinks and graph edges are derived from mentions — nothing is authored twice.
- Wikilinks: `[[stem]]`, `[[stem|display label]]` (label is presentation only), `[[stem#heading]]` (fragment navigates only), `[[gpty/security-model]]` for a path. A fenced block, an inline code span, or `\[[` is literal, so a note documenting the syntax creates no edges. A mistyped target appears as a ghost node in the Graph view.
- Rendering: headings, emphasis, tables, fenced code and wikilinks render in the preview; raw HTML is not interpreted, images become alt text, and only `http`/`https`/`mailto` links become clickable (after a confirmation). Notes are read and rendered at a 1 MiB cap — a larger note opens read-only.
- Declared link weights are a user's display preference in `user://link_weights.json`; never encode them in notes or commit them. `gpty vault weight` writes only that store, and only while the GUI runs.

## Ship it

1. `./scripts/build-wiki` rewrites the tracked `godot/knowledge.json` and prints the note count and version hash.
2. `./scripts/build-wiki --check` is the CI gate: it fails on a stale bundle.
3. `./scripts/docs-check` lints the docs tree (Markdown, roadmap tables, split pages).
4. Optional live proof: launch a headless GUI in a temp sandbox (`GPTY_SOCKET`, `GPTY_TEST_USER_DIR`, `XDG_*` pointed there), run `gpty layout load "Knowledge Base"`, then read `knowledge/<version>/<note path>` under that temp dir — the bundle is seeded on first use.
5. `./scripts/ci-check` runs the bundle gate among everything else; `--fast` does not.

## Don't

- Don't edit `godot/knowledge.json` by hand, and don't edit the seeded copy under `user://knowledge/<hash>`. The app copy is a snapshot; a changed bundle seeds a new directory and never overwrites local edits.
- Don't put roadmap or changelog status in the vault. Task state lives in `docs/content/docs/roadmap` and `.../changelog`; the vault states current behavior and reasoning.
- Don't copy an existing note's explanation to add a new angle — link it and add only what is new.
