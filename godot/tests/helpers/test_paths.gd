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

## Whether `path` is an absolute real path safely inside [`method user_dir`].
## Rejects empty paths, relative paths, '.', '..', '/', drive roots, and the
## [`method user_dir`] root itself.
static func is_safe_user_path(path: String) -> bool:
	if not BasePersistenceManager.is_real_absolute_path(path):
		return false
	var norm_path := _normalize_path(path)
	var norm_root := _normalize_path(user_dir())
	if norm_root == "" or norm_root == "/" or norm_root.ends_with(":/"):
		return false
	var prefix := norm_root + "/"
	if OS.get_name() == "Windows":
		return norm_path.to_lower().begins_with(prefix.to_lower())
	return norm_path.begins_with(prefix)

## Recursively removes `path` if it is a directory or file safely inside
## [`method user_dir`]. Refuses empty paths, relative paths, '.', '..', '/',
## and any path outside or equal to [`method user_dir`]. Returns true if the
## path was safely removed or does not exist, false if refused or if deletion
## failed.
static func remove_tree(path: String) -> bool:
	if not is_safe_user_path(path):
		return false
	var target := _normalize_path(path)
	if not DirAccess.dir_exists_absolute(target):
		if FileAccess.file_exists(target):
			return DirAccess.remove_absolute(target) == OK
		return true
	_delete_dir_recursive(target)
	return not DirAccess.dir_exists_absolute(target)

static func _normalize_path(p: String) -> String:
	var path := p.strip_edges().simplify_path()
	if path.length() > 1 and path.ends_with("/") and not path.ends_with(":/"):
		path = path.trim_suffix("/")
	return path

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
