extends GutTest
# ColorSwatch — the words a colour swatch carries.
# Defends: a translucent swatch names its opacity rather than showing the
# engine's unexplained checkerboard, and a fully transparent one reads "unset".

func test_readings():
	assert_eq(ColorSwatch.describe(Color(1, 1, 1)), "", "an opaque colour needs no words")
	assert_eq(ColorSwatch.describe(Color(1, 1, 1, 0.4)), "40%")
	assert_eq(ColorSwatch.describe(Color(1, 1, 1, 0.305)), "31%", "rounded, not truncated")
	assert_eq(ColorSwatch.describe(Color(1, 1, 1, 0.0)), ColorSwatch.UNSET)

func test_labels():
	assert_eq(ColorSwatch.label_text("Selection", Color(0.3, 0.5, 1.0, 0.4)), "Selection (40%)")
	assert_eq(ColorSwatch.label_text("Default BG", Color(0, 0, 0, 0)), "Default BG (unset)")
	assert_eq(ColorSwatch.label_text("Wrapper bg", Color(0.1, 0.1, 0.1)), "Wrapper bg")

func test_tooltips_say_what_the_checkerboard_is():
	assert_eq(ColorSwatch.tooltip(Color(1, 1, 1)), "", "nothing to explain")
	assert_string_contains(ColorSwatch.tooltip(Color(1, 1, 1, 0.3)), "checkerboard")
	assert_string_contains(ColorSwatch.tooltip(Color(1, 1, 1, 0.3)), "Translucent")
	assert_string_contains(ColorSwatch.tooltip(Color(1, 1, 1, 0.0)), "Unset")

func test_attach_and_sync_follow_the_picker():
	var picker := ColorPickerButton.new()
	picker.color = Color(0.3, 0.5, 1.0, 0.4)
	var lbl := Label.new(); lbl.text = "Selection"
	add_child(picker); add_child(lbl)
	ColorSwatch.attach(lbl, picker)
	assert_eq(lbl.text, "Selection (40%)")
	assert_string_contains(lbl.tooltip_text, "Translucent")
	picker.color = Color(0.2, 0.4, 0.8)          # assignment does not emit
	ColorSwatch.sync(lbl, picker)
	assert_eq(lbl.text, "Selection", "opaque drops the reading")
	assert_eq(lbl.tooltip_text, "")
	picker.color_changed.emit(picker.color)      # a live pick
	assert_eq(lbl.text, "Selection")
	picker.queue_free(); lbl.queue_free()
