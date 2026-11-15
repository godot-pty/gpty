extends SceneTree
# Idiom probe for the GDScript performance sweep.
#
# Measures the shapes the audit rows replace, on the installed Godot build:
# per-character String indexing and appends vs a native slice, a Dictionary
# default container vs a plain get, `range()` vs integer iteration, font
# measurement, the palette read, a reusable Image vs a fresh one, the audio
# interleave loop, and a NodePath lookup vs a cached reference.
#
#   godot --headless --path godot -s res://tests/bench/gdscript_probe.gd
#
# Median of five runs per case; prints `probe <name> iters=<n> median_us=<f>
# per_op_us=<f>`. This is a measurement tool, not a test: there are no
# assertions and no pass/fail. The results belong in a roadmap row's before/
# after text; they are never the user-visible gain on their own.

var _sink := 0
var _last_color := Color.BLACK

var _line := ""
var _dict := {}
var _font: Font
var _label := "a-forty-character-label-for-font-measure"
var _img_w := 1280
var _img_h := 720
var _img_data := PackedByteArray()
var _image: Image
var _audio := PackedFloat32Array()
var _host: Node
var _cached_node: Node


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	print("gdscript_probe: godot=%s headless=%s" % [
		Engine.get_version_info()["string"], str(DisplayServer.get_name() == "headless")])
	_case_string()
	_case_dict()
	_case_range()
	_case_font()
	_case_palette()
	_case_image()
	_case_audio()
	_case_node_path()
	print("gdscript_probe: sink=%d" % _sink)
	quit()


## Five timed runs, the median printed. `fn` takes the iteration count.
func _record(name: String, iterations: int, fn: Callable) -> void:
	var samples: Array[float] = []
	for _r in 5:
		var started := Time.get_ticks_usec()
		fn.call(iterations)
		samples.append(float(Time.get_ticks_usec() - started))
	samples.sort()
	var median: float = samples[2]
	print("probe %s iters=%d median_us=%.1f per_op_us=%.3f" % [
		name, iterations, median, median / float(iterations)])


# ── String indexing and appends ────────────────────────────────────────
func _case_string() -> void:
	_line = "0123456789".repeat(20)
	_record("string_index_concat", 2000, Callable(self, "_string_index_concat"))
	_record("string_run_slice", 2000, Callable(self, "_string_run_slice"))


func _string_index_concat(iters: int) -> void:
	for _i in iters:
		var text := ""
		for c in 200:
			var ch: String = _line[c]
			text += ch
		_sink += text.length()


func _string_run_slice(iters: int) -> void:
	for _i in iters:
		var text := _line.substr(0, 200)
		_sink += text.length()


# ── Dictionary default containers ──────────────────────────────────────
func _case_dict() -> void:
	_dict = {"a": 1, "b": 2, "c": 3, "d": 4, "e": 5}
	_record("dict_default_empty", 200000, Callable(self, "_dict_default_empty"))
	_record("dict_plain_get", 200000, Callable(self, "_dict_plain_get"))


func _dict_default_empty(iters: int) -> void:
	for _i in iters:
		_sink += _dict.get("missing", {}).size()


func _dict_plain_get(iters: int) -> void:
	for _i in iters:
		if _dict.get("missing") == null:
			_sink += 1


# ── range() vs integer iteration ───────────────────────────────────────
func _case_range() -> void:
	_record("range_loop", 1000, Callable(self, "_range_loop"))
	_record("int_loop", 1000, Callable(self, "_int_loop"))


func _range_loop(iters: int) -> void:
	for _i in iters:
		for n in range(1000):
			_sink += n


func _int_loop(iters: int) -> void:
	for _i in iters:
		for n in 1000:
			_sink += n


# ── Font measurement ───────────────────────────────────────────────────
func _case_font() -> void:
	_font = ThemeDB.fallback_font
	if _font == null:
		print("probe get_string_size skipped=no-fallback-font")
		return
	_record("get_string_size", 10000, Callable(self, "_measure_label"))


func _measure_label(iters: int) -> void:
	for _i in iters:
		_sink += int(_font.get_string_size(
			_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x)


# ── Palette read ───────────────────────────────────────────────────────
func _case_palette() -> void:
	_record("palette_read", 100000, Callable(self, "_palette_read"))
	_record("palette_local", 100000, Callable(self, "_palette_local"))


func _palette_read(iters: int) -> void:
	for _i in iters:
		_last_color = UiPalette.active().ACCENT
		_sink += int(_last_color.r * 255.0)


func _palette_local(iters: int) -> void:
	var accent := UiPalette.active().ACCENT
	for _i in iters:
		_last_color = accent
		_sink += int(_last_color.r * 255.0)


# ── A fresh Image vs a reused one ──────────────────────────────────────
func _case_image() -> void:
	if not ClassDB.class_has_method("Image", "set_data"):
		print("probe image_frame skipped=no-Image.set_data")
		return
	_img_data.resize(_img_w * _img_h * 4)
	_image = Image.create_from_data(
		_img_w, _img_h, false, Image.FORMAT_RGBA8, _img_data)
	_record("image_create_from_data", 30, Callable(self, "_image_create"))
	_record("image_create_force", 30, Callable(self, "_image_create_force"))
	_record("image_set_data", 30, Callable(self, "_image_reuse"))
	_record("image_set_force", 30, Callable(self, "_image_reuse_force"))


func _image_create(iters: int) -> void:
	for _i in iters:
		var img := Image.create_from_data(
			_img_w, _img_h, false, Image.FORMAT_RGBA8, _img_data)
		_sink += img.get_width()


func _image_create_force(iters: int) -> void:
	for _i in iters:
		var img := Image.create_from_data(
			_img_w, _img_h, false, Image.FORMAT_RGBA8, _img_data)
		_sink += img.get_data().size()


func _image_reuse(iters: int) -> void:
	for _i in iters:
		_image.set_data(_img_w, _img_h, false, Image.FORMAT_RGBA8, _img_data)
		_sink += _image.get_width()


func _image_reuse_force(iters: int) -> void:
	for _i in iters:
		_image.set_data(_img_w, _img_h, false, Image.FORMAT_RGBA8, _img_data)
		_sink += _image.get_data().size()


# ── Audio interleave ───────────────────────────────────────────────────
func _case_audio() -> void:
	_audio.resize(2048 * 2)
	_audio.fill(0.1)
	_record("audio_interleave", 1000, Callable(self, "_audio_interleave"))


func _audio_interleave(iters: int) -> void:
	for _i in iters:
		var buffer := PackedVector2Array()
		buffer.resize(2048)
		for f in 2048:
			buffer[f] = Vector2(_audio[f * 2], _audio[f * 2 + 1])
		_sink += buffer.size()


# ── NodePath lookup vs a cached reference ──────────────────────────────
func _case_node_path() -> void:
	_host = Node.new()
	for i in 100:
		var child := Node.new()
		child.name = "n%d" % i
		_host.add_child(child)
	_cached_node = _host.get_node_or_null(NodePath("n50"))
	_record("node_path_lookup", 10000, Callable(self, "_node_path_lookup"))
	_record("node_cached", 10000, Callable(self, "_node_cached"))
	_host.free()


func _node_path_lookup(iters: int) -> void:
	for _i in iters:
		if _host.get_node_or_null(NodePath("n50")) != null:
			_sink += 1


func _node_cached(iters: int) -> void:
	for _i in iters:
		if _cached_node != null:
			_sink += 1
