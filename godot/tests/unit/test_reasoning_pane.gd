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
	_pane.receive_agent_event(_event("session.bound"), "other-terminal")
	assert_string_contains(_pane._status.text, "Listening for OMP events")
	assert_eq(_pane._turns.size(), 0)

func test_projects_reasoning_deltas_from_attached_terminal():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "Inspecting output"}), "omp-terminal")
	await get_tree().create_timer(0.1).timeout
	assert_eq(_pane._turns.size(), 1)
	assert_string_contains(_pane._turns[0]["text"], "Inspecting output")
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "Inspecting output")
	assert_false(_pane._view_at(0).scroll_active)
	assert_false(_pane._view_at(0).fit_content)
	assert_eq(_pane._status.text, "Reasoning…")
	assert_false(_pane._fold_at(0).folded)

	_pane.receive_agent_event(_event("agent.settled"), "omp-terminal")
	assert_eq(_pane._status.text, "Done")
	assert_eq(_pane._turns[0]["status"], "done")
	assert_false(_pane._view_at(0).scroll_following)

func test_two_turns_keep_history_in_collapsed_fold():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "first thought"}), "omp-terminal")
	_pane.receive_agent_event(_event("agent.settled"), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "second thought"}), "omp-terminal")
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
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("agent.settled"), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_eq(_pane._turns[0]["status"], "empty")
	assert_eq(_pane._turns[0]["text"], "")
	assert_eq(_pane._status.text, "No reasoning emitted")
	assert_not_null(_pane._fold_at(0))
	assert_string_contains(_pane._fold_at(0).title, "No reasoning")

func test_new_omp_session_id_clears_folds():
	_pane.receive_agent_event(_event("session.bound"), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "old session"}), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)

	_pane.receive_agent_event(_event("session.bound", {}, "s2"), "omp-terminal")
	assert_eq(_pane._turns.size(), 0)
	assert_eq(_pane._status.text, "Attached to OMP session")
	assert_eq(_pane._turn_list.get_child_count(), 0)

func test_same_session_bound_keeps_folds():
	_pane.receive_agent_event(_event("session.bound"), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "keep me"}), "omp-terminal")
	_pane.receive_agent_event(_event("session.bound"), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_eq(_pane._turns[0]["text"], "keep me")

func test_layout_state_omits_turns_and_session_id():
	_pane.receive_agent_event(_event("session.bound"), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "secret thinking"}), "omp-terminal")
	var state: Dictionary = _pane._get_layout_state()
	assert_eq(state.get("source_attachment_id"), "omp-terminal")
	assert_false(state.has("turns"))
	assert_false(state.has("omp_session_id"))
	assert_false(JSON.stringify(state).contains("secret thinking"))
	assert_false(JSON.stringify(state).contains("s1"))

func test_omp_turn_index_events_do_not_relabel_history():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "x"}), "omp-terminal")
	_pane.receive_agent_event(_event("turn.started", {"turn_index": 42}), "omp-terminal")
	await get_tree().create_timer(0.05).timeout
	assert_string_contains(_pane._fold_at(0).title, "Turn 1")

func test_rebind_updates_status_after_shutdown():
	_pane.receive_agent_event(_event("session.bound", {"emitted_at_ms": 1000}), "omp-terminal")
	assert_eq(_pane._status.text, "Attached to OMP session")
	_pane.receive_agent_event(_event("session.shutdown", {"emitted_at_ms": 2000}), "omp-terminal")
	assert_eq(_pane._status.text, "OMP session ended")
	_pane.receive_agent_event(_event("session.bound", {"emitted_at_ms": 3000}), "omp-terminal")
	assert_eq(_pane._status.text, "Attached to OMP session")

func test_stale_shutdown_after_rebind_is_ignored():
	_pane.receive_agent_event(_event("session.bound", {"emitted_at_ms": 3000}), "omp-terminal")
	_pane.receive_agent_event(_event("session.shutdown", {"emitted_at_ms": 1000}), "omp-terminal")
	assert_eq(_pane._status.text, "Attached to OMP session")

func test_repeated_empty_agent_started_reuses_live_turn():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_string_contains(_pane._fold_at(0).title, "Turn 1")

func test_reasoning_delta_before_agent_started_keeps_text_on_one_turn():
	_pane.receive_agent_event(_event("thinking.delta", {"text": "early thought"}, "s1", 1), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started", {}, "s1", 2), "omp-terminal")
	assert_eq(_pane._turns.size(), 1)
	assert_eq(_pane._turns[0]["text"], "early thought")
	# Streaming renders are coalesced; the view catches up after the delay.
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.05).timeout
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "early thought")

func test_monotonic_seq_envelopes_still_render():
	_pane.receive_agent_event(_event("session.bound", {}, "s1", 1), "omp-terminal")
	_pane.receive_agent_event(_event("tool.call", {"tool_name": "bash"}, "s1", 2), "omp-terminal")
	_pane.receive_agent_event(_event("agent.started", {}, "s1", 3), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "seq path"}, "s1", 4), "omp-terminal")
	assert_eq(_pane._turns[0]["text"], "seq path")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.05).timeout
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "seq path")

## A streaming turn re-parses its accumulated markdown at most once per
## RENDER_DELAY: the old path called render_now per delta, so a fast stream
## re-parsed the whole turn (and every other turn) for every token.
func test_streaming_deltas_render_coalesced():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	for i in 30:
		_pane.receive_agent_event(_event("thinking.delta", {"text": "chunk-%d " % i}), "omp-terminal")
	# The model is complete immediately ...
	assert_string_contains(_pane._turns[0]["text"], "chunk-29")
	# ... while the view has not been re-parsed for the burst yet.
	assert_false(str(_pane._view_at(0).get_parsed_text()).contains("chunk-29"),
		"a delta burst must not render synchronously")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.05).timeout
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "chunk-0 ")
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "chunk-29")

## A completed turn is static: streaming a new turn must not reparse it. The
## old `_refresh_turn_layout` re-issued `set_markdown` for every turn on every
## delta, which re-rendered the whole accordion (and cleared any selection).
func test_a_streaming_turn_does_not_re_render_completed_turns():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(_event("thinking.delta", {"text": "first"}), "omp-terminal")
	_pane.receive_agent_event(_event("agent.settled"), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.1).timeout

	var first_view: MarkdownView = _pane._view_at(0)
	watch_signals(first_view)

	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	for i in 5:
		_pane.receive_agent_event(
			_event("thinking.delta", {"text": "second %d " % i}), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.2).timeout

	assert_eq(get_signal_emit_count(first_view, "rendered"), 0,
		"a completed turn must not be re-rendered while another streams")
	assert_string_contains(_pane._view_at(1).get_parsed_text(), "second 4")


## Selection is the copy path. A streaming render replaces the body and would
## drop it, so the view holds the pending render while text is selected.
func test_a_selection_survives_a_streaming_render():
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(
		_event("thinking.delta", {"text": "first selection"}), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.1).timeout

	var view: MarkdownView = _pane._view_at(0)
	view.select_all()
	var selected: String = view.get_selected_text()
	assert_string_contains(selected, "first selection", "the body must be selectable")

	view.set_markdown("replacement text")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.15).timeout
	assert_eq(view.get_selected_text(), selected,
		"a streaming render must not clear the selection")
	assert_string_contains(view.get_parsed_text(), "first selection",
		"the pending render waits for the selection")

	view.deselect()
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.15).timeout
	assert_string_contains(view.get_parsed_text(), "replacement text",
		"and it lands once the selection is released")


## The retention cap is a setting, not a silent data loss: the cut and its
## reason are visible in the turn.
func test_the_turn_cap_is_visible():
	_pane.max_turn_bytes = 32
	_pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	_pane.receive_agent_event(
		_event("thinking.delta", {"text": "x".repeat(80)}), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.1).timeout

	assert_true(_pane._turns[0].get("truncated", false), "the record says it was cut")
	assert_lte(_pane._turns[0]["text"].to_utf8_buffer().size(), 32)
	assert_string_contains(_pane._view_at(0).get_parsed_text(), "limit",
		"the view must say why the turn stops")


## The idle instructions contain the protocol probe command; a Label could not
## be selected, so a user had to retype it.
func test_the_status_instructions_can_be_selected_and_copied():
	var status = _pane._status
	assert_true(status is RichTextLabel, "the status must be selectable text")
	assert_true(status.selection_enabled)
	assert_true(status.context_menu_enabled, "right-click Copy must be available")
	status.select_all()
	assert_string_contains(status.get_selected_text(), "echo $GPTY_EVENT_PROTOCOL")


## Live output follows the newest line like a log viewer. The old check
## re-measured "is the bar near the bottom" when the scroll ran — after a
## render had grown the content — so a multi-line growth stopped the follow.
## The pane tracks intent instead: a user scroll-up pauses it, returning to
## the bottom (or a new turn) resumes it.
func test_a_live_turn_follows_the_bottom_until_the_user_scrolls_up():
	var host := Control.new()
	host.size = Vector2(420, 320)
	add_child_autofree(host)
	var pane := ReasoningPane.new()
	pane.source_attachment_id = "omp-terminal"
	host.add_child(pane)
	pane.size = Vector2(420, 320)
	await get_tree().process_frame
	await get_tree().process_frame

	pane.receive_agent_event(_event("agent.started"), "omp-terminal")
	for i in 40:
		pane.receive_agent_event(
			_event("thinking.delta", {"text": "reasoning line %d\n" % i}), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.35).timeout

	var bar := pane._turn_scroll.get_v_scroll_bar()
	assert_gt(bar.max_value, bar.page, "the content must overflow the viewport")
	assert_gte(bar.value + bar.page, bar.max_value - 2.0,
		"a live turn is followed to the bottom")

	# The user scrolls up: the next growth must not yank them back.
	pane._turn_scroll.scroll_vertical = 0
	await get_tree().process_frame
	assert_false(pane._follow_live, "scrolling up clears follow")
	for i in 10:
		pane.receive_agent_event(
			_event("thinking.delta", {"text": "more %d\n" % i}), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.35).timeout
	assert_eq(bar.value, 0, "a deliberate scroll-up is not overridden")

	# Returning to the bottom re-arms it.
	pane._turn_scroll.scroll_vertical = int(bar.max_value)
	await get_tree().process_frame
	assert_true(pane._follow_live, "scrolling back to the bottom re-arms follow")
	for i in 10:
		pane.receive_agent_event(
			_event("thinking.delta", {"text": "tail %d\n" % i}), "omp-terminal")
	await get_tree().create_timer(MarkdownView.RENDER_DELAY + 0.35).timeout
	assert_gte(bar.value + bar.page, bar.max_value - 2.0, "it follows again")
