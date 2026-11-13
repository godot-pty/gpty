extends GutTest
# Settings Concepts tab — list container must exist so saving a concept
# cannot null-deref `_concept_list` (that crashed the app on Add Concept).

class MockWorkspace extends Control:
	func get_terminal_for_ffi() -> Node:
		return null

var _ws: MockWorkspace
var _panel: SettingsPanel

func before_each():
	MockAutoloads.setup()
	_ws = MockWorkspace.new()
	add_child_autofree(_ws)
	_panel = SettingsPanel.new(_ws)
	add_child_autofree(_panel)
	await get_tree().process_frame

func after_each():
	MockAutoloads.teardown()

func test_concept_list_is_created():
	assert_not_null(_panel._concept_list, "Concepts tab must own a list VBox")
	assert_true(_panel._concept_list.is_inside_tree())

func test_refresh_concept_list_does_not_crash_without_terminal():
	_panel._concept_terminal = null
	_panel._refresh_concept_list()
	assert_eq(_panel._concept_list.get_child_count(), 0)

func test_refresh_survives_null_list():
	_panel._concept_list = null
	_panel._refresh_concept_list()
	assert_null(_panel._concept_list, "refresh must not resurrect a null list")
	# Recovery: a freshly assigned list still refreshes cleanly.
	_panel._concept_list = VBoxContainer.new()
	_panel._concept_terminal = null
	_panel._refresh_concept_list()
	assert_eq(_panel._concept_list.get_child_count(), 0,
		"refresh with no terminal must yield no rows")

# ── Provenance ─────────────────────────────────────────────────────────

## The row *A concept row's provenance tooltip can never show*: the provenance
## sits on the label a reader points at, and that label has to stop the mouse —
## a `Label` defaults to `MOUSE_FILTER_IGNORE`, which the viewport's tooltip
## lookup skips. Built through the row builder, because a terminal is the only
## thing that makes the refreshed list produce any row at all.
func test_a_plugin_concepts_provenance_is_a_readable_tooltip():
	var row := _panel._make_concept_row(
		{"name": "cat", "trigger": "reached", "enabled": true}, true,
		"From plugin gpty-omp (revision abc123)", 0)
	var lbl := row.get_node_or_null("ConceptName") as Label
	assert_not_null(lbl, "the row carries its name label")
	if lbl == null:
		return
	assert_eq(lbl.tooltip_text, "From plugin gpty-omp (revision abc123)",
		"the sentence explaining where the rule came from is on the row's text")
	assert_eq(lbl.mouse_filter, Control.MOUSE_FILTER_STOP,
		"a MOUSE_FILTER_IGNORE label is never a hover target, so the tooltip would never show")

## A rule the user wrote came from nowhere, so it carries no provenance.
func test_a_concept_without_a_source_carries_no_tooltip():
	var row := _panel._make_concept_row({"name": "mine", "trigger": "x"}, true, "", 0)
	var lbl := row.get_node_or_null("ConceptName") as Label
	assert_not_null(lbl)
	if lbl == null:
		return
	assert_eq(lbl.tooltip_text, "")
