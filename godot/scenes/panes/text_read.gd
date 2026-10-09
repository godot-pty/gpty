class_name TextRead
extends RefCounted
## One definition of the capped untrusted-path read.
##
## A pane's path can come from an untrusted layout/profile (or a typo), so
## every read is gated the same way: absolute paths only, the path must be a
## regular file, and at most [constant DEFAULT_MAX_BYTES] is read — the reader
## runs on the GUI thread.
##
## `FileAccess.file_exists` is the path-type gate on Godot 4.7.2 — measured:
## false for directories, character devices (`/dev/zero`) and FIFOs, even when
## reached through a symlink, true only for regular files (symlinks to regular
## files included) — so a non-regular path never reaches `open` (which on a
## FIFO would block the GUI thread until a writer appears). `get_size()`
## returns -1 for anything non-regular.

## Largest read any pane performs. `code_viewer` and the wiki pane share it.
const DEFAULT_MAX_BYTES := 1 << 20

## Read at most `cap` bytes of `path`.
##
## Returns `{"ok": bool, "text": String, "truncated": bool, "size": int}`.
## `ok` is false — with no read attempted — for a non-absolute path, a
## non-regular file, a bad size, or a failed open. `text` decodes a torn UTF-8
## tail by hand when the cap landed inside a sequence.
static func read_prefix(path: String, cap: int = DEFAULT_MAX_BYTES) -> Dictionary:
	if path == "" or not path.is_absolute_path():
		return {"ok": false, "text": "", "truncated": false, "size": 0}
	if not FileAccess.file_exists(path):
		return {"ok": false, "text": "", "truncated": false, "size": 0}
	var size := FileAccess.get_size(path)
	if size < 0:
		return {"ok": false, "text": "", "truncated": false, "size": 0}
	var f = FileAccess.open(path, FileAccess.READ)
	if not f:
		return {"ok": false, "text": "", "truncated": false, "size": 0}
	var truncated := size > cap
	var text := (
		_decode_utf8_prefix(f.get_buffer(cap)) if truncated else f.get_as_text()
	)
	return {"ok": true, "text": text, "truncated": truncated, "size": size}

## Decode at most `cap` bytes, cutting a UTF-8 sequence the cap landed inside
## so the text does not end on a replacement glyph.
static func _decode_utf8_prefix(bytes: PackedByteArray) -> String:
	var size := bytes.size()
	var cut := size
	# Walk back over up to 3 continuation bytes to the lead of the last
	# sequence; if that sequence is incomplete, drop it as well.
	while cut > 0 and size - cut < 4 and (bytes[cut - 1] & 0xC0) == 0x80:
		cut -= 1
	if cut > 0:
		var lead_index := cut - 1
		var lead: int = bytes[lead_index]
		var need := 1
		if lead & 0xE0 == 0xC0:
			need = 2
		elif lead & 0xF0 == 0xE0:
			need = 3
		elif lead & 0xF8 == 0xF0:
			need = 4
		cut = size if size - lead_index >= need else lead_index
	return bytes.slice(0, cut).get_string_from_utf8()

## The one truncation notice both panes show.
static func truncation_notice(cap: int, total: int) -> String:
	return "\n\n… truncated: showing the first %s of %s …\n" % [
		String.humanize_size(cap), String.humanize_size(total),
	]
