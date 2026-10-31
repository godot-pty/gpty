# Note Editor

The note editor is the Wiki pane's writing half: a buffer beside a live preview, an explicit save, and a set of guards that exist because losing typed prose is worse than any inconvenience they cause. It edits notes that are already in the [[vault|vault]], and it creates, renames, and deletes them under the same path rules.

## Three modes, one buffer

Edit shows the source, Preview shows the rendered note, and Split shows both; Split is the default. The preview renders the *buffer*, not the file, so unsaved work is what you see as you type. Rendering settles rather than running per keystroke — a full render of a large note is real work, and queueing one per character would spend it on text nobody has paused to read. Switching modes and opening a note render immediately, because those are explicit acts.

The preview is the same sanitized Markdown pipeline used elsewhere: raw HTML and BBCode are escaped, images reduce to alt text, and only http, https, and mailto links become metadata. [[wikilinks|Wikilinks]] are the exception the wiki adds: the renderer reuses the index's own parser, so the mentions that become clickable are exactly the occurrences that became edges. A note read past the 1 MiB cap shows a truncation banner above the body, saying so rather than stopping silently.

## Saving is explicit

The Save button and `Ctrl+S` do the same thing: write the buffer to the file. There is no autosave to the vault. Unsaved changes show as a marker next to the note, and Save is disabled while there are none.

Leaving a dirty note asks first, with Save / Discard / Cancel. The same question guards more than Back: following a mention, opening a node from the graph, closing the pane (titlebar, sidebar, `Ctrl+Shift+W`), changing the pane type, resetting the workspace, activating a profile, closing a workspace, reloading layouts, and quitting the app all route through the pane's own close request. Cancel cancels the whole action, including a quit. An IPC `killPane` is the one path that cannot show a dialog: it refuses with "unsaved changes" while the buffer is dirty, rather than asking or discarding. The pane can therefore never be destroyed around a buffer it did not get an answer for.

## Recovery copies

Because the vault write only happens on an explicit save, a crash or an outside kill would take everything typed since. The editor therefore snapshots a dirty buffer as a *recovery copy* outside the vault, under `state_dir()/scratch`, with the directory created owner-only on first use. It is not a note write and never touches the vault.

The snapshot is throttled to at most once every 1.5 seconds while the buffer stays dirty. That is a throttle, not a per-keystroke debounce: a debounce that restarts on every keystroke never fires during a long typing run, which is precisely when the most work is at risk. At most about a second and a half of typing can be lost.

Reopening the same note — same vault, same path — offers the copy: Restore puts the buffer back, dirty, still carrying the stamp of the file revision it was typed against, so a later save still checks the file the user saw; Discard drops it. It is never applied on its own. The copy is dropped the moment the buffer reaches the file or the user discards it. Each write also prunes records whose vault is definitively gone, erring toward keeping a vault that is merely unreadable.

## Writing safely

A save is atomic: a hidden random sibling temp file is written, then renamed over the target, keeping the note's own mode. A reader either sees the old file or the new one.

A save also carries a stamp — the `(mtime, size)` the buffer was loaded from. If the file changed on disk since then, the write is refused with `changed_on_disk` and the pane offers an explicit overwrite instead of quietly discarding someone else's edit. Forcing the save accepts that. The pane's own saves refresh the stamp, so consecutive saves do not trip it.

Line endings are preserved: the editor works in LF, and a CRLF note is converted back on the way out, byte for byte for everything else. A CRLF note opens clean, because dirty is measured in the editor's own space.

The 1 MiB read cap makes a larger note read-only. The pane says why ("Read-only — larger than 1 MiB") rather than pretending the truncated prefix is the whole file.

## The note verbs

New note asks for a path, starting at `Untitled.md`; a name whose last component has no extension gains `.md`, and any other extension is left as typed so the vault can refuse it. Create claims the destination with `create_new`, so an existing note answers "exists" and is never replaced. The directory must already exist inside the vault — the editor never creates folders and never writes through a directory symlinked out of it. Paths follow the walk's vocabulary: relative, ordinary components, none hidden, ending in `.md`, at most 1,024 bytes, with `..` unrepresentable. Save is contained too: a symlink pointing at a sibling note is written through, one pointing out of the vault is refused. Opening follows the same rule as saving: a note whose link resolves outside the vault answers `outside_vault` instead of another file's text.

Rename offers to update references after the move: "N mention(s) in M note(s) still name old — update them?" Nothing is written unless you answer Update, and the pass touches only occurrences that resolved to the old name, preserving aliases and fragments. Delete asks for confirmation, then acts on the vault entry: a symlinked note is unlinked as a link, its target untouched.

## Related

- [[vault]]
- [[wikilinks]]
- [[wiki-pane]]
- [[keyboard-shortcuts]]
