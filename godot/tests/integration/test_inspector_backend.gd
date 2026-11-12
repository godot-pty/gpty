extends GutTest
# InspectorPane's backend dropdown. The pane settings overlay builds its rows
# from the extension's own backend list on every open, selects the canonical
# kind for an alias, keeps a value the list does not know as a custom row, and
# shows the cli Command row only for the cli backend.

class RosterStub extends Node:
	var calls := 0
	var rows: Array = []

	func list_backends() -> String:
		calls += 1
		return JSON.stringify(rows)

var _pane
var _panel: PaneSettingsPanel

func before_each():
	_pane = InspectorPane.new()
	_pane.backend = "mock"
	add_child_autofree(_pane)
	await get_tree().process_frame
	_panel = PaneSettingsPanel.new()
	add_child_autofree(_panel)

func _open():
	_panel.open_for(_pane)

func _select() -> OptionButton:
	return _panel.find_child("BackendSelect", true, false) as OptionButton

func _item_index(select: OptionButton, prefix: String) -> int:
	for i in select.item_count:
		if select.get_item_text(i).begins_with(prefix):
			return i
	return -1

func _hint() -> Label:
	return _panel.find_child("BackendHint", true, false) as Label

# ── The real extension roster ──────────────────────────────────────────

func test_the_dropdown_lists_the_extensions_backends():
	assert_not_null(_pane._ai,
		"GptyAi must be registered: build and install the gpty-gdext extension")
	if _pane._ai == null:
		return
	_open()
	var select := _select()
	assert_eq(select.item_count, 3)
	assert_eq(select.get_item_text(0), "Mock")
	assert_string_contains(select.get_item_text(1), "Oh-My-Pi")
	assert_string_contains(select.get_item_text(2), "CLI")
	assert_eq(select.selected, _item_index(select, "Mock"),
		"the pane's current backend is the selected row")

func test_selecting_a_backend_applies_and_persists():
	_open()
	var select := _select()
	var cli := _item_index(select, "CLI")
	select.selected = cli
	select.item_selected.emit(cli)
	_panel._apply_to_target()
	_panel._debounce_timer.stop()
	assert_eq(_pane.backend, "cli", "the selection is applied to the pane")
	assert_eq(_pane._get_layout_state()["backend"], "cli", "the choice is layout state")

	var restored = InspectorPane.new()
	add_child_autofree(restored)
	await get_tree().process_frame
	restored.apply_settings(_pane._get_layout_state())
	assert_eq(restored.backend, "cli", "a restore keeps the saved backend")

# ── Aliases and unknown values ─────────────────────────────────────────

func test_an_alias_selects_the_canonical_row():
	_pane.apply_settings({"backend": "pi"})
	assert_eq(_pane.backend, "omp", "an alias is stored as its kind")
	_open()
	var select := _select()
	assert_eq(select.selected, _item_index(select, "Oh-My-Pi"),
		"the alias selects the omp row instead of a Custom row")
	_panel._apply_to_target()
	assert_eq(_pane.backend, "omp")
	assert_eq(_pane._get_layout_state()["backend"], "omp",
		"the canonical spelling is what a layout re-saves")

func test_an_unknown_backend_stays_custom():
	_pane.apply_settings({"backend": "gpt-5"})
	_open()
	var select := _select()
	assert_eq(select.item_count, 4)
	assert_eq(select.get_item_text(3), "Custom: gpt-5")
	assert_eq(select.selected, 3, "the unknown value is what the panel shows")
	assert_true(_hint().visible)
	assert_eq(_hint().text, BackendChoice.CUSTOM_HINT)
	_panel._apply_to_target()
	assert_eq(_pane.backend, "gpt-5", "applying the panel does not reset an unknown value")

# ── Availability and freshness ─────────────────────────────────────────

func test_availability_is_annotated_without_disabling_the_row():
	var stub := RosterStub.new()
	stub.rows = [
		{"kind": "mock", "name": "Mock", "available": true},
		{"kind": "omp", "name": "Oh-My-Pi (omp RPC)", "available": false},
		{"kind": "cli", "name": "CLI bridge (NDJSON)", "available": true},
	]
	add_child_autofree(stub)
	_pane._ai = stub
	_pane.backend = "omp"
	_open()
	var select := _select()
	var omp := _item_index(select, "Oh-My-Pi")
	assert_eq(select.get_item_text(omp), "Oh-My-Pi (omp RPC) (not found)")
	assert_false(select.is_item_disabled(omp), "a persisted selection stays selectable")
	assert_eq(select.selected, omp)
	assert_true(_hint().visible)
	assert_string_contains(_hint().text, "GPTY_OMP")

func test_the_roster_is_read_on_every_panel_open():
	var stub := RosterStub.new()
	stub.rows = [{"kind": "mock", "name": "Mock", "available": true}]
	add_child_autofree(stub)
	_pane._ai = stub
	_open()
	assert_eq(stub.calls, 1, "opening the panel reads the roster")
	_panel.close()
	_open()
	assert_eq(stub.calls, 2, "availability is re-read on the next open, not cached")

# ── The cli-only Command row ───────────────────────────────────────────

func test_the_command_row_and_hint_show_only_for_cli():
	_open()
	var command_row := _panel.find_child("CommandRow", true, false) as Control
	var command_hint := _panel.find_child("CommandHint", true, false) as Label
	var command_edit := _panel.find_child("CommandEdit", true, false) as LineEdit
	assert_false(command_row.visible, "a non-cli backend has no command to show")
	assert_false(command_hint.visible)

	var select := _select()
	var cli := _item_index(select, "CLI")
	select.selected = cli
	select.item_selected.emit(cli)
	assert_true(command_row.visible, "the cli backend shows its command field")
	assert_true(command_hint.visible, "an empty command is called out")
	assert_eq(command_hint.text, InspectorPane.CLI_EMPTY_HINT)

	command_edit.text = "my-adapter --x"
	command_edit.text_changed.emit(command_edit.text)
	assert_false(command_hint.visible, "a command silences the hint")
	assert_true(command_row.visible)
	_panel._debounce_timer.stop()
