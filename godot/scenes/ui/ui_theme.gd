class_name UiTheme
## The one Theme the app runs on, built from `UiTokens` so a token is the only
## place a chrome colour or size is chosen.
##
## Applied once, on the `Workspace` scene root (`workspace.gd`): every pane,
## overlay, popup and dialog is its descendant, and a `Window` inherits a theme
## from its parent Control (verified on 4.7.2), so nothing carries a second
## copy. Values are built here rather than stored in a `.tres` because a resource
## cannot read the token constants — a `.tres` would be the second source of
## truth this module exists to remove.
##
## Stock Godot chrome is 60% opaque (`Color(0.1, 0.1, 0.1, 0.6)`) and 16 px, so
## the sidebars and the Settings cards showed the pane content behind them and
## the "built-in" text was larger than the app's own. Both are settled here.
##
## Content margins are set explicitly wherever the stock stylebox carried them:
## a `StyleBoxFlat` with no content margin collapses the control onto its text.

static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = UiTokens.FS_SMALL

	# --- Text -----------------------------------------------------------------
	t.set_font_size("font_size", "Label", UiTokens.FS_SMALL)
	t.set_color("font_color", "Label", UiTokens.TEXT)

	for item in ["normal_font_size", "mono_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		t.set_font_size(item, "RichTextLabel", UiTokens.FS_SMALL)
	t.set_color("default_color", "RichTextLabel", UiTokens.TEXT)
	t.set_color("selection_color", "RichTextLabel", UiTokens.SELECTION)

	t.set_font_size("font_size", "TooltipLabel", UiTokens.FS_CAPTION)
	t.set_color("font_color", "TooltipLabel", UiTokens.TEXT)
	t.set_stylebox("panel", "TooltipPanel", _padded(_flat(UiTokens.SURFACE_RAISED, UiTokens.BORDER, 1), UiTokens.SPACE_MD))

	# --- Buttons --------------------------------------------------------------
	t.set_font_size("font_size", "Button", UiTokens.FS_SMALL)
	t.set_color("font_color", "Button", UiTokens.TEXT)
	t.set_color("font_hover_color", "Button", UiTokens.ACCENT_HOVER)
	t.set_color("font_pressed_color", "Button", UiTokens.ACCENT)
	t.set_color("font_focus_color", "Button", UiTokens.TEXT)
	t.set_color("font_disabled_color", "Button", UiTokens.TEXT_DISABLED)
	for state in _button_states():
		t.set_stylebox(state, "Button", _button_box(state))

	# CheckBox/CheckButton fall back to Button's type for any item they don't
	# define, so their styleboxes are emptied explicitly: a checkbox keeps its
	# glyph, not a filled button behind it.
	for type in ["CheckBox", "CheckButton"]:
		t.set_font_size("font_size", type, UiTokens.FS_SMALL)
		t.set_color("font_color", type, UiTokens.TEXT)
		t.set_color("font_hover_color", type, UiTokens.ACCENT_HOVER)
		t.set_color("font_pressed_color", type, UiTokens.TEXT)
		t.set_color("font_disabled_color", type, UiTokens.TEXT_DISABLED)
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
	t.set_color("font_color", "LineEdit", UiTokens.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", UiTokens.TEXT_MUTED)
	t.set_color("font_selected_color", "LineEdit", UiTokens.TEXT)
	# Read-only content is content: a path or a review text the user must read is
	# not a disabled control, so it keeps the primary ink.
	t.set_color("font_uneditable_color", "LineEdit", UiTokens.TEXT)
	t.set_color("caret_color", "LineEdit", UiTokens.ACCENT)
	t.set_color("selection_color", "LineEdit", UiTokens.SELECTION)
	t.set_stylebox("normal", "LineEdit", _padded(_flat(UiTokens.SURFACE_RAISED, UiTokens.BORDER, 1), UiTokens.SPACE_SM))
	t.set_stylebox("focus", "LineEdit", _padded(_flat(UiTokens.SURFACE_RAISED, UiTokens.ACCENT, 1), UiTokens.SPACE_SM))
	t.set_stylebox("read_only", "LineEdit", _padded(_flat(UiTokens.SURFACE, UiTokens.BORDER, 1), UiTokens.SPACE_SM))

	# TextEdit's items are inherited by CodeEdit.
	t.set_font_size("font_size", "TextEdit", UiTokens.FS_SMALL)
	t.set_color("font_color", "TextEdit", UiTokens.TEXT)
	t.set_color("font_readonly_color", "TextEdit", UiTokens.TEXT)
	t.set_color("font_selected_color", "TextEdit", UiTokens.TEXT)
	t.set_color("caret_color", "TextEdit", UiTokens.ACCENT)
	t.set_color("selection_color", "TextEdit", UiTokens.SELECTION)
	t.set_stylebox("normal", "TextEdit", _padded(_flat(UiTokens.BG, UiTokens.BORDER, 1), UiTokens.SPACE_SM))
	t.set_stylebox("focus", "TextEdit", _padded(_flat(UiTokens.BG, UiTokens.ACCENT, 1), UiTokens.SPACE_SM))
	t.set_stylebox("read_only", "TextEdit", _padded(_flat(UiTokens.SURFACE, UiTokens.BORDER, 1), UiTokens.SPACE_SM))

	# --- Menus ----------------------------------------------------------------
	t.set_font_size("font_size", "PopupMenu", UiTokens.FS_SMALL)
	t.set_color("font_color", "PopupMenu", UiTokens.TEXT)
	t.set_color("font_hover_color", "PopupMenu", UiTokens.TEXT)
	t.set_color("font_disabled_color", "PopupMenu", UiTokens.TEXT_DISABLED)
	t.set_color("font_accelerator_color", "PopupMenu", UiTokens.TEXT_MUTED)
	t.set_stylebox("panel", "PopupMenu", _padded(_flat(UiTokens.SURFACE, UiTokens.BORDER, 1), UiTokens.SPACE_MD))
	t.set_stylebox("hover", "PopupMenu", _padded(_flat(UiTokens.ACCENT.lerp(UiTokens.SURFACE, 0.75)), UiTokens.SPACE_MD))
	var line := StyleBoxLine.new()
	line.color = UiTokens.BORDER
	line.thickness = 1
	t.set_stylebox("separator", "PopupMenu", line)

	# --- Surfaces -------------------------------------------------------------
	for type in ["Panel", "PanelContainer", "PopupPanel"]:
		t.set_stylebox("panel", type, _flat(UiTokens.SURFACE, UiTokens.BORDER, 1))

	# --- Lists and trees (content surfaces: the background is BG) --------------
	for type in ["Tree", "ItemList"]:
		t.set_font_size("font_size", type, UiTokens.FS_SMALL)
		t.set_color("font_color", type, UiTokens.TEXT)
		t.set_stylebox("panel", type, _padded(_flat(UiTokens.BG, UiTokens.BORDER, 1), UiTokens.SPACE_SM))

	# --- Tabs -----------------------------------------------------------------
	t.set_font_size("font_size", "TabBar", UiTokens.FS_CONTROL)
	t.set_color("font_selected_color", "TabBar", UiTokens.TEXT)
	t.set_color("font_unselected_color", "TabBar", UiTokens.TEXT_MUTED)
	t.set_color("font_hovered_color", "TabBar", UiTokens.ACCENT_HOVER)
	t.set_stylebox("tab_selected", "TabBar", _tab_box(true))
	t.set_stylebox("tab_unselected", "TabBar", _tab_box(false))
	t.set_stylebox("tab_hovered", "TabBar", _tab_box(false))
	t.set_stylebox("panel", "TabContainer", _flat(UiTokens.SURFACE, UiTokens.BORDER, 1))

	# --- Separators and scrolling ---------------------------------------------
	for type in ["HSeparator", "VSeparator"]:
		t.set_stylebox("separator", type, line)
	t.set_constant("separation", "HSeparator", UiTokens.SPACE_LG)
	t.set_constant("separation", "VSeparator", UiTokens.SPACE_LG)
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("scroll", "ScrollBar", StyleBoxEmpty.new())
	t.set_stylebox("scroll_focus", "ScrollBar", StyleBoxEmpty.new())
	t.set_stylebox("grabber", "ScrollBar", _flat(Color(UiTokens.TEXT_MUTED, 0.35)))
	t.set_stylebox("grabber_highlight", "ScrollBar", _flat(Color(UiTokens.TEXT_MUTED, 0.55)))
	t.set_stylebox("grabber_pressed", "ScrollBar", _flat(Color(UiTokens.ACCENT, 0.7)))

	# --- Windows and dialogs ---------------------------------------------------
	# The embedded frame stylebox is left to the engine: a `Window`'s title band is
	# painted from Godot's default theme and a Control's theme cannot reach it
	# (measured 2026-11-04: a magenta `Window/embedded_border` painted nothing).
	# `AppDialog` therefore makes its modals borderless and draws its own header;
	# the engine windows that keep a frame (FileDialog) keep it at the engine's
	# own chrome, which is what a native file picker looks like.
	t.set_font_size("title_font_size", "Window", UiTokens.FS_CONTROL)
	t.set_color("title_color", "Window", UiTokens.TEXT)
	t.set_stylebox("panel", "AcceptDialog", _padded(_flat(UiTokens.SURFACE, UiTokens.BORDER, 1), UiTokens.SPACE_XXL))
	t.set_constant("buttons_separation", "AcceptDialog", UiTokens.SPACE_LG)

	# --- The concept graph -----------------------------------------------------
	t.set_stylebox("panel", "GraphEdit", _padded(_flat(UiTokens.SURFACE, UiTokens.BORDER, 1), UiTokens.SPACE_SM))
	t.set_stylebox("panel", "GraphNode", _graph_node_box(UiTokens.SURFACE_RAISED))
	t.set_stylebox("panel_selected", "GraphNode", _graph_node_box(UiTokens.SURFACE_RAISED))
	t.set_stylebox("titlebar", "GraphNode", _graph_node_box(UiTokens.SURFACE))
	t.set_stylebox("titlebar_selected", "GraphNode", _graph_node_box(UiTokens.SURFACE))

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
	match state:
		"hover":
			return _padded(_flat(UiTokens.SURFACE_RAISED.lerp(UiTokens.ACCENT, 0.12), UiTokens.ACCENT, 1), UiTokens.SPACE_SM)
		"pressed":
			return _padded(_flat(UiTokens.SURFACE, UiTokens.ACCENT, 1), UiTokens.SPACE_SM)
		"disabled":
			return _padded(_flat(UiTokens.SURFACE_RAISED, UiTokens.BORDER, 1), UiTokens.SPACE_SM)
		"focus":
			return _padded(_flat(Color.TRANSPARENT, UiTokens.ACCENT, 1), UiTokens.SPACE_SM)
		_:
			return _padded(_flat(UiTokens.SURFACE_RAISED, UiTokens.BORDER, 1), UiTokens.SPACE_SM)

static func _tab_box(selected: bool) -> StyleBoxFlat:
	var box := _flat(UiTokens.SURFACE if selected else UiTokens.SURFACE_RAISED)
	if selected:
		box.border_width_top = 2
		box.border_color = UiTokens.ACCENT
	box.content_margin_left = UiTokens.SPACE_LG
	box.content_margin_right = UiTokens.SPACE_LG
	box.content_margin_top = UiTokens.SPACE_SM
	box.content_margin_bottom = UiTokens.SPACE_SM
	return box

## GraphNode draws its body and its title bar with the same fat padding (the
## stock box carried 18 px horizontally and 12 px vertically); a node laid out
## with the engine default of zero would collapse onto its ports.
static func _graph_node_box(bg: Color) -> StyleBoxFlat:
	var box := _flat(bg, UiTokens.BORDER, 1)
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
