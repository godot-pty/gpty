---
title: gpty v0.6.0
date: 2026-10-19
---

v0.6.0 is the knowledge-base release. A new wiki pane opens a vault of plain Markdown notes, indexes
it for full-text search, edits notes with a live preview, follows `[[wikilinks]]` in place, draws the
vault's link graph, and exposes search and read to agents over the pane API. The file tree also
learned to open supported files in a viewer pane instead of handing them to the desktop.

<!--more-->

![gPTY v0.6.0](/images/v0.6.0_1.png)

## A vault, not a format

The wiki pane points at a directory of ordinary `.md` files. There is no import step, no database
inside the vault and no proprietary format: the index lives outside it at `state_dir()/vaults.db`,
and the vault stays something Obsidian or an editor can own. The walk skips hidden entries at every
level, caps the note count and depth, and reads at most 1 MiB of each note - the same cut the text
viewers use, so a search hit can never name text the view does not show.

The pane's note list and its search box both come from that one index. Search re-reads only notes
whose mtime or size changed, drops deleted rows, and ranks with porter stemming because notes are
prose: "running" finds "run". A query the index cannot run answers an error; a query with no hits
answers an empty result, and the search box stays on screen so you can amend it.

## Edit with the preview in front of you

A note opens into an editor beside the sanitized Markdown preview (Edit / Split / Preview, split by
default), and the preview follows the buffer rather than the file, so unsaved work is what you see.
Saving is explicit - the Save button or Ctrl+S - with a dirty marker and Save disabled while clean.
The write is atomic, keeps the note's own mode, preserves CRLF endings, and refuses to overwrite a
file that changed on disk since it was loaded without asking. A note past the 1 MiB read cap stays
read-only, because saving a truncated read would drop the rest.

The editor also creates, renames and deletes notes. The path rules are the walk's own: `.md`, no
hidden components, a directory that already exists inside the vault, and a destination claimed with
`create_new` so an existing note is never overwritten. A rename can offer to update the mentions
that named the old name, with a count before anything is written; only occurrences that actually
resolved to it are respelled, and aliases, fragments, CRLF and fenced code survive.

If the app exits with unsaved work, a recovery copy of the dirty buffer is waiting when the note is
opened again. It lives outside the vault, is keyed by the vault and note path, and is offered -
never applied automatically - through a Restore / Discard question.

## Links you can follow

`[[note]]`, `[[note|alias]]` and `[[note#heading]]` are parsed as the index pass reads each note and
stored as one row per occurrence, with the line it was written on. The link parser is the Markdown
renderer's parser, so a fenced block, an inline code span and an escaped opener stay literal in both
places. A target resolves by stem, or by path when it contains `/`, exact case first and then a
unique case-insensitive match - a stem two notes share is ambiguous and is reported, never guessed.

Clicking a mention follows it in place behind the existing Save / Discard / Cancel guard, and a
fragment lands on the heading it names. The link panel lists outgoing mentions and backlinks with
their lines; a mention into the note already open only moves the view. An unresolved mention offers
to create the note it names, because creating it is not a guess about which candidate was meant.

![Links and backlinks in the note view](/images/v0.6.0_3.png)

## The graph is the vault's own structure

The wiki pane's **Graph** view draws the link structure already in the index. Nodes are notes plus a
ghost for every unresolved target; edges aggregate mentions per note pair, with a mutual pair drawn
double-headed, and thickness is logarithmic and clamped so one chatty note cannot drown the drawing.
It writes nothing and adds no file type: positions are session geometry, Relayout restores the
deterministic arrangement, and clicking a note opens it through the same leave guard as the list.

![The vault's link graph](/images/v0.6.0_2.png)

An edge's measured weight is only a mention count, so a weight can also be *declared* - right-click
an edge, or use `gpty vault weight` / the `vault-weight` MCP tool. A declaration overrides the
number for thickness, the Relayout springs and link-panel ordering, and lives in the user-owned
`user://link_weights.json` rather than the rebuildable index. It never changes which edges exist,
what a click reaches, or any trust decision. Renaming a note re-keys both endpoints so the curation
follows the file.

## Agents can read the knowledge base

`gpty vault search <vault> <pattern>` and `gpty vault read <vault> <path>` - also the
`vault-search` and `vault-read` MCP tools - expose the vault through the same control socket as
every other primitive. Search re-indexes first, so a note edited outside gPTY is visible to the next
query. Read answers the note document under the editor's own path vocabulary, regular-file gate and
1 MiB cut. Both are native Rust methods on the blocking pool, and both are reads: the vault API
never writes a note.

## The file tree opens files in a viewer

Double-clicking a supported file - source, config, docs, Markdown, text, log, diff, patch, and the
extensionless `Makefile` / `Dockerfile` / `LICENSE` / `Justfile` - now opens a read-only
`code_viewer` pane at that path instead of leaving gPTY. Opening the same file again focuses the
pane that already shows it, and **Reload** re-reads it after a change on disk. Everything the closed
`ViewableFiles` table does not name keeps the existing confirmation-then-system path, so binaries,
images and a downloaded `.desktop` behave as before.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.6.0).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.6.0.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
