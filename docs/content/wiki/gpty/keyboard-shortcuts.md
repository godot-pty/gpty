# Keyboard Shortcuts

Most of gPTY's actions are reachable from the keyboard. Shortcuts fall into two scopes: those a terminal pane interprets, and those the workspace handles globally.

## Terminal pane

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+C` | Copy the terminal selection |
| `Ctrl+Shift+V` | Paste the clipboard into the terminal |
| `Ctrl+Shift+F` | Toggle the scrollback search bar |
| `PageUp` | Scroll back one screenful |
| `PageDown` | Scroll forward one screenful |
| `Ctrl+V` | Sent to the shell as `^V` — deliberately not paste |

These are handled by the focused terminal before the workspace sees them. `Ctrl+Shift+F` opens a search bar over the pane; Escape closes it. Plain `Ctrl+F` is deliberately **not** intercepted, because full-screen programs like `vim` and `less` use it to page forward, so it reaches the PTY like any other key.

`Ctrl+Shift+C` copies only. With nothing selected it still consumes the chord and does nothing — it never falls through to a workspace shortcut, and it never clears the search bar or triggers an action. After a copy the selection is cleared.

`Ctrl+Shift+V` pastes. When the program running in the terminal has enabled bracketed paste, gPTY wraps the text the way the terminal protocol expects, so a shell or editor can tell a paste from typing. Either way the text is filtered first: control characters other than tab and newline are removed, escape included, so a clipboard that carries a paste terminator or an interrupt cannot end the bracket early or act as a keypress. Newlines and tabs survive, so a multi-line paste stays a multi-line paste.

`Ctrl+V` is the deliberate exception. It is passed through to the shell as a literal `^V` instead of pasting, because programs use it: readline's quoted-insert and vim's visual-block mode both rely on receiving it. Paste is `Ctrl+Shift+V` for this reason, not by convention.

`PageUp` and `PageDown` move the viewport through scrollback one screen at a time, without sending anything to the program. Typing, or pressing Enter, returns the view to the live prompt.

## Workspace and panes

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+N` | New terminal pane |
| `Ctrl+Shift+D` | New code viewer pane |
| `Ctrl+Shift+T` | New file tree pane |
| `Ctrl+Shift+O` | New inspector pane |
| `Ctrl+Shift+W` | Close the focused pane |
| `Ctrl+Shift+R` | Close all panes in the workspace |
| `Ctrl+Shift+B` | Toggle the sidebar |
| `Ctrl+Shift+P` | Open the command palette |
| `F11` or `Ctrl+Shift+M` | Toggle fullscreen |
| `Alt+←` `Alt+→` `Alt+↑` `Alt+↓` | Move focus to the adjacent pane |
| `Ctrl+PageDown` | Next workspace |
| `Ctrl+PageUp` | Previous workspace |
| `Escape` | Close the palette, a search bar, or a settings popup |

New panes use the normal split rule: the largest tile halves along its longer axis, and the spawn is refused when both halves would be smaller than the 6-unit minimum. The four pane-type shortcuts are the only ones gPTY binds directly; Reasoning, CLI View, Wiki, and Media panes are spawned from the sidebar's Add Pane grid, the command palette, or the control API.

Closing a pane is guarded. If a command is still running, gPTY asks once before stopping it, and a pane holding unsaved work — a wiki note, for example — can cancel the close. `Ctrl+Shift+W` targets the focused pane; if focus is on a read-only pane, the workspace remembers the last terminal you clicked, so the shortcut still has a sensible target.

`Alt` plus an arrow moves focus to the nearest pane in that direction, judged by pane centers. It only works while a pane holds keyboard focus, which is the normal state after clicking into a pane. The workspace claims the chord before the terminal's key handling, so the arrow does not become a shell escape sequence; every other `Alt` combination still reaches the program.

Fullscreen is the same action on both bindings: `F11` and `Ctrl+Shift+M`. The sidebar's collapse state is independent of fullscreen, and `Ctrl+Shift+B` works in either mode.

## Command palette

`Ctrl+Shift+P` opens a small input with a filtered list. Typing matches anywhere in a command name, so `new` lists every pane type, `close` lists the close actions, and `load` lists the reload action. Enter runs the first match; clicking a row runs it too.

The commands are one `new <type>` entry for each of the eight pane types, then `close active`, `spawn 16 terminals`, `settings`, `close all`, `save`, and `load`. `save` writes the current workspace set, and `load` reloads the saved set from disk after asking every pane to close. See [[layout]].

## Wiki editor

| Shortcut | Action |
|---|---|
| `Ctrl+S` | Save the open note |

The wiki pane's editor saves explicitly: the Save button or `Ctrl+S` writes the note. There is no autosave; edits mark the note dirty, and leaving a dirty note raises Save / Discard / Cancel. A recovery copy is kept outside the vault between saves, so a crash does not cost the buffer, but it is offered back rather than applied automatically.

## Where shortcuts come from

Workspace shortcuts are registered once at startup, with fixed bindings. Pane-type spawn shortcuts are registered from the pane registry, so the tooltip on a sidebar button always names the same chord that actually works. Terminal chords are handled inside the terminal pane's keyboard path rather than through the global action map, which is why `Ctrl+V` and `Ctrl+F` can pass through to programs while `Ctrl+Shift+V` and `Ctrl+Shift+F` do not.

## Related

[[gpty]] · [[sidebar]] · [[settings]] · [[layout]] · [[workspace]] · [[terminal-pane]]
