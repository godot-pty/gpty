# Terminal Grid

The terminal grid is the screen state: a fixed rectangle of character cells plus a
cursor position. Everything a terminal shows lives there, and everything gPTY's UI draws
is read from it.

## What it is

A terminal does not store "a picture". It stores rows and columns of cells, and each cell
holds one character together with how it should look. In gPTY a cell is literally a small
struct: the character, a foreground RGB triple, a background RGB triple, and flags for
bold, italic, underline, inverse and "wide".

That design is old and it is not an accident. Text-based programs are written against a
rectangle: `top` knows it has 24 rows and 80 columns (`24×80` — the shape a terminal
grew up with, inherited from hardware), a text editor knows which line it is on, a
progress bar knows where the current line ends. The rectangle is the contract between the
program and the screen.

Two more pieces complete the state:

- **The cursor.** One cell position, plus a shape (block, underline or beam) and a
  visibility flag. A program moves it; the emulator keeps it.
- **Attributes applied at write time.** When the program writes a character, the current
  color and flags are copied into that cell. Changing the color afterwards does not
  affect cells already written.

## How gPTY uses it

`TermGrid` in `crates/gpty-core/src/term.rs` owns one `alacritty_terminal` terminal and
hands the UI a rectangle of `CellInfo`. The Godot pane's `_draw()` converts those cells
into glyphs and background rectangles; it holds no text of its own.

The interesting part is how it avoids repainting everything, because a terminal redraws
many times per second and the visible change is usually tiny.

1. The [[terminal-emulator|emulator]] records which cells it wrote and which row ranges
   changed. `alacritty_terminal` exposes that as `TermDamage`: either `Full` (everything)
   or `Partial` (a list of row/column bounds).
2. `TermGrid::get_grid_updates(force_full)` converts that into `GridUpdate::Full` — all
   rows — or `GridUpdate::Partial`, a flat list of `CellUpdate { row, col, cell }`.
3. The UI repaints only those cells.

A full update is forced in three situations, and they are worth knowing because they
explain a visible behavior: the first frame after a resize or open, a change to the color
palette (which restyles cells that have not been rewritten), and a change to the
scrollback view offset. Scrolling the view back is not a change to the grid's contents;
it shifts which lines are being displayed, so the whole visible rectangle must be
redrawn.

The grid's dimensions come from the pane's tile. gPTY's default is 24 rows by 80
columns; the same numbers are given to the PTY so the child is told its size, and
resizing the tile updates both together.

## Practical consequences

| Thing you see | What it is |
|---|---|
| Text redrawn in place (`top`, progress bars) | The program moving the cursor and rewriting cells |
| Selection highlighting | Cell ranges in the grid, not text spans |
| A character occupying two columns | A `wide` cell (see [[text-width-and-unicode]]) |
| Scrolling past the top line | [[scrollback]], stored outside the grid |
| A stale fragment after a resize | A program that drew once and ignored the new size |

## Limits and edge cases

- **A cell is not a character position you can reason about casually.** Wide characters
  occupy two columns; that is why [[text-width-and-unicode]] exists as its own note.
- **The grid is not the scrollback.** By default a pane keeps 10,000 lines of history in
  SQLite (clamped between 100 and 100,000), separate from the visible rectangle. Search
  runs over that text, which is plain text extracted from the same byte stream — see
  [[history]].
- **Resizing is not a re-layout of history.** The rectangle changes, the PTY is resized
  and the child receives a signal; programs that redraw will, others will not.
- **"Grid" is an overloaded word in gPTY.** The *terminal* grid is this cell rectangle;
  the *layout* grid is the tiling system measured in 60 abstract units with a minimum
  tile of 6. They are unrelated; see [[layout]].
- **Copy and search read cells, not the original bytes.** What you copy is what is on
  screen, attributes included, not the escape sequences that produced it.
- **Damage is the whole optimization.** If a render is skipped, the next one catches up
  from the same damage list, because the list is cleared only when it is turned into
  updates.

## Related

- [[terminal-foundations]]
- [[terminal-emulator]]
- [[scrollback]]
- [[text-width-and-unicode]]
- [[terminal-pane]]
