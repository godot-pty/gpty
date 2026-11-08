class_name UiTheme
## The one Theme the app runs on, built from `UiPalette` and `UiTokens`, so a
## token is the only place a chrome colour or size is chosen.
##
## Applied on the `Workspace` scene root (`workspace.gd`) and rebuilt whenever
## the palette switches: every pane, overlay, popup and dialog is its
## descendant, and a `Window` inherits a theme from its parent Control (verified
## on 4.7.2), so nothing carries a second copy. Values are built here rather
## than stored in a `.tres` because a resource cannot read the palette — a
## `.tres` would be the second source of truth this module exists to remove.
##
## Stock Godot chrome is 60% opaque (`Color(0.1, 0.1, 0.1, 0.6)`) and 16 px, so
## the sidebars and the Settings cards showed the pane content behind them and
## the "built-in" text was larger than the app's own. Both are settled here.
##
## Content margins are set explicitly wherever the stock stylebox carried them:
## a `StyleBoxFlat` with no content margin collapses the control onto its text.

## Type-variation roles. A widget that needs a colour its type's default does
## not carry names one of these instead of pinning a token in an override, so
## the widget follows a palette switch through the theme.
const MUTED_LABEL := &"MutedLabel"
const DANGER_LABEL := &"DangerLabel"
const WARNING_LABEL := &"WarningLabel"
## A link-style button: the sidebar's active row and its accent glyphs.
const ACCENT_BUTTON := &"AccentButton"
## An icon-only Button: the glyph alone at rest, an accent-tinted hover/pressed
## and the keyboard focus ring. Text buttons keep the filled `Button` base.
## Applied by `Icons.icon_button`; a glyph that changes at runtime swaps its
## codepoint, never the variation.
const ICON_BUTTON := &"IconButton"
## A glyph in the accent colour: a Button's own font colours cannot reach the
## child `Label` that draws an icon-button glyph.
const ACCENT_LABEL := &"AccentLabel"

static func build() -> Theme:
	var p := UiPalette.active()
	var t := Theme.new()
	t.default_font_size = UiTokens.FS_SMALL

	# --- Text -----------------------------------------------------------------
	t.set_font_size("font_size", "Label", UiTokens.FS_SMALL)
	t.set_color("font_color", "Label", p.TEXT)

	for item in ["normal_font_size", "mono_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		t.set_font_size(item, "RichTextLabel", UiTokens.FS_SMALL)
	t.set_color("default_color", "RichTextLabel", p.TEXT)
	t.set_color("selection_color", "RichTextLabel", p.SELECTION)

	t.set_font_size("font_size", "TooltipLabel", UiTokens.FS_CAPTION)
	t.set_color("font_color", "TooltipLabel", p.TEXT)
	t.set_stylebox("panel", "TooltipPanel", _padded(_flat(p.SURFACE_RAISED, p.BORDER, 1), UiTokens.SPACE_MD))

	# --- Buttons --------------------------------------------------------------
	t.set_font_size("font_size", "Button", UiTokens.FS_SMALL)
	t.set_color("font_color", "Button", p.TEXT)
	t.set_color("font_hover_color", "Button", p.ACCENT_HOVER)
	t.set_color("font_pressed_color", "Button", p.ACCENT)
	t.set_color("font_focus_color", "Button", p.TEXT)
	t.set_color("font_disabled_color", "Button", p.TEXT_DISABLED)
	for state in _button_states():
		t.set_stylebox(state, "Button", _button_box(state))

	# CheckBox/CheckButton fall back to Button's type for any item they don't
	# define, so their styleboxes are emptied explicitly: a checkbox keeps its
	# glyph, not a filled button behind it.
	for type in ["CheckBox", "CheckButton"]:
		t.set_font_size("font_size", type, UiTokens.FS_SMALL)
		t.set_color("font_color", type, p.TEXT)
		t.set_color("font_hover_color", type, p.ACCENT_HOVER)
		t.set_color("font_pressed_color", type, p.TEXT)
		t.set_color("font_disabled_color", type, p.TEXT_DISABLED)
		for state in _button_states():
			t.set_stylebox(state, type, StyleBoxEmpty.new())

	# An OptionButton keeps Button's look but reserves room for its arrow; the
	# stock box carries 8 px of right content margin for exactly that.
	for state in _button_states():
		var box := _button_box(state)
		box.content_margin_right = UiTokens.SPACE_LG
		t.set_stylebox(state, "OptionButton", box)

	# --- Inputs ---------------------------------------------------------------
	t.set_font_size("font_size", "LineEdit", UiTokens.FS_SMALL)
	t.set_color("font_color", "LineEdit", p.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", p.TEXT_MUTED)
	t.set_color("font_selected_color", "LineEdit", p.TEXT)
	# Read-only content is content: a path or a review text the user must read is
	# not a disabled control, so it keeps the primary ink.
	t.set_color("font_uneditable_color", "LineEdit", p.TEXT)
	t.set_color("caret_color", "LineEdit", p.ACCENT)
	t.set_color("selection_color", "LineEdit", p.SELECTION)
	t.set_stylebox("normal", "LineEdit", _padded(_flat(p.SURFACE_RAISED, p.BORDER, 1), UiTokens.SPACE_SM))
	t.set_stylebox("focus", "LineEdit", _padded(_flat(p.SURFACE_RAISED, p.ACCENT, 1), UiTokens.SPACE_SM))
	t.set_stylebox("read_only", "LineEdit", _padded(_flat(p.SURFACE, p.BORDER, 1), UiTokens.SPACE_SM))

	# TextEdit's items are inherited by CodeEdit.
	t.set_font_size("font_size", "TextEdit", UiTokens.FS_SMALL)
	t.set_color("font_color", "TextEdit", p.TEXT)
	t.set_color("font_readonly_color", "TextEdit", p.TEXT)
	t.set_color("font_selected_color", "TextEdit", p.TEXT)
	t.set_color("caret_color", "TextEdit", p.ACCENT)
	t.set_color("selection_color", "TextEdit", p.SELECTION)
	t.set_stylebox("normal", "TextEdit", _padded(_flat(p.BG, p.BORDER, 1), UiTokens.SPACE_SM))
	t.set_stylebox("focus", "TextEdit", _padded(_flat(p.BG, p.ACCENT, 1), UiTokens.SPACE_SM))
	t.set_stylebox("read_only", "TextEdit", _padded(_flat(p.SURFACE, p.BORDER, 1), UiTokens.SPACE_SM))

	# --- Menus ----------------------------------------------------------------
	t.set_font_size("font_size", "PopupMenu", UiTokens.FS_SMALL)
	t.set_color("font_color", "PopupMenu", p.TEXT)
	t.set_color("font_hover_color", "PopupMenu", p.TEXT)
	t.set_color("font_disabled_color", "PopupMenu", p.TEXT_DISABLED)
	t.set_color("font_accelerator_color", "PopupMenu", p.TEXT_MUTED)
	t.set_stylebox("panel", "PopupMenu", _padded(_flat(p.SURFACE, p.BORDER, 1), UiTokens.SPACE_MD))
	t.set_stylebox("hover", "PopupMenu", _padded(_flat(p.ACCENT.lerp(p.SURFACE, 0.75)), UiTokens.SPACE_MD))
	var line := StyleBoxLine.new()
	line.color = p.BORDER
	line.thickness = 1
	t.set_stylebox("separator", "PopupMenu", line)

	# --- Surfaces -------------------------------------------------------------
	for type in ["Panel", "PanelContainer", "PopupPanel"]:
		t.set_stylebox("panel", type, _flat(p.SURFACE, p.BORDER, 1))

	# --- Lists and trees (content surfaces: the background is BG) --------------
	for type in ["Tree", "ItemList"]:
		t.set_font_size("font_size", type, UiTokens.FS_SMALL)
		t.set_color("font_color", type, p.TEXT)
		t.set_stylebox("panel", type, _padded(_flat(p.BG, p.BORDER, 1), UiTokens.SPACE_SM))

	# --- Tabs -----------------------------------------------------------------
	t.set_font_size("font_size", "TabBar", UiTokens.FS_CONTROL)
	t.set_color("font_selected_color", "TabBar", p.TEXT)
	t.set_color("font_unselected_color", "TabBar", p.TEXT_MUTED)
	t.set_color("font_hovered_color", "TabBar", p.ACCENT_HOVER)
	t.set_stylebox("tab_selected", "TabBar", _tab_box(true))
	t.set_stylebox("tab_unselected", "TabBar", _tab_box(false))
	t.set_stylebox("tab_hovered", "TabBar", _tab_box(false))
	t.set_stylebox("panel", "TabContainer", _flat(p.SURFACE, p.BORDER, 1))

	# --- Separators and scrolling ---------------------------------------------
	for type in ["HSeparator", "VSeparator"]:
		t.set_stylebox("separator", type, line)
	t.set_constant("separation", "HSeparator", UiTokens.SPACE_LG)
	t.set_constant("separation", "VSeparator", UiTokens.SPACE_LG)
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	# A scrollbar is a control, not a hairline. `ScrollBar::get_minimum_size`
	# takes a bar's thickness from the track stylebox's content margins plus the
	# type's padding constants, and a thumb's minimum length from the grabber's
	# margins - so an empty track is a 0 px bar: nothing to see, nothing to
	# drag, and no column reserved beside the content. The track fills the
	# column; the padding constants inset the thumb inside it.
	var thumb_width := UiTokens.SCROLLBAR_THICKNESS - UiTokens.SCROLLBAR_INSET * 2
	var bar_track := _flat(p.SURFACE_RAISED)
	bar_track.set_content_margin_all(thumb_width / 2)
	var bar_track_focus := _flat(p.SURFACE_RAISED, p.ACCENT, 1)
	bar_track_focus.set_content_margin_all(thumb_width / 2)
	var bar_thumb := _flat(Color(p.TEXT_MUTED, 0.75))
	var bar_thumb_hl := _flat(p.ACCENT_HOVER)
	var bar_thumb_pressed := _flat(p.ACCENT)
	for box in [bar_thumb, bar_thumb_hl, bar_thumb_pressed]:
		box.set_content_margin_all(UiTokens.SCROLLBAR_MIN_THUMB / 2)
	t.set_stylebox("scroll", "ScrollBar", bar_track)
	t.set_stylebox("scroll_focus", "ScrollBar", bar_track_focus)
	t.set_stylebox("grabber", "ScrollBar", bar_thumb)
	t.set_stylebox("grabber_highlight", "ScrollBar", bar_thumb_hl)
	t.set_stylebox("grabber_pressed", "ScrollBar", bar_thumb_pressed)
	t.set_constant("padding_left", "VScrollBar", UiTokens.SCROLLBAR_INSET)
	t.set_constant("padding_right", "VScrollBar", UiTokens.SCROLLBAR_INSET)
	t.set_constant("padding_top", "HScrollBar", UiTokens.SCROLLBAR_INSET)
	t.set_constant("padding_bottom", "HScrollBar", UiTokens.SCROLLBAR_INSET)

	# --- Windows and dialogs ---------------------------------------------------
	# The embedded frame stylebox is left to the engine: a `Window`'s title band is
	# painted from Godot's default theme and a Control's theme cannot reach it
	# (measured 2026-11-04: a magenta `Window/embedded_border` painted nothing).
	# `AppDialog` therefore makes its modals and its file pickers borderless and
	# draws a header of its own (`AppDialog.picker` inserts one above the
	# engine-built column, so the picker's own controls stay where they are).
	t.set_font_size("title_font_size", "Window", UiTokens.FS_CONTROL)
	t.set_color("title_color", "Window", p.TEXT)
	t.set_stylebox("panel", "AcceptDialog", _padded(_flat(p.SURFACE, p.BORDER, 1), UiTokens.SPACE_XXL))
	t.set_constant("buttons_separation", "AcceptDialog", UiTokens.SPACE_LG)

	# --- The concept graph -----------------------------------------------------
	t.set_stylebox("panel", "GraphEdit", _padded(_flat(p.SURFACE, p.BORDER, 1), UiTokens.SPACE_SM))
	t.set_stylebox("panel", "GraphNode", _graph_node_box(p.SURFACE_RAISED))
	t.set_stylebox("panel_selected", "GraphNode", _graph_node_box(p.SURFACE_RAISED))
	t.set_stylebox("titlebar", "GraphNode", _graph_node_box(p.SURFACE))
	t.set_stylebox("titlebar_selected", "GraphNode", _graph_node_box(p.SURFACE))

	# --- Roles ----------------------------------------------------------------
	# One registration per colour role, so no widget has to hold a token itself.
	for role in [[MUTED_LABEL, "Label", p.TEXT_MUTED],
			[DANGER_LABEL, "Label", p.DANGER],
			[WARNING_LABEL, "Label", p.WARNING],
			[ACCENT_LABEL, "Label", p.ACCENT]]:
		t.set_type_variation(role[0], role[1])
		t.set_color("font_color", role[0], role[2])
	t.set_type_variation(ACCENT_BUTTON, "Button")
	t.set_color("font_color", ACCENT_BUTTON, p.ACCENT)
	t.set_color("font_hover_color", ACCENT_BUTTON, p.ACCENT_HOVER)
	t.set_color("font_pressed_color", ACCENT_BUTTON, p.ACCENT)
	t.set_color("font_focus_color", ACCENT_BUTTON, p.ACCENT)

	# The icon-only treatment: no chrome at rest, an accent wash under the
	# pointer, and the same 1 px accent focus ring an input gets. `StyleBoxEmpty`
	# is what makes a glyph button read as a glyph instead of a filled text
	# button; the focus box is the only state with an outline.
	t.set_type_variation(ICON_BUTTON, "Button")
	t.set_stylebox("normal", ICON_BUTTON, StyleBoxEmpty.new())
	t.set_stylebox("disabled", ICON_BUTTON, StyleBoxEmpty.new())
	t.set_stylebox("hover", ICON_BUTTON, _flat(Color(p.ACCENT, 0.16)))
	t.set_stylebox("pressed", ICON_BUTTON, _flat(Color(p.ACCENT, 0.32)))
	t.set_stylebox("focus", ICON_BUTTON, _padded(_flat(Color.TRANSPARENT, p.ACCENT, 1), UiTokens.SPACE_XS))

	return t

## The four-side margin block every card sets by hand today.
static func margins(node: MarginContainer, px: int) -> void:
	node.add_theme_constant_override("margin_left", px)
	node.add_theme_constant_override("margin_top", px)
	node.add_theme_constant_override("margin_right", px)
	node.add_theme_constant_override("margin_bottom", px)

static func _button_states() -> Array:
	return ["normal", "hover", "pressed", "disabled", "focus"]

static func _button_box(state: String) -> StyleBoxFlat:
	var p := UiPalette.active()
	match state:
		"hover":
			return _padded(_flat(p.SURFACE_RAISED.lerp(p.ACCENT, 0.12), p.ACCENT, 1), UiTokens.SPACE_SM)
		"pressed":
			return _padded(_flat(p.SURFACE, p.ACCENT, 1), UiTokens.SPACE_SM)
		"disabled":
			return _padded(_flat(p.SURFACE_RAISED, p.BORDER, 1), UiTokens.SPACE_SM)
		"focus":
			return _padded(_flat(Color.TRANSPARENT, p.ACCENT, 1), UiTokens.SPACE_SM)
		_:
			return _padded(_flat(p.SURFACE_RAISED, p.BORDER, 1), UiTokens.SPACE_SM)

static func _tab_box(selected: bool) -> StyleBoxFlat:
	var p := UiPalette.active()
	var box := _flat(p.SURFACE if selected else p.SURFACE_RAISED)
	if selected:
		box.border_width_top = 2
		box.border_color = p.ACCENT
	box.content_margin_left = UiTokens.SPACE_LG
	box.content_margin_right = UiTokens.SPACE_LG
	box.content_margin_top = UiTokens.SPACE_SM
	box.content_margin_bottom = UiTokens.SPACE_SM
	return box

## GraphNode draws its body and its title bar with the same fat padding (the
## stock box carried 18 px horizontally and 12 px vertically); a node laid out
## with the engine default of zero would collapse onto its ports.
static func _graph_node_box(bg: Color) -> StyleBoxFlat:
	var p := UiPalette.active()
	var box := _flat(bg, p.BORDER, 1)
	box.content_margin_left = UiTokens.SPACE_XXL
	box.content_margin_right = UiTokens.SPACE_XXL
	box.content_margin_top = UiTokens.SPACE_XL
	box.content_margin_bottom = UiTokens.SPACE_XL
	return box

static func _padded(sb: StyleBoxFlat, px: int) -> StyleBoxFlat:
	sb.set_content_margin_all(px)
	return sb

static func _flat(bg: Color, border := Color.TRANSPARENT, width := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = UiTokens.RADIUS
	sb.corner_radius_top_right = UiTokens.RADIUS
	sb.corner_radius_bottom_left = UiTokens.RADIUS
	sb.corner_radius_bottom_right = UiTokens.RADIUS
	if width > 0:
		sb.border_color = border
		sb.set_border_width_all(width)
	return sb
