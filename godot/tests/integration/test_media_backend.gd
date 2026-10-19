extends GutTest
# Live checks for the GptyMedia FFI edge. The decode logic itself is covered
# by `crates/gpty-media`; these tests prove the Godot-facing shape: JSON in,
# Dictionary with packed arrays out, and a refusal for an untrusted path.

const FIXTURES := "../crates/gpty-media/tests/fixtures/"

func _fixture(name: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join(FIXTURES + name).simplify_path()

func _open(node: Node, name: String, extra: Dictionary = {}) -> Dictionary:
	var config := {"path": _fixture(name)}
	config.merge(extra)
	var answer = JSON.parse_string(node.open(JSON.stringify(config)))
	assert_true(answer is Dictionary, "open did not return a JSON object")
	if not answer.get("ok", false):
		return answer
	# Opening is asynchronous: the worker probes off the GUI thread.
	for _i in 500:
		var status = JSON.parse_string(node.status())
		if status.get("state") == "failed":
			return {"ok": false, "error": status.get("error")}
		if status.get("info") != null:
			return {"ok": true, "info": status["info"]}
		await get_tree().process_frame
	return {"ok": false, "error": {"code": "timeout", "message": "media did not open"}}

func test_video_decodes_to_packed_rgba() -> void:
	var node := GptyMedia.new()
	add_child_autofree(node)
	var opened = await _open(node, "h264.mp4")
	assert_true(opened.get("ok", false), str(opened))
	assert_eq(opened["info"]["video"]["codec"], "h264")

	var frame := {}
	for _i in 200:
		frame = node.poll_video()
		if not frame.is_empty():
			break
		await get_tree().process_frame
	assert_false(frame.is_empty(), "no video frame reached the FFI")
	assert_eq(frame["width"], 64)
	assert_eq(frame["height"], 48)
	var data = frame["data"]
	assert_true(data is PackedByteArray)
	assert_eq(data.size(), 64 * 48 * 4)
	node.close()

func test_audio_decodes_to_packed_f32() -> void:
	var node := GptyMedia.new()
	add_child_autofree(node)
	var opened = await _open(node, "opus.ogg", {"sample_rate": 44100, "channels": 2})
	assert_true(opened.get("ok", false), str(opened))
	assert_eq(opened["info"]["audio"]["codec"], "opus")

	var chunk := {}
	for _i in 200:
		chunk = node.poll_audio()
		if not chunk.is_empty():
			break
		await get_tree().process_frame
	assert_false(chunk.is_empty(), "no audio chunk reached the FFI")
	assert_eq(chunk["sample_rate"], 44100)
	assert_eq(chunk["channels"], 2)
	var data = chunk["data"]
	assert_true(data is PackedFloat32Array)
	assert_gt(data.size(), 0)
	assert_eq(data.size() % 2, 0)
	node.close()

func test_untrusted_paths_are_refused() -> void:
	var node := GptyMedia.new()
	add_child_autofree(node)
	for path in ["relative.mp4", "https://example.com/a.mp4", "res://icon.png"]:
		var answer = await _open(node, path)
		assert_true(answer is Dictionary)
		assert_false(answer.get("ok", true), path)
		assert_eq(answer["error"]["code"], "bad_path", path)
	node.close()
