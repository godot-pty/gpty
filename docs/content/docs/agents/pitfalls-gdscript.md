---
title: "Pitfalls: GDScript & UI"
weight: 81
---

Curated traps, subtle engine behaviors, and invariants for Godot 4.7+ and GDScript development.

## Theming, Styling & Colors

- **Pressed-state text color ignores `font_color`:** A toggle-mode `Button` resolves text from `font_pressed_color`, which falls back to the theme default and silently ignores `font_color`. Use a type variation role (e.g., `UiTheme.ACCENT_BUTTON`), which defines `font_color`, `font_hover_color`, `font_pressed_color`, and `font_focus_color` together in the theme.
- **ScrollBar thickness is derived from content margins:** Godot derives `ScrollBar` thickness from the track stylebox's content margins plus padding constants (`VScrollBar.padding_left`/`padding_right`), while the grabber stylebox margins only determine thumb minimum length. An empty track (`StyleBoxEmpty`) creates a 0 px bar with no column reserved. Geometry is theme-owned (`UiTokens.SCROLLBAR_THICKNESS`/`SCROLLBAR_INSET`/`SCROLLBAR_MIN_THUMB`).
- **Embedded Window frame uses default theme:** `Window/embedded_border` and `embedded_unfocused_border` have no effect in Godot 4.7.2. An `AcceptDialog` lays out every direct child Control over the same content rect (requiring a single root `VBoxContainer`), and its internal `dialog_text` keeps rendering until hidden. `AppDialog` builds borderless modals with custom headers.
- **A per-surface `modulate` is not a translucent window:** `Window.transparent`/`transparent_bg` plus a `Workspace.modulate` alpha makes every stacked surface blend again instead of fading the finished window - the terminal's row backgrounds, its ground and the window ground compounded to framebuffer alpha **0.992** at a 70 % setting (measured 2026-11-20 on 4.7.2). A whole-window alpha is one post-pass: `godot/shaders/window_opacity.gdshader` samples a `BackBufferCopy` placed above every app surface, and `render_mode blend_disabled` writes the sample renormalised to the setting's alpha; `Workspace.apply_window_alpha` hides the copy and the veil at 100 %, so an opaque window pays nothing. Embedded dialogs, file pickers and popup menus draw after the canvas and stay opaque.
- **Window transparency needs `transparent_bg` and a real display to prove it:** with it off, a written 0.5 alpha read back **0.333** (the channel is not 8-bit); the headless display server refuses `Window.transparent` even when it is set directly, so a GUT test asserts the viewport/veil half and the window flag is proven on a headed run. `project.godot` must also set `display/window/per_pixel_transparency/allowed`, or the engine answers `is_window_transparency_available()` false even on a renderer that supports it.
- **Palette reads in initializers freeze mode:** An `@export var c: Color = UiPalette.active().X` evaluates once at definition time and freezes whichever theme mode was active at construction. Read colors at draw time or use `Theme` type variations. `scripts/check-theme-tokens` fails class-body `UiPalette.active()` reads and `add_theme_color_override`.
- **Ancestor theme resolves only after entering the tree:** A script probe setting `host.theme = UiTheme.build()` and checking `get_theme_stylebox("panel")` in the same frame gets Godot's default theme. Await one `process_frame` first for variation lookup to resolve.
- **Phosphor glyph `Label` instantiation cost:** In Godot 4.7.2, `add_child` of a `Label` carrying a Phosphor PUA codepoint costs 3.3–3.5 ms (vs. 0.09 ms for ASCII), and re-assigning `text` on an attached label costs ~0.00 ms. Update labels and glyphs in place; avoid recreation during workspace or tab switching.

## Node Hierarchy, Sizing & Viewports

- **`extends Node` cannot render `Control` children:** Only `Control` nodes render child `Control`s (`Label`, `Button`, etc.). A `Label` parented to a plain `Node` is completely invisible. Containers must extend `Control`.
- **Textless Buttons collapse without explicit minimum width/height:** Godot does not derive a `Button`'s minimum size from child Controls. A button that carries an icon+text `HBox` instead of native `text` needs an explicit `custom_minimum_size.y`.
- **Width floor inside scroll children freezes layout:** Setting `custom_minimum_size.x` on a `RichTextLabel` inside a horizontal-scroll-disabled `ScrollContainer` propagates upward and prevents shrinking. The container must own width; sync only height from `get_content_height()` and re-run on `resized`.
- **`TabContainer` font size ownership:** The internal `TabBar` inherits font size overrides from the `TabContainer` theme item, not `TabBar`. Set `font_size` on both. A tab hidden by an overflow reports a zero-based rect from `get_tab_rect()`; calculate total width by summing rect widths sequentially.
- **`Tree` does not expand on double-click by default:** `TreeItem` defaults to `collapsed = false`, and double-clicking emits `item_activated` without auto-toggling. Code that populates rows on first activation and immediately toggles `collapsed` collapses the newly populated folder.
- **3D `SubViewport` in a pane:** Sizing is `(0, 0)` on the frame the first graph is shown; units-per-pixel calculations must use the Control's height as a fallback. An `ImmediateMesh` surface is committed only on `surface_end()`. Clear `SubViewportContainer` visibility pauses (`_hidden_paused`) on the visible branch.
- **Reparenting fires `_exit_tree`:** `Node.reparent()` removes and re-adds the node. Subsystems that stop backends on tree exit (`cli_view`, `media`, `inspector`) must check `PaneBody.backend_preserved` across workspace moves.

## Focus, Keyboard & Input Handling

- **Focus traversal visits disabled buttons:** `find_next_valid_focus()` filters `FOCUS_NONE` and invisibility, but not `disabled`. A toolbar whose buttons disable must set `focus_mode = Control.FOCUS_NONE` on disabled items, or Tab navigation will land on them.
- **Input bubbling in Godot 4.7.2:** `_gui_input` does not bubble to ancestors. An input-stage handler (`_input`) with `gui_get_focus_owner()` checks is required to handle global shortcuts like Escape without relying on container bubbling.
- **Terminal consumes keyboard:** A focused `TerminalPane` consumes all keystrokes in `_handle_keyboard`. Overlays must capture keyboard ownership on open, and handle Escape before GUI input.
- **Z-Index does not affect Control picking:** Godot GUI mouse picking checks reverse tree order (last sibling first), ignoring `z_index`. Overlays must call `move_child(overlay, -1)` on open to ensure they receive clicks ahead of earlier siblings.
- **Tooltip mouse filters:** Viewport tooltip lookup skips controls whose `mouse_filter` is `IGNORE` (the default for `Label` and `RichTextLabel`). Controls showing tooltips must set `mouse_filter = Control.MOUSE_FILTER_STOP` or `PASS`.

## GDScript Syntax, Lifecycles & Typing

- **No NUL character in strings:** A `\u0000` literal decodes as `\uFFFD` and triggers unexpected NUL character errors at load time. Never use NUL characters for string splitting or composite map keys; use nested dictionaries or structured objects.
- **`:=` inference fails on untyped Variant:** `var x := ws._palette._field` produces a parse error because reading a property on a `Variant` base yields `Variant`. Explicitly type the variable: `var x: LineEdit = ws._palette._field`.
- **Typed arrays (`Array[T]`):** A typed parameter `func f(arr: Array[Control])` rejects a plain `Array` at call sites. Furthermore, `Array[Dictionary]` rejects across the Rust GDExtension boundary; always pass untyped `Array` to Rust.
- **String format operator `%` with arrays:** `"...: %s" % changed` where `changed` is an `Array` treats the array as the format argument list. If the string has only one `%s`, it raises a format error for arrays with >1 element. Wrap with `% str(changed)` or pass explicit tuples.
- **Default arguments evaluate at script load:** `func f(x := some_var)` captures `some_var` at definition time, not call time. Use sentinel defaults (`func f(x := -1)`) and resolve dynamic values in the function body.
- **Reference cycles in `RefCounted`:** If object A stores object B and object B stores object A, neither is freed on exit. Use `WeakRef` on the owned child and bind methods directly instead of capturing parent instances in closures.
- **Autoload callable references:** Publishing an inline closure `ShortcutManager.overlay_owns_keyboard = func(): ...` captures the enclosing node. When the node is freed, the callable points to dead memory. Reset callbacks in `_exit_tree()`.
