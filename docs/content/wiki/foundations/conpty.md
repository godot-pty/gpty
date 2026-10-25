# ConPTY

ConPTY is Windows' pseudo console: the mechanism that gives a Windows program the same
"you are attached to a terminal" illusion a Unix PTY gives. It is why a gPTY pane on
Windows can run an interactive shell, a full-screen editor or a colorized build without
the app needing a second terminal implementation.

## What it is

Unix has `/dev/ptmx`: the kernel allocates a master and a slave device and puts a line
discipline between them. Windows has no such device. Historically, console programs
talked to `conhost.exe` through the Win32 console API — a rich set of calls for writing
characters, setting colors and moving the cursor — and there was no supported way for an
unrelated application to host that console inside its own window.

ConPTY closes that gap with a *pseudo console*: a console host process plus a pair of
pipes. The application creates the pseudo console, gets a handle for the "master" side,
and starts the child attached to it. Everything the child does through the console API is
executed against a real console buffer and then **re-rendered** by the console host into
a stream of VT-style bytes, which the application reads from the pipe. Input travels the
other way: the application writes bytes, the console host turns them into console input
records for the child.

Two consequences follow from "there is a process in the middle", and they matter:
the output gPTY receives is a rendering of console state rather than the child's raw
writes, and input goes through a translation step instead of a kernel line discipline.

## The familiar example

A Windows program that prints in color and draws a progress bar with cursor movement is
usually calling console APIs, not writing escape sequences. Under a ConPTY, the console
host observes those calls and emits the equivalent VT sequences for the hosting
application. That is why a pane can display such a program correctly even though the
program never produced a byte of ANSI text itself. On Unix the same program would be
writing the escape sequences directly to the slave device.

## Why `portable-pty` exists

gPTY's engine asks for a PTY once, through `portable-pty` 0.9, using a single set of
types: a native PTY system handle, a command builder, a master handle, and a size. The
allocation itself — `/dev/ptmx` on Unix, a pseudo console on Windows — happens inside
the crate, so the pane's spawn, read loop and resize logic are written once.

The platform branches that remain are small but informative — executable lookup honors
Windows' `PATHEXT` extensions, and foreground-job detection returns "unknown" on Windows
because a pseudo console has no foreground-process-group equivalent to compare against.
That last one is the clearest statement of what ConPTY does not model: there is no
process-group notion to ask about.

## What actually differs

| Question | Unix PTY | ConPTY |
|---|---|---|
| What the pair is | Kernel device pair (`/dev/ptmx`, `/dev/pts/N`) | A console host process plus pipes |
| Line discipline | In the kernel | Not present; the console host handles input |
| Where output comes from | The child's own writes | The console host's re-rendering of console state |
| Interrupt | `Ctrl+C` becomes `SIGINT` via the line discipline | A console control event delivered by the console host |
| Window size | `ioctl` plus `SIGWINCH` to the child | A resize request to the pseudo console |

The practical reading of that table: the *contract* is the same — a program that asks
"am I on a terminal?" hears yes, and an application can read a VT-style byte stream and
drive a grid — while the *mechanism* differs enough that timing and some edge cases are
not identical.

## Limits and edge cases

- Latency is one process deeper. Output passes through the console host before gPTY sees
  it, so a burst of writes can arrive in slightly different chunks than on Unix. The
  parser does not care: the byte stream is still a byte stream.
- Re-rendering can normalize. Because the console host converts console state into
  sequences, some details of *how* a program drew something may not survive byte-for-byte.
  In practice this is invisible for normal interactive use, and it is the reason
  terminal-compatibility edge cases are often platform-specific.
- Resize is a request, not a signal. A program that ignores the new size will keep
  drawing at the old dimensions, exactly as on Unix.
- Text selection and copy in the pane are gPTY's own (the grid is gPTY's state); they do
  not depend on the Windows console's selection mode.
- Closing the pane tears down the pseudo console, and the child is expected to notice.
  A detached helper process can keep running, the same as a Unix equivalent.

## Related

- [[terminal-foundations]]
- [[pty|PTY (the Unix mechanism)]]
- [[shell]]
- [[terminal-emulator]]
- [[terminal-pane]]
