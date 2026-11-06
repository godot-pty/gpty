extends GutTest
# UiTheme — the one Theme the app runs on.
#
# What matters is that the theme is *complete*: every surface a control can be
# seen through is opaque, the type scale is the tokens' rather than the engine's
# 16 px, and a type that inherits another type's items (a ConfirmationDialog
# from AcceptDialog, an OptionButton from Button) resolves them without a second
# definition. The CheckBox case is a regression guard: it inherits Button's items
# through the class chain, so a themed Button would otherwise put a filled box
# behind every checkbox.

var _theme: Theme

func before_each():
	UiPalette.use(UiPalette.MODE_DARK)
	_theme = UiTheme.build()

func after_each():
	# The palette is process-global; a test that left it light would re-theme
	# every later suite.
	UiPalette.use(UiPalette.MODE_DARK)

func test_panels_are_opaque():
	for type in ["Panel", "PanelContainer", "PopupPanel", "AcceptDialog", "GraphEdit", "Tree", "ItemList"]:
		var box := _theme.get_stylebox("panel", type) as StyleBoxFlat
		assert_not_null(box, "%s has a panel stylebox" % type)
		assert_eq(box.bg_color.a, 1.0, "%s panel is opaque" % type)

func test_the_chrome_panels_use_the_surface_token():
	for type in ["Panel", "PanelContainer", "PopupPanel", "AcceptDialog", "GraphEdit"]:
		var box := _theme.get_stylebox("panel", type) as StyleBoxFlat
		assert_eq(box.bg_color, UiPalette.active().SURFACE, "%s panel is the surface token" % type)

func test_buttons_are_opaque_and_padded():
	# A StyleBoxFlat with no content margin collapses the button onto its label;
	# the stock box carried 4 px on every side.
	for state in ["normal", "hover", "pressed", "disabled"]:
		var box := _theme.get_stylebox(state, "Button") as StyleBoxFlat
		assert_not_null(box, "Button/%s is a StyleBoxFlat" % state)
		assert_eq(box.bg_color.a, 1.0, "Button/%s is opaque" % state)
		assert_eq(box.content_margin_left, UiTokens.SPACE_SM, "Button/%s keeps its padding" % state)
		assert_eq(box.content_margin_top, UiTokens.SPACE_SM, "Button/%s keeps its padding" % state)

func test_checkboxes_keep_their_glyph_not_a_button_background():
	for type in ["CheckBox", "CheckButton"]:
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			var box := _theme.get_stylebox(state, type)
			assert_true(box is StyleBoxEmpty, "%s/%s stays empty" % [type, state])

func test_option_button_reserves_room_for_its_arrow():
	var box := _theme.get_stylebox("normal", "OptionButton") as StyleBoxFlat
	assert_eq(box.content_margin_right, UiTokens.SPACE_LG, "the arrow has its room")
	assert_eq(box.content_margin_left, UiTokens.SPACE_SM)

func test_the_type_scale_comes_from_the_tokens():
	assert_eq(_theme.default_font_size, UiTokens.FS_SMALL)
	assert_eq(_theme.get_font_size("font_size", "Label"), UiTokens.FS_SMALL)
	assert_eq(_theme.get_font_size("font_size", "Button"), UiTokens.FS_SMALL)
	assert_eq(_theme.get_font_size("font_size", "LineEdit"), UiTokens.FS_SMALL)
	assert_eq(_theme.get_font_size("normal_font_size", "RichTextLabel"), UiTokens.FS_SMALL)
	assert_eq(_theme.get_font_size("font_size", "TabBar"), UiTokens.FS_CONTROL)
	assert_eq(_theme.get_font_size("title_font_size", "Window"), UiTokens.FS_CONTROL)

func test_text_colours_come_from_the_tokens():
	assert_eq(_theme.get_color("font_color", "Label"), UiPalette.active().TEXT)
	assert_eq(_theme.get_color("font_color", "Button"), UiPalette.active().TEXT)
	assert_eq(_theme.get_color("font_placeholder_color", "LineEdit"), UiPalette.active().TEXT_MUTED)
	assert_eq(_theme.get_color("font_unselected_color", "TabBar"), UiPalette.active().TEXT_MUTED)

func test_a_confirmation_dialog_resolves_the_accept_dialog_panel():
	# ConfirmationDialog defines no panel of its own; the class-chain fallback is
	# what keeps it from falling back to the engine's translucent grey.
	var dlg := ConfirmationDialog.new()
	dlg.theme = _theme
	add_child_autofree(dlg)
	await wait_frames(1)
	var box := dlg.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(box)
	assert_eq(box.bg_color, UiPalette.active().SURFACE)
	assert_eq(box.bg_color.a, 1.0)

func test_the_dialog_panel_carries_its_own_padding():
	# `AppDialog` makes its modals borderless (the engine's embedded frame is
	# painted from Godot's default theme, not this one), so the panel is the
	# whole surface: it must be opaque and pad the content itself.
	var box := _theme.get_stylebox("panel", "AcceptDialog") as StyleBoxFlat
	assert_not_null(box)
	assert_eq(box.bg_color, UiPalette.active().SURFACE)
	assert_eq(box.bg_color.a, 1.0)
	for side in ["content_margin_left", "content_margin_top", "content_margin_right", "content_margin_bottom"]:
		assert_eq(box.get(side), UiTokens.SPACE_XXL, "the panel pads %s" % side)

func test_margins_sets_all_four_sides():
	var mc := MarginContainer.new()
	add_child_autofree(mc)
	UiTheme.margins(mc, UiTokens.SPACE_XXL)
	for side in ["left", "top", "right", "bottom"]:
		assert_eq(mc.get_theme_constant("margin_%s" % side), UiTokens.SPACE_XXL,
			"margin_%s" % side)

## The whole point of the split: the same builder, a second colour set, so a
## palette switch is a rebuild and not a second theme.
func test_the_light_set_builds_a_light_theme():
	UiPalette.use(UiPalette.MODE_LIGHT)
	_theme = UiTheme.build()
	var panel := _theme.get_stylebox("panel", "Panel") as StyleBoxFlat
	assert_eq(panel.bg_color, UiPalette.light().SURFACE)
	assert_eq(_theme.get_color("font_color", "Label"), UiPalette.light().TEXT)
	var button := _theme.get_stylebox("normal", "Button") as StyleBoxFlat
	assert_eq(button.bg_color, UiPalette.light().SURFACE_RAISED)
	assert_eq(_theme.get_stylebox("panel", "TabContainer").bg_color, UiPalette.light().SURFACE)

## A role is how a widget asks for a colour it does not own: the theme answers,
## so a palette switch reaches it without the widget holding a token.
func test_role_variations_resolve():
	for role in [[UiTheme.MUTED_LABEL, "Label", _theme.get_color("font_color", UiTheme.MUTED_LABEL)],
			[UiTheme.DANGER_LABEL, "Label", _theme.get_color("font_color", UiTheme.DANGER_LABEL)],
			[UiTheme.WARNING_LABEL, "Label", _theme.get_color("font_color", UiTheme.WARNING_LABEL)]]:
		assert_eq(_theme.get_type_variation_base(role[0]), role[1],
			"%s is a %s variation" % [role[0], role[1]])
	assert_eq(_theme.get_color("font_color", UiTheme.MUTED_LABEL), UiPalette.dark().TEXT_MUTED)
	assert_eq(_theme.get_color("font_color", UiTheme.DANGER_LABEL), UiPalette.dark().DANGER)
	assert_eq(_theme.get_color("font_color", UiTheme.WARNING_LABEL), UiPalette.dark().WARNING)
	assert_eq(_theme.get_type_variation_base(UiTheme.ACCENT_BUTTON), "Button")
	assert_eq(_theme.get_color("font_color", UiTheme.ACCENT_BUTTON), UiPalette.dark().ACCENT)
	assert_eq(_theme.get_color("font_pressed_color", UiTheme.ACCENT_BUTTON), UiPalette.dark().ACCENT)

## And the resolution is live, not just the table: a Label that names the role
## reads the role's colour through its ancestor's theme.
func test_a_role_label_reads_the_themes_colour():
	var host := Control.new()
	host.theme = _theme
	add_child_autofree(host)
	var lbl := Label.new()
	lbl.theme_type_variation = UiTheme.MUTED_LABEL
	host.add_child(lbl)
	await wait_frames(1)
	assert_eq(lbl.get_theme_color("font_color"), UiPalette.dark().TEXT_MUTED)


## The icon-only treatment: nothing at rest, an accent wash under the pointer,
## and the same 1 px accent ring an input gets. Text buttons keep the filled
## base, so one variation cannot leak into the other.
func test_the_icon_button_variation_is_flat_until_pointed_at():
	assert_eq(_theme.get_type_variation_base(UiTheme.ICON_BUTTON), "Button")
	assert_true(_theme.get_stylebox("normal", UiTheme.ICON_BUTTON) is StyleBoxEmpty,
		"an icon button draws no box at rest")
	assert_true(_theme.get_stylebox("disabled", UiTheme.ICON_BUTTON) is StyleBoxEmpty)
	for state in ["hover", "pressed"]:
		var box := _theme.get_stylebox(state, UiTheme.ICON_BUTTON) as StyleBoxFlat
		assert_not_null(box, "%s is a fill, not an empty box" % state)
		assert_gt(box.bg_color.a, 0.0, "%s washes the glyph's background" % state)
		assert_eq(box.bg_color.r, UiPalette.dark().ACCENT.r, "%s is the accent" % state)
	var focus := _theme.get_stylebox("focus", UiTheme.ICON_BUTTON) as StyleBoxFlat
	assert_not_null(focus, "the keyboard ring is an outline, not a fill")
	assert_gt(focus.border_width_left, 0, "the ring draws a border")
	assert_eq(focus.border_color, UiPalette.dark().ACCENT)
	assert_eq(_theme.get_stylebox("normal", "Button").bg_color.r,
		UiPalette.dark().SURFACE_RAISED.r, "a text button keeps the filled base")


func test_the_accent_label_role_resolves_to_the_accent():
	assert_eq(_theme.get_type_variation_base(UiTheme.ACCENT_LABEL), "Label")
	assert_eq(_theme.get_color("font_color", UiTheme.ACCENT_LABEL), UiPalette.dark().ACCENT)
