extends GutTest
# Contract tests across the IPC seam: `WorkspaceIpcHandlers.handle` against the
# workspace it drives — the real dispatch table, the real id/label resolution,
# the real panes.
#
# The coverage this replaces reimplemented `_resolve_pane_target`, the listPanes
# response and the error envelope inside the test file and asserted on those
# copies (its own header said so), so a change to the shipped handlers — the id
# and label resolution IPC targeting rests on, above all — could not fail it.
#
# One workspace for the whole script: every instance schedules a deferred
# concept push 2 s after `_ready`, and freeing it before that timer fires
# leaves the callback on a freed object, so an instance per test would cost
# ~2 s of waiting each.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
## Everything the workspace answered through its `send_ipc_answer` seam, as
## `{id, ok, payload}`. A deferred answer has no socket behind it in a GUT run
## (`respond_ipc` writes to the Rust queue), so this is how one is observed.
var _sent: Array = []

func _collect_answer(id: int, ok: bool, payload: String) -> void:
	_sent.append({"id": id, "ok": ok, "payload": payload})

func before_all():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	# The plugin seams stay off the real store for the whole script: the
	# `pluginsChanged` arm and the deferred install refresh both re-read the
	# concept set now, and a dev machine's plugins are not this test's input.
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager.refresh_plugin_concepts()
	_ws = WorkspaceScript.new()
	_ws.send_ipc_answer = _collect_answer
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

func after_all():
	# Let the workspace's deferred concept push land while it is still alive.
	await get_tree().create_timer(2.1).timeout
	remove_child(_ws)
	_ws.free()
	_ws = null
	ConceptManager.plugin_concepts_source = Callable()
	ConceptManager._plugin_concept_entries = []
	MockAutoloads.teardown()

func _spawn(type_name: String) -> Control:
	var body = _ws._spawn_pane(type_name, {})
	assert_not_null(body, "spawning a %s pane must work" % type_name)
	return body

## The pane the IPC target names, or null when resolution refused it.
func _target(target: String) -> Control:
	return _ws._resolve_pane_target(target).get("body")

# ── listPanes ↔ pane targeting ─────────────────────────────────────────

func test_every_listed_id_addresses_the_pane_it_names():
	var extra = _spawn("code_viewer")
	var result = WorkspaceIpcHandlers.handle(_ws, "listPanes", {})
	assert_true(result is Dictionary and result.has("panes"), "listPanes must answer a panes array")
	assert_eq(int(result["count"]), _ws._tm.tiles.size(), "count must match the live tile list")
	assert_eq((result["panes"] as Array).size(), _ws._tm.tiles.size())

	for entry in result["panes"]:
		var pane_id := str(entry["id"])
		var focus = WorkspaceIpcHandlers.handle(_ws, "focusPane", {"pane_id": pane_id})
		assert_true(
			focus is Dictionary and focus.get("success", false),
			"the id listPanes reports (%s) must address the pane IPC targeting resolves" % pane_id
		)
		assert_eq(
			_ws._tm.last_body, _target(pane_id),
			"focusPane must make the pane it resolved the active one"
		)

	# The label is the legacy spelling of the same target, and it must resolve
	# to the pane carrying it rather than to whichever pane comes first.
	var by_label = WorkspaceIpcHandlers.handle(_ws, "focusPane", {"pane_id": str(extra.pane_label)})
	assert_true(by_label.get("success", false), "the pane label must still address its pane")
	assert_eq(_ws._tm.last_body, extra, "label targeting must activate the labelled pane")

	# A pane that cannot take keyboard focus must not be handed the keys: the
	# activation above must leave the keyboard owner released.
	assert_null(
		_ws.get_viewport().gui_get_focus_owner() as TerminalPane,
		"activating a read-only pane must not leave a terminal holding keyboard focus"
	)

	_ws._kill_now(extra)

# ── newPane: the pane the caller asked for ─────────────────────────────
#
# The MCP tool surface advertises clap's ids (`pane_type`, `title`) and
# `wire.rs` translates them into the keys this handler reads (`type`,
# `title_label`). For a while nothing translated them: the handler looked up
# `type`, got its default, and every MCP call created a terminal.

func test_new_pane_creates_the_type_the_caller_names():
	var answer = WorkspaceIpcHandlers.handle(_ws, "newPane", {"type": "code_viewer"})
	assert_true(answer is Dictionary, "newPane must answer a document")
	assert_false(answer.has("error"), "a registered type must spawn: %s" % answer)
	assert_eq(str(answer.get("type", "")), "code_viewer", "the answer names the type it created")
	var body := _target(str(answer.get("pane_id", "")))
	assert_true(
		body is CodeViewerPane,
		"the spawned body must be the requested pane type, not the default one"
	)
	_ws._kill_now(body)

func test_new_pane_applies_the_display_title_it_is_given():
	var answer = WorkspaceIpcHandlers.handle(_ws, "newPane", {
		"type": "file_tree", "title": "MARKER",
	})
	assert_false(answer.has("error"), "%s" % answer)
	var body := _target(str(answer.get("pane_id", "")))
	var wrapper: Control = null
	for t in _ws._tm.tiles:
		if _ws._tm._find_body(t.wrapper) == body:
			wrapper = t.wrapper
	assert_not_null(wrapper, "the new pane must own a tile")
	var label = wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
	assert_not_null(label, "every tile carries a title label")
	assert_eq(
		str(label.text).strip_edges(), "MARKER",
		"the title must reach the title bar, where a caller can see it"
	)
	_ws._kill_now(body)

func test_new_pane_honours_focus():
	var focused = WorkspaceIpcHandlers.handle(_ws, "newPane", {"type": "code_viewer", "focus": true})
	assert_false(focused.has("error"), "%s" % focused)
	var eager := _target(str(focused.get("pane_id", "")))
	assert_eq(_ws._tm.last_body, eager, "focus:true must make the new pane the active one")

	var quiet = WorkspaceIpcHandlers.handle(_ws, "newPane", {"type": "code_viewer", "focus": false})
	assert_false(quiet.has("error"), "%s" % quiet)
	var passive := _target(str(quiet.get("pane_id", "")))
	assert_eq(_ws._tm.last_body, eager, "focus:false must leave the active pane where it was")

	# A string would be truthy in GDScript: coerced, it focuses the opposite of
	# what `"false"` says, so it is refused instead.
	var refused = WorkspaceIpcHandlers.handle(_ws, "newPane", {"type": "code_viewer", "focus": "true"})
	assert_true(refused.has("error"), "a non-boolean focus must be refused, not coerced")

	_ws._kill_now(passive)
	_ws._kill_now(eager)

func test_new_pane_split_reaches_the_tile_rect():
	# One full-grid terminal, so the assertion is about the direction rather
	# than whatever layout the tests above left behind.
	_ws._tm.reset()
	var first = _spawn("terminal")
	var answer = WorkspaceIpcHandlers.handle(_ws, "newPane", {
		"type": "code_viewer", "split": "top", "focus": false,
	})
	assert_false(answer.has("error"), "%s" % answer)
	var fresh := _target(str(answer.get("pane_id", "")))
	assert_not_null(fresh, "the caller must get the pane it created")
	assert_eq(_ws._tm.tiles.size(), 2, "one new tile beside the one terminal")
	var half := PaneTypes.GRID / 2
	var target_tile: Dictionary = _ws._tm.tiles[0]
	var fresh_tile: Dictionary = _ws._tm.tiles[1]
	assert_eq(
		Rect2i(target_tile.col, target_tile.row, target_tile.cspan, target_tile.rspan),
		Rect2i(0, half, PaneTypes.GRID, half),
		"the requested side must move the target below the new pane")
	assert_eq(
		Rect2i(fresh_tile.col, fresh_tile.row, fresh_tile.cspan, fresh_tile.rspan),
		Rect2i(0, 0, PaneTypes.GRID, half),
		"the new pane must occupy the requested top half")

	# The CLI's clap enum cannot emit this, but raw IPC and an MCP client can:
	# it is a bad parameter, refused before anything spawns.
	var refused = WorkspaceIpcHandlers.handle(_ws, "newPane", {
		"type": "code_viewer", "split": "sideways",
	})
	assert_true(refused.has("error"), "a side the CLI cannot emit must be refused")
	assert_eq(int(refused["error"]["code"]), -32602, "a bad side is bad params, not a failed spawn")
	assert_eq(_ws._tm.tiles.size(), 2, "a refused side must not create a pane")

	_ws._kill_now(fresh)

# ── The drain loop's own body ──────────────────────────────────────────
#
# `Workspace._poll_ipc_requests` cannot be driven from a test: it reads the
# static Rust queue. `WorkspaceIpcHandlers.dispatch_request` is that loop's
# per-request body, so this drives the real dispatch and envelope instead of a
# copy of the params decision.

func test_a_batch_produces_one_response_per_request():
	var batch := [
		{"id": 41, "method": "paneStatus", "params": "{}", "timeout_ms": 5000},
		{"id": 42, "method": "paneRead", "params": "[1,2]", "timeout_ms": 5000},
		{"id": 43, "method": "noSuchMethod", "params": "{}", "timeout_ms": 5000},
	]
	var answers := []
	for req in batch:
		answers.append_array(WorkspaceIpcHandlers.dispatch_request(_ws, req))
	assert_eq(answers.size(), 3, "one bad request must not cost another its answer")
	assert_eq(
		[int(answers[0]["id"]), int(answers[1]["id"]), int(answers[2]["id"])],
		[41, 42, 43], "every request must be answered, in order")

	assert_true(bool(answers[0]["success"]), "paneStatus must succeed")
	assert_true(
		answers[0]["payload"] is Dictionary and answers[0]["payload"].has("panes"),
		"a success payload is the handler's own document")

	assert_false(bool(answers[1]["success"]), "a non-object params must be refused")
	assert_eq(int(answers[1]["payload"]["code"]), -32602)
	assert_string_contains(str(answers[1]["payload"]["message"]), "params")

	assert_false(bool(answers[2]["success"]), "an unknown method must be refused")
	assert_eq(int(answers[2]["payload"]["code"]), -32601)
	# The flat shape: the error object itself, not `{"error": {...}}` one level
	# down, which the Rust edge would then stringify into the message.
	assert_true(answers[2]["payload"].has("code") and answers[2]["payload"].has("message"))
	assert_false(answers[2]["payload"].has("error"), "the answer must not nest a second envelope")

func test_a_pane_wait_is_booked_rather_than_answered_in_the_batch():
	var terminal = _spawn("terminal")
	var answers = WorkspaceIpcHandlers.dispatch_request(_ws, {
		"id": 44,
		"method": "paneWait",
		"params": JSON.stringify({
			"pane_id": str(terminal.attachment_id), "pattern": "never", "timeout_ms": 500,
		}),
		"timeout_ms": 5000,
	})
	assert_eq(answers, [], "a wait answers from the wait poll, frames later")
	assert_true(_ws._pending_waits.has("44"), "the request must be booked for that poll")
	_ws._pending_waits.erase("44")
	_ws._kill_now(terminal)

func test_an_expired_plugin_review_opens_no_dialog():
	var answers = WorkspaceIpcHandlers.dispatch_request(_ws, {
		"id": 45, "method": "pluginInstall", "params": "{}", "timeout_ms": 0,
	})
	assert_eq(answers, [], "an expired review has no channel left to answer")

# ── A pane answer waits for that pane's child ──────────────────────────
#
# `newPane`/`paneRun` answer a `pane_id` before the pane's child exists: a
# terminal starts it from the first size its tile is laid out at, after the
# drain returns. So the answer is held until the pane reports the start —
# without that, a spawn that failed answered a success over a tile that could
# never run anything (the `new-pane --command` defect, where the command line
# was spawned as the pane's program).

const START_SETTLE_TIMEOUT_MS := 5000

## Wait out a held pane answer (the start lands a frame or two after dispatch).
func _settle_pane_starts() -> void:
	var deadline := Time.get_ticks_msec() + START_SETTLE_TIMEOUT_MS
	while not _ws._pending_pane_starts.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

## Dispatch one request the way the drain loop does, then wait out whatever it
## deferred.
func _dispatch_and_settle(req: Dictionary) -> Array:
	var answers = WorkspaceIpcHandlers.dispatch_request(_ws, req)
	await _settle_pane_starts()
	return answers

## The pane's text, once it holds `marker` (or when the deadline passes).
func _read_until(pane_id: String, marker: String) -> String:
	var text := ""
	var deadline := Time.get_ticks_msec() + START_SETTLE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		text = str(WorkspaceIpcHandlers.handle(
			_ws, "paneRead", {"pane_id": pane_id, "lines": 200}).get("text", ""))
		if text.contains(marker):
			return text
		await get_tree().process_frame
	return text

func test_new_pane_command_runs_a_compound_command_line():
	_sent.clear()
	var answers = await _dispatch_and_settle({
		"id": 51, "method": "newPane", "timeout_ms": 4000,
		"params": JSON.stringify({
			"type": "terminal", "command": "echo NP_ONE; echo NP_TWO",
		}),
	})
	assert_eq(answers, [], "a pane answer is held until its child has started")
	assert_eq(_sent.size(), 1, "the held answer must still arrive")
	assert_eq(int(_sent[0]["id"]), 51, "the answer must answer the request that asked")
	assert_true(bool(_sent[0]["ok"]), "a started pane answers success: %s" % _sent[0]["payload"])
	var doc = JSON.parse_string(str(_sent[0]["payload"]))
	assert_true(doc is Dictionary and doc.has("pane_id"), "a success payload is the pane document")
	assert_eq(str(doc.get("type", "")), "terminal")

	var body := _target(str(doc["pane_id"]))
	assert_not_null(body, "the answer's pane_id must address the pane it created")
	# The line is an argument of the configured shell, never the program.
	assert_eq(str(body.shell_command), str(SettingsManager.cfg_shell_command),
		"the configured shell must stay the pane's program")
	var args: Array = body.shell_args
	assert_eq(args.size(), 2, "one run flag and the command line")
	assert_true(str(args[0]) in ["-c", "/c"], "the shell family's own run flag")
	assert_eq(str(args[1]), "echo NP_ONE; echo NP_TWO",
		"the whole command line must be one argument, not a program name")

	var text := await _read_until(str(doc["pane_id"]), "NP_TWO")
	assert_true(text.contains("NP_ONE") and text.contains("NP_TWO"),
		"both halves of a `;`-separated command line must run: %s" % text)
	_ws._kill_now(body)

func test_a_failed_spawn_answers_an_error_and_leaves_no_pane():
	_sent.clear()
	var toasts: Array = []
	var capture := func(data: Dictionary): toasts.append(data)
	ToastManager.toast_requested.connect(capture)
	var tiles_before: int = _ws._tm.tiles.size()
	var saved_shell := SettingsManager.cfg_shell_command
	# The spawn failure a shell-program contract can still produce: the program
	# the settings name does not exist.
	SettingsManager.cfg_shell_command = "/nonexistent/gpty-no-such-program"
	var answers = await _dispatch_and_settle({
		"id": 52, "method": "newPane", "timeout_ms": 4000,
		"params": JSON.stringify({"type": "terminal"}),
	})
	SettingsManager.cfg_shell_command = saved_shell
	ToastManager.toast_requested.disconnect(capture)

	assert_eq(answers, [], "the answer must wait for the start, not report it early")
	assert_eq(_sent.size(), 1, "a refusal must still answer its request")
	assert_false(bool(_sent[0]["ok"]), "a pane with no child is not a success")
	var err = JSON.parse_string(str(_sent[0]["payload"]))
	assert_true(err is Dictionary, "the payload is the flat error object, not an envelope")
	assert_string_contains(str(err.get("message", "")), "gpty-no-such-program",
		"the error must name the program that could not be started")
	assert_eq(int(err.get("code", 0)), -32000, "a failed spawn is an application error")
	assert_eq(_ws._tm.tiles.size(), tiles_before,
		"a pane that could not start must be closed, not left as an empty grid")
	assert_eq(toasts.size(), 1, "the refusal must also reach the user")
	assert_string_contains(str(toasts[0].get("text", "")), "gpty-no-such-program",
		"the toast must name the same program the error names")

# The `cli_view` arm starts its program from `_ready`, so its answer is
# synchronous — but it is the same contract: a pane that cannot run is an
# error naming the program, with no tile left behind.

func test_new_pane_cli_view_refuses_a_program_that_cannot_start():
	var tiles_before: int = _ws._tm.tiles.size()
	var toasts: Array = []
	var capture := func(data: Dictionary): toasts.append(data)
	ToastManager.toast_requested.connect(capture)
	var answer = WorkspaceIpcHandlers.handle(_ws, "newPane", {
		"type": "cli_view", "command": "/nonexistent/gpty-no-such-program",
	})
	ToastManager.toast_requested.disconnect(capture)

	assert_true(answer is Dictionary and answer.has("error"),
		"a program that cannot start must not answer a pane: %s" % answer)
	assert_string_contains(str(answer["error"]["message"]), "gpty-no-such-program",
		"the error must name the program that could not be started")
	assert_eq(int(answer["error"].get("code", 0)), -32000,
		"a pane that cannot start is app state, not a bad parameter")
	assert_eq(_ws._tm.tiles.size(), tiles_before, "the refused pane must be closed")
	assert_eq(toasts.size(), 1, "the refusal must also reach the user")
	assert_string_contains(str(toasts[0].get("text", "")), "gpty-no-such-program",
		"the toast must name the same program the error names")

# ── paneStatus: one target, or every pane ──────────────────────────────

func test_pane_status_without_a_pane_covers_every_pane():
	var terminal = _spawn("terminal")
	var viewer = _spawn("code_viewer")
	var terminal_id := str(terminal.attachment_id)
	var viewer_id := str(viewer.attachment_id)

	var result = WorkspaceIpcHandlers.handle(_ws, "paneStatus", {})
	assert_true(result is Dictionary and result.has("panes"), "no target must answer a panes array")
	var entries: Array = result["panes"]
	assert_eq(entries.size(), _ws._tm.tiles.size(), "the aggregate must cover every tile")

	var by_id := {}
	for entry in entries:
		by_id[str(entry["pane_id"])] = entry
	assert_true(by_id.has(terminal_id), "the terminal must be listed")
	assert_true(by_id.has(viewer_id), "the non-terminal must be listed, not dropped")
	var terminal_status = by_id[terminal_id]["status"]
	assert_true(terminal_status is Dictionary, "a terminal must carry its status primitives")
	assert_true(terminal_status.has("running"), "the status document must be paneStatus's own")
	assert_eq(str(by_id[terminal_id]["type"]), "terminal")
	assert_null(by_id[viewer_id]["status"], "a pane without status primitives must say so with null")
	assert_eq(str(by_id[viewer_id]["type"]), "code_viewer")

	# The single-pane contract is unchanged: a terminal answers its status
	# object, and a non-terminal is refused as having no status rather than
	# pretending it does not exist.
	var one = WorkspaceIpcHandlers.handle(_ws, "paneStatus", {"pane_id": terminal_id})
	assert_false(one.has("error"), "a terminal target must answer its status")
	assert_true(one.has("running"), "the single-pane answer must stay the status document itself")
	var not_terminal = WorkspaceIpcHandlers.handle(_ws, "paneStatus", {"pane_id": viewer_id})
	assert_true(not_terminal.has("error"), "a pane without status primitives must be refused")
	assert_string_contains(str(not_terminal["error"]["message"]), "no status primitives")

	_ws._kill_now(terminal)
	_ws._kill_now(viewer)

func test_pane_targeting_accepts_an_id_and_a_legacy_label():
	var by_id = _spawn("code_viewer")
	var by_label = _spawn("code_viewer")
	var by_id_key := str(by_id.attachment_id)
	var by_label_key := str(by_label.pane_label)

	var killed = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": by_id_key})
	assert_true(killed.get("success", false), "killPane must accept an attachment id")
	assert_null(_target(by_id_key), "the pane addressed by id must be gone")
	assert_eq(_target(by_label_key), by_label, "the other pane must survive")

	killed = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": by_label_key})
	assert_true(killed.get("success", false), "killPane must still accept a label")
	assert_null(_target(by_label_key), "the pane addressed by label must be gone")

	var missing = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": "no-such-pane"})
	assert_true(missing.has("error"), "killing an unknown pane must be an error, not a success")

# ── Cross-workspace label resolution ──────────────────────────────────
#
# `attachment_id` is unique across every workspace; a label is numbered per
# workspace and restarts at 1, so two workspaces both hold a "T1" in ordinary
# use. Resolving that label to the active workspace's pane handed an agent's
# command to a pane it never named - the user switching tabs while an agent
# works in the background is enough to trigger it.

## Both workspaces hold a "T1": every targeting method refuses the label,
## names both candidates, and acts on neither pane.
func test_a_label_two_workspaces_share_is_refused_by_every_targeting_method():
	var first = _ws._tm._find_body(_ws._tm.tiles[0].wrapper)
	assert_eq(str(first.pane_label), "T1", "the first workspace's terminal is T1")
	_ws._add_workspace()
	var second = _spawn("terminal")
	assert_eq(str(second.pane_label), "T1", "labels restart in the new workspace")
	assert_ne(str(first.attachment_id), str(second.attachment_id), "ids stay globally unique")

	var first_ws := str(_ws._workspaces[0].name)
	var second_ws := str(_ws._workspaces[1].name)
	var marker := "ambiguous-label-marker"
	var calls := {
		"inject": {"pane_id": "T1", "text": marker},
		"paneRead": {"pane_id": "T1"},
		"paneStatus": {"pane_id": "T1"},
		"killPane": {"pane_id": "T1"},
		"focusPane": {"pane_id": "T1"},
	}
	for method in calls:
		var refused = WorkspaceIpcHandlers.handle(_ws, method, calls[method])
		assert_true(refused.has("error"), "%s must refuse an ambiguous label" % method)
		var message := str(refused["error"]["message"])
		assert_string_contains(message, "ambiguous", "%s must say why it refused" % method)
		assert_string_contains(message, str(first.attachment_id),
			"%s must name the %s candidate's id" % [method, first_ws])
		assert_string_contains(message, str(second.attachment_id),
			"%s must name the %s candidate's id" % [method, second_ws])
		assert_string_contains(message, first_ws, "%s must name the first workspace" % method)
		assert_string_contains(message, second_ws, "%s must name the second workspace" % method)

	assert_eq(_target("T1"), null, "an ambiguous label addresses nothing")
	assert_true(is_instance_valid(first) and is_instance_valid(second),
		"a refused target must not kill or free a pane")
	# The refusal is returned before any write, so no pane can have received
	# the marker; wait out an echo window so a silent delivery could not hide.
	await get_tree().process_frame
	await get_tree().process_frame
	for pane in [first, second]:
		assert_false(str(pane._terminal.get_plain_text(200)).contains(marker),
			"a refused label must deliver nothing to %s" % pane.attachment_id)

	_ws._close_workspace_now(1)

## An id resolves from either workspace (ids are globally unique), and a label
## that only one pane carries still resolves while another workspace is active.
func test_a_unique_label_and_every_id_resolve_from_another_workspace():
	var first = _ws._tm._find_body(_ws._tm.tiles[0].wrapper)
	_ws._add_workspace()
	var second = _spawn("terminal")
	assert_eq(str(second.pane_label), first.pane_label, "both workspaces hold a T1")

	for body in [first, second]:
		var by_id = WorkspaceIpcHandlers.handle(
			_ws, "paneRead", {"pane_id": str(body.attachment_id), "lines": 20})
		assert_false(by_id.has("error"), "an id must resolve from either workspace")
		assert_eq(str(by_id["text"]), str(body._terminal.get_plain_text(20)),
			"the id must read the pane it names, not the active workspace's")

	# With one carrier left, the label is unambiguous again - even though the
	# caller is looking at another workspace.
	_ws._kill_now(second)
	assert_eq(_target(str(first.pane_label)), first, "a unique label must still resolve")
	var by_label = WorkspaceIpcHandlers.handle(
		_ws, "paneRead", {"pane_id": str(first.pane_label), "lines": 20})
	assert_false(by_label.has("error"), "a unique label must still address its pane")
	assert_eq(str(by_label["text"]), str(first._terminal.get_plain_text(20)))

	_ws._close_workspace_now(1)

## Give a pane unsaved work, the way the wiki editor does when a note is typed
## into: the IPC seam only cares that the pane reports `has_unsaved_state()`.
func _dirty(pane: Control) -> void:
	pane._current_rel = "note.md"
	pane._saved_text = "before"
	pane._editable_note = true
	pane._editor.text = "after"

func test_kill_pane_refuses_a_pane_holding_unsaved_work():
	# A caller cannot answer the pane's Save/Discard dialog, so a pane with
	# unsaved work is refused rather than silently thrown away — the rule
	# `layoutLoad` already applies to an untrusted profile.
	var wiki = _spawn("wiki")
	_dirty(wiki)
	var wiki_id := str(wiki.attachment_id)

	var refused = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": wiki_id})
	assert_true(refused.has("error"), "an unsaved pane must be refused, not killed")
	assert_true(is_instance_valid(wiki), "and it must survive the call")

	# The same call goes through once nothing would be lost.
	wiki._saved_text = wiki._editor.text
	var killed = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": wiki_id})
	assert_true(killed.get("success", false), "a clean pane kills as before")

func test_layout_load_refuses_while_a_pane_holds_unsaved_work():
	# Activating a profile resets the active workspace, so the same refusal
	# applies. The probe profile is empty, so nothing about it is untrusted and
	# nothing spawns — the unsaved pane is the only thing that can refuse.
	ProfileManager.add_profile("Close guard probe", [])
	var wiki = _spawn("wiki")
	_dirty(wiki)

	var refused = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "Close guard probe"})
	assert_true(refused.has("error"), "a load over unsaved work must refuse")
	assert_true(is_instance_valid(wiki), "and nothing may be reset")

	wiki._saved_text = wiki._editor.text
	var loaded = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "Close guard probe"})
	assert_true(loaded.get("success", false), "a clean workspace loads as before")
	await get_tree().process_frame
	assert_false(is_instance_valid(wiki), "and the load really did replace the pane set")

	# Drop the probe again, so the profile list stays what the other tests
	# expect from the store.
	var profiles = ProfileManager.get_all_profiles()
	for i in profiles.size():
		if str(profiles[i].get("name", "")) == "Close guard probe":
			ProfileManager.delete_profile(i)
			break

# ── Method contracts ───────────────────────────────────────────────────

func test_terminal_only_methods_refuse_other_panes():
	var viewer = _spawn("code_viewer")
	var viewer_id := str(viewer.attachment_id)

	var read = WorkspaceIpcHandlers.handle(_ws, "paneRead", {"pane_id": viewer_id})
	assert_true(read.has("error"), "paneRead must refuse a pane that has no terminal")

	var injected = WorkspaceIpcHandlers.handle(_ws, "inject", {"pane_id": viewer_id, "text": "x"})
	assert_true(injected.has("error"), "inject must refuse a pane that has no terminal")

	var absent = WorkspaceIpcHandlers.handle(_ws, "paneRead", {"pane_id": "no-such-pane"})
	assert_true(absent.has("error"), "paneRead must refuse an unknown pane")

	_ws._kill_now(viewer)

func test_unknown_method_answers_method_not_found():
	var result = WorkspaceIpcHandlers.handle(_ws, "notAMethod", {})
	assert_true(result.has("error"), "an unknown method must answer an error")
	assert_eq(int(result["error"]["code"]), -32601, "unknown methods answer JSON-RPC -32601")

# ── layoutList / layoutLoad ────────────────────────────────────────────

func test_layout_list_reports_the_profiles_the_store_holds():
	ProfileManager.add_profile("contract-listed", [])
	var result = WorkspaceIpcHandlers.handle(_ws, "layoutList", {})
	assert_true(result is Dictionary and result.has("layouts"), "layoutList must answer layouts")
	assert_true(
		(result["layouts"] as Array).has("contract-listed"),
		"a saved profile must appear in layoutList"
	)

func test_layout_save_answers_the_name_the_store_kept():
	# A save captures the active workspace, so empty it first: the two saves
	# then differ in nothing but their name, and the answered profile loads
	# without a trust prompt.
	for pane in _ws._pane_bodies(_ws._active_workspace()):
		_ws._kill_now(pane)
	var first = WorkspaceIpcHandlers.handle(_ws, "layoutSave", {"name": "contract-dedupe"})
	assert_true(first.get("success", false), "the first save must succeed")
	assert_eq(str(first.get("name", "")), "contract-dedupe")
	var second = WorkspaceIpcHandlers.handle(_ws, "layoutSave", {"name": "contract-dedupe"})
	assert_true(second.get("success", false), "the second save must succeed too")
	assert_eq(str(second.get("name", "")), "contract-dedupe (2)",
		"a duplicate name is stored with a suffix, so the answer must name that row")
	var listed = WorkspaceIpcHandlers.handle(_ws, "layoutList", {})
	assert_true((listed.get("layouts", []) as Array).has("contract-dedupe (2)"),
		"the answered name must be the one layoutList reports")
	var loaded = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-dedupe (2)"})
	assert_true(loaded.get("success", false), "the answered name must load")

func test_layout_load_refuses_an_untrusted_profile():
	ProfileManager.add_profile("contract-untrusted", [
		{
			"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(), "shell_args": ["-c", "echo pwned"]},
		},
	])
	var tiles_before: int = _ws._tm.tiles.size()

	var refused = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-untrusted"})
	assert_true(refused.has("error"), "an untrusted profile must be refused over IPC")
	assert_string_contains(str(refused["error"]["message"]), "GUI", "the refusal must point at the GUI")
	assert_eq(_ws._tm.tiles.size(), tiles_before, "a refused load must not touch the workspace")

	ProfileManager.add_profile("contract-trusted", [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60, "settings": {"type": "code_viewer"}},
	])
	var loaded = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-trusted"})
	assert_true(loaded.get("success", false), "a trusted profile must still load over IPC")
	assert_eq(_ws._tm.tiles.size(), 1, "the trusted profile replaces the layout")

# ── Consent memory ────────────────────────────────────────────────────

func test_consented_content_skips_the_trust_gates():
	var version: String = GptyTerminal.get_app_version()
	# A legacy builtin approval still covers the plan it recorded; the seeded
	# defaults are user profiles now, so their consent comes through this
	# plan-key walk rather than a builtin origin.
	TrustedStore.approve_builtin("contract-legacy", version, ["contract-tool"])

	# A user profile is covered when every untrusted tile's exact plan was
	# approved; any uncovered plan keeps the gate.
	var covered := {"name": "contract-covered", "tiles": [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]}
	assert_true(_ws._profile_consented(covered), "an approved plan covers a user profile")
	var uncovered := {"name": "contract-uncovered", "tiles": [
		{"settings": {"type": "terminal", "command": "contract-other"}},
	]}
	assert_false(_ws._profile_consented(uncovered), "an unapproved plan still asks")

	# The restore gate: covered plans stop counting, anything else does not,
	# and a trusted tile never counts with or without a record.
	var tiles_covered: Array[Dictionary] = [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]
	assert_false(_ws._tiles_untrusted_without_consent(tiles_covered, ""))
	var tiles_uncovered: Array[Dictionary] = [
		{"settings": {"type": "terminal", "command": "contract-other"}},
	]
	assert_true(_ws._tiles_untrusted_without_consent(tiles_uncovered, ""))
	var tiles_trusted: Array[Dictionary] = [{"settings": {"type": "terminal"}}]
	assert_false(_ws._tiles_untrusted_without_consent(tiles_trusted, ""))

func test_plugin_profiles_are_consented_by_their_installed_revision():
	var version: String = GptyTerminal.get_app_version()
	var plugin_tiles: Array[Dictionary] = [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]
	var plugin_profile := {
		"_origin": "plugin", "name": "contract-plugin",
		"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6",
		"tiles": plugin_tiles,
	}
	assert_true(_ws._tiles_untrusted(plugin_tiles),
		"the plugin's tiles name a program, so the gate applies")

	# A plan-key approval covers a user profile but not a plugin profile: the
	# plugin branch decides first, and the install review's record is the
	# answer the user actually gave.
	TrustedStore.approve_builtin("contract-plan", version, ["contract-tool"])
	assert_false(_ws._profile_consented(plugin_profile),
		"a plan approval is not the plugin's install record")

	TrustedStore.approve_plugin("godot-pty/gpty-omp", "a1b2c3d4e5f6", ["contract-tool"])
	assert_true(_ws._profile_consented(plugin_profile),
		"the approved revision activates without the trust dialog")

	# The record keys on the pin, so a newer revision re-prompts.
	var newer := plugin_profile.duplicate(true)
	newer["revision"] = "f6e5d4c3b2a1"
	assert_false(_ws._profile_consented(newer), "another revision re-prompts")

	# ...and the approved revision covers only the plans the review listed:
	# tiles that changed under the same pin are a new decision.
	var changed := plugin_profile.duplicate(true)
	changed["tiles"] = [{"settings": {"type": "terminal", "command": "contract-other"}}]
	assert_false(_ws._profile_consented(changed),
		"a plugin profile whose tiles changed under the same revision re-prompts")

	# A record written before plans were stored still approves the revision,
	# and covers no plans — so that profile asks once more.
	TrustedStore.approve_plugin("godot-pty/gpty-omp-alt", "0123456789ab")
	var legacy := plugin_profile.duplicate(true)
	legacy["plugin_id"] = "godot-pty/gpty-omp-alt"
	legacy["revision"] = "0123456789ab"
	assert_true(TrustedStore.is_plugin_approved("godot-pty/gpty-omp-alt", "0123456789ab"))
	assert_false(_ws._profile_consented(legacy),
		"an approval without plans cannot cover untrusted tiles")

func test_a_user_profile_cannot_claim_where_it_came_from():
	var version: String = GptyTerminal.get_app_version()
	# Both records the file could point at exist and cover this plan.
	TrustedStore.approve_builtin("contract-claimed", version, ["contract-tool"])
	TrustedStore.approve_plugin("godot-pty/gpty-omp", "a1b2c3d4e5f6", ["contract-tool"])

	# A user profile claiming every identity field, with its own different
	# tile. The loader strips the claims, so the entry reads as user content
	# and the plan walk runs — the approval above never gets consulted.
	MockAutoloads.set_store(ProfileManager.PROFILES_FILE, {"profiles": [{
		"name": "contract-claimed",
		"builtin": true,
		"plugin": true,
		"plugin_id": "godot-pty/gpty-omp",
		"revision": "a1b2c3d4e5f6",
		"_origin": "builtin",
		"tiles": [{"settings": {"type": "terminal", "command": "contract-other"}}],
	}]})
	ProfileManager.load_profiles()
	var claimed := ProfileManager.find_profile("contract-claimed")
	assert_false(claimed.is_empty(), "the user profile must load")
	assert_eq(claimed.get("_origin"), ProfileManager.ORIGIN_USER,
		"provenance comes from the loader, not from the file")
	assert_false(_ws._profile_consented(claimed),
		"fields inside a user profile never choose which record is consulted")

func test_layout_load_sees_installed_plugin_profiles():
	# The merge this item adds is what makes a plugin profile reachable by
	# name over IPC — layoutList offers it and layoutLoad gates on the
	# plugin's record. A plugin id of its own, so no other case in this
	# script's shared consent store can stand in for the answer.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-herdr", "revision": "c0ffee123456",
		"name": "contract-plugin-load",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "shell_args": ["-i"]}}],
	}])
	ProfileManager.refresh_plugin_profiles()

	var listed = WorkspaceIpcHandlers.handle(_ws, "layoutList", {})
	assert_true(listed is Dictionary and listed.has("layouts"), "layoutList must answer layouts")
	assert_true((listed["layouts"] as Array).has("contract-plugin-load"),
		"an installed plugin profile must be listed")

	var refused = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-plugin-load"})
	assert_true(refused.has("error"), "an unapproved plugin profile must be refused over IPC")
	assert_string_contains(str(refused["error"]["message"]), "GUI",
		"the refusal must point at the GUI")

	TrustedStore.approve_plugin("godot-pty/gpty-herdr", "c0ffee123456", ["-i"])
	var loaded = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-plugin-load"})
	assert_true(loaded.get("success", false),
		"an approved plugin profile must load over IPC")
	assert_eq(_ws._tm.tiles.size(), 1, "the plugin profile replaces the layout")

	# Leave the merged set empty again — the mocked autoload outlives this
	# test for the whole script — without asking the real store.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

func test_an_admin_notification_refreshes_the_profile_list():
	# The install review refreshes on a timer because the CLI moves the clone
	# into place only after it reads the answer. An admin action is the
	# opposite: the store is already written when the notification arrives, so
	# the refresh is synchronous and `refreshed: true` means the GUI has
	# caught up. Without it, `gpty plugin uninstall` left the row in a running
	# GUI (and kept activating it from memory) until the next restart.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6",
		"name": "contract-admin-refresh",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal"}}],
	}])
	ProfileManager.refresh_plugin_profiles()
	assert_false(ProfileManager.find_profile("contract-admin-refresh").is_empty(),
		"precondition: the installed plugin's profile is listed")

	# What the store answers once `gpty plugin uninstall` has removed it.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	var answer = WorkspaceIpcHandlers.handle(
		_ws, "pluginsChanged", {"action": "uninstall", "id": "godot-pty/gpty-omp"})
	assert_eq(answer.get("refreshed"), true, "the notification must re-read the store")
	assert_true(ProfileManager.find_profile("contract-admin-refresh").is_empty(),
		"an uninstalled plugin's profile must leave the list without a restart")

	var refused = WorkspaceIpcHandlers.handle(_ws, "pluginsChanged", {"action": "rm -rf /"})
	assert_true(refused.has("error"),
		"an action outside the vocabulary must be refused, not ignored")

	# The id is inert today but validated anyway (boundary property, not a
	# consumer's concern) — and a refusal must precede the refresh, so a
	# malformed notice cannot move the profile list as a side effect. The
	# source below would add a row if the handler got as far as refreshing.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-nvim", "revision": "deadbeef1234",
		"name": "contract-refused-notice",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal"}}],
	}])
	var bad_id = WorkspaceIpcHandlers.handle(
		_ws, "pluginsChanged", {"action": "disable", "id": "Not An Id"})
	assert_true(bad_id.has("error"), "a malformed plugin id must be refused")
	assert_string_contains(str(bad_id["error"]["message"]), "plugin id",
		"the refusal must name the field it refused")
	assert_true(ProfileManager.find_profile("contract-refused-notice").is_empty(),
		"a refused notice must not refresh the store")

	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

func test_accepted_plugin_profiles_are_read_after_the_clone_lands():
	# The install review's accept path refreshes on a timer: the CLI only
	# moves the accepted clone into place after it reads the answer, so an
	# immediate re-read would miss the profiles it wrote.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

	# What the store answers once the install has landed.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-nvim", "revision": "deadbeef1234",
		"name": "contract-installed",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "code_viewer"}}],
	}])
	_ws._refresh_plugin_content_deferred()
	assert_true(ProfileManager.find_profile("contract-installed").is_empty(),
		"the refresh must wait for the install to land, not read immediately")

	await get_tree().create_timer(2.1).timeout
	var found := ProfileManager.find_profile("contract-installed")
	assert_false(found.is_empty(),
		"the deferred refresh must pick up the installed plugin's profiles")
	assert_true(found.get("plugin", false), "it must arrive as a plugin profile")
	assert_eq(found.get("plugin_id"), "godot-pty/gpty-nvim")

	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

func test_accepted_plugin_concepts_are_read_after_the_clone_lands():
	# The concept half of the same deferred read: the CLI writes the record
	# only after the human answers, so the concept set has to be picked up on
	# the same timer, from the same record.
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager.refresh_plugin_concepts()

	ConceptManager.plugin_concepts_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-nvim", "revision": "deadbeef1234",
		"name": "contract-concept",
		"concept": {"name": "contract-concept", "trigger": "^contract",
			"actions": [{"target": "code_viewer"}]},
	}])
	_ws._refresh_plugin_content_deferred()
	assert_eq(ConceptManager.plugin_sources().size(), 0,
		"the refresh must wait for the install to land, not read immediately")

	await get_tree().create_timer(2.1).timeout
	assert_true(ConceptManager.plugin_sources().has("contract-concept"),
		"the deferred refresh must pick up the installed plugin's concepts")
	assert_eq(ConceptManager.plugin_sources()["contract-concept"].get("plugin_id"),
		"godot-pty/gpty-nvim", "the rule keeps its provenance")
	assert_not_null(
		_find_concept(ConceptManager.get_concepts(), "contract-concept"),
		"the rule must reach the merged set the engine is pushed")

	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager.refresh_plugin_concepts()

func _find_concept(concepts: Array, name: String) -> Dictionary:
	for c in concepts:
		if c is Dictionary and c.get("name", "") == name:
			return c
	return {}

# ── Refusal codes: a bad parameter is -32602, app state is -32000 ───────
#
# The pane API's refusals were split by whichever code the arm happened to
# inherit: `newPane`'s `focus`/`split`/`command` checks answered -32602 while
# `Unknown pane type`, `Command required`, `Invalid command`, the plugin
# action/id checks and the wait-pattern checks answered -32000, so a script
# branching on `error.code` could not tell "fix the call" from "the app
# refused" inside one method family. The rule now lives on
# `WorkspaceIpcHandlers.bad_param`/`refused`; this table is what holds every
# arm to it.

func _refusal_params(params: Dictionary, terminal: Control, viewer: Control) -> Dictionary:
	var out := {}
	for key in params:
		var value = params[key]
		if value is String and value == "@terminal":
			out[key] = str(terminal.attachment_id)
		elif value is String and value == "@viewer":
			out[key] = str(viewer.attachment_id)
		else:
			out[key] = value
	return out

## One row per refusal arm of the pane API. A new arm adds its row here, and
## cannot pick a code without saying which kind of refusal it is.
func test_every_refusal_arm_answers_the_code_its_kind_owns():
	var terminal := _spawn("terminal")
	var viewer := _spawn("code_viewer")
	var long_text := "x".repeat(1025)
	var rows := [
		# A value the request named and the handler cannot accept: -32602.
		["newPane", {"type": "nosuchtype"}, -32602, "Unknown pane type"],
		["newPane", {"type": "terminal", "focus": "yes"}, -32602, "`focus` must be a boolean"],
		["newPane", {"type": "terminal", "split": "diagonal"}, -32602, "`split` must be one of"],
		["newPane", {"type": "terminal", "command": long_text}, -32602, "Invalid command"],
		["paneRun", {}, -32602, "Command required"],
		["paneRun", {"command": long_text}, -32602, "Invalid command"],
		["paneWait", {"pane_id": "@terminal", "pattern": ""}, -32602, "Invalid wait pattern"],
		["paneWait", {"pane_id": "@terminal", "pattern": long_text}, -32602, "Invalid wait pattern"],
		["paneRead", {"pane_id": ""}, -32602, "Pane target required"],
		["killPane", {}, -32602, "Pane target required"],
		["inject", {"pane_id": "@terminal", "text": "x".repeat(65537)}, -32602, "exceeds 64 KiB"],
		["broadcast", {}, -32602, "Invalid broadcast request"],
		["layoutSave", {}, -32602, "Profile name required"],
		["layoutSave", {"name": "x".repeat(129)}, -32602, "Profile name too long"],
		["conceptToggle", {}, -32602, "Concept name required"],
		["conceptToggle", {"name": "gpty-no-such-concept"}, -32602, "Unknown concept"],
		["pluginsChanged", {"action": "nuke", "id": "ok-id"}, -32602, "Unknown plugin action"],
		["pluginsChanged", {"action": "enable", "id": "BAD ID"}, -32602, "Malformed plugin id"],
		["vaultWeight", {"vault_path": "relative", "src": "a.md", "target": "b.md", "weight": 5},
			-32602, "not an absolute directory"],
		# App state a well-formed request names: -32000.
		["paneRead", {"pane_id": "nosuchpane"}, -32000, "not found"],
		["paneRead", {"pane_id": "@viewer"}, -32000, "has no readable output"],
		["paneStatus", {"pane_id": "@viewer"}, -32000, "no status primitives"],
		["paneWait", {"pane_id": "@viewer", "pattern": "x"}, -32000, "is not a terminal"],
		["inject", {"pane_id": "@viewer", "text": "x"}, -32000, "is not a terminal"],
		["focusPane", {"pane_id": "nosuchpane"}, -32000, "not found"],
		["killPane", {"pane_id": "nosuchpane"}, -32000, "not found"],
		["layoutLoad", {"name": "gpty-no-such-profile"}, -32000, "not found"],
	]
	var next_id := 900
	for row in rows:
		next_id += 1
		var where := "%s %s" % [row[0], JSON.stringify(row[1])]
		var answers = WorkspaceIpcHandlers.dispatch_request(_ws, {
			"id": next_id,
			"method": row[0],
			"params": JSON.stringify(_refusal_params(row[1], terminal, viewer)),
			"timeout_ms": 5000,
		})
		assert_eq(answers.size(), 1, "%s must be answered in the batch" % where)
		if answers.size() != 1:
			continue
		assert_false(bool(answers[0]["success"]), "%s must be refused" % where)
		var payload: Dictionary = answers[0]["payload"]
		assert_eq(int(payload.get("code", 0)), int(row[2]),
			"%s answered %s; a bad parameter is -32602 and app state is -32000" % [where, payload])
		assert_string_contains(str(payload.get("message", "")), str(row[3]),
			"%s must name its reason" % where)
	_ws._kill_now(terminal)
	_ws._kill_now(viewer)

## The store is the door the row closed: a name the merged set does not hold
## cannot be invented into `concepts.json` one IPC call at a time.
func test_an_unknown_concept_toggle_is_refused_and_writes_nothing():
	var before: Array = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE).get("concepts", []).duplicate(true)
	var refused = WorkspaceIpcHandlers.handle(_ws, "conceptToggle", {"name": "gpty-no-such-concept"})
	assert_true(refused.has("error"), "an unknown concept must be refused")
	assert_eq(int(refused["error"]["code"]), -32602,
		"an unknown name is a bad parameter, like an unknown pane type")
	assert_string_contains(str(refused["error"]["message"]), "Unknown concept")
	var after: Array = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE).get("concepts", [])
	assert_eq(after.size(), before.size(), "a refused toggle must not grow the store")
	assert_true(_find_concept(after, "gpty-no-such-concept").is_empty(),
		"and must not store the name")
	var listed = WorkspaceIpcHandlers.handle(_ws, "conceptList", {})
	assert_true(_find_concept(listed.get("concepts", []), "gpty-no-such-concept").is_empty(),
		"conceptList must not report a phantom row")
	var toggled = WorkspaceIpcHandlers.handle(_ws, "conceptToggle", {"name": "cat_command"})
	assert_true(toggled.get("success", false), "a name the merged set holds must still toggle")
