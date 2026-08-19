extends PaneBody
class_name InspectorPane
## Private, tool-free, iterative Q&A. Owns one in-memory GptyAi session.
## Does not attach to a terminal-hosted OMP conversation.

@export var backend := "omp"
@export var auto_run := true
@export var accept_concept_captures := false
@export var system_prompt := ""
@export var model := ""

var _display: MarkdownView
var _status: Label
var _prompt: LineEdit
var _thinking_display: MarkdownView
var _ai: Node
var _session_id := ""
var _run_id := ""
var _assembled := ""
var _prompt_quote := ""
var _thinking_assembled := ""
var _pending_capture := ""
var _pending_prompt := ""
var _busy := false

func _ready():
	super._ready()

	var root = VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	_status = Label.new()
	_status.name = "Status"
	_status.text = "Inspector idle — private Q&A, not the terminal OMP session"
	_status.add_theme_font_size_override("font_size", 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)

	_thinking_display = MarkdownView.new()
	_thinking_display.name = "ThinkingDisplay"
	_thinking_display.visible = false
	_thinking_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thinking_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_thinking_display.size_flags_stretch_ratio = 0.4
	root.add_child(_thinking_display)
	_thinking_display.scroll_following = true

	_display = MarkdownView.new()
	_display.name = "Display"
	_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_display)
	_display.scroll_following = true

	_prompt = LineEdit.new()
	_prompt.placeholder_text = "Ask (private Inspector session)…"
	_prompt.text_submitted.connect(_on_prompt_submitted)
	root.add_child(_prompt)

	_apply_font_sizes()

	_ai = ClassDB.instantiate("GptyAi")
	if _ai == null:
		_status.text = "GptyAi unavailable (rebuild gdext)"
		return
	_ai.name = "GptyAi"
	add_child(_ai)
	if not _ai.has_method("session_open"):
		_status.text = "Stale GDExtension — rebuild gpty-gdext and restart Godot"
		push_error("GptyAi is missing session_open; Godot is loading an old libgpty_gdext")
		_ai = null

func _exit_tree():
	_close_session()

func _recompute_cell_metrics():
	_apply_font_sizes()

func _apply_font_sizes():
	if _display:
		_display.add_theme_font_size_override("normal_font_size", font_size)
		_display.add_theme_font_size_override("mono_font_size", font_size)
	if _thinking_display:
		_thinking_display.add_theme_font_size_override("normal_font_size", font_size)
		_thinking_display.add_theme_font_size_override("mono_font_size", font_size)

func _process(_delta):
	if _ai == null or _session_id == "" or not _ai.has_method("session_poll"):
		return
	var raw = str(_ai.session_poll(JSON.stringify({
		"session_id": _session_id,
		"max_events": 128,
	})))
	if raw == "" or raw == "[]":
		return
	var events = JSON.parse_string(raw)
	if not (events is Array):
		return
	for ev in events:
		if ev is Dictionary:
			_handle_envelope(ev)

func _handle_envelope(env: Dictionary):
	if str(env.get("session_id", "")) != _session_id:
		return
	var run_id := str(env.get("run_id", ""))
	if _run_id != "" and run_id != "" and run_id != _run_id:
		return
	var event = env.get("event", {})
	if not (event is Dictionary):
		return
	match str(event.get("type", "")):
		"started":
			_status.text = "Inspecting via %s…" % str(event.get("backend", backend))
			_busy = true
		"status":
			_status.text = str(event.get("message", ""))
		"prompt":
			_prompt_quote += "\n\n> %s\n\n" % str(event.get("text", ""))
			_render_markdown(_prompt_quote + _assembled)
		"thinking":
			_append_thinking(str(event.get("text", "")))
		"answer_started":
			_status.text = "Answering…"
			if _thinking_assembled == "":
				_thinking_display.visible = false
		"delta":
			_assembled += str(event.get("text", ""))
			_render_markdown(_prompt_quote + _assembled)
		"done":
			_assembled = str(event.get("text", _assembled))
			_render_markdown(_prompt_quote + _assembled, true)
			_status.text = "Done"
			_finish_turn()
		"error":
			_status.text = "Error: %s" % str(event.get("message", "unknown"))
			_finish_turn()
		"cancelled":
			_status.text = "Cancelled"
			_finish_turn()

func _append_thinking(text: String):
	if text == "":
		return
	_thinking_assembled += text
	_thinking_display.set_markdown(_thinking_assembled)
	_thinking_display.visible = true
	_status.text = "Reasoning…"

func _reset_stream_display():
	_assembled = ""
	_prompt_quote = ""
	_thinking_assembled = ""
	_display.clear_markdown()
	_thinking_display.clear_markdown()
	_thinking_display.visible = false

func _finish_turn():
	_busy = false
	_run_id = ""
	if _pending_prompt != "":
		var next = _pending_prompt
		_pending_prompt = ""
		_start_turn(next)

func can_receive_content(_event: Dictionary = {}) -> bool:
	if not accept_concept_captures:
		return false
	if not auto_run:
		return true
	return _ai != null and _ai.has_method("session_prompt")

func receive_content(text: String, event: Dictionary = {}) -> bool:
	if not can_receive_content(event):
		return false
	_pending_capture = text
	if auto_run:
		return _start_turn(text)
	_status.text = "Capture ready — submit from the prompt box or enable auto-run"
	_render_markdown(text, true)
	return true

func _on_prompt_submitted(text: String):
	var t = text.strip_edges()
	if t == "":
		return
	_prompt.clear()
	_start_turn(t)

func _ensure_session() -> bool:
	if _ai == null or not _ai.has_method("session_open"):
		return false
	if _session_id != "":
		return true
	var raw = str(_ai.session_open(JSON.stringify({
		"backend": backend if backend != "" else "omp",
		"system_prompt": system_prompt,
		"cwd": "",
		"model": model,
	})))
	var resp = JSON.parse_string(raw)
	if resp is Dictionary and bool(resp.get("ok", false)):
		_session_id = str(resp.get("session_id", ""))
		return _session_id != ""
	var err = ""
	if resp is Dictionary:
		err = str(resp.get("error", "failed to open session"))
	else:
		err = "failed to open session"
	_status.text = err
	return false

func _close_session():
	if _ai == null or _session_id == "":
		return
	var payload := JSON.stringify({"session_id": _session_id})
	if _ai.has_method("session_cancel"):
		_ai.session_cancel(payload)
	if _ai.has_method("session_close"):
		_ai.session_close(payload)
	_session_id = ""
	_run_id = ""
	_busy = false
	_pending_prompt = ""

func _start_turn(text: String) -> bool:
	if not _ensure_session():
		return false
	if _busy:
		_pending_prompt = text
		if _ai.has_method("session_cancel"):
			_ai.session_cancel(JSON.stringify({"session_id": _session_id}))
		return true
	_reset_stream_display()
	var raw = str(_ai.session_prompt(JSON.stringify({
		"session_id": _session_id,
		"capture": text,
		"concept_name": "",
		"source_pane": pane_label,
	})))
	var resp = JSON.parse_string(raw)
	if not (resp is Dictionary) or not bool(resp.get("ok", false)):
		var err = "Failed to start Inspector turn"
		if resp is Dictionary:
			err = str(resp.get("error", err))
		_status.text = err
		_busy = false
		return false
	_run_id = str(resp.get("run_id", ""))
	_busy = true
	_status.text = "Started turn %s" % str(resp.get("turn_id", ""))
	return true

func _render_markdown(md: String, immediate := false):
	if immediate:
		_display.render_now(md)
	else:
		_display.set_markdown(md)

func _pane_type() -> String:
	return "inspector"

func _default_title() -> String:
	return "Inspector"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({
		"backend": backend,
		"auto_run": auto_run,
		"accept_concept_captures": accept_concept_captures,
		"system_prompt": system_prompt,
		"model": model,
	})
	return state

func apply_settings(settings: Dictionary):
	var prev_backend = backend
	var prev_model = model
	var prev_prompt = system_prompt
	super.apply_settings(settings)
	if settings.get("backend") is String:
		backend = settings["backend"]
	if settings.get("auto_run") is bool:
		auto_run = settings["auto_run"]
	if settings.get("accept_concept_captures") is bool:
		accept_concept_captures = settings["accept_concept_captures"]
	if settings.get("system_prompt") is String:
		system_prompt = settings["system_prompt"]
	if settings.get("model") is String:
		model = settings["model"]
	if is_inside_tree() and (
		backend != prev_backend or model != prev_model or system_prompt != prev_prompt
	):
		_close_session()

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var hint = Label.new()
	hint.text = "Private Q&A. Does not follow the terminal OMP conversation."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	v.add_child(hint)

	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "Inspector"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)

	var attach_le = LineEdit.new()
	attach_le.text = attachment_id
	attach_le.placeholder_text = "omp-inspector"
	attach_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Attachment ID:", attach_le)

	var font_spin = SpinBox.new()
	font_spin.min_value = 8
	font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)

	v.add_child(HSeparator.new())

	var backend_le = LineEdit.new()
	backend_le.text = backend
	backend_le.placeholder_text = "mock | omp"
	backend_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Backend:", backend_le)

	var model_le = LineEdit.new()
	model_le.text = model
	model_le.placeholder_text = "optional omp --model"
	model_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Model:", model_le)

	var auto_cb = CheckButton.new()
	auto_cb.button_pressed = auto_run
	auto_cb.toggled.connect(func(_on): panel._debounce_timer.start())
	_add_setting_row(v, "Auto-run:", auto_cb)

	var capture_cb = CheckButton.new()
	capture_cb.button_pressed = accept_concept_captures
	capture_cb.text = "Accept terminal concept captures (opt-in)"
	capture_cb.toggled.connect(func(_on): panel._debounce_timer.start())
	v.add_child(capture_cb)

	var sys_te = TextEdit.new()
	sys_te.text = system_prompt
	sys_te.placeholder_text = "(default Inspector system prompt)"
	sys_te.custom_minimum_size = Vector2(0, 60)
	sys_te.text_changed.connect(func(): panel._debounce_timer.start())
	var sys_lbl = Label.new()
	sys_lbl.text = "System prompt:"
	sys_lbl.add_theme_font_size_override("font_size", 12)
	v.add_child(sys_lbl)
	v.add_child(sys_te)

	var run_btn = Button.new()
	run_btn.text = "Run on last capture"
	run_btn.pressed.connect(func():
		if _pending_capture != "":
			_start_turn(_pending_capture)
	)
	v.add_child(run_btn)

	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"attachment_id": PaneTypes.sanitize_attachment_id(attach_le.text.strip_edges()),
			"font_size": int(font_spin.value),
			"backend": backend_le.text.strip_edges(),
			"model": model_le.text.strip_edges(),
			"auto_run": auto_cb.button_pressed,
			"accept_concept_captures": capture_cb.button_pressed,
			"system_prompt": sys_te.text,
		}

	return v

func _add_setting_row(parent: VBoxContainer, label: String, control: Control):
	var hb = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 12)
	hb.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(control)
	parent.add_child(hb)
