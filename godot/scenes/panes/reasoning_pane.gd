extends PaneBody
class_name ReasoningPane
## Passive projection of documented reasoning events from one terminal-hosted
## OMP session. This pane never starts an agent or parses terminal output.
##
## Turn records (`_turns`) are the source of truth for the session accordion.
## They stay in RAM for the current OMP session only and are the contract a
## later SQLite writer can persist without a second in-memory format.

## User-tunable caps (Settings → Reasoning). Loaded from SettingsManager at
## _ready with clamps; changes apply to panes created afterward.
var max_turns: int = 16
var max_turn_bytes: int = 65536
const TURN_SCHEMA := 1

@export var source_attachment_id := "omp-terminal"

var _status: Label
var _turn_scroll: ScrollContainer
var _turn_list: VBoxContainer
## JSON-shaped turn records. Do not store node refs here.
var _turns: Array[Dictionary] = []
var _fold_by_id: Dictionary = {}
var _live_index: int = -1
var _next_turn_index: int = 1
var _omp_session_id := ""
var _last_bound_at_ms: int = 0
var _session_ended := false

func _ready():
	super._ready()
	max_turns = clampi(int(SettingsManager.cfg_reasoning_max_turns), 1, 64)
	max_turn_bytes = clampi(int(SettingsManager.cfg_reasoning_max_turn_bytes), 4096, 1048576)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	_status.text = _idle_status()
	root.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.name = "TurnScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_turn_scroll = scroll

	_turn_list = VBoxContainer.new()
	_turn_list.name = "TurnList"
	_turn_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_turn_list)

var _last_vbar_visible := false

func _process(_delta):
	if _turn_scroll == null:
		return
	var vbar := _turn_scroll.get_v_scroll_bar()
	var visible := vbar != null and vbar.visible
	if visible != _last_vbar_visible:
		_last_vbar_visible = visible
		call_deferred("_refresh_turn_layout")

## Visible viewport width: the scroll container size minus the vertical
## scrollbar when it is shown. Using the outer size would make content
## clip at the right edge once the scrollbar appears late in a turn.
func _viewport_width() -> int:
	if _turn_scroll == null:
		return 0
	var vbar := _turn_scroll.get_v_scroll_bar()
	var bar_w := int(vbar.size.x) if vbar != null and vbar.visible else 0
	return maxi(int(_turn_scroll.size.x) - bar_w, 0)

func _sync_turn_list_width():
	if _turn_list == null or _turn_scroll == null:
		return
	var width := _viewport_width()
	if width > 0:
		_turn_list.custom_minimum_size.x = width

func _refresh_turn_layout():
	_sync_turn_list_width()
	for rec in _turns:
		var view := _view_for(rec)
		view.configure_for_accordion()
		var body := str(rec.get("text", ""))
		if body != "":
			view.render_now(body)
	_sync_fold_heights()
	call_deferred("_sync_fold_heights_y")
	_scroll_turn_list_to_bottom()

func _sync_fold_heights():
	for rec in _turns:
		var fold := _fold_for(rec)
		var view := _view_for(rec)
		if fold == null or view == null:
			continue
		if fold.folded:
			view.custom_minimum_size = Vector2(0, 0)
		else:
			var width := maxi(_viewport_width() - 8, 0)
			if width > 0:
				view.custom_minimum_size = Vector2(width, 0)
			view.queue_redraw()

func _sync_fold_heights_y():
	for rec in _turns:
		var fold := _fold_for(rec)
		var view := _view_for(rec)
		if fold == null or view == null:
			continue
		if fold.folded:
			view.custom_minimum_size = Vector2(0, 0)
			continue
		var width := maxi(_viewport_width() - 8, 0)
		if width <= 0:
			continue
		var height := view.get_content_height()
		view.custom_minimum_size = Vector2(width, height + 4 if height > 0 else 0)

func _scroll_turn_list_to_bottom():
	if _turn_scroll == null:
		return
	call_deferred("_apply_turn_scroll_bottom")

func _apply_turn_scroll_bottom():
	if _turn_scroll == null:
		return
	var bar := _turn_scroll.get_v_scroll_bar()
	if bar == null:
		return
	# Follow only while already at the bottom; a deliberate scroll-up
	# during a live turn must not be yanked back down.
	if bar.value + bar.page >= bar.max_value - 8.0:
		_turn_scroll.scroll_vertical = int(bar.max_value)

func _idle_status() -> String:
	var source := source_attachment_id if source_attachment_id != "" else "(unset)"
	return "Listening for OMP events from %s. This pane does not scrape the TUI.\nLink the shipped extension, then restart omp:\n  omp plugin link <gpty>/extensions/gpty-omp-events\nIn that terminal, echo $GPTY_EVENT_PROTOCOL should print 1." % source

func _recompute_cell_metrics():
	for rec in _turns:
		var view := _view_for(rec)
		if view:
			view.add_theme_font_size_override("normal_font_size", font_size)
			view.add_theme_font_size_override("mono_font_size", font_size)

func can_receive_content(_event: Dictionary = {}) -> bool:
	return false

func receive_agent_event(envelope: Dictionary, source_id: String):
	if source_attachment_id != "" and source_id != source_attachment_id:
		return
	var event = envelope.get("event", {})
	if not (event is Dictionary):
		return
	var incoming := str(envelope.get("omp_session_id", ""))
	match str(event.get("name", "")):
		"omp.session.bound":
			_bind_session(incoming, _event_ms(event))
		"omp.session.shutdown":
			if _ignore_shutdown(incoming, _event_ms(event)):
				return
			_freeze_live(_event_ms(event))
			_session_ended = true
			_status.text = "OMP session ended"
		"omp.agent.started":
			if _session_ended:
				_bind_session(incoming, _event_ms(event))
			else:
				_note_session_id(incoming)
			var live := _live_turn()
			if (
				not live.is_empty()
				and str(live.get("status", "")) == "streaming"
				and str(live.get("text", "")) != ""
			):
				_status.text = "Reasoning…"
				return
			if _reuse_empty_live_turn():
				_status.text = "Reasoning…"
				return
			_start_turn(_event_ms(event))
			_status.text = "Reasoning…"
		"omp.reasoning.delta":
			if _session_ended:
				_bind_session(incoming, _event_ms(event))
			var text := str(event.get("text", ""))
			if text != "":
				_append_live_text(text)
				_status.text = "Reasoning…"
		"omp.agent.settled":
			var had_live := (
				not _live_turn().is_empty()
				and str(_live_turn().get("status", "")) == "streaming"
			)
			_freeze_live(_event_ms(event))
			if not had_live:
				return
			var rec := _live_turn()
			var has_text := not rec.is_empty() and str(rec.get("text", "")) != ""
			_status.text = "Done" if has_text else "No reasoning emitted"

func _pane_type() -> String:
	return "reasoning"

func _default_title() -> String:
	return "Reasoning"

func apply_settings(settings: Dictionary):
	var previous_source := source_attachment_id
	super.apply_settings(settings)
	if settings.get("source_attachment_id") is String:
		source_attachment_id = PaneTypes.sanitize_attachment_id(settings["source_attachment_id"])
	else:
		source_attachment_id = PaneTypes.sanitize_attachment_id(source_attachment_id)
	if source_attachment_id != previous_source:
		_clear_turns()
		_omp_session_id = ""
		_last_bound_at_ms = 0
		_session_ended = false
	if is_inside_tree() and _omp_session_id == "" and _status:
		_status.text = _idle_status()

func _get_layout_state() -> Dictionary:
	var state := super._get_layout_state()
	state["source_attachment_id"] = source_attachment_id
	return state

func _build_pane_settings_ui(panel: Control) -> Control:
	var v := VBoxContainer.new()
	var source := LineEdit.new()
	source.text = source_attachment_id
	source.placeholder_text = "omp-terminal"
	source.text_changed.connect(func(_text): panel._debounce_timer.start())
	var label := Label.new()
	label.text = "Source attachment ID (must match the terminal's Attachment ID, not its display name):"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(label)
	v.add_child(source)
	panel._gather_func = func():
		return {
			"pane_name": pane_name,
			"attachment_id": attachment_id,
			"font_size": font_size,
			"source_attachment_id": source.text.strip_edges(),
		}
	return v

func _event_ms(event: Dictionary) -> int:
	var value = event.get("emitted_at_ms", 0)
	if value is int or value is float:
		return int(value)
	return 0

func _reuse_empty_live_turn() -> bool:
	var rec := _live_turn()
	if rec.is_empty():
		return false
	if str(rec.get("status", "")) != "streaming":
		return false
	return str(rec.get("text", "")) == ""

func _bind_session(incoming: String, event_ms: int):
	if incoming != "" and _omp_session_id != "" and incoming != _omp_session_id:
		_clear_turns()
	if incoming != "":
		_omp_session_id = incoming
	if event_ms > 0:
		_last_bound_at_ms = event_ms
	_session_ended = false
	_status.text = "Attached to OMP session"

func _note_session_id(incoming: String):
	if incoming == "":
		return
	if _omp_session_id != "" and incoming != _omp_session_id:
		_clear_turns()
	_omp_session_id = incoming

func _ignore_shutdown(incoming: String, event_ms: int) -> bool:
	if incoming != "" and _omp_session_id != "" and incoming != _omp_session_id:
		return true
	if event_ms > 0 and _last_bound_at_ms > 0 and event_ms < _last_bound_at_ms:
		return true
	return false

func _live_turn() -> Dictionary:
	if _live_index < 0 or _live_index >= _turns.size():
		return {}
	return _turns[_live_index]

func _fold_for(rec: Dictionary) -> FoldableContainer:
	return _fold_by_id.get(str(rec.get("id", "")), null)

func _view_for(rec: Dictionary) -> MarkdownView:
	var fold := _fold_for(rec)
	if fold == null:
		return null
	return fold.get_node_or_null("Display") as MarkdownView

func _fold_at(index: int) -> FoldableContainer:
	if index < 0 or index >= _turns.size():
		return null
	return _fold_for(_turns[index])

func _view_at(index: int) -> MarkdownView:
	if index < 0 or index >= _turns.size():
		return null
	return _view_for(_turns[index])

func _fold_title(rec: Dictionary) -> String:
	var suffix := "Reasoning…"
	match str(rec.get("status", "")):
		"done":
			suffix = "Done"
		"empty":
			suffix = "No reasoning"
	return "Turn %d · %s" % [int(rec.get("turn_index", 0)), suffix]

func _sync_fold_title(rec: Dictionary):
	var fold := _fold_for(rec)
	if fold:
		fold.title = _fold_title(rec)

func _make_turn(started_at_ms: int) -> Dictionary:
	var idx := _next_turn_index
	_next_turn_index += 1
	var sid := _omp_session_id if _omp_session_id != "" else "unknown"
	return {
		"schema": TURN_SCHEMA,
		"id": "%s-%d" % [sid, idx],
		"omp_session_id": sid,
		"turn_index": idx,
		"started_at_ms": started_at_ms,
		"settled_at_ms": 0,
		"status": "streaming",
		"text": "",
	}

func _start_turn(started_at_ms: int):
	_freeze_live(started_at_ms)
	for rec in _turns:
		var fold := _fold_for(rec)
		if fold:
			fold.folded = true
	while _turns.size() >= max_turns:
		_drop_oldest_turn()
	var rec := _make_turn(started_at_ms)
	_turns.append(rec)
	_live_index = _turns.size() - 1
	_add_fold(rec)

func _add_fold(rec: Dictionary):
	if _turn_list == null:
		return
	var fold := FoldableContainer.new()
	fold.name = str(rec.get("id", "turn"))
	fold.title = _fold_title(rec)
	fold.folded = false
	fold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fold.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	fold.folding_changed.connect(func(_is_folded): _on_fold_expanded_changed())

	var view := MarkdownView.new()
	view.name = "Display"
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	view.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	view.configure_for_accordion()
	view.add_theme_font_size_override("normal_font_size", font_size)
	view.add_theme_font_size_override("mono_font_size", font_size)
	fold.add_child(view)

	_turn_list.add_child(fold)
	_fold_by_id[str(rec["id"])] = fold
	_sync_turn_list_width()

	var text := str(rec.get("text", ""))
	if text != "":
		view.render_now(text)
	call_deferred("_refresh_turn_layout")

func _append_live_text(delta: String):
	if _live_index < 0:
		_start_turn(0)
	var rec := _live_turn()
	if rec.is_empty() or str(rec.get("status", "")) != "streaming":
		return
	rec["text"] = _append_capped(str(rec.get("text", "")), delta, max_turn_bytes)
	var view := _view_for(rec)
	if view:
		view.render_now(str(rec["text"]))
	call_deferred("_refresh_turn_layout")

func _on_fold_expanded_changed():
	call_deferred("_refresh_turn_layout")

func _freeze_live(settled_at_ms: int):
	var rec := _live_turn()
	if rec.is_empty() or str(rec.get("status", "")) != "streaming":
		return
	var text := str(rec.get("text", ""))
	rec["status"] = "done" if text != "" else "empty"
	if settled_at_ms > 0:
		rec["settled_at_ms"] = settled_at_ms
	var view := _view_for(rec)
	if view:
		view.scroll_following = false
		if text != "":
			view.render_now(text)
	_sync_fold_title(rec)
	call_deferred("_refresh_turn_layout")

func _drop_oldest_turn():
	if _turns.is_empty():
		return
	var rec: Dictionary = _turns[0]
	_turns.remove_at(0)
	if _live_index >= 0:
		_live_index -= 1
	var id := str(rec.get("id", ""))
	var fold = _fold_by_id.get(id)
	_fold_by_id.erase(id)
	_free_fold(fold)

func _clear_turns():
	for id in _fold_by_id:
		_free_fold(_fold_by_id[id])
	_fold_by_id.clear()
	_turns.clear()
	_live_index = -1
	_next_turn_index = 1
	_last_bound_at_ms = 0
	_session_ended = false

func _free_fold(fold):
	if not is_instance_valid(fold):
		return
	var parent = fold.get_parent()
	if parent:
		parent.remove_child(fold)
	fold.free()

func _append_capped(existing: String, delta: String, max_bytes: int) -> String:
	var combined := existing + delta
	if combined.to_utf8_buffer().size() <= max_bytes:
		return combined
	if existing.to_utf8_buffer().size() >= max_bytes:
		return existing
	return _close_open_fences(_truncate_utf8(combined, max_bytes))

## Truncating raw Markdown mid-fence leaves an unclosed ``` block: the
## renderer would treat the rest as code, un-wrapping prose that had
## already rendered normally. Re-close an odd fence count.
func _close_open_fences(s: String) -> String:
	var count := 0
	var idx := 0
	while true:
		var fence := s.find("```", idx)
		if fence == -1:
			break
		count += 1
		idx = fence + 3
	if count % 2 == 1:
		return s + "\n```\n"
	return s

func _truncate_utf8(s: String, max_bytes: int) -> String:
	var buf := s.to_utf8_buffer()
	if buf.size() <= max_bytes:
		return s
	var n := max_bytes
	while n > 0 and (buf[n - 1] & 0xC0) == 0x80:
		n -= 1
	if n > 0 and (buf[n - 1] & 0xC0) == 0xC0:
		n -= 1
	return buf.slice(0, n).get_string_from_utf8()
