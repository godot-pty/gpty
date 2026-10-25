extends BasePersistenceManager
## KnowledgeStore — the bundled knowledge base's seed and resolver.
##
## `docs/content/wiki` is the source of truth, but a release has no `docs/`
## directory. `scripts/build-wiki` packs the notes into `res://knowledge.json`,
## which the exporter includes; this store unpacks that bundle into
## `user://knowledge/<content hash>/` the first time something asks for it.
##
## The hash is in the directory name on purpose. A release whose notes changed
## seeds a new directory instead of writing over the previous one, so a user's
## edits survive an upgrade but are never silently merged with new text. The
## wiki pane keeps the token (`@knowledge`) in its saved layout and resolves it
## to the current absolute path here, which is why a restored tile follows the
## installed build rather than a path from the machine that saved it.
##
## The bundle is app content, not workspace state: it is validated like any
## other file boundary (path shape, counts, byte caps, duplicate paths) before
## a single byte is written below `user://knowledge`. Nothing here touches the
## control socket, a PTY, or the vault index; the Wiki pane does that after it
## receives the resolved path.
##
## Test seam: `bundle_path` and `store_root` let the suite point the store at a
## temporary bundle/root instead of seeding the user's real vault.

const BUNDLE_FILE := "res://knowledge.json"
const STORE_ROOT := "user://knowledge"
## The value a profile/layout uses to name the shipped vault.
const TOKEN := "@knowledge"
## Written last, so a directory without it is a seed that never finished.
const MARKER := ".seeded"

const MAX_NOTES := 2000
const MAX_NOTE_BYTES := 1 << 20
const MAX_BUNDLE_BYTES := 32 << 20
const MAX_PATH_BYTES := 1024
const MIN_VERSION_CHARS := 8
const MAX_VERSION_CHARS := 64

## Test seams; the production values are the constants above.
var bundle_path := BUNDLE_FILE
var store_root := STORE_ROOT

var _resolved := ""
var _error := ""

func _on_init():
	reset()

## Forget the cached resolution. The next `resolve(TOKEN)` re-reads the bundle
## and reuses an already-seeded directory.
func reset() -> void:
	_resolved = ""
	_error = ""

## Why the last seed failed, or "" when it succeeded. The Wiki pane puts this
## in its placeholder instead of showing a bare empty list.
func last_error() -> String:
	return _error

## The vault path a configured value names. Anything but the token is returned
## unchanged — the Wiki pane still applies its own absolute-directory check to
## a user-typed path.
func resolve(configured: String) -> String:
	if configured != TOKEN:
		return configured
	if _resolved != "":
		return _resolved
	var seeded := _seed()
	if seeded == "":
		return ""
	_resolved = seeded
	return _resolved

func _seed() -> String:
	_error = ""
	var text := _read_text(bundle_path)
	if text == "":
		_error = "The bundled knowledge base is missing."
		return ""
	var parsed := parse_bundle(text)
	if parsed.has("error"):
		_error = str(parsed["error"])
		return ""
	var version := str(parsed["version"])
	var notes: Array = parsed["notes"]

	# The suite redirects every `user://` store through `GPTY_TEST_USER_DIR`;
	# resolving the store root the same way keeps the 52 seeded notes out of a
	# developer's real profile. An absolute test root passes through.
	var root := resolve_store_path(store_root)
	if not root.is_absolute_path():
		root = ProjectSettings.globalize_path(root)
	var final_dir := root.path_join(version)
	# A seeded directory is never rewritten: the hash names the content, and
	# whatever is in it may be the user's edits.
	if DirAccess.dir_exists_absolute(final_dir):
		return final_dir

	var root_exists := DirAccess.dir_exists_absolute(root)
	if not root_exists and DirAccess.make_dir_recursive_absolute(root) != OK:
		_error = "Could not create the knowledge base directory."
		return ""
	# Seed into a hidden sibling and rename it into place. A crash leaves a
	# temp directory, never a half-written vault under the version the pane
	# would open; a second instance that loses the rename adopts the winner.
	var temp_dir := root.path_join(".tmp-%s-%d" % [version, Time.get_ticks_usec()])
	if DirAccess.make_dir_recursive_absolute(temp_dir) != OK:
		_error = "Could not create the knowledge base staging directory."
		return ""
	for note in notes:
		var rel := str(note["path"])
		var target := temp_dir.path_join(rel)
		var parent := target.get_base_dir()
		var parent_exists := DirAccess.dir_exists_absolute(parent)
		if not parent_exists and DirAccess.make_dir_recursive_absolute(parent) != OK:
			_abort(temp_dir, "Could not create a note directory.")
			return ""
		if not _write_text(target, str(note["text"])):
			_abort(temp_dir, "Could not write " + rel + ".")
			return ""
	if not _write_text(temp_dir.path_join(MARKER), version):
		_abort(temp_dir, "Could not finish the knowledge base.")
		return ""
	if DirAccess.rename_absolute(temp_dir, final_dir) != OK:
		_remove_tree(temp_dir)
		if DirAccess.dir_exists_absolute(final_dir):
			return final_dir
		_error = "Could not install the knowledge base."
		return ""
	return final_dir

func _abort(temp_dir: String, why: String) -> void:
	_error = why
	_remove_tree(temp_dir)

## Validate `res://knowledge.json` without touching the filesystem. The bundle
## is a shipped resource, but it crosses into a writable vault, so it gets the
## same treatment as a layout file: closed shape, path vocabulary, caps, and a
## content hash that can only name a direct child of the store root.
static func parse_bundle(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_BUNDLE_BYTES:
		return {"error": "Knowledge bundle is too large."}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"error": "Knowledge bundle is not valid JSON."}
	var data = json.get_data()
	if not (data is Dictionary):
		return {"error": "Knowledge bundle has no object."}
	var raw = data.get("notes")
	if not (raw is Array) or raw.is_empty():
		return {"error": "Knowledge bundle has no notes."}
	if raw.size() > MAX_NOTES:
		return {"error": "Knowledge bundle has too many notes."}
	var version := str(data.get("version", ""))
	# A hand-built bundle without a usable version still seeds: hash the text
	# rather than inventing a directory name that could leave the root.
	if not _valid_version(version):
		version = text.sha256_text().substr(0, 16)
	var seen := {}
	var notes: Array = []
	var total := 0
	for item in raw:
		if not (item is Dictionary):
			return {"error": "Knowledge bundle has a malformed note."}
		var rel := str(item.get("path", ""))
		var body = item.get("text")
		if not (body is String):
			return {"error": "Knowledge bundle has a note without text."}
		var body_text: String = body
		var problem := note_path_problem(rel)
		if problem != "":
			return {"error": "%s: %s" % [rel, problem]}
		var key := rel.to_lower()
		if seen.has(key):
			return {"error": "Knowledge bundle repeats %s." % rel}
		seen[key] = true
		var size: int = body_text.to_utf8_buffer().size()
		if size > MAX_NOTE_BYTES:
			return {"error": "%s is larger than the note cap." % rel}
		total += size
		if total > MAX_BUNDLE_BYTES:
			return {"error": "Knowledge bundle is too large."}
		notes.append({"path": rel, "text": body_text})
	return {"version": version, "notes": notes}

## The wiki vault's path vocabulary, applied before a bundle byte is written:
## a relative path of ordinary components, none hidden, ending in `.md`.
static func note_path_problem(rel: String) -> String:
	if rel == "":
		return "empty path"
	if rel.to_utf8_buffer().size() > MAX_PATH_BYTES:
		return "path is too long"
	if rel.begins_with("/") or rel.contains("\\") or rel.contains(":") or rel.contains("\u0000"):
		return "path is not vault-relative"
	var parts := rel.split("/")
	if parts.is_empty() or not parts[parts.size() - 1].ends_with(".md"):
		return "not a Markdown note"
	for part in parts:
		if part == "" or part == "." or part == "..":
			return "path has an empty, current or parent component"
		if part.begins_with("."):
			return "path names a hidden entry"
	return ""

static func _valid_version(value: String) -> bool:
	if value.length() < MIN_VERSION_CHARS or value.length() > MAX_VERSION_CHARS:
		return false
	for ch in value:
		if not "0123456789abcdef".contains(ch):
			return false
	return true

static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var child := path.path_join(name)
		if dir.current_is_dir():
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
