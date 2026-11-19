---
title: "Pitfalls: Terminal & PTY"
weight: 83
---

Traps and invariants across PTY emulation, ANSI parsing, VTE escape processing, grid layout, and child process lifecycles.

## PTY Spawning & Process Lifecycles

- **`portable_pty` `$HOME` fallback behavior:** `CommandBuilder::as_command()` resolves directory paths with `cwd.filter(is_dir).unwrap_or(home)`. If `$HOME` points to a deleted or non-existent path, spawns fail with `No such file or directory (os error 2)` naming the *binary* (e.g. `/bin/bash`) even when the binary exists and is executable.
- **Teardown via `Drop`:** Every Rust structure wrapping a child process (`portable_pty::Child`) or dedicated reader thread must implement `Drop` to call `.kill()` and abort reader tasks. Without explicit teardown, closing panes in Godot leaves orphaned shell processes and background threads.
- **PTY child working directory:** A child process spawned from the GDExtension without an explicit `cwd` inherits the Godot project directory, not the user's terminal launch directory. Always resolve and supply the active workspace directory explicitly.
- **Exit detection on Windows (ConPTY):** ConPTY keeps the PTY pipe open after the child process exits. Relying solely on pipe EOF causes panes to report `running: true` indefinitely. Exit detection requires polling `try_wait` alongside pipe reads.
- **Non-blocking input writes:** PTY input is backpressured through bounded channels (`STDIN_QUEUE_CAP` to `WRITER_QUEUE_CHUNKS`). Writing to the PTY must be non-blocking; blocking in the write path leaves raw-mode children unkillable when they cease reading stdin.

## Grid Synchronization, Rendering & Sizing

- **SGR 7 inverse video color swap:** ANSI SGR 7 swaps both foreground and background colors. Do the swap once at the grid presentation boundary (`CellInfo::paint_colors`). Bash readline wraps bracketed paste echos in SGR 7; swapping only text color paints glyphs with their own background, rendering them invisible.
- **Selection lives in grid space:** Text selection coordinates must be maintained in grid buffer lines (`alacritty_terminal::Term::selection`), not in viewport screen coordinates. Output scrolling and window resizing rotate the grid; viewport-based selections desynchronize immediately.
- **Transient pane sizes collapse grids:** During layout churn (splits, spawns), panels briefly report tiny pixel sizes (~38×40 px, or 4×2 cells). If passed to `resize_grid()`, the grid collapses and rewraps destructively. Skip resizing when pixel dimensions fall below the minimum grid threshold (`TerminalPane._grid_for_size`).
- **Resize rate-limiting & debouncing:** Firing SIGWINCH on every frame during window drag overwhelms child processes. Debounce `_on_resize` calls in GDScript and avoid redundant SIGWINCH signals if calculated rows and columns have not changed.
- **Raw-byte buffering for grid replay:** Never buffer parsed plain text for terminal replay. The ANSI state machine requires raw byte streams with escape sequences preserved.

## Terminal Protocols & Key Handling

- **Terminal query replies (`Event::PtyWrite`):** `alacritty_terminal` emits `Event::PtyWrite` in response to terminal status queries (such as DSR cursor position requests `ESC[6n`). gPTY must forward these reply bytes back to the child PTY. Dropping them breaks interactive TUIs (e.g., OMP, lazydocker) after window resizes.
- **Alt key combos:** For Alt+letter combinations, the keymap expects the frontend layer to prepend `\x1b` (ESC) in the `_key_to_text` fallback path.
- **Mouse mode reporting:** Mouse reporting mode bits (`get_mouse_mode`) are the source of truth for whether the child owns the pointer. The frontend encodes SGR (DECSET 1006) or legacy X10 mouse packets accordingly. Shift-clicking bypasses mouse reporting to allow host text selection.
- **Ctrl+V passthrough:** `Ctrl+V` must reach the child shell as literal `^V` (for readline quoted-insert and vim visual-block). Terminal paste must always be bound to `Ctrl+Shift+V`.
