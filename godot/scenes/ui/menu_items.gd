class_name MenuItems
# The one builder for a native PopupMenu item. An item in this app is an
# icon-font glyph, the words, a tooltip and the metadata the opener reads back;
# the workspace rows and the pane actions both come through here, so their icon
# size, tint and missing-glyph fallback cannot drift.
#
# `glyph` is a Phosphor codepoint (`Icons.*` or a pane type's `menu_icon`).
# `Icons.glyph_texture` answers null for a glyph the bundled font does not have;
# the item still appears, without an icon, rather than with a blank slot.

static func add(menu: PopupMenu, glyph: String, text: String, tip: String = "",
		meta: Variant = null) -> int:
	return _add(menu, glyph, text, false, false, tip, meta)

## A one-of list (the pane types): the check mark marks the current choice.
static func add_radio(menu: PopupMenu, glyph: String, text: String,
		checked: bool, tip: String = "", meta: Variant = null) -> int:
	return _add(menu, glyph, text, true, checked, tip, meta)

static func _add(menu: PopupMenu, glyph: String, text: String, is_radio: bool,
		checked: bool, tip: String, meta: Variant) -> int:
	var texture: Texture2D = null
	if glyph != "":
		texture = Icons.glyph_texture(glyph, UiPalette.active().TEXT)
	if is_radio:
		if texture != null:
			menu.add_icon_radio_check_item(texture, text)
		else:
			menu.add_radio_check_item(text)
	elif texture != null:
		menu.add_icon_item(texture, text)
	else:
		menu.add_item(text)
	var i := menu.item_count - 1
	if tip != "":
		menu.set_item_tooltip(i, tip)
	if meta != null:
		menu.set_item_metadata(i, meta)
	if is_radio:
		menu.set_item_checked(i, checked)
	return i
