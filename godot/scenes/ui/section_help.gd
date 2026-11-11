class_name SectionHelp
## The reusable Help affordance a section header carries: a question-mark icon
## button at the right of the heading, tooltip and accessible name "Help", whose
## press opens a table of what each glyph in that section does.
##
## Generic on purpose: the mechanism knows no section, no pane type and no
## action name. The caller hands it a title, one intro sentence and a provider
## returning `[{glyph, action, chord}]` in display order. The provider is called
## at press time, not at attach time, so a chord registered later (a panel built
## before the workspace registers its bindings) is still spelled correctly.
##
## `host` parents the popup: pass a Control under the workspace root, not a
## clipped one (the sidebar sets `clip_contents`, which would cut a modal).

## The button's tooltip and accessible name: one name for every section, so a
## user learns the affordance once.
const NAME := "Help"
const BUTTON_NAME := "HelpBtn"
const TABLE_NAME := "HelpTable"
const INTRO_NAME := "HelpIntro"

## The popup's text column: the table's rows are short, and the intro sentence
## wraps inside this width instead of stretching the dialog to its unwrapped
## length.
const MIN_WIDTH := 360.0

## Add the button to `header` - an HBoxContainer whose other children fill the
## width, so the button lands at the right edge - and return it.
static func attach(header: HBoxContainer, host: Node, title: String, intro: String,
		rows_of: Callable) -> Button:
	var btn := Button.new()
	btn.name = BUTTON_NAME
	Icons.icon_button(btn, Icons.QUESTION, NAME)
	btn.tooltip_text = NAME
	btn.pressed.connect(func(): show_table(host, title, intro, rows_of.call()))
	header.add_child(btn)
	return btn

## The popup: the app's own modal frame (`AppDialog.alert`), one wrapping
## sentence, then a three-column `glyph | action | chord` table. A glyph Label
## carries the action words as its accessible name, so a reader never hears a
## private-use codepoint. Returns the dialog.
static func show_table(host: Node, title: String, intro: String, rows: Array) -> AcceptDialog:
	var dialog := AppDialog.alert(host, title, "Close")
	var column := AppDialog.content(dialog)

	var intro_label := Label.new()
	intro_label.name = INTRO_NAME
	intro_label.text = intro
	intro_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro_label.custom_minimum_size.x = MIN_WIDTH
	column.add_child(intro_label)

	var table := GridContainer.new()
	table.name = TABLE_NAME
	table.columns = 3
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.add_theme_constant_override("h_separation", UiTokens.SPACE_XL)
	table.add_theme_constant_override("v_separation", UiTokens.SPACE_MD)
	for row in rows:
		if not row is Dictionary:
			continue
		var action := str(row.get("action", ""))
		table.add_child(_glyph_label(str(row.get("glyph", "")), action))
		table.add_child(_action_label(action))
		table.add_child(_chord_label(str(row.get("chord", ""))))
	column.add_child(table)

	# One dialog per press, freed on close: a help popup that only hid would
	# leave its whole table in the tree for the session, and the sidebar's Help
	# button can be pressed any number of times. Every close path is covered -
	# the OK button (`confirmed`) and Escape/window close (`canceled`).
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	AppDialog.popup(dialog)
	return dialog

static func _glyph_label(glyph: String, action: String) -> Label:
	var label := Label.new()
	label.text = glyph
	label.add_theme_font_override("font", Icons.font_resource)
	# The heading size is what every icon control in the app draws a glyph at.
	label.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	label.custom_minimum_size.x = 20
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.accessibility_name = action
	return label

static func _action_label(action: String) -> Label:
	var label := Label.new()
	label.text = action
	label.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label

static func _chord_label(chord: String) -> Label:
	var label := Label.new()
	label.text = chord
	label.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	label.theme_type_variation = UiTheme.MUTED_LABEL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label
