extends GutTest
# History (FTS5) search from the pane.
#
# Two failures this defends against, both silent before:
#   1. Raw FTS5 syntax rejected ordinary search text — `main.rs` is a syntax
#      error near ".", `error: x` is read as a column filter, `warning:` and
#      `*` fail too — and every rejection came back as an empty result list,
#      indistinguishable from "no match". Live regex search accepts all of
#      them, which is why the two scopes disagreed.
#   2. The panel only appeared when there were results, so a failed query, a
#      pane with no stored history, and a genuine no-match all looked the
#      same: nothing at all.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_history_lines = 1000

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## A workspace with one running terminal whose history holds MARKER.
func _pane_with_marker() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	body._terminal.send_line("echo HISTSEARCH_MARKER")
	await get_tree().create_timer(1.2).timeout
	# The search box only renders results in the History scope.
	body._search_visible = true
	body._scope_history = true
	return body

func test_punctuated_queries_find_stored_lines():
	var body = await _pane_with_marker()
	# Each of these is rejected by raw FTS5 MATCH.
	for pattern in ["HISTSEARCH_MARKER", "HISTSEARCH_MARKER:", "echo HISTSEARCH_MARKER"]:
		body._do_history_search(pattern)
		assert_gt(
			body._history_results.size(), 0,
			"'%s' must find the stored line, not silently return nothing" % pattern
		)
	assert_eq(body._search_error, "", "a findable query must not report an error")
	await get_tree().create_timer(2.1).timeout

func test_no_match_explains_itself():
	var body = await _pane_with_marker()
	body._do_history_search("zzz_no_such_text_zzz")
	assert_eq(body._history_results.size(), 0)
	assert_true(
		body._history_panel.visible,
		"the panel must appear to explain the empty result"
	)
	assert_gt(
		body._history_list.get_child_count(), 0,
		"an explanation row must be present when nothing matches"
	)
	await get_tree().create_timer(2.1).timeout

func test_unsearchable_input_is_not_an_error():
	# Punctuation-only input reduces to no terms: empty, but not a failure.
	var body = await _pane_with_marker()
	body._do_history_search("*")
	assert_eq(body._history_results.size(), 0)
	assert_eq(body._search_error, "", "punctuation-only input is an empty search, not an error")
	await get_tree().create_timer(2.1).timeout
