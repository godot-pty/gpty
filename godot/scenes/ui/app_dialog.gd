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

## How much of the window a modal may take, and the gap it keeps from the edge.
## A share rather than a pixel cap: the same card has to fit a 500x300 window and
## a 4K one. `popup_centered()` used to centre the card at its content minimum,
## which a long line or an unwrapped autowrap label could push past the window.
const VIEWPORT_RATIO := 0.75
const VIEWPORT_MARGIN := 24
## The floor the limit may never go under, and the floor a text body always has.
## Both are under the app's own minimum window (`WindowChrome.MIN_WINDOW_W/H`,
## 500x300), so the limit never claims more room than the window can give.
const LIMIT_FLOOR := Vector2i(240, 160)

## Node names: `content` finds the layout, and a test can name both.
const LAYOUT_NAME := "Layout"
const TITLE_NAME := "DialogTitle"
const TEXT_NAME := "BodyText"
## The picker's own header (see `picker`): the strip above the engine's column.
const HEADER_NAME := "Header"
const CLOSE_NAME := "DialogClose"

## The largest size a modal may take inside `available` (viewport pixels): a
## share of the window, less a margin on each edge. Pure, so the maths is
## testable without a window.
static func modal_limit(available: Vector2i, ratio := VIEWPORT_RATIO) -> Vector2i:
	return Vector2i(
		maxi(int(float(available.x) * ratio) - 2 * VIEWPORT_MARGIN, LIMIT_FLOOR.x),
		maxi(int(float(available.y) * ratio) - 2 * VIEWPORT_MARGIN, LIMIT_FLOOR.y))

## The width a text body wraps at: the modal's own limit less its padding, so
## the label is shaped at the width it is drawn at, floored and capped so a
## window smaller or larger than the body's design size still wraps.
static func text_width(available: Vector2i, ratio := VIEWPORT_RATIO) -> int:
	return clampi(modal_limit(available, ratio).x - 2 * UiTokens.SPACE_LG,
		LIMIT_FLOOR.x, int(BODY_MIN_SIZE.x))

## The window a dialog lives in. Resolved from its parent Control: the dialog is
## a Window and `get_viewport()` would return the window itself.
static func available_size(dialog: AcceptDialog) -> Vector2i:
	var parent := dialog.get_parent()
	if parent is CanvasItem and (parent as CanvasItem).is_inside_tree():
		return Vector2i((parent as CanvasItem).get_viewport().get_visible_rect().size)
	return Vector2i(1280, 720)

## Centre `dialog` in the window and keep it there.
##
## `popup_centered()` sizes the card from its content minimum alone, so a long
## line in the (hidden) engine label or an autowrap body shaped before its first
## layout could make the card larger than the window - the running-work confirm's
## "Close anyway" button ended up below the bottom edge. `max_size` is the
## engine-level clamp; the bounded body widths in `set_text`/`set_body` are what
## keep the minimum itself within it.
static func popup(dialog: AcceptDialog, ratio := VIEWPORT_RATIO) -> void:
	dialog.max_size = modal_limit(available_size(dialog), ratio)
	dialog.popup_centered_clamped(Vector2i.ZERO, ratio)

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

## A file or directory picker in the app's own frame.
##
## A `FileDialog` is an `AcceptDialog`, so it is borderless for the reason
## `_adopt` gives: the engine paints its title band from Godot's default theme,
## which a Control's theme cannot reach, and the band showed the pane behind it.
## Unlike a modal, the engine has already built the picker's layout (one internal
## `VBoxContainer` holding the path bar, the list and the name row), so the
## header is inserted at the top of that column instead of a new column being
## added: nothing of the picker's own controls moves, and inserting a child is
## stable — measured on 4.7.2, the column is not rebuilt by `file_mode`,
## `access`, a filter add or a re-popup.
static func picker(parent: Node, title: String, file_mode := FileDialog.FILE_MODE_OPEN_FILE,
		access := FileDialog.ACCESS_FILESYSTEM) -> FileDialog:
	var dialog := FileDialog.new()
	# The mode's setter renames the window ("Open a File", "Open a Directory"),
	# so the caller's title is applied after it, not before.
	dialog.file_mode = file_mode
	dialog.access = access
	dialog.title = title
	parent.add_child(dialog)
	dialog.borderless = true
	# The engine's label is a second title that would sit in the content rect.
	dialog.get_label().hide()
	_attach_picker_header(dialog, title)
	# One hook rather than a call at every site, for the reason `_adopt` gives,
	# and the one moment a repair is safe: the header is a child of the engine's
	# column, so a future engine that rebuilds it on show loses it, not the
	# picker's layout.
	dialog.about_to_popup.connect(func():
		_attach_picker_header(dialog, title)
		group_buttons(dialog))
	return dialog

## The picker's column: the engine's internal `VBoxContainer` (unnamed, so found
## by type). Falls back to the column holding the path field, and gives up with
## a warning rather than reparenting anything of the picker's.
static func _picker_column(dialog: FileDialog) -> VBoxContainer:
	for child in dialog.get_children(true):
		if child is VBoxContainer and child.get_child_count() > 0:
			return child as VBoxContainer
	for node in dialog.find_children("*", "VBoxContainer", true, false):
		var column := node as VBoxContainer
		if not column.find_children("*", "LineEdit", true, false).is_empty():
			return column
	return null

static func _attach_picker_header(dialog: FileDialog, title: String) -> void:
	var column := _picker_column(dialog)
	if column == null:
		push_warning("AppDialog.picker: the picker's content column was not found; "
			+ "the dialog stays borderless without a header")
		return
	if column.get_node_or_null(NodePath(HEADER_NAME)) != null:
		return
	var header := HBoxContainer.new()
	header.name = HEADER_NAME
	header.add_theme_constant_override("separation", UiTokens.SPACE_LG)
	var heading := Label.new()
	heading.name = TITLE_NAME
	heading.text = title
	heading.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	# The engine's own cancel path, so `canceled` fires and a site's
	# `queue_free` runs exactly as it does for the Cancel button.
	var close := Button.new()
	close.name = CLOSE_NAME
	close.tooltip_text = "Close"
	Icons.icon_button(close, Icons.CLOSE, "Close")
	close.pressed.connect(func(): dialog.get_cancel_button().pressed.emit())
	header.add_child(close)
	column.add_child(header)
	column.move_child(header, 0)
	# The window's minimum size is computed from the picker's own content, which
	# does not count a header this module added: without this the strip would
	# overlap the path bar instead of sitting above it.
	dialog.min_size.y += UiTokens.FS_HEADING + 2 * UiTokens.SPACE_SM

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
	# An autowrap Label with no width floor is shaped one word per line before
	# its first layout (`Label::get_minimum_size` reports the height at the
	# current width, which is still 0), so the card's minimum height was
	# unbounded and `popup_centered` centred it off screen. The floor is the
	# modal's own width: the label shapes at the width it will be drawn at.
	label.custom_minimum_size.x = text_width(available_size(dialog))
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
	# The requested size is a design size, not a promise the window can keep: a
	# 720x360 body in an 800x500 window is clamped to the modal's own limit.
	var limit := modal_limit(available_size(dialog))
	body.custom_minimum_size = Vector2(
		mini(int(min_size.x), limit.x), mini(int(min_size.y), limit.y))
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
	# It is still a Control child, so the engine measures it for the window's
	# content minimum: an unwrapped long line would push the card past the
	# `popup` clamp. Clipping lets it shrink instead (it never renders).
	dialog.get_label().hide()
	dialog.get_label().clip_text = true

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
