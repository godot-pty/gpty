extends GutTest
# BasePersistenceManager write path: the temp-file-and-rename replace, and the
# two properties that keep it from being a weapon.
#
# FileAccess.WRITE truncates its target as soon as it opens, so a crash
# mid-write used to leave an empty or partial file that _read_file reports as
# "no data" — resetting every setting, profile, workspace and concept store
# at once. These tests pin the observable replacement contract, that a planted
# symlink at the temp path is not followed, and that the store is owner-only.

const PATH := "user://test_persistence.json"
const PREFIX := "test_persistence.json."

## A manager whose temp-file name is fixed, so a test can make the temp
## creation fail deterministically. The shipped suffix is random by design
## (see `_temp_suffix`), which no test can occupy in advance.
class FixedTempManager extends BasePersistenceManager:
	func _temp_suffix() -> String:
		return "test"

var _mgr: Node

func before_each():
	_mgr = BasePersistenceManager.new()
	add_child_autofree(_mgr)
	_remove_files()

func after_each():
	_remove_files()

func _remove_files():
	for p in _siblings():
		_remove_path(p)
	_remove_path(PATH)

## The absolute path a store path resolves to. `_write_file` and `_read_file`
## apply `resolve_store_path`, so a test that inspects the file directly must
## ask the same function — otherwise it looks at `user://` while the manager
## wrote under `GPTY_TEST_USER_DIR`.
func _abs(p: String) -> String:
	var resolved := BasePersistenceManager.resolve_store_path(p)
	return resolved if resolved.is_absolute_path() else ProjectSettings.globalize_path(resolved)

## Every file belonging to this store: the store itself and any temp file a
## write may have left behind.
func _siblings() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(_abs(PATH).get_base_dir())
	if dir == null:
		return out
	for entry in dir.get_files():
		if entry.begins_with(PREFIX):
			out.append(_abs(PATH).get_base_dir().path_join(entry))
	return out

func _remove_path(p: String):
	# A test may occupy a path with a directory, and FileAccess.file_exists()
	# is false for a directory — so checking only for files left it behind and
	# poisoned later runs, since every write then failed to create its temp.
	var abs := _abs(p)
	if DirAccess.dir_exists_absolute(abs) or FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)

func test_round_trips_through_read_file():
	_mgr._write_file(PATH, {"a": 1, "b": "two"})
	var back = _mgr._read_file(PATH)
	assert_eq(back.get("a"), 1)
	assert_eq(back.get("b"), "two")

## The suite's user root is one rule, and only an absolute directory takes
## effect: the harness redirects every store, while a malformed value keeps
## `user://` so a typo cannot send stores somewhere the app cannot find again.
func test_store_paths_follow_only_an_absolute_test_root():
	var previous := OS.get_environment("GPTY_TEST_USER_DIR")
	var root := ProjectSettings.globalize_path("user://store_root_probe")
	OS.set_environment("GPTY_TEST_USER_DIR", root)
	var redirected := BasePersistenceManager.resolve_store_path("user://settings.json")
	var res_untouched := BasePersistenceManager.resolve_store_path("res://profiles.default.json")
	var abs_untouched := BasePersistenceManager.resolve_store_path("/absolute/settings.json")
	OS.set_environment("GPTY_TEST_USER_DIR", "relative/root")
	var relative_ignored := BasePersistenceManager.resolve_store_path("user://settings.json")
	# A scheme is not a directory, so it cannot be the sandbox either.
	OS.set_environment("GPTY_TEST_USER_DIR", "user://elsewhere")
	var virtual_ignored := BasePersistenceManager.resolve_store_path("user://settings.json")
	OS.set_environment("GPTY_TEST_USER_DIR", previous)

	assert_eq(redirected, root.path_join("settings.json"))
	assert_eq(res_untouched, "res://profiles.default.json")
	assert_eq(abs_untouched, "/absolute/settings.json")
	assert_eq(relative_ignored, "user://settings.json", "a relative root is ignored")
	assert_eq(virtual_ignored, "user://settings.json", "a virtual root is ignored")


## Godot calls `res://` and `user://` absolute (measured on 4.7.2), so
## "absolute" alone cannot guard a path that leaves Godot's resolution. These
## are the predicates every such boundary asks.
func test_virtual_paths_are_not_real_paths():
	assert_true(BasePersistenceManager.is_virtual_path("user://knowledge"))
	assert_true(BasePersistenceManager.is_virtual_path("res://knowledge.json"))
	assert_false(BasePersistenceManager.is_virtual_path("/tmp/notes"))
	assert_false(BasePersistenceManager.is_virtual_path("relative/notes"))

	assert_false(BasePersistenceManager.is_real_absolute_path("user://knowledge"))
	assert_false(BasePersistenceManager.is_real_absolute_path("res://knowledge.json"))
	assert_false(BasePersistenceManager.is_real_absolute_path("relative/notes"))
	assert_false(BasePersistenceManager.is_real_absolute_path(""))
	assert_true(BasePersistenceManager.is_real_absolute_path("/tmp/notes"))

	var real := BasePersistenceManager.real_path("user://store_root_probe")
	assert_false(BasePersistenceManager.is_virtual_path(real), real)
	assert_true(BasePersistenceManager.is_real_absolute_path(real), real)
	assert_eq(BasePersistenceManager.real_path("/tmp/notes"), "/tmp/notes")
	assert_true(BasePersistenceManager.real_path("res://profiles.default.json").ends_with(
		"profiles.default.json"))

func test_replaces_existing_content():
	_mgr._write_file(PATH, {"old": true})
	_mgr._write_file(PATH, {"new": true})
	var back = _mgr._read_file(PATH)
	assert_true(back.get("new"), "the second write must be stored")
	assert_false(back.has("old"), "the file must be replaced, not merged")

func test_leaves_no_temp_file_behind():
	_mgr._write_file(PATH, {"a": 1})
	var leftovers := PackedStringArray()
	for p in _siblings():
		if p != _abs(PATH):
			leftovers.append(p)
	assert_eq(
		leftovers.size(), 0,
		"the temp file must be renamed into place, never left behind (got %s)" % leftovers
	)

## The name a write builds its temp file in must not be one an attacker can
## occupy: `FileAccess.open(path, WRITE)` follows a symlink, so a fixed
## `<store>.tmp` let anything able to write in `user://` point the next save at
## a file of its choosing.
func test_a_planted_symlink_at_the_temp_path_is_not_followed():
	var dir := DirAccess.open(_abs(PATH).get_base_dir())
	assert_not_null(dir, "the store directory must exist")
	var victim := "user://test_persistence_victim.txt"
	_remove_path(victim)
	var victim_file := FileAccess.open(_abs(victim), FileAccess.WRITE)
	victim_file.store_string("ORIGINAL")
	victim_file.close()

	# Occupy the *predictable* name with a symlink to the victim, as an attacker
	# with write access to user:// would.
	_remove_path(PATH + ".tmp")
	assert_eq(
		dir.create_link(_abs(victim), _abs(PATH + ".tmp")),
		OK,
		"the probe must be able to plant a symlink"
	)

	_mgr._write_file(PATH, {"payload": true})

	var victim_text := FileAccess.open(_abs(victim), FileAccess.READ).get_as_text()
	assert_eq(victim_text, "ORIGINAL", "a planted symlink must never be written through")
	assert_true(_mgr._read_file(PATH).get("payload"), "the store must still be written")

	_remove_path(PATH + ".tmp")
	_remove_path(victim)

func test_a_written_store_is_owner_only():
	if OS.get_name() == "Windows":
		pending("file modes are not a Windows notion")
		return
	_mgr._write_file(PATH, {"a": 1})
	assert_eq(
		FileAccess.get_unix_permissions(_abs(PATH)),
		0x180,
		"a store must be readable by its owner only (0600)"
	)

func test_a_failed_write_leaves_the_previous_file_intact():
	# The property the temp-and-rename buys, made deterministic: if the write
	# cannot complete, the data already on disk must still be there. Writing
	# straight to the target truncated it first, so any failure mid-write (disk
	# full, crash, power loss) cost the previous contents too.
	_mgr._write_file(PATH, {"old": true})
	# Occupy the temp path with a directory so the temp file cannot be created.
	var fixed := FixedTempManager.new()
	add_child_autofree(fixed)
	var tmp := "%s.%s.tmp" % [PATH, "test"]
	DirAccess.make_dir_absolute(_abs(tmp))

	fixed._write_file(PATH, {"new": true})

	var back = fixed._read_file(PATH)
	assert_true(back.get("old"), "the existing file must survive a failed write")
	assert_false(back.has("new"), "nothing may be written when the temp file cannot be created")

# ── The owner-only repair on the read path ─────────────────────────────
#
# The write path sets `STORE_UNIX_MODE` on every store it lands, but a store
# written by an older build keeps the process umask's mode until it is saved
# again (measured on a normal install: `layout.json` 0644 beside
# `concepts.json` 0600), and the engine creates `user://` itself at 0755. These
# tests pin the repair: reading fixes the mode, contents are never rewritten,
# a symlink is not chmod'd through, and the directory that holds everything is
# closed to other accounts.

func test_a_loose_store_is_tightened_when_it_is_read():
	if OS.get_name() == "Windows":
		pending("file modes are not a Windows notion")
		return
	_mgr._write_file(PATH, {"kept": "value"})
	var abs := _abs(PATH)
	FileAccess.set_unix_permissions(abs, 0x1A4)  # 0644
	assert_eq(FileAccess.get_unix_permissions(abs), 0x1A4, "the probe must start world-readable")

	var back = _mgr._read_file(PATH)

	assert_eq(back.get("kept"), "value", "the contents must load unchanged")
	assert_eq(FileAccess.get_unix_permissions(abs), 0x180, "reading must repair the mode to 0600")

## A symlink at a store path is not the store. The write path replaces it by
## renaming over the link; the repair must not `chmod` whatever it points at,
## or a planted link would change a file outside gPTY's stores.
func test_a_symlinked_store_is_not_tightened_through():
	if OS.get_name() == "Windows":
		pending("file modes and symlinks are not a Windows notion")
		return
	var victim := PATH + ".victim"
	_remove_path(victim)
	var victim_file := FileAccess.open(_abs(victim), FileAccess.WRITE)
	victim_file.store_string('{"victim": true}')
	victim_file.close()
	FileAccess.set_unix_permissions(_abs(victim), 0x1A4)  # 0644
	_remove_path(PATH)
	var dir := DirAccess.open(_abs(PATH).get_base_dir())
	assert_not_null(dir, "the store directory must exist")
	assert_eq(
		dir.create_link(_abs(victim), _abs(PATH)),
		OK,
		"the probe must be able to plant a symlink"
	)

	var back = _mgr._read_file(PATH)

	assert_true(back.get("victim"), "the store behind the link is still read")
	assert_eq(
		FileAccess.get_unix_permissions(_abs(victim)),
		0x1A4,
		"a symlink's target must never be chmod'd through the store path"
	)

## The directory holding the stores is the first line of defense: a 0700 root
## hides every store inside it whatever a file's own mode says.
func test_the_user_root_is_owner_only():
	if OS.get_name() == "Windows":
		pending("file modes are not a Windows notion")
		return
	var root := BasePersistenceManager.user_root()
	assert_true(DirAccess.dir_exists_absolute(root), "the harness creates the test root")
	FileAccess.set_unix_permissions(root, 0x1ED)  # 0755
	assert_eq(FileAccess.get_unix_permissions(root), 0x1ED, "the probe must start open")

	BasePersistenceManager.secure_user_root()

	assert_eq(FileAccess.get_unix_permissions(root), 0x1C0, "the root must be owner-only (0700)")

## A filesystem that refuses the change is a diagnostic, not a failed load: the
## refusal is reported once per store per run rather than once per read, and
## the caller carries on with the store as it is.
func test_a_refused_repair_is_reported_once_per_store():
	if OS.get_name() == "Windows":
		pending("file modes are not a Windows notion")
		return
	BasePersistenceManager._mode_failure_reported.clear()
	# A regular file occupies a path component, so the store path cannot even be
	# opened for the repair - the shape of a filesystem refusing the change.
	_mgr._write_file(PATH, {"blocker": true})
	var blocked := _abs(PATH).path_join("inner.json")
	_mgr._tighten_store_mode(blocked)
	_mgr._tighten_store_mode(blocked)

	assert_true(
		BasePersistenceManager._mode_failure_reported.has(blocked),
		"the refusal must be recorded"
	)
	assert_eq(
		BasePersistenceManager._mode_failure_reported.size(),
		1,
		"and reported once, not once per read"
	)
	BasePersistenceManager._mode_failure_reported.clear()

## The engine's log directory is tightened with the root: Godot writes
## `user://logs/godot.log` with the process umask once file logging is on, and
## a log line is program text, which this project never wants world-readable.
func test_the_log_directory_is_tightened_with_the_root():
	if OS.get_name() == "Windows":
		pending("file modes are not a Windows notion")
		return
	var logs := BasePersistenceManager.user_root().path_join("logs")
	DirAccess.make_dir_recursive_absolute(logs)
	FileAccess.set_unix_permissions(logs, 0x1ED)  # 0755
	var log_file := logs.path_join("godot.log")
	var handle := FileAccess.open(log_file, FileAccess.WRITE)
	handle.store_string("engine log")
	handle.close()
	FileAccess.set_unix_permissions(log_file, 0x1A4)  # 0644

	BasePersistenceManager.secure_user_root()

	assert_eq(FileAccess.get_unix_permissions(logs), 0x1C0, "the log directory must be 0700")
	assert_eq(FileAccess.get_unix_permissions(log_file), 0x180, "and its files 0600")
	assert_eq(
		FileAccess.get_file_as_string(log_file),
		"engine log",
		"repairing a log file must not rewrite it"
	)
	DirAccess.remove_absolute(log_file)
	DirAccess.remove_absolute(logs)
