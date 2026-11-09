extends GutTest
# ToastOverlay — a toast is an opaque card, not bare ink over the terminal.
# Defends: the message has its own surface with padding, the level is a leading
# edge (not only the label's colour), and the text is published to assistive
# tech.

var _overlay: ToastOverlay

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	_overlay = ToastOverlay.new()
	_overlay.theme = UiTheme.build()
	add_child(_overlay)

func after_each():
	_overlay.free()
	MockAutoloads.teardown()

func _panel_of() -> PanelContainer:
	# The newest toast is the last panel child: a preempted toast is queue_free'd
	# but still a child until the frame ends.
	for i in range(_overlay.get_child_count() - 1, -1, -1):
		var c := _overlay.get_child(i)
		if c is PanelContainer:
			return c
	return null

func test_a_toast_is_an_opaque_padded_panel():
	ToastManager.info("Copied line 3")
	var panel := _panel_of()
	assert_not_null(panel, "a toast is a panel, not a bare Label")
	var box := panel.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(box)
	assert_eq(box.bg_color.a, 1.0, "the message must not read over the terminal's text")
	assert_gt(box.content_margin_top, 0.0, "the card has padding")
	var lbl := panel.get_child(0) as Label
	assert_eq(lbl.text, "Copied line 3")
	assert_eq(lbl.accessibility_name, "Copied line 3", "a screen reader gets the message")
	assert_eq(lbl.accessibility_live, A11y.LIVE_POLITE)

func test_the_level_is_a_leading_edge_not_only_ink():
	var p := UiPalette.active()
	ToastManager.warn("Careful")
	var warn_box := _panel_of().get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(warn_box.border_color, p.WARNING)
	assert_eq(warn_box.border_width_left, 3, "the level has a leading edge, not only ink")
	ToastManager.error("Broken")
	var err_box := _panel_of().get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(err_box.border_color, p.DANGER)
	assert_eq(err_box.border_width_left, 3)
