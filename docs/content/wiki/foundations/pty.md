# Pseudo-Terminal (PTY)

A pseudo-terminal is a pair of virtual devices that makes an ordinary program believe
it is talking to a real terminal. One end, the *master*, is held by the application that
owns the window; the other end, the *slave*, is handed to the program. Everything gPTY
does with a terminal pane starts here.

## What it is

The pair behaves like a very short cable with a peculiar middle. Write to the master and
the bytes come out of the slave, exactly as if a user had typed them on a keyboard; write
to the slave and the bytes appear on the master, exactly as if the terminal were printing
them. On Linux the master is opened through `/dev/ptmx`, which allocates a new pair and
returns a file descriptor for the master plus a name for the slave (`/dev/pts/N`).

The middle of that cable is the part a pipe does not have: the **line discipline**. It is
a small kernel state machine that implements the behaviors every shell assumes exist:

| Behavior | What it means | Typical bytes |
|---|---|---|
| Echo | Typed characters are echoed back by the kernel, not by the program | everything |
| Canonical mode | Input is delivered line-by-line, and backspace edits before delivery | `Enter`, `Backspace` |
| Signal characters | A keystroke becomes a signal to the foreground process | `Ctrl+C`, `Ctrl+Z`, `Ctrl+\` |
| Terminal size | The pair carries rows and columns | — |
| Job control | One process group is *foreground*; background readers get stopped | `Ctrl+Z` then `fg` |

That last row is why a PTY is not optional. Job control, `Ctrl+C`, prompts, progress
bars and full-screen editors all depend on the program being able to ask the kernel
"am I attached to a terminal?" — the `isatty()` call — and getting a yes.

## A pipe is not a terminal

A pipe also carries bytes in both directions, so it is tempting to think a pipe would do.
It will not, for three concrete reasons that a newcomer can observe:

- `isatty()` returns false, so programs change behavior. `ls` stops coloring, `git` drops
  its pager, Python prints no prompt, and many tools switch to block-buffered output, so
  lines arrive late or in a burst.
- There is no line discipline: no echo, no line editing, no `Ctrl+C` translation, no
  terminal size.
- There is no foreground process group, so job control does not exist at all.

So `ls --color=auto | cat` prints plain names, while the same command in a terminal
prints colors. Nothing is broken — the program correctly noticed it was not talking to a
terminal.

## How gPTY uses it

gPTY does not touch `/dev/ptmx` directly. It uses `portable-pty` 0.9 through
`crates/gpty-core/src/pty.rs`, which asks the platform for a native PTY pair and
presents one cross-platform interface. Each terminal pane owns exactly one PTY.

The lifecycle is short and worth knowing because it explains most of the app's timing:

1. A pane is created and a PTY pair is allocated.
2. A `CommandBuilder` is filled with the pane's program (a shell by default), its
   arguments, its working directory and its environment. `TERM` is set to
   `xterm-256color` so programs emit a modern, predictable dialect of escape sequences.
3. The program is spawned on the **slave** side and immediately believes it is
   interactive.
4. A dedicated OS thread per PTY reads the master and forwards output to the pane's
   terminal task, which folds the bytes into the screen grid.
5. Typing in the pane writes to the master; resizing the tile sends the new rows and
   columns, which the kernel turns into a `SIGWINCH` for the child.

Output backpressure is deliberate. The reader may queue 256 unread chunks — about 1 MiB
per pane — and then it stops reading. When the kernel's buffer fills, the child's write
blocks. That is correct behavior for a terminal: dropping chunks would corrupt the byte
stream, because escape sequences span chunk boundaries and are not self-contained
records.

## Limits and edge cases

- A flooding command (`yes`, `cat /dev/urandom`) does not grow gPTY's memory without
  bound; it slows down instead, because the pane stops draining.
- Closing a pane closes the master and, on Unix, kills the child's whole process group,
  so a `sleep`, a build or a `yes` started from that shell does not linger after the
  pane is gone. A process that escaped the group (by calling `setsid`, say) is beyond
  that reach and can hold the slave open after the pane has closed.
- Resizing is not a redraw request. The child gets `SIGWINCH` and decides what to do; a
  program that ignores it will draw at the old width inside a narrower pane.
- Every pane costs one OS thread for its I/O, independent of how many panes exist.

## Related

- [[terminal-foundations]]
- [[conpty|ConPTY (the Windows equivalent)]]
- [[shell]]
- [[terminal-emulator]]
- [[terminal-pane]]
