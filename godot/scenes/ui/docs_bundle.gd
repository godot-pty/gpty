class_name DocsBundle
extends RefCounted
## The bundled documentation the Settings > About tab reads.
##
## `scripts/build-docs` packs every Markdown document reachable from `README.md`
## into `res://docs.json`, which the exporter includes because a release has no
## `docs/` directory. The generator has already done the display work - YAML
## front matter and the README's badge header dropped, `<details>` unwrapped,
## and every internal link rewritten to the `gpty-doc:` scheme with its
## fragment translated to the target heading's text - so this class only
## validates the bundle and answers keyed lookups.
##
## The bundle is app content, never user data: this class reads it, and no path
## in it is joined to anything or opened. The path check below is therefore a
## shape check (a malformed bundle must not claim entries), not the vault's
## write guard. It is deliberately its own small rule rather than
## `KnowledgeStore.note_path_problem`: that autoload's script is swapped in the
## test suite, so a static call through it would vanish under a test mock.
##
## Loading is lazy - the About tab's first visit, never application startup -
## and the parsed map is cached for the process. `bundle_path` and `reset()`
## are the test seams.

const BUNDLE_FILE := "res://docs.json"
## The page the About tab opens and the oldest history entry the viewer keeps.
const ROOT_DOC := "README.md"

const MAX_DOCS := 2000
const MAX_DOC_BYTES := 1 << 20
const MAX_BUNDLE_BYTES := 32 << 20
const MAX_PATH_BYTES := 1024

## Where the bundle is read from; a test points this at a fixture.
static var bundle_path := BUNDLE_FILE

static var _docs: Dictionary = {}
static var _loaded := false
static var _error := ""

## Load the bundle if it is not loaded yet. Answers `""` on success, else the
## sentence the About tab shows instead of a document.
static func ensure() -> String:
	if _loaded:
		return _error
	_loaded = true
	var file := FileAccess.open(bundle_path, FileAccess.READ)
	if file == null:
		_error = "The bundled documentation is missing."
		return _error
	var length := file.get_length()
	if length <= 0:
		file.close()
		_error = "The bundled documentation is missing."
		return _error
	if length > MAX_BUNDLE_BYTES:
		file.close()
		_error = "The bundled documentation is too large."
		return _error
	var source := file.get_as_text()
	file.close()
	var parsed := parse_bundle(source)
	if parsed.has("error"):
		_error = str(parsed["error"])
		return _error
	_docs = parsed["docs"]
	return ""

## Forget the parsed bundle: the next `ensure()` reads the file again.
static func reset() -> void:
	_docs = {}
	_loaded = false
	_error = ""

static func has(path: String) -> bool:
	return _docs.has(path)

static func text(path: String) -> String:
	var entry = _docs.get(path)
	return str(entry["text"]) if entry is Dictionary else ""

## Every bundled path, sorted - the shape a test or a future index reads.
static func paths() -> PackedStringArray:
	var out := PackedStringArray(_docs.keys())
	out.sort()
	return out

## Validate one decoded bundle without touching the filesystem. The bundle is a
## shipped resource, but it crosses into a label the user reads, so it gets the
## same treatment as a layout file: closed shape, path vocabulary and caps.
static func parse_bundle(source: String) -> Dictionary:
	if source.to_utf8_buffer().size() > MAX_BUNDLE_BYTES:
		return {"error": "Documentation bundle is too large."}
	var json := JSON.new()
	if json.parse(source) != OK:
		return {"error": "Documentation bundle is not valid JSON."}
	var data = json.get_data()
	if not (data is Dictionary):
		return {"error": "Documentation bundle has no object."}
	var raw = data.get("docs")
	if not (raw is Array) or raw.is_empty():
		return {"error": "Documentation bundle has no documents."}
	if raw.size() > MAX_DOCS:
		return {"error": "Documentation bundle has too many documents."}
	var docs := {}
	var seen := {}
	var total := 0
	for item in raw:
		if not (item is Dictionary):
			return {"error": "Documentation bundle has a malformed document."}
		var path := str(item.get("path", ""))
		var body = item.get("text")
		if not (body is String):
			return {"error": "Documentation bundle has a document without text."}
		var text: String = body
		var problem := _path_problem(path)
		if problem != "":
			return {"error": "%s: %s" % [path, problem]}
		var key := path.to_lower()
		if seen.has(key):
			return {"error": "Documentation bundle repeats %s." % path}
		seen[key] = true
		var size: int = text.to_utf8_buffer().size()
		if size > MAX_DOC_BYTES:
			return {"error": "%s is larger than the document cap." % path}
		total += size
		if total > MAX_BUNDLE_BYTES:
			return {"error": "Documentation bundle is too large."}
		docs[path] = {"path": path, "text": text}
	return {"docs": docs}

## The bundle's path vocabulary: a relative path of ordinary components, none
## hidden, ending in `.md`.
static func _path_problem(rel: String) -> String:
	if rel == "":
		return "empty path"
	if rel.to_utf8_buffer().size() > MAX_PATH_BYTES:
		return "path is too long"
	if rel.begins_with("/") or rel.contains("\\") or rel.contains(":"):
		return "path is not repository-relative"
	var parts := rel.split("/")
	if parts.is_empty() or not parts[parts.size() - 1].ends_with(".md"):
		return "not a Markdown document"
	for part in parts:
		if part == "" or part == "." or part == "..":
			return "path has an empty, current or parent component"
		if part.begins_with("."):
			return "path names a hidden entry"
	return ""
