# Vault

A vault is an ordinary directory of Markdown notes that gPTY lists, searches, and edits. Nothing in the directory belongs to gPTY: the files are yours, and everything the app derives from them lives somewhere else.

## A directory, not a file format

Point the [[wiki-pane|Wiki pane]] at any absolute directory and gPTY treats the `.md` files inside it as notes. Subfolders are part of the vault, and other file types are simply not notes. There is no manifest to keep in sync, no database inside the vault, and no required front matter. A vault made in Obsidian opens as-is, and a vault made here opens in Obsidian.

That compatibility is deliberate. The index, the search table, and the link edges are all derived data; the notes alone are the source of truth. Copy the directory to another machine and the wiki is intact. Delete gPTY entirely and the folder still reads as plain Markdown.

## The index lives outside the vault

The note list, search hits, wikilink edges, and the [[link-graph|link graph]] all come from one SQLite store at `state_dir()/vaults.db`. `state_dir()` is gPTY's own private state directory, never the vault, which has three consequences worth knowing:

- Copying or syncing the vault moves your notes and nothing else. The index is rebuilt locally.
- Deleting the store loses nothing. The next index pass re-reads the files and recreates every derived row.
- The control socket and the CLI can reach the store without resolving Godot's `user://` paths, which is why an agent can search a vault with no pane open.

## What the walk calls a note

Every listing and every search starts with a walk of the directory. Its rules are fixed, and they are the same rules the pane's list, the editor, and the graph obey.

| Rule | Value |
|---|---|
| Hidden entries | skipped at every level (`.obsidian`, `.git`, `.trash`) |
| Links out of the vault | skipped and counted (`outside`); a link that stays inside is followed |
| Extension | `.md` as the last path component |
| Order | sorted per directory (plain entries before symlinks), then by relative path |
| Notes per walk | 2,000, then `truncated` is set |
| Depth | 16 directory levels |
| Unreadable entry | skipped; the rest of the vault still lists |
| Path length | 1,024 bytes |
| Body read | 1 MiB, a torn UTF-8 tail dropped |

The walk is best-effort on purpose: a vault is user data, and one unreadable subdirectory does not hide the rest of it. A symlink is followed only when it resolves inside the vault — the same rule a read and a save enforce — so a link to `~/.ssh` or a project tree is skipped, never indexed, and the pane's footer says how many were skipped. A link that stays inside the vault works, and a directory already reached is not walked twice: loops stop at the canonical path rather than at the depth cap.

The count cap has a subtler rule attached. Notes are dropped from the index only when a walk was complete; a truncated walk can add and refresh notes but never concludes that anything vanished, because the files it did not reach are still real.

## Titles and search

A note's title is what the list and the search results show. gPTY takes the first heading past a closed YAML front matter block; if there is no heading, it uses the file stem. Titles are capped at 200 characters. An unterminated `---` is not front matter and is treated as ordinary text.

Search is SQLite FTS5 with the `porter unicode61` tokenizer over title and body. Porter stemming suits prose, where "saving", "saved", and "save" should find each other. What you type is not an FTS5 query: free text is first sanitised into quoted, ANDed terms, so an ordinary search such as `main.rs` works instead of being rejected by the query parser. Hits come back best-rank-first with a body snippet; the API accepts 1–500, and the pane's search box asks for 200.

Indexing is incremental. Only notes whose modification time or size changed are re-read, and saving a note re-indexes the vault before the call returns. An edit made outside gPTY — in an editor, in Obsidian, by another agent — is picked up by the next query because a search indexes changed notes first.

A note is read and stored at the same 1 MiB cap. That shared cut is not cosmetic: if the index stored more than the viewer shows, a search hit could match text you can never see. A larger note still opens, but read-only.

## Reaching a vault from outside the pane

The absolute vault path is the only handle needed. The CLI and the MCP server expose the same operations over the control socket:

```bash
gpty vault search ~/notes "atomic save" --limit 20
gpty vault read ~/notes wiki/vault.md
```

Search answers `{results, total, truncated}` and read answers the note document `{path, text, truncated, crlf, mtime, size}`. The MCP tools are `vault-search`, `vault-read`, and `vault-weight`; the two reads are answered natively by the Rust side off the GUI thread, because a vault is a directory rather than workspace state. Curating link weights is the exception — `gpty vault weight <vault> <src> <target> --weight N` goes to the running GUI, because the store belongs to it, as [[declared-link-weights|Declared Link Weights]] explains. The full method surface is in [[control-api|Control API]].

## Why plain files are the point

Every feature in this cluster is disposable on top of the files. [[wikilinks|Wikilinks]] are text spans in the notes; the edges they produce are index rows. The graph is a query. The weights are a separate user-owned JSON file. Remove gPTY and you have a folder of Markdown that any other tool can read — which is also why a note you do not touch is a note gPTY cannot break.

## Related

- [[index]]
- [[wikilinks]]
- [[link-graph]]
- [[note-editor]]
- [[wiki-pane]]
