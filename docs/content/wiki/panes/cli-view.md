# CLI View Pane

A CLI view pane runs one program with an argument vector and shows its merged output as plain text lines. It is the "plugin UI v1" pane: a third-party command gets a home inside gPTY without being handed a terminal, a shell, or any Godot surface.

## What it is

The body is `CliViewPane` (`godot/scenes/panes/cli_view_pane.gd`); the registered type key is `cli_view` and its label prefix is `V`. The process itself belongs to the Rust extension class `GptyCliView` and the core `gpty_core::cli` module — the script is only the view, plus the Stop and Restart buttons.

The distinction from a [[terminal-pane|Terminal Pane]] is deliberate and structural: there is no PTY and no grid. A CLI view runs a line producer, so lines are the whole contract. The command is always `program` plus `args`, never a shell string, so a saved tile cannot smuggle in shell syntax and a plugin manifest cannot turn a display pane into a shell.

## When to use it

Use it for a tool that prints a report and exits, or streams log-ish output: a build watcher, a formatter in check mode, a status command, a plugin's front end. It is the pane a plugin action opens when the plugin's job is "show me this CLI's output".

Do not use it for anything interactive. There is no input path at all — the child's stdin is `/dev/null` — so a program that prompts will read end-of-file rather than your answer. For prompts, full-screen output, colours and cursor movement, use a terminal pane.

## How to open it

| Method | Action |
|---|---|
| Sidebar | the CLI view button |
| Palette | `new cli view` |
| CLI | `gpty new-pane -t cli_view -c <program> --arg <value>` |
| MCP | the `new-pane` tool with `type: "cli_view"`, `command`, `args` |
| Layout/profile | a saved tile restores `command` and `shell_args` |

The pane has no keyboard shortcut. A pane created without a command stays idle and says so; set the program in Pane Settings and press Restart. Applying settings never restarts the child by itself — the panel re-applies on every keystroke, and relaunching a tool per keystroke is not a preview — so a changed plan shows "Command changed — Restart to apply".

## What it shows and how it is driven

stdout and stderr are merged into one queue of complete lines; two reader threads feed it, and the pane drains the whole queue once per frame. A header row carries the status text and the two buttons:

| Control | Effect |
|---|---|
| Status | `Idle`, `Running (pid N)`, `Exited (code)`, `Stopped`, or the start error |
| Restart | starts the program, replacing a live child |
| Stop | kills the child and its process group |

The status label is written on transitions only. A restart keeps the existing output — this is a log view, and the next run continues it rather than erasing what the previous one printed. The view follows the bottom only while you are already at the bottom, so scrolling up to read an earlier line is not yanked back down by the next one.

Backpressure is the design, not a side effect. The Rust queue holds up to 512 complete lines; when it is full the readers stop reading, the pipes fill, and the child's write blocks. Nothing is dropped while the process runs. A line with no newline is split at 16 KiB so a byte dump cannot grow the buffer without a ceiling, and the GUI keeps the newest 4,000 lines it has drained, re-rendering only when it trims.

`paneRead` works on this pane: its answer is the drained text, not the status label. `paneStatus` returns the process document with `program`, `args`, `pid`, `running`, `exit_code` and `exit_reason`.

## Settings that matter

| Setting | What it changes |
|---|---|
| Name | the pane's title |
| Font size | 8–32 px |
| Program | the executable to run: a bare name is resolved through `PATH`, an absolute path must pass the executable gate |
| Arguments | the argv, shown space-joined |

The arguments field renders the argv joined by spaces, which cannot represent an argument containing a space. The pane therefore keeps the original argv and only re-parses the field when you actually edit it, so changing the font size cannot fragment an argument that contains whitespace.

## What it does not do

It does not use a shell: `>` redirection, `&&`, globs and quotes are not interpreted, so `-c "a && b"` reaches the program as one argument. It does not emulate a terminal: no grid, no alternate screen, no colour interpretation. It does not accept input, and it does not merge the child into the pane's process — closing the pane stops the child and its process group, which is the only thing that kills it.

It also does not hand the child the workspace credentials. The spawn strips the inherited control-socket keys (`GPTY_SECRET`, `GPTY_SOCKET` and the rest of the stripped set) from the child environment, because a tile is not a reason to hand a third-party CLI the ability to control the workspace. An absolute program is additionally held to the terminal's executable rule — regular file, owned by you or root, not group- or other-writable — while a bare name is resolved through `PATH`, as shipped profiles do.

## Limits and edge cases

One child at a time, one command per pane. Output is retained up to 4,000 lines in the view; older lines are dropped from the pane even though the child's own backpressure already bounded what was in flight. Starting a command that is not found or fails the executable gate reports the error in the status row instead of leaving the pane silent. Because the command is pane state, restoring a tile that names a program is a spawn plan and passes through Workspace Trust on restore.

## Related

- [[pane]]
- [[plugins]]
- [[control-api]]
- [[workspace-trust]]
- [[terminal-pane]]
