class_name TerminalFonts
extends RefCounted
## The terminal's font loader: bytes, never a resource loader.
##
## `font_path` can come from a shared layout, a profile, a plugin's JSON or
## `settings.json`, and the old loader called `load()` on it. A `.tres` whose
## sub-resource is a GDScript executes during `load()`, so naming one as a font
## ran code with no Workspace Trust dialog - a font is not a spawn plan.
##
## The rules here:
##   * only an absolute path with a font extension is read (see
##     [constant PaneTypes.FONT_EXTENSIONS]); anything else is the bundled font;
##   * the file must be a regular file (Godot 4.7.2 reports false for
##     directories, FIFOs and devices - measured, same gate as `TextRead`);
##   * at most [constant MAX_FONT_BYTES] is read, because this runs on the GUI
##     thread with data a file chose;
##   * the bytes must carry a font tag and parse to at least one face.
##
## The bundled fallback is the one path that reaches `load()`, and it is a
## compile-time `res://` constant from the caller, never file data. It has to:
## an export carries the imported `.fontdata`, not the source `.ttf`, so
## reading the bundled font's bytes would fail in a packaged build.

## Largest font read. Nerd Font families run to a few MiB; 32 MiB is slack for
## a wide CJK face and still bounds a hostile "font" pointed at a huge file.
const MAX_FONT_BYTES := 32 << 20

## The bundled fonts, loaded once per path. `load()` shares the resource
## anyway; the cache just skips repeated loader lookups.
static var _bundled: Dictionary = {}

## A font for `path`, or the bundled `fallback` when `path` is not a font file.
##
## The caller sets `fixed_size` - the same contract the old `_load_font` had.
static func load_for(path: String, fallback: String) -> Font:
	if _is_data_path(path) and PaneTypes.font_extension_ok(path):
		var custom := _from_file(path)
		if custom != null:
			return custom
	return bundled(fallback)

## A real filesystem file, not a `res://`/`user://` virtual path. Godot calls
## those absolute too; a font there would be read from the project or the user
## directory, which is never what a setting means (and the bundled `res://`
## fonts are loaded through the trusted constant, not through their bytes).
static func _is_data_path(path: String) -> bool:
	return path != "" and path.is_absolute_path() \
		and not path.begins_with("res://") and not path.begins_with("user://")

## The trusted fallback font. `path` is a compile-time constant from the
## caller; it never carries file data.
static func bundled(path: String) -> Font:
	var cached = _bundled.get(path)
	if cached is Font:
		return cached
	var font: Font = load(path)
	if font != null:
		_bundled[path] = font
	return font

static func _from_file(path: String) -> FontFile:
	# `file_exists` is the path-type gate: false for directories, FIFOs and
	# character devices even through a symlink, so a scheme-style `/dev/zero`
	# cannot block this thread.
	if not FileAccess.file_exists(path):
		return null
	var size := FileAccess.get_size(path)
	if size <= 4 or size > MAX_FONT_BYTES:
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(size)
	f.close()
	if not _looks_like_font(bytes):
		return null
	var font := FontFile.new()
	font.data = bytes
	# FreeType reports a bad face here rather than at draw time; a zero means
	# the file named a font but is not one.
	if font.get_face_count() <= 0:
		return null
	return font

## True for the sfnt/OpenType/TrueType-collection/WOFF tags. A resource file
## (`.tres`) never starts with one, so the check refuses it before FreeType.
static func _looks_like_font(bytes: PackedByteArray) -> bool:
	if bytes.size() < 4:
		return false
	if bytes[0] == 0x00 and bytes[1] == 0x01 and bytes[2] == 0x00 and bytes[3] == 0x00:
		return true
	if bytes[0] == 0x4F and bytes[1] == 0x54 and bytes[2] == 0x54 and bytes[3] == 0x4F:  # OTTO
		return true
	if bytes[0] == 0x74 and bytes[1] == 0x72 and bytes[2] == 0x75 and bytes[3] == 0x65:  # true
		return true
	if bytes[0] == 0x74 and bytes[1] == 0x74 and bytes[2] == 0x63 and bytes[3] == 0x66:  # ttcf
		return true
	if bytes[0] == 0x77 and bytes[1] == 0x4F and bytes[2] == 0x46 and bytes[3] == 0x46:  # wOFF
		return true
	if bytes[0] == 0x77 and bytes[1] == 0x4F and bytes[2] == 0x46 and bytes[3] == 0x32:  # wOF2
		return true
	return false
