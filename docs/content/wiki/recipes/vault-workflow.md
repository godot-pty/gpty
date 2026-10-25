# Vault Workflow

A vault is just a directory of Markdown files. This walks one from empty pane to a graph an agent can query: open it, write, link, read backlinks, search, curate, rename, recover, and hand it to an agent.

## Point the pane at a directory

1. Open a Wiki pane — `Ctrl+Shift+P` and search for the Wiki pane, or `gpty new-pane -t wiki`.
2. Open the pane's settings popup and fill in **Vault path** with an absolute directory. In this repository that is `/path/to/gpty/docs/content/wiki`.
3. Wait for the list to fill.

The pane walks the directory recursively for `.md` files, skipping hidden entries at every level, up to 2,000 notes. If it hits that cap, a footer says the listing stopped rather than pretending the vault is smaller than it is.

Expected result: the note list shows every note by vault-relative path. If it stays empty, the path is wrong, not absolute, or contains no Markdown — the pane does not search parent directories for you.

The index lives in gPTY's own state directory, never inside your vault, so pointing a pane at a git checkout writes nothing into it.

## Write a note and link it

1. Press **New note**. The pane creates `Untitled.md` at the vault root; a bare name you type instead gains the `.md` suffix. The directory must already exist inside the vault.
2. Write in the editor. The toolbar switches between **Edit** (source only), **Split** (source and live preview) and **Preview** (rendered only); Split is what makes the preview update as you type.
3. Link another note with a wikilink target such as `[[getting-started]]`, a labelled one such as `[[pane|the pane note]]`, or a heading one such as `[[vault#Titles and search]]`.
4. Save with **Save** or `Ctrl+S`. The dirty marker (`● Unsaved changes`) clears.

Expected result: the note appears in the list immediately, and the preview turns your wikilink into a link you can click.

If you try to leave — switch notes, close the pane — a guard offers Save, Discard or Cancel. There is no autosave: a note is on disk only after an explicit save.

## Read the links back

1. Click a rendered wikilink. The target opens in place, behind the same leave guard.
2. Open the note's link panel: **Links to** lists this note's mentions, **Backlinks** lists the notes that mention this one, and unresolved mentions show with their candidates so you can tell a missing note from a mis-typed target.
3. Press **Graph** to draw the vault. Nodes are indexed notes plus one ghost per unresolved target; edges aggregate mentions between a pair.
4. Click a node to open it, or click a ghost to create the note it names.

Expected result: the panel and the graph agree, because both read the same index rows. A long mention list ends with a footer like `… 3 more mention(s) not shown`, which is truncation in the panel, not in the index.

If a link looks dead, it is: a target resolves by exact case first, then by a unique case-insensitive match, and an ambiguous match is never silently picked. Backslashed or fenced occurrences are literal text and create no edge.

## Search

1. Type into the **Search notes** field. The list is replaced by hits as you type.
2. Read a hit to jump to the note.

Search is full-text over the vault, with stemming — `owning` finds `ownership` — and terms are ANDed, so more words narrow the result. To search the same vault from a shell or an agent:

```bash
gpty vault search /path/to/gpty/docs/content/wiki "vault"
```

The answer carries `results`, `total` and `truncated`. A `truncated: true` means the walk hit its note cap, so the answer is partial.

## Curate a link's weight

1. Right-click an edge in the graph to set a weight (1–100) or clear it, or from a shell: `gpty vault weight /path/to/gpty/docs/content/wiki wiki/vault.md wiki/wikilinks.md --weight 40`.
2. Press Relayout or reopen the graph to see the edge thicken and the pair settle closer together.

A declared weight is 1–100 and display-only: it overrides the measured mention count for edge thickness, layout stiffness and link-panel order. It never hides an edge, never gates navigation and never writes to the vault. The store is the running GUI's, so the command needs a live workspace and will not start one.

## Rename without breaking links

1. Open the note and press **Rename**.
2. Enter the new vault-relative path.
3. Accept the prompt that reports how many mentions in how many notes still name the old target.

Expected result: the file moves and the references are rewritten. If you decline, the rename still happens and those links simply stop resolving — which is what the prompt is warning about. Renames never follow a symlink out of the vault.

## Recover an unsaved buffer

1. If gPTY closes with a dirty buffer, the next time you open that note you are asked: *had unsaved changes when gpty last closed. Restore them?*
2. Choose Restore to load the buffer, or decline to read the file on disk.

Recovery copies are kept outside the vault, are never applied automatically, and are written on a throttle rather than on every keystroke. There is a second guard for the other direction: if the file changed on disk while you had it open, saving asks before overwriting your version.

## Expose the vault to an agent

1. Note the absolute vault path — an agent needs the same one you typed into the pane.
2. Give the agent read access with the two read-only commands:

```bash
gpty vault search /path/to/gpty/docs/content/wiki "link graph" --limit 20
gpty vault read /path/to/gpty/docs/content/wiki wiki/link-graph.md
```

Search re-indexes notes whose modification time or size changed before answering, so a note edited outside gPTY is visible to the next search without reopening the pane. `read` returns `path`, `text`, `truncated`, `crlf`, `mtime` and `size`.

Expected result: the search returns ranked hits with vault-relative paths, and read returns the note body.

Neither command writes to the vault, and a miss is an error with a stable code (`not_found`, `bad_path`) rather than an empty success. A read is capped at the same 1 MiB display limit as the editor, and `truncated` says so; a note larger than that opens read-only in the pane as well.

## Related

- [[vault]]
- [[wiki-pane]]
- [[wikilinks]]
- [[link-graph]]
- [[note-editor]]
- [[declared-link-weights]]
