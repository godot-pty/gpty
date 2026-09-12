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

## Every file in `user://` that belongs to this store: the store itself and any
## temp file a write may have left behind.
func _siblings() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open("user://")
	if dir == null:
		return out
	for entry in dir.get_files():
		if entry.begins_with(PREFIX):
			out.append("user://" + entry)
	return out

func _remove_path(p: String):
	# A test may occupy a path with a directory, and FileAccess.file_exists()
	# is false for a directory — so checking only for files left it behind and
	# poisoned later runs, since every write then failed to create its temp.
	var abs := ProjectSettings.globalize_path(p)
	if DirAccess.dir_exists_absolute(abs) or FileAccess.file_exists(p):
		DirAccess.remove_absolute(abs)

func test_round_trips_through_read_file():
	_mgr._write_file(PATH, {"a": 1, "b": "two"})
	var back = _mgr._read_file(PATH)
	assert_eq(back.get("a"), 1)
	assert_eq(back.get("b"), "two")

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
		if p != PATH:
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
	var dir := DirAccess.open("user://")
	assert_not_null(dir, "user:// must be a directory")
	var victim := "user://test_persistence_victim.txt"
	_remove_path(victim)
	var victim_file := FileAccess.open(victim, FileAccess.WRITE)
	victim_file.store_string("ORIGINAL")
	victim_file.close()

	# Occupy the *predictable* name with a symlink to the victim, as an attacker
	# with write access to user:// would.
	_remove_path(PATH + ".tmp")
	assert_eq(
		dir.create_link(
			ProjectSettings.globalize_path(victim), ProjectSettings.globalize_path(PATH + ".tmp")
		),
		OK,
		"the probe must be able to plant a symlink"
	)

	_mgr._write_file(PATH, {"payload": true})

	var victim_text := FileAccess.open(victim, FileAccess.READ).get_as_text()
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
		FileAccess.get_unix_permissions(ProjectSettings.globalize_path(PATH)),
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
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(tmp))

	fixed._write_file(PATH, {"new": true})

	var back = fixed._read_file(PATH)
	assert_true(back.get("old"), "the existing file must survive a failed write")
	assert_false(back.has("new"), "nothing may be written when the temp file cannot be created")
