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
	_theme = UiTheme.build()

func test_panels_are_opaque():
	for type in ["Panel", "PanelContainer", "PopupPanel", "AcceptDialog", "GraphEdit", "Tree", "ItemList"]:
		var box := _theme.get_stylebox("panel", type) as StyleBoxFlat
		assert_not_null(box, "%s has a panel stylebox" % type)
		assert_eq(box.bg_color.a, 1.0, "%s panel is opaque" % type)

func test_the_chrome_panels_use_the_surface_token():
	for type in ["Panel", "PanelContainer", "PopupPanel", "AcceptDialog", "GraphEdit"]:
		var box := _theme.get_stylebox("panel", type) as StyleBoxFlat
		assert_eq(box.bg_color, UiTokens.SURFACE, "%s panel is the surface token" % type)

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
	assert_eq(_theme.get_color("font_color", "Label"), UiTokens.TEXT)
	assert_eq(_theme.get_color("font_color", "Button"), UiTokens.TEXT)
	assert_eq(_theme.get_color("font_placeholder_color", "LineEdit"), UiTokens.TEXT_MUTED)
	assert_eq(_theme.get_color("font_unselected_color", "TabBar"), UiTokens.TEXT_MUTED)

func test_a_confirmation_dialog_resolves_the_accept_dialog_panel():
	# ConfirmationDialog defines no panel of its own; the class-chain fallback is
	# what keeps it from falling back to the engine's translucent grey.
	var dlg := ConfirmationDialog.new()
	dlg.theme = _theme
	add_child_autofree(dlg)
	await wait_frames(1)
	var box := dlg.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(box)
	assert_eq(box.bg_color, UiTokens.SURFACE)
	assert_eq(box.bg_color.a, 1.0)

func test_the_dialog_panel_carries_its_own_padding():
	# `AppDialog` makes its modals borderless (the engine's embedded frame is
	# painted from Godot's default theme, not this one), so the panel is the
	# whole surface: it must be opaque and pad the content itself.
	var box := _theme.get_stylebox("panel", "AcceptDialog") as StyleBoxFlat
	assert_not_null(box)
	assert_eq(box.bg_color, UiTokens.SURFACE)
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
