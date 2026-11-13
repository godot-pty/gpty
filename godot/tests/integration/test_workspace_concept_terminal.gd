extends GutTest
# The workspace's one "give me a terminal for the concept FFI" answer.
#
# Settings' Concepts section asks `Workspace.get_terminal_for_ffi()` for a
# backend to run concept queries through. It walks the active workspace's
# tiles, and every tile is not a terminal (an Inspector, a Reasoning pane, a
# wiki), so the walk must skip what it cannot use instead of reading a field
# only a terminal has — that raised "Invalid access to property or key
# '_terminal' on a base object of type 'Control (ReasoningPane)'" and left the
# section empty even when a terminal sat in another tile (measured 2026-11-13).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	# The mock seeds one terminal workspace; this script builds its own tiles,
	# so the seeded pane would be the first terminal the lookup finds.
	MockAutoloads.set_store(WorkspaceStore.FILE, {"active": 0, "workspaces": []})
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

func after_each():
	if _ws:
		remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()


## The reported case: a non-terminal tile is first, a terminal is second. The
## lookup must reach the terminal, and must not raise a script error on the
## reasoning body on the way (GUT fails the test on an unexpected error).
func test_the_concept_terminal_is_found_past_a_non_terminal_tile():
	var reasoning = _ws._spawn_pane("reasoning", {}, false)
	assert_not_null(reasoning, "the fixture needs a non-terminal first tile")
	var terminal = _ws._spawn_pane("terminal", {}, false)
	assert_not_null(terminal, "the fixture needs a terminal tile")
	assert_eq(_ws.get_terminal_for_ffi(), terminal._terminal,
		"the lookup must answer the terminal's backend, not stop at the first tile")


## A workspace with no terminal has no answer, and asking must stay silent.
func test_no_terminal_answers_null():
	var reasoning = _ws._spawn_pane("reasoning", {}, false)
	assert_not_null(reasoning)
	assert_null(_ws.get_terminal_for_ffi(),
		"a workspace without a terminal answers null instead of erroring")
