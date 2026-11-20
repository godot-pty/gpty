class_name TestPaths
## The per-run user directory every test that needs a filesystem path writes
## under.
##
## `user://` resolves through the OS — the Known Folder API on Windows, which
## no environment variable redirects — so a suite that created probe vaults or
## legacy layouts there would write into the developer's real profile. The
## harness (`scripts/gut-check`, and the live smoke) exports
## `GPTY_TEST_USER_DIR`, and this helper is the test-facing half of the same
## seam `BasePersistenceManager.resolve_store_path` applies to the stores and
## `history_db_path` applies to the gdext scrollback database.
##
## A bare GUT run without the harness falls back to `user://`, which is what a
## developer expects when running the suite directly.

static func user_dir() -> String:
	var root := BasePersistenceManager.user_root_override()
	if root != "":
		DirAccess.make_dir_recursive_absolute(root)
		return root
	return ProjectSettings.globalize_path("user://").trim_suffix("/").trim_suffix("\\")

## An absolute path under the run's user directory. `rel` is a name or a
## slash-separated relative path, never a `user://` path.
static func user_path(rel: String) -> String:
	return user_dir().path_join(rel.trim_prefix("/"))

## A fresh, empty fixture directory under the run's user root. Any tree left
## at `rel` by an interrupted run, or by a teardown whose removal was refused,
## is removed first: a fixed fixture name that is never emptied makes one
## failed test poison every later test that reuses the name (measured on
## `windows-smoke`: a refused removal turned four `test_file_tree` tests and
## five `test_wiki_pane` tests red, none of them about their own subject).
static func fresh_dir(rel: String) -> String:
	var path := user_path(rel)
	if not remove_tree(path):
		push_warning("TestPaths.fresh_dir: could not clear %s; the fixture may inherit files" % path)
	DirAccess.make_dir_recursive_absolute(path)
	return path

## `p` in one spelling, for comparing two paths on one platform. On Windows
## `\` and `/` are unified first - both separate there, and
## `String.simplify_path()` keeps a drive prefix exactly as it was written, so
## the environment's "C:\...\user" and a `path_join`ed "C:\...\user/probe"
## normalised to "C:/..." and "C:\..." and never shared a prefix. The bytes are
## otherwise left alone: a real path may legitimately end in a space, and
## trimming it here compared a different string from the one on disk.
static func normalize_path(p: String, windows := OS.get_name() == "Windows") -> String:
	var path := p.replace("\\", "/") if windows else p
	path = path.simplify_path()
	if path.length() > 1 and path.ends_with("/") and not path.ends_with(":/"):
		path = path.trim_suffix("/")
	return path

## Whether `path` is an absolute real path strictly under `root`: never `root`
## itself, never a sibling that merely shares its name as a string prefix.
## `windows` selects the separator and case rules (default: this platform), so a
## test can pin the Windows spelling on any platform.
static func is_safe_path_under(path: String, root: String, windows := OS.get_name() == "Windows") -> bool:
	if not BasePersistenceManager.is_real_absolute_path(path):
		return false
	var norm_path := normalize_path(path, windows)
	var norm_root := normalize_path(root, windows)
	if norm_root == "" or norm_root == "/" or norm_root.ends_with(":/"):
		return false
	var prefix := norm_root + "/"
	if windows:
		return norm_path.to_lower().begins_with(prefix.to_lower())
	return norm_path.begins_with(prefix)

## Whether `path` is an absolute real path safely inside [`method user_dir`].
static func is_safe_user_path(path: String) -> bool:
	return is_safe_path_under(path, user_dir())

## Recursively removes `path` if it is a directory or file safely inside
## [`method user_dir`]. Refuses empty paths, relative paths, '.', '..', '/',
## and any path outside or equal to [`method user_dir`]. Returns true if the
## path was safely removed or does not exist, false if refused or if deletion
## failed.
static func remove_tree(path: String) -> bool:
	if not is_safe_user_path(path):
		return false
	var target := normalize_path(path)
	if not DirAccess.dir_exists_absolute(target):
		if FileAccess.file_exists(target):
			return DirAccess.remove_absolute(target) == OK
		return true
	_delete_dir_recursive(target)
	return not DirAccess.dir_exists_absolute(target)

static func _delete_dir_recursive(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir != null:
		dir.include_hidden = true
		for f in dir.get_files():
			DirAccess.remove_absolute(dir_path.path_join(f))
		for d in dir.get_directories():
			var child := dir_path.path_join(d)
			if is_safe_user_path(child):
				_delete_dir_recursive(child)
		dir = null
	DirAccess.remove_absolute(dir_path)
