extends GutTest
# Reasoning pane — passive OMP projection; never owns jobs or captures.

var _pane

func before_each():
	_pane = ReasoningPane.new()
	_pane.source_attachment_id = "omp-terminal"
	add_child_autofree(_pane)
	await get_tree().process_frame

func _event(event_name: String, extra: Dictionary = {}, session := "s1", seq := -1) -> Dictionary:
	var event := {"name": event_name}
	event.merge(extra)
	var envelope := {"omp_session_id": session, "event": event}
	if seq >= 0:
		envelope["seq"] = seq
	return envelope

func test_pane_type_is_reasoning():
	assert_eq(_pane._pane_type(), "reasoning")
	assert_eq(_pane._default_title(), "Reasoning")

func test_never_accepts_concept_captures():
	assert_false(_pane.can_receive_content())
	assert_false(_pane.receive_content("should not start"))

func test_ignores_events_from_other_attachments():
	_pane.receive_agent_event(_event("omp.session.bound"), "other-terminal")
	assert_string_contains(_pane._status.text, "Listening for OMP events")
	assert_eq(_pane._turns.size(), 0)

func test_projects_reasoning_deltas_from_attached_terminal():
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "Inspecting output"}), "omp-terminal")
	await get_tree().create_timer(0.1).timeout
	assert_eq(_pane._turns.size(), 1)
	assert_string_contains(_pane._turns[0]["text"], "Inspecting output")
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "Inspecting output")
	assert_false(_pane._view_at(0).scroll_active)
	assert_false(_pane._view_at(0).fit_content)
	assert_eq(_pane._status.text, "Reasoning…")
	assert_false(_pane._fold_at(0).folded)

	_pane.receive_agent_event(_event("omp.agent.settled"), "omp-terminal")
	assert_eq(_pane._status.text, "Done")
	assert_eq(_pane._turns[0]["status"], "done")
	assert_false(_pane._view_at(0).scroll_following)

func test_two_turns_keep_history_in_collapsed_fold():
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "first thought"}), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.settled"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "second thought"}), "omp-terminal")
	await get_tree().create_timer(0.1).timeout

	assert_eq(_pane._turns.size(), 2)
	assert_eq(_pane._turns[0]["text"], "first thought")
	assert_eq(_pane._turns[0]["status"], "done")
	assert_eq(_pane._turns[1]["text"], "second thought")
	assert_eq(_pane._turns[1]["status"], "streaming")
	assert_true(_pane._fold_at(0).folded)
	assert_false(_pane._fold_at(1).folded)
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "first thought")
	assert_string_contains(_pane._view_at(1).get_parsed_text(), "second thought")
	assert_string_contains(_pane._fold_at(0).title, "Turn 1")
	assert_string_contains(_pane._fold_at(1).title, "Turn 2")

func test_empty_settle_keeps_stub_fold():
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.settled"), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_eq(_pane._turns[0]["status"], "empty")
	assert_eq(_pane._turns[0]["text"], "")
	assert_eq(_pane._status.text, "No reasoning emitted")
	assert_not_null(_pane._fold_at(0))
	assert_string_contains(_pane._fold_at(0).title, "No reasoning")

func test_new_omp_session_id_clears_folds():
	_pane.receive_agent_event(_event("omp.session.bound"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "old session"}), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)

	_pane.receive_agent_event(_event("omp.session.bound", {}, "s2"), "omp-terminal")
	assert_eq(_pane._turns.size(), 0)
	assert_eq(_pane._status.text, "Attached to OMP session")
	assert_eq(_pane._turn_list.get_child_count(), 0)

func test_same_session_bound_keeps_folds():
	_pane.receive_agent_event(_event("omp.session.bound"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "keep me"}), "omp-terminal")
	_pane.receive_agent_event(_event("omp.session.bound"), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_eq(_pane._turns[0]["text"], "keep me")

func test_layout_state_omits_turns_and_session_id():
	_pane.receive_agent_event(_event("omp.session.bound"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "secret thinking"}), "omp-terminal")
	var state: Dictionary = _pane._get_layout_state()
	assert_eq(state.get("source_attachment_id"), "omp-terminal")
	assert_false(state.has("turns"))
	assert_false(state.has("omp_session_id"))
	assert_false(JSON.stringify(state).contains("secret thinking"))
	assert_false(JSON.stringify(state).contains("s1"))

func test_omp_turn_index_events_do_not_relabel_history():
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "x"}), "omp-terminal")
	_pane.receive_agent_event(_event("omp.turn.started", {"turn_index": 42}), "omp-terminal")
	await get_tree().create_timer(0.05).timeout
	assert_string_contains(_pane._fold_at(0).title, "Turn 1")

func test_rebind_updates_status_after_shutdown():
	_pane.receive_agent_event(_event("omp.session.bound", {"emitted_at_ms": 1000}), "omp-terminal")
	assert_eq(_pane._status.text, "Attached to OMP session")
	_pane.receive_agent_event(_event("omp.session.shutdown", {"emitted_at_ms": 2000}), "omp-terminal")
	assert_eq(_pane._status.text, "OMP session ended")
	_pane.receive_agent_event(_event("omp.session.bound", {"emitted_at_ms": 3000}), "omp-terminal")
	assert_eq(_pane._status.text, "Attached to OMP session")

func test_stale_shutdown_after_rebind_is_ignored():
	_pane.receive_agent_event(_event("omp.session.bound", {"emitted_at_ms": 3000}), "omp-terminal")
	_pane.receive_agent_event(_event("omp.session.shutdown", {"emitted_at_ms": 1000}), "omp-terminal")
	assert_eq(_pane._status.text, "Attached to OMP session")

func test_repeated_empty_agent_started_reuses_live_turn():
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started"), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_string_contains(_pane._fold_at(0).title, "Turn 1")

func test_reasoning_delta_before_agent_started_keeps_text_on_one_turn():
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "early thought"}, "s1", 1), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started", {}, "s1", 2), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_eq(_pane._turns[0]["text"], "early thought")
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "early thought")

func test_monotonic_seq_envelopes_still_render():
	_pane.receive_agent_event(_event("omp.session.bound", {}, "s1", 1), "omp-terminal")
	_pane.receive_agent_event(_event("omp.tool.started", {"tool_name": "bash"}, "s1", 2), "omp-terminal")
	_pane.receive_agent_event(_event("omp.agent.started", {}, "s1", 3), "omp-terminal")
	_pane.receive_agent_event(_event("omp.reasoning.delta", {"text": "seq path"}, "s1", 4), "omp-terminal")
	assert_eq(_pane._turns[0]["text"], "seq path")
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "seq path")
