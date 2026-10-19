# gPTY UI/UX assessment

Date: October 19, 2026. Build: v0.5.6 (commit 97eec6b), Godot 4.7.2, Linux, 1920x1080.
Focus requested: visual polish and ease of use. Priority order: first launch, navigation, settings, visual polish, panes, content.

This report is preserved as the 2026-10 baseline. It predates the v0.6.0 wiki work, the pane close contract and the v0.7.0 media pane, so the v0.8.0 roadmap re-runs the method on a current build before any fix is planned against a stale capture (see `ROADMAP.md`, "Re-baseline the audit on the 0.7.0 build").

## Method

- Ran the real app (the actual main scene, autoloads and Rust extension) in a private sandbox with a fresh first-run state, so no existing settings or layouts influenced it.
- Drove it with synthetic clicks and key events from a scratch script and saved the app's own rendered viewport as PNGs (`raw/`). Nothing from the desktop was captured.
- Read the UI code to explain what the screenshots show and to count hard-coded styling.
- Contrast ratios are WCAG calculations from colour constants in the code or sampled pixels.
- Small windows (800x500, 560x340) were rendered in an embedded viewport, because the real window would not resize. Treat them as accurate for layout, not for OS window behaviour.
- No project files were modified.

## Verification levels

- **Verified**: reproduced in the running app, with a control where one mattered.
- **Observed**: seen in the running app, but only once or without a control.
- **Code**: read in the source, not exercised.

## Findings

### P1 - loses input or work

**UX-01 First terminal is not focused at launch; first keystrokes are dropped.** Verified.
After a fresh launch there is no active pane (`last_body` is null) and no focus owner. Typing `echo typed_without_click` produced nothing in the terminal. The control run (click the pane, then type the same text) put the text at the prompt. `gpty list-panes` also reported `FOCUS false` for the lone pane after launch in an earlier live run.
Fix: call `activate_pane()` on the first pane after the workspace is restored or built. Effort: S.

**UX-02 Reset, and closing panes, kill running terminals with no confirmation or undo.** Verified (Reset); Code (close, quit).
A shell with `sleep 600` typed into it was removed by one click on Reset, with no dialog. In code, only the Wiki pane implements `request_close` (the confirm hook); terminals never ask. The destructive red Reset button sits directly under Settings at the same size, and `Ctrl+Shift+R` triggers it with no confirmation. Note: I confirmed the pane was removed immediately; I did not separately confirm `sleep` was still alive at that instant.
Fix: have terminals confirm when a foreground process other than the shell is running, or confirm Reset whenever any pane exists. Rename Reset to "Close all panes". Effort: M.

### P2 - friction or visible breakage

**UX-03 An empty workspace shows the engine's default grey, with no empty state.** Verified.
After Reset (or closing the last pane) the whole content area is `rgb(76,76,76)`, Godot's default clear colour. It matches nothing else in the app and says nothing about what to do next.
Fix: set the project clear colour to the app background and show a centred empty state ("No panes. Ctrl+Shift+N for a terminal"). Effort: S.

**UX-04 Command palette: five separate problems.** Verified unless noted.
- It never takes focus when opened: keys typed right after `Ctrl+Shift+P` went nowhere. Cause (Code): `find_child("*", true, false) as LineEdit` in `_toggle_palette` returns the first descendant, which is a container, so the cast gives null and `grab_focus()` never runs.
- It opens empty: the list only fills after you type.
- Observed: once the field has focus, Escape no longer closes it.
- Code: Enter only runs the first match; there is no arrow-key selection.
- Entries are raw lowercase strings with no shortcuts or icons, and include a developer command, "spawn 16 terminals", plus ambiguous "save" and "load".
Fix: find the `LineEdit` by type, populate on open, handle Escape inside the field, add up/down selection, show shortcut hints, hide developer commands. Effort: M.

**UX-05 Settings and Pane Settings panels are translucent, and the Environment field is crushed.** Verified.
Both are built from a bare `Panel`, which uses Godot's default semi-transparent panel style. In Pane Settings the pane behind (the "Media" icon, "Reload", the Inspector prompt) bleeds through the form. The Environment box is squeezed to one line with a horizontal scrollbar. The panel also shows an internal `Attachment ID: pane-njmjn612` with no explanation.
Fix: give both an opaque `StyleBoxFlat` and a minimum height for the Environment box. Effort: S.

**UX-06 Overlays and titles do not adapt to small windows.** Verified in the embedded 800x500 and 560x340 renders.
At 800x500 the Settings panel spills left over the sidebar. At 560x340 it is clipped and overlaps the pane titles. Pane titles run underneath their own buttons, and the sidebar pane list is cut off after the first row.
Fix: size panels relative to the viewport, ellipsise titles, and let the sidebar scroll as a whole. Effort: M.

**UX-07 Stock Godot dialogs clash with the app.** Verified (Save Profile); Code (the rest).
There are 17 `ConfirmationDialog` or `AcceptDialog` constructions and no project theme, so they render in default Godot grey. The Save Profile dialog also clips its command fields to `/bin/ba` and uses the jargon "Pane commands (edit to customize)".
Fix: a theme that covers `Window`, `AcceptDialog` and `ConfirmationDialog`; widen the fields. Effort: M (largely free once UX-08 lands).

**UX-08 No shared theme, small type, and two contrast failures.** Code plus calculation.
- 160 `add_theme_*_override` calls, 41 hard-coded `Color(...)` literals and no `Theme` resource.
- Font sizes used: 10, 11, 12 (43 uses), 13, 14, 16, 18 and 36.
- Status bar right-hand text: 4.15:1 at 11 px, below the 4.5:1 needed for small text.
- Reset red on the sidebar: 3.49:1 at 16 px, also below 4.5:1.
- No UI scale or HiDPI setting was found. On a 4K display the 11-12 px text will be very small. I did not test a 4K display.
Fix: one `Theme` resource plus a handful of size and colour tokens, and a UI scale setting. Effort: L, but it unlocks UX-05 and UX-07.

**UX-09 Discoverability.** Verified (visual); Code (shortcuts).
- "Add Pane" is a grid of glyphs (`>_ {} /> @ ? $_ [] |>`); the names are visible only in tooltips.
- The window-mode dropdown at the top reads just "OS", and nothing says what the other values do.
- The palette shortcut (`Ctrl+Shift+P`) and most other shortcuts appear nowhere in the UI except some tooltips.
Fix: show names beside the icons or a short first-run hint, label the dropdown, and add a shortcuts list under Settings or About. Effort: S-M.

### P3 - polish

**UX-10 One icon, three meanings.** Verified. The counter-clockwise arrow is Reset (destructive) in the sidebar, "Change pane type" on every pane row and title bar, and "reset to default" on every Appearance row. Give them distinct icons.

**UX-11 Dense per-pane controls.** Verified. Each pane has five 24x31 px icon buttons in the sidebar row, and the same set again in its title bar. Consider keeping close and settings visible and moving the rest into a menu. The type-swap menu also does not mark the current type.

**UX-12 Pane content has no inner padding, and empty states are inconsistent.** Verified. Inspector, Reasoning and Code Viewer text touches the pane edge. Code Viewer's empty state is only a faint "Reload", while Wiki and Media explain what to do. Use the Media and Wiki empty states as the model.

**UX-13 The search bar covers the prompt line and shows no match count.** Observed. Matches are marked by a thin gold bar at the left of the line. I saw no visible count or next/previous controls.

**UX-14 Toasts are faint and mostly state the obvious.** Observed ("Terminal spawned", "Inspector spawned").

**UX-15 Appearance tab swatches show checkerboards with no explanation.** Verified. Unset colours look like broken swatches.

## What works well

- Terminal rendering is crisp and colours are correct (see `raw/07_one_terminal_with_output.png`).
- The Phosphor icon set is used consistently, and the accent blue for the active row is the same across workspace, profile and pane lists.
- Sidebar rows have measured heights, ellipsise long names, and support inline rename by double-click.
- The status bar shows the active pane's type and name, and profile activation gives clear feedback.
- Wiki and Media empty states say exactly what to do.
- There are 39 tooltip assignments, so icon-only buttons are at least explained on hover.

## Suggested order

1. UX-01, UX-03, UX-05 (small changes with visible payoff).
2. UX-02 and UX-04 (trust and flow).
3. UX-08, then UX-07 and UX-06 (theme work that fixes several findings at once).
4. UX-09, then the P3 items.

## Not examined

- Vault graph view, concept graph editor, and the Wiki pane with a real vault.
- Plugin review and workspace-trust dialogs (code only).
- The CRT shader and any animation or motion.
- Keyboard-only traversal and focus rings, screen readers and colour-blind use.
- Real OS window resizing, 4K/HiDPI, Windows and macOS.
- Real users.

## Side note

Every launch logged "Unicode parsing error ... Unexpected NUL character" six times. I did not trace its source and have not treated it as a UX finding.

## Files

- `annotated/` - nine screenshots with numbered boxes matching the findings above.
- The raw, unannotated captures were produced in the audit's scratch checkout and are not part of this repository; the annotated set carries the numbered evidence.
