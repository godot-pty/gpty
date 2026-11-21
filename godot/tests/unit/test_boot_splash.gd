extends GutTest
# The launch frame is drawn by the engine before any script or autoload, so it
# cannot read the user's palette or settings: project.godot pins one committed
# picture and its background. These tests stop the picture, the colour it sits
# on, and the way the engine scales it from drifting apart.

const PATH := "res://assets/boot_splash.png"
const SIZE := Vector2i(3840, 2160)

func _surface() -> Color:
	return UiPalette.DARK["SURFACE"]

func test_the_launch_frame_is_configured():
	assert_eq(ProjectSettings.get_setting("application/boot_splash/image"), PATH,
		"the launch frame is the committed asset")
	assert_eq(ProjectSettings.get_setting("application/boot_splash/stretch_mode"), 2,
		"Keep Width (2 in 4.7's hint) preserves the frame's aspect without clipping a 4:3 window")
	var show: bool = ProjectSettings.get_setting("application/boot_splash/show_image")
	assert_true(show, "the frame is drawn")
	assert_eq(ProjectSettings.get_setting("application/boot_splash/minimum_display_time"), 0,
		"a fast launch is not held on the frame")
	var bg: Color = ProjectSettings.get_setting("application/boot_splash/bg_color")
	assert_eq(bg.to_html(false), _surface().to_html(false),
		"the engine's letterbox is the art's own edge colour")

func test_the_launch_frame_is_a_brand_surface():
	var tex := load(PATH) as Texture2D
	assert_not_null(tex, "the boot splash texture loads")
	if tex == null:
		return
	assert_eq(tex.get_width(), SIZE.x, "the frame is 2x a 1920 px window")
	assert_eq(tex.get_height(), SIZE.y)
	var img := tex.get_image()
	assert_not_null(img, "the texture carries its image")
	if img == null:
		return
	if img.is_compressed():
		var err := img.decompress()
		assert_eq(err, OK, "the frame decompresses for sampling")
		if err != OK:
			return
	var surface := _surface()
	for p in [Vector2i(0, 0), Vector2i(SIZE.x - 1, 0),
			Vector2i(0, SIZE.y - 1), Vector2i(SIZE.x - 1, SIZE.y - 1)]:
		assert_eq(img.get_pixelv(p).to_html(false), surface.to_html(false),
			"corner %s is the surface token, so every crop/letterbox edge is seamless" % p)

	# The mark is the icon's blue line art (its grey plate was dropped); the
	# wordmark is the light TEXT token. Both sit in the central safe area that
	# Keep Width can never crop.
	var found_mark := false
	for y in range(600, 1241, 8):
		for x in range(1600, 2241, 8):
			var c := img.get_pixel(x, y)
			if c.b - max(c.r, c.g) > 0.2:
				found_mark = true
				break
		if found_mark:
			break
	assert_true(found_mark, "the central mark's accent stroke is drawn")

	var found_wordmark := false
	for y in range(1300, 1641, 8):
		for x in range(1600, 2241, 8):
			var c := img.get_pixel(x, y)
			if c.r > 0.8 and c.g > 0.8 and c.b > 0.8:
				found_wordmark = true
				break
		if found_wordmark:
			break
	assert_true(found_wordmark, "the gPTY wordmark is drawn")

	var bytes := FileAccess.get_file_as_bytes(PATH)
	assert_lt(bytes.size(), 512 * 1024,
		"the frame is embedded in the binary; keep it under half a MiB")
