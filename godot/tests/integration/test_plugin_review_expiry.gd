extends GutTest
# The plugin-install review dialog must not outlive the IPC request that asked
# for it. Rust hands the request's *remaining* fallback deadline to GDScript
# (`timeout_ms` in the drained dictionary); the dialog arms a timer from it and
# closes itself when the request dies, so a late click cannot answer a dead
# channel while the user believes the install happened.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _dialog(ws: Control) -> ConfirmationDialog:
	for c in ws.get_children():
		if c is ConfirmationDialog and c.name == "PluginReviewDialog":
			return c
	return null

func _review_params() -> Dictionary:
	return {
		"id": "owner/demo", "name": "Demo", "version": "1.0.0",
		"revision": "abc1234",
	}

func _wait_until(predicate: Callable, timeout_s := 3.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if predicate.call():
			return true
	return false

# ── Expiry ─────────────────────────────────────────────────────────────

func test_a_review_closes_when_its_request_deadline_passes():
	var ws := await _make_workspace()
	watch_signals(ToastManager)
	ws._show_plugin_review(11, _review_params(), 150)
	assert_eq(ws._pending_plugin_reviews.size(), 1, "the review must be pending")
	var dialog := _dialog(ws)
	assert_not_null(dialog, "the review dialog must open")

	assert_true(
		await _wait_until(func(): return ws._pending_plugin_reviews.is_empty()),
		"the review must expire with the request that asked for it")
	assert_false(is_instance_valid(dialog), "the expired dialog must be freed")
	assert_signal_emitted(ToastManager, "toast_requested")

func test_an_expired_request_never_opens_a_dialog():
	var ws := await _make_workspace()
	# 0 means the request's fallback already fired before this frame drained
	# it: there is no channel left to answer, so nothing opens.
	ws._show_plugin_review(12, _review_params(), 0)
	assert_eq(ws._pending_plugin_reviews.size(), 0, "a dead request opens nothing")
	assert_null(_dialog(ws), "no dialog may be created for it")

# ── The answered path still settles the same entry ─────────────────────

func test_answering_before_the_deadline_cleans_up():
	var ws := await _make_workspace()
	ws._show_plugin_review(13, _review_params(), 60_000)
	var dialog := _dialog(ws)
	assert_not_null(dialog, "the review dialog must open")
	# No client holds this request in the test, so Rust logs
	# `respond_ipc: no pending request` — a genuine anomaly signal in
	# production (an answer arriving after the fallback fired), expected here.
	# The tracker is silenced for that one line instead of the warning being
	# weakened.
	gut.error_tracker.disabled = true
	dialog.canceled.emit()
	gut.error_tracker.disabled = false
	assert_eq(ws._pending_plugin_reviews.size(), 0, "an answered review is settled")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(is_instance_valid(dialog), "the answered dialog must be freed")
	assert_null(ws.get_node_or_null("ReviewExpiry"), "the expiry timer must go with the answer")

func test_accepting_a_review_records_its_revision_and_plans():
	# The wiring between the summary the dialog showed and the consent record
	# the activation gate reads: the revision alone used to be the record, so
	# a plugin whose profiles changed under the same pin kept the approval.
	var ws := await _make_workspace()
	var params := _review_params()
	params["profiles"] = [
		{"name": "Tools", "tiles": 2, "programs": ["omp"],
			"plans": ["omp\u001f--model", "-i"]},
	]
	ws._show_plugin_review(14, params, 60_000)
	var dialog := _dialog(ws)
	assert_not_null(dialog, "the review dialog must open")
	# No client holds this request in the test (see the answered-path test).
	gut.error_tracker.disabled = true
	dialog.confirmed.emit()
	gut.error_tracker.disabled = false
	assert_true(TrustedStore.is_plugin_approved("owner/demo", "abc1234"),
		"accepting approves the pinned revision")
	assert_eq(TrustedStore.plugin_plans("owner/demo", "abc1234"), ["omp\u001f--model", "-i"],
		"and records the plans the review listed")
	assert_eq(ws._pending_plugin_reviews.size(), 0, "the accepted review is settled")
	# The accepted install schedules a deferred store re-read; let it land
	# while the mock is still installed (the workspace tear-down would leave
	# the callback on a freed object otherwise).
	await get_tree().create_timer(2.1).timeout

# ── Same-name profile replacement ──────────────────────────────────────

func _replacement_params() -> Dictionary:
	var params := _review_params()
	params["profiles"] = [{
		"name": "Agent Workspace", "tiles": 3, "programs": [], "plans": [],
	}]
	return params

func test_the_review_names_a_user_profile_it_will_replace():
	var ws := await _make_workspace()
	ProfileManager.add_profile("Agent Workspace", [])
	ws._show_plugin_review(21, _replacement_params(), 60_000)
	var dialog := _dialog(ws)
	assert_not_null(dialog)
	assert_string_contains(AppDialog.body_of(dialog),
		"Replaces your profile(s): Agent Workspace",
		"the review is the consent surface for the replacement")
	await get_tree().create_timer(2.1).timeout

func test_accepting_a_replacement_deletes_the_profile_after_the_plugin_lands():
	var ws := await _make_workspace()
	ProfileManager.add_profile("Agent Workspace", [])
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ws._show_plugin_review(22, _replacement_params(), 60_000)
	var dialog := _dialog(ws)
	assert_not_null(dialog)
	gut.error_tracker.disabled = true
	dialog.confirmed.emit()
	gut.error_tracker.disabled = false
	assert_true(ws._pending_profile_replacements.has("owner/demo"),
		"the accepted install remembers the replacement")

	# The CLI writes the record after it reads the answer; answer with the
	# plugin's raw profile before the deferred pickup fires.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "owner/demo", "revision": "abc1234",
		"name": "Agent Workspace", "tiles": [],
	}])
	await get_tree().create_timer(2.1).timeout

	assert_eq(ProfileManager.find_user_profile("Agent Workspace"), -1,
		"the user's copy is gone once the plugin really landed")
	var plugin_rows := 0
	for profile in ProfileManager.get_all_profiles():
		if profile.get("plugin", false) == true:
			plugin_rows += 1
			assert_eq(profile.get("name"), "Agent Workspace",
				"the plugin takes the bare name after the replacement")
	assert_eq(plugin_rows, 1)
	ConceptManager.plugin_concepts_source = Callable()

func test_a_failed_install_does_not_delete_the_user_profile():
	var ws := await _make_workspace()
	ProfileManager.add_profile("Agent Workspace", [])
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ws._show_plugin_review(23, _replacement_params(), 60_000)
	var dialog := _dialog(ws)
	assert_not_null(dialog)
	gut.error_tracker.disabled = true
	dialog.confirmed.emit()
	gut.error_tracker.disabled = false

	# No plugin record ever appears.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	await get_tree().create_timer(2.1).timeout

	assert_ne(ProfileManager.find_user_profile("Agent Workspace"), -1,
		"an install that never landed must leave the user's profile alone")
	assert_false(ws._pending_profile_replacements.has("owner/demo"),
		"the pending promise is settled either way")
	ConceptManager.plugin_concepts_source = Callable()
