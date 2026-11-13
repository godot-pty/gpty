class_name A11y
## The app's accessible surface: identity, value and announcements, in one
## place, so a custom-drawn pane reads the same way the themed chrome does.
##
## Godot names a Button from its text before its tooltip, and a glyph is a
## private-use codepoint — hence `Icons.icon_button(btn, glyph, name)`, which
## draws the glyph in a child Label (leaving `Button.text` empty) and writes
## `accessibility_name` at the choke point.
##
## A custom `_draw()` Control has no text element. Its visible content is
## published as a text node on the tile's title bar (`publish`) and its one-line
## announcements replace a live node there; the element's value is recorded too
## (`set_text`), for adapters that map it, and written by `apply_update` from
## the host's own `NOTIFICATION_ACCESSIBILITY_UPDATE` — the one place the engine
## accepts that write.
##
## Measured on the 4.7.2 AccessKit export (2026-11-05): an element carries the
## name snapshot taken when it was created, and neither the value nor the role
## from `AccessibilityServer.update_set_value`/`update_set_role` reaches AT-SPI,
## so a replacement is the only way content changes and an unchanged slot is
## left alone instead of being churned. `scripts/accessibility-probe` prints an
## `a11y-values:` line that grades a later engine in one command. See
## `docs/content/docs/agents/gdscript.md`.

const LIVE_NAME := "A11yLive"
## The readable content node: a static text element whose name is the surface's
## visible text. It is not live — a screen reader reads it on demand — so a
## changing buffer is never announced in full.
const TEXT_NAME := "A11yText"
## What `set_value` last pushed, readable by tests and `--audit-accessibility`
## (an element's value has no getter).
const VALUE_META := &"a11y_value"
## A role and value waiting for the control's own accessibility update.
##
## 4.7.2's AccessKit server refuses `update_set_role`/`update_set_value` outside
## `NOTIFICATION_ACCESSIBILITY_UPDATE` and prints an engine error for each call
## (`drivers/accesskit/accessibility_server_accesskit.cpp:746`, `:834`), so the
## write happens in `apply_update`, which the host forwards from that
## notification.
const PENDING_ROLE_META := &"a11y_pending_role"
const PENDING_VALUE_META := &"a11y_pending_value"
const ANNOUNCE_CAP := 300
## How long the "is a screen reader attached" answer is reused. A reader
## attaching mid-session is not a sub-second event, and the engine call is
## otherwise paid per pane per frame.
const POLL_MS := 2000

## `Control.accessibility_live` is bound as a plain int in 4.7.2 (its property
## hint is `Off,Polite,Assertive` with no named constants), so the levels the
## app uses are spelled here. Polite waits for the reader to be idle instead
## of interrupting what it is reading.
const LIVE_OFF := 0
const LIVE_POLITE := 1

static var _active := false
static var _checked_ms := -POLL_MS


## Whether accessible output is worth producing: an accessibility driver is
## loaded, or a screen reader reports itself attached.
##
## Measured on 4.7.2 (2026-11-05): the Linux AT-SPI adapter loads and serves
## the tree in the export, while `accessibility_screen_reader_active()` stays 0
## even with `org.a11y.Status.IsEnabled` set — this desktop's at-spi bus exposes
## no screen-reader flag. Gating on the flag alone left the export silent;
## `is_supported()` is the half that is true exactly when an element server
## exists. A false positive costs one string per second.
static func enabled() -> bool:
	return AccessibilityServer.is_supported() or screen_reader()


## Whether a screen reader says it is attached. Never the only gate: see
## `enabled()`.
static func screen_reader() -> bool:
	var now := Time.get_ticks_msec()
	if now - _checked_ms >= POLL_MS:
		_checked_ms = now
		# The engine answers 1 (active), 0 (not) or -1 (unknown — the headless
		# display server reports this). Unknown is not active: a push with no
		# element server is work for nobody.
		_active = DisplayServer.accessibility_screen_reader_active() > 0
	return _active


## Record a Control's text value and ask for its accessibility update.
##
## The meta is written before the gate so the audit can read what the surface
## would expose on a driver-capable engine. The engine write itself happens in
## `apply_update`, which the control must forward from its own
## `NOTIFICATION_ACCESSIBILITY_UPDATE`: 4.7.2's server refuses it anywhere else
## and prints an engine error for every attempt.
static func set_value(control: Control, text: String) -> void:
	_queue_value(control, text, -1)


## A custom-drawn surface whose value is text: the same queue, plus the
## multiline-text-field role. Measured on 4.7.2's AccessKit adapter
## (2026-11-05): neither the value nor the role reaches AT-SPI — an element
## carries only the name snapshot taken at creation — so this is recorded for
## adapters that do map them, and `publish` is what exposes the content today.
static func set_text(control: Control, text: String) -> void:
	_queue_value(control, text, AccessibilityServer.ROLE_MULTILINE_TEXT_FIELD)


static func _queue_value(control: Control, text: String, role: int) -> void:
	if control == null or not is_instance_valid(control):
		return
	control.set_meta(VALUE_META, text)
	if not enabled():
		return
	control.set_meta(PENDING_VALUE_META, text)
	control.set_meta(PENDING_ROLE_META, role)
	control.queue_accessibility_update()

## Write the role and value `set_value`/`set_text` queued. A host Control
## forwards its own notification here:
##
##     func _notification(what):
##         if what == NOTIFICATION_ACCESSIBILITY_UPDATE:
##             A11y.apply_update(self)
##
## One-shot: the pending metas are consumed, and a control with nothing
## waiting returns without touching the server.
static func apply_update(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	if not control.has_meta(PENDING_VALUE_META):
		return
	var text := str(control.get_meta(PENDING_VALUE_META, ""))
	var role := int(control.get_meta(PENDING_ROLE_META, -1))
	control.remove_meta(PENDING_VALUE_META)
	control.remove_meta(PENDING_ROLE_META)
	var element := control.get_accessibility_element()
	if not element.is_valid():
		return
	if role >= 0:
		AccessibilityServer.update_set_role(element, role)
	AccessibilityServer.update_set_value(element, text)


## Publish a text node in `slot` under `host`, replacing what was there.
##
## Dynamic content cannot be edited into an existing element: the engine
## publishes a Control's accessible name once, when its element is created, and
## later writes (`accessibility_name`, `text`, `queue_accessibility_update`) do
## not reach the AT-SPI adapter (measured on the 4.7.2 export, 2026-11-05). A
## node added after the change is published with its name, so content is a
## replacement, not an update. The caller owns the cadence.
##
## A slot whose name and live mode are unchanged is returned as it is: the
## replacement is only how *new* content reaches AT, and a reader is holding the
## node that is there. `TerminalPane._a11y_tick` republishes its last output
## line every `A11Y_PUSH_MS`, so a churning idle pane used to drop the node AT
## was on once a second.
##
## `host` must be a Control whose own children are published — a pane body is a
## leaf in the exposed tree, the tile's title bar is not (see `announce_host`).
static func publish(host: Control, slot: String, text: String, live := LIVE_OFF) -> Label:
	if host == null or not is_instance_valid(host) or text == "":
		return null
	var previous := host.get_node_or_null(NodePath(slot))
	if previous is Label:
		var label := previous as Label
		# The name is the content channel, so it is what "unchanged" means: a
		# comparison against `text` would never match now that the node carries
		# no display text, and the slot would churn once per push.
		if label.accessibility_name == text and label.accessibility_live == live:
			return label
	if previous != null:
		# The node is what AT holds, so the old one leaves the tree before the
		# replacement claims the name.
		host.remove_child(previous)
		previous.queue_free()
	var node := Label.new()
	node.name = slot
	# `accessibility_name` alone is the name a driver reads:
	# `Control::_get_accessibility_name` returns it and a Label does not derive
	# a name from its text. Do NOT also set `node.text` — a Label shapes and
	# lays out that string, and a terminal's full screen made one workspace
	# switch cost 992 ms of main-thread text shaping (221x78 = 17 315 chars,
	# measured 2026-11-11). The value Label.text feeds does not reach AT-SPI on
	# 4.7.2 anyway (see the note above).
	node.accessibility_name = text
	node.accessibility_live = live
	node.clip_text = true
	node.focus_mode = Control.FOCUS_NONE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.modulate = Color(1, 1, 1, 0)
	node.size = Vector2(1, 1)
	host.add_child(node)
	return node


## Where a pane's published text lives.
##
## A `PaneBody` is a leaf in the tree the engine publishes: a Label added to the
## pane itself never appears, while the tile's title bar publishes its children
## (measured on the 4.7.2 export, 2026-11-05). The bar is also where the pane's
## identity already lives, so AT meets the pane's name, badge and content in
## one place. Falls back to the control itself when there is no bar (a pane
## built outside a tile, e.g. in a test).
static func announce_host(control: Control) -> Control:
	var node: Node = control
	while node != null and not (node is PaneBody):
		node = node.get_parent()
	if node is PaneBody:
		var parent := node.get_parent()
		if parent != null:
			var bar := parent.get_node_or_null("TitleBar")
			if bar is Control:
				return bar as Control
	return control


static func one_line(text: String, cap := ANNOUNCE_CAP) -> String:
	var out := ""
	var pending_space := false
	for i in text.length():
		var c := text.unicode_at(i)
		if c == 0x20 or c < 0x20 or c == 0x7F:
			# Whitespace and control characters collapse to one separator; a
			# leading or trailing one is dropped.
			pending_space = out != ""
			continue
		if pending_space:
			out += " "
			pending_space = false
		out += text[i]
		if out.length() >= cap:
			break
	return out.left(cap)
