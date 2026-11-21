extends SceneTree
# Frame-cost harness for the two terminal effect shaders (`UiEffects.AMBIENT`).
#
# One full-size ColorRect in an offscreen SubViewport, redrawn every measured
# frame. The run measures a plain rect first (the baseline), then the selected
# shader on the same rect, so one invocation prints both numbers the effect
# table records:
#
#   godot --path godot --disable-vsync -s res://tests/bench/effect_bench.gd
#
#   BENCH_EFFECT   crt|grain|none   (default crt; none prints the baseline only)
#   BENCH_SIZE     WxH              (default 3840x2160 - at 1080p the harness's
#                                    own frame floor can hide a cheap shader;
#                                    docs/content/docs/agents/testing.md, "A GPU
#                                    shader effect's cost is a frame time")
#   BENCH_FRAMES   measured frames  (default 120)
#   BENCH_WARMUP   warmup frames    (default 20)
#
# A real display driver is required; under `--headless` there is no redraw pass.
# The shaders are preloaded by path because a `-s` entry point compiles before
# the project's autoloads exist, and naming `UiEffects` would pull
# `SettingsManager` in and fail to load. These are the same two files the table
# preloads; `test_ui_effects.gd` keeps the table and the pane schema aligned.

const SHADERS := {
	"crt": preload("res://shaders/effects/crt.gdshader"),
	"grain": preload("res://shaders/effects/grain.gdshader"),
}
## A terminal ground, so the measurement is the shader the UI runs.
const GROUND := Color("#202128")

var _viewport: SubViewport
var _rect: ColorRect

func _initialize() -> void:
	_run()

func _run():
	var effect := OS.get_environment("BENCH_EFFECT")
	if effect == "":
		effect = "crt"
	if effect != "none" and not SHADERS.has(effect):
		push_error("effect_bench: unknown BENCH_EFFECT=%s (crt|grain|none)" % effect)
		quit(2)
		return
	var size := _size_from_env()
	var frames := _env_int("BENCH_FRAMES", 120)
	var warmup := _env_int("BENCH_WARMUP", 20)

	_viewport = SubViewport.new()
	_viewport.size = size
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_rect = ColorRect.new()
	_rect.color = GROUND
	_rect.size = Vector2(size)
	_viewport.add_child(_rect)
	await process_frame
	await RenderingServer.frame_post_draw

	var baseline_us := await _measure(warmup, frames)
	var effect_us := 0.0
	if effect != "none":
		var material := ShaderMaterial.new()
		material.shader = SHADERS[effect]
		material.set_shader_parameter("strength", 1.0)
		# Half the pane's cell height is the real cadence; a fixed 3 px period
		# keeps the bench independent of a font it does not load.
		material.set_shader_parameter("rows", float(size.y) / 3.0)
		material.set_shader_parameter("quad_px", Vector2(size))
		_rect.material = material
		effect_us = await _measure(warmup, frames)

	print("effect=%s size=%dx%d frames=%d baseline_us=%.0f effect_us=%.0f delta_us=%.0f" % [
		effect, size.x, size.y, frames, baseline_us, effect_us,
		maxf(effect_us - baseline_us, 0.0)])
	quit()

## Median frame interval over `frames` after `warmup`, in microseconds. The
## rect is re-recorded every frame; the frame interval is what the compositor
## sees under `--disable-vsync`.
func _measure(warmup: int, frames: int) -> float:
	var samples := PackedFloat64Array()
	for i in warmup + frames:
		_rect.queue_redraw()
		var before := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		if i >= warmup:
			samples.append(float(Time.get_ticks_usec() - before))
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]

func _size_from_env() -> Vector2i:
	var raw := OS.get_environment("BENCH_SIZE")
	if raw == "":
		return Vector2i(3840, 2160)
	var parts := raw.split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		push_warning("effect_bench: BENCH_SIZE=%s is not WxH; using 3840x2160" % raw)
		return Vector2i(3840, 2160)
	return Vector2i(maxi(1, int(parts[0])), maxi(1, int(parts[1])))

func _env_int(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name)
	if raw == "" or not raw.is_valid_int():
		return fallback
	return maxi(0, int(raw))
