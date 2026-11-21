class_name SchemeLibrary
extends RefCounted
## The colour schemes a terminal can wear: the ones shipped under
## `res://schemes/`, plus whatever the user imported into `user://schemes/`.
##
## A scheme file is untrusted input when it comes from disk, so this class
## never parses it itself: `GptyScheme.parse` asks `gpty_core::scheme`, which
## caps the text, closes the key set and refuses a DOCTYPE, an internal subset
## or an unknown entity. What this class owns is the library - listing, the
## capped read, the hex-to-`Color` conversion and the import id - so the
## Settings rows and the pane row share one answer.
##
## Files under the two library directories are app-managed (a shipped file, or
## the native copy an import wrote), so they are read through `FileAccess`;
## a scheme path outside them (an old `settings.json` value) still goes through
## `TextRead.read_prefix`, the one gate for a path the app did not create.

const SHIPPED_DIR := "res://schemes"
const USER_DIR := "user://schemes"
## Mirrors `gpty_core::scheme::MAX_SCHEME_BYTES`; a cut file must be refused,
## not parsed, because a truncated YAML can still be valid-but-wrong.
const MAX_BYTES := 1 << 14
const MAX_ID_CHARS := 48

## `USER_DIR` is the shipped default; this mutable copy is the test seam
## (`DocsBundle.bundle_path` is the same pattern), so a test points imports and
## listings at a temp directory instead of the developer's user data.
static var user_dir := USER_DIR

## Parsed schemes by path. A scheme file is immutable once imported (an import
## always writes a new file), so a hit is safe; `reset` is the escape hatch for
## a hand edit, and the v0.9.5 roadmap row owns a better reload.
static var _cache: Dictionary = {}

## Every scheme in the library, sorted by label. `shipped` says which directory
## it came from; a user file shadows a shipped one with the same id.
static func list() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var seen := {}
	for shipped in [false, true]:
		var dir := _dir_for(shipped)
		var access := DirAccess.open(dir)
		if access == null:
			continue
		var names := access.get_files()
		names.sort()
		for file_name in names:
			if not str(file_name).ends_with(".json") or str(file_name).begins_with("."):
				continue
			var id := str(file_name).get_basename()
			if seen.has(id):
				continue
			seen[id] = true
			var path := dir.path_join(str(file_name))
			entries.append({
				"id": id,
				"label": display_name(path),
				"path": path,
				"shipped": shipped,
			})
	entries.sort_custom(func(a, b): return str(a.label).to_lower() < str(b.label).to_lower())
	return entries

## The label a picker shows: the file's own `name` when it is readable, else
## the stem with its separators turned into spaces and each word capitalised.
static func display_name(path: String) -> String:
	var text := _read_library_text(path)
	if text != "":
		var parsed = JSON.parse_string(text)
		if parsed is Dictionary:
			var named: String = str(parsed.get("name", ""))
			if named != "":
				return named
	return _title_from_stem(path.get_file().get_basename())

## Parse one library file, or a scheme path outside the library. `{}` when the
## file is missing, too large, unreadable or not a scheme.
static func loaded(path: String) -> Dictionary:
	if path == "":
		return {}
	if _cache.has(path):
		return _cache[path]
	var text := ""
	if BasePersistenceManager.is_real_absolute_path(path):
		var read := TextRead.read_prefix(path, MAX_BYTES)
		if not read.ok or read.truncated:
			return {}
		text = str(read.text)
	else:
		text = _read_library_text(path)
		if text == "":
			return {}
	var parsed := parse_text(text, path.get_file())
	if parsed.get("ok", false) == true:
		_cache[path] = parsed
		return parsed
	return {}

## `GptyScheme.parse`'s JSON answer, normalised. `{ok: false, error: …}` when
## the extension is absent or the answer is not a dictionary.
static func parse_text(text: String, file_name: String) -> Dictionary:
	if not ClassDB.class_exists("GptyScheme"):
		return {"ok": false, "error": "The colour-scheme parser is not available in this build."}
	var answer = JSON.parse_string(GptyScheme.parse(text, file_name))
	if not (answer is Dictionary) or not answer.has("ok"):
		return {"ok": false, "error": "The colour-scheme parser gave no answer."}
	return answer

## Create `user_dir` when it does not exist. True when it is there.
static func ensure_user_dir() -> bool:
	var absolute := ProjectSettings.globalize_path(user_dir)
	if DirAccess.dir_exists_absolute(absolute):
		return true
	DirAccess.make_dir_recursive_absolute(absolute)
	return DirAccess.dir_exists_absolute(absolute)

## An id no library file already uses: lowercase ASCII letters, digits and
## hyphens, at most [constant MAX_ID_CHARS], then `-2` … `-99`. `""` when every
## candidate is taken (the caller refuses the import).
static func unique_user_id(base_name: String) -> String:
	var base := _sanitize_id(base_name)
	for attempt in range(1, 100):
		var candidate := base if attempt == 1 else "%s-%d" % [base, attempt]
		if not _id_taken(candidate):
			return candidate
	return ""

## The single hex-to-colour conversion for a parsed scheme.
static func color(scheme: Dictionary, key: String, fallback: Color) -> Color:
	var raw := str(scheme.get(key, ""))
	if raw == "":
		return fallback
	return Color.from_string(raw, fallback)

## Drop the parse cache (tests, and a deliberate re-read of an edited file).
static func reset() -> void:
	_cache.clear()

static func _dir_for(shipped: bool) -> String:
	return SHIPPED_DIR if shipped else user_dir

static func _read_library_text(path: String) -> String:
	if FileAccess.get_size(path) > MAX_BYTES:
		return ""
	return FileAccess.get_file_as_string(path)

static func _title_from_stem(stem: String) -> String:
	var words := stem.replace("-", " ").replace("_", " ").split(" ", false)
	var titled := PackedStringArray()
	for word in words:
		titled.append(word.substr(0, 1).to_upper() + word.substr(1))
	var label := " ".join(titled)
	return label if label != "" else "Scheme"

static func _sanitize_id(base_name: String) -> String:
	var lowered := base_name.to_lower()
	var out := ""
	var pending_dash := false
	for ch in lowered:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			if pending_dash and out != "":
				out += "-"
			pending_dash = false
			out += ch
		else:
			pending_dash = true
	if out.length() > MAX_ID_CHARS:
		out = out.left(MAX_ID_CHARS).rstrip("-")
	return out if out != "" else "scheme"

static func _id_taken(id: String) -> bool:
	var file := id + ".json"
	return FileAccess.file_exists(SHIPPED_DIR.path_join(file)) \
		or FileAccess.file_exists(user_dir.path_join(file))
