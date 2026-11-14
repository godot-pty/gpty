extends Control
class_name Sidebar

signal request_new_pane(type_name: String)
signal request_close(body: Control)
signal request_settings
signal request_reset
signal request_focus(body: Control)
signal request_pane_menu(body: Control, source_btn: Button)
signal request_pane_settings(body: Control)
signal toggled
signal request_profile(name: String)
signal request_profile_in_new_workspace(name: String)
signal request_profile_rename(index: int, name: String)
signal request_profile_uninstall(plugin_id: String)
signal request_save_profile
signal request_delete_profile(index: int)
signal request_window_mode(mode: int)
signal request_search
signal request_workspace_switch(index: int)
signal request_workspace_add
signal request_workspace_close(index: int)
signal request_workspace_rename(index: int, name: String)
signal request_workspace_menu(index: int, source_btn: Button)
signal request_workspaces_close_all

## The sidebar's width open and collapsed. One owner: `Workspace._build_sidebar`
## and `_toggle_sidebar` both read these, so the fold's own state test cannot
## drift from the width it sets.
const WIDTH := 180
const COLLAPSED_WIDTH := 20


var bg: ColorRect
## The column's own scroll container and the VBox inside it. The window can be
## shorter than the sections' minimum heights (a 340 px window holds ~530 px of
## chrome), so the whole column scrolls instead of its tail being clipped.
var _content_scroll: ScrollContainer = null
## The header's title and collapse glyph, toggled with the fold (the fold used
## to find them by node path, which an added container would have broken).
var _title_label: Label = null
var _collapse_arrow: Button = null
var _wm_dropdown: OptionButton
var _pane_list: VBoxContainer
var _profile_list: VBoxContainer
var _workspace_list: VBoxContainer
## The pane row accented as active; `set_active_pane` is the only mover between
## frames, and a rebuild re-derives it.
var _pane_active: Control = null
## The "Panes:" heading row; hidden while the list is empty so a fresh
## workspace does not show a section title over nothing.
var _pane_heading: HBoxContainer = null

## The one inline close question. The row (or title row) it belongs to renders
## check/cross in place of its actions. Kinds: "workspace" (index + name),
## "pane" (body), "workspaces_all", "panes_all". `snapshot` pins a title-row
## action to the list it was opened against; `ok` is the visible check button.
var _pending_close: Dictionary = {}
## The last lists the workspace handed over, so a confirm click can re-render.
var _ws_names: Array[String] = []
var _ws_active := -1
var _ws_cwds: Array[String] = []
var _pane_items: Array = []
## What each list's rows were last built from, one string per row. A refresh that
## matches moves the accent only: building a row is 7-10.4 ms (three Phosphor
## glyph Labels at 3.3-3.5 ms each), an accent on an attached row is free.
var _ws_rendered: Array[String] = []
var _profile_rendered: Array[String] = []
var _pane_rendered: Array[String] = []
## Whether each list has been built at least once. An empty model matches an
## empty signature, so without this the first refresh would skip the rows that
## must exist (the profile section's catalog hint is always there).
var _ws_drawn := false
var _profile_drawn := false
var _pane_drawn := false
## The last profile list handed over, so a confirm click can rebuild it
## without the workspace re-sending the model.
var _profile_items: Array = []
var _profile_active_name := ""
var _workspaces_add_btn: Button = null
var _workspaces_close_all_btn: Button = null
var _workspaces_confirm: HBoxContainer = null
var _panes_close_all_btn: Button = null
var _panes_confirm: HBoxContainer = null

## The Add Pane header: its heading renames itself to the tile the pointer (or,
## failing that, the keyboard cursor) is on, and its Help button lists what
## every glyph adds.
const ADD_PANE_TITLE := " Add Pane:"
const ADD_PANE_HELP_TEXT := "Each button adds one pane of that type to the active workspace: the largest tile splits in two. Hover a glyph to read its name beside the heading, or press Tab to reach the buttons."
var _add_pane_heading: Label = null
var _add_pane_hover := ""
var _add_pane_focus := ""


func _ready():
	clip_contents = true
	anchor_top = 0.0
	anchor_bottom = 1.0

func build(bg_rect: ColorRect):
	bg = bg_rect
	var margin = MarginContainer.new()
	margin.name = "SidebarMargin"
	# Left/right 8px ≈ scrollbar width: rows never start at the sidebar's
	# edge, and an appearing scrollbar fills the reserved space.
	margin.add_theme_constant_override("margin_left", UiTokens.SPACE_LG)
	margin.add_theme_constant_override("margin_right", UiTokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UiTokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", UiTokens.SPACE_MD)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	# The whole column scrolls, so a short window reaches every section instead
	# of clipping the last one. `SIZE_EXPAND_FILL` on the content keeps today's
	# tall-window behaviour: a `ScrollContainer` stretches an expand-flagged
	# child to its own size, so the pane list still fills the leftover height.
	var sc := ScrollContainer.new(); sc.name = "SidebarScroll"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(sc)
	_content_scroll = sc

	var v = VBoxContainer.new(); v.name = "SidebarContent"
	v.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	_add_header(v)
	_add_window_mode(v)
	_add_buttons(v)
	_add_workspace_section(v)
	_add_profile_section(v)
	_add_pane_list_ui(v)
	_add_collapsed_button()

	SettingsManager.settings_changed.connect(_sync_window_mode)

func update_pane_list(panes: Array, active_body: Control = null):
	if not _pane_list: return
	_pane_items.assign(panes)
	_pane_active = active_body
	var content := _pane_signature()
	if _pane_drawn and _pending_close.is_empty() and content == _pane_rendered:
		_apply_pane_state()
		return
	_pane_drawn = true
	_pane_rendered = content
	_render_panes()

## Which pane a row is, and the label it wears: an id keeps two panes of one type
## apart, and a close renumbers the labels of the survivors.
func _pane_signature() -> Array[String]:
	var sig: Array[String] = []
	for body in _pane_items:
		sig.append("%d\u001f%s" % [body.get_instance_id(), str(body.get("pane_label"))])
	return sig

## Move the list's state without touching its rows: the active accent and the
## section's header. Everything else a row shows is in `_pane_signature`.
func _apply_pane_state() -> void:
	for row in _pane_list.get_children():
		if row.is_queued_for_deletion():
			continue
		var btn := row.get_child(0) as Button
		if btn != null:
			_apply_row_accent(btn, row.get_meta("body") == _pane_active)
	_sync_pane_header()

## One pane row: label, settings, More, Close, and the hidden check/cross pair.
## The close asks in this row first; only the check emits `request_close`.
func _make_pane_row(body: Control, is_active: bool) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTokens.SPACE_HAIR)
	row.set_meta("body", body)

	var pane_label := str(body.get("pane_label"))
	var label := pane_label if pane_label != "" else "%s?" % PaneTypes.ALL.get(body._pane_type(), {}).get("label_prefix", "?")
	var btn = _make_sidebar_button(label)
	_apply_row_accent(btn, is_active)
	btn.pressed.connect(func(): request_focus.emit(body))
	row.add_child(btn)

	# The three trailing actions, the same three the title bar shows: settings,
	# the one menu (minimize, swap position, type list with the current type
	# marked), close. The five it used to carry left ~49 px for the label.
	var set_btn = _make_row_action_button(Icons.SETTINGS, "Pane settings")
	set_btn.pressed.connect(func(): request_pane_settings.emit(body))
	row.add_child(set_btn)

	var menu_btn = _make_row_action_button(Icons.MORE, "More pane actions")
	menu_btn.pressed.connect(func(): request_pane_menu.emit(body, menu_btn))
	row.add_child(menu_btn)

	var cls_btn = _make_row_action_button(Icons.DELETE, "Close pane")
	cls_btn.name = "ClosePaneRowBtn"
	cls_btn.pressed.connect(func(): _request_close_confirm("pane", 0, "", body, cls_btn))
	row.add_child(cls_btn)

	var confirm := _confirm_row("CloseConfirmOk", "CloseConfirmCancel", "'%s'" % label)
	row.add_child(confirm)
	var pending := _pending_pane(body)
	set_btn.visible = not pending
	menu_btn.visible = not pending
	cls_btn.visible = not pending
	confirm.visible = pending
	if pending:
		_pending_close["ok"] = confirm.get_child(0)
	return row

## Move the active-row accent without rebuilding the list — called on pane
## focus changes (the workspace polls `_tm.last_body` each frame).
func set_active_pane(body: Control):
	if body == _pane_active:
		return
	_pane_active = body
	_apply_pane_state()

## The one constructor for a sidebar button that carries text: a section row's
## label (`icon == ""`) and a full-width icon+text action (Search, Settings,
## Feedback). Centering lives here so every new sidebar text button inherits it
## instead of choosing its own alignment.
##
## Row labels keep `clip_text`: a user-authored name must not size the button to
## its text and drag the fixed 180 px panel's other rows out of view; the
## overrun ellipsizes instead of slicing the row. An icon+text action centers
## its glyph and label as one group in a full-rect HBox; the Button itself has
## no text, so it keeps its explicit 28 px height.
func _make_sidebar_button(text: String, icon := "") -> Button:
	var btn := Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if icon == "":
		btn.text = text
		btn.clip_text = true
		btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		return btn

	btn.custom_minimum_size.y = 28
	var h := HBoxContainer.new()
	h.name = "IconTextRow"
	h.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(h)

	var icon_lbl := Label.new()
	icon_lbl.text = icon
	icon_lbl.add_theme_font_override("font", Icons.font_resource)
	icon_lbl.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(icon_lbl)

	var text_lbl := Label.new()
	text_lbl.text = text
	text_lbl.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	text_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(text_lbl)
	return btn

## A trailing glyph on a section row (pane and profile rows). Glyph-only
## affordances are the sidebar's idiom, so the tooltip carries the meaning.
func _make_row_action_button(icon: String, tooltip: String) -> Button:
	var btn = Button.new()
	btn.tooltip_text = tooltip
	# The row's action, not its glyph: the tooltip is already the sentence a
	# pointer user reads, and the accessible name must not drift from it.
	Icons.icon_button(btn, icon, tooltip)
	return btn

func _add_header(v: VBoxContainer):
	var h = HBoxContainer.new(); h.name = "Header"
	h.add_theme_constant_override("separation", 0)
	var title = Label.new(); title.text = " gPTY"; title.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	title.name = "SidebarTitle"; title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(title)
	_title_label = title
	var arrow = Button.new()
	arrow.name = "SidebarArrow"
	arrow.custom_minimum_size = Vector2(UiTokens.BUTTON_MIN_WIDTH, UiTokens.BUTTON_MIN_HEIGHT)
	Icons.icon_button(arrow, Icons.COLLAPSE, "Hide sidebar")
	arrow.pressed.connect(_toggle_sidebar)
	h.add_child(arrow)
	_collapse_arrow = arrow
	v.add_child(h)

func _add_buttons(v: VBoxContainer):
	_add_pane_buttons(v)

	var search_btn = _make_sidebar_button("Search", Icons.SEARCH)
	search_btn.tooltip_text = _with_chord("Search the active terminal", "term:search")
	search_btn.pressed.connect(func(): request_search.emit())
	v.add_child(search_btn)

	var settings_btn = _make_sidebar_button("Settings", Icons.SETTINGS)
	settings_btn.pressed.connect(func(): request_settings.emit())
	v.add_child(settings_btn)

	var feedback_btn = _make_sidebar_button("Feedback", Icons.FEEDBACK)
	feedback_btn.tooltip_text = "Report a bug or request a feature - opens a prefilled GitHub issue in your browser"
	feedback_btn.pressed.connect(_on_feedback_pressed)
	v.add_child(feedback_btn)

func _add_window_mode(v: VBoxContainer):
	var wm_dropdown = OptionButton.new()
	wm_dropdown.name = "WindowModeDropdown"
	wm_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for label in SettingsManager.WINDOW_MODE_LABELS:
		wm_dropdown.add_item(label)
	wm_dropdown.select(SettingsManager.cfg_window_mode)
	# The control's own name is what a reader hears, and the tooltip says what
	# each value draws: three bare words were the whole explanation before.
	wm_dropdown.accessibility_name = SettingsManager.WINDOW_MODE_TITLE
	wm_dropdown.tooltip_text = SettingsManager.WINDOW_MODE_HINT
	wm_dropdown.item_selected.connect(func(idx: int): request_window_mode.emit(idx))
	v.add_child(wm_dropdown)
	_wm_dropdown = wm_dropdown

func _add_pane_buttons(v: VBoxContainer):
	# The heading and the section's Help button share one row: the glyph grid is
	# compact, so what each glyph adds is a press away, and the heading names the
	# tile under the pointer without every tile spending a line on its name.
	var header = HBoxContainer.new(); header.name = "AddPaneHeader"
	_add_pane_heading = Label.new(); _add_pane_heading.name = "AddPaneHeading"
	_add_pane_heading.text = ADD_PANE_TITLE
	# The heading renames itself on hover, so its text must never widen the
	# section: `clip_text` drops the text from the label's minimum width (the
	# mechanism `_make_sidebar_button` relies on) and the overrun ellipsizes.
	_add_pane_heading.clip_text = true
	_add_pane_heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_add_pane_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_add_pane_heading)
	# The popup is parented to the sidebar's background rect, not the sidebar:
	# the sidebar clips its content, which would cut a modal in half.
	SectionHelp.attach(header, bg if bg != null else self, "Add Pane", ADD_PANE_HELP_TEXT, _pane_help_rows)
	v.add_child(header)

	# A two-row grid, not a strip: eight pane types in one row overflow the
	# 164 px content width (the eighth icon was clipped to `|` when the media
	# pane landed). Four columns keep every button reachable and leave the
	# icons their ambient size.
	var row = GridContainer.new()
	row.name = "PaneTypeRow"
	row.columns = 4
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("h_separation", UiTokens.SPACE_XS)
	row.add_theme_constant_override("v_separation", UiTokens.SPACE_XS)

	for key in PaneTypes.ALL:
		var info = PaneTypes.ALL[key]
		var btn = Button.new()
		# The chord comes from the registry, not the pane type's own field: one
		# spelling for the tooltip, the Help table and the key that works.
		btn.tooltip_text = _with_chord("New " + info["name"], "app:new_" + key)
		Icons.icon_button(btn, info["icon"], btn.tooltip_text)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 28)
		btn.pressed.connect(func(): request_new_pane.emit(key))
		btn.mouse_entered.connect(_on_pane_tile_entered.bind(key))
		btn.mouse_exited.connect(_on_pane_tile_exited.bind(key))
		btn.focus_entered.connect(_on_pane_tile_focused.bind(key))
		btn.focus_exited.connect(_on_pane_tile_unfocused.bind(key))
		row.add_child(btn)

	v.add_child(row)

## The rows the Add Pane Help popup shows, read when it opens: one per registry
## entry in grid order. The chord is the binding the key path actually reads, so
## the table cannot name a chord that does not fire.
func _pane_help_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key in PaneTypes.ALL:
		var info = PaneTypes.ALL[key]
		rows.append({
			"glyph": info["icon"],
			"action": "Add a %s pane" % info["name"],
			"chord": ShortcutManager.chord("app:new_" + key),
		})
	return rows

## A sentence plus the chord `action` is bound to, or the sentence alone when it
## has none: a tooltip that names a chord must read the binding that works.
func _with_chord(text: String, action: String) -> String:
	var chord := ShortcutManager.chord(action)
	return text if chord == "" else "%s (%s)" % [text, chord]

## What the Feedback issue reports about this build - the four facts the row
## allows and nothing else: no pane type, no profile, no path, no environment.
func feedback_about() -> Dictionary:
	return {
		"version": GptyTerminal.get_app_version(),
		"os": OS.get_name(),
		"os_version": OS.get_version(),
		"window_mode": SettingsManager.window_mode_label(),
	}

## Open the prefilled issue; when no browser can be reached (offline, headless,
## no default handler) the same text goes to the clipboard instead, so the
## report is one paste away and nothing is submitted by the app.
func _on_feedback_pressed() -> void:
	var about := feedback_about()
	ExternalLink.open(
		FeedbackText.url(about), FeedbackText.body(about),
		"Couldn't open a browser - issue text copied; paste it at github.com/godot-pty/gpty/issues/new",
		"Feedback")

func _on_pane_tile_entered(key: String) -> void:
	_add_pane_hover = key
	_sync_add_pane_heading()

func _on_pane_tile_exited(key: String) -> void:
	# Only this tile's own report clears it: moving between two tiles delivers
	# the new `mouse_entered` and the old `mouse_exited` in either order.
	if _add_pane_hover == key:
		_add_pane_hover = ""
	_sync_add_pane_heading()

func _on_pane_tile_focused(key: String) -> void:
	_add_pane_focus = key
	_sync_add_pane_heading()

func _on_pane_tile_unfocused(key: String) -> void:
	if _add_pane_focus == key:
		_add_pane_focus = ""
	_sync_add_pane_heading()

## The pointer's tile first, then the keyboard cursor's: a click that leaves
## focus behind must not pin a stale name while the user browses the grid.
func _sync_add_pane_heading() -> void:
	if _add_pane_heading == null:
		return
	var key := _add_pane_hover if _add_pane_hover != "" else _add_pane_focus
	if key == "" or not PaneTypes.ALL.has(key):
		_add_pane_heading.text = ADD_PANE_TITLE
		return
	_add_pane_heading.text = " Add a %s Pane" % PaneTypes.ALL[key]["name"]

func _sync_window_mode():
	if _wm_dropdown:
		_wm_dropdown.select(SettingsManager.cfg_window_mode)

## The one header every section wears: the heading label, the section's own
## controls in the order it passes them, then the fold toggle right-most. Adds the
## header to `host`, binds the fold to the section's `scroll`, and returns the
## header (the Panes section hides it while the list is empty).
func _add_section_header(host: VBoxContainer, section_id: String, header_name: String,
		actions: Array, scroll: ScrollContainer, expanding := false) -> HBoxContainer:
	var header := HBoxContainer.new()
	header.name = header_name
	var lbl := Label.new()
	lbl.name = section_id.capitalize() + "Heading"
	lbl.text = str(SECTION_NAMES[section_id]) + ":"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)
	for b in actions:
		header.add_child(b)
	# The fold is the header's last control: every section has one, and Panes has
	# no add button, so it is the only button there besides the close-all.
	var toggle := Button.new()
	toggle.name = section_id.capitalize() + "FoldBtn"
	toggle.focus_mode = Control.FOCUS_ALL
	toggle.pressed.connect(_toggle_section_fold.bind(section_id))
	header.add_child(toggle)
	host.add_child(header)
	_fold_sections[section_id] = {"host": host, "scroll": scroll, "toggle": toggle,
		"expanding": expanding}
	_sync_section_fold(section_id)
	return header

## Draw one section's fold from the setting, the only place the state lives, so a
## refresh, a rebuild and a second launch all read the same answer and none can
## leave the button disagreeing with the list.
##
## Hiding the list's `ScrollContainer` is what drops the section's minimum to its
## header: Godot's container sort skips a hidden child, and the scroll reserves
## nothing of its own (measured 4.7.2: a 216 px section minimum becomes 62 px,
## back to 216 when unfolded).
func _sync_section_fold(section_id: String) -> void:
	var s: Dictionary = _fold_sections.get(section_id, {})
	if s.is_empty():
		return
	var folded := SettingsManager.is_sidebar_folded(section_id)
	var section_name := str(SECTION_NAMES[section_id])
	var toggle: Button = s["toggle"]
	(s["scroll"] as Control).visible = not folded
	var host: Control = s["host"]
	var expanding := bool(s["expanding"]) and not folded
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL if expanding else Control.SIZE_FILL
	# The name goes first: `Icons.set_glyph` mirrors the button's name onto the
	# glyph Label, which is the node a screen reader reads.
	toggle.accessibility_name = ("Show the %s section" if folded else "Fold the %s section") % section_name
	toggle.tooltip_text = toggle.accessibility_name
	Icons.set_glyph(toggle, Icons.CARET_UP if folded else Icons.CARET_DOWN)

## A fold press: the setting is the state, so the write and the redraw are the
## whole handler. `SettingsManager` rejects an id this build has no section for.
func _toggle_section_fold(section_id: String) -> void:
	if not _fold_sections.has(section_id):
		return
	SettingsManager.set_sidebar_folded(section_id,
		not SettingsManager.is_sidebar_folded(section_id))
	_sync_section_fold(section_id)

## Every section list (workspaces, profiles, panes) shares these: a
## five-row visibility cap before an inner scrollbar, one accent color for
## the active row, and measured (not hard-coded) section heights.
const SECTION_MAX_VISIBLE_ROWS = 5

## The three foldable sections' display names, keyed by the ids
## `SettingsManager.SIDEBAR_SECTIONS` persists. A section not in this table has
## no fold.
const SECTION_NAMES := {"workspaces": "Workspaces", "profiles": "Profiles", "panes": "Panes"}

## One entry per foldable section: `host` (the VBox whose combined minimum is the
## section's height), `scroll` (the list container the fold hides), `toggle` (the
## header's right-most button) and `expanding` (whether the section takes the
## height the sections above leave over, which a fold must give back).
var _fold_sections: Dictionary = {}

## The profiles section's catalog hint: with no installed plugin profile the
## only shipped layout is the built-in, and the tool layouts live in plugin
## repos listed on this page.
const PLUGINS_CATALOG_URL := "https://gpty.dev/plugins/"
const CATALOG_HINT_TEXT := "More layouts \u2192"

func _add_workspace_section(parent: VBoxContainer):
	var section = VBoxContainer.new(); section.name = "WorkspaceSection"

	var add_btn = Button.new(); add_btn.name = "AddWorkspaceBtn"
	add_btn.tooltip_text = "New workspace (max 8)"
	Icons.icon_button(add_btn, Icons.ADD, "New workspace (max 8)")
	add_btn.pressed.connect(func(): request_workspace_add.emit())
	_workspaces_add_btn = add_btn

	# The section's close-all: visible only while a workspace exists, and it
	# asks in place (check/cross) before the running-work walk.
	var all_btn = Button.new(); all_btn.name = "WorkspacesCloseAllBtn"
	Icons.icon_button(all_btn, Icons.DELETE, "Close all workspaces")
	all_btn.tooltip_text = "Close all workspaces"
	all_btn.visible = false
	all_btn.pressed.connect(func(): _request_close_confirm("workspaces_all", 0, "", null, all_btn))
	_workspaces_close_all_btn = all_btn

	var confirm := _confirm_row("WorkspacesCloseAllConfirmOk",
		"WorkspacesCloseAllConfirmCancel", "all workspaces")
	confirm.name = "WorkspacesCloseAllConfirm"
	_workspaces_confirm = confirm

	# No fixed cap on visible rows beyond 5: five rows fully shown, an
	# inner scrollbar appears only when there are more.
	var sc = ScrollContainer.new(); sc.name = "WorkspaceScroll"

	_workspace_list = VBoxContainer.new(); _workspace_list.name = "WorkspaceList"
	_workspace_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_workspace_list)

	_add_section_header(section, "workspaces", "WorkspaceHeader",
		[add_btn, all_btn, confirm], sc)
	section.add_child(sc)
	parent.add_child(section)

func update_workspace_list(names: Array[String], active: int, cwds: Array[String] = []):
	if not _workspace_list: return
	_ws_names.assign(names)
	_ws_active = active
	_ws_cwds.assign(cwds)
	var content := _workspace_signature()
	if _ws_drawn and _pending_close.is_empty() and content == _ws_rendered:
		_apply_workspace_state()
		return
	_ws_drawn = true
	_ws_rendered = content
	_render_workspaces()

## One string per row, so equal models compare equal without a rebuild. The fields
## are joined with U+001F, which a name or a path cannot contain: a printable
## separator would let `a|b` + `c` collide with `a` + `b|c`.
func _workspace_signature() -> Array[String]:
	var sig: Array[String] = []
	for i in _ws_names.size():
		sig.append("%s\u001f%s" % [_ws_names[i], str(_ws_cwds[i]) if i < _ws_cwds.size() else ""])
	return sig

## Move the list's state without touching its rows: the active accent and the
## header's buttons. A switch between workspaces whose names and directories did
## not change costs this instead of five rows of control creation.
func _apply_workspace_state() -> void:
	for row in _workspace_list.get_children():
		if row.is_queued_for_deletion():
			continue
		var btn := row.get_child(0) as Button
		if btn != null:
			_apply_row_accent(btn, int(row.get_meta("workspace_index", -1)) == _ws_active)
	_sync_workspace_header()

## Rebuild the workspace rows from the stored lists, then sync the header. A
## pending row question survives a rebuild only while its target is still there.
func _render_workspaces():
	if not _workspace_list: return
	_validate_workspace_pending()
	for c in _workspace_list.get_children(): c.queue_free()
	var rows: Array[Control] = []
	for i in _ws_names.size():
		var cwd := str(_ws_cwds[i]) if i < _ws_cwds.size() else ""
		var row := _make_workspace_row(i, _ws_names[i], i == _ws_active, cwd)
		_workspace_list.add_child(row)
		rows.append(row)
	var sc = _workspace_list.get_parent() as ScrollContainer
	if sc:
		sc.custom_minimum_size.y = _measured_section_height(_workspace_list, rows)
	_sync_workspace_header()

func _validate_workspace_pending():
	match str(_pending_close.get("kind", "")):
		"workspace":
			var idx := int(_pending_close.get("index", -1))
			if idx < 0 or idx >= _ws_names.size() \
					or _ws_names[idx] != str(_pending_close.get("name", "")):
				_pending_close.clear()
		"workspaces_all":
			if _ws_names != _pending_close.get("snapshot", []):
				_pending_close.clear()

func _sync_workspace_header():
	var all := str(_pending_close.get("kind", "")) == "workspaces_all"
	var any := not _ws_names.is_empty()
	_workspaces_add_btn.visible = not all
	_workspaces_close_all_btn.visible = not all and any
	_workspaces_confirm.visible = all and any
	if all and any:
		_pending_close["ok"] = _workspaces_confirm.get_child(0)

func _render_panes():
	if not _pane_list: return
	_validate_pane_pending()
	for c in _pane_list.get_children(): c.queue_free()
	var rows: Array[Control] = []
	for body in _pane_items:
		var row := _make_pane_row(body, body == _pane_active)
		_pane_list.add_child(row)
		rows.append(row)
	# The same five-row cap the workspace and profile lists take. Without a
	# minimum the list is only the pixels left over after the fixed blocks
	# above it - 33 px of a 500 px window, one row cut in half - and the outer
	# column would never need to scroll.
	var sc := _pane_list.get_parent() as ScrollContainer
	if sc:
		sc.custom_minimum_size.y = _measured_section_height(_pane_list, rows)
	_sync_pane_header()

func _validate_pane_pending():
	match str(_pending_close.get("kind", "")):
		"pane":
			var body = _pending_close.get("body")
			if body == null or not is_instance_valid(body) or not _pane_items.has(body):
				_pending_close.clear()
		"panes_all":
			if _pane_items.is_empty() or _pane_items != _pending_close.get("snapshot", []):
				_pending_close.clear()

func _sync_pane_header():
	var all := str(_pending_close.get("kind", "")) == "panes_all"
	var any := not _pane_items.is_empty()
	_pane_heading.visible = any
	_panes_close_all_btn.visible = any and not all
	_panes_confirm.visible = any and all
	if all and any:
		_pending_close["ok"] = _panes_confirm.get_child(0)

func _pending_workspace(idx: int, ws_name: String) -> bool:
	return str(_pending_close.get("kind", "")) == "workspace" \
		and int(_pending_close.get("index", -1)) == idx \
		and str(_pending_close.get("name", "")) == ws_name

func _pending_pane(body: Control) -> bool:
	return str(_pending_close.get("kind", "")) == "pane" \
		and _pending_close.get("body") == body

## The one inline question: set the target, re-render both sections (so an
## older question is replaced, not left on screen), and focus the check.
func _request_close_confirm(kind: String, index := 0, ws_name := "",
		body: Control = null, source: Button = null):
	_pending_close = {"kind": kind, "index": index, "name": ws_name,
		"body": body, "source": source}
	if kind == "workspaces_all":
		_pending_close["snapshot"] = _ws_names.duplicate()
	elif kind == "panes_all":
		_pending_close["snapshot"] = _pane_items.duplicate()
	_render_workspaces()
	_render_panes()
	_render_profiles()
	_focus_pending_confirm()

func _accept_close_confirm():
	if _pending_close.is_empty():
		return
	var state := _pending_close.duplicate()
	_pending_close.clear()
	_render_workspaces()
	_render_panes()
	_render_profiles()
	match str(state.get("kind", "")):
		"workspace":
			request_workspace_close.emit(int(state.get("index", -1)))
		"pane":
			var body = state.get("body")
			if body != null and is_instance_valid(body):
				request_close.emit(body)
		"workspaces_all":
			request_workspaces_close_all.emit()
		"panes_all":
			request_reset.emit()
		"plugin_profile":
			request_profile_uninstall.emit(str(state.get("plugin_id", "")))

func _cancel_close_confirm():
	if _pending_close.is_empty():
		return
	var state := _pending_close.duplicate()
	_pending_close.clear()
	_render_workspaces()
	_render_panes()
	_render_profiles()
	_focus_close_trigger(state)

func _focus_pending_confirm():
	var ok = _pending_close.get("ok")
	if ok is Button and is_instance_valid(ok) and ok.is_visible_in_tree():
		ok.grab_focus()

## Two glyph buttons replacing a row's actions: check confirms, cross cancels.
## The first child is the check; `_pending_close.ok` points at it for focus.
func _confirm_row(ok_name: String, cancel_name: String, what: String,
		action := "closing") -> HBoxContainer:
	var box := HBoxContainer.new()
	box.name = "CloseConfirm"
	box.add_theme_constant_override("separation", UiTokens.SPACE_XS)
	var ok := Button.new()
	ok.name = ok_name
	Icons.icon_button(ok, Icons.CHECK, "Confirm %s %s" % [action, what])
	ok.tooltip_text = "Confirm %s %s" % [action, what]
	ok.pressed.connect(_accept_close_confirm)
	box.add_child(ok)
	var no := Button.new()
	no.name = cancel_name
	Icons.icon_button(no, Icons.CLOSE, "Cancel %s %s" % [action, what])
	no.tooltip_text = "Cancel %s %s" % [action, what]
	no.pressed.connect(_cancel_close_confirm)
	box.add_child(no)
	box.visible = false
	return box

func _focus_close_trigger(state: Dictionary):
	match str(state.get("kind", "")):
		"workspace":
			var idx := int(state.get("index", -1))
			for row in _workspace_list.get_children():
				if row.is_queued_for_deletion() or int(row.get_meta("workspace_index", -1)) != idx:
					continue
				var btn := row.get_node_or_null("WorkspaceCloseBtn") as Button
				if btn: btn.grab_focus()
		"pane":
			for row in _pane_list.get_children():
				if row.is_queued_for_deletion() or row.get_meta("body") != state.get("body"):
					continue
				var btn := row.get_node_or_null("ClosePaneRowBtn") as Button
				if btn: btn.grab_focus()
		"workspaces_all":
			_workspaces_close_all_btn.grab_focus()
		"panes_all":
			_panes_close_all_btn.grab_focus()
		"plugin_profile":
			var profile_name := str(state.get("profile_name", ""))
			for row in _profile_list.get_children():
				if row.is_queued_for_deletion() \
						or str(row.get_meta("profile_name", "")) != profile_name:
					continue
				var btn := row.get_node_or_null("ProfileUninstallBtn") as Button
				if btn: btn.grab_focus()

## Sum the real combined minimum heights of `rows` (plus the list's
## separation), capped at SECTION_MAX_VISIBLE_ROWS fully-visible rows. No
## hard-coded row heights — theme metrics decide, so a row can never be
## truncated.
func _measured_section_height(list: VBoxContainer, rows: Array[Control]) -> int:
	var separation := float(list.get_theme_constant("separation"))
	var shown := mini(rows.size(), SECTION_MAX_VISIBLE_ROWS)
	var total := 0.0
	for i in shown:
		total += rows[i].get_combined_minimum_size().y
	if shown > 0:
		total += separation * (shown - 1)
	return int(total)

## Style a section-row button as the active row (accent text + pressed
## look) or clear it. Shared by workspace, profile, and pane rows so the
## active-row semantics stay identical across sections.
func _apply_row_accent(btn: Button, active: bool):
	# `button_pressed` only sticks on toggle-mode buttons; row state is
	# managed by this helper on every refresh, so clicks never corrupt it.
	btn.toggle_mode = true
	btn.button_pressed = active
	# The accent is a theme role, not three overrides: a pressed button resolves
	# text from font_pressed_color, so the variation carries all three states and
	# a palette switch re-colours the row without this helper running.
	btn.theme_type_variation = UiTheme.ACCENT_BUTTON if active else &""

func _make_workspace_row(idx: int, ws_name: String, is_active: bool, cwd := "") -> HBoxContainer:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTokens.SPACE_XS)
	row.set_meta("workspace_index", idx)

	var dir_hint := cwd if cwd != "" else "default (gpty's own directory)"
	var btn = _make_sidebar_button(ws_name)
	btn.tooltip_text = "Switch workspace (double-click to rename)\nWorking directory: %s" % dir_hint
	_apply_row_accent(btn, is_active)
	btn.pressed.connect(func(): request_workspace_switch.emit(idx))
	btn.gui_input.connect(func(ev: InputEvent): _on_workspace_row_input(idx, btn, ev))
	row.add_child(btn)

	# The row's actions are one menu (directory, clear) and the discard. The
	# folder is no longer its own button: the menu carries it with its icon and
	# the current path in the tooltip. Close is always the right-most glyph,
	# including on the last workspace — closing it is a real state now.
	var more_btn := _make_row_action_button(Icons.MORE, "More workspace actions")
	more_btn.name = "WorkspaceMoreBtn"
	more_btn.pressed.connect(func(): request_workspace_menu.emit(idx, more_btn))
	row.add_child(more_btn)

	var close_btn := _make_row_action_button(Icons.DELETE, "Close workspace")
	close_btn.name = "WorkspaceCloseBtn"
	close_btn.pressed.connect(func(): _request_close_confirm("workspace", idx, ws_name, null, close_btn))
	row.add_child(close_btn)

	var confirm := _confirm_row("CloseConfirmOk", "CloseConfirmCancel", "'%s'" % ws_name)
	row.add_child(confirm)
	var pending := _pending_workspace(idx, ws_name)
	more_btn.visible = not pending
	close_btn.visible = not pending
	confirm.visible = pending
	if pending:
		_pending_close["ok"] = confirm.get_child(0)
	return row

## Swap a row label Button for an inline LineEdit; commits exactly once
## (Enter, blur, or Escape — Escape restores the original name). The
## once-only guard matters: after a commit rebuilds the list, the freed
## LineEdit still fires focus_exited, and a second commit on a freed
## object corrupted the rebuild (rows vanished until restart).
func _begin_inline_rename(btn: Button, on_commit: Callable):
	var row := btn.get_parent()
	for c in row.get_children():
		var open := c as LineEdit
		if open != null and open.name == "InlineRename" \
				and not open.is_queued_for_deletion():
			open.grab_focus()
			open.select_all()
			return

	var le = LineEdit.new()
	le.name = "InlineRename"
	le.text = btn.text
	le.custom_minimum_size.y = btn.size.y
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(le)
	btn.visible = false
	le.grab_focus()
	le.select_all()
	var committed := [false]
	le.text_submitted.connect(func(t: String):
		if committed[0]:
			return
		committed[0] = true
		on_commit.call(t)
		_finish_inline_rename(btn, le)
	)
	le.focus_exited.connect(func():
		if committed[0] or not is_instance_valid(le):
			return
		committed[0] = true
		on_commit.call(le.text)
		_finish_inline_rename(btn, le)
	)
	le.gui_input.connect(func(e2: InputEvent):
		if e2 is InputEventKey and e2.pressed and e2.keycode == KEY_ESCAPE:
			if committed[0]:
				return
			committed[0] = true
			on_commit.call(btn.text)
			_finish_inline_rename(btn, le)
	)

## End the inline edit: remove the editor and, when its row still exists,
## show the label again. A commit that changed the name rebuilds the list and
## queues the old row for deletion; restoring its label then would paint the
## old row beside the new one for a frame, so only a surviving row is restored.
func _finish_inline_rename(btn: Button, le: LineEdit) -> void:
	if not is_instance_valid(le):
		return
	var row := le.get_parent()
	le.visible = false
	le.queue_free()
	if is_instance_valid(btn) and is_instance_valid(row) \
			and not row.is_queued_for_deletion():
		btn.visible = true

func _start_workspace_rename(idx: int, btn: Button) -> void:
	_begin_inline_rename(btn, func(t: String): request_workspace_rename.emit(idx, t))

## The workspace More menu's Rename: the same inline editor double-click opens.
func begin_workspace_rename(idx: int) -> void:
	if _workspace_list == null:
		return
	for row in _workspace_list.get_children():
		if row.is_queued_for_deletion() or int(row.get_meta("workspace_index", -1)) != idx:
			continue
		var btn := row.get_child(0) as Button
		if btn != null:
			_start_workspace_rename(idx, btn)
		return

func _on_workspace_row_input(idx: int, btn: Button, ev: InputEvent):
	if not (ev is InputEventMouseButton):
		return
	if not ev.double_click or ev.button_index != MOUSE_BUTTON_LEFT:
		return
	_start_workspace_rename(idx, btn)

func _add_pane_list_ui(v: VBoxContainer):
	var section = VBoxContainer.new(); section.name = "PaneSection"

	# The section's close-all: visible only while a pane exists. The check
	# that follows it emits the same reset the old footer button did.
	var all_btn = Button.new(); all_btn.name = "PanesCloseAllBtn"
	Icons.icon_button(all_btn, Icons.DELETE, "Close all panes in this workspace")
	all_btn.tooltip_text = _with_chord("Close every pane in this workspace", "app:reset_workspace")
	all_btn.pressed.connect(func(): _request_close_confirm("panes_all", 0, "", null, all_btn))
	_panes_close_all_btn = all_btn

	var confirm := _confirm_row("PanesCloseAllConfirmOk",
		"PanesCloseAllConfirmCancel", "all panes")
	confirm.name = "PanesCloseAllConfirm"
	_panes_confirm = confirm

	var sc = ScrollContainer.new()
	sc.name = "PaneScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_pane_list = VBoxContainer.new()
	_pane_list.name = "PaneList"
	_pane_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_pane_list)

	_pane_heading = _add_section_header(section, "panes", "PaneHeader",
		[all_btn, confirm], sc, true)
	section.add_child(sc)
	# Hidden until the list has a row: a workspace that never restores (a trust
	# dialog is waiting) must not show a section title over nothing.
	# `update_pane_list` is the one switch.
	_pane_heading.visible = false
	v.add_child(section)

func _add_collapsed_button():
	var btn = Button.new()
	btn.name = "SidebarCollapsedBtn"
	btn.custom_minimum_size = Vector2(18, 22)
	Icons.icon_button(btn, Icons.EXPAND, "Show sidebar")
	btn.offset_left = 1; btn.offset_top = 2
	btn.offset_right = 19; btn.visible = false
	btn.pressed.connect(_toggle_sidebar)
	add_child(btn)

func _toggle_sidebar():
	var on = (offset_right != WIDTH)
	var coll = get_node_or_null("SidebarCollapsedBtn")
	if on:
		offset_right = WIDTH; bg.size.x = WIDTH
		if _content_scroll: _content_scroll.show()
		if _title_label: _title_label.visible = true
		if _collapse_arrow: _collapse_arrow.visible = true
		if coll: coll.visible = false
	else:
		offset_right = COLLAPSED_WIDTH; bg.size.x = COLLAPSED_WIDTH
		if _content_scroll: _content_scroll.hide()
		if _title_label: _title_label.visible = false
		if _collapse_arrow: _collapse_arrow.visible = false
		if coll: coll.visible = true
	toggled.emit()

func _add_profile_section(parent: VBoxContainer):
	var section = VBoxContainer.new(); section.name = "ProfileSection"

	var save_btn = Button.new(); save_btn.name = "SaveProfileBtn"
	save_btn.tooltip_text = "Save current layout as profile"
	Icons.icon_button(save_btn, Icons.ADD, "Save current layout as profile")
	save_btn.pressed.connect(func(): request_save_profile.emit())

	var sc = ScrollContainer.new(); sc.name = "ProfileScroll"

	_profile_list = VBoxContainer.new(); _profile_list.name = "ProfileList"
	_profile_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_profile_list)

	_add_section_header(section, "profiles", "ProfileHeader", [save_btn], sc)
	section.add_child(sc)
	parent.add_child(section)

func update_profile_list(profiles: Array[Dictionary], active_name := ""):
	if not _profile_list: return
	_profile_items.assign(profiles)
	_profile_active_name = active_name
	var content := _profile_signature()
	if _profile_drawn and _pending_close.is_empty() and content == _profile_rendered:
		_apply_profile_state()
		return
	_profile_drawn = true
	_profile_rendered = content
	_render_profiles()

## Everything a profile row shows or binds, in order: the label, its tooltip, and
## what the trailing buttons do. The active name is the accent, not the content.
func _profile_signature() -> Array[String]:
	var sig: Array[String] = []
	for i in _profile_items.size():
		var p: Dictionary = _profile_items[i]
		sig.append("%s\u001f%s\u001f%s\u001f%s\u001f%s\u001f%d" % [
			str(p.get("name", "Unnamed")), str(p.get("description", "")),
			"1" if p.get("plugin", false) == true else "0",
			str(p.get("plugin_id", "")), str(p.get("revision", "")),
			int(p.get("_user_index", i))])
	return sig

func _apply_profile_state() -> void:
	for row in _profile_list.get_children():
		# The catalog hint is a row without a profile name: it is never accented.
		if row.is_queued_for_deletion() or not row.has_meta("profile_name"):
			continue
		var btn := row.get_child(0) as Button
		if btn != null:
			_apply_row_accent(btn, str(row.get_meta("profile_name")) == _profile_active_name)

func _render_profiles():
	if not _profile_list: return
	_validate_profile_pending()
	for c in _profile_list.get_children(): c.queue_free()
	var rows: Array[Control] = []
	for i in _profile_items.size():
		var p = _profile_items[i]
		var p_name = str(p.get("name", "Unnamed"))
		# `== true` rather than a typed cast: a user profile comes from a
		# hand-editable file, and a stray value must read as "not a plugin"
		# instead of raising on the assignment.
		var is_plugin: bool = p.get("plugin", false) == true
		var row = HBoxContainer.new()
		row.set_meta("profile_name", p_name)
		var btn = _make_sidebar_button(p_name)
		btn.tooltip_text = str(p.get("description", ""))
		_apply_row_accent(btn, p_name == _profile_active_name)
		# Toggle-mode buttons flip on click; re-assert so a canceled
		# activation dialog doesn't leave a phantom pressed row.
		btn.pressed.connect(func():
			request_profile.emit(p_name)
			_apply_row_accent(btn, p_name == _profile_active_name)
		)
		row.add_child(btn)

		# The row's other gesture: open this profile in a workspace of its own
		# and leave the active one alone. A modifier click would cost no space,
		# but nothing on screen would advertise it, and the two actions differ
		# in whether they replace live panes - so the destructive-safe one is
		# the plain click on the name, and this glyph is the visible second
		# action (the workspace tab metaphor: a new tab from a template).
		var new_ws_btn := _make_row_action_button(
			Icons.NEW_WORKSPACE, "Open '%s' in a new workspace" % p_name)
		new_ws_btn.name = "ProfileNewWorkspaceBtn"
		new_ws_btn.pressed.connect(func(): request_profile_in_new_workspace.emit(p_name))
		row.add_child(new_ws_btn)
		if is_plugin:
			# An installed plugin owns its profiles: they arrive and are
			# replaced with the plugin. The row says where it came from and
			# offers the plugin's one destructive action, uninstall.
			btn.tooltip_text = _plugin_provenance(p)
			var plugin_id := str(p.get("plugin_id", ""))
			if plugin_id != "":
				var uninstall_btn := _make_row_action_button(
					Icons.DELETE, "Uninstall plugin '%s' and everything it installed" % plugin_id)
				uninstall_btn.name = "ProfileUninstallBtn"
				uninstall_btn.pressed.connect(func():
					_request_profile_uninstall_confirm(p_name, plugin_id, uninstall_btn))
				row.add_child(uninstall_btn)
				var confirm := _confirm_row("ProfileUninstallConfirmOk",
					"ProfileUninstallConfirmCancel", "plugin '%s'" % plugin_id, "uninstalling")
				row.add_child(confirm)
				var pending := _pending_profile(p_name)
				new_ws_btn.visible = not pending
				uninstall_btn.visible = not pending
				confirm.visible = pending
				if pending:
					_pending_close["ok"] = confirm.get_child(0)
		else:
			var user_index := int(p.get("_user_index", i))
			btn.tooltip_text += "\nDouble-click to rename"
			btn.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.double_click \
						and ev.button_index == MOUSE_BUTTON_LEFT:
					_begin_inline_rename(btn, func(t: String):
						request_profile_rename.emit(user_index, t))
			)
			var x = Button.new()
			Icons.icon_button(x, Icons.DELETE, "Delete profile")
			x.pressed.connect(func(): request_delete_profile.emit(user_index))
			row.add_child(x)
		_profile_list.add_child(row)
		rows.append(row)

	# The catalog hint is the section's last row, always: with installed
	# plugin profiles the section is where the user finds new ones, so the
	# entry point must not disappear the moment the first plugin lands. It
	# counts as a row for the height cap like any other.
	var hint_row := _make_catalog_hint_row()
	_profile_list.add_child(hint_row)
	rows.append(hint_row)

	# Show up to SECTION_MAX_VISIBLE_ROWS rows at full measured height; a
	# scrollbar appears only beyond that.
	var sc := _profile_list.get_parent() as ScrollContainer
	if sc: sc.custom_minimum_size.y = _measured_section_height(_profile_list, rows)

func _pending_profile(profile_name: String) -> bool:
	return str(_pending_close.get("kind", "")) == "plugin_profile" \
		and str(_pending_close.get("profile_name", "")) == profile_name

## A profile-uninstall question survives a model refresh only while the
## plugin row it named is still there.
func _validate_profile_pending():
	if str(_pending_close.get("kind", "")) != "plugin_profile":
		return
	var profile_name := str(_pending_close.get("profile_name", ""))
	for p in _profile_items:
		if p is Dictionary and p.get("plugin", false) == true \
				and str(p.get("name", "")) == profile_name:
			return
	_pending_close.clear()

func _request_profile_uninstall_confirm(profile_name: String, plugin_id: String,
		source: Button):
	_pending_close = {"kind": "plugin_profile", "profile_name": profile_name,
		"plugin_id": plugin_id, "source": source}
	_render_workspaces()
	_render_panes()
	_render_profiles()
	_focus_pending_confirm()

## Where a plugin-sourced profile came from. The second sentence is the
## reason such a row has no rename or delete: the plugin replaces it whole.
func _plugin_provenance(profile: Dictionary) -> String:
	return "Installed from %s@%s" % [
		str(profile.get("plugin_id", "")),
		str(profile.get("revision", "")),
	] + " — plugin profiles follow the plugin\nTrash uninstalls the plugin and every profile and concept it ships"

## The profiles section's catalog hint row. Same row shape as a profile row
## (a Button inside a row container) so the section's measured height sees
## it; pressing it opens the registry page.
func _make_catalog_hint_row() -> HBoxContainer:
	var row = HBoxContainer.new()
	var btn = _make_sidebar_button(CATALOG_HINT_TEXT)
	btn.name = "CatalogHintBtn"
	btn.tooltip_text = "Browse the plugin registry"
	btn.pressed.connect(func(): ExternalLink.open(PLUGINS_CATALOG_URL))
	row.add_child(btn)
	return row
