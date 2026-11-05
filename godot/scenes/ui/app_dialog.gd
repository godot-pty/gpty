class_name AppDialog
## The one place a modal is built, so every dialog in the app looks the same,
## groups its buttons the same way, and carries its text where a user can read
## and copy it.
##
## Three defects this closes. Godot spreads a dialog's buttons across the full
## width by wrapping each one in a `SIZE_EXPAND_FILL` spacer — measured on
## 4.7.2, Restore and Cancel sat ~290 px apart in a 1046 px dialog. The engine's
## `dialog_text` is a plain label, so a pinned plugin revision or a spawn plan
## could be read but never selected and copied. And an embedded `Window`'s title
## band is painted from Godot's own default theme — a `Theme` on a Control
## ancestor cannot reach it (measured 2026-11-04: a magenta
## `Window/embedded_border` painted nothing and the band showed the pane behind),
## so the band was stock grey at best and transparent at worst. The dialog is
## therefore borderless and draws its own header inside the panel that this
## module controls.

## The selectable body's floor: wide enough for a spawn plan or a revision hash
## on one line, tall enough for a short trust list. A caller with more to show
## passes its own size (`REVIEW_BODY_SIZE`).
const BODY_MIN_SIZE := Vector2(720, 180)

## The plugin install review's size: a revision, a version, three command lists
## and two declared hooks, and it is the dialog a user is asked to approve.
const REVIEW_BODY_SIZE := Vector2(720, 360)

## Node names: `content` finds the layout, and a test can name both.
const LAYOUT_NAME := "Layout"
const TITLE_NAME := "DialogTitle"
const TEXT_NAME := "BodyText"

## A `ConfirmationDialog` added to `parent`. Empty strings leave the button
## labels alone, so a site can set them later.
static func confirm(parent: Node, title := "", ok_text := "", cancel_text := "") -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	if ok_text != "":
		dialog.ok_button_text = ok_text
	if cancel_text != "":
		dialog.cancel_button_text = cancel_text
	_adopt(parent, dialog, title)
	return dialog

## An `AcceptDialog` (one OK button) added to `parent`.
static func alert(parent: Node, title := "", ok_text := "") -> AcceptDialog:
	var dialog := AcceptDialog.new()
	if ok_text != "":
		dialog.ok_button_text = ok_text
	_adopt(parent, dialog, title)
	return dialog

## Where a site puts its own controls. The dialog lays every direct child out
## over the same rect, so there is exactly one container and one shape.
static func content(dialog: AcceptDialog) -> VBoxContainer:
	return dialog.get_node(LAYOUT_NAME) as VBoxContainer

## Plain dialog text: a wrapping label inside the content column, in the app's
## type and colour. `dialog_text` still carries the string, so the engine's own
## (hidden) label and every reader of the property agree on it.
static func set_text(dialog: AcceptDialog, text: String) -> Label:
	var label := Label.new()
	label.name = TEXT_NAME
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", UiTokens.TEXT)
	content(dialog).add_child(label)
	dialog.dialog_text = text
	return label

## Text the user must read — and may need to copy — in a selectable body.
##
## A read-only `TextEdit`, not a `RichTextLabel`: review text carries file paths
## in brackets, and a `RichTextLabel` would take `[b]` in a path as markup.
static func set_body(dialog: AcceptDialog, text: String, min_size := BODY_MIN_SIZE) -> TextEdit:
	var body := TextEdit.new()
	body.name = TEXT_NAME
	body.text = text
	body.editable = false
	body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	body.custom_minimum_size = min_size
	body.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
	content(dialog).add_child(body)
	dialog.dialog_text = text
	return body

## The text a dialog shows: its `set_body` surface or its `set_text` label when
## it has one, otherwise the engine label's string. A test reads a dialog's text
## through this, so it keeps working whichever surface the site chose.
static func body_of(dialog: AcceptDialog) -> String:
	var body := dialog.get_node_or_null(LAYOUT_NAME + "/" + TEXT_NAME) as Control
	if body is TextEdit:
		return (body as TextEdit).text
	if body is Label:
		return (body as Label).text
	return dialog.dialog_text

## Group the dialog's buttons at the right edge.
##
## The row is `[spacer, button, spacer, button, spacer, …]`; keeping the first
## spacer's stretch and shrinking every other child bunches the buttons (in
## their existing order) against the right edge. Left as it is, the dialog sets
## the buttons at its own size apart.
static func group_buttons(dialog: AcceptDialog) -> void:
	var row := dialog.get_ok_button().get_parent() as HBoxContainer
	if row == null:
		return
	var anchored := false
	for child in row.get_children():
		var control := child as Control
		if control == null:
			continue
		if not anchored and not (control is BaseButton):
			control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			anchored = true
		else:
			control.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

static func _adopt(parent: Node, dialog: AcceptDialog, title: String) -> void:
	parent.add_child(dialog)
	# No engine frame: it would be painted from Godot's default theme and its
	# title would sit in a band this module cannot colour.
	dialog.borderless = true
	# The engine's own label shares the content rect with our layout; hiding it
	# keeps `dialog_text` as data (see `set_text`) without rendering it twice.
	dialog.get_label().hide()

	var layout := VBoxContainer.new()
	layout.name = LAYOUT_NAME
	layout.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	dialog.add_child(layout)

	if title != "":
		dialog.title = title
		var heading := Label.new()
		heading.name = TITLE_NAME
		heading.text = title
		heading.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
		layout.add_child(heading)

	# One hook rather than a call at every site: `add_button` runs after
	# construction, and the grouping has to see that button.
	dialog.about_to_popup.connect(func(): group_buttons(dialog))
