extends GutTest
# The close contract end to end: every path that destroys a pane or quits the
# app asks the panes first (`PaneBody.request_close`), a refusal cancels the
# whole action, and the quit itself goes through the workspace's seam.
#
# One workspace for the whole script, like `test_ipc_dispatch_contract.gd`
# (each instance schedules a deferred concept push 2 s after `_ready`).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _quit_called := false


class ScriptedPane extends RefCounted:
	## A pane whose close answer is scripted: the walk only calls
	## `request_close`/the answer, so a RefCounted stands in for a pane and the
	## walk's semantics are pinned here (the real dialog behavior by the wiki
	## pane's own tests). RefCounted, not a Node: no orphan per test.
	var proceeds := true
	var asks := 0

	func request_close(answer: Callable) -> void:
		asks += 1
		answer.call(proceeds)


func before_all():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager.refresh_plugin_concepts()
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame


func before_each():
	_quit_called = false
	_ws.quit_action = func(): _quit_called = true


func after_all():
	# Let the workspace's deferred concept push land while it is still alive.
	await get_tree().create_timer(2.1).timeout
	remove_child(_ws)
	_ws.free()
	_ws = null
	ConceptManager.plugin_concepts_source = Callable()
	ConceptManager._plugin_concept_entries = []
	MockAutoloads.teardown()


func _spawn_wiki() -> Control:
	var body = _ws._spawn_pane("wiki", {})
	assert_not_null(body, "spawning a wiki pane must work")
	return body


## Give a pane unsaved work. The guard only asks whether the pane would lose
## something; the buffer's provenance is the wiki pane's own business.
func _dirty(pane: Control) -> void:
	pane._current_rel = "note.md"
	pane._saved_text = "before"
	pane._editable_note = true
	pane._editor.text = "after"


func _ask_dialog(pane: Control) -> ConfirmationDialog:
	return pane.find_child("DiscardConfirm", false, false) as ConfirmationDialog


## The question a pane must be asking. Asserting here keeps a missing dialog a
## clean test failure rather than a null dereference (a script error aborts the
## whole GUT run).
func _expect_ask(pane: Control) -> ConfirmationDialog:
	var dialog := _ask_dialog(pane)
	assert_not_null(dialog, "the pane must be asking before this answer")
	return dialog


func after_each():
	# One Workspace serves the whole script, so its panes outlive a test: drop
	# them all (the primitive, no asking). A leftover dirty pane would be asked
	# again by the next test's walk, and a second exclusive dialog cannot be
	# raised while a leftover question is still open.
	for ws in _ws._workspaces:
		ws.tm.reset()
	await get_tree().process_frame


# ── The walk itself ────────────────────────────────────────────────────

func test_the_walk_asks_every_pane_before_it_continues():
	var a := ScriptedPane.new()
	var b := ScriptedPane.new()
	var c := ScriptedPane.new()
	var done := []
	_ws._ask_close_then([a, b, c], func(): done.append(true))

	assert_eq([a.asks, b.asks, c.asks], [1, 1, 1], "every pane is asked once")
	assert_eq(done, [true], "the continuation runs after the last answer")

func test_a_refusing_pane_stops_the_walk():
	var a := ScriptedPane.new()
	var b := ScriptedPane.new()
	b.proceeds = false
	var c := ScriptedPane.new()
	var done := []
	var refused := []
	_ws._ask_close_then([a, b, c], func(): done.append(true), func(): refused.append(true))

	assert_eq(a.asks, 1, "panes before the refusal are asked")
	assert_eq(b.asks, 1, "the refusing pane is asked")
	assert_eq(c.asks, 0, "panes after a refusal are never asked")
	assert_eq(done, [], "a refusal cancels the action")
	assert_eq(refused, [true], "the caller hears about the refusal")

func test_the_walk_skips_a_pane_that_was_freed_while_asking():
	var a := ScriptedPane.new()
	# An entry freed between the walk's start and its turn. A dead Node
	# reference is what `is_instance_valid` sees in the real case (and a
	# RefCounted cannot be freed by hand).
	var gone: Node = Node.new()
	gone.free()
	var b := ScriptedPane.new()
	var done := []
	_ws._ask_close_then([a, gone, b], func(): done.append(true))

	assert_eq([a.asks, b.asks], [1, 1], "a freed pane is skipped, not fatal")
	assert_eq(done, [true])

# ── Quit (the workspace's seam) ────────────────────────────────────────

func test_quitting_a_clean_workspace_quits():
	_spawn_wiki()
	_ws.request_quit()
	assert_true(_quit_called, "a workspace with nothing to lose quits at once")

func test_a_dirty_pane_holds_the_quit_until_it_answers():
	var pane := _spawn_wiki()
	_dirty(pane)
	_ws.request_quit()
	assert_false(_quit_called, "the pane is asked before the window goes away")
	var dialog := _ask_dialog(pane)
	assert_not_null(dialog, "the quit must reach the pane's own question")

	dialog.custom_action.emit("discard")
	assert_true(_quit_called, "discarding lets the quit through")

func test_a_canceled_quit_can_be_asked_again():
	var pane := _spawn_wiki()
	_dirty(pane)
	_ws.request_quit()
	_expect_ask(pane).canceled.emit()
	await get_tree().process_frame
	assert_false(_quit_called, "canceling cancels the quit")

	# Clean the buffer by hand (this pane has no vault, so `_save` cannot
	# succeed), and the next request has nothing to ask.
	pane._saved_text = pane._editor.text
	_ws.request_quit()
	assert_true(_quit_called, "the next quit is not blocked by the canceled one")

# ── The destruction funnels ────────────────────────────────────────────

func test_killing_a_dirty_pane_asks_first_and_a_refusal_keeps_it():
	var pane := _spawn_wiki()
	_dirty(pane)
	# A bare test workspace restores whatever the developer's real `user://`
	# holds, so only this pane's own tile is asserted on.
	var tiles_before: int = _ws._tm.tiles.size()

	_ws._kill(pane)
	assert_true(is_instance_valid(pane), "the pane stays until it answers")
	assert_eq(_ws._tm.tiles.size(), tiles_before, "and its tile stays")
	var dialog := _ask_dialog(pane)
	assert_not_null(dialog, "a close over unsaved work asks")
	assert_string_contains(dialog.dialog_text, "note.md")

	dialog.canceled.emit()
	await get_tree().process_frame
	assert_true(is_instance_valid(pane), "canceling keeps the pane")

	_ws._kill(pane)
	_expect_ask(pane).custom_action.emit("discard")
	await get_tree().process_frame
	assert_false(is_instance_valid(pane), "discarding closes it")
	assert_eq(_ws._tm.tiles.size(), tiles_before - 1)

func test_kill_last_asks_through_the_same_guard():
	var pane := _spawn_wiki()
	_dirty(pane)
	_ws._tm.last_body = pane

	_ws._kill_last()
	assert_true(is_instance_valid(pane), "the shortcut's kill asks too")
	_expect_ask(pane).canceled.emit()
	await get_tree().process_frame
	assert_true(is_instance_valid(pane), "and a cancel keeps the pane")

func test_resetting_the_workspace_asks_before_it_destroys_a_dirty_pane():
	var pane := _spawn_wiki()
	_dirty(pane)

	_ws._do_reset()
	assert_true(is_instance_valid(pane), "the reset waits for the answer")
	_expect_ask(pane).canceled.emit()
	await get_tree().process_frame
	assert_true(is_instance_valid(pane), "canceling keeps the workspace as it is")

	_ws._do_reset()
	_expect_ask(pane).custom_action.emit("discard")
	await get_tree().process_frame
	assert_false(is_instance_valid(pane), "discarding resets")

func test_swapping_a_dirty_pane_asks_before_the_old_body_goes():
	var pane := _spawn_wiki()
	_dirty(pane)

	_ws._swap_pane(pane, "code_viewer")
	assert_true(is_instance_valid(pane), "the swap waits for the answer")
	_expect_ask(pane).canceled.emit()
	await get_tree().process_frame
	assert_true(is_instance_valid(pane), "canceling keeps the pane's type")

	_ws._swap_pane(pane, "code_viewer")
	_expect_ask(pane).custom_action.emit("discard")
	await get_tree().process_frame
	assert_false(is_instance_valid(pane), "discarding replaces the old body")
	var swapped := false
	for t in _ws._tm.tiles:
		if _ws._tm._find_body(t.wrapper) is CodeViewerPane:
			swapped = true
	assert_true(swapped, "with the requested type")

func test_closing_a_workspace_asks_before_its_panes_go():
	_ws._add_workspace()
	var pane := _spawn_wiki()
	_dirty(pane)
	var workspaces: int = _ws._workspaces.size()

	_ws._close_workspace(_ws._active)
	assert_true(is_instance_valid(pane), "the workspace close waits too")
	_expect_ask(pane).canceled.emit()
	await get_tree().process_frame
	assert_eq(_ws._workspaces.size(), workspaces, "canceling keeps the workspace")

	_ws._close_workspace(_ws._active)
	_expect_ask(pane).custom_action.emit("discard")
	await get_tree().process_frame
	assert_false(is_instance_valid(pane), "discarding closes it")
	assert_eq(_ws._workspaces.size(), workspaces - 1)
