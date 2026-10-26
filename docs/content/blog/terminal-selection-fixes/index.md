---
title: The screen is not the document
date: 2026-10-26
---

Two bugs reported from daily use had one wrong idea behind them: that where a cell appears on
screen is where its text lives. One made the copy shortcut jump a scrolled-back pane to the
bottom; the other let the highlight drift onto different text. Both are fixed and will ship in
the next release.

<!--more-->

To reproduce either on v0.7.0: scroll a pane back, drag-select a line, then press `Ctrl` or
`Shift` on the way to `Ctrl+Shift+C`. The view snaps to the cursor row, and the highlight ends up
covering whatever text now sits on those same rows. The selection did not move. The screen did.

## The shortcut that went to the bottom

The cause was a single unconditional line in the key handler: every key that was not
`PageUp`/`PageDown`/`Enter`/copy/paste called `scroll_reset()`, which sets the viewport offset to
zero. A bare modifier sends nothing to the child process, so the pane had no reason to move - but
it did, because "handle a key" and "show live output" had been written as the same event.

### Why it looked fixed once already

Half of this was fixed on 2026-08-13 (`81feaf3`): pressing `Ctrl` used to clear the selection
outright, so a copy from scrollback died at the first modifier press. That change moved the clear
into the branches that actually deliver input, and left the selection alone for bare modifiers.
What it did not touch was `scroll_reset()`, which had the same unconditional shape.

That is why the symptom seemed to come back. The selection now survived the chord, the screen
still jumped to the bottom, and because the selection was stored in screen rows - the second bug
below - the highlight then covered whatever text had arrived underneath it. Nothing reintroduced
the jump: `git log -S` dates the unconditional call to the initial commit (`dfe9f82`). It had only
become visible.

The reset now lives in the branches that send input to the child - keymap bytes, printable
unicode and `Enter`, through a small `_snap_to_bottom()` seam. Bare modifiers, `PageUp`/`PageDown`,
the copy and paste chords and the search toggle no longer move the view; typing and `Enter` still
return to live output, where the echo is about to appear. The change also removes a grid-mutex FFI
call and a generation bump that every keypress was paying for.

## The highlight that did not move with its text

The selection was stored as viewport cells (`_sel_start`/`_sel_end`), and both the painting and
the copy read those rows straight out of the paint cache - a snapshot of the visible screen.
Anything that moved the viewport desynchronised it: the wheel, `PageUp`/`PageDown`, a search jump,
output arriving at the bottom, and the modifier jump above. The highlight stayed on its rows, so
the copy took different text. This had never been fixed separately; it was the other half of the
same assumption, and the 2026-08-13 change made it the visible failure.

The tempting one-line fix - store `row - display_offset` and add it back when drawing - does not
hold. alacritty's line indices are not stable content identities: when output scrolls the screen,
the same text moves to a lower line index while `display_offset` is raised to keep a scrolled-back
viewport pinned. A saved line therefore drifts by the amount that scrolled. Worse, rows scrolled
out of the viewport are not in the pane's cache at all, so a copy of an off-screen selection had
no text to read.

The selection now lives in the grid, where alacritty already keeps one and rotates it whenever
the grid scrolls (and on resize): `alacritty_terminal::Term::selection`, exposed through
`selection_start`/`selection_extend`/`selection_clear`. The pane keeps only a projection for
drawing - `get_selection_cells` maps each selected grid line back with
`screen_row = grid_line + display_offset` - and copy reads `get_selection_text` from the grid rows.
A selection scrolled out of the viewport has no highlight, but it copies in full.

The edges were kept deliberate: the drag is cell-granular and inclusive at both ends, and the drag
anchor is read back from the live range so output rotating under a held button cannot skew it.
Copying joins wrapped lines instead of inserting a newline at each wrap, and the selection is
dropped when the terminal's width changes or an application switches to the alternate screen -
alacritty's rule. The old screen-space highlight survived both and silently landed on other text.

## What it does now

- `Ctrl` and `Shift` do not move a scrolled-back pane; the copy chord works on what you selected.
- Scrolling, searching and new output move the highlight with its text.
- Copy includes rows that scrolled out of view.
- Typing or `Enter` still returns the view to live output.

## How it was checked

Four new tests in `gpty-core` drive the grid directly: a view scroll with output while scrolled
back, output at the bottom scrolling the screen, copying rows out of the viewport, and a rotation
while the drag anchor is held. The GUT suite (62 scripts, 796 tests) covers the pane routing,
including a modifier press that neither clears the selection nor snaps the view. A throwaway live
smoke ran the reported flow against a real shell - 120 lines of scrollback, a real mouse drag,
`Ctrl`/`Shift`, wheel up and down, output arriving while scrolled back, then the copy chord - 22
assertions, all green, file deleted afterwards. The full `./scripts/ci-check` (fmt, clippy,
FFI-surface parity, GUT, the live pane-API smoke and `cargo audit`) passes on the final tree.

One documentation fix rode along: the manual test checklist told testers to copy with
`Ctrl+Shift+V`, which pastes.

## Still missing

There is no one-click way back to live output yet. That affordance - a floating chevron shown only
while the pane is scrolled back, which must not clear the selection or be reported to a TUI that
owns the mouse - is queued in
[the v0.8.0 roadmap](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/roadmap/v0.8.md).

Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty). The next release's
changelog will name these fixes.
