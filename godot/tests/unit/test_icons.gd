extends GutTest
# Icons — the one icon-button treatment.
#
# The glyph is drawn by a child `Label`, never by `Button.text`: the engine
# composes a button's exposed name as `"<name>: <text>"`, so a private-use
# codepoint left in the text reaches a screen reader. These assert the split
# (text empty, glyph in the Label), the size floor every icon button shares, and
# that a runtime glyph swap keeps the same element.

var _host: Control


func before_each():
	UiPalette.use(UiPalette.MODE_DARK)
	_host = Control.new()
	_host.theme = UiTheme.build()
	add_child(_host)


func after_each():
	UiPalette.use(UiPalette.MODE_DARK)


func _make(glyph := Icons.CLOSE, name := "Close pane", variation := &"") -> Button:
	var btn := Button.new()
	Icons.icon_button(btn, glyph, name, variation)
	_host.add_child(btn)
	return btn


func test_the_glyph_is_drawn_by_a_child_label_not_by_the_button():
	var btn := _make()
	assert_eq(btn.text, "", "a codepoint in `text` is what AT reads as the name")
	var label := btn.get_node_or_null(NodePath(Icons.GLYPH_NAME)) as Label
	assert_not_null(label, "the glyph lives in a Label named %s" % Icons.GLYPH_NAME)
	assert_eq(label.text, Icons.CLOSE)
	assert_eq(Icons.glyph(btn), Icons.CLOSE, "the codepoint reads back off the button")
	assert_eq(label.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"the decoration must never take the pointer")


func test_the_accessible_name_is_the_words_alone():
	var btn := _make(Icons.SETTINGS, "Pane settings")
	assert_eq(btn.accessibility_name, "Pane settings")
	var label := btn.get_node(NodePath(Icons.GLYPH_NAME)) as Label
	assert_eq(label.accessibility_name, "Pane settings",
		"the child repeats the words so it cannot surface as a codepoint either")


func test_the_button_takes_the_icon_variation():
	var btn := _make()
	assert_eq(btn.theme_type_variation, UiTheme.ICON_BUTTON,
		"the flat rest state and the focus ring come from the one variation")


func test_a_variation_tints_the_glyph():
	var btn := _make(Icons.FOLDER, "Choose workspace directory", UiTheme.ACCENT_LABEL)
	var label := btn.get_node(NodePath(Icons.GLYPH_NAME)) as Label
	assert_eq(label.theme_type_variation, UiTheme.ACCENT_LABEL,
		"a button's font colours cannot reach the child Label")
	assert_eq(btn.theme_type_variation, UiTheme.ICON_BUTTON, "the button keeps its treatment")


func test_the_width_floor_is_shared():
	var small := _make()
	assert_eq(small.custom_minimum_size.x, UiTokens.BUTTON_MIN_WIDTH,
		"an icon button takes the shared floor")
	var wide := Button.new()
	wide.custom_minimum_size = Vector2(36, UiTokens.BUTTON_MIN_HEIGHT)
	Icons.icon_button(wide, Icons.CLOSE, "Close")
	_host.add_child(wide)
	assert_eq(wide.custom_minimum_size.x, 36, "a wider control keeps its width")


func test_glyph_reads_nothing_from_a_plain_button():
	var plain := Button.new()
	plain.text = "Save"
	_host.add_child(plain)
	assert_eq(Icons.glyph(plain), "")
	assert_null(plain.get_node_or_null(NodePath(Icons.GLYPH_NAME)),
		"reading must not create the Label")


func test_set_glyph_swaps_the_codepoint_on_the_same_element():
	var btn := _make(Icons.MAXIMIZE_WIN, "Maximize window")
	var label := btn.get_node(NodePath(Icons.GLYPH_NAME)) as Label
	btn.accessibility_name = "Restore window"
	Icons.set_glyph(btn, Icons.RESTORE_WIN)
	assert_same(btn.get_node(NodePath(Icons.GLYPH_NAME)), label,
		"the same Label draws the new glyph")
	assert_eq(Icons.glyph(btn), Icons.RESTORE_WIN)
	assert_eq(label.accessibility_name, "Restore window",
		"the child's name follows the button's when the glyph moves")
	assert_eq(btn.get_child_count(), 1, "no second Label is ever created")
