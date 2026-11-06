---
title: gpty v0.8.0
date: 2026-11-06
---

v0.8.0 is the release where the interface became the project's own. An audit re-run on a fresh 0.7.2
build found all nine of its findings still open, so this release commits the harness that takes the
evidence and then builds the foundation the rest of the 0.8 chain stands on: one theme grown from one
token module, a light palette that follows the desktop, a UI scale that cannot push the layout under
itself, and screen-reader accessibility the app maintains rather than a flag someone else set. The
chrome stops being mouse-only too - pane buttons, the Wiki pane and the vault link graph are all
reachable from the keyboard, and an overlay that is open finally owns the keyboard.

Nothing in the PTY engine, the IPC surface or the control API changes behaviour.

<!--more-->

![A fresh launch on v0.8.0](/images/v0.8.0_1.png)

**The interface has one source of truth.** Every colour, size and spacing step in the chrome now comes
from `ui_tokens.gd` and `ui_palette.gd` through one `Theme` applied at the scene root, so a pane, an
overlay, a popup and a dialog cannot drift apart. The type scale is seven steps, spacing is seven
steps, and one 22×18 px target is the floor for every icon-only button - which is why a pane title bar's
five actions and the sidebar's trailing glyphs finally agree on a size.

Colours are measurable now, not argued about: `UiPalette.CONTRAST_PAIRS` lists every foreground
against the surface it is drawn on, and the palette's unit test fails the build when a pair drops
under 4.5:1 in either set. Close All on the sidebar went from 3.49:1 to 6.75:1, the status bar's
right-hand readout from 4.15:1 to 6.35:1. The gate that keeps the rule from rotting is
`scripts/check-theme-tokens`: a colour override or a palette read at class-body level fails CI unless
the line carries a reviewed `# theme-ok:` reason.

**A light theme that follows the desktop.** `UiPalette` carries two complete sets - 18 tokens each -
and `Appearance` picks dark, light or system. The system setting resolves through the engine's
theme-change callback, so flipping the desktop's dark mode re-themes gPTY without a restart. The
terminal keeps its own scheme; only the chrome moves, which is what makes a light chrome over a dark
terminal readable instead of muddy.

![The light chrome over four panes](/images/v0.8.0_2.png)

![Settings on the Appearance tab, in the light theme](/images/v0.8.0_3.png)

**The scale is a setting, and it knows its own limit.** `UI scale` applies a factor to the whole
interface - chrome and terminal text together. A scale can also push the layout under the smallest
space the chrome is designed for (the Settings card is 540×560), so the app caps what it applies at
the window's own size and says which percentage it is actually showing when the cap bites. At 800×500
a 125 % request now lands at 100 % instead of clipping.

![The interface at 125 %](/images/v0.8.0_4.png)

**The keyboard can reach the chrome.** The pane title bar's five buttons, the Wiki pane's note toolbar
and the link graph's canvas and three actions are explicit traversal rings rather than leftovers of
tree order - the graph canvas draws its own accent focus frame because a custom-drawn `Control` has no
stylebox to do it, and arrows pan it while `+`/`-` zoom about the crosshair. Measured with
`scripts/ui-capture --audit-focus` on the wiki state: 83 of 83 focusable controls reached, where the
old walk printed 5. An open overlay takes focus, keeps the keyboard from the shell behind it, returns
focus on close, and lets exactly four window chords through (the palette, the sidebar, and the two
fullscreen toggles).

**Accessibility is a surface, not a flag.** `A11y` names every control at the choke point - a glyph
button cannot be built without its words - publishes terminal output as a live region, and leaves an
unchanged line's node alone so a reader is not thrown out of it every second. `scripts/accessibility-probe`
proves the tree actually arrives: it emulates a screen reader on the session bus, launches the app with
the AccessKit driver, walks the AT-SPI registry and asserts the controls this repo named are in it.

**One frame for every dialog, including the file picker.** Nineteen `ConfirmationDialog`/`AcceptDialog`
sites are built by `AppDialog`, with buttons grouped at the right edge instead of scattered 290 px
apart, and text a user must read or copy in a selectable body - so a path containing `[b]` cannot be
read as markup. Godot's `FileDialog` was the last surface still wearing the engine's grey title band;
it now carries a header of the app's own with a close control wired to the picker's cancel.

![The workspace-directory picker](/images/v0.8.0_5.png)

**The badges spell their state.** `failed` and `needs-attention` used to be the same circle, told
apart by red against amber - unreadable to a protan or deutan user and invisible to a screen reader.
They are an X-circle and a warning triangle now, each named and tooltipped, and `completed` and
`working` complete the four.

![The four agent-state badges](/images/v0.8.0_6.png)

**Evidence you can re-run.** The audit's method is a committed driver now: `godot/tests/bench/ui_capture.gd`
stages 21 named states through the real main scene and writes each one's PNG from the app's own
viewport, `scripts/ui-capture --audit-focus` prints what keyboard traversal reaches, and
`scripts/ui-capture-check` proves a state's capture is local to that state. All of it runs inside
`scripts/ui-sandbox`, a private home, runtime directory and control socket, so a capture never
depends on the developer's desktop - and every image in this post came out of it.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.8.0).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.8.0.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
