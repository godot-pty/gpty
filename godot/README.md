# gpty — Godot Project

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
├── fonts/                   # Bundled fonts (DejaVu Sans Mono + Phosphor icons)
│   ├── DejaVuSansMono.ttf
│   ├── DejaVuSansMono-Bold.ttf
│   ├── DejaVuSansMono-Oblique.ttf
│   └── Phosphor-Regular.ttf
└── scenes/
    ├── main.tscn            # Root scene (Workspace)
    ├── autoloads/           # 9 singleton managers
    │   ├── base_persistence_manager.gd  # Shared JSON I/O base
    │   ├── settings_manager.gd
    │   ├── profile_manager.gd
    │   ├── concept_manager.gd
    │   ├── layout_manager.gd
    │   ├── focus_manager.gd
    │   ├── toast_manager.gd
    │   ├── shortcut_manager.gd
    │   └── update_checker.gd
    ├── terminal/            # Core terminal logic
    │   ├── workspace.gd     # Grid layout, sidebar, profiles, concept routing
    │   ├── terminal_pane.gd # Control-based renderer, keyboard, selection
    │   └── terminal_manager.gd
    ├── ui/                  # UI components
    │   ├── sidebar.gd
    │   ├── settings_panel.gd
    │   ├── toast_overlay.gd
    │   └── icons.gd         # Phosphor icon constants
    └── panes/               # Specialty pane types
        ├── pane_body.gd
        ├── code_viewer.gd
        ├── file_tree.gd
        └── observer_pane.gd
```

## Key Bindings

### Terminal

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+C` | Copy selection |
| `Ctrl+Shift+V` | Paste from clipboard |
| `Ctrl+F` | Toggle scrollback search |
| `PageUp` / `PageDown` | Scroll through history |

### Workspace

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+N` | Spawn terminal |
| `Ctrl+Shift+C` | Spawn code viewer |
| `Ctrl+Shift+T` | Spawn file tree |
| `Ctrl+Shift+O` | Spawn observer |
| `Ctrl+Shift+W` | Close focused pane |
| `Ctrl+Shift+B` | Toggle sidebar |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+Shift+R` | Reset workspace |
| `F11` / `Ctrl+Shift+M` | Toggle fullscreen |
| `Alt+←↑↓→` | Jump to adjacent pane |

> **Note:** `Ctrl+Shift+C` copies when text is selected in a terminal; otherwise spawns a code viewer.

## Sidebar

- [+ Terminal] — spawn a new terminal
- [Settings] — open global settings panel
- [Reset] — clear all terminals and layout

Layout is auto-saved on close and auto-restored on startup via `user://layout.json`.

## Command Palette (Ctrl+P)

Type partial commands: `new`, `close`, `settings`, `reset`, `save`, `load`.
