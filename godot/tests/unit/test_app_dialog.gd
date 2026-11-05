extends GutTest
# AppDialog — the one modal builder.
#
# Two properties are pinned here. The buttons land together at the right edge:
# Godot wraps each one in a `SIZE_EXPAND_FILL` spacer, which spread Restore and
# Cancel ~290 px apart in a 1046 px dialog (measured 2026-11-04). And the text a
# user must read lives in a selectable body, so a pinned plugin revision can be
# copied out of the install review.

var _host: Control

func before_each():
	_host = Control.new()
	_host.size = Vector2(900, 600)
	add_child_autofree(_host)

func test_confirm_adds_a_confirmation_dialog_to_the_parent():
	var dialog := AppDialog.confirm(_host, "Title", "Go", "Cancel")
	assert_true(dialog is ConfirmationDialog)
	assert_eq(dialog.get_parent(), _host)
	assert_eq(dialog.title, "Title")
	assert_eq(dialog.ok_button_text, "Go")
	assert_eq(dialog.cancel_button_text, "Cancel")

func test_alert_is_one_button_and_parented():
	var dialog := AppDialog.alert(_host, "Notice", "Fine")
	assert_true(dialog is AcceptDialog)
	assert_false(dialog is ConfirmationDialog, "an alert has no cancel button")
	assert_eq(dialog.get_parent(), _host)
	assert_eq(dialog.ok_button_text, "Fine")

func test_the_buttons_group_at_the_right_edge():
	var dialog := AppDialog.confirm(_host, "Grouping", "Second", "First")
	dialog.add_button("Third", false, "extra")
	dialog.popup_centered()
	await wait_frames(3)

	var row := dialog.get_ok_button().get_parent() as HBoxContainer
	var buttons: Array[Button] = []
	for child in row.get_children():
		if child is Button:
			buttons.append(child)
	assert_eq(buttons.size(), 3, "every button is in the row")

	# Adjacent: one spacer (0 px) plus the row's two separations.
	var sep := float(row.get_theme_constant("separation"))
	assert_gt(sep, 0.0, "the row has a separation between its children")
	for i in range(1, buttons.size()):
		var gap := buttons[i].get_global_rect().position.x - buttons[i - 1].get_global_rect().end.x
		assert_lte(gap, 2 * sep + 1,
			"buttons %d and %d sit together (gap %.1f)" % [i - 1, i, gap])

	# At the right: only the row's trailing separation is left after the last
	# button, so the group is flush with the content edge.
	var trailing := row.get_global_rect().end.x - buttons[buttons.size() - 1].get_global_rect().end.x
	assert_almost_eq(trailing, sep, 2.0,
		"the group ends at the right edge (%.1f px left)" % trailing)

func test_the_first_spacer_keeps_its_stretch_and_the_rest_stop():
	var dialog := AppDialog.confirm(_host)
	dialog.popup_centered()
	await wait_frames(3)
	var row := dialog.get_ok_button().get_parent() as HBoxContainer
	var spacers: Array[Control] = []
	for child in row.get_children():
		if not (child is BaseButton):
			spacers.append(child as Control)
	assert_gt(spacers.size(), 1)
	assert_eq(spacers[0].size_flags_horizontal, Control.SIZE_EXPAND_FILL,
		"the leading spacer absorbs the slack")
	for i in range(1, spacers.size()):
		assert_eq(spacers[i].size_flags_horizontal, Control.SIZE_SHRINK_BEGIN,
			"trailing spacer %d does not push buttons apart" % i)

func test_a_button_added_after_construction_is_grouped_too():
	# The hook runs on `about_to_popup`, so a caller's own `add_button` — which
	# every trust dialog uses for its details toggle — is covered.
	var dialog := AppDialog.confirm(_host)
	var extra := dialog.add_button("Details", false, "details")
	dialog.popup_centered()
	await wait_frames(3)
	assert_eq(extra.size_flags_horizontal, Control.SIZE_SHRINK_BEGIN)

func test_set_body_makes_the_text_selectable():
	var dialog := AppDialog.confirm(_host)
	var body := AppDialog.set_body(dialog, "revision abc123\n/bin/bash -lc 'echo hi'")
	assert_eq(body.name, AppDialog.TEXT_NAME)
	assert_false(body.editable, "the body is read-only")
	assert_eq(body.text, "revision abc123\n/bin/bash -lc 'echo hi'")
	assert_eq(AppDialog.body_of(dialog), body.text)
	assert_false(dialog.get_label().visible, "the engine label stays hidden")

func test_a_bracketed_path_is_not_markup():
	# Review text carries paths in brackets. A RichTextLabel would take `[b]` as
	# markup; the body is a TextEdit, so the text is exactly what was set.
	var text := "spawn: /opt/[b]in/tool"
	var dialog := AppDialog.confirm(_host)
	AppDialog.set_body(dialog, text)
	assert_eq(AppDialog.body_of(dialog), text)

func test_body_of_falls_back_to_the_engine_label():
	var dialog := AppDialog.confirm(_host)
	dialog.dialog_text = "plain text"
	assert_eq(AppDialog.body_of(dialog), "plain text")

func test_the_title_and_the_text_live_inside_the_panel():
	# The engine's embedded frame cannot be coloured from this theme, so the
	# modal is borderless and carries its own header inside the panel it owns.
	var dialog := AppDialog.confirm(_host, "Headed")
	assert_true(dialog.borderless, "no engine frame")
	var heading := AppDialog.content(dialog).get_node_or_null(AppDialog.TITLE_NAME) as Label
	assert_not_null(heading, "the content column starts with the title")
	assert_eq(heading.text, "Headed")
	assert_eq(dialog.title, "Headed", "the window's own title field agrees")
	assert_false(dialog.get_label().visible, "the engine label is hidden")

func test_set_text_renders_one_wrapping_label():
	var dialog := AppDialog.confirm(_host, "T")
	AppDialog.set_text(dialog, "a long sentence that has to wrap instead of clipping")
	var label := AppDialog.content(dialog).get_node_or_null(AppDialog.TEXT_NAME) as Label
	assert_not_null(label)
	assert_ne(label.autowrap_mode, TextServer.AUTOWRAP_OFF)
	assert_eq(AppDialog.body_of(dialog), label.text)
	assert_false(dialog.get_label().visible, "the engine label does not render it twice")
