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

func before_each():
	MockAutoloads.setup()
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
	assert_eq(panel.bg_color, UiTokens.SURFACE, "the theme is UiTheme.build()")
	# The content area's clear colour is the background token, not the engine's
	# default grey (that is what an empty workspace used to show).
	assert_eq(RenderingServer.get_default_clear_color(), UiTokens.BG)

	# Wait out the deferred concept push so it cannot resume after the free.
	await get_tree().create_timer(2.1).timeout
