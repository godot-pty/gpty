---
title: "Roadmap details - WIKI"
weight: 900
build:
  list: never
---

Every WIKI row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## WIKI-1

**Safe Markdown rendering** - CommonMark/GFM converted to sanitized Godot BBCode in Rust;
render-debounced streams; code-viewer rendered/source toggle

Commits: d17bac7

## WIKI-2

**Wiki pane type** - `wiki` in `PaneTypes.ALL`; opens a vault at an absolute directory path
validated by `sanitize_tile` (same trust rule as code_viewer/file_tree). **Closed:** `wiki` is
registered on both sides of the vocabulary seam - `PaneType` (variant, `as_str`, `FromStr`,
`ALL: [PaneType; 7]`) and `PaneTypes.ALL` (appended last in both, the order the key-for-key seam
test enforces), plus the `_PaneScripts` body map - so every derived surface carries it with no
second list: the sidebar button, the palette's `new wiki`, `gpty new-pane -t wiki`, the swap menu,
`W<n>` labels, and the plugin-manifest tile validator. The new `WikiPane` body opens a vault at an
absolute directory path validated at use (`is_absolute_path` + `DirAccess.dir_exists_absolute`,
`file_tree`'s rule; `sanitize_tile` is unchanged - the item's 'validated by sanitize_tile' is the
same tile gate every type passes, and a file-supplied path is never trusted), lists the vault's
`.md` notes recursively (hidden entries skipped, bounded at 2000 entries / depth 16), and renders a
note read-only through the sanitized `MarkdownView`; the read guard is shared with code_viewer as
`TextRead.read_prefix` (regular-file gate, 1 MiB cap, torn-UTF8-safe decode) rather than copied.
Verified: `test_wiki_pane.gd` 9/9 (recursive scan, hidden skip, depth cap, entry cap + `truncated`,
invalid-vault refusal, note render + back, layout-state round trip), the file-sink suite passing
through the extracted guard, both Rust seam tests, and the full `ci-check` (49 GUT scripts / 513
tests; the smoke's new `wiki` step shows `new-pane -t wiki` reporting type `wiki` live).

Commits: d17bac7

## WIKI-3

**Vault model** - local-first directory of plain Markdown files (potentially Obsidian-compatible:
`.md` on disk, no proprietary format), indexed with full-text search in SQLite FTS5 (reuses the
v0.5.1 history engine). **Closed:** a new `gpty_core::vault` store (SQLite + FTS5 at
`state_dir()/vaults.db` - never inside the vault, which stays plain `.md` files the app only reads)
is the one definition of what a note is: the walk (`scan_vault`: hidden entries skipped at every
level, `.md` only, `MAX_NOTES` 2000 / `MAX_DEPTH` 16, sorted) and the 1 MiB body cut with the torn
UTF-8 tail dropped, the same cut `TextRead` makes on the display path. The wiki pane's list and its
debounced search box both come from it, through the *static*
`GptyTerminal.vault_index`/`vault_search` (JSON envelopes; `error` reserved for "the query could not
run", so "no match" stays distinguishable from "not indexed"); activating a hit opens the note
through the same `TextRead` + sanitized `MarkdownView` path. The store reuses the v0.5.1 engine's
skeleton deliberately - WAL + `busy_timeout`, a `user_version` gate, external-content FTS5 with the
three triggers, `restrict_to_owner` on the db and its `-wal`/`-shm` siblings, the process-wide
`write_guard` held innermost across one transaction - with a `(vault_id, rel_path)` key and
`porter unicode61`, because notes are prose. A pass re-reads only notes whose mtime (nanoseconds) or
size changed, drops rows for vanished notes, prunes rows whose vault root is gone, and never prunes
from a truncated walk (the notes it did not reach would be deleted). Verified: 14 `vault` unit tests
(schema idempotence, owner-only mode, vault-scoped and porter-stemmed search, the punctuation-only
query, the hidden/depth/entry walk rules, added/updated/removed staleness, the truncated-walk
no-prune rule, the torn-tail read, title extraction), `test_wiki_pane.gd` 9/9, `test_gdext_ffi.gd`
6/6 (the JSON contract, including the error envelope), `test_layout_restore.gd` 13/13, and
`ci-check` green.

Commits: d17bac7

## WIKI-4

**Markdown editor & preview** - edit notes with live preview through the existing sanitized
Markdown→BBCode pipeline (v0.4.0); source/rendered toggle like code_viewer. **Closed:** the note
view is an editor - a `CodeEdit` beside the existing `MarkdownView` in a split container, with three
modes (`edit` / `split` / `preview`, split by default, persisted as the tile's `view_mode` and
exposed as a "Note view" pane-settings row) - and the preview is fed from the *buffer* on every edit
(coalesced by MarkdownView's own 75 ms timer), so Preview shows unsaved work, not the file. Saving
is explicit: a Save button and Ctrl+S, a dirty marker, Save disabled while clean, a first-ask before
leaving a dirty note (Back) or changing the vault, and Back re-walks the vault so the list reflects
the edit. The write path is one new pair of static FFI functions over `gpty_core::vault`, the module
that already owns the note vocabulary: `vault_note_read` (the index's 1 MiB cut, the walk's path
rules, a regular-file gate - a FIFO in a vault must not reach `File::open` from the GUI thread -
plus the file's CRLF flag and a (mtime, size) **stamp in microseconds**, because nanoseconds lose
their low bits in JSON's double) and `vault_note_write` (the same rules; the canonicalized path must
stay under the vault root, so a symlink out of the vault is refused and one to a sibling note is
written through; content ≤ `MAX_NOTE_BYTES`; a stamp that differs from the loaded one answers
`code: "changed_on_disk"`, which the pane turns into an explicit overwrite confirmation; the
replacement is a hidden random-named sibling temp renamed over the target, keeping the note's own
mode; a successful write re-indexes the vault before answering, so the edit is searchable at once -
`indexed: false` when the save landed but the index could not). A note read truncated stays
read-only ("Read-only - larger than 1 MiB"): saving a prefix would drop the rest. CRLF endings
survive an edit. Refusals the caller asked about are not logged; only `Outside`/`Io` are
diagnostics. Verified by 9 Rust tests (path vocabulary, stamp conflict, both symlink directions,
mode preservation, cap, CRLF/truncation flags), 11 new GUT cases in `test_wiki_pane.gd` (open/save,
live preview, modes, both guards, re-index-then-search, read-only past the cap, CRLF round trip,
vault change, layout state) and the wire shapes in `test_gdext_ffi.gd`. One seam lesson, now in
AGENTS.md: a programmatic `CodeEdit.text` assignment emits `text_set` only - `text_changed` is for
edits and arrives deferred - so the pane recomputes dirty state from the buffer and tests type
through `insert_text_at_caret`.

Commits: d17bac7

## WIKI-5

**Closing a pane or quitting the app loses unsaved wiki edits** - the editor's guards cover in-pane
navigation (Back, a vault change), but the kill paths do not: `Ctrl+Shift+W` / the sidebar kill /
IPC `killPane` and quitting the app destroy a dirty buffer with no prompt, and the pane writes
nothing on `_exit_tree` (deliberately - nothing writes without a user action). Found while building
the editor (2026-10). **Closed:** the close is a pane contract now -
`PaneBody.request_close(answer)` (the answer is async and boolean: `true` proceeds, `false` cancels)
with `PaneBody.has_unsaved_state()` as its state half - and every destruction path consults it: the
single-pane ones through `Workspace._kill` (the titlebar's X, the sidebar's close button,
`Ctrl+Shift+W`/the palette via `_kill_last`, IPC `killPane`), the type swap (`_swap_pane`, whose old
body dies), the mass ones through one walk (`_ask_close_then`: `_reset`/`_do_reset`, profile
activation `_do_activate`, `_close_workspace`, the palette's `_restore`), and quitting -
`request_quit()` is the app's only quit path now, reached from the window-manager close request
(`auto_accept_quit` is off), the titlebar's close button and the Rust shutdown flag (`daemon stop`,
a refused socket bind), walking every pane of every workspace. The ask is the editor convention -
**Save** (write, then continue), **Discard**, **Cancel** - and one answer drives the whole action:
Cancel cancels the reset/swap/close/quit, a *failed* save or a declined overwrite cancels the close
instead of proceeding over it, a pane already asking declines a second ask (dialogs cannot stack),
and an exclusive dialog is freed a frame before the next one is raised (Godot refuses two at once,
which would have stranded the answer). The Back button gained the same Save answer, and
`_save(force, answer)` now reports its outcome to its caller - without that, a failed save would
have closed the pane anyway. An IPC caller, which cannot answer a dialog, is refused instead:
`killPane` and `layoutLoad` answer an error naming the pane, the rule `layoutLoad` already applied
to untrusted profiles. Verified: 6 new wiki-pane cases (Save-then-continue, Discard-without-writing,
Cancel reported as false, conflict-again mid-close, `has_unsaved_state`, a clean pane answering at
once) plus the reworked Back guard, 11 cases in the new `test_pane_close_guard.gd` (the walk's
continue/refuse/skip-freed semantics, the quit seam - including a cancelled quit being askable again
- and the kill/kill-last/reset/swap/workspace-close funnels against a real workspace), 2 IPC
refusals in `test_ipc_dispatch_contract.gd`, and the full `ci-check` -
`gut-check: OK - 50 scripts, 545 tests` (27 unit + 23 integration scripts, the new
`test_pane_close_guard.gd` among them) and the live pane-API smoke, which drives `kill-pane`,
`layout load` and `daemon stop` through the guard. The scratch-buffer fallback for SIGKILL-class
exits is *not* part of this item and is queued below.

Commits: d17bac7

## WIKI-6

**A crash no longer takes the wiki buffer** - the close guards cover every deliberate path, but
SIGKILL/crash (or an outside kill) loses unsaved edits: nothing is written until the user saves, by
design, and the pane writes nothing on teardown. Found while closing the item above, which named a
scratch buffer as the fallback (2026-10). a *recovery copy* of the dirty buffer, owned by
`gpty_core::vault` (`write_scratch`/`read_scratch`/`clear_scratch`, behind the static
`vault_scratch_read`/`vault_scratch_write`/`vault_scratch_clear`) and living outside the vault at
`state_dir()/scratch/<fnv1a64(canonical root, NUL, rel path)>.json` - FNV-1a spelled out locally
because `DefaultHasher`'s algorithm is not promised across Rust releases and a toolchain bump would
orphan every copy - written atomically (hidden random temp, renamed over the previous copy), dir
0700 / file 0600, and carrying the identity it was written for (`vault`, `path`, `mtime`, `size`,
`text`): a record that names another vault or note, or cannot be parsed, answers *absent*, so a
stale file or a hash collision can never restore the wrong text. The pane snapshots from a
**throttle** armed by the first dirty edit (`SCRATCH_DEBOUNCE`, deliberately not restarted per
keystroke - a restarted debounce never fires during a long typing run, which is exactly when the
most work is at risk) and drops the copy on every *deliberate* end: a save, the Discard answer of
the close ask, and the settings panel's vault change (keyed to the vault the buffer belonged to).
Reopening the note asks - Restore / Discard / Escape = not now - and never applies anything on its
own; the restored buffer carries the stamp it was *typed against*, so a file that moved on while
gpty was away still gets the existing `changed_on_disk` overwrite question instead of a silent
overwrite. A note read-only for being past the 1 MiB cap is never offered a restore (a restored
buffer could not be saved and the close guard would not see it as unsaved work - the copy is kept
instead), and `_save` remains the only write that reaches a vault. A buffer past `MAX_NOTE_BYTES`
gets no copy on purpose: the same module refuses its *save* by that limit, so the two say one thing
instead of promising a recovery nothing could write back. Verified: 5 Rust unit tests (round trip +
idempotent clear, key isolation across vaults and notes, identity/stamp/malformed-record guards, the
walk's path vocabulary + size cap, dir 0700 / file 0600) and 10 GUT tests in `test_wiki_pane.gd` (a
clean note writes nothing, a dirty one snapshots the exact buffer with its stamp, the throttle is
not restarted by a later keystroke, save / discard / vault change drop it, the crash → reopen →
Restore → save chain, a decided copy never returns, a moved-on file still asks, a read-only note is
not offered and keeps its copy, CRLF) plus the scratch wire shapes (absent vs found vs error
envelopes, the caller's stamp coming back, idempotent clear) in `test_gdext_ffi.gd`. One product
defect fell out of the blast radius and is fixed with it: **a CRLF note opened already dirty**
(`_saved_text` held the file's CRLF text while the editor works in LF, so Save was lit for an edit
nobody made and - with the copy in place - a snapshot of the file itself would have been offered
back as a recovered edit); `test_a_crlf_note_opens_clean` pins the fix. The tests hit the known
exclusive-child rule the hard way (a `queue_free`d dialog is still registered for the rest of the
frame, so the next exclusive popup is refused): they await a frame before counting dialogs, the same
lesson `_save_after_dialog` already documents.

Commits: d17bac7

## WIKI-7

**Recovery copies are never pruned** - a copy is only ever read, offered or cleared through the key
of the note being opened, so one whose vault directory (or note) went away is unreachable forever:
`state_dir()/scratch` keeps every orphan a crash produced. Cheap and content-free today (a copy
exists only while a buffer is dirty, and it is a few hundred bytes), but nothing reclaims the files,
and a vault that is moved or renamed orphans one per unsaved note. Found 2026-10 while closing the
item above. Fix direction: a prune alongside the write - the record already names its vault root and
note, so a copy whose vault is not a directory can be dropped - held to the index's discipline:
prune only from a *complete* walk of the small scratch directory, never delete a copy whose vault
still exists (it may be temporarily unreadable), and never touch a copy whose note merely was not
listed, because a truncated walk would delete exactly the work this feature exists to keep.
`prune_scratch` is the first step of `write_scratch`, so the prune rides the pane's 1.5 s throttle -
one short directory listing, each record read to be judged, a few times a minute at most over a
directory that holds one file per dirty note, and it runs *before* the copy is located so even a
write refused for a vault that is no longer a directory tidies the directory. The deletion rule is
the item's discipline made concrete: a copy goes only when its own record names a vault the
filesystem answers **definitively** gone for - `metadata` says `NotFound`, or says the path is not a
directory - while a permission error, an unmounted network path, or any other I/O error answers
"cannot judge" and the copy is kept, and a copy whose *note* is missing is kept too, because nothing
on this path walks a vault at all (a truncated walk cannot reach the prune's verdict, which is
stronger than checking the note's absence would have been). A record that cannot be read or parsed,
one that never names a vault, one whose vault is not absolute (ours always is - `scratch_location`
canonicalizes), and any name the module did not build (`<16 hex>.json` /
`.gpty-scratch-<16 hex>.tmp` are the only shapes it claims) are all left where they are: a deletion
needs a record that says "unreachable", never one the code could not interpret. The same pass
reclaims the `.gpty-scratch-*.tmp` remains of a write that died between its temp write and its
rename, once older than an hour - a live temp file exists for microseconds, so no writer can lose
one to the age check - because those are the same leak from the same directory. Every prune failure
is a logged diagnostic; housekeeping never fails the write it rides on. Verified: 5 new
`gpty-core::vault` tests - the two orphan shapes reclaimed (vault directory removed; vault path
replaced by a file) while a live vault's copy and its text survive, a note deleted out of a live
vault keeping its copy, foreign / unparseable / vault-less / relative-vault records kept, a stale
temp reclaimed with a fresh one kept, and a `#[cfg(unix)]` case where the vault's parent is
unreadable (kept on root and non-root alike - the metadata call either fails with EACCES or succeeds
and sees a directory) - plus `cargo test --workspace` (445 tests, 0 failed) and the full `ci-check`:
`gut-check: OK - 50 scripts, 558 tests, all passed`, the live pane-API smoke, and cargo audit. The
GUT and smoke steps ran with a sandboxed `XDG_RUNTIME_DIR` because a GUI was live - the collision is
the queued item below, and this run is one more data point for it.

Commits: d17bac7

## WIKI-8

**The Markdown preview no longer stops at a cap of its own** - `crates/gpty-gdext/src/markdown.rs`
cut its input at `MAX_MARKDOWN_BYTES` (512 KiB) and rendered the rest not at all, with nothing said:
a 900 KiB note rendered half of itself with no notice, and the wiki pane's own truncation notice
(appended *after* the body) could never be seen for a note past the cap it announces - which is
exactly the case it exists for. `code_viewer` showed the same thing for a large `.md`. Found while
testing the editor (2026-10). the cap is the read cap - `MAX_MARKDOWN_BYTES` =
`TextRead.DEFAULT_MAX_BYTES` = `gpty_core::vault::MAX_NOTE_BYTES` (1 MiB), one number, so a document
at a pane's read cap renders whole - and it cannot drift again:
`the_input_cap_is_the_read_cap_the_panes_apply` (a Rust test in `markdown.rs`) `include_str!`s
`godot/scenes/panes/text_read.gd`, reads the `DEFAULT_MAX_BYTES` declaration and fails if it stops
agreeing with either the render cap or the note cap, the same cross-language seam check
`pane_types_match_the_gui_registry_key_for_key` uses. The cut now travels with the text: the render
answer is JSON, `{text, truncated, shown, size}` - the shape a read answers
(`TextRead.read_prefix`), so a caller gets the numbers rather than having to compute UTF-8 byte
lengths in GDScript - and `MarkdownView` is the single place a reader is told, as one banner
**above** the body: the renderer's own numbers when *its* cap bit (a pasted buffer, a routed
capture, a long model turn - sources no read capped), and `set_source_notice` for a cut the caller
made. The panes stopped appending a notice to the source: a note at the read cap is at the render
cap too, so the appended notice was the first thing the cut dropped, and the wiki pane's preview now
hands the notice to the view while the text views keep their own at the end of the text they hold
(`TextRead.truncation_notice` is a bare sentence the caller places). Costs measured before raising
the cap (a `probe_render_cost` Rust test stayed behind, and the GUI-thread numbers are in the cap's
doc comment): the Rust render is ~30 / 55 / 107 ms debug (~5 / 9 / 14 ms release) for 256 KiB / 512
KiB / 1 MiB, linear, and the render is not the whole cost of showing a document - the label's own
BBCode parse and shape is, which is why the follow-up below exists rather than a smaller cap.
Verified: 3 new Rust tests (at-cap whole / past-cap reported / UTF-8-safe cut) + the seam test + the
probe, `test_markdown_renderer_formats_and_sanitizes` rewritten for the envelope and the cap, 2 new
GUT cases (`test_a_capture_over_the_render_cap_says_what_it_is_not_showing` for the renderer's cut
on a routed capture, `test_a_markdown_file_past_the_cap_announces_the_cut_in_the_rendered_view` for
the read cut in a rendered `.md`), the wiki read-only case extended to assert the banner sits before
the body, and the full `ci-check` - `gut-check: OK - 50 scripts, 558 tests`.

Commits: d17bac7

## WIKI-9

**A live preview of a large note pays its whole render per keystroke burst** - measured 2026-10
while aligning the render cap: `MarkdownView.render_now` plus the label's own BBCode parse is ~74 /
157 / 336 ms for 256 KiB / 512 KiB / 1 MiB of Markdown in the debug build the harness runs (the Rust
render is ~30 / 55 / 107 ms of that, the rest is `RichTextLabel`), and a pane in split/preview mode
re-renders through the 75 ms coalescing timer after every edit burst - so a note near the cap
stutters while it is being typed. Nothing is hidden any more (that was the item above) and `edit`
mode renders nothing, so this is smoothness, not correctness. Fix direction: measure a release build
first - the debug numbers above are a ceiling, and the shipped artifact is what a user types into -
and if it still hurts, render on settle/idle rather than on the coalescing timer, or let a document
past a threshold declare its preview stale until asked (a "preview paused - render" state). Not by
lowering the render cap again: that is the silent-prefix bug this release just closed. measuring the
*release* build with the new `godot/tests/bench/markdown_bench.gd` harness found the item's cost
model was missing its dominant term - the **shape** pass, the frame after the text lands. It was
also superlinear, and the cause was this renderer's own output: Godot lays a `[ul]`/`[ol]` list out
superlinearly in the item count, and the unit the item was measured with is list-dense. Measured on
the Godot 4.7.2 binary (headless, ~1.7 MiB of rendered BBCode): two-item lists **38915 ms**, a real
1 MiB note **146705 ms**, against **819 ms** for that same rendered text with the list tags stripped
and 0.5–1.3 s for every other construct (headings, quotes, inline code, links, tables) - so a 256
KiB note in split mode froze for 2.7 s per update and a 1 MiB one for 2.4 *minutes*, which is not a
stutter but a hang. Two changes, both measured: (1) the renderer emits **no list tags** - each item
is a `• `/`N. ` line inside one `[indent]` per list (a nested list opens its own), which renders
identically (screenshot-verified against the tag form at the same width, fonts and wrapping) and
makes the shape linear: 250 / 473 / 948 ms (debug) and 261 / 486 / 973 ms (release) for 256 KiB /
512 KiB / 1 MiB, with the numbering now the renderer's own - which is also how a list starting at 3
renders `3.` instead of `1.`, since `[ol]` cannot carry a start; (2) the wiki pane's preview renders
on **settle** - `MarkdownView.set_markdown_settled` restarts its timer per edit (`settle_delay` 0.4
s) so a typing run queues no render at all and one lands when the user stops, while `set_markdown`'s
non-restarting throttle stays for streams (Reasoning, Inspector) and `render_now` for explicit acts
(open, mode switch, save). The item's second option (a stale-until-asked preview) was not needed
once the superlinear term was gone, and the closure's numbers are the evidence a later decision
would use. Verified: 2 rewritten/added `markdown.rs` tests (bullets and our own numbers, nested
indent; the `[ol]`-pin test replaced), 1 new and 1 adapted GUT case
(`test_a_settled_preview_waits_for_the_typing_to_stop` pins the restart semantics: a render inside
the window is exactly what a throttle did), `gut-check: OK - 50 scripts, 559 tests, all passed`, and
the full `ci-check`. Total per preview update in the shipped release build: 0.32 / 0.55 / 1.10 s for
256 KiB / 512 KiB / 1 MiB, linear.

Commits: d17bac7

## WIKI-10

**A note with frontmatter loses its title in search results** - `vault::note_title` takes the *first
non-empty line*: a heading there becomes the note's title, anything else falls back to the filename
stem, and a YAML block's opening `---` is "anything else" - so an Obsidian-shaped note (`---` /
`title: …` / `---` / `# Real heading`) is labelled and ranked by its stem in every `vault_search`
hit, even though the body (frontmatter included) is indexed and searchable and the note itself
renders. The block also renders as ordinary Markdown - there is no properties UI. Found 2026-10
while comparing the wiki to Obsidian's vault format. Fix direction: skip a leading `---`…`---`/`...`
block before scanning for the heading (a small change in `note_title` with tests), and - if
Properties are ever wanted - honour a `title:` key from that block, which is a line lookup rather
than a YAML dependency; whether the block is hidden, dimmed, or shown as properties is a renderer
decision that belongs with it. `note_title` now scans past a leading, *closed* YAML frontmatter
block. The helper (`without_frontmatter(body) -> &str`) requires the file's **first** line to be
exactly `---` (trailing whitespace and a CRLF `\r` allowed) and the block to end at the next `---`
or `...` line; every other shape - an unterminated `---`, a leading blank line, a first line that is
not the delimiter - returns the body whole, so the pre-existing scan runs unchanged and a note that
has no frontmatter cannot read differently than before. The scan's own rule is untouched (first `#`
heading, else the stem), which is what puts the observed Obsidian shape (`---` / `title: …` / `---`
/ `# Real heading`) back on its heading for both halves of the hit: the label the pane renders
(`title - snippet`) and the `notes_fts` title column `bm25` weights. **No `title:` key is read** -
the item conditioned that on a Properties feature, none exists, and a label rule should not grow a
frontmatter parser - and the block stays ordinary visible Markdown inside the indexed body, so a
property's value is still searchable (pinned). One consequence recorded rather than hidden: a
heading *inside* the skipped block is the block's, not the note's, which is the reading that makes
the convention work at all. Verified: `a_frontmatter_block_is_not_the_title` (7 cases - the observed
shape; a `...` close with CRLF delimiters; a heading inside the block; no heading after a closed
block → stem; unterminated → the old behaviour; a non-delimiter first line; a leading blank line)
and `a_frontmatter_note_is_found_and_labelled_by_its_heading` (a real `index_vault` pass, then
`search_user_text` asserting the hit's `title` and that the properties text is still indexed) -
`gpty-core`'s 34 `vault` tests (2 new), the full `ci-check` green,
`gut-check: OK - 50 scripts, 559 tests` (no GDScript changed), and the live pane-API smoke.

Commits: d17bac7

## WIKI-11

**Wikilinks & backlinks - the pane half** - the data half landed 2026-10 (the record is at the end
of this item), so what remains is the wiki pane's view of it: a backlink panel that lists each
mention with the line it was written on (`vault_links` already answers `src`/`line`), the
unresolved-target display (each entry carries the `candidates` an ambiguous stem could not choose
between), and following a link **in place** behind the existing Save/Discard/Cancel guard - no
history stack in v1 (the notes list is the escape). Rendering a mention's alias, or following a
fragment, stays a presentation decision for that half; the store keeps the edge only.
`[[note-name]]` linking, per-note backlink panel, unresolved-link detection. **Data half (settled
2026-10):** links are parsed in the index pass and stored in `vaults.db`, never derived on the fly
from the vault - the pass already reads every changed note's body to fill `body`/`title`, so a link
parse there is ~free, sits in the same transaction as the note row, and cannot drift from the text
the FTS index holds; "a link changed" is exactly the note's existing `(mtime, size)` staleness
trigger, so there is no separate link-writer and no per-link CRUD path. Schema: a
`links(vault_id, src, target, resolved NULL, seq)` table beside `notes`, indexed on
`(vault_id, resolved)` for the backlink query, with the bump handled by *rebuilding* the derived
tables (`user_version` 1→2) rather than migrating - the vault is the source of truth, the store is a
cache. Unresolved-link detection is then `resolved IS NULL`, and the graph canvas above queries the
same table, so the two features share one definition of what a link is. **Settled 2026-10 (owner):**
a bare `[[name]]` resolves by stem first and by relative path when the target contains `/`; a stem
shared by two notes is **never** silently picked - the link stays unresolved with a hint naming both
candidates (the autocomplete, when it exists, always writes a path for an ambiguous stem); matching
is exact-case first, then a *unique* case-insensitive match, else ambiguous (correct on a
case-sensitive filesystem without breaking `[[Note]]` on Windows/macOS); `[[target\|alias]]` ships
in v1 with the alias as the display label; `[[target#heading]]` parses in v1 with the fragment
dropped - the edge is to the note, and following a heading is a later half; caps are 512 occurrences
per note and 1024 bytes per target under the standard `regex` crate (worst case ≈1M rows at the
2000-note cap); following a link navigates **in place** behind the existing Save/Discard/Cancel
guard, with no history stack in v1 (the notes list is the escape). **Multi-edges and parse rules
(settled 2026-10):** a *backlink is not syntax* - it is the same edge read in reverse
(`WHERE resolved = ?`), so nothing is authored twice and there is no second thing to parse. One row
per **occurrence**, not per pair: `links(vault_id, src, seq, line, target, resolved)` with primary
key `(vault_id, src, seq)`, so a note mentioning `[[B]]` three times has three rows, the backlink
panel lists each mention with its line, and the graph aggregates them into one edge carrying the
count. Links are parsed per *line*, which gives the occurrence's line while the body is already in
memory. Many-to-many is then free (a note links many targets, a target is linked from many notes,
self-links included). Not every `[[…]]` is an edge: a code span or fenced code block is literal text
- a note documenting the syntax must not create edges - so the parser skips them, and an escaped
`\[\[…\]\]` is literal too. An alias (`\|…`) is display-only and a `#fragment` belongs to
navigation; the edge is to the note. `resolved` is *derived*, so it must be maintained when the note
set moves: recomputed for a changed note's rows at parse time, and cleared in one UPDATE for rows
whose target note disappeared (the same path a future rename needs) - an edge left pointing at a
deleted note is the trap of a derived-edge store. **Landed (data half, 2026-10):**
`gpty_core::links` holds the parser and the resolver as pure functions (a fenced block, an inline
code span and a backslash-escaped opener are literal text; 512 occurrences per note, 1024 bytes per
target; `alias`/`fragment` parsed but never stored), and `VaultStore` owns when they run: the
`links` table (`(vault_id, src, seq)` primary key, indexed on `(vault_id, resolved)`) is written in
the same transaction as the note row it came from, `reresolve_links` re-derives the vault's edges
when the note set actually moves (`added`/`removed`) - a stub that appears resolves its linkers, a
vanished target loses its resolution, a stem that is now shared stops resolving - a removed note's
rows are deleted with it, `clear_vault`/`prune_dead_vaults` drop a vault's links, and the
`user_version=2` bump rebuilds the derived tables instead of migrating them (a v1 store's notes were
never link-parsed). `GptyTerminal.vault_links(vault, note)` answers outgoing occurrences, backlinks
(the same edges read in reverse) and unresolved targets with derived candidates - a read of the
derived store, never a vault scan. Verified: 11 `links` unit tests (occurrence shapes with their
lines, fences/spans/escapes, both caps, stem-vs-path resolution, the case rules, ambiguity) and 6
store tests (edges written with the row and rewritten on edit, ambiguous candidates,
stub-appears/target-vanishes, a shared stem stopping a resolved edge, removal +
`clear_vault`/`prune_dead_vaults`, the v1→v2 rebuild), the GUT wire test
`test_vault_links_answer_shaped_json`, and the full `ci-check`. **Pane half (closed 2026-10):**
mentions render from the same parser the index uses - `links::Link` gained the occurrence's byte
span, `extract_mentions` replaces each accepted occurrence with a sentinel before Markdown parsing
(so surrounding emphasis/headings/tables are untouched and the label is never re-parsed), and
`GptyMarkdown.render(text, wikilinks)` substitutes
`[url=gpty-note:<percent-encoded target>]label[/url]`; the `wikilinks` flag is set only by the wiki
pane (`MarkdownView.wikilinks_enabled`), fences/spans/escaped openers stay literal, and a document's
own Markdown link cannot name the scheme (`safe_url` unchanged). `MarkdownView` emits
`note_link_clicked(target)` instead of opening anything; following asks
`GptyTerminal.vault_link_resolve` → `VaultStore::resolve_target`, which runs the index's own
`NoteIndex` over the index's note set (`note_paths`, shared with `links_for`/`reresolve_links`), so
a shared stem answers its candidates and is never picked, and an unsaved mention resolves too. The
pane opens the answer **in place** behind `_request_leave` (Save/Discard/Cancel; no history stack).
The new link panel lists every outgoing occurrence (`target · line N`; unresolved rows name the
target and its candidates and are not clickable) and every backlink (`src · line N`, clickable),
capped at 50 rows per section with the remainder counted, rebuilt on open and after a save's
re-index. Verified: 4 renderer unit tests (on/off, code/escape, encoded targets, impersonation
refused), the `links` byte-span test, the `resolve_target` store test, 10 new `test_wiki_pane.gd`
cases (rows + lines, ambiguity candidates, follow by row, backlink and preview click, dirty-buffer
ask with Discard and Save, missing-target handling, no panel when empty), the extended
`test_gdext_ffi.gd` wire test for `vault_link_resolve` and the render flag, and `ci-check`. A
missing row is the create-from-link action; an ambiguous one is information only and never guessed.

Commits: d17bac7

## WIKI-12

**Create, rename, and delete notes** - the editor edits existing notes only: `write_vault_note`
refuses a path with no file behind it (deliberately - editing must not silently create), so the pane
cannot add a note, and a vault maintained elsewhere is the only way to get one. Found while building
the editor (2026-10); pairs with wikilinks, whose unresolved-link detection wants a create-from-link
action. Fix direction: extend the write helper with the missing file verbs under the same
containment rules - a New-note action whose name follows the walk's vocabulary (`.md`, no hidden
components, collision handling instead of an overwrite) and a confirm-then-delete - each re-indexing
the vault like a save does. `gpty_core::vault` gained `create_vault_note`, `rename_vault_note` and
`delete_vault_note`, and the FFI exposes them as
`vault_note_create`/`vault_note_rename`/`vault_note_delete`. The rules: the walk's vocabulary for
every path; a create/rename destination's directory must already exist and canonicalize inside the
vault (no directory creation, nothing through a directory symlink out); the destination is claimed
with `create_new` (and rename replaces only that claim, removing it on failure) so an existing note,
symlink or directory answers `NoteError::Exists` (`code: exists`) - no overwrite path, no
check-then-write race; and create/rename/delete act on the vault **entry**, so a symlinked note is
moved or unlinked as a link with its target untouched, while reads/writes keep following links with
the `Outside` refusal. A rename preserves mtime/size (the open buffer's stamp stays valid) and each
verb re-indexes, so a create is searchable at once and a rename's `removed`+`added` re-derive the
link table. The pane: New note on the list (`Untitled.md` default, bare names gain `.md`),
Rename/Delete on the open note (delete confirms and says unsaved work will be lost),
create-from-link from a missing mention or panel row (ambiguous stems are never created), recovery
copy re-keyed on rename and dropped on delete, and `_has_open_ask` now counts only visible dialogs
because an answered one runs an action that may ask the leave question. Verified: 5 new `gpty-core`
tests (create/refuse/collision/vocabulary, delete entry semantics, rename + existing destination,
directory-symlink escape, symlinked entry moved/unlinked), the FFI wire test
`test_vault_note_file_verbs_answer_shaped_json`, 9 new `test_wiki_pane.gd` cases (create, collision
retry, rename, dirty rename copy move, delete + cancel, dirty warning, missing-mention create,
ambiguous never created), and `ci-check`.

Commits: d17bac7

## WIKI-13

**Renaming a note leaves `[[old-stem]]` mentions unresolved** - the rename verb re-indexes and lets
the derived `resolved` column do its job, so a mention that named the note by stem (or by its old
path) silently becomes unresolved: the referring notes are untouched, the link panel shows the
target as missing, and the create-from-link action would now offer to recreate the *old* name - a
plausible way to fork a note by accident. Found while building the verbs (2026-10). Fix direction: a
rename-time pass over the vault's notes that rewrites only the target spellings that resolved to
this note (preserving aliases and fragments, never touching fenced code or code spans), offered as
an explicit "Update references?" choice beside the rename rather than done silently - it writes to
*other* notes, so it must be confirmed and report a count - with the store's re-index as the
confirmation. Until then a rename leaves the old mentions as the user's to fix. the pass is
`gpty_core::vault`'s `preview_link_rewrite`/`rewrite_links_after_rename`, behind the statics
`GptyTerminal.vault_link_rewrite_preview`/`vault_link_rewrite`, and `gpty_core::links::retarget`
answers the one spelling question (a path target keeps its `.md` style, a bare target becomes the
new stem, and a `[`, `]`, `\|`, `#` or control character in the new name makes it unspellable - the
parser would re-read it as syntax). The walk runs after the rename and the old note set is that walk
with the new path swapped back, so only occurrences that resolved to the old name *before* the move
are candidates: a stem two notes shared was ambiguous and stays untouched, while `[[OLD]]` (a unique
case-insensitive match) is respelled exactly. The editor's own file is not a candidate - its buffer
belongs to the pane - and CRLF, aliases, fragments and every other byte survive; a note over the
read cap is skipped rather than written back as a prefix. The pane offers it after a successful
rename (`UpdateReferencesConfirm`: "N mention(s) in M note(s) still name OLD", Update / Not now),
writes nothing before the answer, reports what landed (plus notes that could not be updated), and
re-indexes so the new backlinks appear. Every write is `write_vault_note`'s and the apply re-plans
in the same call, so an edit made while the question was open is read fresh; only a note that
changes between that plan and its write answers `changed_on_disk` and counts as skipped. Tests: five
core cases (five spelling styles with code literals; ambiguous stem plus self-exclusion; CRLF;
unspellable name; read cap) and two GUT cases (offer/apply with alias and fragment preserved and
code untouched; decline leaves the files alone), plus the existing rename test now asserts that a
vault with no mentions is not asked.

Commits: d17bac7

## WIKI-14

**Link graph canvas - our version of a canvas, with no new file type** - Obsidian's `.canvas` is a
second format living inside the vault; ours is the vault's own link structure, rendered. Nodes are
notes (the index's list), edges are wikilinks (the `links` table the wikilinks item adds), queried
from `vaults.db` when the pane opens and re-queried after every mutation - a save already
re-indexes, and so will create/rename/delete - so there is nothing to keep in sync and nothing new
written into the vault. v1: pan/zoom, a deterministic auto-layout, drag to rearrange (geometry in
RAM for the session, since the *view* is generated on the fly), click a node to open the note, and
the selected note's in/out links highlighted; unresolved targets render as ghost nodes, which is the
unresolved-link view the wikilinks item wants. Persistent arrangement, if wanted later, is gpty's
own store keyed `(vault, rel_path, …)` - never a file in the vault. Layout is UI/UX, so it belongs
in a pure, unit-testable GDScript model beside `concept_graph_model.gd` (the v0.5.4 editor is the
precedent for canvas UX and closed-schema parsing; the terminal grid is the precedent for batched
drawing once node counts grow). Scale: the walk caps at 2000 notes, and that ceiling is where a
`GraphEdit`-per-node canvas stops being the right renderer - pick the draw path with it in view.
Multi-edges **aggregate**: one drawn edge per note pair, carrying the count (thickness or label) - N
parallel curves would be noise, and the per-occurrence detail lives in the backlink panel; direction
stays in the data (it is what makes the backlink query work) and is cosmetic in the layout.
**Weights and direction (settled 2026-10, owner):** the measured weight is *mentions* - `COUNT(*)`
per `(src, resolved)`, derived on read with no column, since occurrences are already rows;
`COUNT(DISTINCT line)` (contexts) stays a knob if a dense vault's layout gets noisy. Drawing clamps
thickness (1→3 px) and damps layout stiffness (log or clamp, never linear), so one chatty note
cannot dominate the springs, and a filter that *hides* edges by weight is never the default - a view
may dim, the data does not disappear. Direction is data-only: no arrows by default (an optional
toggle), mutual pairs (both rows present) drawn double-headed, layout undirected. the data half is
`VaultStore::graph`/`graph_limited` - one aggregated row per ordered `(src, resolved)` pair, ghosts
for unresolved targets, deterministic order (count DESC, then names), `MAX_GRAPH_EDGES` (10k per
class) and `MAX_GRAPH_GHOSTS` (2k) setting `truncated` - behind the static
`GptyTerminal.vault_graph`. `VaultGraphModel` (pure, unit-tested) normalizes it into one undirected
pair per note pair (`ab`/`ba`/`mutual`, self-references dropped), clamps stroke width and layout
springs logarithmically (`1→3 px`, `MAX_SPRING`), and lays out deterministically: a sunflower seed
with FNV-1a jitter (never `hash()`), then a size-bounded Fruchterman–Reingold relaxation with
grid-approximated repulsion, because the 2000-note walk makes all-pairs repulsion 4M pairs per
sweep. `VaultGraphView` is one custom-drawn Control (not a GraphEdit per node) with pan/zoom/drag,
off-screen culling, hover/selected labels, optional arrows (mutual pairs double-headed), ghost nodes
as outline circles, and session geometry a re-query preserves - unseen ids are placed near a
neighbour and **Relayout** returns to the deterministic arrangement. The wiki pane's Graph button
queries the index on every press (every mutation already re-indexes), a node click opens the note
behind the same leave guard as the list, and a ghost click runs the preview's own `_follow_target`
(create-from-link when missing, report when ambiguous). Tests: `gpty-core` graph tests (aggregation,
ghosts, self-reference, caps, empty/cleared vault), `test_vault_graph_model.gd`,
`test_vault_graph_view.gd`, and seven `test_wiki_pane.gd` cases (contents, click, dirty guard,
re-query after save, Back, ghost create, invalid vault).

Commits: d17bac7

## WIKI-15

**Declared edge weights - the authored layer** - measured weights (mentions) are a crude proxy: two
notes can be deeply related and mention each other once, or name-drop ten times and share nothing.
This lets a *declared* weight override the measured one for display, authored by a human (a
set/clear control on an edge in the canvas above) or by an agent (the LLM-curation path: the
read/search access above plus one narrow write verb). Rules, settled 2026-10: (1) **never in
`vaults.db`** - that store is a cache we reserve the right to rebuild (a schema bump drops and
re-indexes the derived tables), and authored work must not live where a rebuild erases it; the map
is user-owned in the `PaneEnvStore`/`TrustedStore` pattern (`user://link_weights.json`, atomic
temp+rename, 0600, capped per vault), keyed `(vault, src, target)` on relative paths; (2)
**display-only** - a declared weight changes thickness, layout stiffness and backlink ordering, and
can never hide an edge, gate navigation, trigger a write, or count as consent (the Tier 2
declaration rule: spoofable input feeds no decision); (3) rebuild- and rename-safe by construction -
it lives outside the derived store, the queued rename item owns re-keying it (a rename that does not
re-key silently loses the curation), and entries whose endpoint vanished are pruned lazily; (4) the
write surface is one number and nothing else - per-edge set/clear first, later a single IPC method
(and only then a possible MCP tool). Phasing: the store and the canvas control can land with the
canvas; the agent verb wants the read/search surface above, so it comes after it. the store is
`user://link_weights.json` (`LinkWeightsStore`, the `PaneEnvStore` shape: typed reads, weights
1–100, 32 vaults × 1024 directed entries, atomic temp+rename 0600), keyed `(vault, src, target)` on
normalized absolute vault roots and the walk's own note-path vocabulary; `LinkWeights` is the pure
vocabulary (range, path shape, nested lookup, normalization), and `VaultGraphModel.apply_weights`
merges it into the parsed graph as `declared`/`weight` without touching `count`. The canvas offers
**Set/Change declared weight…** and **Clear** on a right-clicked edge (edge hit-testing is
point-to-segment in the model), styles a declared edge with the accent and counts it in the status
line, and the pane writes both directions of the drawn pair; the link panel orders each section by
the mention's directed declaration before applying its 50-row cap. An untruncated graph show prunes
declarations whose endpoint is no longer indexed (a truncated one never does). The agent verb is the
one write: `vaultWeight` over the control socket,
`gpty vault weight <vault> <src> <target> --weight N\|--clear`, MCP `vault-weight` (22 tools),
answered by the GUI because `user://` is Godot's and never auto-spawning one. Display-only end to
end: nothing outside the canvas/panel reads it. Tests: `test_link_weights.gd` (vocabulary, caps,
reload, prune), the model's declared-weight and edge hit-test cases, the view's menu/scale cases,
and the pane's re-query, set/clear, prune and panel-ordering cases.

Commits: d17bac7

## WIKI-16

**A note rename does not re-key its declared link weights** - `user://link_weights.json` keys
`(vault, src, target)` on relative paths, so a rename (or an outside move) leaves every authored
weight naming the old path; the next complete graph prunes those entries and the curation is gone.
Found while closing the declared-weights item (2026-10), whose rule (3) already names this as its
own job. The rename verb re-indexes and already offers the mention rewrite as a step, so the same
step should re-key both endpoints (the pane knows its vault) before the pruned graph is ever shown;
a refused or failed rename must leave the store untouched. Acceptance: declare a weight in both
directions, rename one note, reopen the graph - the pair is still declared; a cancelled rename
changes nothing; tests seed through `LinkWeightsStore` and assert the rename path's re-key and the
cancelled path's no-op. **Closed (2026-10-18):**
`LinkWeightsStore.rekey_note(vault, old_rel, new_rel)` rebuilds one vault's map in a single pass and
saves once: a row whose source is the old path moves to the new one, every target naming it is
respelled, a self-declaration moves with the note, and unrelated declarations are untouched. A row
already stored at the destination (stale - a rename requires that note to be absent) merges with the
moved row, and the moved declaration wins each shared target; a store with nothing to move returns
false without a write, an invalid path changes nothing, and another vault is never touched. The wiki
pane calls it immediately after `vault_note_rename` answers without an error, before
`_refresh_links()` and the optional mention-update question, so the authored layer follows the file
before any complete graph could prune the old name - and declining to respell other notes cannot
discard it, because a declaration is not a mention. A refused or cancelled rename never reaches the
call and leaves the store as it was. An outside move is indistinguishable from a delete to the index
and still prunes (queued in Future). Tests: `test_link_weights.gd` (both endpoints plus a
self-declaration, stale-destination merge, no-op/invalid-path immunity, vault isolation) and
`test_wiki_pane.gd` (a real rename re-keys both directions; a cancelled rename and a destination
collision change nothing). `./scripts/gut-check`: 56 scripts, 717 tests, all passed.

Commits: d17bac7

## WIKI-17

**Wikilink navigation polish - heading fragments, line jumps, and nested labels** - Three
presentation pieces, no new read or write path. **(1) Fragments follow.** The renderer emits
`[url=gpty-note:<target>#<fragment>]label[/url]` (each part percent-encoded, the literal `#` the
only separator) and `MarkdownView` splits it into `note_link_clicked(target, fragment)` - a click
resolves the *note* through the existing `vault_link_resolve` and then lands inside it.
`vault_links` outgoing rows carry the fragment too: `links_for` re-parses the stored body and
attaches it by `seq`, so the table still stores no fragment. **(2) Line jumps.** A backlink row
opens the linking note at the mention's line; a mention into the note already open only moves the
view, so it asks nothing. The landing is two-step because `scroll_to_line` counts rendered lines: a
new pure `MarkdownAnchors` scans the source for ATX headings (leading frontmatter and fenced blocks
skipped; exact text then case-insensitive; a source line maps to its nearest heading above), and
`MarkdownView.scroll_to_heading` searches the *rendered* parsed text for that heading and maps it
with `get_character_line`. The scroll is queued one frame for the label's layout pass
(`get_character_line` is -1 before it, measured on 4.7.2) and an identical re-render is skipped -
the editor's settled render 0.4 s after opening used to reset the scroll; edit mode scrolls the
source directly. A missing fragment still opens the note and is toasted. **(3) Nested labels.** A
mention inside a Markdown link label or an image alt **yields to its container** and renders as
plain label text: the event loop resolves a sentinel while inside `Tag::Link`/`Tag::Image`, so no
nested `[url]` is emitted and the outer link - what the author wrote - stays the click target.
Tests: `markdown::tests::*fragment*`, `*inside_a_markdown_link*`, `*image_alt*`;
`vault::tests::a_note_row_writes_its_edges_and_their_backlink` (fragment by `seq`);
`test_markdown_anchors.gd` (heading scan); `test_wiki_pane.gd`
(`test_a_fragment_mention_lands_on_the_heading_in_the_editor`,
`test_the_panel_row_names_the_fragment_and_follows_it`,
`test_a_backlink_row_jumps_to_the_mention_line`,
`test_a_missing_fragment_still_opens_the_note_and_says_so`,
`test_a_mention_inside_a_markdown_link_yields_to_it`). Display only: nothing here executes, resolves
a note from a fragment, or widens a read.

Commits: d17bac7

## WIKI-18

**A renamed note's own `[[old-name]]` mentions stay unresolved** - the reference pass deliberately
skips the note at its new path: its buffer is the editor's, and rewriting the file under an unsaved
buffer would turn the user's work into an outside edit. A note that mentions itself therefore keeps
that one mention unresolved after a rename (the outgoing panel shows it as missing, and
create-from-link offers the old name back). Low reachability - a note has to name itself - found
while closing the rename item above (2026-10). Fix direction: include the note when its buffer is
clean and have the pane adopt the rewritten text and stamp from the answer (the apply already writes
only through `write_vault_note`), with an explicit skip for a dirty buffer; never write under one.
the pass takes the buffer state as an `include_renamed` flag on
`preview_link_rewrite`/`rewrite_links_after_rename` (and on both FFI verbs), so the preview's counts
and the apply cannot disagree about the note in the editor - clean includes it, dirty skips it and
still updates every other note. The apply returns `LinkRewriteResult::renamed_note`
(`{text, crlf, mtime, size}` over FFI) when it wrote that note, and the pane adopts the text
(LF-normalized, keeping its caret line and scroll), moves `_saved_text` with it so the buffer stays
clean, and takes the fresh stamp - no second read, and no spurious `changed_on_disk` on the next
save. Never writes under a dirty buffer: the pane passes `not _is_dirty()` at both preview and apply
(recomputed there, since the dialog can outlive an edit). Tests:
`a_rename_rewrites_the_notes_own_mentions_when_the_caller_includes_it` (CRLF body + stamp),
`a_renamed_note_without_self_mentions_answers_no_body`,
`a_renamed_note_past_the_read_cap_is_skipped_even_when_included`; GUT
`test_renaming_a_clean_self_linked_note_updates_its_own_text` and
`test_a_dirty_self_linked_note_is_never_rewritten_under_the_buffer`.

Commits: d17bac7

## WIKI-19

**The vault index cannot open its database on a fresh Windows profile** - `gpty_ipc::transport::state_dir()`
returns `%LOCALAPPDATA%\gpty` on Windows and the Unix `private_state_dir` creates/tightens its
directory, but the Windows arm created nothing; `VaultStore::open` (and the recovery copies / plugin
store) only open files inside it. A Windows GUT run with the new sandbox measured the consequence:
`vault index open failed (…\localappdata\gpty\vaults.db): unable to open database file`, the wiki
note list stayed empty, `test_lists_markdown_notes_recursively_and_skips_hidden` failed, and its
follow-up `[0]` index hit Godot's interactive debugger (`-d`), flooding 1.7 GB of `Debugger Break`
and stalling the suite to the 600 s cap. The live smoke had masked the directory half because it
seeds a plugin record there first. `local_app_data()` now calls the shared `local_app_dir`, which
`create_dir_all`s `%LOCALAPPDATA%\gpty` before returning it - the same creation contract as the Unix
arm, owned by the state-dir function rather than by whichever store opens first. Pinned by
`local_app_dir_is_created_on_first_use` (runs on every platform). The GUT gate also stops passing
`-d` (Godot parses it as `--debug`; a runtime test error now fails the test instead of entering the
debugger) and caps the run at `GUT_TIMEOUT` (600 s), so a future failure cannot become a 1.7 GB
flood that holds the runner. Verified: `cargo test -p gpty-ipc local_app_dir` green; the local gate
green; the Windows GUT leg is the CI proof.

Commits: d17bac7

## WIKI-20

**The vault walk follows symlinks the note reader refuses** - **reproduced** at `af6fcc0` before the
fix: a vault holding a link to an outside directory and a link to an outside `secret.md` listed
`escape/secret.md` and `file.md`, `index_vault` added both, and a search for the outside file's
token returned two hits with its text in the snippets. The walk now resolves every link (and every
directory, so a Windows junction is judged by where it really is) and keeps only what canonicalizes
inside the canonical vault root; the rest is skipped and counted in `ScanResult::outside`, which
travels through `IndexOutcome` to the `vault_index` document and the pane's list footer ("Skipped N
link(s) pointing outside this vault"). Loops and a second road to a directory stop at a visited set
of canonical directories instead of the depth cap, and plain entries are visited before links so an
alias cannot capture the notes its target's own name would list. The premise was half-true: *reads*
never canonicalized either - only a save refused an outside link - so `read_vault_note` shares the
new `resolve_inside` with `write_vault_note` and answers `Outside` (`outside_vault`) instead of
another file's text. Tests: `symlinks_out_of_the_vault_are_not_listed_or_indexed` (list, index and
search over an outside file and an outside directory),
`a_symlink_out_of_the_vault_is_neither_read_nor_written`,
`a_symlink_inside_the_vault_lists_its_notes_once`,
`a_symlink_loop_terminates_and_lists_each_note_once`, and the GUT
`test_the_list_skips_a_link_out_of_the_vault_and_says_so` for the footer. Docs: the walk rule table
and paragraph in the vault page, the editor page's containment sentence, and a
`Vault containment (v0.7.1)` bullet in the security notes.

Commits: d17bac7, f92a8c9

## WIKI-21

**The shipped Knowledge Base profile opens to `Vault index failed: not an absolute path: user://knowledge/<hash>`** - reported
on the v0.7.1 download. The profile seeded its 52 bundled notes correctly and then listed nothing:
`KnowledgeStore._seed()` globalized the store root only when `String.is_absolute_path()` was false,
and Godot 4.7 answers **true** for `user://` (measured against the engine), so the fallback was dead
code. `resolve()` returned `user://knowledge/399b8ba145eb9499`; the pane's own guard passed it
because `DirAccess` accepts the scheme; `vault_index`'s Rust gate then refused it, since no scheme
survives into `std::path`. The suite hid it — `GPTY_TEST_USER_DIR` maps `user://` to an absolute
sandbox before the store ever sees it, so the production branch never ran. Fixed with one vocabulary
in `BasePersistenceManager`: `is_virtual_path()` (`res://`/`user://`), `real_path()` (a scheme
globalized, through the test redirect when one is set) and `is_real_absolute_path()` (the guard for
a value leaving Godot). `KnowledgeStore` resolves the token to a real path, the wiki pane and
`LinkWeights.valid_vault_path` refuse a scheme — so the same virtual path can neither open a pane
nor register as a socket-readable vault root — and every other boundary that hands a path to Rust or
the OS asks the same predicate: `TextRead` (code viewer and stored colour schemes), the file tree
(viewer, system handler, directory walk), `WorkspaceStore.sanitize_cwd` (PTY spawn), and the media
and font gates. Regression: `test_the_production_seed_answers_a_real_path` clears the redirect,
seeds into a unique `user://` probe and asserts the answer is real **and indexes**; the pane and
link-weight tests pin the refusal, the media gate keeps its remote-versus-scheme messages, and the
layout-restore token test still runs token → seed → index → list.

Commits: 39085e9

## WIKI-22

**The note toolbar is unreachable while the buffer has focus** - found 2026-11-04 while closing
**The keyboard cannot drive pane chrome or the Wiki pane**, and measured on that fix build: the note
view's controls are now tab stops, but a keyboard user who is editing cannot reach them - a focused
`CodeEdit` consumes Tab for indentation, Escape leaves the note (Back is the fix for the trap, not a
focus move), and the toolbar sits before the editor in tree order, so the only path to
Rename/Delete/Edit-Split-Preview while typing is to leave the note, reopen it, or click. Fixed
2026-11-04: the toolbar (Edit/Split/Preview, Rename, Delete, Save) is one explicit traversal ring
built from `KeyboardFocus.reachable_children`/`KeyboardFocus.ring` - the pair pane chrome now uses
too - so Tab wraps inside the bar; `Ctrl+Shift+K` enters it (`Workspace._focus_note_toolbar`) and
Escape returns to the buffer (`WikiPane._return_from_note_toolbar`) before the buffer's own Escape
leaves the note, one level out per press. The chord resolves its pane from the focus owner first:
`last_body` alone was measured wrong (a wiki pane opened from its own list kept the startup terminal
as the active pane, so a `last_body`-only rule never fired from the buffer the chord exists for).
`PaneBody.keyboard_entry()` is the new contract behind the row's third half: entering the pane from
its chrome (`TerminalManager._return_focus_to_body`) now lands in the note buffer instead of Back.
Inert with no buffer on screen (no note open, `preview` mode), where the toolbar is already one Tab
from Back. Test: `test_wiki_note_keyboard.gd` - the chord from the focused buffer lands on the first
toolbar button with `last_body` pointing elsewhere, Escape returns to the buffer without leaving the
note and only the second Escape leaves it, the ring covers modes/Rename/Delete/Save in both
directions, the chord is inert in the list view and in preview mode, and chrome Escape aims at the
buffer. `--audit-focus wiki-vault` on the built app: 0 mouse-only buttons of 178 controls (its
tab-order walk still stops inside the title-bar ring - **The focus audit stops inside the first
keyboard ring** below).

Commits: b699d07, b499d7c

## WIKI-23

**The vault link graph is mouse-only** - measured 2026-11-03 in `wiki-graph`: the graph is the only
pane surface and it had zero focusable controls - `Arrows`, `Relayout` and `Fit` were `FOCUS_NONE`,
and the canvas was a `FOCUS_NONE` `Control` whose drag, wheel zoom, click-to-open and right-click
weight menu all lacked a key path, so the Tab order started in the sidebar and the map could not be
operated at all without a pointer. Fixed 2026-11-04: the canvas and its three actions are one
explicit ring with the canvas first (`KeyboardFocus.ring`), so all four are tab stops and the canvas
draws its own accent focus frame (a custom-drawn `Control` has no stylebox to do it); arrows pan
(`PAN_STEP` 48 px, Shift x4), `+`/`-` zoom about the crosshair, and Enter acts on what the crosshair
covers - a note opens, a ghost resolves, an edge opens its declared-weight menu - through the same
`VaultGraphModel.hit_test`/`hit_test_edge` the pointer uses (`VaultGraphView.cursor_hit`, one answer
for the draw and the gesture, so the highlight cannot disagree with the action). The crosshair is
the canvas centre, drawn only while the canvas holds the keyboard, and the node under it gets its
own ring and label. Opening the graph hands the keyboard to the canvas (the Graph button, and
`WikiPane.keyboard_entry` for the chrome route), and Escape still leaves for the list. Measured with
`--audit-focus wiki-graph`: 3 mouse-only buttons and a mouse-only canvas (35 focusable) before, 0
and 39 after, focus-owner the canvas, tab-order canvas -> Arrows -> Relayout -> Fit. Tests:
`test_vault_graph_view.gd` (the ring in both directions, arrow/Shift pan, zoom about the crosshair,
Enter on a node, a ghost and an edge), `test_wiki_pane.gd` (the Graph button hands focus over;
Escape returns to the list).

Commits: 547df56, c96d0ff

## WIKI-24

**The vault graph's labels overlap at the bundled vault's density** - measured 2026-11-03 on the
52-note / 267-link bundled vault: labels were drawn for every node at the fitted zoom and two titles
printed on top of each other at the top of the map (the `wiki-graph` capture), so note identity was
unreadable where the map is most useful; the first fit used node positions only
(`VaultGraphModel.bounds`), not label extents. Fixed 2026-11-04: labels are placed, not drawn per
node - `VaultGraphView.label_placements` orders the candidates by what the user is aiming at
(crosshair, pointer, open note), then degree, then id, and `VaultGraphModel.cull_labels` drops every
box that would print over one already accepted (or that the view clips anyway), so no two titles
stack. Always-on labels still stop at `LABEL_ZOOM`/`MAX_ALWAYS_LABELS`, but past either threshold
the aimed-at, pointed-at and open nodes keep their names instead of the map going nameless.
`fit_to_view` reserves the widest label (`MAX_LABEL_BLOCK`) out of the usable box, so a fitted map's
right-hand labels land inside the padding instead of running off the canvas. Node circles are
deliberately not label obstacles: measured on the bundled vault, blocking against them deleted
nearly every label in the crowded centre. Tests: `test_vault_graph_model.gd` (disjoint boxes kept,
an overlapping one dropped by priority, out-of-view skipped, no candidates),
`test_vault_graph_view.gd` (an 8-node cluster keeps fewer labels than nodes and the open note's, no
two placed boxes intersect, the fit puts every label inside the view, and a 130-node graph names
only the open note). Re-captured `wiki-graph` on the built app: 52 notes, labels legible, nothing
stacked. Screenshot ([captures](../v0.8.md#screenshots)): *Vault link graph* - the 0.7.2 capture of
the stacking this row closed.

Commits: 547df56, 7e72797

## WIKI-25

**Opening the link graph blocks the frame, and `pane-view --graph` inherits it** - fixed 2026-11-14
(build 0.8.3). The query, the model and the layout now run in one `WorkerThreadPool` task:
`WikiPane.request_graph` sets `_graph_wanted`, queues `WikiPane._build_graph_document` (the Rust
`vault_graph` call, `VaultGraphModel.parse` and `VaultGraphModel.layout` — nothing there touches a
node or an autoload, and the weights and the view's positions are copied in on the main thread) and
returns; `_poll_graph_build` applies the result on the frame it lands, and `graph_built(ok, reason)`
reports it once. A build that is no longer wanted (`_hide_graph`, which every surface that leaves
the canvas now calls) or that read a previous vault is dropped, and a wanted graph whose build read
the wrong root is rebuilt, so Back cannot be undone by a late result. `VaultGraphView.show_graph`
takes the worker's `prepared_positions`, so a drag still survives a re-query, and
`_get_layout_state` reports a pending build as the graph the user asked for. The IPC side is the
third deferred-answer method: `paneView` moved from `handle` into `dispatch_request` (the one place
that holds the request id), and a request naming `graph` is booked in `_pending_graph_answers` and
answered from the pane's `graph_built` via the shared `WorkspaceIpcHandlers.view_answer`; the
deadline sweep answers 250 ms before the request's own fallback, so a caller reads "still being
built" or "left the link graph" instead of a generic timeout. Measured with
`godot/tests/bench/graph_bench.gd` (`BENCH_NOTES=600` and `=2000`, links=5): 600 notes/3,000 edges
was 382 ms of frame (query 36, parse 28, layout 319) and is now 45 µs of frame with the canvas 399
ms later on the worker; 2,000 notes/10,000 edges was 1,250 ms of frame (query 124, parse 124, layout
1,001) and is now 49 µs with the canvas 1.32 s later; a warm re-query at 2,000 notes is 255 ms of
work that no longer touches the frame. Tests:
`test_opening_the_graph_returns_before_the_canvas_is_built`,
`test_leaving_the_graph_before_it_lands_keeps_the_canvas_down`,
`test_a_build_that_lands_after_a_vault_change_is_rebuilt_for_the_new_vault`,
`test_a_dragged_node_keeps_its_place_across_a_build`, and in the contract file
`test_pane_view_opens_the_graph_then_a_note` (now dispatch + settle),
`test_a_graph_request_is_refused_when_the_pane_left_the_graph`,
`test_a_graph_request_is_answered_before_its_own_deadline`. Changelog sentence for **The v0.8.3
changelog records the remaining window and pane work**: opening the link graph no longer blocks the
window, and `pane-view --graph` answers when the canvas is up.

Commits: 69a3793, c86693a

## WIKI-26

**The vault graph is a physical 3D map you can push around** - the graph is a deterministic 2D
canvas (`vault_graph_model.gd` owns the layout and hit-testing; `vault_graph_view.gd` draws it and
already supports dragging a node and a Relayout that re-runs the springs), so it feels like a static
diagram next to Obsidian's. Fix: a 3D presentation inside a `SubViewport` (Camera3D, orthographic by
default with a free-orbit toggle, one sprite or billboarded label per note, link lines) backed by
Godot 3D physics: each note is a body, each link a spring, so a dragged node pushes its neighbours
and the map settles when released. Keep `vault_graph_model.gd` the only owner of graph data, link
resolution and the semantic hit-test (raycast into the viewport, then delegate to the model); the
view owns bodies, springs and camera. Persist node positions in the pane's layout state (the same
state that carries `open_note` and `graph`), capped and ignored per missing note. The simulation
pauses when the pane is hidden or the viewport is not visible; node and link caps stay as they are;
no physics state is ever written to the vault. Tests: a push moves a neighbour and settles; a link
stays attached while both ends move; a hidden pane ticks nothing; positions round-trip through the
layout; a deleted note is ignored; the graph data is unchanged after an interaction. Shipped
2026-11-18 (build 0.8.5): `godot/scenes/ui/vault_graph_3d.gd` is a `SubViewport`-hosted
`RigidBody3D` per node and one spring per drawn edge, with a deterministic per-id depth layer; a
drag freezes one body, pushes its neighbours, and rewrites its incident rest lengths on release; the
simulation freezes when settled or hidden (a hidden view reports zero ticks) and the initial at-rest
map skips a pointless settle pass. Picking stays with `VaultGraphModel`: `hit_test`/`hit_test_edge`
run on camera-projected screen positions (the screen-nearest rule the planar canvas and the labels
share), not a physics raycast, and labels stay in the screen-space cull rather than a `Label3D` per
note. `VaultGraphCanvas` is the shared contract; the planar canvas remains the fallback,
`graph_mode` is `auto`/`3d`/`2d` (Compatibility resolves to planar), and `graph_positions` rides the
pane's layout state capped at 4000 entries, +/-4096 and 0.1 rounding, with missing notes ignored; a
mode switch keeps the arrangement. The cinematic layer is additive/alpha halos, a depth fog that
leaves the ground alone, dark-theme glow, a fixed-seed dust pool only while moving, and a vignette;
the 3D ground is the 2D palette background behind a transparent viewport so both themes stay exact.
Measured on the dev machine (RTX 5070 Ti, Forward+, headless CPU): 52 notes / 312 links build 5.7
ms, force step 0.20 ms, node visuals 0.44 ms, link rebuild 1.2 ms; 2000 notes / 10 000 edges build
170 ms, force step 5.5 ms, node visuals 15.1 ms, link rebuild 15 ms at the fallback 15 Hz; no ticks
once settled or hidden. Tests: `test_vault_graph_3d.gd` (push/settle, hidden ticks, link endpoints,
round-trip, deleted note, data unchanged, Motion Off, orbit) plus the model, planar, pane and
settings suites. Screenshot ([captures](../v0.8.md#screenshots)): *The vault graph as a physical 3D
map*.

Commits: 6cecfd6, f6dcb3e

## WIKI-27

**A workspace switch reopens the orbital graph on its last rendered frame** - reported 2026-11-18
from use: leave the wiki workspace, return, open Graph, and the previous map is drawn as a static
background. Cause (`stale-state`): `VaultGraph3D._pause_for_hidden` set `_hidden_paused` and
`UPDATE_DISABLED`; the visible branch of `_notification` requested a frame while the flag still held
the viewport disabled, and `_resume_from_hidden` (the only clearer) was reached only from a physics
frame that is off while settled, so the `SubViewportContainer` kept its last texture. Fixed: the
visible branch calls `_resume_from_hidden`, which clears the flag and requests `UPDATE_ONCE` when
settled. Test: `test_a_settled_view_repaints_after_hiding`
(`godot/tests/integration/test_vault_graph_3d.gd`), whose hidden host is the workspace switch's
visibility path. Audit: `vault_graph_3d.gd` is the only app-owned `SubViewport`; the other
visibility handlers own no render target (recorded under `stale-state` in `pitfalls.md`).

Commits: 3f1ce6a

## WIKI-28

**The wiki pane's view chrome duplicated its views and started on the wrong one** - the pane had
Back to notes + Graph, New note, a Physical/Planar pair and both Relayout and Fit. Now a new pane
opens on the graph; the note list shows only Graph, the note editor shows Notes and Graph, and the
graph shows only Notes; the top-level New button reads New; one Planar/Orbital button switches the
map and the Physical button is gone; Relayout remains (it resets and fits) and the Fit button is
removed. Tests: `test_a_fresh_pane_opens_the_graph`, `test_a_saved_notes_view_is_not_overridden`,
`test_the_view_buttons_follow_the_surface`, `test_graph_notes_returns_to_the_list`,
`test_the_mode_button_names_the_other_presentation`, `test_relayout_is_the_only_layout_action`,
`test_the_new_button_says_new`. Screenshot ([captures](../v0.8.md#screenshots)): *The wiki pane's
view buttons and the graph chrome*.

Commits: 3f1ce6a

## WIKI-29

**The default graph build can steal the keyboard from the note list it replaces** - fixed
2026-11-20: `_show_graph_canvas` reads the focus owner before it hides anything and hands the
keyboard to the canvas when that owner is one of the surfaces the canvas replaces
(`_is_graph_replaced_surface`: the list, search, note box/toolbar, footer, placeholder, New and
Graph), so a build that lands over the list keeps the next keystroke; a surface it does not replace
keeps what the user gave it. `_graph_focus_pending` and `request_graph(take_focus)` are gone - the
decision is read at land time instead of remembered, which also stops a press whose build lands
after the user clicked another pane. Tests:
`test_a_default_graph_build_carries_the_keyboard_off_the_list` (fails on
`gui_get_focus_owner() == null` with the carry removed, measured),
`test_a_default_graph_build_does_not_steal_another_surfaces_keyboard`, and
`test_opening_the_graph_hands_the_keyboard_to_the_canvas` now focuses the button the way a click
does; `test_title_bar_keyboard.gd`'s read-only wiki case drops its `graph: false` narrowing and
settles the default build before the chrome Escape.

Commits: 5687578, df089ac

## WIKI-30

**The orbital map can be travelled in depth, and one button switches presentation** - closed
2026-11-24; the camera was orthographic (`VaultGraph3D._ensure_scene`:
`projection = PROJECTION_ORTHOGONAL`) and the wheel only changed `Camera3D.size`, so the map could
not be traversed in z, while the **Orbit** toolbar toggle (`_orbit_button`) only armed a background
drag and showed nothing when pressed. Fix: a 55° perspective camera; zoom is the world height at the
orbit target (`_view_height`, 60-6 000) with the distance derived from it; Shift+wheel and Page
Up/Page Down travel the target along the camera's forward axis by 12% of the visible height;
per-node units-per-pixel keeps drag and hit-test scale truthful at depth; the fit adds a 220-unit
perspective margin; background left-drag orbits by default, Shift-drag and middle-drag pan; the
Orbit button, `_orbit_mode` and `_set_orbit` are deleted, and the single Planar/Orbital button keeps
naming the other presentation. Tests:
`test_the_orbital_camera_is_perspective_and_fits_by_view_height`,
`test_depth_travel_moves_the_target_along_the_view_without_zooming`,
`test_shift_wheel_travels_and_plain_wheel_zooms`, `test_depth_changes_the_projected_scale`,
`test_a_background_drag_orbits_by_default_and_shift_drag_pans`,
`test_the_graph_toolbar_has_one_presentation_switch_and_no_orbit_toggle`. The `wiki-graph-depth`
capture repeats (`ui-capture-check`: 2 states PASS). Screenshot
([captures](../v0.8.md#screenshots)): *The orbital map after an orbit and a depth travel*.

Commits: 570c792

## WIKI-31

**The link graph has its own theme system, and the first theme is Planetary** - closed 2026-11-24;
before this the graph read only `UiPalette.active()` and local colour constants, so its ground,
nodes and links could not be themed independently of the chrome. Fix:
`godot/scenes/ui/graph_theme.gd` is a closed table (`default`, `planetary`) with a 37-key style, a
dark and a light set per theme, deterministic backdrop stars, a note hue derived from the id, and
the capped ring selection; the default reproduces today's chrome palette; Planetary paints the
orbital map as lit spheres with tilted rings on the busiest notes, a starfield, gold accents on the
related edges and stronger glow/fog, and the planar canvas as the same hues with planet rings; the
style is per-pane (`graph_theme`, a closed `WIKI_SETTINGS` value) with a **Link map theme** row in
Pane Settings and the active non-default theme named in the status line; a theme switch repaints
both presentations live without moving a body. Tests: `godot/tests/unit/test_graph_theme.gd` (schema
completeness, default values, planetary shape, star determinism, note hues, ring cap),
`test_a_theme_change_repaints_without_moving_the_arrangement`,
`test_the_graph_theme_is_a_closed_published_vocabulary`,
`test_the_planetary_theme_swaps_glyphs_without_moving_bodies`,
`test_pane_set_owns_the_wiki_graph_theme`; the `wiki-graph-planetary`, `wiki-graph-planetary-planar`
and `light-wiki-graph-planetary` captures repeat (`ui-capture-check`: PASS) and the orbital state
renders on Compatibility. Screenshot ([captures](../v0.8.md#screenshots)): *The Planetary theme on
the orbital map*.

Commits: 570c792

## WIKI-32

**The note link scan visits every byte of every note** - code: `scan_line`
(`crates/gpty-core/src/links.rs:132`) and `find_close` (`crates/gpty-core/src/links.rs:169`) advance
one byte per loop iteration and test only for a backtick or a bracket, so a line with no link syntax
pays a compare per byte; `parse_links` runs them over every non-fenced line and is called by the
vault index (`crates/gpty-core/src/vault.rs:893`, `crates/gpty-core/src/vault.rs:1525`,
`crates/gpty-core/src/vault.rs:1716`) and by the wiki preview's mention pass
(`crates/gpty-gdext/src/markdown.rs:276`) on every render. The caps allow 2000 notes of 1 MiB
(`crates/gpty-core/src/vault.rs:34`, `crates/gpty-core/src/vault.rs:50`), so a full index can walk
up to 2 GiB through this loop, and the preview repeats it on a note at the cap. Fix:
`memchr::memchr2` for the next backtick or `[` in `scan_line`, and `memchr::memchr2` for the next
`[` or `]` in `find_close`; the skipped bytes can only be plain text, so no state is lost.
`is_escaped` and `run_length` walk short runs and stay as they are. Keep the scalar scanner as the
`#[cfg(test)]` reference and compare over a deterministic corpus with fences, inline code runs,
escaped openers, nested brackets, CRLF and UTF-8; the existing link tests stay unchanged. Probe:
`scan_probe` adds `parse_links` MB/s on a link-free 1 MiB note, a 1 MiB note with 100 links, and a
2000-note index-equivalent loop. Land only if link-free text is at least 3x faster; record the
numbers here and close with the number if it misses. Supporting analysis:
`TEMP/simd-opportunities.md`.

## WIKI-33

**The graph worker is handed the canvas's live positions dictionary** - code:
`WikiPane._start_graph_task` (`godot/scenes/panes/wiki_pane.gd:770`) passes `_graph_view.positions`
straight into the worker's `VaultGraphModel.layout`, while the main thread writes the same
Dictionary in `VaultGraphView.show_graph` (`godot/scenes/ui/vault_graph_view.gd:152`) and on every
drag motion (`:553`); the doc comment at `wiki_pane.gd:762-764` claims both inputs are copied. A
worker reading a Dictionary the main thread mutates is a data race, not a timing claim. Fix:
`var prepared: Dictionary = _graph_view.positions.duplicate()` (the values are Vector2, so a shallow
duplicate is enough). Tests: `godot/tests/unit/test_vault_graph_view.gd` asserts the task input is
not the view's dictionary and a drag during a build cannot change the copy. Evidence and rejected
alternatives: `TEMP/gdscript-opportunities.md`.

## WIKI-34

**Every keystroke in a large note copies the buffer three times, and every render copies it once more** - code:
`WikiPane._on_editor_changed` (`godot/scenes/panes/wiki_pane.gd:1308`) calls `_update_dirty`
(`:1323`, `_is_dirty` reads `_editor.text` and compares it), then `_touch_scratch` (`:1677`,
`_is_dirty` again), then `_preview_text` (`:1284`, `_editor.text` again) - three full-buffer fetches
and two full comparisons per keystroke at the 1 MiB read cap. Separately
`MarkdownView._apply_pending` (`godot/scenes/ui/markdown_view.gd:250`) unconditionally copies and
scans `_pending_markdown.replace("[", "[lb]")` before the renderer answer overwrites `body`, so
every applied render pays a 1 MiB copy. Fix: read `_editor.text` once, compute `dirty` once, and
pass `(text, dirty)` to the dirty label, scratch timer and preview; move the `[lb]` escape into the
renderer-null/no-answer branch. Tests: `test_wiki_pane.gd` passes; a 1 MiB keypress probe records
`_on_editor_changed` down expected >=2x, `last_render_usec` not worse, output identical. Evidence:
`TEMP/gdscript-opportunities.md`.

## WIKI-35

**The link-graph canvas re-measures every label and re-scans every node on every redraw** - code:
`VaultGraphView.show_graph` (`godot/scenes/ui/vault_graph_view.gd:161`) calls `_measure_label_block`
(`:340`), one `font.get_string_size` per node (up to 2000) on the frame the canvas goes up. Every
redraw (`:711`) calls `label_placements` (`:365`), which measures up to 120 visible labels, does
`_degrees.get(id, {})` twice per node (the `{}` default is allocated eagerly), builds a Dictionary
per candidate and sorts, then `VaultGraphModel.cull_labels`
(`godot/scenes/ui/vault_graph_model.gd:578`) runs an O(k^2) Rect2 scan; `_draw` and
`label_placements` each call `cursor_hit()` (`:727`, `:375`), each an O(N) hit test with `str()` per
node. A pan/drag queues a redraw per motion event. Fix: precompute per-node
`{degree, radius, label, label_px}` in `show_graph`, cache label widths by text and early-exit at
`MAX_LABEL_BLOCK`; `label_placements(cursor := "")` takes the cursor id so `_draw` computes
`cursor_hit` once; read `_degrees.get(id)` without an eager default; use cached widths.
`cull_labels` stays until the Rust row below. Tests:
`test_vault_graph_view.gd`/`test_vault_graph_model.gd` pass; a headless 2000-node/120-label
`label_placements` + `_draw` probe down expected >=30%; `graph_bench` gains `apply_us`/`label_us`.
Evidence: `TEMP/gdscript-opportunities.md`.

## WIKI-36

**The link graph's layout and hit-testing run in GDScript at up to 2000 notes** - code:
`VaultGraphModel.parse` (`godot/scenes/ui/vault_graph_model.gd:84`) aggregates and sorts pairs;
`_relax` (`:287`) runs 24-240 Fruchterman-Reingold sweeps over Dictionaries and Vector2 at up to
2000 nodes/10000 edges; `hit_test`/`hit_test_edge` (`:506`) and `cull_labels` (`:578`) are pure
GDScript math. The build runs on a `WorkerThreadPool` task, so it does not stall the frame, but it
is VM time and sets `landed_ms`; Rust already owns the index query (`vault_graph`,
`crates/gpty-gdext/src/vault_api.rs:357`). Fix: add
`GptyTerminal.vault_graph_layout(root, previous_json, weights_json)` returning nodes/edges/positions
(`PackedVector2Array` in node order; GDScript rebuilds the id->Vector2 Dictionary from node order),
moving parse/aggregation/`_relax`/hit-test/`cull_labels` into Rust; the view keeps pan/zoom/draw and
font metrics, and `wiki_pane._build_graph_document` calls the Rust layout. Tests: Rust
deterministic-layout/bounds/no-NaN/degrees-weights tests and hit-test/cull equality against the
GDScript reference cases; GDScript graph tests pass. Probe: `graph_bench` at `BENCH_NOTES=2000`
`layout_us` down expected >=5x and `landed_ms` down expected >=2x; a headless hit-test/cull loop at
2000/10000 down expected >=5x. Evidence: `TEMP/gdscript-opportunities.md`.

## WIKI-37

**A heading whose text also appears in the body can land the preview on the body line** - `MarkdownView.scroll_to_heading`
searches the *rendered text* for the heading's line (that is what makes source lines and rendered
lines agree), so a paragraph that says exactly the same thing and appears first wins the search.
Found while closing the fragment item (2026-10-18); the renderer emits no anchors, so text matching
was the chosen approach. Display-only - a wrong scroll inside the right note, never a wrong note.
Fix direction only if it is noticed in use: have `GptyMarkdown.render` track each heading's
plain-text offset while emitting events and map that offset with `get_character_line`, or emit an
invisible marker the view can find.

## WIKI-38

**Setext headings have no anchor** - `MarkdownAnchors` recognizes ATX (`#`) headings only, so
`[[note#Title]]` does not land on a `Title` over `===` heading, and a source line under one derives
no anchor (it lands at the nearest ATX heading above, or the top). The preview renders setext
headings (pulldown-cmark does), so the gap is navigation, not display. Found while closing the
fragment item (2026-10-18); rare in Obsidian-shaped notes, which is why it was scoped out. Fix
direction: add the two-line `===`/`---` form to the scanner - carefully, because a leading `---` is
frontmatter and a thematic break is not a heading.

## WIKI-39

**Suggested related notes from the FTS index** - score a note's own top terms against the rest of
the vault (`notes_fts` already holds them, porter-stemmed) and surface the neighbours as
*suggestions*: fully derived, no store, no authoring, no trust question, display-only like
everything else in the graph. This is the middle layer between measured mention counts and declared
weights (v0.6.0), and it answers "what else is about this" without an LLM; queue it once the link
layer has settled.

## WIKI-40

**Templates** - a designated folder whose contents are inserted into the open note with a **closed
token table** (`{{date}}`, `{{time}}`, `{{title}}`, `{{vault}}`) expanded in Rust and inserted as an
*edit*, so the user still saves and templates open no second write path into the vault. Parked
off-release by the owner's call (2026-10) because nothing depends on it; scheduled here by the
roadmap restructure, and it still adds no trust surface. The scripting half of this on the Obsidian
side is its Templater plugin - the ecosystem this project stays out of. **Daily notes are a cron-job
on a template** (open or create `<folder>/<pattern>.md` for today, then apply one) and can ride
along when this is built, reusing the create-note verb; they are not worth an item of their own.

## WIKI-41

**Markdown lint for the open note** - three defects are silent today: an unclosed fence swallows the
rest of the note in the preview (the renderer parses what it is given and nothing compares the fence
count), a `[[mention]]` that resolves to nothing is visible only in the link panel, and two headings
with the same text make `[[note#heading]]` ambiguous (`MarkdownAnchors.find` returns the first).
Fix: a pure `MarkdownLint` scanner beside `godot/scenes/ui/markdown_anchors.gd`, reusing
`MarkdownAnchors` and the index's link parser; a status row under the note toolbar ("1 unclosed
fence, 2 unresolved links") that opens a popup listing each with its line; click-to-jump through
`_scroll_open_note`, which already scrolls the source by line and the preview by
`MarkdownView.scroll_to_source_line`; and no auto-fix - a lint item names a line and never edits the
buffer.

## WIKI-42

**Markdown formatting toolbar** - the note editor is a bare `CodeEdit`
(`godot/scenes/panes/wiki_pane.gd:311`) under a view-mode row, so bold, lists, tables and links are
typed by hand even though the renderer already supports them (GFM tables, strikethrough and task
lists; `crates/gpty-gdext/src/markdown.rs:164-168`). Fix: a `FormatBar` under the action row - an
`HFlowContainer` so a narrow tile wraps instead of clipping - built from `Icons.icon_button` buttons
for bold, italic, strikethrough, inline code, link, wikilink, heading level (menu),
bullet/numbered/task list, quote, code fence and table, wired into the existing note-toolbar
`KeyboardFocus` ring; edit computation as a pure module (`godot/scenes/ui/markdown_format.gd`, the
`MarkdownAnchors` shape) answering line/column range edits that the pane applies inside one
`begin_complex_operation`, so an action is one undo step with the selection and scroll restored;
chords declared pane-local in `ShortcutManager._ready` (`declare`, not `register` - the `term:*`
precedent - so a terminal's `Ctrl+B` is untouched) and read by the editor's own input handler;
`AppDialog`-based Link, Wikilink and Table dialogs, the Link one stating that only http/https/mailto
render. Alignment is GFM's only: the table dialog writes `:---`/`:---:`/`---:` markers, and because
Godot's BBCode table has no per-column horizontal alignment the renderer aligns each cell with
`[center]`/`[right]` for those markers to show - probe it in a capture before relying on it, and if
cells do not align, keep the source markers and say in the tooltip that the preview renders tables
left-aligned. Chords: `Ctrl+B`/`Ctrl+I`/`Ctrl+K`, `Ctrl+Shift+X` (strike), `Ctrl+E` (inline code),
`Ctrl+Shift+E` (fence), `Ctrl+Shift+7`/`8`/`9` (numbered/bullet/quote), `Ctrl+Alt+K` (wikilink).

## WIKI-43

**Outline navigator** - `MarkdownAnchors.headings` already scans ATX headings for link fragments,
but nothing shows them, so a long note is navigated by scrolling; `_atx_heading` computes the level
and then drops it, so the scanner cannot even express indentation. Fix: append `level` to each
`headings()` entry; a toggleable `OutlinePanel` - an `ItemList` (one tab stop, arrows, Enter jumps)
in a `ScrollContainer`, about 140 px - as the first column of the note view, refreshed on a 0.3 s
debounce off the buffer and capped at 200 rows with a counted footer; a jump reuses
`_scroll_open_note`, so it scrolls the source in edit/split and the rendered heading in preview; the
toggle persists per tile as `outline`, following the `graph` rule (`WIKI_SETTINGS` in
`godot/scenes/panes/pane_types.gd:591`: `ipc: false`, replayed once at attach, never moved by a
settings re-apply).

## WIKI-44

**Find in the open note** - the pane's search box queries the vault index only (`_run_search`), so
there is no way to find text in the note on screen. Fix: `Ctrl+F` opens a find strip above the
buffer; `TextEdit.set_search_text` highlights every match and
`TextEdit.search(text, flags, from_line, from_column)` (4.7; `SEARCH_MATCH_CASE`,
`SEARCH_BACKWARDS`; answers column/line as a `Vector2i`) steps next and previous with wrap-around
and a "No matches" status; the match length is the query length, exact for the single-line
plain-text queries the strip accepts; Escape in the field closes the strip, which means the pane's
`_input` must decline Escape there (today it is Back for every other focus owner in the note view);
the strip clears when the note closes. Replace is deliberately out: it needs its own undo story.

## WIKI-45

**Images in notes render as nothing** - `Tag::Image` is reduced to `[i]Image: alt[/i]`
(`crates/gpty-gdext/src/markdown.rs`), so a note written elsewhere (Obsidian embeds images
routinely) shows no image at all, and nothing can insert one. Fix: resolve a relative image path
against the vault root under the walk's containment rule (`gpty_core::vault`: canonicalize, refuse
anything outside the root), a closed extension set (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`) and a
byte and pixel cap before decode, into a texture the view holds and `[img]`s; a toolbar action opens
a picker inside the vault and inserts `![alt](relative/path)`. Remote URLs stay alt text - the
renderer has no network path and this release does not add one.

## WIKI-46

**Table editor** - a table can be inserted by the toolbar and then only hand-edited: adding a row
means typing a pipe line in the right shape, and a cell containing a `\|` breaks the row. Fix:
caret-aware commands on the Table menu - insert row above/below, delete row, insert column
left/right, delete column, and align the column under the caret - as pure `MarkdownFormat` edits
(one undo step, delimiter row preserved, widths untouched), disabled when no table is under the
caret (`table_at`). A grid or cell editor view is deliberately not attempted: the source is the
document.

## WIKI-47

**Wikilink autocomplete** - `[[` is the vault's link syntax and the pane renders and follows it, but
writing one means recalling a note's exact stem; a misspelling silently becomes an unresolved link,
and create-from-link then offers to fork the note. Fix: typing `[[` opens a completion list fed by
the existing FTS index (`vault_search`, capped at 10, debounced 150 ms), Up/Down/Enter/Tab pick,
Escape cancels, and the insert writes the stem (alias form `[[stem\|alias]]` when text is selected);
the popup is anchored at the caret, works with mouse and keyboard, and leaves the pane's existing
leave rules unchanged.

## WIKI-48

**Preview depth: fenced-code highlighting and footnotes** - a fenced block renders as one `[code]`
run whose info string is literal first text, and `Options::ENABLE_FOOTNOTES` is off
(`crates/gpty-gdext/src/markdown.rs:164-168`) although the `FootnoteDefinition`/`FootnoteReference`
arms already exist. Fix: (a) a closed language table (`rs`, `py`, `gd`, `js`/`ts`, `sh`/`bash`,
`json`, `toml`, `yaml`, `c`, `cpp`, `md`) mapping keywords, strings and comments to `[color]` spans
- a token scan in the renderer, no new dependency, and anything unlisted stays plain; (b) enable
footnotes and link `[^1]` to its definition. Display only: the source is untouched.

## WIKI-49

**Editor conveniences: list continuation, task toggling, and a word count** - Enter at the end of
`- item` starts a plain line, so the marker is re-typed; a checklist is ticked by editing `[ ]` by
hand; and nothing reports the document's length. Fix: Enter continues the current list or quote
prefix and a second Enter on an empty item clears it (a pure prefix computation shared with the
toolbar's list commands); a task toggle flips `- [ ]`/`- [x]` on every touched line from the toolbar
and a chord; the note bar shows `words · characters` from a 0.5 s debounced count and hides in
preview mode. No new store and no new write path.

## WIKI-50

**A note near the 1 MiB render cap still costs ~1.1 s per settle render** - v0.6.0 removed the
superlinear shape term (list tags; minutes → ~1 s for the largest note a pane reads) and moved the
render off the keystroke, so typing is smooth; what remains is the linear cost of the update itself,
dominated by Godot's shape pass (0.97 s of the 1.10 s for 1 MiB in release - the v0.6.0 closure
carries the full table). Evidence-gated: act only if editing a note near the cap in split mode still
hurts. The item's own alternative is then a *paused* preview past a size threshold (a "preview
updates when you ask" state with an explicit render action) - a UX decision, not a performance one -
and `edit` mode already renders nothing. Not by lowering the render cap (the silent-prefix bug) and
not by hiding the shape (the label has to lay out what it shows).

## WIKI-51

**Declared link weights cannot follow a note moved outside gPTY** - the wiki pane's rename now
re-keys both endpoints (2026-10, closed above), but a move made in a file manager looks exactly like
a delete to the index: the next complete graph prunes the declarations as vanished, and an outside
move cannot be told apart from a deletion, so guessing would attach authored data to a path the
index never saw. Display-only loss with a small blast radius. Fix direction only if a user reports
it: an explicit graph-side "re-link declarations from &lt;old path>" action seeded by the vanished
endpoint, or a one-graph tombstone the prune respects - neither is worth building ahead of demand.
