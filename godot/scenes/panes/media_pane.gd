extends PaneBody
class_name MediaPane
# Local audio/video pane.
#
# The file is a path carrier like every file pane: an absolute local path,
# validated at use by `MediaFiles` (allowlist + regular-file gate), never a
# URL and never handed to `ResourceLoader` — the pane builds the decoder for
# the kind the table named. Playback is Godot's native streams for the
# formats the engine ships (Theora `.ogv`, Ogg Vorbis/MP3/WAV audio); the
# wider Rust demux/decode matrix is a later roadmap item, and this pane's
# path gate, layout state and UI survive that swap. Transport controls
# (play/pause/seek/loop, paneStatus) are their own item as well: opening a
# file plays it once, and the status line says what happened.

@export var file_path := ""

var _video: VideoStreamPlayer
## `VideoStreamPlayer.expand` is a *cover* fit — a tall pane crops the sides
## of a wide clip — so the player lives inside an AspectRatioContainer that
## is given the clip's own ratio and centers it instead (letterbox/pillarbox).
var _video_frame: AspectRatioContainer
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

	_video_frame = AspectRatioContainer.new()
	_video_frame.name = "VideoFrame"
	_video_frame.visible = false
	content.add_child(_video_frame)
	_video_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_video = VideoStreamPlayer.new()
	_video.name = "Video"
	_video.expand = true
	_video.autoplay = false
	_video.finished.connect(_on_finished)
	_video_frame.add_child(_video)
	_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

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
	_audio.finished.connect(_on_finished)
	add_child(_audio)

## Play `path`, replacing whatever this pane was playing. A refused path
## clears `file_path` (the viewer's rule: the pane is not showing a file it
## could not open) and explains itself in the placeholder.
func load_media(path: String) -> void:
	path = path.strip_edges()
	if _video == null:
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
	var kind: String = verdict.kind
	var stream := _load_stream(path, kind)
	if stream == null:
		file_path = ""
		_show_error("Could not decode this media file: %s" % MediaFiles.display_name(path))
		return
	file_path = path
	_kind = kind
	_placeholder.visible = false
	_status.visible = true
	if kind == MediaFiles.VIDEO:
		_video.stream = stream as VideoStream
		_video_frame.visible = true
		_video.visible = true
		_fit_video()
		_fit_video.call_deferred()
	else:
		_audio.stream = stream as AudioStream
		_show_audio_placeholder(path)
	_start_playback()

## The one place a path becomes a decoder. Typed streams only: the extension
## table already chose the kind, and no branch consults `ResourceLoader`.
func _load_stream(path: String, kind: String) -> Resource:
	if kind == MediaFiles.VIDEO:
		var stream := VideoStreamTheora.new()
		stream.file = path
		return stream
	if kind == MediaFiles.AUDIO:
		match path.get_extension().to_lower():
			"mp3":
				return AudioStreamMP3.load_from_file(path)
			"wav":
				return AudioStreamWAV.load_from_file(path)
			_:
				return AudioStreamOggVorbis.load_from_file(path)
	return null

## Give the frame the clip's own ratio. `get_video_texture()` reports the
## stream's dimensions once the stream is assigned, but a decoder may expose
## it a frame later, so the caller also defers one call; a zero height means
## nothing is available yet and the default 16:9 frame stands in.
func _fit_video():
	if _video == null or _video_frame == null:
		return
	var texture := _video.get_video_texture()
	if texture == null or texture.get_height() <= 0:
		return
	_video_frame.ratio = float(texture.get_width()) / float(texture.get_height())

func _start_playback():
	# `play()` is an engine error outside the tree; every production caller is
	# in it (`_ready` or a settings apply from the panel), so a guard is the
	# whole contract rather than a retry loop.
	if not is_inside_tree():
		return
	if _kind == MediaFiles.VIDEO and _video.stream != null:
		_video.play()
	elif _kind == MediaFiles.AUDIO and _audio.stream != null:
		_audio.play()
	_status.text = "Playing %s" % MediaFiles.display_name(file_path)

func _teardown_stream():
	if _video != null:
		if _video.is_inside_tree():
			_video.stop()
		_video.stream = null
		_video.visible = false
	if _video_frame != null:
		_video_frame.visible = false
	if _audio != null:
		if _audio.is_inside_tree():
			_audio.stop()
		_audio.stream = null
	_kind = ""
	_status.visible = false
	_status.text = ""

func _show_idle():
	_video.visible = false
	_video_frame.visible = false
	_placeholder.visible = true
	_placeholder_title.text = "Media"
	_placeholder_hint.text = "No file selected — set an absolute path in pane settings."
	_status.visible = false

func _show_audio_placeholder(path: String):
	_placeholder.visible = true
	_placeholder_title.text = MediaFiles.display_name(path)
	_placeholder_hint.text = "Audio"

func _show_error(message: String):
	_video.visible = false
	_video_frame.visible = false
	_placeholder.visible = true
	_placeholder_title.text = "Media"
	_placeholder_hint.text = message
	_status.visible = false

func _on_finished():
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
	if _video == null:
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
	file_le.placeholder_text = "/path/to/movie.ogv or song.ogg"
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
