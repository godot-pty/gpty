# Terminal Emulator

A terminal emulator is the program that reads the byte stream a program writes and
maintains the screen you see. The program on the other side never draws anything; it
emits a description of the screen, and the emulator interprets it.

## What it is

In 1978 a terminal was a physical device with a serial cable, and its manual defined a
set of escape sequences: `ESC [ 2 J` cleared the screen, `ESC [ 1 ; 3 1 m` set a color.
Programs were written against that manual. The devices are gone, but the sequences
remain, so a modern emulator is a compatibility interpreter for decades of accumulated
convention — VT100, VT220, xterm and their many extensions.

The important consequence is a separation of responsibilities that newcomers often miss:

| The program | The emulator |
|---|---|
| Writes bytes | Reads bytes |
| Knows a rectangle of rows and columns | Maintains that rectangle |
| Sends "move cursor to row 3, clear to end of line" | Performs the move and clears |
| Sends "set foreground to color 4" | Records the color on subsequent cells |
| Never knows what is actually visible | Owns the visible state |

So `top` does not paint your screen. It emits a sequence of cursor moves and text, and
whatever emulator is listening decides how that looks. This is why the same program looks
different in two terminals, and why a terminal can support features the program has never
heard of — a searchable scrollback, for instance, is invisible to the program.

## The concrete version

Run `printf '\033[2J\033[H\033[1;31mhello\033[0m\n'`. The bytes mean: erase the display,
home the cursor, switch to bold red, print `hello`, reset attributes. Nothing about that
output says "red text in the top-left corner" — it says "apply these operations in
order". A program that prints a progress bar takes this further: it emits carriage
returns and erase-line sequences many times per second, rewriting one line in place.

## How gPTY uses it

gPTY separates the interpretation from the drawing, in two Rust crates with a narrow seam:

- **`vte` 0.15** is the ANSI parser. It is a state machine over bytes, not over screens;
  it recognizes control characters, printable runs and CSI/OSC/DCS sequences and reports
  them as calls.
- **`alacritty_terminal` 0.26** is the terminal state machine. It applies those calls to
  a grid, a cursor, scroll regions and attribute state, and records which cells changed.
- **`TermGrid`** in `crates/gpty-core/src/term.rs` wraps the two and exports the result to
  the UI as plain structs: character, foreground, background, bold, italic, underline.
  The Godot pane draws those cells; it is a renderer, not a terminal.

gPTY reads the same PTY output three ways, which is worth knowing because it explains
features that seem unrelated:

- Through the full emulator, to produce the visible screen and the [[terminal-grid|grid]].
- Through a plain-text line parser that strips escape sequences, to feed concept
  triggers and the plain-text scrollback index. (See [[concepts]] and [[history]].)
- As raw bytes, when a concept capture buffers output to route to another pane.

The emulator also owns the input direction in a limited way: `keymap.rs` converts a
keyboard event into the byte sequence the program expects, and the emulator's mouse
tracking state decides whether the pane sends mouse reports at all or treats a drag as a
text selection. Cursor shape — block, underline or beam — is likewise chosen by the
program's escape sequences, with gPTY's settings providing the default.

## Limits and edge cases

- **Unsupported sequences are ignored, not fatal.** An emulator must never crash on
  arbitrary bytes; the worst case is that a program draws something odd.
- **Attributes are per cell.** A color set mid-line does not retroactively restyle the
  text already printed, so selecting and re-copying text preserves what was on screen at
  the time.
- **The program can change what a keystroke means.** In a full-screen application, arrow
  keys send escape sequences rather than editing a line; in a shell prompt they edit the
  line. That switching is the emulator honoring the application's mode requests.
- **`Ctrl+V` is deliberately passed through** as a literal `^V` rather than being
  captured as paste, because shells and editors use it. Paste is `Ctrl+Shift+V`, and copy
  is `Ctrl+Shift+C`; see [[keyboard-shortcuts]].
- **Not every terminal is equal.** A program probing for capabilities gets gPTY's answer
  via `TERM=xterm-256color`, so features gPTY does not implement are not advertised.
- **Rendering latency is gPTY's own.** Interpretation is fast; the visible step is a
  Godot `_draw()` over the cells flagged as [[terminal-grid|damaged]].

## Related

- [[terminal-foundations]]
- [[terminal-grid]]
- [[ansi-escape-sequences]]
- [[pty]]
- [[full-screen-tui]]
