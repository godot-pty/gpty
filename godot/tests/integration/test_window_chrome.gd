extends GutTest
# WindowChrome — the titlebar's maximize control.
#
# The glyph is drawn by a child Label, so the button's own `text` is empty. The
# switch used to compare `max_btn.text` against the glyph constants, which could
# never match: the control said "maximize" in fullscreen forever (row
# *Window controls never swap maximize/restore*). These read the mode back off
# the control, and assert the bar's buttons draw through the shared treatment.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control


func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_window_mode = 0


func after_each():
	SettingsManager.cfg_window_mode = 0
	SettingsManager.cfg_window_opacity = SettingsManager.OPACITY_DEFAULT
	WindowChrome.force_transparency = -1
	get_window().transparent = false
	get_window().transparent_bg = false
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()


func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1000, 700)
	return ws


func _controls(ws: Control) -> Dictionary:
	var bar: Control = ws._chrome.titlebar
	assert_not_null(bar, "the chrome builds a titlebar")
	return {
		"min": bar.get_node_or_null("WinControls/Minimize"),
		"max": bar.get_node_or_null("WinControls/Maximize"),
		"close": bar.get_node_or_null("WinControls/Close"),
	}


func test_the_maximize_control_swaps_glyph_and_name_with_the_mode():
	var ws = await _make_workspace()
	var chrome: WindowChrome = ws._chrome
	var max_btn: Button = _controls(ws)["max"]
	assert_not_null(max_btn, "the maximize control is named in the bar")

	SettingsManager.cfg_window_mode = 1
	chrome._sync_max_button()
	assert_eq(Icons.glyph(max_btn), Icons.MAXIMIZE_WIN, "windowed offers maximize")
	assert_eq(max_btn.accessibility_name, "Maximize window")

	SettingsManager.cfg_window_mode = 2
	chrome._sync_max_button()
	assert_eq(Icons.glyph(max_btn), Icons.RESTORE_WIN,
		"fullscreen offers restore, not a second maximize")
	assert_eq(max_btn.accessibility_name, "Restore window",
		"the name moves with the glyph: the button acts as what it says")

	SettingsManager.cfg_window_mode = 0
	chrome._sync_max_button()
	assert_eq(Icons.glyph(max_btn), Icons.MAXIMIZE_WIN, "back to a decorated window")
	assert_eq(max_btn.accessibility_name, "Maximize window")


func test_apply_mode_drives_the_switch():
	var ws = await _make_workspace()
	var max_btn: Button = _controls(ws)["max"]
	SettingsManager.cfg_window_mode = 2
	ws._chrome.apply_mode()
	assert_eq(Icons.glyph(max_btn), Icons.RESTORE_WIN,
		"every mode change goes through apply_mode")
	assert_eq(max_btn.accessibility_name, "Restore window")


func test_the_window_controls_draw_their_glyph_as_a_label():
	var ws = await _make_workspace()
	var buttons := _controls(ws)
	for key in ["min", "max", "close"]:
		var btn: Button = buttons[key]
		assert_not_null(btn, "the %s control is named in the bar" % key)
		assert_eq(btn.text, "",
			"nothing is composed into the exposed name for the %s control" % key)
		assert_ne(Icons.glyph(btn), "", "the %s control draws a glyph" % key)
		assert_eq(btn.custom_minimum_size.x, 36, "the bar's own target size wins")

# ── Window opacity ─────────────────────────────────────────────────────

## A stored value outside the picker's range is clamped before it reaches the
## alpha; an unsupported display server is always opaque.
func test_opacity_alpha_is_opaque_squarely():
	assert_almost_eq(WindowChrome.opacity_alpha(80, true), 0.8, 0.001)
	assert_eq(WindowChrome.opacity_alpha(80, false), 1.0,
		"a window that cannot be transparent stays opaque")
	assert_eq(WindowChrome.opacity_alpha(100, true), 1.0,
		"100 % is an opaque window")
	assert_almost_eq(WindowChrome.opacity_alpha(5, true), 0.4, 0.001,
		"a hand-edited value clamps to the floor")

func test_opacity_veils_the_whole_window():
	var ws = await _make_workspace()
	WindowChrome.force_transparency = 1
	SettingsManager.cfg_window_opacity = 80
	ws._chrome.apply_opacity()
	# The headless display server refuses `Window.transparent` (measured: the
	# property stays false even when set directly), so the viewport's
	# transparent background and the workspace's veil are the observable half
	# of the same branch, and the window flag is proven on a real display.
	assert_true(get_window().transparent_bg,
		"the viewport must clear to transparent for the desktop to show")
	assert_true(ws._opacity_veil.visible, "the opacity pass must be on")
	assert_eq((ws._opacity_veil.material as ShaderMaterial).get_shader_parameter("window_alpha"),
		0.8, "the veil must carry the setting's alpha")

func test_a_window_that_cannot_be_transparent_stays_opaque():
	var ws = await _make_workspace()
	WindowChrome.force_transparency = 0
	SettingsManager.cfg_window_opacity = 80
	ws._chrome.apply_opacity()
	assert_false(get_window().transparent_bg,
		"an unsupported display server must not even clear transparent")
	assert_false(ws._opacity_veil.visible, "the opacity pass must be off")

func test_100_percent_is_an_opaque_window():
	var ws = await _make_workspace()
	WindowChrome.force_transparency = 1
	SettingsManager.cfg_window_opacity = 100
	ws._chrome.apply_opacity()
	assert_false(get_window().transparent_bg, "an opaque window needs no alpha flag")
	assert_false(ws._opacity_veil.visible, "an opaque window pays for no opacity pass")
	assert_false(ws._opacity_copy.visible, "and no backbuffer copy")

func test_saving_the_opacity_reaches_the_window():
	var ws = await _make_workspace()
	WindowChrome.force_transparency = 1
	SettingsManager.cfg_window_opacity = 90
	SettingsManager.save_settings()
	assert_true(ws._opacity_veil.visible,
		"the settings_changed listener must turn the opacity pass on")
	assert_eq((ws._opacity_veil.material as ShaderMaterial).get_shader_parameter("window_alpha"),
		0.9, "the saved alpha must reach the veil")

## The veil must copy and overwrite above everything the app draws, including
## the toast overlay and the four workspace overlays (z 100), or a pane would
## be left out of the alpha. It must never take a click.
func test_the_opacity_veil_sits_above_every_surface():
	var ws = await _make_workspace()
	assert_not_null(ws._opacity_veil, "the workspace owns the opacity veil")
	assert_not_null(ws._opacity_copy, "the workspace owns the veil's backbuffer copy")
	assert_gt(ws._opacity_veil.z_index, 100, "above the toast and the overlays")
	assert_gt(ws._opacity_veil.z_index, ws._opacity_copy.z_index,
		"the copy must run before the veil samples it")
	assert_eq(ws._opacity_veil.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"the veil must never take a click from the pane grid")
	assert_false(ws._opacity_veil.visible, "a fresh window is opaque")

## With transparency on, the engine's clear colour is transparent: this rect
## is what keeps seams and the empty workspace at the app's own alpha.
func test_the_window_has_a_ground_rect_beneath_every_surface():
	var ws = await _make_workspace()
	var bg := ws.get_child(0) as ColorRect
	assert_not_null(bg, "the workspace must paint a ground before anything else")
	assert_eq(bg.name, "WindowBg")
	assert_eq(bg.color, UiPalette.active().BG, "the ground is the app background")
	assert_eq(bg.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"it must never take a click from the pane grid")

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.apply_appearance()
	assert_eq(bg.color, UiPalette.light().BG,
		"a palette switch must repaint the ground with the rest of the chrome")
