# ANSI Escape Sequences

An ANSI escape sequence is a short byte pattern that tells a terminal to do something other than print a character: move the cursor, erase part of the screen, switch to bold, or set a window title. Every terminal program—a shell prompt, `git`, `vim`, a compiler's colored diagnostics—speaks this protocol, and a terminal emulator is mostly the machinery that interprets it.

## What it is

A terminal receives a stream of bytes over a pseudo-terminal and decides, byte by byte, whether each one is text to place in the next cell or the start of a command. The commands all begin with the escape byte, `0x1B` (written `ESC`, `\033`, or `\x1b`). Three families cover almost everything a user will meet:

| Form | Name | Purpose |
|---|---|---|
| `ESC [` … final byte | CSI, control sequence | Cursor movement, erase, modes, scrolling |
| `ESC ]` … `BEL`/`ST` | OSC, operating system command | Titles, hyperlinks, application-defined notices |
| `ESC [` … `m` | SGR, select graphic rendition | Color and text attributes |

CSI sequences carry numeric parameters separated by semicolons and end in a letter. `ESC[2J` erases the display, `ESC[3;5H` puts the cursor at row 3, column 5, and `ESC[1m` turns on bold. The parameters are optional and have defaults, which is why `ESC[H` and `ESC[1;1H` mean the same thing. SGR is a CSI sequence whose final byte is `m`; it sets the attributes that apply to everything printed afterwards, until another SGR changes them.

```text
\x1b[2J        erase the whole display
\x1b[H         move the cursor home
\x1b[3;5H      move to row 3, column 5
\x1b[K         erase from the cursor to the end of the line
\x1b[1;31m     bold, red foreground
\x1b[0m        reset all attributes
\x1b[?1049h    switch to the alternate screen
\x1b]0;title\x07   set the window title
```

A useful way to read this is as a tiny painting language. The terminal has a cursor; printing a character writes it at the cursor and advances one cell. Nothing in the stream says "this word is red"—the sequence says "the foreground is now red", and the color stays in effect until reset. Erasing is equally literal: it blanks cells, it does not delete text from a document. The terminal keeps no document at all, only the current state of the grid.

Cursor movement is what makes interactive output possible. Instead of appending lines, a program can jump back to a known position and overwrite what it drew before. A scrolling region (set with `ESC[<top>;<bottom>r`) narrows the part of the screen that scrolls, which is how a full-screen application keeps a status bar fixed while its content moves. Erase and scroll-region commands together are the whole basis of screen-oriented programs; there is no separate drawing API.

## How gPTY uses it

gPTY has two parsers over the same bytes, for two different jobs. The concept matcher uses a deliberately small line parser in `crates/gpty-core/src/parser.rs` that walks the stream with the Rust `vte` crate and keeps only printable text, discarding colors, cursor moves, and erase operations. That is what lets a regex trigger match a command's output without being confused by formatting.

The display path is different. `crates/gpty-core/src/term.rs` wraps `alacritty_terminal`, feeds the same bytes through `vte::ansi::Processor`, and maintains full grid state: cursor position, SGR attributes, scrolling regions, alternate-screen mode, and mouse modes. It is the grid that knows a cell is bold or red, and it hands the Godot renderer a resolved picture of the screen.

One detail shows why "just strip the escapes" is not enough. On Windows, ConPTY renders line breaks by moving the cursor to the next row rather than emitting a newline byte. The line parser therefore interprets cursor moves that advance the row, committing the pending line, while ignoring same-row moves—those are prompt redraws and progress-bar updates that must not be split into separate lines.

## Why bytes and not markup

It is tempting to think of terminal output as styled text, like HTML. It is not. The stream is imperative: it mutates cursor and attribute state, and the visible result depends on the order of every instruction before it. That is why the same byte stream can render differently at a different window width, and why scrollback is a record of lines rather than a record of commands.

It also means terminal output is untrusted display data. A program can paint anything it likes on the grid—including escape sequences that look like prompts—but those bytes are interpreted by the emulator as drawing instructions, never executed. gPTY's concept engine is built around that rule: a concept can capture output and route it to another pane, but it can never write to a PTY or run a command. The effects gPTY honors beyond the grid are deliberately few: OSC title updates, emulator replies such as cursor-position reports that are written back to the child, and the display-only `gpty_state=` declaration used for agent state.

## Limits and edge cases

Unknown or malformed sequences are ignored rather than treated as text. A sequence that is never terminated is different: the parser stays inside it, so every byte after it is swallowed and the string's payload accumulates until a terminator arrives. Both halves matter — output stops being interpreted *and* memory grows — so a terminal has to bound it, and what needs bounding depends on which sequences its parser actually buffers.

gPTY closes an unterminated OSC after 64 KiB with a `BEL` and resumes normal parsing, from one shared guard (`crates/gpty-core/src/escstring.rs`) placed in front of both parsers: the display grid and the plain-text line parser. A truncated title or hyperlink can therefore neither hold text extraction hostage nor grow the process. On Windows none of this is observable from a pane: the console host parses the child's output first and buffers an unterminated string itself, so the guard is unit-tested coverage there rather than a streaming path ([[conpty]]). DCS, APC, PM and SOS payloads are read and discarded by `alacritty_terminal` instead of buffered, so they are not counted — measuring that is what decides the guard's scope rather than assuming every string behaves alike.

Finally, escape sequences do not compose into a reliable "screenshot" format. If you need the screen as text, ask the terminal for its resolved cells, not for the bytes that produced them—which is exactly what `paneRead` does.

## Related

- [[terminal-foundations]]
- [[terminal-grid]]
- [[terminal-emulator]]
- [[full-screen-tui]]
- [[terminal-colors]]
