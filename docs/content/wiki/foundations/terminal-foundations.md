# Terminal Foundations

Every terminal you have ever used is at least two programs wearing one costume: a
program that *produces* text, and a program that *draws* it. This cluster explains the
pieces in between, using gPTY's own implementation as the worked example. Read these
six notes before the project notes and the rest of the wiki will have somewhere to sit.

## Why start here

A newcomer can use gPTY for a week without knowing what a PTY is. Then something
strange happens: a command that works in a normal terminal refuses to print color, a
full-screen program draws garbage, pasting does nothing, resizing a pane leaves stale
text, or a script that works in CI hangs when run by hand. Every one of those is a
consequence of the layers below, not a bug in the app.

The layers are worth separating because each one owns a different question, and each
one fails in its own way:

| Layer | Owns | In gPTY |
|---|---|---|
| PTY | Makes a program believe it talks to a terminal | `portable-pty` 0.9, `crates/gpty-core/src/pty.rs` |
| Emulator | Turns the byte stream into screen state | `vte` 0.15 + `alacritty_terminal` 0.26, `term.rs` |
| Grid | Holds cells, cursor, damage | `TermGrid`, handed to Godot as cell rows |
| Shell | Decides what a typed line means | the program spawned on the PTY's slave side |

The single most useful distinction in this cluster: a **PTY is a kernel interface**,
a **terminal emulator is an interpreter**, a **grid is state**, and a **shell is just a
program**. Four different things that people casually call "the terminal".

## Reading order

1. This hub, for the map.
2. [[pty]] — the kernel object that makes interactive programs work at all.
3. [[terminal-emulator]] — who reads the bytes that come back.
4. [[terminal-grid]] — where the picture actually lives.
5. [[shell]] — the program most panes start, and why `gpty pane-run` behaves the way
   it does.
6. [[conpty]] — the same story on Windows, where the pseudo console is a process, not
   a device.

If you only have five minutes, read [[pty]] and [[terminal-emulator]] and stop.

## The notes

[[pty|Pseudo-Terminal (PTY)]] explains the master/slave pair, why a pipe is not a
terminal (no line discipline, no job control, `isatty` returns false), and why a shell
that sees a pipe stops being interactive. It is the reason a gPTY pane can run `vim`.

[[conpty|ConPTY]] covers Windows, where there is no `/dev/ptmx` and the pseudo console
is a broker process that re-renders output before gPTY sees it. ConPTY is also why
`portable-pty` exists: gPTY asks for one API and the crate picks the platform's
mechanism.

[[shell|Shell]] separates interactive from non-interactive shells, explains `-c`,
prompts, and startup files in general terms, and pins down a distinction that matters
daily: `paneRun` goes through the configured shell, while the CLI View pane runs an
argv array with no shell at all.

[[terminal-emulator|Terminal Emulator]] is the interpreter. The program on the other
side writes bytes — text, plus escape sequences that move the cursor and set colors —
and the emulator turns that stream into a screen. In gPTY that is `vte` feeding
`alacritty_terminal`; the Godot UI is a renderer of the resulting state, not a
terminal itself.

[[terminal-grid|Terminal Grid]] is that state: a rectangle of cells with a character,
a foreground, a background and attribute flags, plus one cursor position. gPTY panes
default to 24 rows by 80 columns, and the UI repaints only cells the emulator marked
as damaged.

## Two things this cluster deliberately leaves out

Escape sequences get their own notes rather than being duplicated here: start with
[[ansi-escape-sequences]], then [[terminal-colors]] and [[text-width-and-unicode]].
Scrolling past the visible rectangle is [[scrollback]], and the class of program that
takes over the whole screen is [[full-screen-tui]].

## Related

- [[index]]
- [[pty]]
- [[conpty]]
- [[shell]]
- [[terminal-emulator]]
- [[terminal-grid]]
