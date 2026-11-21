extends GutTest

# Test TextRead.read_prefix capped buffer reads.
# Guarantees that buffer reads are bounded to `cap + 1` bytes without calling
# `get_as_text()`, eliminating uncapped reads and TOCTOU races on dynamic or
# growing files.

var _created_paths: Array[String] = []


func after_each():
	for path in _created_paths:
		TestPaths.remove_tree(path)
	_created_paths.clear()


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	_created_paths.append(path)
	return path


func test_refuses_invalid_or_non_absolute_paths():
	assert_false(TextRead.read_prefix("").ok, "empty path must be refused")
	assert_false(TextRead.read_prefix("not/absolute.txt").ok, "relative path must be refused")
	assert_false(TextRead.read_prefix("res://scenes/main.tscn").ok, "res:// scheme must be refused")
	assert_false(TextRead.read_prefix("user://config.json").ok, "user:// scheme must be refused")


func test_refuses_non_existent_file():
	var missing := TestPaths.user_path("absent_%d.txt" % Time.get_ticks_usec())
	var r := TextRead.read_prefix(missing)
	assert_false(r.ok, "missing file must be refused")
	assert_eq(r.text, "")
	assert_eq(r.size, 0)
	assert_false(r.truncated)


func test_refuses_directory():
	var dir := TestPaths.user_path("test_dir_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_created_paths.append(dir)
	var r := TextRead.read_prefix(dir)
	assert_false(r.ok, "directory path must be refused")
	assert_eq(r.text, "")
	assert_eq(r.size, 0)
	assert_false(r.truncated)


func test_reads_small_file_in_full():
	var file := _write_file(TestPaths.user_path("small_%d.txt" % Time.get_ticks_usec()), "hello world\n")
	var r := TextRead.read_prefix(file)
	assert_true(r.ok)
	assert_false(r.truncated)
	assert_eq(r.text, "hello world\n")
	assert_eq(r.size, 12)


func test_reads_exact_cap_file():
	var cap := 64
	var file := _write_file(TestPaths.user_path("exact_%d.txt" % Time.get_ticks_usec()), "x".repeat(cap))
	var r := TextRead.read_prefix(file, cap)
	assert_true(r.ok)
	assert_false(r.truncated, "file of exactly cap bytes must not be marked truncated")
	assert_eq(r.size, cap)
	assert_eq(r.text.length(), cap)


func test_reads_cap_plus_one_file():
	var cap := 64
	var file := _write_file(TestPaths.user_path("plus_one_%d.txt" % Time.get_ticks_usec()), "y".repeat(cap + 1))
	var r := TextRead.read_prefix(file, cap)
	assert_true(r.ok)
	assert_true(r.truncated, "file of cap + 1 bytes must be marked truncated")
	assert_eq(r.size, cap + 1)
	assert_eq(r.text.length(), cap, "only cap characters must be returned")


func test_2mib_file_reads_exactly_1mib_without_get_as_text():
	var cap: int = TextRead.DEFAULT_MAX_BYTES  # 1 MiB
	var total_size: int = 2 * (1 << 20)        # 2 MiB
	var file := _write_file(TestPaths.user_path("huge_2mib_%d.txt" % Time.get_ticks_usec()), "a".repeat(total_size))
	var r := TextRead.read_prefix(file, cap)

	assert_true(r.ok, "read of 2 MiB file must succeed")
	assert_true(r.truncated, "2 MiB file must be reported as truncated")
	assert_eq(r.size, total_size, "reported size must equal the 2 MiB file size on disk")
	assert_eq(r.text.length(), cap, "exactly 1 MiB of characters must be read")
	assert_true(r.text.begins_with("aaaa"))


func test_torn_utf8_sequence_at_cap():
	var cap := 16
	# 15 ASCII bytes + 2-byte character 'é' (0xC3, 0xA9) = 17 bytes.
	# Reading with cap 16 cuts right after the lead byte 0xC3.
	var content := "a".repeat(15) + "é"
	var file := _write_file(TestPaths.user_path("torn_utf8_%d.txt" % Time.get_ticks_usec()), content)
	var r := TextRead.read_prefix(file, cap)

	assert_true(r.ok)
	assert_true(r.truncated)
	assert_false(r.text.contains("\uFFFD"), "torn sequence at cap must be sliced cleanly without replacement char")
	assert_eq(r.text.length(), 15, "lead byte of incomplete sequence must be dropped")


func test_dynamic_file_reads_bounded_and_reports_read_size():
	if not FileAccess.file_exists("/proc/version"):
		pending("not running on Linux /proc")
		return
	var r_bounded := TextRead.read_prefix("/proc/version", 10)
	assert_true(r_bounded.ok)
	assert_true(r_bounded.truncated, "reading /proc/version with cap 10 must be truncated")
	assert_eq(r_bounded.text.length(), 10, "text length must be capped at 10 bytes")
	assert_gte(r_bounded.size, 10, "size must reflect at least the read buffer size")

	var r_full := TextRead.read_prefix("/proc/version")
	assert_true(r_full.ok)
	assert_false(r_full.truncated)
	assert_gt(r_full.size, 0, "size must be measured from bytes read even when stat reports 0")
	assert_true(r_full.text.contains("Linux"))


func test_text_read_script_does_not_call_get_as_text():
	var f := FileAccess.open("res://scenes/panes/text_read.gd", FileAccess.READ)
	assert_not_null(f, "text_read.gd must exist")
	var content := f.get_as_text()
	f.close()
	assert_false(content.contains("get_as_text()"), "TextRead must not call uncapped get_as_text()")
