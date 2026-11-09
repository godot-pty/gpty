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
| `Ctrl+Shift+E` | Move the keyboard into the focused pane's title-bar buttons |
| `Ctrl+Shift+K` | Move the keyboard into the open note's toolbar (Wiki pane) |
| `F11` or `Ctrl+Shift+M` | Toggle fullscreen |
| `Alt+←` `Alt+→` `Alt+↑` `Alt+↓` | Move focus to the adjacent pane |
| `Ctrl+PageDown` | Next workspace |
| `Ctrl+PageUp` | Previous workspace |
| `Escape` | Close the palette, a search bar, or a settings popup; leave a wiki note; return from pane chrome to the pane, or from the note toolbar to the buffer |

New panes use the normal split rule: the largest tile halves along its longer axis, and the spawn is refused when both halves would be smaller than the 6-unit minimum. The four pane-type shortcuts are the only ones gPTY binds directly; Reasoning, CLI View, Wiki, and Media panes are spawned from the sidebar's Add Pane grid, the command palette, or the control API.

While an overlay is open — Settings, Pane Settings, the command palette or the concept graph editor — only the window actions act: `Ctrl+Shift+P`, `Ctrl+Shift+B`, `F11`/`Ctrl+Shift+M`, and `Escape` to close the overlay. Every other chord is swallowed rather than executed, so `Ctrl+Shift+N`, `Ctrl+Shift+W` and `Ctrl+Shift+R` cannot spawn, close or reset the workspace a panel is configuring, and the key never reaches the terminal behind it either.

Closing a pane is guarded. If a command is still running, gPTY asks once before stopping it, and a pane holding unsaved work — a wiki note, for example — can cancel the close. `Ctrl+Shift+W` targets the focused pane; if focus is on a read-only pane, the workspace remembers the last terminal you clicked, so the shortcut still has a sensible target.

`Alt` plus an arrow moves focus to the nearest pane in that direction, judged by pane centers. It only works while a pane holds keyboard focus, which is the normal state after clicking into a pane. The workspace claims the chord before the terminal's key handling, so the arrow does not become a shell escape sequence; every other `Alt` combination still reaches the program.

Fullscreen is the same action on both bindings: `F11` and `Ctrl+Shift+M`. The sidebar's collapse state is independent of fullscreen, and `Ctrl+Shift+B` works in either mode.

Each pane's title-bar buttons are keyboard stops, but a focused terminal sends `Tab` to its program, so `Ctrl+Shift+E` is the way in: it focuses the first control (pane settings), `Tab` moves through the three and wraps inside the bar, and `Escape` hands the keyboard back to the pane. A chrome action that leaves the pane on screen (a restore from the menu, a completed swap) also gives the keyboard back, so the next keystroke still reaches the shell.

## Command palette

`Ctrl+Shift+P` opens a centred card with a filter field and the full list already showing. Typing matches the command's name first (a name that starts with the query outranks one that contains it), then the command id and keywords, so `new` lists every pane type, `close` lists the close actions, and `load` lists the reload action. `Up`/`Down` move a highlighted cursor - it stops at both ends rather than wrapping - and `Enter` runs the highlighted row, not merely the first match; clicking a row runs it too, and `Escape` closes the palette. The field keeps the keyboard while the arrows move the cursor, so `Tab` is not needed to pick a row (and does not move between rows). A query that matches nothing says so instead of showing an empty card.

Each row shows the command's name, the pane type's glyph, and the chord that runs it directly when one is bound (`Ctrl+Shift+N` for a terminal, `Ctrl+Shift+W` for closing, and so on). The commands are one `New <type>` entry for each of the eight pane types, then `Close Active Pane`, `Open Settings`, `Save Command…`, `Close All Panes`, `Save Workspaces`, and `Reload Saved Workspaces`. The last one and `Close All Panes` are shown in the danger colour because they destroy the open panes: `Reload Saved Workspaces` asks every pane to close and then restores the saved set from disk, while `Save Workspaces` writes the current set. See [[layout]].

Your own saved commands follow under a **Saved commands** heading, in the order the Commands tab puts them, each row hinting `Insert` or `Run`. Choosing one writes it into the active terminal pane: `Insert` leaves it at the prompt to read and edit, `Run` sends Enter with it. `Save Command…` opens the Commands tab with the add form already up. When the active pane is not a terminal the rows are greyed out and their tooltip says why — a saved command is never delivered to a pane you are not looking at. See [[settings]].

## Wiki editor

| Shortcut | Action |
|---|---|
| `Ctrl+S` | Save the open note |
| `Ctrl+Shift+K` | Move the keyboard into the note toolbar |
| `Escape` | Return from the toolbar to the buffer; from the buffer, leave the note (asks about unsaved changes) |

The wiki pane's editor saves explicitly: the Save button or `Ctrl+S` writes the note. There is no autosave; edits mark the note dirty, and leaving a dirty note raises Save / Discard / Cancel. `Escape` is Back: it leaves the note (or the link graph) for the note list and writes nothing unless you answered Save, and the list takes the keyboard so `Enter` can reopen a note. A recovery copy is kept outside the vault between saves, so a crash does not cost the buffer, but it is offered back rather than applied automatically.

The note toolbar — Edit / Split / Preview, Rename, Delete and Save — is a keyboard ring: `Tab` moves through it in visual order and wraps. A focused editor keeps `Tab` for indentation, so `Ctrl+Shift+K` is the way in from the buffer, and `Escape` in the toolbar returns to the buffer without leaving the note. Only the buffer's own `Escape` goes back to the list, so the ladder is one level out per press: toolbar → buffer → list. With no note open, or in `Preview` mode where there is no buffer on screen, the chord does nothing and the toolbar is reachable with plain `Tab` from Back.

## Vault link graph

| Input | Action |
|---|---|
| `Tab` / `Shift+Tab` | Move through the canvas, **Arrows**, **Relayout** and **Fit** — one ring |
| `←` `→` `↑` `↓` | Pan the map; hold `Shift` to pan four times further |
| `+` / `-` | Zoom about the crosshair at the canvas centre |
| `Enter` | Act on what the crosshair covers: open the note, create the note a ghost stands for, or open an edge's weight actions |
| `Escape` | Back to the note list |

Opening the graph hands the keyboard to the canvas, and the canvas draws a focus frame and the crosshair while it holds the keyboard; Escape leaves for the list the way it does from a note. The crosshair is the canvas centre, so panning is how the keyboard walks the map. `Enter` resolves through the same hit test the pointer uses, so the node that is highlighted is the node that opens; on an edge (nothing under the crosshair) it offers the declared-weight actions instead. Dragging one node to rearrange the map stays a pointer gesture — **Relayout** resets the arrangement from the keyboard.

## Where shortcuts come from

Workspace shortcuts are registered once at startup, with fixed bindings. Pane-type spawn shortcuts are registered from the pane registry, so the tooltip on a sidebar button always names the same chord that actually works. Terminal chords are handled inside the terminal pane's keyboard path rather than through the global action map, which is why `Ctrl+V` and `Ctrl+F` can pass through to programs while `Ctrl+Shift+V` and `Ctrl+Shift+F` do not.

## Related

[[gpty]] · [[sidebar]] · [[settings]] · [[layout]] · [[workspace]] · [[terminal-pane]]
