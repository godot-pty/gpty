# Full-Screen TUI

A full-screen TUI is an interactive program that owns the whole terminal screen and repaints it, the way `vim`, `htop`, and `lazygit` do. It is not a different protocol from ordinary terminal output—it is the same escape sequences used with cursor addressing and a second screen buffer.

## What it is

A shell prompt writes append-only output: print a line, newline, print the next. A full-screen program cannot work that way. Its cursor sits wherever it is needed—the middle of the screen, the end of the status bar—and the content changes in place, so it must be able to say "put the cursor here and overwrite these cells."

Three mechanisms make that practical:

- **Cursor addressing.** `ESC[row;colH` places the cursor at an absolute position. Erase commands (`ESC[2J` for the display, `ESC[K` for the rest of a line) clear cells before the program writes new content.
- **The alternate screen.** `ESC[?1049h` switches to a second buffer, and `ESC[?1049l` switches back. The application gets a clean screen without destroying the shell's scrollback, and on exit the original screen reappears exactly as it was.
- **Terminal modes.** The program hides the cursor while repainting (`ESC[?25l`), can capture mouse events, and can ask for bracketed paste so pasted text is distinguishable from typed keys. All of these are set with sequences and are part of the same stream.

The consequence is a repaint model rather than an append model. The program keeps its own model of what the screen should show and emits the minimum sequences—or a full frame—to make the terminal match. Nothing about the screen is retained by the terminal as a document; the program is responsible for redrawing after a resize, a scroll, or a redraw request.

## How gPTY uses it

The pane does not need a special TUI mode. The same grid wraps `alacritty_terminal`, so alternate-screen switching, cursor addressing, and mode changes are already part of the emulator state. gPTY reads that state in a few places where a full-screen program must be treated differently from a shell.

The grid can report whether the alternate screen is active. That answer keeps the emulator's resize surgery off full-screen apps: when a pane grows and the grid has scrollback, gPTY normally issues a sequence that deletes the rows revealed from history, so a resize does not pull old output into view. For an alternate-screen application that would corrupt the app's own layout, so the check is skipped. The same check gates concept matching: redraw output from a TUI is not a command's output and must not trigger captures.

Mode state also reaches the UI. Mouse reporting is exposed as a bitmask of click, drag, motion, and SGR encoding; when the application has enabled reporting the pane forwards mouse events to it, and when the mask is zero the pane keeps the mouse for selection and scrollback. Bracketed paste is exposed so a paste is wrapped in `ESC[200~`/`ESC[201~` instead of being fed line by line. If the application hides the cursor, the pane paints no cursor at all rather than drawing one at a stale position.

What the user sees is the application filling the pane, with gPTY's own chrome around it: the tile border, the pane title (often set by an OSC title sequence), and the pane's search bar if opened. Resizing the tile sends the application a resize notification; well-behaved TUIs redraw, and the alternate screen returns when they exit.

## Why it is not a separate protocol

There is no "TUI escape sequence". A full-screen program is a program that uses the same vocabulary more aggressively: absolute addressing instead of newlines, erase instead of overwrite-by-printing, mode switches instead of a plain byte stream. This matters when something goes wrong. A TUI that crashes without leaving the alternate screen leaves the terminal in that buffer; a TUI that dies mid-repaint leaves a half-drawn frame. Both are fixed by the sequences the program failed to send, not by a terminal-specific reset.

It also means the terminal cannot tell a "TUI" from a shell by looking at the bytes. gPTY's alternate-screen check is a signal, not a definition: a program may paint the primary screen with the same addressing, and the OMP TUI does exactly that. The terminal's job is to keep the grid honest either way; the program's job is to redraw.

## Limits and edge cases

Because the alternate screen keeps no scrollback, you cannot scroll up inside a full-screen app to see earlier frames—the app's own paging is the only history. Mouse-wheel scrolling in such a pane depends on whether the app asked for mouse reporting: when it did, the wheel is forwarded as events, not used for gPTY's history.

Selection and copy still work on the visible grid, but they read cells as currently drawn. A selection made while an app is repainting captures whatever was on screen at that moment. Resizing a tile is a real event for the application, not a scale operation, so an app that ignores the notification can leave artifacts until it is redrawn or restarted.

## Related

- [[terminal-foundations]]
- [[ansi-escape-sequences]]
- [[terminal-grid]]
- [[scrollback]]
- [[terminal-emulator]]
