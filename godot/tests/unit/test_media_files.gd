extends GutTest
# MediaFiles is the closed table behind the media pane and the file tree's
# media route: an extension decides the stream kind, and `check` adds the
# path and regular-file gates before any decoder sees the name.

var _tmp: String


func before_each():
	_tmp = TestPaths.user_path("media_files_probe")
	DirAccess.make_dir_recursive_absolute(_tmp)


func after_each():
	_remove_tree(_tmp)


func _remove_tree(path: String):
	var dir := DirAccess.open(path)
	if dir:
		for f in dir.get_files():
			DirAccess.remove_absolute(path.path_join(f))
		for d in dir.get_directories():
			_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


func _write(path: String, text := "x") -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	return path


func test_video_and_audio_extensions_are_known():
	for path in [
		"/p/movie.ogv", "/p/movie.mp4", "/p/movie.m4v", "/p/movie.mov",
		"/p/movie.mkv", "/p/movie.webm", "/p/movie.avi", "/p/movie.ts",
		"/p/movie.m2ts",
	]:
		assert_eq(MediaFiles.kind_for(path), MediaFiles.VIDEO, path)
	for path in ["/p/song.ogg", "/p/song.oga", "/p/song.mp3", "/p/song.wav"]:
		assert_eq(MediaFiles.kind_for(path), MediaFiles.AUDIO, path)


func test_extensions_are_case_insensitive():
	assert_eq(MediaFiles.kind_for("/p/MOVIE.OGV"), MediaFiles.VIDEO)
	assert_eq(MediaFiles.kind_for("/p/MOVIE.MP4"), MediaFiles.VIDEO)
	assert_eq(MediaFiles.kind_for("/p/SONG.WAV"), MediaFiles.AUDIO)


func test_unknown_formats_are_not_media():
	for path in ["/p/song.flac", "/p/photo.png", "/p/program.exe", "/p/notes.md", "/p/noext"]:
		assert_eq(MediaFiles.kind_for(path), "", path)
		assert_eq(MediaFiles.pane_for(path), "", path)


func test_a_known_format_routes_to_the_media_pane():
	assert_eq(MediaFiles.pane_for("/p/movie.ogv"), "media")
	assert_eq(MediaFiles.pane_for("/p/movie.mp4"), "media")
	assert_eq(MediaFiles.pane_for("/p/song.ogg"), "media")


func test_check_accepts_an_absolute_regular_file():
	var path := _write(_tmp.path_join("clip.wav"))
	var verdict := MediaFiles.check(path)
	assert_eq(verdict.error, "")
	assert_eq(verdict.kind, MediaFiles.AUDIO)


func test_check_treats_an_empty_path_as_no_selection():
	assert_eq(MediaFiles.check("").error, "", "an empty path is idle, not an error")


func test_check_refuses_relative_and_remote_paths():
	assert_eq(MediaFiles.check("clip.wav").error, "Media path must be absolute.")
	var remote := MediaFiles.check("https://example.com/clip.ogg")
	assert_string_contains(remote.error, "Remote media is not supported")
	assert_eq(MediaFiles.check("res://tests/fixtures/media/pattern.ogv").error,
		"Media path must be absolute.")


func test_check_refuses_an_unknown_format_before_a_decoder():
	var path := _write(_tmp.path_join("payload.gd"))
	var verdict := MediaFiles.check(path)
	assert_eq(verdict.kind, "")
	assert_string_contains(verdict.error, "Unsupported media format")
	assert_string_contains(verdict.error, ".ogv", "the message names the supported video format")
	assert_string_contains(verdict.error, ".wav", "the message names the supported audio formats")


func test_check_refuses_a_missing_or_non_regular_file():
	var missing := MediaFiles.check(_tmp.path_join("missing.wav"))
	assert_eq(missing.kind, "")
	assert_string_contains(missing.error, "not found")
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("folder.wav"))
	var directory := MediaFiles.check(_tmp.path_join("folder.wav"))
	assert_string_contains(directory.error, "not a regular file")


func test_supported_text_names_every_table_entry():
	var text := MediaFiles.supported_text()
	for ext in MediaFiles.VIDEO_EXTENSIONS + MediaFiles.AUDIO_EXTENSIONS:
		assert_string_contains(text, "." + ext)
