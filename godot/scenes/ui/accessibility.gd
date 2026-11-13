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
## published as a content node on the tile's title bar (`publish`) and its
## one-line announcements replace a live node there; the element's value is
## recorded too (`set_text`), for adapters that map it, and written by
## `apply_update` from the owning control's own
## `NOTIFICATION_ACCESSIBILITY_UPDATE` — the one place the engine accepts that
## write.
##
## Measured on the 4.7.2 AccessKit export: an element carries the name snapshot
## taken when it was created, so a replacement is the only way content changes
## and an unchanged slot is left alone instead of being churned (2026-11-05).
## `update_set_role` does reach AT-SPI — a terminal pane's element answers
## `GetRole` and exposes `Text` — while `update_set_value` still answers `""`
## through `Text.GetText` even for a pushed screen (2026-11-13), so the
## published name is the channel that carries content.
## `scripts/accessibility-probe` prints an `a11y-values:` line that grades a
## later engine in one command. See `docs/content/docs/agents/gdscript.md`.

const LIVE_NAME := "A11yLive"
## The readable content node: an `A11yContent` whose name is the surface's
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

## Test seam: -1 asks the engine, 0 and 1 answer for it. Headless has no
## accessibility driver, so a GUT test that exercises the gated push path sets
## this and restores `-1` in `after_each`. App code never writes it.
static var force_enabled := -1


## Whether accessible output is worth producing: an accessibility driver is
## loaded, or a screen reader reports itself attached.
##
## Measured on 4.7.2 (2026-11-05): the Linux AT-SPI adapter loads and serves
## the tree in the export, while `accessibility_screen_reader_active()` stays 0
## even with `org.a11y.Status.IsEnabled` set — this desktop's at-spi bus exposes
## no screen-reader flag. Gating on the flag alone left the export silent;
## `is_supported()` is the half that is true exactly when an element server
## exists. A false positive costs one string per second.
##
## `force_enabled` overrides the answer so the gated path is reachable from a
## headless test, which is the only place the push cadence can be asserted.
static func enabled() -> bool:
	if force_enabled >= 0:
		return force_enabled == 1
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


## Publish a content node in `slot` under `host`, replacing what was there.
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
## The node is an `A11yContent` (a `Control` that writes its own role), never a
## `Label` and never a bare `Control`: a Label's AT-SPI name is its display text
## (so content carried only in `accessibility_name` published an empty name),
## and a bare Control keeps the container role AccessKit drops from the tree —
## measured 2026-11-13, the published slot showed as an unnamed node with a
## Label and not at all with a Control, while the pane body's role-carrying
## element reads its name back intact. A Control has no text of its own to
## shape either, which is what keeps the whole-screen publish cheap (a Label
## given the full screen as text cost 992 ms of shaping, 221x78 = 17 315 chars,
## measured 2026-11-11).
##
## `host` must be a Control whose own children are published — a pane body is a
## leaf in the exposed tree, the tile's title bar is not (see `announce_host`).
static func publish(host: Control, slot: String, text: String, live := LIVE_OFF) -> Control:
	if host == null or not is_instance_valid(host) or text == "":
		return null
	var previous := host.get_node_or_null(NodePath(slot))
	if previous is Control:
		var node := previous as Control
		# The name is the content channel, so it is what "unchanged" means.
		if node.accessibility_name == text and node.accessibility_live == live:
			return node
	if previous != null:
		# The node is what AT holds, so the old one leaves the tree before the
		# replacement claims the name.
		host.remove_child(previous)
		previous.queue_free()
	var node := A11yContent.new()
	node.name = slot
	node.accessibility_name = text
	node.accessibility_live = live
	node.clip_contents = true
	node.focus_mode = Control.FOCUS_NONE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.modulate = Color(1, 1, 1, 0)
	node.size = Vector2(1, 1)
	host.add_child(node)
	# The role that makes the element survive into the tree; it is written from
	# the node's own update notification (see `A11yContent`).
	A11y.set_text(node, text)
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
