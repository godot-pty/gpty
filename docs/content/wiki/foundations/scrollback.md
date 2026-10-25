# Scrollback

Scrollback is the history of lines that have scrolled off the top of a terminal's visible screen. It is what lets you scroll up to read a build log that has already passed, and in gPTY it is also written to disk so the output is still there after a restart.

## What it is

A terminal grid has a fixed number of rows and columns—24×80 by default in gPTY. Output does not make the grid taller. When the cursor is on the bottom row and the program prints a newline, the whole grid shifts up by one row, the top row falls out of the viewport, and a blank row appears at the bottom. That top row is not necessarily lost: the emulator can retain it in a scrollback buffer.

It helps to separate three things:

- The **grid** is the rows × columns of cells that the application is actively drawing into.
- The **viewport** is the window onto the grid that the user currently sees.
- The **scrollback** is the retained history above the viewport.

Scrolling does not move the cursor or change what the application believes is on screen. It only changes which rows the viewport shows. When the view is scrolled back, new output keeps arriving at the bottom of the grid; the user is simply looking elsewhere. Scrolling back to the bottom resumes following live output.

## How gPTY uses it

The in-memory terminal is an `alacritty_terminal` grid configured with a bounded scrollback. gPTY's default is 10,000 retained lines per pane, and the "History lines" control in the Terminal settings tab accepts 100 to 100,000. This number caps how many scrolled-off rows the grid keeps in memory, so it bounds memory use per pane as well as how far back the display can scroll.

Persistence is separate. Each pane can own a SQLite store holding its output lines, with an FTS5 full-text index over them. Lines are queued and committed by a per-pane writer thread rather than inserted on the terminal path, because an insert costs roughly 30 µs and holding the grid lock for that long would stall rendering. The store survives restart: on the next launch, the pane's saved rows are fed back into the grid's scrollback so scrolling up shows the previous session.

Two bounds apply to what a pane retains on disk: a row cap (the same history-lines setting) and a derived byte cap of about 1 KiB per retained row. The byte cap exists because one output line can be up to 16 KiB; without it, 10,000 pathological lines could mean hundreds of megabytes. Consequently the store's size is not derivable from the settings alone, which is why the Terminal tab shows an "On disk:" row that sums the database and its `-wal`/`-shm` siblings.

Navigation is deliberately simple. `PageUp` and `PageDown` scroll the viewport through history; the mouse wheel scrolls three lines per notch by default. `Ctrl+Shift+F` opens the pane's search bar. Its scope toggle switches between the live grid and the persisted history: the live search is a regex over the in-memory scrollback plus screen, while the persisted search is free text against SQLite. Persisted terms are sanitized into quoted, ANDed FTS5 terms, so punctuation such as `main.rs` is searchable instead of being a syntax error, and results come back newest-first with a limit clamped to 1–500 (the pane asks for 100).

## The alternate screen

Full-screen applications such as `vim`, `less`, and `btop` switch to the alternate screen buffer. In gPTY, that buffer keeps no scrollback: the app's constant repainting does not fill the normal history, and switching back restores the primary screen as it was. This is also why the concept engine skips matching while the alternate screen is active—redraw output is not shell output, and capturing it would produce garbage.

The distinction is per buffer, not per program. An application can paint the primary screen without entering the alternate screen; gPTY's grid notes the OMP TUI as an example. Such a program can therefore add lines to history as it repaints.

## Limits and edge cases

Persistence is write-behind, so the most recent output may not yet be searchable if it was printed since the last flush; the pane flushes the queue when it closes. A pane restored under a different identity has no matching store, and history search reports that as "no history stored" rather than an empty result—the pane distinguishes the two.

Scrolling back does not stop output, but new lines can push old ones out of the in-memory buffer while you are reading, and the oldest lines are also the first the row and byte caps delete. The store file is restricted to the owner on Unix, because every line a pane prints—including anything secret that passed through it—is written there.

## Related

- [[terminal-foundations]]
- [[terminal-grid]]
- [[full-screen-tui]]
- [[terminal-emulator]]
- [[ansi-escape-sequences]]
