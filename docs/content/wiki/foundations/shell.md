# Shell

A shell is an ordinary program that reads commands and runs other programs. It is not
part of the terminal, not part of the PTY, and not part of gPTY — it is simply the
program a pane usually starts, and understanding which mode it is in explains most
"why does this behave differently" moments.

## What it is

When a pane starts, PTY slave in hand, it executes one program: by default an
interactive shell such as `bash`, `zsh` or `fish`. On Windows it might be PowerShell or
`cmd`. The shell then does three jobs in a loop: print a prompt, read a line of text,
and act on it — run a program, run a *builtin*, expand a variable, or report an error.

Some commands are builtins rather than executables, and the reason is structural:
`cd` cannot be a separate program, because a child process cannot change its parent's
working directory. The same is true of `export` and `alias`. So the shell grows a small
vocabulary of its own (variables, quoting, pipelines, redirections, exit codes) and
executes everything else as a child process, which inherits the PTY.

## Interactive versus non-interactive

The same binary behaves very differently depending on how it was started, and this is
the single most useful thing to know about shells.

| | Interactive | Non-interactive |
|---|---|---|
| Reads from | The terminal | A script, `-c` string, or stdin |
| Prints a prompt | Yes | No |
| Line editing, history, completion | Yes (usually) | No |
| Job control | Yes | Usually off |
| Startup files | Interactive ones are read | A much smaller set, if any |
| Errors | Reported at the prompt, shell continues | May exit with a status |

Whether a shell considers itself interactive depends on whether its input is a terminal
— which loops straight back to the [[pty|PTY]]. Remove the PTY and `bash` quietly
becomes a script interpreter: no prompt, no `Ctrl+C` handling at the shell level, no
history.

## `-c` and startup files in general terms

Shells accept a command string instead of a session: `sh -c 'make test'` runs `make test`
in a fresh shell, then exits with the command's status code. This is the standard way to
run "one command through a shell" from another program, because it is the only way to get
shell features — pipes, globs, `&&`, variable expansion — without writing a script file.

Startup files are the shell's configuration hooks. In general terms: a *login* shell
reads profile files, an *interactive* shell reads a per-shell rc file (`.bashrc`,
`.zshrc` and so on), and a non-interactive shell may read almost nothing — or, for some
shells, one "environment file" named by an environment variable. That asymmetry is why a
command can work interactively and fail under `-c`: your `PATH` tweak lives in a file
that only interactive shells read.

There is a security-shaped corner here. Because some of those variables name a file the
shell will *execute* at startup, setting them from a saved layout or a profile is
equivalent to injecting code. gPTY drops variables like `BASH_ENV`, `ENV`,
`PROMPT_COMMAND` and `ZDOTDIR` when they come from pane settings, layouts or profiles;
you can still set them yourself inside a shell, where the value comes from you and not
from a file someone sent you.

## How gPTY uses it

A terminal pane's program is configurable, but not from the Pane Settings popup. The
program and its arguments come from the tile that created the pane — a profile, a saved
layout tile, or the creation call (`gpty new-pane -c ...`) — while the working directory
comes from the workspace's default directory. The pane settings popup does own the
environment override. Together those values are what is started on the PTY slave; left
alone, the program is a shell, so the pane looks and feels like a terminal.

Two gPTY features deliberately take different paths, and the difference is worth
memorizing:

- `gpty pane-run --command "cargo test"` opens a **new terminal pane** and runs the
  command **through the configured shell**. Shell syntax works, so pipes and `&&` are
  fine, and the pane keeps the shell's environment and startup files.
- The CLI View pane runs an **argv array directly**: no shell, no PTY, no expansion.
  `cargo test` is a program and an argument, not a line to interpret. That is also why
  it strips workspace credentials from the child's environment — there is no shell in
  between to sanitize anything for it.

A third path exists for the same reason: gPTY's concept captures and control-API
injections send bytes or text to a pane, and those arrive at the shell as input, not as
commands executed by gPTY. The shell decides what they mean.

## Limits and edge cases

- The shell is a child of the GUI process. If it exits, the pane's foreground program is
  gone; the pane reports the exit rather than respawning silently.
- `Ctrl+V` is passed through to the shell as a literal `^V`, which readline uses for
  quoted insert. Paste is `Ctrl+Shift+V`; see [[keyboard-shortcuts|the shortcut list]].
- A program launched from the shell inherits the PTY, so it can take over the whole
  screen; that is normal and is the subject of [[full-screen-tui]].
- Output the shell writes is not privileged in any way. Anything a program prints is
  untrusted text that the [[terminal-emulator]] interprets, which is why concepts may
  capture it but never act on it.

## Related

- [[terminal-foundations]]
- [[pty]]
- [[cli-view]]
- [[profile]]
- [[terminal-pane]]
