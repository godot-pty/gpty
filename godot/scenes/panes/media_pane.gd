extends PaneBody
class_name MediaPane
# Local audio/video pane.
#
# The file is a path carrier like every file pane: an absolute local path,
# validated at use by `MediaFiles` (allowlist + regular-file gate), never a
# URL and never handed to `ResourceLoader`. Both streams come from the pinned
# FFmpeg backend (`GptyMedia` → `gpty-media`): video is uploaded as an
# ImageTexture, audio is decoded to interleaved f32 and pushed into an
# AudioStreamGenerator. One session is opened for the file, with `video` and
# `audio` set to the streams this pane will actually drain — an unconsumed
# queue is backpressure and would stall the other stream.
#
# Presentation is clocked: video is gated on the audio playback position when
# audio is running (PTS mapped through `get_playback_position()`), otherwise
# on a monotonic start clock, so a decoder that runs faster than real time
# does not play the clip several times too fast. Transport controls
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
var _finished := false
var _finished_announced := false

var _audio: AudioStreamPlayer
var _audio_playback: AudioStreamGeneratorPlayback
var _pending_audio: Array = []
var _audio_playing := false
var _audio_started := false
var _audio_start_pts_us := 0
var _generator_capacity := 0

## User-owned pane settings, persisted with the tile like the file path.
var volume_db := 0.0
var muted := false

var _placeholder: CenterContainer
var _placeholder_title: Label
var _placeholder_hint: Label
var _status: Label
var _kind := ""

const MIX_RATE := 48000
const AUDIO_BUFFER_SECONDS := 0.2
## Chunks held locally beyond the generator buffer (~1.4 s). Draining the
## backend queue into this lead keeps a full audio queue from blocking the
## worker, which also decodes video.
const AUDIO_PENDING_MAX := 32
## How far ahead of the media clock a video frame may be held (µs); audio
## playback positions are coarse, so a small tolerance avoids stutter.
const VIDEO_PRESENT_TOLERANCE_US := 20_000
## Drop a frame this far behind the media clock when a newer one is waiting.
const VIDEO_CATCHUP_US := 150_000

func _ready():
	super._ready()
	_build_ui()
	if file_path != "":
		load_media(file_path)
	else:
		_show_idle()

func _process(_delta):
	_poll_backend()

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
	_open_media(path, _kind == MediaFiles.VIDEO, true)
	if _kind == MediaFiles.AUDIO:
		_show_audio_placeholder(path)

## Open one backend session for the streams this pane will drain.
func _open_media(path: String, want_video: bool, want_audio: bool) -> void:
	if _backend == null:
		_backend = GptyMedia.new()
		_backend.name = "MediaBackend"
		add_child(_backend)
	if want_audio:
		_prepare_audio()
	var answer = JSON.parse_string(_backend.open(JSON.stringify({
		"path": path,
		"video": want_video,
		"audio": want_audio,
		"sample_rate": MIX_RATE,
		"channels": 2,
	})))
	if not (answer is Dictionary) or not answer.get("ok", false):
		var error = answer.get("error", {}) if answer is Dictionary else {}
		_show_error("Could not open the media file: %s" % str(error.get("message", "")))
		return
	_finished = false
	_finished_announced = false
	_clock_start_us = -1
	_pending_frames.clear()
	_status.text = "Opening %s" % MediaFiles.display_name(path)

## The generator buffer is set up now, but playback starts with the first
## decoded chunk so the media clock starts on real samples, not on silence.
func _prepare_audio() -> void:
	_audio.stop()
	_audio_playback = null
	_audio_playing = false
	_audio_started = false
	_audio_start_pts_us = 0
	_pending_audio.clear()
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = AUDIO_BUFFER_SECONDS
	_generator_capacity = int(MIX_RATE * AUDIO_BUFFER_SECONDS)
	_audio.stream = generator
	_apply_audio_volume()

func _apply_audio_volume() -> void:
	if _audio != null:
		_audio.volume_db = -80.0 if muted else volume_db

## Drain decoded frames and audio, gate video on the media clock, and announce
## the end once both the backend and the generator have caught up.
func _poll_backend() -> void:
	if _backend == null:
		return
	var status = JSON.parse_string(_backend.status())
	if status is Dictionary:
		if status.get("state") == "failed":
			var error = status.get("error", {})
			_show_error("Could not decode this media file: %s" % str(error.get("message", "")))
			return
		if status.get("state") == "finished":
			_finished = true
	if _kind == MediaFiles.VIDEO:
		_poll_video()
	_feed_audio()
	if _finished and not _finished_announced:
		if not _pending_frames.is_empty() or not _pending_audio.is_empty():
			return
		if _audio_started and _audio_playback != null \
				and _audio_playback.get_frames_available() < _generator_capacity - 64:
			return
		_finished_announced = true
		_status.visible = true
		_status.text = "Finished %s" % MediaFiles.display_name(file_path)

## Current media position in microseconds. Audio, when running, is the clock;
## otherwise the monotonic start clock is used. `-1` means no clock yet.
func _media_clock_us() -> int:
	if _audio_started and _audio_playback != null:
		return _audio_start_pts_us + int(_audio.get_playback_position() * 1_000_000.0)
	if _clock_start_us < 0:
		return -1
	return _first_pts_us + (Time.get_ticks_usec() - _clock_start_us)

func _poll_video() -> void:
	var now := Time.get_ticks_usec()
	if _clock_start_us < 0 and not _audio_started:
		_clock_start_us = now
	for _i in 8:
		var frame = _backend.poll_video()
		if frame.is_empty():
			break
		if _clock_start_us < 0 and not _audio_started:
			_clock_start_us = now
			_first_pts_us = int(frame["pts_us"])
		_pending_frames.append(frame)
		while _pending_frames.size() > 4:
			_pending_frames.pop_front()

	var media_now := _media_clock_us()
	if media_now < 0:
		media_now = _first_pts_us
	while not _pending_frames.is_empty():
		var frame: Dictionary = _pending_frames[0]
		var pts := int(frame["pts_us"])
		if pts > media_now + VIDEO_PRESENT_TOLERANCE_US:
			break
		_pending_frames.pop_front()
		# Catch up by dropping a frame already well past due when a newer one
		# is waiting; never drop the last frame in the queue.
		if media_now - pts > VIDEO_CATCHUP_US and not _pending_frames.is_empty():
			continue
		_present_video(frame)
		if _status.text.begins_with("Opening"):
			_status.text = "Playing %s" % MediaFiles.display_name(file_path)

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

## Push decoded chunks into the generator while it has room. A chunk that
## does not fit stays pending; the generator consumes in real time.
func _feed_audio() -> void:
	if _audio.stream == null:
		return
	# Drain the backend queue even when the generator is full. Leaving the
	# queue full blocks the worker on an audio send, and that same worker
	# decodes video; the local lead is bounded.
	if _pending_audio.size() < AUDIO_PENDING_MAX:
		for _i in 8:
			var polled = _backend.poll_audio()
			if polled.is_empty():
				break
			_pending_audio.append(polled)
	if _pending_audio.is_empty():
		return
	var available := 0
	if _audio_playing:
		if _audio_playback == null:
			return
		available = _audio_playback.get_frames_available()
		if available <= 0:
			return
	var added := 0
	while not _pending_audio.is_empty() and added < 8:
		var chunk: Dictionary = _pending_audio[0]
		var channels := int(chunk.get("channels", 2))
		var data: PackedFloat32Array = chunk.get("data", PackedFloat32Array())
		if channels <= 0:
			_pending_audio.pop_front()
			continue
		var frames := int(data.size() / channels)
		if frames <= 0:
			_pending_audio.pop_front()
			continue
		if not _audio_playing:
			if not _start_audio(chunk):
				return
			available = _audio_playback.get_frames_available()
		if frames > available:
			break
		var buffer := PackedVector2Array()
		buffer.resize(frames)
		if channels >= 2:
			for f in frames:
				buffer[f] = Vector2(data[f * channels], data[f * channels + 1])
		else:
			for f in frames:
				var sample := data[f]
				buffer[f] = Vector2(sample, sample)
		if not _audio_playback.push_buffer(buffer):
			break
		_pending_audio.pop_front()
		available -= frames
		added += 1
		if _status.text.begins_with("Opening"):
			_status.text = "Playing %s" % MediaFiles.display_name(file_path)

## Start the generator on the first real chunk, so `get_playback_position()`
## and the media PTS share an origin.
func _start_audio(chunk: Dictionary) -> bool:
	_audio.play()
	_audio_playback = _audio.get_stream_playback() as AudioStreamGeneratorPlayback
	if _audio_playback == null:
		_show_error("Could not start audio playback")
		return false
	_audio_playing = true
	_audio_started = true
	_audio_start_pts_us = int(chunk.get("pts_us", 0))
	return true

func _teardown_stream():
	_stop_backend()
	_kind = ""
	_status.visible = false
	_status.text = ""

func _stop_backend():
	if _backend != null:
		_backend.close()
	_texture = null
	_pending_frames.clear()
	_clock_start_us = -1
	_finished = false
	_finished_announced = false
	if _video_surface != null:
		_video_surface.texture = null
		_video_surface.visible = false
	if _audio != null:
		_audio.stop()
		_audio.stream = null
	_audio_playback = null
	_audio_playing = false
	_audio_started = false
	_audio_start_pts_us = 0
	_pending_audio.clear()

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

func _pane_type() -> String:
	return "media"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({
		"file_path": file_path,
		"volume_db": volume_db,
		"muted": muted,
	})
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
	if settings.get("volume_db") != null and (settings["volume_db"] is float or settings["volume_db"] is int):
		volume_db = clampf(float(settings["volume_db"]), -40.0, 6.0)
		_apply_audio_volume()
	if settings.get("muted") is bool:
		muted = settings["muted"]
		_apply_audio_volume()
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

	var volume := HSlider.new()
	volume.min_value = -40.0
	volume.max_value = 6.0
	volume.step = 0.5
	volume.value = volume_db
	volume.custom_minimum_size.x = 140
	volume.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Volume (dB):", volume)

	var mute := CheckBox.new()
	mute.text = "Mute"
	mute.button_pressed = muted
	mute.toggled.connect(func(_v): panel._debounce_timer.start())
	v.add_child(mute)

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
			"volume_db": float(volume.value),
			"muted": mute.button_pressed,
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
