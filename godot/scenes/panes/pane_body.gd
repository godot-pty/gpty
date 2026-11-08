class_name PaneBody
extends Control
# Base class for all pane types — shared infrastructure for settings,
# serialization, and the pane settings panel.

signal title_changed(new_title: String)

## Panes never spawn panes. A body that needs another pane asks its workspace
## by emitting this; the workspace is the only spawner, attaches the new pane
## through its usual path and activates it. `settings` is the same dictionary
## `TerminalManager.spawn_pane`/`apply_settings` consume (`type` plus the
## pane's own keys, e.g. `{"file_path": ...}` for a code viewer). The
## workspace may answer with an existing pane instead of a new one (a viewer
## already showing that file is focused), so a body must not assume its
## request created anything.
signal request_pane(type: String, settings: Dictionary)

@export var pane_name := "":
	set(value):
		pane_name = value
		refresh_accessibility_name()
## Stable logical link used by profiles and companion panes. Unlike
## `pane_label`, this value survives save/restore.
@export var attachment_id := ""
## Broadcast-targeting tags; each sanitized like attachment_id.
@export var tags: Array = []
@export var font_size: int = 14:
	set(value):
		font_size = value
		if _font != null:
			_recompute_cell_metrics()


## "T1", "C3", etc. Assigned by TerminalManager. The pane's accessible name is
## derived from it, so every assignment refreshes the identity.
var pane_label: String = "":
	set(value):
		pane_label = value
		refresh_accessibility_name()
var _font: Font  # set by concrete types that render text

func _ready():
	add_to_group("panes")
	refresh_accessibility_name()


## The pane's accessible identity: its label plus the type (or the user's own
## name for it). A screen reader meets a pane as one named region before it
## reads the body, so the name has to say both which pane and what kind.
func refresh_accessibility_name() -> void:
	var type_name := _default_title()
	var info: Variant = PaneTypes.ALL.get(_pane_type())
	if info is Dictionary:
		type_name = str(info.get("name", type_name))
	var display := pane_name if pane_name != "" else type_name
	accessibility_name = ("%s: %s" % [pane_label, display]) if pane_label != "" else display

## The inset every pane's content keeps from the pane's own edge.
##
## The tile wrapper adds a 1 px border and `BodyVBox` adds no separation, so a
## pane that laid its root out at the full rect printed its first line on the
## border. Six pixels is a token step: enough to separate text from the frame,
## little enough for a 180 px tile.
const CONTENT_INSET := UiTokens.SPACE_MD

## Lay `node` out as this pane's content frame: the full rect, inset by
## `CONTENT_INSET` on every side. One definition, because five panes were each
## about to spell the same four offsets. A pane whose surface is its own pixels
## edge to edge (a terminal's grid, a video's frame) does not call it.
func _fill_content(node: Control) -> void:
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	node.offset_left += CONTENT_INSET
	node.offset_top += CONTENT_INSET
	node.offset_right -= CONTENT_INSET
	node.offset_bottom -= CONTENT_INSET

## The one "nothing to show yet" surface: a centred hero glyph, a title and a
## sentence that names the fix, laid over `content`.
##
## The media pane's placeholder was this shape inline while the code viewer had
## only a disabled Reload button, so one pane explained itself and the other did
## not. `title` and `hint` may be empty when the pane owns its wording (media
## rewrites both from `_show_idle`/`_show_error`). The wiki pane keeps its single
## centred sentence: its toolbar stays live above it and every message it shows
## is a one-line diagnostic, not a state.
##
## Returns `{host, title, hint}` so the pane keeps the refs it needs to rewrite
## the text without rebuilding the surface.
static func empty_state(content: Control, glyph: String, title: String, hint: String, font_px: int) -> Dictionary:
	var host := CenterContainer.new()
	content.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var box := VBoxContainer.new()
	box.name = "EmptyBox"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", UiTokens.SPACE_LG)
	host.add_child(box)

	var glyph_label := Label.new()
	glyph_label.name = "EmptyGlyph"
	glyph_label.text = glyph
	glyph_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph_label.add_theme_font_size_override("font_size", UiTokens.FS_HERO)
	box.add_child(glyph_label)

	# A title can carry file-supplied text (a media file's name): one line that
	# ellipsizes inside a fixed width, so it cannot stretch the pane's minimum
	# width to the length of a 120-character name.
	var title_label := Label.new()
	title_label.name = "EmptyTitle"
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", font_px + 2)
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.custom_minimum_size.x = 200
	box.add_child(title_label)

	var hint_label := Label.new()
	hint_label.name = "EmptyHint"
	hint_label.text = hint
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.add_theme_font_size_override("font_size", font_px)
	hint_label.custom_minimum_size.x = 200
	box.add_child(hint_label)

	return {"host": host, "title": title_label, "hint": hint_label}

func _recompute_cell_metrics():
	pass  # overridden by types that render text

## Apply a settings dictionary to this pane.
##
## Every key goes through `PaneTypes.settings_schema(_pane_type())`: the closed
## per-type table is the only way a value reaches a property. Files are already
## filtered at their boundary (`PaneTypes.sanitize_tile`); this second gate is
## what stops a programmatic caller - or a future path that forgets to sanitize
## - from setting an arbitrary exported property (the hole that let a layout
## choose `font_bold_path` and have it `load()`ed). A key outside the table is
## ignored, never assigned.
func apply_settings(settings: Dictionary):
	var accepted: Dictionary = PaneTypes.sanitize_settings(
		_pane_type(), settings, PaneTypes.SOURCE_RUNTIME)["settings"]
	for key in accepted:
		var v = accepted[key]
		match key:
			"type":
				pass  # the discriminator; `_pane_type()` is a method, not a property
			"pane_name":
				pane_name = v
			"font_size":
				font_size = v
			"tags":
				tags = v
			_:
				# Keys a pane applies itself (`graph`, `loop`, `open_note`) have
				# no property of this name: its own `apply_settings` reads them
				# from the same dictionary.
				if key in self:
					set(key, v)
	ensure_attachment_id()
	if accepted.has("pane_name"):
		title_changed.emit(pane_name if pane_name != "" else _default_title())

## Apply the user's own per-pane state, after the saved settings at attach.
##
## Some pane settings are the user's gestures rather than file content — the
## Inspector's prompt and auto-send switches (`PaneInspectorStore`, keyed by
## `attachment_id`) — so they live in a user-owned store that a layout or
## profile cannot write, and the pane reads them here, once the id is final.
## The base has no such state; a pane whose aim is user-owned overrides this.
## `Workspace._attach_pane_into` is the only caller, so every entry route
## (spawn, restore, type swap) applies it.
func apply_user_state():
	pass

## Every pane has a stable public id. Generate one when no saved
## attachment_id was applied (fresh panes, legacy wrappers).
func ensure_attachment_id():
	if attachment_id == "":
		attachment_id = PaneTypes.generate_attachment_id()

func _default_title() -> String:
	return get_class()

func _get_layout_state() -> Dictionary:
	return {
		"type": _pane_type(),
		"pane_name": pane_name,
		"attachment_id": attachment_id,
		"tags": tags.duplicate(),
		"font_size": font_size,
	}

func _pane_type() -> String:
	return "base"  # overridden by concrete types

## The control that takes the keyboard when this pane is entered from outside:
## pane chrome's Escape, or a chrome action that leaves the pane on screen
## (`TerminalManager._return_focus_to_body`). Null means the pane has no aim of
## its own and the caller falls back to `KeyboardFocus.first_reachable`, the
## pane's first tab stop.
##
## A terminal is its own grid. A wiki pane showing a note aims at the buffer,
## because that is where a keyboard user continues and the toolbar is one chord
## away from it; the pane's first tab stop would be Back, a top-row action the
## note view does not need as an entry.
func keyboard_entry() -> Control:
	return null

## Status primitives for `paneStatus`, or null when the pane has none.
##
## A terminal returns its process/grid document; the media pane returns its
## transport state. The IPC aggregate lists a pane with `status: null` rather
## than dropping it, so a client can still see that the pane exists.
func status_document() -> Variant:
	return null

## The grid has given this pane's tile the rect it is drawn at, on every layout
## pass (`Workspace._apply_layout`). A pane that must know its drawn size — a
## terminal spawns its child at it — waits for this, because a tile the grid has
## never positioned is only as big as the container's minimum. The default panes
## read their size from Godot's layout and do not need it.
func mark_tile_laid_out() -> void:
	pass

## Routed-content capability contract.
##
## Routers must ask before delivery, and acknowledge source data only when
## receive_content() returns true. Receivers may decline because of their
## role, state, or a runtime failure; routers should then try the next match.
func can_receive_content(_event: Dictionary = {}) -> bool:
	return false

func receive_content(_text: String, _event: Dictionary = {}) -> bool:
	return false

## Agent-state observation contract.
##
## A pane observes ONE terminal, named by its stable `attachment_id`; a
## terminal observes itself (it returns its own id, because the tiered tracker
## it reads is that terminal's state). Empty means the pane observes nothing —
## the base default.
##
## `on_agent_state_changed` is called with that terminal's state on every
## change, and once when the pane enters a workspace (or when the observed
## terminal attaches after it — restore order is not fixed), so a companion
## created mid-session starts informed instead of waiting for the next
## transition. States are `idle` / `working` / `needs-attention` /
## `completed` / `failed`.
##
## DISPLAY ONLY. A Tier 2 declaration is spoofable by anything that prints to
## the terminal, and Tier 3 is a heuristic; a hook must never feed a decision,
## an action, a capture, or IPC. The titlebar badge has always followed that
## rule, and it is this contract's first implementation.
func agent_state_source_id() -> String:
	return ""

func on_agent_state_changed(_state: String) -> void:
	pass

## Close contract: ask before this pane is destroyed.
##
## `answer` receives whether the pane may go — `true` proceeds with the
## teardown, `false` cancels it and the pane stays exactly as it is. The
## answer may be deferred (a pane with unsaved work opens a Save/Discard
## dialog), so a caller must never assume it lands before `request_close`
## returns, and it must never destroy the pane itself: whoever asks passes a
## continuation as `answer`. The base answers `true` immediately — a pane with
## nothing to lose never asks — and every destruction path goes through here:
## the workspace's kill, swap, reset, workspace-close and layout-reload paths,
## and quitting the app.
func request_close(answer: Callable) -> void:
	answer.call(true)

## The state half of the close contract: whether this pane holds work that a
## close would destroy. A caller that cannot show a dialog — an IPC client,
## which has no way to answer one — checks this and refuses instead of asking
## (the same rule `layoutLoad` applies to an untrusted profile).
func has_unsaved_state() -> bool:
	return false

## Whether destroying this pane would stop work that is still running — the
## other thing a close can lose, and a different question from unsaved state:
## a process can be restarted, a lost edit cannot. A caller that can show a
## dialog aggregates this across the panes an action destroys and asks once
## (the workspace's `_ask_running_then`); a caller that cannot (IPC) treats
## the action itself as consent and proceeds.
func has_running_work() -> bool:
	return false

# Override to add type-specific settings controls.
# `panel` provides `_debounce_timer` and `_gather_func` (set by each type).
func _build_pane_settings_ui(_panel: Control) -> Control:
	return VBoxContainer.new()
