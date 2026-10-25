# History

History is the durable copy of what a terminal pane printed. The grid in memory is what you see; the history store is what survives closing the pane, closing the app, and rebooting the machine.

## Why persist scrollback

A terminal's scrollback normally dies with the process. gPTY keeps it because a pane is part of a saved layout: restoring a workspace should restore the shell, and a shell with an empty screen loses the reason you arranged the panes that way. It also makes the pane searchable across sessions — the failing test output from an hour ago is still there after a restart.

The store is keyed by a pane's stable `attachment_id`. A pane created without one gets no persistent store, because a per-run session id would only write rows that orphan at the next launch. When a pane is restored, the newest `history_lines` rows are loaded back into its scrollback.

## The store

History lives in one SQLite database, `user://history.db`, with an FTS5 full-text index beside the plain rows. FTS5 is the same engine the Wiki pane uses for note search; the difference is the tokenizer. Terminal lines use the default tokenizer so paths, flags, and identifiers stay searchable; the wiki uses stemming because prose is prose.

Writers never touch SQLite on the terminal path:

| Stage | Behaviour |
|---|---|
| Terminal task | Queues each committed output line |
| Per-pane writer | Commits queued lines in batches on an interval, one writer per pane |
| Exit | The pane flushes on teardown so the last lines are in the database |

An insert costs roughly 30 µs, mostly the FTS index, so committing inline would stall output and hold the grid lock the renderer needs. The trade-off is that a search can miss the last few lines printed before the flush — the queue is drained, not instant.

Two caps bound a pane's store: a row cap from Settings (default 10,000 lines, adjustable from 100 to 100,000) and a derived byte cap of 1 KiB per row. The byte cap only binds when lines are unusually long: 10,000 rows of maximum-length 16 KiB lines would otherwise be 160 MB.

## Searching

`Ctrl+Shift+F` opens the search bar in the active terminal. Results are newest-first; the UI asks for 100 hits, and the API clamps the request to 1–500. History search is per pane — it searches that terminal's store, not every pane's.

The search box takes free text as a person types it, not an FTS5 query. Raw input would make ordinary searches fail: `main.rs` is a syntax error in FTS5, `error: x` reads as a column filter, an unclosed quote fails. Input is therefore sanitized into word-only terms, quoted and joined by a space, which FTS5 treats as AND. Punctuation is searchable because it becomes a separator; searching for `main.rs` finds `main.rs`.

A query that could not run at all reports an error, distinct from "no match", so an empty result is honest.

## What it costs on disk

Scrollback is plaintext. The point of a history store is that you can read it after the process is gone, and search it by content, so it is not encrypted.

Settings shows an **On disk** figure for the store, computed from the database file and its `-wal` and `-shm` siblings. That number is why the control is "history lines" rather than "megabytes": the row cap plus the per-row byte cap determine the bound, but the actual size depends on how long the lines actually were.

The database and its siblings are created owner-only (mode 0600), and the same rule covers the other JSON stores next to it. That protects against other accounts on a shared machine. It does not protect against anything running as you: any process of yours can read the file, the same way it can read a shell history file.

## Limits and edge cases

The store is per pane and per user; search does not cross panes. A pane whose task dies abruptly — a `SIGKILL`, a forced daemon stop — loses whatever was still queued. Search is line-based: a multi-line match is not a thing, so a query matches one stored line at a time.

## Related

- [[gpty]]
- [[scrollback]]
- [[settings]]
- [[terminal-grid]]
- [[security-model]]
