extends GutTest
# The accessible surface: the A11y helper, the pane identity every body carries,
# the terminal's visible-grid value, and the rule that no glyph-only button
# reaches a screen reader as its private-use codepoint.
#
# Headless cannot prove AT-SPI (no display, no AccessKit driver): what is
# asserted here is the metadata the app produces, and whether an element server
# receives it is `scripts/accessibility-probe`'s job against a rebuilt export.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control


func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()


func after_each():
	A11y.force_enabled = -1
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()


# ── A11y ───────────────────────────────────────────────────────────────

func test_one_line_collapses_whitespace_and_controls():
	assert_eq(A11y.one_line("a\nb\tc\u0007"), "a b c")
	assert_eq(A11y.one_line("  leading and trailing  "), "leading and trailing")
	assert_eq(A11y.one_line("\n\n"), "")
	assert_eq(A11y.one_line(""), "")


func test_one_line_is_capped():
	var long := ""
	for _i in 500:
		long += "x"
	var line := A11y.one_line(long)
	assert_eq(line.length(), A11y.ANNOUNCE_CAP, "an announcement is one bounded line")
	assert_eq(A11y.one_line("abcdefghij", 4), "abcd", "the cap is the caller's too")


func test_publish_carries_text_name_and_live_mode():
	var host := Control.new()
	add_child_autofree(host)
	var node := A11y.publish(host, "A11yLive", "built 3 files", A11y.LIVE_POLITE)
	assert_not_null(node)
	assert_eq(node.accessibility_name, "built 3 files",
		"the published name is what a driver reads")
	# The node must not be a Label: on 4.7.2 a Label's AT-SPI name is its
	# display text, so content carried in `accessibility_name` alone published
	# an empty name (measured 2026-11-13), while a Label given the whole screen
	# as text cost 992 ms of shaping (221x78, measured 2026-11-11).
	assert_false(node is Label, "content is carried by a plain Control's name")
	assert_eq(node.accessibility_live, A11y.LIVE_POLITE,
		"an announcement must reach a reader without focus")
	assert_eq(node.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"a hidden node must never take the pointer")
	assert_eq(node.focus_mode, Control.FOCUS_NONE, "nor the keyboard")
	assert_eq(node.modulate.a, 0.0, "nor the picture")


## Dynamic content is a replacement, not an edit: the engine publishes a
## Control's name once, so the previous node must leave the tree and the fresh
## one must carry the new text under the same slot name.
func test_publish_replaces_the_slot():
	var host := Control.new()
	add_child_autofree(host)
	A11y.publish(host, "A11yText", "first screen")
	var second := A11y.publish(host, "A11yText", "second screen")
	assert_eq(host.get_child_count(), 1, "the slot holds one node, not a history")
	assert_eq(str(host.get_node("A11yText").get_instance_id()), str(second.get_instance_id()))
	assert_eq(second.accessibility_name, "second screen")
	assert_false(second is Label, "a replacement is a plain Control too")


func test_publish_ignores_empty_text():
	var host := Control.new()
	add_child_autofree(host)
	assert_null(A11y.publish(host, "A11yLive", ""), "nothing to say, nothing to publish")
	assert_eq(host.get_child_count(), 0)


## A reader holds the node it was given. Republishing the same line must not
## take it away (an idle pane's tick would churn it once a second).
func test_publish_leaves_an_unchanged_slot_alone():
	var host := Control.new()
	add_child_autofree(host)
	var first := A11y.publish(host, "A11yLive", "same line", A11y.LIVE_POLITE)
	var second := A11y.publish(host, "A11yLive", "same line", A11y.LIVE_POLITE)
	assert_same(second, first, "an unchanged slot is the same element")
	assert_eq(host.get_child_count(), 1)
	assert_false(first.is_queued_for_deletion(), "the node AT reads must stay alive")


func test_publish_replaces_when_the_live_mode_changes():
	var host := Control.new()
	add_child_autofree(host)
	var first := A11y.publish(host, "A11yLive", "same line", A11y.LIVE_POLITE)
	var second := A11y.publish(host, "A11yLive", "same line", A11y.LIVE_OFF)
	assert_ne(second, first, "a different live mode is a different element")
	assert_eq(second.accessibility_live, A11y.LIVE_OFF)
	assert_eq(host.get_child_count(), 1, "the slot still holds one node")


func test_set_value_records_the_value_without_a_driver():
	var control := Control.new()
	add_child_autofree(control)
	A11y.set_value(control, "prompt$ ls")
	assert_eq(str(control.get_meta(A11y.VALUE_META, "")), "prompt$ ls",
		"the audit reads the recorded value; headless has no element server")
	assert_false(control.has_meta(A11y.PENDING_VALUE_META),
		"headless has no element server, so nothing is queued for a write")
	assert_false(A11y.screen_reader(),
		"the headless server reports an unknown reader state (-1), not an attached one")
	assert_false(A11y.enabled(),
		"headless has no accessibility driver: every push is gated on this and must no-op")


## The engine accepts `update_set_role`/`update_set_value` only inside a
## control's accessibility update, so a queued pair must leave with the flush.
func test_apply_update_consumes_a_queued_value_once():
	var control := Control.new()
	add_child_autofree(control)
	control.set_meta(A11y.PENDING_VALUE_META, "screen")
	control.set_meta(A11y.PENDING_ROLE_META, AccessibilityServer.ROLE_MULTILINE_TEXT_FIELD)
	A11y.apply_update(control)
	assert_false(control.has_meta(A11y.PENDING_VALUE_META), "the queue is one-shot")
	assert_false(control.has_meta(A11y.PENDING_ROLE_META))
	A11y.apply_update(control)  # nothing queued: must be a no-op, not an error


## The pane's own `_notification` is what lets the write happen at all: without
## the forward, `apply_update` is never reached and the queued value is dropped.
func test_a_terminal_forwards_its_accessibility_update():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	assert_true(body is TerminalPane, "the fixture's first pane is a terminal")
	body.set_meta(A11y.PENDING_VALUE_META, "screen")
	body._notification(Node.NOTIFICATION_ACCESSIBILITY_UPDATE)
	assert_false(body.has_meta(A11y.PENDING_VALUE_META),
		"the terminal must hand its accessibility update to A11y.apply_update")


# ── Pane identity ──────────────────────────────────────────────────────

func test_pane_identity_is_label_plus_name():
	var body := PaneBody.new()
	add_child_autofree(body)
	body.pane_label = "T1"
	body.pane_name = "build shell"
	assert_eq(body.accessibility_name, "T1: build shell")


func test_pane_identity_falls_back_to_the_type_name():
	var body := PaneBody.new()
	add_child_autofree(body)
	body.pane_label = "C3"
	assert_eq(body.accessibility_name, "C3: %s" % body._default_title(),
		"without a user name the pane is named by its label and its type")


# ── Terminal visible grid ──────────────────────────────────────────────

func test_terminal_exposes_its_visible_grid():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	assert_true(body is TerminalPane, "the fixture's first pane is a terminal")
	body._terminal.send_line("echo A11Y_MARKER")
	assert_true(await _wait_until(func() -> bool:
		return body.visible_text().contains("A11Y_MARKER")),
		"visible_text must carry what the grid draws: %s" % body.visible_text().left(200))
	assert_true(body.accessibility_name.begins_with(str(body.pane_label)),
		"the pane's identity must survive the shell's own title")
	# The publish host is the tile's title bar: a pane body is a leaf in the
	# exposed tree, so its own children are never published (measured on the
	# export). Headless has no driver, so nothing is published here — the host
	# is the assertion.
	var host: Control = A11y.announce_host(body)
	assert_not_null(host)
	assert_eq(str(host.name), "TitleBar",
		"published text must go to the tile's title bar, not the pane body")


## The gap this row exists to close: the test above recomputed
## `A11y.announce_host(body)` and never looked at the body's own host or the
## node it published, and nothing exercised the gated push at all. This drives
## the tick itself, on a restored body, and asserts what a driver would read.
func test_a_restored_terminal_publishes_its_screen_on_its_own_host():
	A11y.force_enabled = 1
	var ws = await _make_workspace()
	var body = _first_body(ws)
	body._terminal.send_line("echo A11Y_MARKER")
	assert_true(await _wait_until(func() -> bool:
		return body.visible_text().contains("A11Y_MARKER")),
		"visible_text must carry what the grid draws: %s" % body.visible_text().left(200))
	# The tick is the thing under test, not `_process`'s cadence: clear the
	# rate limit so this call must publish.
	body._a11y_push_ms = -1000000
	body._a11y_tick(Time.get_ticks_msec())
	assert_eq(str(body._a11y_host.name), "TitleBar",
		"the body publishes on its own resolved host, not a recomputed one")
	var node: Node = body._a11y_host.get_node_or_null(A11y.TEXT_NAME)
	assert_not_null(node, "the screen reaches AT as a published text node")
	assert_true(node.accessibility_name.contains("A11Y_MARKER"),
		"the published name carries the grid's text")
	# Compare against the snapshot the push took, not a fresh `visible_text()`:
	# the shell's next prompt can land between the tick and the assert.
	assert_eq(node.accessibility_name, body._a11y_last_value)
	assert_eq(str(body.get_meta(A11y.VALUE_META, "")), body._a11y_last_value,
		"the element value records the same screen")


## The starvation this row found: a churning grid generation refreshed the
## settle stamp every sync, so the push never ran. The value must not depend on
## it.
func test_a_churning_grid_still_publishes_the_value():
	A11y.force_enabled = 1
	var ws = await _make_workspace()
	var body = _first_body(ws)
	body._terminal.send_line("echo A11Y_MARKER")
	assert_true(await _wait_until(func() -> bool:
		return body.visible_text().contains("A11Y_MARKER")))
	body._a11y_changed_ms = Time.get_ticks_msec()
	body._a11y_push_ms = -1000000
	body._a11y_last_value = ""
	body._a11y_tick(Time.get_ticks_msec())
	assert_not_null(body._a11y_host.get_node_or_null(A11y.TEXT_NAME),
		"a settle stamp inside its window must not stop the value")


## The rate limit is what keeps an idle pane from rebuilding the node once per
## frame; the node must survive an immediate second tick.
func test_the_value_push_is_rate_limited():
	A11y.force_enabled = 1
	var ws = await _make_workspace()
	var body = _first_body(ws)
	body._terminal.send_line("echo A11Y_MARKER")
	assert_true(await _wait_until(func() -> bool:
		return body.visible_text().contains("A11Y_MARKER")))
	var now := Time.get_ticks_msec()
	body._a11y_push_ms = -1000000
	body._a11y_last_value = ""
	body._a11y_tick(now)
	var first: Node = body._a11y_host.get_node_or_null(A11y.TEXT_NAME)
	assert_not_null(first)
	body._a11y_last_value = ""
	body._a11y_tick(now + 1)
	assert_eq(str(body._a11y_host.get_node_or_null(A11y.TEXT_NAME).get_instance_id()),
		str(first.get_instance_id()), "a second tick inside the window must not re-publish")


## The announcement keeps the settle rule: a focused pane says nothing, and an
## unfocused one waits for the grid to be quiet.
func test_the_announcement_waits_for_a_quiet_grid():
	A11y.force_enabled = 1
	var ws = await _make_workspace()
	var body = _first_body(ws)
	body._terminal.send_line("echo A11Y_MARKER")
	assert_true(await _wait_until(func() -> bool:
		return body.visible_text().contains("A11Y_MARKER")))
	var now := Time.get_ticks_msec()
	body._a11y_push_ms = -1000000
	body._a11y_changed_ms = Time.get_ticks_msec()
	body._a11y_tick(now)
	assert_null(body._a11y_host.get_node_or_null(A11y.LIVE_NAME),
		"a grid that changed a moment ago is not announced yet")
	body._a11y_changed_ms = now - TerminalPane.A11Y_SETTLE_MS - 1
	if body.has_focus():
		body.release_focus()
	body._a11y_tick(now)
	assert_not_null(body._a11y_host.get_node_or_null(A11y.LIVE_NAME),
		"a quiet grid announces its last line")


# ── Glyph buttons ──────────────────────────────────────────────────────

## Every glyph-only button in the workspace must carry a word. Godot names a
## Button from its text before its tooltip, and each glyph here is a
## private-use codepoint drawn by a child Label, so an unnamed button is read
## aloud as a codepoint.
func test_every_glyph_button_has_an_accessible_name():
	var ws = await _make_workspace()
	var checked := 0
	for button in _all_buttons(ws):
		var glyph := Icons.glyph(button)
		if glyph == "":
			continue
		checked += 1
		assert_ne(button.accessibility_name, "",
			"glyph button %s has no accessible name" % _short_path(ws, button))
		assert_ne(button.accessibility_name, glyph,
			"glyph button %s is named by its codepoint" % _short_path(ws, button))
	assert_gt(checked, 0, "the sweep must actually find the chrome's glyph buttons")


# ── Fixtures ───────────────────────────────────────────────────────────

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws


func _first_body(ws: Control) -> Control:
	var tm: TerminalManager = ws._tm
	return tm._find_body(tm.tiles[0].wrapper)


func _wait_until(predicate: Callable, timeout_s := 8.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if predicate.call():
			return true
	return false


func _all_buttons(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	if node is Button:
		out.append(node as Button)
	for child in node.get_children():
		out.append_array(_all_buttons(child))
	return out


func _short_path(root: Node, node: Node) -> String:
	return str(root.get_path_to(node))
