extends GutTest
# The media pane plays the local formats MediaFiles names, refuses everything
# else before a decoder sees it, and carries its path through layout state.
#
# Playback is asserted on the player itself (`playing` / `is_playing()`), not
# on a status string: Godot's audio driver is Dummy in this suite and a video
# decodes in headless mode, so both halves are observable without a display.
# The `.ogv` fixture is a five-second synthetic test pattern + sine tone
# (ffmpeg: testsrc + sine, libtheora/libvorbis); the WAV is generated here so
# no second binary asset is needed.

var _tmp: String


func before_each():
	MockAutoloads.setup()
	_tmp = TestPaths.user_path("media_pane_probe")
	DirAccess.make_dir_recursive_absolute(_tmp)


func after_each():
	_remove_tree(_tmp)
	MockAutoloads.teardown()


func _remove_tree(path: String):
	var dir := DirAccess.open(path)
	if dir:
		for f in dir.get_files():
			DirAccess.remove_absolute(path.path_join(f))
		for d in dir.get_directories():
			_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


func _make_pane() -> MediaPane:
	var pane := MediaPane.new()
	add_child_autofree(pane)
	return pane


func _wav(name := "tone.wav") -> String:
	var path := _tmp.path_join(name)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = 8000
	stream.stereo = false
	var data := PackedByteArray()
	data.resize(8000)
	data.fill(128)
	stream.data = data
	assert_eq(stream.save_to_wav(path), OK, "the test must be able to write its WAV")
	return path


func _video() -> String:
	var path := ProjectSettings.globalize_path("res://tests/fixtures/media/pattern.ogv")
	assert_true(FileAccess.file_exists(path), "the video fixture must be readable")
	return path


func test_pane_type_is_media():
	assert_eq(MediaPane.new()._pane_type(), "media", "the registry key is the discriminator")
	MediaPane.new().free()


func test_a_fresh_pane_is_idle():
	var pane := _make_pane()
	assert_false(pane._video.visible)
	assert_true(pane._placeholder.visible)
	assert_string_contains(pane._placeholder_hint.text, "pane settings")
	assert_eq(pane.file_path, "")


func test_an_audio_file_loads_and_plays():
	var pane := _make_pane()
	var path := _wav()
	pane.load_media(path)

	assert_eq(pane.file_path, path, "a played file is the pane's file")
	assert_eq(pane._kind, MediaFiles.AUDIO)
	assert_true(pane._audio.playing, "the pane must actually start the stream")
	assert_false(pane._video.visible)
	assert_eq(pane._audio.stream.get_length(), 1.0, "the loaded stream is the file's audio")
	assert_string_contains(pane._placeholder_title.text, "tone.wav")
	assert_string_contains(pane._status.text, "Playing")


func test_a_video_file_loads_and_plays():
	var pane := _make_pane()
	var path := _video()
	pane.load_media(path)
	await get_tree().process_frame

	assert_eq(pane.file_path, path)
	assert_eq(pane._kind, MediaFiles.VIDEO)
	assert_true(pane._video.visible, "a video uses the video surface")
	assert_false(pane._placeholder.visible)
	assert_true(pane._video.is_playing(), "the video decoder must be running")
	assert_gt(pane._video.get_stream_length(), 4.0, "the fixture is the five-second clip")
	assert_string_contains(pane._status.text, "Playing")


func test_an_unsupported_extension_is_refused_before_a_decoder():
	var pane := _make_pane()
	var path := _tmp.path_join("payload.gd")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("extends Node")
	f.close()
	pane.load_media(path)

	assert_eq(pane.file_path, "", "a refused path must not become the pane's file")
	assert_eq(pane._kind, "")
	assert_string_contains(pane._placeholder_hint.text, "Unsupported media format")


func test_a_relative_path_is_refused():
	var pane := _make_pane()
	pane.load_media("tone.wav")
	assert_eq(pane.file_path, "")
	assert_string_contains(pane._placeholder_hint.text, "must be absolute")


func test_a_remote_url_is_refused():
	var pane := _make_pane()
	pane.load_media("https://example.com/clip.ogg")
	assert_eq(pane.file_path, "")
	assert_string_contains(pane._placeholder_hint.text, "Remote media is not supported")


func test_a_missing_file_is_refused_without_clearing_the_pane_silently():
	var pane := _make_pane()
	pane.load_media(_tmp.path_join("missing.wav"))
	assert_eq(pane.file_path, "")
	assert_string_contains(pane._placeholder_hint.text, "not found")


func test_clearing_the_path_returns_to_idle():
	var pane := _make_pane()
	pane.load_media(_wav())
	assert_true(pane._audio.playing)
	pane.load_media("")
	assert_eq(pane.file_path, "")
	assert_false(pane._audio.playing)
	assert_true(pane._placeholder.visible)
	assert_string_contains(pane._placeholder_hint.text, "pane settings",
		"clearing the field is idle, not a decode failure")


func test_a_bad_path_stops_the_previous_playback():
	var pane := _make_pane()
	pane.load_media(_wav())
	assert_true(pane._audio.playing)

	pane.load_media(_tmp.path_join("missing.wav"))

	assert_false(pane._audio.playing, "a refused replacement must not keep playing")
	assert_null(pane._audio.stream, "the old stream is released")
	assert_eq(pane._kind, "")
	assert_false(pane._status.visible)


func test_apply_settings_loads_the_path():
	var pane := _make_pane()
	var path := _wav()
	pane.apply_settings({"file_path": path})
	assert_eq(pane.file_path, path)
	assert_true(pane._audio.playing)


func test_an_unrelated_setting_does_not_restart_playback():
	var pane := _make_pane()
	var path := _wav()
	pane.load_media(path)
	var stream: AudioStream = pane._audio.stream
	pane.apply_settings({"pane_name": "Renamed", "font_size": 18, "file_path": path})
	assert_true(pane._audio.stream == stream,
		"the same path must not reach the decoder again for a name/font edit")
	assert_true(pane._audio.playing)
	assert_eq(pane.pane_name, "Renamed")


func test_layout_state_carries_the_file_path():
	var pane := _make_pane()
	var path := _wav()
	pane.load_media(path)
	var state := pane._get_layout_state()
	assert_eq(state.get("type"), "media")
	assert_eq(state.get("file_path"), path)


func test_it_does_not_accept_routed_content():
	var pane := _make_pane()
	assert_false(pane.can_receive_content({}), "a media pane is not a concept receiver")
	assert_false(pane.receive_content("text", {}))
