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

func test_envelopes_from_other_runs_are_ignored():
	# A late delta from a finished or aborted turn carries that turn's run_id.
	# Once _finish_turn() cleared _run_id, the old guard only compared while
	# _run_id was non-empty and let the stale delta through, appending another
	# turn's tokens to the current answer.
	_pane._session_id = "s1"
	_pane._run_id = ""
	_pane._assembled = ""
	_pane._handle_envelope({
		"session_id": "s1", "run_id": "finished-run",
		"event": {"type": "delta", "text": "stale"},
	})
	assert_eq(_pane._assembled, "", "a finished turn's late delta must be dropped")

	_pane._run_id = "live-run"
	_pane._handle_envelope({
		"session_id": "s1", "run_id": "live-run",
		"event": {"type": "delta", "text": "fresh"},
	})
	assert_eq(_pane._assembled, "fresh", "the live run's deltas still apply")

	# Run-less notices (a dropped-events report, session status) carry no run
	# and must still reach the pane, or the gap would be announced and then
	# discarded here.
	_pane._run_id = ""
	_pane._handle_envelope({
		"session_id": "s1", "run_id": "",
		"event": {"type": "status", "message": "3 earlier events dropped"},
	})
	assert_string_contains(_pane._status.text, "3 earlier events dropped")

func test_cli_adapter_path_another_user_controls_is_refused():
	# The adapter command comes from pane settings, which a profile or
	# workspace file can supply, and it is executed as argv — so an absolute
	# path must not point at a file another user could have written.
	if _pane._ai == null:
		pending("GptyAi GDExtension class not registered")
		return
	var path := "/tmp/gpty_inspector_probe_%d" % OS.get_process_id()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("#!/bin/sh\n")
	f.close()
	OS.execute("chmod", ["777", path])

	_pane.backend = "cli"
	_pane.command = [path]
	assert_false(_pane._ensure_session(), "a world-writable adapter must not open")
	assert_string_contains(_pane._status.text, "rejected")

	DirAccess.remove_absolute(path)

func test_command_field_only_reparses_when_edited():
	# The Command field joins argv with spaces, so it cannot show an argument
	# containing a space. Gathering settings while that field is untouched --
	# which happens whenever any other setting is edited -- must not re-split
	# the argv, or the pane silently starts launching a different program and
	# persists the mangled value back to the profile.
	var argv = ["/opt/my adapters/run.sh", "--flag"]
	var shown = " ".join(argv)
	assert_eq(_pane._command_from_field(shown, shown, argv), argv,
		"an untouched Command field must keep the original argv")
	assert_eq(
		_pane._command_from_field("my-adapter --x", shown, argv),
		["my-adapter", "--x"],
		"an edited Command field is parsed as whitespace-separated argv")

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
