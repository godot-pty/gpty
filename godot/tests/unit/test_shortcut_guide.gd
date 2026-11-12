extends GutTest
# ShortcutGuide — the empty workspace's shortcut surface. The card content comes
# from the caller (the workspace passes `ShortcutCatalog` and the registry), so
# what is asserted here is the surface's own contract: every row reaches a card,
# the primary action emits its pane type, the one clock cycles and pins, and the
# responsive width owns the column count. The real chords are pinned once in the
# integration test, so nothing is copied into a second list here.

const TITLE := "No panes"
const SUBTITLE := "Every shortcut the window answers, in one place."

var _rows := [
	{"group": "Workspace", "label": "Command palette", "chord": "Ctrl+Shift+P"},
	{"group": "Workspace", "label": "Next workspace", "chord": "Ctrl+PageDown"},
	{"group": "Panes", "label": "Close the active pane", "chord": "Ctrl+Shift+W"},
]
var _steps := [
	{"type": "terminal", "chord": "Ctrl+Shift+N", "label": "New Terminal"},
	{"type": "file_tree", "chord": "Ctrl+Shift+T", "label": "New File Tree"},
]
var _primary := {"label": "Open a Terminal", "type": "terminal", "chord": "Ctrl+Shift+N"}

func _make(rows: Array, steps: Array, primary: Dictionary) -> ShortcutGuide:
	var guide := ShortcutGuide.new()
	guide.theme = UiTheme.build()
	guide.configure(TITLE, SUBTITLE,
		func() -> Array: return rows,
		func() -> Array: return steps,
		func() -> Dictionary: return primary)
	add_child_autofree(guide)
	return guide

func _labels(guide: ShortcutGuide) -> Array:
	var out := []
	for label in guide.find_children("*", "Label", true, false):
		out.append((label as Label).text)
	return out

# ── Cards and action ───────────────────────────────────────────────────

func test_the_atlas_lists_every_row_in_its_group():
	var guide := _make(_rows, _steps, _primary)
	await get_tree().process_frame
	assert_eq(guide.rows(), _rows, "the surface reports the rows it was given")
	var texts := _labels(guide)
	for row in _rows:
		assert_true(texts.has(str(row["chord"])), "%s is on screen" % row["chord"])
		assert_true(texts.has(str(row["label"])), "%s is on screen" % row["label"])
	assert_true(texts.has("Workspace"), "the group heading is on screen")
	assert_true(texts.has("Panes"), "every group heading is on screen")
	assert_eq((guide.find_child("Title", true, false) as Label).text, TITLE)

func test_the_primary_action_emits_its_type():
	var guide := _make(_rows, _steps, _primary)
	await get_tree().process_frame
	watch_signals(guide)
	var primary := guide.find_child("PrimaryAction", true, false) as Button
	assert_not_null(primary)
	assert_eq(primary.text, "Open a Terminal")
	primary.pressed.emit()
	assert_signal_emitted_with_parameters(guide, "new_pane_requested", ["terminal"])

func test_configure_again_replaces_the_atlas():
	var guide := _make([{"group": "A", "label": "One", "chord": "Ctrl+1"}], [], {})
	await get_tree().process_frame
	assert_eq(guide.rows().size(), 1)
	var next_rows := [
		{"group": "A", "label": "Two", "chord": "Ctrl+2"},
		{"group": "A", "label": "Three", "chord": "Ctrl+3"},
	]
	guide.configure(TITLE, SUBTITLE,
		func() -> Array: return next_rows,
		func() -> Array: return [],
		func() -> Dictionary: return {})
	assert_eq(guide.rows().size(), 2, "the new provider is read")
	var texts := _labels(guide)
	assert_true(texts.has("Ctrl+2"))
	assert_false(texts.has("Ctrl+1"), "the old atlas row is freed, not hidden")

# ── The one clock ──────────────────────────────────────────────────────

func test_the_hero_cycles_and_pins():
	var guide := _make(_rows, _steps, _primary)
	await get_tree().process_frame
	guide.pin_animation()
	assert_eq(guide._step, 0, "the pin always starts at the first step")
	var chord := guide.find_child("HeroChord", true, false) as Label
	assert_eq(chord.text, "Ctrl+Shift+N", "the first step is the terminal spawn")
	guide._process(ShortcutGuide.HERO_CYCLE + 0.01)
	assert_eq(guide._step, 1, "the clock advances one step per cycle")
	assert_eq(chord.text, "Ctrl+Shift+T", "the caption and chord follow the step")
	guide.pin_animation()
	assert_eq(guide._step, 0, "a second pin returns to the first frame")

func test_the_clock_stops_when_hidden():
	var guide := _make(_rows, _steps, _primary)
	await get_tree().process_frame
	assert_true(guide.is_processing(), "a visible guide animates")
	guide.visible = false
	await get_tree().process_frame
	assert_false(guide.is_processing(), "a hidden guide costs no frames")
	guide.visible = true
	await get_tree().process_frame
	assert_true(guide.is_processing(), "showing it restarts the clock")
	guide.pin_animation()

# ── Responsive columns ────────────────────────────────────────────────

func test_fit_width_clamps_and_switches_columns():
	var guide := _make(_rows, _steps, _primary)
	await get_tree().process_frame
	guide.fit_width(800.0)
	assert_almost_eq(guide.custom_minimum_size.x, 752.0, 0.01,
		"the width allowance is the margins plus the scrollbar")
	assert_eq(guide._columns, 2, "800 px of grid holds two columns")
	guide.fit_width(560.0)
	assert_almost_eq(guide.custom_minimum_size.x, 512.0, 0.01)
	assert_eq(guide._columns, 1, "560 px falls back to one column")
	guide.fit_width(200.0)
	assert_almost_eq(guide.custom_minimum_size.x, ShortcutGuide.MIN_WIDTH, 0.01,
		"a narrow grid clamps to the floor instead of shrinking to nothing")
	assert_eq(guide._columns, 1)

func test_split_groups_balances_the_shipped_shape():
	var rows := []
	var names := ["Workspace", "New Panes", "Panes", "Keyboard Focus", "Terminal"]
	var counts := [8, 4, 4, 4, 3]
	for i in counts.size():
		for j in counts[i]:
			rows.append({"group": names[i], "label": "x", "chord": "Ctrl+X"})
	var groups := ShortcutGuide.group_rows(rows)
	assert_eq(groups.size(), 5, "the first-seen group order is kept")
	var parts := ShortcutGuide.split_groups(groups, 2)
	assert_eq(parts.size(), 2)
	var first := 0
	for group in parts[0]:
		first += (group["rows"] as Array).size()
	var second := 0
	for group in parts[1]:
		second += (group["rows"] as Array).size()
	assert_eq(first, 12, "Workspace + New Panes fill the first column")
	assert_eq(second, 11, "the rest fill the second, not a short tail")
