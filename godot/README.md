# gpty - Godot Project

## Running

```bash
# Build the Rust extension first
cd .. && cargo build -p gpty-gdext

# Launch Godot (editor)
cd godot && godot -e

# Press F5 to run the application
```

The workspace starts an IPC server on startup (`$XDG_RUNTIME_DIR/gpty.sock` on Linux)
that accepts JSON-RPC 2.0 commands. Use the `gpty` CLI to control it
from the terminal:

## Structure

```
godot/
├── project.godot            # Godot 4.7 project config
├── gpty.gdextension      # GDExtension library config
    ├── concepts.default.json    # Shipped default concepts
    ├── profiles.default.json    # Shipped recommended layouts (Agent Workspace)
    ├── fonts/                   # Bundled fonts (DejaVu Sans Mono + Phosphor icons)
    │   ├── DejaVuSansMono.ttf
    │   ├── DejaVuSansMono-Bold.ttf
    │   ├── DejaVuSansMono-Oblique.ttf
    │   └── Phosphor-Regular.ttf
    └── scenes/
        ├── main.tscn            # Root scene (Workspace)
        ├── autoloads/           # 12 singleton managers
        │   ├── base_persistence_manager.gd  # Shared JSON I/O base
        │   ├── settings_manager.gd
        │   ├── profile_manager.gd
        │   ├── concept_manager.gd
        │   ├── workspace_store.gd  # Named workspace (tab set) persistence
        │   ├── pane_env_store.gd   # User-owned per-pane env, keyed by attachment_id
        │   ├── trusted_store.gd    # Workspace Trust consent memory (builtins + plugins)
        │   ├── link_weights_store.gd # User-owned declared link weights (display-only)
        │   ├── focus_manager.gd
        │   ├── toast_manager.gd
        │   ├── shortcut_manager.gd
        │   └── update_checker.gd
        ├── terminal/            # Core terminal logic
        │   ├── workspace.gd     # Grid layout, workspace tabs, sidebar, profiles, concept routing
        │   ├── ipc_handlers.gd  # WorkspaceIpcHandlers - IPC/pane-API method dispatch
        │   ├── terminal_pane.gd # Control-based renderer, keyboard, selection
        │   ├── concept_router.gd # Pure concept-event routing (extracted, testable)
        │   ├── plugin_review_text.gd # Pure plugin-review dialog text (extracted, testable)
        │   └── terminal_manager.gd
        ├── ui/                  # UI components
        │   ├── sidebar.gd       # Vertical stack: window mode, workspaces, panes, profiles
        │   ├── settings_panel.gd
        │   ├── concept_graph_editor.gd # Visual rule editor overlay (GraphEdit)
        │   ├── concept_graph_model.gd  # Pure canvas/build/validate/compile logic
        │   ├── vault_graph_model.gd    # Pure vault link-graph normalize/layout/hit-test
        │   ├── vault_graph_view.gd     # Custom-drawn vault link-graph canvas
        │   ├── link_weights.gd         # Pure declared-weight vocabulary (paths, range, lookup)
        │   ├── palette.gd       # Shared UI accent colors
        │   ├── toast_overlay.gd
        │   ├── window_chrome.gd # Titlebar + window-mode/fullscreen handling
        │   ├── markdown_view.gd # Safe shared Markdown renderer
        │   ├── markdown_anchors.gd # Pure ATX heading scan for fragment/line navigation
        │   └── icons.gd         # Phosphor icon constants
        └── panes/               # Specialty pane types
            ├── pane_body.gd
            ├── pane_types.gd    # Pane registry, sanitizers, palette command list
            ├── viewable_files.gd # Closed table: which paths open in the viewer
            ├── media_files.gd   # Closed table + path gate for the media pane
            ├── code_viewer.gd
            ├── file_tree.gd
            ├── text_read.gd     # Shared read guard: regular-file gate + 1 MiB cap
            ├── inspector_pane.gd
            ├── cli_view_pane.gd
            ├── reasoning_pane.gd
            ├── media_pane.gd    # Local audio/video playback
            └── wiki_pane.gd     # Vault browser, Markdown note editor, link graph
```

## Key Bindings

### Terminal

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+C` | Copy selection |
| `Ctrl+Shift+V` | Paste from clipboard |
| `Ctrl+Shift+F` | Toggle scrollback search |
| `PageUp` / `PageDown` | Scroll through history |

### Wiki editor

| Shortcut | Action |
|----------|--------|
| `Ctrl+S` | Save the open note (same as the Save button) |

### Workspace

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+N` | Spawn terminal |
| `Ctrl+Shift+D` | Spawn code viewer |
| `Ctrl+Shift+T` | Spawn file tree |
| `Ctrl+Shift+O` | Spawn inspector |
| `Ctrl+Shift+W` | Close focused pane |
| `Ctrl+Shift+B` | Toggle sidebar |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+Shift+R` | Close all panes |
| `F11` / `Ctrl+Shift+M` | Toggle fullscreen |
| `Alt+←↑↓→` | Jump to adjacent pane |

> **Note:** `Ctrl+Shift+C` copies the terminal selection; with no selection it does nothing.
>
> **Note:** `Ctrl+V` is deliberately passed through to the shell as a literal `^V` - shells and TUIs use it (readline quoted-insert, vim visual-block mode). Paste uses `Ctrl+Shift+V`.

## Sidebar

- [+ Terminal] - spawn a new terminal
- [Settings] - open global settings panel
- [Close all panes] - close every pane in this workspace; if a command is still running, it asks first
- [Folder button on a workspace row] - choose that workspace's default directory; every terminal spawned there, including one activated from a profile, starts in it (`Use default` clears it)

Layout is auto-saved on close and auto-restored on startup via `user://layout.json`.

The shipped **Agent Workspace** profile opens a normal terminal plus separate
Inspector (private Q&A) and Reasoning (passive agent thinking) panes. Five
single-pane ecosystem presets ship alongside it: herdr, lazygit, nvim,
claude, and OMP - each restores one full-screen terminal running that tool.
None of them install the OMP extension or launch `omp`; the user does that in
the terminal. Inspector does not follow the terminal conversation. Reasoning
requires the `@gpty/omp-events` extension and gpty's Unix event socket
(`gpty-events.sock`); it is not available on Windows builds yet.

## Command Palette (Ctrl+Shift+P)

Type partial commands: `new`, `close`, `settings`, `close all`, `save`, `load`.
