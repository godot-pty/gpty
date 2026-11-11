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


## The picker wears the app's frame for the reason a modal does (the engine's
## band is stock grey), but its layout is the engine's: the header is inserted at
## the top of the picker's own column so nothing of it moves.
func test_the_picker_takes_the_apps_own_frame():
	var dialog := AppDialog.picker(_host, "Working directory", FileDialog.FILE_MODE_OPEN_DIR)
	assert_true(dialog is FileDialog)
	assert_true(dialog.borderless, "no engine title band")
	assert_false(dialog.get_label().visible, "the engine label would be a second title")
	assert_eq(dialog.file_mode, FileDialog.FILE_MODE_OPEN_DIR, "the site's mode is kept")
	assert_eq(dialog.title, "Working directory")

	var column: VBoxContainer = null
	for child in dialog.get_children(true):
		if child is VBoxContainer:
			column = child
	assert_not_null(column, "the picker builds its own column")
	var header := column.get_child(0) as HBoxContainer
	assert_not_null(header, "the header is the column's first child")
	assert_eq(str(header.name), AppDialog.HEADER_NAME)

	var heading := header.get_node_or_null(NodePath(AppDialog.TITLE_NAME)) as Label
	assert_not_null(heading, "the header carries the title")
	assert_eq(heading.text, "Working directory")
	var close := header.get_node_or_null(NodePath(AppDialog.CLOSE_NAME)) as Button
	assert_not_null(close, "the header carries a close control")
	assert_eq(Icons.glyph(close), Icons.CLOSE)
	assert_eq(close.accessibility_name, "Close")

	# Inserted, not wrapped: the picker's own path field is still in the column
	# and is not a child of the header.
	var fields := column.find_children("*", "LineEdit", true, false)
	assert_gt(fields.size(), 0, "the picker's path field is untouched")
	assert_false(header.is_ancestor_of(fields[0]),
		"the header sits above the picker's controls, it does not contain them")


func test_the_picker_header_close_takes_the_engines_cancel_path():
	var dialog := AppDialog.picker(_host, "Font")
	watch_signals(dialog)
	var header := dialog.find_child(AppDialog.HEADER_NAME, true, false)
	var close := header.get_node(AppDialog.CLOSE_NAME) as Button
	close.pressed.emit()
	assert_signal_emitted(dialog, "canceled",
		"the site's `canceled` -> `queue_free` runs exactly as for the Cancel button")


func test_the_picker_header_is_inserted_once_across_a_popup():
	var dialog := AppDialog.picker(_host, "Font")
	dialog.popup_centered()
	await wait_frames(3)
	var headers := 0
	for child in dialog.get_children(true):
		if child is VBoxContainer:
			for grandchild in child.get_children():
				if str(grandchild.name) == AppDialog.HEADER_NAME:
					headers += 1
	assert_eq(headers, 1, "a second popup must not stack a second header")


# ── The window clamp ───────────────────────────────────────────────────

func test_the_modal_limit_is_a_share_of_the_window_less_a_margin():
	# 800x500 at the default 0.75 with a 24 px gap on each edge.
	assert_eq(AppDialog.modal_limit(Vector2i(800, 500)), Vector2i(552, 327))
	# A window smaller than the design size is floored, never negative: a 0x0
	# viewport (a dialog built before the first layout) must still answer.
	assert_eq(AppDialog.modal_limit(Vector2i(0, 0)), AppDialog.LIMIT_FLOOR)
	assert_eq(AppDialog.modal_limit(Vector2i(64, 64)), AppDialog.LIMIT_FLOOR)
	# A large window keeps the share, not an absolute cap.
	assert_eq(AppDialog.modal_limit(Vector2i(3840, 2160)), Vector2i(2832, 1572))
	# A site's own ratio is honoured (the cwd picker asks for 0.6).
	assert_eq(AppDialog.modal_limit(Vector2i(1000, 1000), 0.6), Vector2i(552, 552))

func test_a_modal_is_clamped_to_the_viewport():
	# `popup_centered()` sized the card from its content minimum alone, so a long
	# running-work list put "Close anyway" below the window's bottom edge. The
	# popup path sets the engine-level clamp to the same limit.
	var dialog := AppDialog.confirm(_host, "T")
	AppDialog.popup(dialog)
	assert_eq(dialog.max_size, AppDialog.modal_limit(AppDialog.available_size(dialog)),
		"the card may not grow past the window share it was centred in")
	dialog.queue_free()

func test_a_text_body_wraps_at_a_width_floor():
	# An autowrap Label with no width floor reports the height at the current
	# width before its first layout - one word per line - so the card's minimum
	# height was unbounded. The floor is the modal's own width.
	var dialog := AppDialog.confirm(_host, "T")
	var label := AppDialog.set_text(dialog, "one sentence long enough that an unbounded autowrap would shape it into a column")
	assert_eq(label.custom_minimum_size.x, AppDialog.text_width(AppDialog.available_size(dialog)))
	assert_gte(label.custom_minimum_size.x, AppDialog.LIMIT_FLOOR.x)
	assert_lte(label.custom_minimum_size.x, AppDialog.BODY_MIN_SIZE.x)
	dialog.queue_free()

func test_a_selectable_body_is_clamped_to_the_window():
	var dialog := AppDialog.confirm(_host, "T")
	var body := AppDialog.set_body(dialog, "review text", AppDialog.REVIEW_BODY_SIZE)
	var limit := AppDialog.modal_limit(AppDialog.available_size(dialog))
	assert_lte(body.custom_minimum_size.x, limit.x,
		"a 720 px body may not claim more than the window's share")
	assert_lte(body.custom_minimum_size.y, limit.y)
	dialog.queue_free()

func test_the_hidden_engine_label_cannot_widen_the_card():
	# The engine measures every Control child for the window's content minimum,
	# hidden or not, and `set_text`/`set_body` keep `dialog_text` for readers. A
	# long line in that hidden label would otherwise set the card's width again.
	var dialog := AppDialog.confirm(_host, "T")
	AppDialog.set_text(dialog, "x".repeat(400))
	assert_true(dialog.get_label().clip_text,
		"the hidden label must be able to shrink, not set a minimum width")
	dialog.queue_free()
