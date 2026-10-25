# Text Width and Unicode

A terminal does not lay out text the way a word processor does. It places characters into a fixed grid of cells, and the width of a character in cells—not its length in bytes or codepoints—decides where the next character goes. Getting that width wrong is what makes CJK text, emoji, and accented characters drift out of alignment.

## What it is

There are four different units in play, and confusing them is the root of most terminal text bugs:

| Unit | What it counts | Example |
|---|---|---|
| Byte | UTF-8 encoding units | `é` is 2 bytes; `字` is 3 |
| Codepoint | Unicode scalar values | `é` can be 1 or 2 codepoints |
| Grapheme cluster | What a reader sees as one character | a letter plus a combining accent |
| Display cell | Grid columns the terminal advances | `a` is 1; `字` is 2; a combining accent is 0 |

A cell is the terminal's unit. Most Latin characters occupy one cell. East Asian wide characters—Chinese, Japanese, Korean ideographs and full-width forms—occupy two, because they are drawn at roughly twice the width. Combining marks occupy zero: they attach to the preceding character rather than advancing the cursor. Emoji are the messy case: many are wide, and a family emoji built from several people joined by zero-width joiners is a single grapheme cluster that still occupies two cells.

The important consequence is that a string of N codepoints can occupy more or fewer than N cells, and the terminal has to decide cell by cell. The program and the terminal must agree on the same width table. When they do not, a line that the program counted as 40 columns wide may need 44, and everything after it shifts.

## How gPTY uses it

The grid is rows × columns of cells—24×80 by default—and every cell holds exactly one character plus its attributes. A wide character is stored in two parts: the glyph in its starting cell, and a spacer cell immediately after it. The first cell carries a wide flag; the second exists only to reserve the column.

That flag survives all the way to the renderer. The grid export packs a per-cell `attrs` integer whose bit 16 means "wide character". The Godot pane uses it to draw the glyph once and advance two cell widths, skipping the spacer instead of painting a second character on top. Backgrounds and underlines are painted across both cells, which is why a selected or highlighted wide character forms one continuous block rather than a glyph followed by a gap.

The same cell model governs cursor movement, damage tracking, and text extraction. Damage updates name a row and column and describe changed cells; a wide character changing therefore touches both of its cells. `paneRead` walks the grid column by column and joins one character per cell, trimming trailing spaces, so its lines have the same column structure as the screen.

## Why misalignment is a width bug

If a program believes `字` is one column, it pads a table for one column and the terminal writes two—so the next column of the table appears one cell to the right. If the terminal believes an emoji is one cell but the font draws it two cells wide, the glyph overlaps its neighbor. Neither problem is fixed by changing the font: the layout was computed from the wrong width.

This is why terminal applications use a width function rather than string length. It is also why the width of ambiguous characters—some symbols and emoji that can be narrow or wide depending on context—is a compatibility question. Two programs can both be "correct" Unicode and still disagree about how many columns a character needs.

## Selection, copying, and editing

Selection is a rectangle over cells, not over codepoints. A wide character that straddles a selection edge still occupies two columns, so a selection can cover half of it visually. Copying walks the selected columns and appends the character in each cell; because the spacer after a wide character is a space in the grid, copied text can carry a padding space after each wide glyph. That is a property of copying cells, not of the clipboard.

Editing has the related hazard: when an application erases or overwrites half of a wide character, the other half must go too. A terminal that erases a single cell can leave a stray half-glyph or a spacer with nothing in front of it. gPTY's grid inherits the emulator's handling of wide cells, so erasing and clearing reason about the pair.

## Limits and edge cases

The grid stores one character per cell, not a full grapheme cluster. A base letter and its combining accent are separate codepoints, and a family emoji is a sequence that the terminal places in a cell and its spacer; the grid does not model the sequence as a unit. That is fine for painting and for cursor arithmetic, and it is why the terminal is not a text editor: it never needs to normalize, sort, or reverse a string.

The practical rule for anything reading terminal output is to treat the grid as authoritative. Do not re-measure the text with a different width table, and do not assume a character is one column. Numbers, paths, and ASCII code are safe; anything else should be read cell by cell.

## Related

- [[terminal-foundations]]
- [[terminal-grid]]
- [[ansi-escape-sequences]]
- [[terminal-emulator]]
- [[scrollback]]
