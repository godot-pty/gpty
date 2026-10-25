# Wiki Pane

A wiki pane browses a directory of Markdown notes as a vault: it lists the notes, searches them, renders one through the sanitized Markdown pipeline, edits it with a live preview, and draws the vault's link graph. You are reading one of its notes right now.

## What it is

The body is `WikiPane` (`godot/scenes/panes/wiki_pane.gd`); the registered type key is `wiki` and its label prefix is `W`. A vault is just a directory of `.md` files — the pane does not own a database format. The search index lives elsewhere, in gPTY's state directory, so a vault stays plain and portable.

The pane has two faces. The **list** shows the vault's notes, a search box and a **Graph** button. Opening a note switches to the **note view**: a source editor, a live rendered preview, a small toolbar with the view modes, and a links panel for what the note points at and what points back at it.

## When to use it

Use it for durable notes you want to keep next to the work: project context, decisions, runbooks, recipes. It is also a working example of the link model behind [[wikilinks]] and the [[link-graph]], since it is the only pane that implements both.

For reading a single arbitrary file, the [[code-viewer|Code Viewer]] is lighter and read-only. For writing code, use an editor in a terminal.

## How to open it

| Method | Action |
|---|---|
| Sidebar | the wiki button |
| Palette | `new wiki` |
| CLI | `gpty new-pane -t wiki` |
| MCP | the `new-pane` tool with `type: "wiki"` |
| Layout/profile | a saved tile restores its vault path, open note and whether the graph was showing |
| Built-in profile | **Knowledge Base** opens the app's bundled vault without a path |

The pane has no keyboard shortcut of its own. A new pane has no vault until one is set in Pane Settings (or supplied by a profile or layout); a hand-set path must be absolute and existing, and it is validated every time it is used rather than trusted once. The built-in **Knowledge Base** profile stores the `@knowledge` token instead of a machine path: the pane resolves it to the copy seeded from the app's bundle on first use, and a later release with changed notes seeds a new copy rather than overwriting local edits. The repository ships this wiki at `docs/content/wiki` — that directory is a good first vault in a checkout.

The same vault is reachable without a pane: the control surface exposes `vault-search`, `vault-read` and `vault-weight`, so an agent or a script can query notes and set link weights while you work. Those tools share the pane's index rules, so both agree on what a note is.

## What it shows and how it is driven

The list is built by one recursive walk: `.md` files only, hidden entries skipped at every level, at most 2,000 notes and 16 levels deep. Search runs against an SQLite FTS5 index with porter stemming (notes are prose, so `run` matches `running`), waits 0.15 s after a keystroke, and asks for up to 200 hits; the store itself accepts 1–500.

The note view has three modes, remembered per pane as `view_mode`:

| Mode | Layout |
|---|---|
| `edit` | source editor only |
| `split` | source and live preview (the default) |
| `preview` | rendered Markdown only |

Editing is explicit. A dirty marker appears while the buffer differs from disk; **Save** or `Ctrl+S` writes; there is no autosave. Closing or leaving a note with unsaved changes raises a Save / Discard / Cancel guard, and every path that can destroy the buffer runs through it. Saves are atomic and carry a stamp of the file's `mtime` and `size`, so a note changed by something else since it was loaded is not silently overwritten. An unsaved buffer also gets a recovery copy outside the vault, offered back the next time the note is opened — never applied on its own.

The note verbs are **New note** (default name `Untitled.md`; a bare name gains the extension inside the vault), **Rename** (which offers to rewrite references), and **Delete**. Paths follow the same vocabulary as the walk, and the Rust side refuses any path that would leave the vault.

In the preview, `[[wikilinks]]` render as internal links and are followed in place, through the same leave guard. Below the note, the links panel lists **Links to** (this note's outgoing mentions) and **Linked from** (backlinks), ordered with any declared weights taken into account.

**Graph** replaces the list with the vault's link structure: one node per indexed note plus one ghost per unresolved target, edges aggregated per ordered pair. The layout is deterministic; you can pan, zoom and drag nodes, and clicking a note opens it through the leave guard while clicking a ghost runs the same resolution a preview mention does. A right-click on an edge sets or clears a declared weight between 1 and 100. Weights are display-only and live in `user://link_weights.json`: they change thickness, layout stiffness and link order, never which edges exist or what a click can reach.

## Settings that matter

| Setting | What it changes |
|---|---|
| Name | the pane's title |
| Font size | 8–32 px in the editor and preview |
| Vault path | absolute directory to index and edit |
| Note view | `Edit`, `Split` or `Preview` |

## What it does not do

It does not index anything but `.md` files, and it does not show hidden files. It does not write outside the vault, and it does not store note content in the database: the index is derived and can be rebuilt. It does not treat front matter as metadata — a `---` block is text. It does not auto-save, auto-reload an outside edit, or silently apply a recovery copy.

## Limits and edge cases

A note body is capped at 1 MiB. A note that hits the cap while loading is shown read-only, because saving would replace the file with its visible prefix. The walk's 2,000-note and 16-level limits bound both the list and the index. The graph caps answers at 10,000 edges per class and 2,000 ghosts, and reports when a cap cut the answer. Graph geometry is session state — node positions are not saved — while declared weights and the open note are.

## Related

- [[pane]]
- [[vault]]
- [[wikilinks]]
- [[link-graph]]
- [[note-editor]]
- [[code-viewer]]
