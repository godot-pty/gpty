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

func test_cli_backend_requires_command():
	if _pane._ai == null:
		pending("GptyAi GDExtension class not registered")
		return
	_pane.backend = "cli"
	_pane.command = []
	assert_false(_pane._ensure_session(), "cli without a command must not open")
	assert_string_contains(_pane._status.text, "requires a command")

func test_command_setting_roundtrips_through_layout_state():
	_pane.apply_settings({"command": ["my-adapter", "--model", "x y"]})
	var state = _pane._get_layout_state()
	assert_true(state.has("command"), "layout state must persist the command")
	assert_eq(state["command"], ["my-adapter", "--model", "x y"],
		"command must roundtrip as argv through the layout state")

func test_cli_backend_streams_from_fake_adapter():
	if _pane._ai == null:
		pending("GptyAi GDExtension class not registered")
		return
	if OS.get_name() == "Windows":
		pending("fake adapter needs a POSIX shell")
		return
	var script := "#!/bin/sh\nread line\n" \
		+ "printf '%s\\n' '{\"type\":\"thinking\",\"text\":\"t\"}'\n" \
		+ "printf '%s\\n' '{\"type\":\"delta\",\"text\":\"cli said hi\"}'\n" \
		+ "printf '%s\\n' '{\"type\":\"done\",\"text\":\"cli said hi\"}'\n"
	var path := "user://fake_cli_adapter.sh"
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "must write the adapter script")
	f.store_string(script)
	f.close()
	var abs := ProjectSettings.globalize_path(path)
	OS.execute("chmod", ["+x", abs])
	_pane.backend = "cli"
	_pane.command = [abs]
	_pane.auto_run = false
	assert_true(_pane._start_turn("inspect this"), "cli turn must start")
	var saw_done := false
	for _i in 80:
		await get_tree().process_frame
		if _pane._status.text == "Done":
			saw_done = true
			break
	assert_true(saw_done, "the fake cli adapter must stream to completion")
	assert_string_contains(_pane._assembled, "cli said hi")
	DirAccess.remove_absolute(abs)
