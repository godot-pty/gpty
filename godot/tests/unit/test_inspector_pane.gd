extends GutTest
# Inspector pane — receive_content starts a private mock session without a PTY.

var _pane

func before_each():
	_pane = InspectorPane.new()
	_pane.backend = "mock"
	_pane.auto_run = true
	add_child_autofree(_pane)
	await get_tree().process_frame

func test_receive_content_starts_mock_turn():
	if _pane._ai == null:
		pending("GptyAi GDExtension class not registered")
		return
	_pane.accept_concept_captures = true
	assert_true(_pane.receive_content("error: something broke"))
	assert_true(_pane._busy or _pane._session_id != "", "turn should start")
	var saw_done := false
	for _i in 30:
		await get_tree().process_frame
		if _pane._status.text == "Done":
			saw_done = true
			break
	assert_true(saw_done, "mock inspection should complete")
	assert_string_contains(_pane._assembled, "## Observation")
	assert_string_contains(_pane._assembled, "error: something broke")
	assert_true(_pane._display.bbcode_enabled)
	assert_string_contains(_pane._display.get_parsed_text(), "Observation")

	_pane._on_prompt_submitted("second observation")
	saw_done = false
	for _i in 30:
		await get_tree().process_frame
		if _pane._status.text == "Done" and "second observation" in _pane._assembled:
			saw_done = true
			break
	assert_true(saw_done, "a second observation should replace the first")
	assert_string_contains(_pane._assembled, "second observation")
	assert_false("error: something broke" in _pane._assembled)

func test_declines_routed_content_without_ai_bridge():
	var ai = _pane._ai
	_pane._ai = null
	assert_false(_pane.can_receive_content())
	assert_false(_pane.receive_content("must be flushed"))
	assert_eq(_pane._session_id, "")
	_pane._ai = ai

func test_declines_concept_captures_until_opt_in():
	if _pane._ai == null:
		pending("GptyAi GDExtension class not registered")
		return
	_pane.accept_concept_captures = false
	assert_false(_pane.can_receive_content())
	assert_false(_pane.receive_content("terminal capture"))
	assert_eq(_pane._session_id, "")

func test_done_keeps_prompt_quote():
	if _pane._ai == null:
		pending("GptyAi GDExtension class not registered")
		return
	_pane.accept_concept_captures = true
	_pane.receive_content("error: something broke")
	for _i in 30:
		await get_tree().process_frame
		if _pane._status.text == "Done":
			break
	assert_ne(_pane._prompt_quote, "", "quote must survive done")

func test_pane_type_is_inspector():
	assert_eq(_pane._pane_type(), "inspector")
	assert_eq(_pane._default_title(), "Inspector")
