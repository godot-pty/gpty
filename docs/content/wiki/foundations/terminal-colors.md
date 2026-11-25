# Terminal Colors

Terminal colors are attributes attached to cells by SGR escape sequences. A program does not send pixels; it names a color—one of sixteen, an index into 256, or an explicit RGB triplet—and the terminal resolves that name to a color when it paints the cell.

## What it is

Three generations of color coexist in the same escape syntax, and every modern terminal understands all three.

**The sixteen ANSI colors.** Eight base colors and eight bright variants, each with a fixed index. SGR 30–37 select the foreground and 40–47 the background; 90–97 and 100–107 select the bright foreground and background. SGR 0 resets everything, 1 turns on bold, and 7 reverses foreground and background.

**256 colors.** `ESC[38;5;n` sets the foreground and `ESC[48;5;n` the background, where `n` runs from 0 to 255. Indices 0–15 are the ANSI colors, 16–231 are a 6×6×6 RGB cube, and 232–255 are a grayscale ramp. This is the palette a `256color` `TERM` describes.

**Truecolor.** `ESC[38;2;r;g;bm` and `ESC[48;2;r;g;bm` carry 8-bit red, green, and blue components directly, so the program picks the exact color rather than an index. This is what modern tools use for syntax highlighting and gradients.

```bash
printf '\033[31mred text\033[0m\n'
printf '\033[38;5;208morange from the 256-color cube\033[0m\n'
printf '\033[38;2;120;180;255mexact blue\033[0m\n'
printf '\033[7minverse video\033[27m back to normal\n'
```

SGR is stateful: a color set now applies to every character printed after it, until another SGR changes it. That is why output is often wrapped in a color/reset pair, and why a program that crashes mid-line can leave the rest of the screen in an unintended attribute.

## How gPTY uses it

The engine stores the sixteen system colors as an array of RGB triplets in `crates/gpty-core/src/color.rs`. That array is the default palette, and it is what the ANSI indices resolve to unless a pane supplies its own.

Resolution happens in one place. `color_to_rgb` maps a named color through the palette, expands indexed colors using the ANSI table for 0–15, the 6×6×6 cube for 16–231, and the grayscale ramp for 232–255, and passes truecolor components through unchanged. The grid asks that function for every cell it exports, so the UI never interprets SGR itself.

Each terminal draws with a colour scheme: the sixteen ANSI entries plus an explicit foreground, background, cursor and selection. Settings → Appearance offers a dark and a light scheme, and the resolved chrome mode picks one — `Follow system` follows the desktop's dark-mode preference, and an empty light slot follows the dark one, so one chosen scheme styles both modes. The scheme's foreground and background become the grid's defaults (`NamedColor::Foreground`/`Background` resolve to them), which is why a scheme's background, not entry 0, is the colour a resize exposes. A pane can keep its own scheme from Pane Settings (stored in `user://pane_schemes.json` by attachment id); an empty choice follows Settings. Eleven schemes ship, and an Alacritty (TOML/YAML), iTerm2 (`.itermcolors`), Base16, native JSON or 16-colour CSV file can be imported: the import writes a validated native copy under `user://schemes/`, so the source file can move or be deleted, and a refused import says why in one sentence. A slot the scheme does not carry takes the built-in palette's value, and a legacy CSV that omits the foreground/background pair takes entries 7/0 — a native or imported scheme names the pair explicitly. This is a palette substitution, not a filter: truecolor output is unaffected, while ANSI colors change everywhere at once.

Appearance's **Terminal backdrop** can paint that ground as a two-stop gradient: the scheme colour at the bottom and 6 % toward white (dark ground) or black (light ground) at the top. Only cells at the default background reveal it; every ANSI, inverse or selected cell paints over it with its own exact colour, and an ambient effect paints its own ground instead.

## Paint-ready cells

A cell carries its resolved foreground and background as RGB, plus attribute flags. SGR 7 (inverse) is stored as its own bit rather than applied at parse time. Before the grid is packed for rendering, the inverse swap is applied once, so the foreground the renderer receives is always the glyph color and the background is always the background. The inverse bit also travels to Godot, but as cell data—not as an instruction to swap again.

That distinction is not academic. A shell's readline wraps the echo of a bracketed paste in `ESC[7m`/`ESC[27m`; a renderer that swapped only the text color and not the background painted the pasted line in its own background color and made it invisible. Resolving both colors before drawing removes the possibility.

Default colors are part of the theme too: cells that never received an SGR use a light gray foreground and a dark gray background, and the Appearance settings tab controls chrome colors such as selection and focus borders separately from the terminal palette.

## Limits and edge cases

Indexed colors 0–15 are only as accurate as the palette in effect; a scheme that omits an ANSI entry fills that slot from the built-in palette rather than from the scheme before it, and a value that is not a valid `#rrggbb` string is ignored rather than guessed. The 6×6×6 cube is a standard approximation, so a 256-color program and a truecolor program asking for the same visual color may end up slightly different.

Bold is an attribute, not a color—gPTY does not automatically brighten bold text—so programs that relied on that old terminal behavior may look flatter. And because color is per cell, changing the scheme affects what is already on screen as well as new output: the palette is the interpretation of the stored indices, not a property of the text.

## Related

- [[terminal-foundations]]
- [[ansi-escape-sequences]]
- [[terminal-grid]]
- [[terminal-emulator]]
- [[settings]]
