extends GutTest
# The UI scale setting: percent -> `content_scale_factor` -> the workspace.
#
# `content_scale_factor` is the mechanism, not a font multiplier: it scales the
# whole interface (layout space shrinks, the pixel grid stays), so a hard-coded
# `custom_minimum_size` grows with the type. Measured on 4.7.2 with the stretch
# mode disabled: a factor of 2.0 moved no layout coordinate and put the screen
# transform at x2.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _original_window_size := Vector2i.ZERO

## Pin the window to the size the assertions measure the cap against, and prove
## it took: a headless or developer window of any other size would move every
## expected number.
func _pin_window(size: Vector2i) -> void:
	get_window().size = size
	assert_eq(get_window().size, size,
		"the test window must take a size the cap can be measured against")

func before_each():
	_original_window_size = get_window().size
	MockAutoloads.setup()
	_pin_window(Vector2i(1920, 1080))
	SettingsManager.cfg_ui_scale = 100
	SettingsManager.apply_ui_scale()

func after_each():
	# Free while the mocks are active: `_exit_tree()` saves through them.
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	SettingsManager.cfg_ui_scale = 100
	SettingsManager.apply_ui_scale()
	get_window().size = _original_window_size
	MockAutoloads.teardown()

func test_the_factor_is_the_percentage():
	for pct in [100, 110, 125, 150, 175, 200]:
		SettingsManager.cfg_ui_scale = pct
		assert_almost_eq(SettingsManager.ui_scale_factor(), float(pct) / 100.0, 0.0001,
			"%d %% is %.2f" % [pct, float(pct) / 100.0])

func test_applying_sets_the_window_content_scale():
	SettingsManager.cfg_ui_scale = 150
	SettingsManager.apply_ui_scale()
	assert_almost_eq(get_window().content_scale_factor, 1.5, 0.0001)

func test_the_loader_clamps_a_hand_edited_value():
	# The floor is the 100 % layout: the setting exists to make the interface
	# bigger, and a value below it would lay the UI out smaller than any layout
	# was measured at.
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"ui_scale": 40})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_ui_scale, 100, "a value under 100 is clamped up")
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"ui_scale": 900})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_ui_scale, 200, "the ceiling is the last preset")

func test_the_save_carries_the_scale():
	SettingsManager.cfg_ui_scale = 175
	SettingsManager.save_settings()
	assert_eq(MockAutoloads.get_store(SettingsManager.SETTINGS_FILE).get("ui_scale"), 175)

func test_the_workspace_applies_the_scale_and_the_theme():
	SettingsManager.cfg_ui_scale = 125
	_ws = WorkspaceScript.new()
	add_child(_ws)
	await get_tree().process_frame
	await get_tree().process_frame

	assert_almost_eq(get_window().content_scale_factor, 1.25, 0.0001,
		"the workspace's own settings pass applies the scale")
	assert_not_null(_ws.theme, "the workspace carries the one Theme")
	var panel := _ws.theme.get_stylebox("panel", "Panel") as StyleBoxFlat
	assert_eq(panel.bg_color, UiPalette.active().SURFACE, "the theme is UiTheme.build()")
	# The content area's clear colour is the background token, not the engine's
	# default grey (that is what an empty workspace used to show).
	assert_eq(RenderingServer.get_default_clear_color(), UiPalette.active().BG)

	# Wait out the deferred concept push so it cannot resume after the free.
	await get_tree().create_timer(2.1).timeout

# ── The window's cap on the applied scale ──────────────────────────────
#
# `content_scale_factor` divides the layout space, so a request the window
# cannot hold must fall back instead of laying the chrome out under its own
# minimums.

func test_the_ceiling_is_the_layout_floor():
	# 800 / 560 = 1.42: the 125 % step fits the 640x400 layout an 800x500
	# window shows, which is what the small-window work unlocked.
	assert_eq(UiTokens.ui_scale_ceiling(Vector2i(800, 500)), 142)
	# Height binds at 1920x1080: 1080 / 340 = 3.17.
	assert_eq(UiTokens.ui_scale_ceiling(Vector2i(1920, 1080)), 317)
	# Height binds here too: 760 / 340 = 2.23, so 200 % fits and 250 % does not.
	assert_eq(UiTokens.ui_scale_ceiling(Vector2i(1280, 760)), 223)
	assert_eq(UiTokens.ui_scale_ceiling(Vector2i.ZERO), -1,
		"an unmeasurable window caps nothing")

func test_the_cap_falls_back_to_100_percent():
	assert_eq(SettingsManager.capped_ui_scale_percent(125, Vector2i(800, 500)), 125,
		"the 800x500 layout holds 125 % now that the surfaces clamp to the window")
	assert_eq(SettingsManager.capped_ui_scale_percent(125, Vector2i(560, 340)), 100,
		"the floor itself holds 100 % and no more")
	assert_eq(SettingsManager.capped_ui_scale_percent(200, Vector2i(560, 340)), 100)
	assert_eq(SettingsManager.capped_ui_scale_percent(125, Vector2i(1920, 1080)), 125)
	assert_eq(SettingsManager.capped_ui_scale_percent(200, Vector2i(1920, 1080)), 200,
		"the tallest preset the window can show")
	assert_eq(SettingsManager.capped_ui_scale_percent(200, Vector2i.ZERO), 200,
		"an unmeasurable window keeps the request")
	assert_eq(SettingsManager.capped_ui_scale_percent(40, Vector2i(1920, 1080)), 100,
		"the floor is 100 %, never a smaller interface")

func test_applying_caps_the_scale_at_the_window():
	_pin_window(Vector2i(560, 340))
	SettingsManager.cfg_ui_scale = 125
	SettingsManager.apply_ui_scale()
	assert_eq(SettingsManager.applied_ui_scale_percent(), 100)
	assert_almost_eq(get_window().content_scale_factor, 1.0, 0.0001,
		"the window gets 100 %, not the 125 % the setting holds")
	assert_almost_eq(SettingsManager.ui_scale_factor(), 1.25, 0.0001,
		"the request itself is untouched")
	assert_eq(SettingsManager.cfg_ui_scale, 125, "the setting keeps what the user chose")

func test_a_resize_moves_the_cap_with_the_window():
	_pin_window(Vector2i(1920, 1080))
	SettingsManager.cfg_ui_scale = 125
	SettingsManager.apply_ui_scale()
	assert_eq(SettingsManager.applied_ui_scale_percent(), 125)
	get_window().size = Vector2i(560, 340)
	await get_tree().process_frame
	assert_eq(SettingsManager.applied_ui_scale_percent(), 100,
		"the resize hook re-applies the cap with no settings change")
	assert_almost_eq(get_window().content_scale_factor, 1.0, 0.0001)
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	assert_almost_eq(get_window().content_scale_factor, 1.25, 0.0001,
		"growing the window restores the user's scale")
