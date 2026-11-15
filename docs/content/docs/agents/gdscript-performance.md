---
title: "GDScript performance"
weight: 31
---

GDScript is an interpreter in front of a C++ engine. The expensive work is not usually the
`draw_*` call - it is the per-element loop that builds the arguments, the node construction around
it, the allocation per cell, and the cross-FFI call per item. This page is the method for finding
and proving one of those costs, and the rule for deciding whether the work belongs in Rust.

## The sweep

Two committed tools, run by hand:

- `scripts/gdscript-audit` - a **report**, not a gate. It parses every `godot/scenes/**/*.gd` file
  into functions (indentation, inner classes included), tags loop context, and ranks literal cost
  atoms: a typed `String` indexed per element, a String append in a loop, an eager Dictionary
  default, a NodePath lookup, a group scan, `Image.create_from_data`, node construction,
  `get_string_size`, JSON in a loop, `range`, a theme read, a container write in a loop, a fresh
  `RegEx`, `await` on `_process`/`_draw`, and `duplicate`. `--top N` (default 40; `0` = all)
  bounds the output, `--hot` keeps functions named for frame/event work, `--json` is
  machine-readable. It exits 0 with findings; it is deliberately not in `ci-check` and has no
  allow-marker convention, because a heuristic gate goes stale or noisy.
- `godot/tests/bench/gdscript_probe.gd` - the idiom probe, headless:

  ```
  godot --headless --path godot -s res://tests/bench/gdscript_probe.gd
  ```

  Median of five runs per case, no assertions. It measures the shapes the audit finds: String
  indexing plus append vs a native slice, an eager `{}` Dictionary default vs a plain get,
  `range()` vs integer iteration, font measurement, the palette read, Image creation vs reuse with
  the copy forced, the audio interleave, and a NodePath lookup vs a cached reference.

The audit is a floor, not a source of truth. It misses costs that are prose (a settings broadcast)
or cross-file (a per-frame caller of a cold-looking helper), and it reports cold setup as loudly as
a hot loop. Read the function it names, then prove the cost with a probe before changing anything.

## What costs, with the 4.7.2 numbers

Measured with the probe on the 4.7.2 `arch_linux` build, 2026-11-15:

| Shape | Measurement | Reading |
|---|---|---|
| String index + append | 87 ns per character (34,857 us for 2000 x 200 `line[c]` + `text += ch`) | A 12,000-cell terminal repaint pays ~1.0 ms in this loop; one slice per row was ~500x cheaper. Do not build a run one character at a time. |
| Node construction | A Phosphor glyph `Label` costs 3.3-3.5 ms to enter the tree; re-assigning `text` on an attached Label costs ~0 | Free-and-recreate row UIs cost milliseconds per row. Pool rows and update in place. |
| Per-pane FFI drains | 192 grid-mutex calls + 96 NodePath walks per frame at 96 panes (call chain) | A per-frame loop over every pane is the cost, not the individual call. Batch in Rust, or gate the scan on a change. |
| Audio interleave | 84.8 us per 2048-frame stereo chunk | 8 chunks in one frame is ~678 us. Return a `PackedVector2Array` from Rust instead. |
| Palette read | 0.314 us per `UiPalette.active()` vs 0.032 us for a local | Reading it once per draw is correct; reading it inside a per-match loop is not (10k matches would be ~3 ms). |
| Font measurement | 175 ns per `get_string_size` | 2000 labels on a graph open is ~0.35 ms; it is not a frame stall by itself. The per-redraw scans around it are. |
| NodePath lookup | 65 ns vs 27 ns for a cached reference | 96 per frame is ~6 us. Cache the body on the wrapper, but do not mistake this for the FFI cost. |
| `range()` | 13.3 ms vs 13.5 ms per 1M iterations | **Flat on 4.7.2.** The `range` atom is a candidate only; never optimize it without a profile. |
| `Dictionary.get(k, {})` | 0.133 us vs 0.095 us per get | The eager default is ~40% more per call; real in a loop, invisible once per frame. |
| `Image` creation | 0.13 us per 1280x720 image; 0.07 us for `Image.set_data`; 0.2 us with `get_data()` forced | The data is copy-on-write. The remaining per-frame cost is the texture upload (`ImageTexture.update`), not the `Image` object; reuse alone is not a measured win. |

The other shapes that show up in this tree:

- **Whole-buffer copies.** `String +` / `String +=` on a streamed turn, `_editor.text` on a large
  note, `replace("[", "[lb]")` on a rendered body: O(n) per event, and the event is per token or
  per keystroke. Keep pieces and join once at the display boundary.
- **Rebuild instead of diff.** A model change that tears down rows and rebuilds them pays node
  construction even when the row identity is unchanged. The pane list was fixed this way; check a
  new list for the same shape.
- **Repeated invariant reads.** `_cell_cache.get("cols")`, `_grid_offset()`, `get_ascent`, the
  active palette and the default font are cheap once and repeated per row, per label or per match.
  Hoist them out of the per-element loop; a palette read at the top of `_draw` is correct.

## Move it to Rust

Move work when it is a **pure data transform over bytes, strings or arrays**, scales with the data
rather than with the UI tree, and needs no Godot engine type. The boundary should be a batch: one
call per frame or per build, flat arrays in, flat arrays out. A new FFI call per item is worse than
the GDScript loop it replaces.

The accepted shapes in this tree:

- the vault graph's parse, pair aggregation, layout, hit-test and label cull over the index's own
  answer (`PackedVector2Array` positions, one call per build);
- the media audio interleave over the decoded sample buffer (`PackedVector2Array`, one call per
  chunk batch);
- the per-pane concept/agent drains, which are already Rust queues behind a per-pane FFI accessor -
  one registry drain per frame with session-tagged envelopes.

What stays in GDScript:

- **All drawing** (`draw_rect`/`draw_string`/`draw_line`, the row layers, repaint granularity);
- **node wiring and layout** (panels, sidebars, dialogs, tile geometry, font metrics, theme
  resolution);
- **bounded configuration work** (settings sanitizers, pane-type validation) that runs per spawn or
  per save.

Rejected examples, so they are not re-proposed without new evidence: the text reader's UTF-8 cut
(the read/slice/decode is native; the GDScript part walks at most three continuation bytes),
mouse-report and paste-payload formatting (human-rate), the file tree (`DirAccess`/`TreeItem` is
UI-bound), and per-frame `Image` reuse for video (copy-on-write; the upload is the copy).

## How to measure

- Time the call with `Time.get_ticks_usec()` marks around each step, and the frame after it with
  `await get_tree().process_frame`; repeat at least three times and attribute every step before
  theorising (`testing.md`'s recipe, and the `gpty-live-gui-smoke` skill's "Timing an interaction").
- A perf claim about an interaction needs a **windowed** run. Draw numbers need a real display
  driver and `--disable-vsync`; under `--headless` every draw timing reads zero. Pure compute (the
  probe, a parser, a sort) may be headless.
- Use the committed end-to-end harnesses: `draw_bench.gd` (full/row/overlay repaint and the stream
  cadence), `graph_bench.gd` (query/parse/layout and request-to-canvas latency), `reasoning_bench.gd`
  (burst/catchup), `switch_bench.gd` (workspace switch, cold/warm), `spawn_bench.gd` (pane
  creation). The probe is the micro-number; the harness is the user-visible one.
- Record **measured** (with the build/source) and **expected** (with the probe that will confirm
  it) separately in the roadmap row. A row lands only with a number and a test; if its gate
  misses, revert the code and close the row with the number. A micro-number is never presented as
  the user-visible gain; quote the end-to-end number with the probe that produced it.

## What is not a defect

- Native built-ins: packed-array indexing, `Rect2.intersects`, `String.substr`,
  `PackedByteArray.slice` - they are C++ already.
- One-off setup: building a panel's controls, connecting signals, loading a font.
- A palette read at draw time (the light/dark switch requires it) once per draw.
- `range()` on 4.7.2: measured flat; the atom is a candidate, not a finding.
- An `Image` object per frame: copy-on-write, measured sub-microsecond; the texture upload is the
  separate cost.

When the audit and the probe disagree, the probe wins; when the probe and the windowed harness
disagree, the harness wins.
