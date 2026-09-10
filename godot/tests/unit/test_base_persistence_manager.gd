extends GutTest
# BasePersistenceManager write path: the temp-file-and-rename replace.
#
# FileAccess.WRITE truncates its target as soon as it opens, so a crash
# mid-write used to leave an empty or partial file that _read_file reports as
# "no data" — resetting every setting, profile, workspace and concept store
# at once. These tests pin the observable replacement contract.

const PATH := "user://test_persistence.json"
const TMP := "user://test_persistence.json.tmp"

var _mgr: Node

func before_each():
	_mgr = BasePersistenceManager.new()
	add_child_autofree(_mgr)
	_remove_files()

func after_each():
	_remove_files()

func _remove_files():
	for p in [PATH, TMP]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

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
	assert_false(
		FileAccess.file_exists(TMP),
		"the temp file must be renamed into place, never left behind"
	)

func test_a_failed_write_leaves_the_previous_file_intact():
	# The property the temp-and-rename buys, made deterministic: if the write
	# cannot complete, the data already on disk must still be there. Writing
	# straight to the target truncated it first, so any failure mid-write (disk
	# full, crash, power loss) cost the previous contents too.
	_mgr._write_file(PATH, {"old": true})
	# Occupy the temp path with a directory so the temp file cannot be created.
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(TMP))

	_mgr._write_file(PATH, {"new": true})

	var back = _mgr._read_file(PATH)
	assert_true(back.get("old"), "the existing file must survive a failed write")
	assert_false(back.has("new"), "nothing may be written when the temp file cannot be created")
