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
    ├── profiles.default.json    # Shipped seed layouts (Agent Workspace, Knowledge Base)
    ├── fonts/                   # Bundled fonts (DejaVu Sans Mono + Phosphor icons)
    │   ├── DejaVuSansMono.ttf
    │   ├── DejaVuSansMono-Bold.ttf
    │   ├── DejaVuSansMono-Oblique.ttf
    │   └── Phosphor-Regular.ttf
    ├── scenes/
        ├── main.tscn            # Root scene (Workspace)
        ├── autoloads/           # 15 singleton managers
        │   ├── base_persistence_manager.gd  # Shared JSON I/O base
        │   ├── settings_manager.gd
        │   ├── profile_manager.gd
        │   ├── concept_manager.gd
        │   ├── workspace_store.gd  # Named workspace (tab set) persistence
        │   ├── pane_env_store.gd   # User-owned per-pane env, keyed by attachment_id
        │   ├── pane_inspector_store.gd # User-owned Inspector aim (prompt + switches), keyed by attachment_id
        │   ├── trusted_store.gd    # Workspace Trust consent memory (builtins + plugins)
        │   ├── link_weights_store.gd # User-owned declared link weights (display-only)
        │   ├── saved_command_store.gd # User-owned saved commands (name / one line / run flag), in palette order
        │   ├── vault_registry.gd   # User-owned vault roots the socket's vault verbs may read
        │   ├── focus_manager.gd
        │   ├── toast_manager.gd
        │   ├── shortcut_manager.gd
        │   └── update_checker.gd
        ├── terminal/            # Core terminal logic
        │   ├── workspace.gd     # Grid layout, workspace tabs, sidebar, profiles, concept routing
        │   ├── ipc_handlers.gd  # WorkspaceIpcHandlers - IPC/pane-API method dispatch
        │   ├── terminal_pane.gd # Control-based renderer, keyboard, selection
        │   ├── terminal_fonts.gd # Byte-only font loader (a data path never reaches load())
        │   ├── concept_router.gd # Pure concept-event routing (extracted, testable)
        │   ├── plugin_review_text.gd # Pure plugin-review dialog text (extracted, testable)
        │   └── terminal_manager.gd
        ├── ui/                  # UI components
        │   ├── sidebar.gd       # Vertical stack: window mode, workspaces, panes, profiles
        │   ├── settings_panel.gd
        │   ├── overlay_panel.gd  # Shared keyboard contract for the four overlays
        │   ├── command_palette.gd # Ctrl+Shift+P command list (OverlayPanel)
        │   ├── palette_model.gd # Palette entries, matching and ranking (pure)
        │   ├── shortcut_catalog.gd # The About tab's keyboard-shortcut list as data (chords from the binding registry)
        │   ├── shortcut_guide.gd # The empty workspace guide: clickable live keycap + every binding (data-driven)
        │   ├── keyboard_focus.gd # Keyboard-entry walk + the toolbar-ring pair (overlay focus, pane content, chrome/note toolbars)
        │   ├── concept_graph_editor.gd # Visual rule editor overlay (GraphEdit)
        │   ├── concept_graph_model.gd  # Pure canvas/build/validate/compile logic
        │   ├── vault_graph_model.gd    # Pure vault link-graph normalize/layout/hit-test
        │   ├── vault_graph_view.gd     # Custom-drawn link-graph canvas (pointer + keyboard, focus ring)
        │   ├── link_weights.gd         # Pure declared-weight vocabulary (paths, range, lookup)
        │   ├── ui_palette.gd   # The chrome colours in two complete sets (dark/light) and the active one
        │   ├── color_swatch.gd # The words a colour swatch carries: opacity reading, "unset", tooltip
        │   ├── ui_tokens.gd    # Type scale, spacing, radius and the WCAG contrast maths
        │   ├── ui_theme.gd     # The one Theme, built from the palette and applied at the root
        │   ├── app_dialog.gd   # The one modal builder (theme, grouped buttons, selectable body)
        │   ├── menu_items.gd   # The one native PopupMenu item builder (icon + text + tooltip + metadata)
        │   ├── section_help.gd # The shared "Help" affordance a section header carries (glyph → action → chord table, rows read on press)
        │   ├── scroll_hints.gd # The two scroll chevrons a pane overlays on its scrolling body (bar, tree or custom binding)
        │   ├── feedback_text.gd # Pure Feedback issue title/body/URL builder (build facts only, capped)
        │   ├── accessibility.gd # Accessible surface owner: names, values, published text (see docs agents/gdscript.md)
        │   ├── a11y_content.gd # A published content node: a Control that writes its own accessible role
        │   ├── agent_badge.gd  # Title-bar agent-state badge: the four silhouettes, painted
        │   ├── toast_overlay.gd
        │   ├── window_chrome.gd # Titlebar + window-mode/fullscreen handling
        │   ├── markdown_view.gd # Safe shared Markdown renderer
        │   ├── markdown_anchors.gd # Pure ATX heading scan for fragment/line navigation
        │   └── icons.gd         # Phosphor icon constants
        └── panes/               # Specialty pane types
            ├── pane_body.gd
            ├── pane_types.gd    # Pane registry, sanitizers
            ├── backend_choice.gd # Inspector backend vocabulary (aliases, dropdown rows)
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

    └── tests/                   # GUT suite and display drivers
        ├── unit/                # Pure-logic tests
        ├── integration/         # Scene-tree tests
        ├── helpers/             # Shared fixtures (ShellFixtures, MockAutoloads)
        └── bench/               # Cost and capture drivers (need a real display)
            ├── draw_bench.gd    # Terminal renderer cost
            ├── markdown_bench.gd
            ├── reasoning_bench.gd
            ├── switch_bench.gd  # Workspace-switch cost: sync call, mode, first frame
            └── ui_capture.gd    # Committed UI state staging -> viewport PNGs
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
- [More (⋯) on a workspace row] - the workspace menu: **Set Directory** (that workspace's default directory; every terminal spawned there, including one activated from a profile, starts in it, and `Use default` clears it; changing it asks when the workspace holds a pane that names its own program) and **Clear Workspace** (close every pane in it, asking first; a hidden workspace is cleared without switching)
- [Trash on a workspace row] - close that workspace. The last workspace can be closed, leaving the zero-workspace guide; the first pane created there makes the **Default** workspace
- [Trash on the Workspaces: / Panes: title rows] - close every workspace / every pane in the active workspace. The row swaps to a check/cross first; the running-work prompt follows the check
- [Trash on a pane row or its title bar] - close that pane. The sidebar row asks check/cross first; the title bar closes immediately, still asking about running work and unsaved edits
- [Profile row] - the name activates that layout in the current workspace (it asks before replacing panes); the arrow button opens it in a new workspace named after the profile and leaves the current one untouched
- [Trash on a user profile row] - deletes it immediately. The two shipped layouts are copied into your user profiles on first launch, so Agent Workspace and Knowledge Base use this same trash; a deleted copy is not restored
- [Trash on a plugin profile row] - uninstalls the plugin after check/cross, removing every profile and concept it ships. Plugin rows have no rename. Saving or renaming into an existing user-profile name asks **Replace Profile?** first, and an install whose profile name collides names the replacement in its review

Layout is auto-saved on close and auto-restored on startup via `user://layout.json`.

The two shipped layouts are seeded into `user://profiles.json` on first launch and
are ordinary user profiles afterwards: **Agent Workspace** opens a normal terminal
plus separate Inspector (private Q&A) and Reasoning (passive agent thinking)
panes, and **Knowledge Base** opens the bundled wiki. The five tool presets -
herdr, lazygit, nvim, claude, and OMP - live in plugin repositories now, each
restoring one full-screen terminal running that tool; Agent Workspace and
Knowledge Base are also published as plugins for a fresh install or a reinstall.
None of them install the OMP extension or launch `omp`; the user does that in
the terminal. Inspector does not follow the terminal conversation. Reasoning
requires the `@gpty/omp-events` extension and gpty's Unix event socket
(`gpty-events.sock`); it is not available on Windows builds yet.

## Command Palette (Ctrl+Shift+P)

Type partial commands: `new`, `close`, `settings`, `close all`, `save`, `load`.
