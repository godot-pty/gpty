# Pane

A pane is the visible unit of a gPTY workspace. It has two layers — a **tile** that owns geometry and chrome, and a **body** that owns content — and the body is what most people mean when they say "pane".

Panes are the reason the app is not just a terminal window: every body is a first-class UI surface, and every body is addressable through the same public API.

## The two layers

A tile is a cell in the tiling grid. It knows its `col`, `row`, `cspan`, and `rspan` in the 60-unit layout grid, draws the titlebar around the body, and carries the minimize, position, type, settings, and close controls. `terminal_manager.gd` owns tile lifecycle: spawn, split, swap, drag, and close.

A body is a Godot `Control` that extends `PaneBody`. It paints the content, handles its own keyboard and mouse input, and implements the settings UI for its type. The body is created from the registry in `PaneTypes.ALL`; the type key is also what the Rust side understands, so the Python-like seam between GDScript and Rust is one vocabulary rather than two.

| Layer | Owns | Examples |
|---|---|---|
| Tile | Geometry, titlebar, focus border, close/minimize, settings button | a terminal and a wiki pane can have the same tile |
| Body | Content, input, per-type settings, status document | `terminal_pane.gd`, `wiki_pane.gd`, `media_pane.gd` |

When a layout is saved, it stores both: the tile's geometry and the body's sanitized settings. A profile does the same for a set of tiles.

## The eight pane types

| Type key | Body | Open with | Use it for |
|---|---|---|---|
| `terminal` | [[terminal-pane]] | `Ctrl+Shift+N`, sidebar, palette, API | A shell, a TUI, an agent CLI |
| `code_viewer` | [[code-viewer]] | `Ctrl+Shift+D`, palette, file tree, API | Reading a file without leaving gPTY |
| `file_tree` | [[file-tree]] | `Ctrl+Shift+T`, palette, API | Browsing a directory and opening files |
| `inspector` | [[inspector]] | `Ctrl+Shift+O`, palette, API | Private, read-only Q&A about what you see |
| `reasoning` | [[reasoning]] | Palette, profile, API | Watching an agent's lifecycle events |
| `cli_view` | [[cli-view]] | Palette, API, plugin profile | Streaming a command's stdout without a PTY |
| `wiki` | [[wiki-pane]] | Palette, API, profile | Browsing and editing a Markdown vault |
| `media` | [[media-pane]] | Palette, API, file tree | Playing a local audio or video file |

The registry also supplies the display name, icon, label prefix, and creation shortcut. `inspector` and `reasoning` split what an older build called Observer; a saved Observer tile is migrated on load, not rejected.

## Opening a pane

Every door ends at the same spawn path, so validation and trust behave the same way regardless of how the pane was requested:

- The sidebar's `+` control and its pane rows.
- The command palette (`Ctrl+Shift+P`, then `new <type>`).
- The CLI: `gpty new-pane --pane-type wiki`, or MCP `new-pane`.
- A workspace layout, a profile, or a plugin-provided profile.
- Another pane, when it routes a file: the file tree opens supported files in a viewer or media pane.

A pane never spawns another pane directly. A body that needs one emits `request_pane`, and the workspace — the only spawner — answers. That is what keeps layout and trust policy in one place.

## Identity

Each pane has a display label and an attachment ID.

- The label is a prefix plus a number: `T1` for terminal, `C1` for code viewer, `F1` file tree, `I1` inspector, `R1` reasoning, `V1` CLI view, `W1` wiki, `M1` media.
- The attachment ID is the stable identifier the control API uses. It follows `[a-z][a-z0-9_-]{0,31}`, defaults to a generated `pane-xxxxxxxx`, and can be set in **Pane Settings**. The API accepts `"active"` where a pane is expected, meaning the focused pane.
- Tags are lowercase identifiers attached at creation (`gpty new-pane --tags ci,backend`) and used by `broadcast` to address several panes at once. They follow the same pattern and are not edited in Pane Settings.
- A terminal also receives `GPTY_ENV=1`, `GPTY_PANE_ID`, and the event-socket credentials in its environment, which is how a program inside the pane can address the workspace.

Duplicate attachment IDs are regenerated at spawn. They would otherwise make `inject`, `pane-read`, `pane-status`, `pane-wait`, `kill-pane`, and `focus-pane` silently act on the wrong pane.

## What a pane can be asked to do

The control API addresses panes, not windows. See [[control-api]] for the full method table.

| Question | Method |
|---|---|
| What panes exist? | `listPanes` |
| Focus or close one? | `focusPane`, `killPane` |
| Type into a terminal? | `inject` |
| Read what it shows? | `paneRead` (screen plus scrollback, 1–2000 lines) |
| Is its process still running? | `paneStatus` |
| Run a command and watch it? | `paneRun`, then `paneWait` |
| Talk to every tagged pane at once? | `broadcast` |

`paneRun` opens a **new** terminal pane; it does not reuse the target's shell. `paneRead` is a snapshot, not a stream. `paneWait` matches a Rust regular expression against recent output and holds the request open until the pattern matches or the deadline passes.

## Routed content

Some panes accept content routed by a concept. The receiver set is explicit: `code_viewer` and `inspector` declare `receives_content`, and every other type does not. A concept action names one of those types; if no receiver is open, the captured bytes replay into the terminal that produced them instead of vanishing.

Concepts are display-only. They can choose which pane shows captured output; they cannot write into a shell. See [[concepts]] and [[capture]].

## Pane settings

The **Pane Settings** popup is type-aware. For a terminal it edits the name, attachment ID, font size, environment, cursor shape and blink, grid rows and columns, scroll lines, default foreground and background, font file, and color scheme. The wiki pane adds its vault path and view mode; the media pane adds its volume and loop state.

Two things it does **not** edit: the shell program and argv, and tags. A pane's program comes from its tile settings in a profile or layout, or from the creation call (`gpty new-pane -c ... --arg ...`); tags come from creation. The working directory is a workspace-level default inherited by new terminals, not a per-pane field.

Per-pane environment is the exception that is user-owned: it is edited in Pane Settings, stored in `user://pane_env.json` keyed by attachment ID, and never adopted from a layout or profile file. A file that carries `shell_env` has it stripped on restore with a notice.

## Closing and restoring

Closing a pane asks when a command is still running in it; a terminal with a foreground job is not removed by a single click. A wiki pane with unsaved text uses the same leave guard as its Back button. Closing every pane in a workspace is **Close All** in the sidebar (also `Ctrl+Shift+R`), and it asks once for the workspace.

Tiles are restored from the workspace's saved layout on startup, and a layout or profile that would spawn a different program or argv goes through [[workspace-trust]] first. A pane whose configured program is the child (a full-screen tool) reports that state through the same status document as any other terminal.

## Related

- [[gpty]]
- [[layout]]
- [[workspace]]
- [[terminal-pane]]
- [[code-viewer]]
- [[control-api]]
