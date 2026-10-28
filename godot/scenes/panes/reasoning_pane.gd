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

var _status: RichTextLabel
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
	_debug = OS.get_environment("GPTY_REASONING_DEBUG") != ""

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	# A RichTextLabel rather than a Label so the instructions (the
	# `echo $GPTY_EVENT_PROTOCOL` command in particular) can be selected and
	# copied; a Label cannot. `context_menu_enabled` gives the right-click
	# Copy/Select All menu, the discoverable half of the same feature.
	_status = RichTextLabel.new()
	_status.name = "Status"
	_status.bbcode_enabled = false
	_status.fit_content = true
	_status.scroll_active = false
	_status.selection_enabled = true
	_status.context_menu_enabled = true
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("normal_font_size", 12)
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

	var vbar := scroll.get_v_scroll_bar()
	if vbar != null:
		vbar.value_changed.connect(_on_scroll_changed)
		# The range changes when a render's fold height reaches the container
		# (one layout after the render). Re-following on that signal is what
		# makes the view catch up in the same frame as the new content, even
		# though the first scroll was clamped at the previous bottom.
		vbar.changed.connect(_on_scroll_range_changed)

var _last_vbar_visible := false

## Opt-in pipeline diagnostics (`GPTY_REASONING_DEBUG=1`): one line per second
## with the input rate, the render rate and the event server's drop counters.
## The pane cannot tell "the model is slow" from "we are slow" without both
## halves, and a dropped delta is invisible in the text.
var _debug := false
var _dbg_elapsed := 0.0
var _dbg_deltas := 0
var _dbg_bytes := 0
var _dbg_max_delta := 0
var _dbg_renders := 0
var _dbg_render_usec := 0
var _dbg_caps := 0

func _process(delta):
	if _turn_scroll == null:
		return
	if _debug:
		_tick_debug(delta)
	var vbar := _turn_scroll.get_v_scroll_bar()
	var visible := vbar != null and vbar.visible
	if visible != _last_vbar_visible:
		_last_vbar_visible = visible
		_queue_layout_refresh()

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

## One deferred refresh per frame, not per delta: a burst of 200 deltas used
## to enqueue 200 deferred calls, each walking every turn.
var _layout_queued := false
var _scroll_queued := false
## Auto-follow intent, not a proximity test at scroll time: content grows by
## whole lines between renders, so "was the bar at the bottom before this
## growth" is the question a live log answers. A user scroll-up clears the
## flag; returning to the bottom (or starting a new turn) sets it again.
var _follow_live := true
var _auto_scrolling := false
const FOLLOW_TOLERANCE := 24.0

func _queue_layout_refresh():
	if _layout_queued:
		return
	_layout_queued = true
	call_deferred("_refresh_turn_layout")

## Width, fold state and (cached) heights. Rendering is not this function's
## job: a turn's view is rendered by the delta that changed it, by its initial
## render, or by `_freeze_live`. Re-rendering every turn here is what used to
## clear a selection and re-parse every completed turn on every token.
func _refresh_turn_layout():
	_layout_queued = false
	_sync_turn_list_width()
	for rec in _turns:
		_sync_fold_height(rec)
	_queue_scroll_bottom()

## A coalesced render changes the content height after the delta that caused
## it has returned, so the fold height follows the render.
func _on_view_rendered(rec: Dictionary):
	if _debug:
		_dbg_renders += 1
		var view := _view_for(rec)
		if view:
			_dbg_render_usec += view.last_render_usec
	call_deferred("_sync_fold_height", rec, true)
	_queue_scroll_bottom()

## `synced_width` caches the width a view's height was measured at, so a
## static turn is not re-measured every frame; `force` follows a render.
func _sync_fold_height(rec: Dictionary, force := false):
	var fold := _fold_for(rec)
	var view := _view_for(rec)
	if fold == null or view == null:
		return
	if fold.folded:
		view.custom_minimum_size = Vector2(0, 0)
		rec["synced_width"] = -1
		return
	var width := maxi(_viewport_width() - 8, 0)
	if width <= 0:
		return
	if not force and int(rec.get("synced_width", -1)) == width:
		return
	rec["synced_width"] = width
	var height := view.get_content_height()
	view.custom_minimum_size = Vector2(width, height + 4 if height > 0 else 0)

func _scroll_turn_list_to_bottom():
	_queue_scroll_bottom()

func _queue_scroll_bottom():
	if _scroll_queued:
		return
	_scroll_queued = true
	call_deferred("_apply_turn_scroll_bottom")

func _apply_turn_scroll_bottom():
	_scroll_queued = false
	if _turn_scroll == null or not _follow_live:
		return
	var bar := _turn_scroll.get_v_scroll_bar()
	if bar == null:
		return
	# This write is ours: the value_changed it emits must not be mistaken for
	# the user scrolling away from the bottom.
	_auto_scrolling = true
	_turn_scroll.scroll_vertical = int(bar.max_value)
	_auto_scrolling = false

## The range grows one layout after a render; if the user is following, take
## the new bottom now. Without this, the scroll issued with the render clamps
## at the previous bottom and a multi-line growth stops the follow.
func _on_scroll_range_changed():
	if _follow_live:
		_queue_scroll_bottom()

## A user drag, wheel or keyboard scroll clears auto-follow once the viewport
## leaves the bottom; scrolling back to the bottom re-arms it. Content growth
## does not call this (the value does not move), which is why the flag — not
## a fresh distance check — is what `_apply_turn_scroll_bottom` reads.
func _on_scroll_changed(_value: float):
	if _auto_scrolling or _turn_scroll == null:
		return
	var bar := _turn_scroll.get_v_scroll_bar()
	if bar == null:
		return
	_follow_live = bar.value + bar.page >= bar.max_value - FOLLOW_TOLERANCE

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
		"session.bound":
			_bind_session(incoming, _event_ms(event))
		"session.shutdown":
			if _ignore_shutdown(incoming, _event_ms(event)):
				return
			_freeze_live(_event_ms(event))
			_session_ended = true
			_status.text = "OMP session ended"
		"agent.started":
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
		"thinking.delta":
			if _session_ended:
				_bind_session(incoming, _event_ms(event))
			var text := str(event.get("text", ""))
			if text != "":
				if _debug:
					_note_debug_delta(text)
				_append_live_text(text)
				_status.text = "Reasoning…"
		"agent.settled":
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

## Follow the terminal this pane watches when that terminal was renamed.
##
## The *same* terminal under a new id, so the OMP session and the turns shown
## still belong to it and stay - unlike `apply_settings`, which treats a source
## change as a different terminal and resets them. `Workspace._retarget_companions`
## calls this for a rename in this pane's own workspace only.
func retarget_source(new_id: String):
	var id := PaneTypes.sanitize_attachment_id(new_id)
	if id == "" or id == source_attachment_id:
		return
	source_attachment_id = id
	# The status text names the source only while nothing is bound; a bound
	# session's status is its own (Reasoning…/Done/session ended).
	if _omp_session_id == "" and is_inside_tree() and _status:
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

## The input half of the diagnostic: what actually reached the pane (the
## server-side counters say what reached the listener and what it rejected).
func _note_debug_delta(text: String):
	var bytes := text.to_utf8_buffer().size()
	_dbg_deltas += 1
	_dbg_bytes += bytes
	_dbg_max_delta = maxi(_dbg_max_delta, bytes)

## One line a second. `in` is the pane's view of the source rate, `render` is
## what the GUI paid to show it, and `server` is the listener's cumulative
## view — `full`/`big` rising is the signature of lost text, not slow drawing.
func _tick_debug(delta: float):
	_dbg_elapsed += delta
	if _dbg_elapsed < 1.0:
		return
	var window := _dbg_elapsed
	var server_text := ""
	var server = JSON.parse_string(str(GptyTerminal.omp_event_stats()))
	if server is Dictionary:
		server_text = " | server accepted=%d (%.1f KiB/s) full=%d big=%d drained=%d queued=%d/%d" % [
			int(server.get("accepted", 0)),
			float(server.get("accepted_bytes", 0)) / 1024.0 / window,
			int(server.get("rejected_queue_full", 0)),
			int(server.get("rejected_oversized", 0)),
			int(server.get("drained_events", 0)),
			int(server.get("queued_events", 0)),
			int(server.get("queued_bytes", 0))]
	var live := _live_turn()
	var turn_bytes := int(live.get("text_bytes", 0)) if not live.is_empty() else 0
	print("[reasoning] in=%.0f ev/s %.1f KiB/s max=%d B | render=%d/s %.1f ms | turn=%s caps=%d%s" % [
		float(_dbg_deltas) / window,
		float(_dbg_bytes) / 1024.0 / window,
		_dbg_max_delta,
		float(_dbg_renders) / window,
		(float(_dbg_render_usec) / 1000.0) / maxi(_dbg_renders, 1),
		String.humanize_size(turn_bytes),
		int(live.get("truncated", 0)) if not live.is_empty() else _dbg_caps,
		server_text])
	_dbg_elapsed = 0.0
	_dbg_deltas = 0
	_dbg_bytes = 0
	_dbg_max_delta = 0
	_dbg_renders = 0
	_dbg_render_usec = 0

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
		# Incremental byte count: an append must not re-encode the whole turn
		# to learn its size.
		"text_bytes": 0,
		"truncated": false,
		"synced_width": -1,
	}

func _start_turn(started_at_ms: int):
	_freeze_live(started_at_ms)
	# A new live turn is what the user is watching: resume following even if
	# they had scrolled up in the previous one.
	_follow_live = true
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
	# The coalesced render lands after a delay, so the height sync has to be
	# driven by the render, not by the delta that scheduled it.
	view.rendered.connect(func(): _on_view_rendered(rec))
	view.add_theme_font_size_override("normal_font_size", font_size)
	view.add_theme_font_size_override("mono_font_size", font_size)
	fold.add_child(view)

	_turn_list.add_child(fold)
	_fold_by_id[str(rec["id"])] = fold
	_sync_turn_list_width()

	var text := str(rec.get("text", ""))
	if text != "":
		if bool(rec.get("truncated", false)):
			_show_truncation_notice(view)
		view.render_now(text)
	_queue_layout_refresh()

func _append_live_text(delta: String):
	if _live_index < 0:
		_start_turn(0)
	var rec := _live_turn()
	if rec.is_empty() or str(rec.get("status", "")) != "streaming":
		return
	var text := str(rec.get("text", ""))
	# The fallback must not be computed when the key exists: `Dictionary.get`'s
	# default is a normal argument, so passing `text.to_utf8_buffer().size()`
	# here encoded the whole turn on every delta (measured: ~200 ms of the
	# capped-append path for one 64 KiB turn).
	var size := int(rec.get("text_bytes", -1))
	if size < 0:
		size = text.to_utf8_buffer().size()
	if size >= max_turn_bytes:
		# The cap is already spent: do not concatenate or re-encode the whole
		# turn for a delta that cannot be shown. (The old path paid a full
		# `existing + delta` and two `to_utf8_buffer()` copies per dropped
		# delta — measured at ~500 ms for one 64 KiB capped turn.)
		_mark_truncated(rec)
		return
	var added := delta.to_utf8_buffer().size()
	if size + added <= max_turn_bytes:
		rec["text"] = text + delta
		rec["text_bytes"] = size + added
	else:
		rec["text"] = _close_open_fences(_truncate_utf8(text + delta, max_turn_bytes))
		rec["text_bytes"] = max_turn_bytes
		_mark_truncated(rec)
	var view := _view_for(rec)
	if view:
		# The model keeps every delta; the view re-parses the accumulated turn
		# markdown at most once per MarkdownView.RENDER_DELAY instead of once
		# per token (the turn is finalized with render_now on settle).
		view.set_markdown(str(rec["text"]))
	_queue_layout_refresh()

## The cap is a user setting, so hitting it is not an error — but silently
## losing the rest of a thought is, so the view says what happened. One notice
## per turn; the flag rides in the record, not in the view.
func _mark_truncated(rec: Dictionary):
	if bool(rec.get("truncated", false)):
		return
	rec["truncated"] = true
	_dbg_caps += 1
	var view := _view_for(rec)
	if view:
		_show_truncation_notice(view)
		view.set_markdown(str(rec.get("text", "")))

func _show_truncation_notice(view: MarkdownView):
	view.set_source_notice(
		"… this turn reached its %s limit; later reasoning is not shown. Raise it in Settings → Reasoning."
		% String.humanize_size(max_turn_bytes))

func _on_fold_expanded_changed():
	_queue_layout_refresh()

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
	_queue_layout_refresh()

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
