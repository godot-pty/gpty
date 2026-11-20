extends GutTest
# TestPaths — safe fixture paths and tree cleanup for GUT tests.
# Refuses unsafe paths (empty, relative, '.', '..', '/', and anything outside
# TestPaths.user_dir()) to eliminate working-tree deletion hazards.

func test_remove_tree_refuses_empty_path():
	assert_false(TestPaths.remove_tree(""), "empty path must be refused")
	assert_false(TestPaths.remove_tree("   "), "whitespace-only path must be refused")

func test_remove_tree_refuses_relative_path():
	assert_false(TestPaths.remove_tree("."), "'.' must be refused")
	assert_false(TestPaths.remove_tree(".."), "'..' must be refused")
	assert_false(TestPaths.remove_tree("./probe"), "'./probe' must be refused")
	assert_false(TestPaths.remove_tree("probe"), "'probe' must be refused")
	assert_false(TestPaths.remove_tree("relative/path"), "relative path must be refused")

func test_remove_tree_refuses_virtual_paths():
	assert_false(TestPaths.remove_tree("res://"), "res:// root must be refused")
	assert_false(TestPaths.remove_tree("res://scenes"), "res:// path must be refused")
	assert_false(TestPaths.remove_tree("user://"), "user:// root must be refused")
	assert_false(TestPaths.remove_tree("user://fixture"), "user:// path must be refused")

func test_remove_tree_refuses_root_and_user_dir():
	assert_false(TestPaths.remove_tree("/"), "'/' root must be refused")
	assert_false(TestPaths.remove_tree(TestPaths.user_dir()), "user_dir() root must be refused")
	assert_false(TestPaths.remove_tree(TestPaths.user_dir() + "/"), "user_dir() with trailing slash must be refused")

func test_remove_tree_refuses_paths_outside_user_dir():
	assert_false(TestPaths.remove_tree("/tmp"), "system /tmp must be refused")
	assert_false(TestPaths.remove_tree(TestPaths.user_dir() + "/../escape"), "path traversal outside user_dir must be refused")
	assert_false(TestPaths.remove_tree(TestPaths.user_dir() + "_other/probe"), "sibling directory of user_dir must be refused")

func test_remove_tree_deletes_directory_tree_and_files():
	var fixture := TestPaths.user_path("probe_tree_%d" % Time.get_ticks_usec())
	var deep_dir := fixture.path_join("nested/deep")
	DirAccess.make_dir_recursive_absolute(deep_dir)
	_write_file(fixture.path_join("root.txt"), "root")
	_write_file(fixture.path_join("nested/mid.txt"), "mid")
	_write_file(deep_dir.path_join("leaf.txt"), "leaf")
	_write_file(fixture.path_join(".hidden.txt"), "hidden")

	assert_true(DirAccess.dir_exists_absolute(fixture), "fixture directory must exist before removal")
	assert_true(TestPaths.remove_tree(fixture), "remove_tree must succeed on fixture inside user_dir")
	assert_false(DirAccess.dir_exists_absolute(fixture), "fixture directory must no longer exist after removal")
	assert_false(FileAccess.file_exists(deep_dir.path_join("leaf.txt")), "nested file must no longer exist")

func test_remove_tree_handles_non_existent_path_safely():
	var absent := TestPaths.user_path("does_not_exist_%d" % Time.get_ticks_usec())
	assert_true(TestPaths.remove_tree(absent), "removing non-existent path inside user_dir should safely succeed")

func test_remove_tree_removes_single_file():
	var file := TestPaths.user_path("probe_file_%d.txt" % Time.get_ticks_usec())
	_write_file(file, "content")
	assert_true(FileAccess.file_exists(file), "file must exist before removal")
	assert_true(TestPaths.remove_tree(file), "remove_tree must succeed on single file")
	assert_false(FileAccess.file_exists(file), "file must be gone after removal")

func test_is_safe_user_path_validates_bounds():
	assert_false(TestPaths.is_safe_user_path(""))
	assert_false(TestPaths.is_safe_user_path("."))
	assert_false(TestPaths.is_safe_user_path("/"))
	assert_false(TestPaths.is_safe_user_path(TestPaths.user_dir()))
	assert_false(TestPaths.is_safe_user_path("res://foo"))
	assert_false(TestPaths.is_safe_user_path("user://foo"))
	assert_true(TestPaths.is_safe_user_path(TestPaths.user_path("valid_subpath")))
	assert_true(TestPaths.is_safe_user_path(TestPaths.user_path("valid_subpath/deep/nested")))

## The Windows spelling, pinned on every platform: the root comes from the
## environment with backslashes while `user_path()` joins with "/", and
## `simplify_path()` keeps the drive separator as written - the raw prefix
## compare answered false for every fixture, so `remove_tree` deleted nothing
## and every fixed-name fixture inherited the previous test's files
## (`windows-smoke` 44648884305: 24 failing tests from one refused helper).
func test_a_windows_drive_root_accepts_its_children():
	var root := "C:\\Users\\runneradmin\\AppData\\Local\\Temp\\tmp.abc\\user"
	assert_true(TestPaths.is_safe_path_under(root.path_join("probe"), root, true),
		"a child joined with '/'")
	assert_true(TestPaths.is_safe_path_under(root + "\\nested\\deep", root, true),
		"a child spelled with backslashes")
	assert_true(TestPaths.is_safe_path_under(
		"c:\\users\\RUNNERADMIN\\appdata\\local\\temp\\tmp.ABC\\user\\probe", root, true),
		"drive and directory case are Windows-insensitive")
	assert_false(TestPaths.is_safe_path_under(root, root, true), "the root itself is not inside")
	assert_false(TestPaths.is_safe_path_under(root + "/../escape", root, true), "'..' must not escape")
	assert_false(TestPaths.is_safe_path_under(root + "_other/probe", root, true),
		"a sibling that starts with the root's bytes")
	assert_false(TestPaths.is_safe_path_under("D:\\elsewhere\\probe", root, true), "another drive")

func test_a_posix_root_compares_case_sensitively():
	assert_true(TestPaths.is_safe_path_under("/tmp/user/probe", "/tmp/user", false))
	assert_false(TestPaths.is_safe_path_under("/tmp/USER/probe", "/tmp/user", false))

func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
