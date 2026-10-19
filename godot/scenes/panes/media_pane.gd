extends PaneBody
class_name MediaPane
# Local audio/video pane.
#
# The file is a path carrier like every file pane: an absolute local path,
# validated at use by `MediaFiles` (allowlist + regular-file gate), never a
# URL and never handed to `ResourceLoader`. Video is decoded by the pinned
# FFmpeg backend (`GptyMedia` → `gpty-media`) and uploaded as an ImageTexture;
# audio still uses Godot's native stream loaders until the Audio playback item
# wires `poll_audio` into an AudioStreamGenerator. A video session is opened
# with `audio: false` for that reason: an unconsumed audio queue is
# backpressure and would stall video decode.
#
# Presentation is PTS-gated against `Time.get_ticks_usec()` so a decoder that
# runs faster than real time does not play the clip at 4×. Transport controls
# (pause/seek/loop, paneStatus) remain their own item.

@export var file_path := ""

## Video surface. `TextureRect` with aspect-preserving stretch gives the same
## letterbox/pillarbox fit the old AspectRatioContainer did, without needing
## the clip's dimensions before the first frame arrives.
var _video_surface: TextureRect
var _backend: GptyMedia
var _texture: ImageTexture
var _pending_frames: Array = []
var _clock_start_us := -1
var _first_pts_us := 0
var _video_finished := false
var _finished_shown := false

var _audio: AudioStreamPlayer
var _placeholder: CenterContainer
var _placeholder_title: Label
var _placeholder_hint: Label
var _status: Label
var _kind := ""

func _ready():
	super._ready()
	_build_ui()
	if file_path != "":
		load_media(file_path)
	else:
		_show_idle()

func _process(_delta):
	_poll_video()

func _exit_tree():
	_stop_backend()

func _build_ui():
	var root := VBoxContainer.new()
	root.name = "MediaRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	# The content area layers the video surface under the placeholder; a
	# plain Control lets both fill the same rect without a container
	# resizing one from the other.
	var content := Control.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)

	_video_surface = TextureRect.new()
	_video_surface.name = "Video"
	_video_surface.visible = false
	_video_surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_video_surface.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_video_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_video_surface)
	_video_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_placeholder = CenterContainer.new()
	_placeholder.name = "Placeholder"
	content.add_child(_placeholder)
	_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	_placeholder.add_child(box)

	var icon := Label.new()
	icon.text = str(PaneTypes.ALL.get("media", {}).get("icon", "|>"))
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 36)
	box.add_child(icon)

	# A file name is file-supplied text: the title is a single line, so it
	# ellipsizes inside a fixed placeholder width instead of making the pane's
	# minimum width follow a 120-character name, and the hint wraps in the
	# same box.
	_placeholder_title = Label.new()
	_placeholder_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placeholder_title.add_theme_font_size_override("font_size", font_size + 2)
	_placeholder_title.clip_text = true
	_placeholder_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_placeholder_title.custom_minimum_size.x = 200
	box.add_child(_placeholder_title)

	_placeholder_hint = Label.new()
	_placeholder_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placeholder_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_placeholder_hint.add_theme_font_size_override("font_size", font_size)
	_placeholder_hint.custom_minimum_size.x = 200
	box.add_child(_placeholder_hint)

	_status = Label.new()
	_status.name = "Status"
	_status.visible = false
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.add_theme_font_size_override("font_size", maxi(10, font_size - 2))
	root.add_child(_status)

	# Audible output is the player's own child node: it has no visual, so it
	# must not sit in the layout where it would claim height from the video.
	_audio = AudioStreamPlayer.new()
	_audio.name = "Audio"
	_audio.finished.connect(_on_audio_finished)
	add_child(_audio)

## Play `path`, replacing whatever this pane was playing. A refused path
## clears `file_path` (the viewer's rule: the pane is not showing a file it
## could not open) and explains itself in the placeholder.
func load_media(path: String) -> void:
	path = path.strip_edges()
	if _video_surface == null:
		# Before `_ready` the UI does not exist; `_ready` loads `file_path`.
		file_path = path
		return
	_teardown_stream()
	var verdict := MediaFiles.check(path)
	if verdict.error != "":
		file_path = ""
		_show_error(verdict.error)
		return
	if verdict.kind == "":
		# An empty path is the user clearing the field, not a broken file:
		# return to the idle view instead of reporting a decode failure.
		file_path = ""
		_show_idle()
		return
	file_path = path
	_kind = verdict.kind
	_placeholder.visible = false
	_status.visible = true
	if _kind == MediaFiles.VIDEO:
		_open_video(path)
		return

	var stream := _load_audio_stream(path)
	if stream == null:
		file_path = ""
		_show_error("Could not decode this media file: %s" % MediaFiles.display_name(path))
		return
	_audio.stream = stream
	_show_audio_placeholder(path)
	_start_playback()

## The one place an audio path becomes a decoder. Typed streams only: the
## extension table already chose the kind, and no branch consults
## `ResourceLoader`. Video never reaches this function.
func _load_audio_stream(path: String) -> Resource:
	match path.get_extension().to_lower():
		"mp3":
			return AudioStreamMP3.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
		_:
			return AudioStreamOggVorbis.load_from_file(path)

## Start a video session. `open` validates the path synchronously and probes
## on the backend's own thread; `_poll_video` follows its status.
func _open_video(path: String) -> void:
	if _backend == null:
		_backend = GptyMedia.new()
		_backend.name = "MediaBackend"
		add_child(_backend)
	var answer = JSON.parse_string(_backend.open(JSON.stringify({
		"path": path,
		"audio": false,
		"sample_rate": 48000,
		"channels": 2,
	})))
	if not (answer is Dictionary) or not answer.get("ok", false):
		var error = answer.get("error", {}) if answer is Dictionary else {}
		_show_error("Could not open the media file: %s" % str(error.get("message", "")))
		return
	_video_finished = false
	_finished_shown = false
	_clock_start_us = -1
	_pending_frames.clear()
	_status.text = "Opening %s" % MediaFiles.display_name(path)

## Drain decoded frames, gate presentation on the PTS clock, and update the
## surface. A frame is presented when its due time arrives; a small backlog is
## kept so a slow frame does not reorder the clip.
func _poll_video() -> void:
	if _backend == null or _kind != MediaFiles.VIDEO:
		return
	var status = JSON.parse_string(_backend.status())
	if status is Dictionary:
		if status.get("state") == "failed":
			var error = status.get("error", {})
			_show_error("Could not decode this media file: %s" % str(error.get("message", "")))
			return
		if status.get("state") == "finished":
			_video_finished = true

	var now := Time.get_ticks_usec()
	# Poll a bounded batch: the backend queue is small, and a slow frame must
	# not spend the whole frame budget draining it.
	for _i in 8:
		var frame = _backend.poll_video()
		if frame.is_empty():
			break
		if _clock_start_us < 0:
			_clock_start_us = now
			_first_pts_us = int(frame["pts_us"])
		_pending_frames.append(frame)
		while _pending_frames.size() > 4:
			_pending_frames.pop_front()

	if _pending_frames.is_empty():
		if _video_finished and not _finished_shown:
			_finish_video()
		return

	while not _pending_frames.is_empty():
		var frame: Dictionary = _pending_frames[0]
		var due := _clock_start_us + int(frame["pts_us"]) - _first_pts_us
		if due > now:
			break
		_pending_frames.pop_front()
		# Catch up by dropping a frame that is already well past due when a
		# newer one is waiting; never drop the last frame in the queue.
		if now - due > 100_000 and not _pending_frames.is_empty():
			continue
		_present_video(frame)
		if _status.text.begins_with("Opening"):
			_status.text = "Playing %s" % MediaFiles.display_name(file_path)
	if _video_finished and _pending_frames.is_empty() and not _finished_shown:
		_finish_video()

func _present_video(frame: Dictionary) -> void:
	var width := int(frame.get("width", 0))
	var height := int(frame.get("height", 0))
	var data: PackedByteArray = frame.get("data", PackedByteArray())
	if width <= 0 or height <= 0 or data.is_empty():
		return
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	if _texture == null or _texture.get_width() != width or _texture.get_height() != height:
		_texture = ImageTexture.create_from_image(image)
		_video_surface.texture = _texture
	else:
		_texture.update(image)
	_video_surface.visible = true
	_placeholder.visible = false

func _finish_video() -> void:
	_finished_shown = true
	_status.visible = true
	_status.text = "Finished %s" % MediaFiles.display_name(file_path)

func _start_playback():
	# `play()` is an engine error outside the tree; every production caller is
	# in it (`_ready` or a settings apply from the panel), so a guard is the
	# whole contract rather than a retry loop.
	if not is_inside_tree():
		return
	if _kind == MediaFiles.AUDIO and _audio.stream != null:
		_audio.play()
		_status.text = "Playing %s" % MediaFiles.display_name(file_path)

func _teardown_stream():
	_stop_backend()
	if _audio != null:
		if _audio.is_inside_tree():
			_audio.stop()
		_audio.stream = null
	_kind = ""
	_status.visible = false
	_status.text = ""

func _stop_backend():
	if _backend != null:
		_backend.close()
	_texture = null
	_pending_frames.clear()
	_clock_start_us = -1
	_video_finished = false
	_finished_shown = false
	if _video_surface != null:
		_video_surface.texture = null
		_video_surface.visible = false

func _show_idle():
	_stop_backend()
	_placeholder.visible = true
	_placeholder_title.text = "Media"
	_placeholder_hint.text = "No file selected — set an absolute path in pane settings."
	_status.visible = false

func _show_audio_placeholder(path: String):
	_placeholder.visible = true
	_placeholder_title.text = MediaFiles.display_name(path)
	_placeholder_hint.text = "Audio"

func _show_error(message: String):
	# A pane showing an error is not showing a file; the viewer's rule.
	file_path = ""
	_kind = ""
	_stop_backend()
	_placeholder.visible = true
	_placeholder_title.text = "Media"
	_placeholder_hint.text = message
	_status.visible = false

func _on_audio_finished():
	_status.visible = true
	_status.text = "Finished %s" % MediaFiles.display_name(file_path)
	if _kind == MediaFiles.AUDIO:
		_placeholder_hint.text = "Audio · finished"

func _pane_type() -> String:
	return "media"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"file_path": file_path})
	return state

func apply_settings(settings: Dictionary):
	# The panel re-applies the whole gathered dict on every debounced edit, so
	# a name or font change arrives with the same `file_path`. Reloading then
	# would restart the clip (and lose its position) for an unrelated edit;
	# only a path that actually changed reaches the decoder.
	var previous_path := file_path
	super.apply_settings(settings)
	if _video_surface == null:
		return
	if settings.get("file_path") is String:
		if file_path != previous_path:
			load_media(file_path)
		elif file_path == "":
			_show_idle()
	elif file_path == "":
		_show_idle()

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "Media"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)

	var font_spin = SpinBox.new()
	font_spin.min_value = 8; font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)

	v.add_child(HSeparator.new())

	var file_le = LineEdit.new()
	file_le.text = file_path
	file_le.placeholder_text = "/path/to/movie.mp4 or song.ogg"
	file_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "File:", file_le)

	var hint := Label.new()
	hint.text = "Local files only. Supported: %s." % MediaFiles.supported_text()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	v.add_child(hint)

	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"file_path": file_le.text.strip_edges(),
		}

	return v

func _add_setting_row(parent: VBoxContainer, label: String, control: Control):
	var hb = HBoxContainer.new()
	var lbl = Label.new(); lbl.text = label
	lbl.add_theme_font_size_override("font_size", 12)
	hb.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(control)
	parent.add_child(hb)
