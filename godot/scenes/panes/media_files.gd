class_name MediaFiles
extends RefCounted
# One closed table: which local files the media pane can play, and the path
# gate every caller uses before a decoder sees a name.
#
# The table is an allowlist, not a sniff. A path can arrive from a layout or
# profile tile (untrusted file input), so nothing here hands it to
# `ResourceLoader.load`: a `.gd` or `.tscn` behind a media extension would be
# loaded as code. The pane builds a typed stream instead (Theora for video,
# the Ogg/MP3/WAV loaders for audio), and only after `check` has answered.
#
# Remote/URL playback is deliberately absent — a separate trust boundary and a
# later roadmap item. `res://`/`user://` are project schemes rather than local
# absolute paths, so they are refused with the other remote-looking paths.
#
# Adding a format is one entry here plus a case in the pane's loader; the
# extension list is also what the file tree consults to choose the pane.

## Containers Godot's native video decoder reads. Theora-in-Ogg only: the
## Rust backend's wider matrix (MP4/WebM/MKV, H.264/VP9/AV1) is a later item.
const VIDEO_EXTENSIONS: Array[String] = ["ogv"]

## Audio formats the native stream loaders read.
const AUDIO_EXTENSIONS: Array[String] = ["ogg", "oga", "mp3", "wav"]

const VIDEO := "video"
const AUDIO := "audio"

## A file name is file-supplied text (a layout can carry any path), so the
## display form is bounded: the pane's status line stays short, its title
## ellipsizes inside its own fixed width, and the settings row still shows the
## full path.
const MAX_DISPLAY_NAME := 120

## The name to show for `path`: its base name, ellipsized past the cap.
static func display_name(path: String) -> String:
	var name := path.get_file()
	if name == "":
		name = path
	if name.length() > MAX_DISPLAY_NAME:
		name = name.left(MAX_DISPLAY_NAME) + "…"
	return name

## The stream kind `path` names, or "" when the table does not know it.
## Extension-only: this is the routing decision, and `check` adds the path
## and file gates on top.
static func kind_for(path: String) -> String:
	var ext := path.get_extension().to_lower()
	if ext in VIDEO_EXTENSIONS:
		return VIDEO
	if ext in AUDIO_EXTENSIONS:
		return AUDIO
	return ""

## The pane type that plays `path`, or "" when the file tree must keep its
## confirm-then-system path. Mirrors `ViewableFiles.viewer_for`.
static func pane_for(path: String) -> String:
	return "media" if kind_for(path) != "" else ""

## Why `path` cannot be played, as `{kind, error}` with `error` empty when it
## can. The message is written for the pane's own status text, so it names the
## exact reason instead of a generic refusal.
static func check(path: String) -> Dictionary:
	var trimmed := path.strip_edges()
	if trimmed == "":
		return {"kind": "", "error": ""}
	if trimmed.begins_with("res://") or trimmed.begins_with("user://"):
		return {"kind": "", "error": "Media path must be absolute."}
	if trimmed.contains("://"):
		return {
			"kind": "",
			"error": "Remote media is not supported — choose a local file.",
		}
	if not trimmed.is_absolute_path():
		return {"kind": "", "error": "Media path must be absolute."}
	var kind := kind_for(trimmed)
	if kind == "":
		return {
			"kind": "",
			"error": "Unsupported media format. Supported: %s." % supported_text(),
		}
	# `file_exists` is Godot 4.7's regular-file check (false for directories,
	# devices and FIFOs), so a planted FIFO never reaches a decoder — the same
	# gate the text panes apply before `FileAccess.open`.
	if not FileAccess.file_exists(trimmed):
		return {
			"kind": "",
			"error": "Media file not found (or not a regular file): %s" % display_name(trimmed),
		}
	return {"kind": kind, "error": ""}

## The formats line, derived from the two tables so a new extension cannot
## leave the refusal message stale.
static func supported_text() -> String:
	var video := ""
	for ext in VIDEO_EXTENSIONS:
		video += ("" if video == "" else ", ") + "." + ext
	var audio := ""
	for ext in AUDIO_EXTENSIONS:
		audio += ("" if audio == "" else ", ") + "." + ext
	return "video %s; audio %s" % [video, audio]
