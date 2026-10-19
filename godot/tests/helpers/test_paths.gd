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
