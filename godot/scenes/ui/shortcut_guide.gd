class_name ShortcutGuide
extends VBoxContainer
## The empty workspace's guide: a title, an animated keycap that demonstrates
## the spawn bindings, a primary action, and every registered shortcut as
## grouped cards.
##
## Data-driven on purpose: the rows, the hero steps and the primary action come
## from callables, so a later guided tour can reuse the surface with its own
## step list, and a test can drive it with fixtures. The rows are re-read on
## every show (`refresh`), because a chord is only known after the workspace
## registers its bindings.
##
## `fit_width` owns the responsive rule: the guide is a centred column capped at
## MAX_WIDTH, and the atlas splits into two columns only when the grid can hold
## them. Below that it is one column; the caller owns the ScrollContainer.
##
## The animation is a wall clock (`_process`), so `pin_animation()` exists for
## the capture harness: it sets the first frame (step 0, phase 0) and stops the
## clock, the same rule `AgentBadge` follows. No colour is cached: the ripple and
## every theme role are read at draw time through `UiPalette`/`UiTheme`.

signal new_pane_requested(type_name: String)

## The guide's width is the grid width minus this allowance: the caller's 16 px
## side margins plus room for a scrollbar, so the column never has to clip.
const WIDTH_ALLOWANCE := 48.0
const MIN_WIDTH := 280.0
const MAX_WIDTH := 760.0
## The available grid width at which two atlas columns fit with readable rows.
const TWO_COLUMN_MIN := 700.0
const CARD_MIN_WIDTH := 260.0
const CHORD_COLUMN := 104.0
const HERO_HEIGHT := 122.0
const HERO_CYCLE := 3.0
const PRESS_TIME := 0.22
const RIPPLE_TIME := 0.9
const PULSE_SCALE := 0.05

## The pulse behind the keycap. A private Control because a ring is geometry, not
## text: there is nothing for an assistive technology to read here, and the same
## step is named by the atlas below. The phase is set by the guide's clock.
class Ripple extends Control:
	var phase := -1.0
	var target: Control = null

	func _draw() -> void:
		if target == null or not is_instance_valid(target):
			return
		if phase < 0.0 or phase > ShortcutGuide.RIPPLE_TIME:
			return
		var t := phase / ShortcutGuide.RIPPLE_TIME
		var centre := target.get_global_rect().get_center() - get_global_rect().position
		var colour: Color = UiPalette.active().ACCENT
		colour.a = 0.45 * (1.0 - t)
		draw_arc(centre, 26.0 + 90.0 * t, 0.0, TAU, 40, colour, 2.0, true)

var _rows: Array = []
var _steps: Array = []
var _primary: Dictionary = {}
var _rows_of: Callable
var _steps_of: Callable
var _primary_of: Callable
var _step := 0
var _phase := 0.0
var _columns := 1
var _pinned := false

var _title: Label
var _subtitle: Label
var _hero: Control
var _hero_keycap: PanelContainer
var _hero_chord: Label
var _hero_caption: Label
var _ripple: Ripple
var _primary_row: HBoxContainer
var _primary_button: Button
var _primary_chip: PanelContainer
var _primary_chord: Label
var _atlas_heading: Label
var _atlas: HBoxContainer
var _atlas_columns: Array[VBoxContainer] = []

func _init() -> void:
	add_theme_constant_override("separation", UiTokens.SPACE_XL)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_ui()

func _ready() -> void:
	set_process(is_visible_in_tree() and not _pinned)
	refresh()

func _process(delta: float) -> void:
	_phase += delta
	if _phase >= HERO_CYCLE:
		_phase = fmod(_phase, HERO_CYCLE)
		if not _steps.is_empty():
			_step = (_step + 1) % _steps.size()
			_apply_step()
	_animate()

## Store the content providers and paint the first frame. The providers are
## called now and again on every show; a provider may return fewer rows, so the
## step index is clamped and the atlas rebuilt from scratch.
func configure(title: String, subtitle: String, rows_of: Callable, steps_of: Callable,
		primary_of: Callable) -> void:
	_title.text = title
	_subtitle.text = subtitle
	_rows_of = rows_of
	_steps_of = steps_of
	_primary_of = primary_of
	refresh()

func refresh() -> void:
	if _rows_of.is_valid():
		var raw_rows = _rows_of.call()
		_rows = raw_rows if raw_rows is Array else []
	if _steps_of.is_valid():
		var raw_steps = _steps_of.call()
		_steps = raw_steps if raw_steps is Array else []
	if _primary_of.is_valid():
		var raw_primary = _primary_of.call()
		_primary = raw_primary if raw_primary is Dictionary else {}
	_step = clampi(_step, 0, maxi(_steps.size() - 1, 0))
	_apply_step()
	_apply_primary()
	_rebuild_atlas()

## The rows the last `refresh` read, for a consumer that wants the same answer
## the surface is showing (the integration test and, later, a guided tour).
func rows() -> Array:
	return _rows.duplicate()

## The caller's responsive pass: it knows the available grid width, the guide
## only knows the thresholds. Rebuilding on a column change is what keeps the
## atlas from squeezing two unreadable columns into a narrow grid.
func fit_width(available: float) -> void:
	custom_minimum_size.x = clampf(available - WIDTH_ALLOWANCE, MIN_WIDTH, MAX_WIDTH)
	set_columns(2 if available >= TWO_COLUMN_MIN else 1)

func set_columns(count: int) -> void:
	var next := 2 if count >= 2 else 1
	if next == _columns:
		return
	_columns = next
	_rebuild_atlas()

## Capture only: set the frame a user sees when the guide appears and stop the
## wall clock, so two runs of one state are pixel-identical.
func pin_animation() -> void:
	_pinned = true
	_phase = 0.0
	_step = 0
	_apply_step()
	_animate()
	set_process(false)

## Flat rows to `[{title, rows}]`, first-seen group order. Pure so the split and
## the atlas can be tested without a scene tree.
static func group_rows(rows: Array) -> Array:
	var out: Array = []
	var index := {}
	for row in rows:
		if not row is Dictionary:
			continue
		var title := str(row.get("group", ""))
		if not index.has(title):
			index[title] = out.size()
			out.append({"title": title, "rows": []})
		var group: Dictionary = out[index[title]]
		(group["rows"] as Array).append(row)
	return out

## Split groups into at most two columns. The first column takes groups until
## adding the next would pass half the rows, so the shipped order lands as
## Workspace + New Panes (12 rows) beside Panes + Keyboard Focus + Terminal (11)
## instead of a short second column under a tall first one.
static func split_groups(groups: Array, columns: int) -> Array:
	if columns <= 1 or groups.size() <= 1:
		return [groups]
	var total := 0
	for group in groups:
		total += (group["rows"] as Array).size()
	var target := int(ceil(float(total) / 2.0))
	var first: Array = []
	var second: Array = []
	var taken := 0
	for group in groups:
		var count := (group["rows"] as Array).size()
		if second.is_empty() and taken + count <= target:
			first.append(group)
			taken += count
		else:
			second.append(group)
	if first.is_empty():
		first.append(groups[0])
		second = groups.slice(1)
	if second.is_empty():
		return [groups]
	return [first, second]

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if is_visible_in_tree():
			refresh()
			if not _pinned:
				_phase = 0.0
				_step = 0
				_apply_step()
				_animate()
				set_process(true)
		else:
			set_process(false)
	elif what == NOTIFICATION_THEME_CHANGED:
		if _ripple != null:
			_ripple.queue_redraw()

func _apply_step() -> void:
	if _steps.is_empty() or not (_steps[_step] is Dictionary):
		_hero_chord.text = ""
		_hero_caption.text = ""
		return
	var step: Dictionary = _steps[_step]
	_hero_chord.text = str(step.get("chord", ""))
	_hero_caption.text = str(step.get("label", ""))

func _apply_primary() -> void:
	var label := str(_primary.get("label", "Open a Terminal"))
	var type_name := str(_primary.get("type", ""))
	var chord := str(_primary.get("chord", ""))
	_primary_button.text = label
	_primary_row.visible = type_name != ""
	_primary_chip.visible = chord != ""
	_primary_chord.text = chord
	_primary_button.tooltip_text = label if chord == "" else "%s (%s)" % [label, chord]

## One clock drives both halves of the flare: the keycap dips and returns over
## PRESS_TIME, and the ripple expands over RIPPLE_TIME. Between them nothing is
## redrawn, so an idle empty state costs no paint work.
func _animate() -> void:
	if _phase < PRESS_TIME:
		_hero_keycap.pivot_offset = _hero_keycap.size * 0.5
		var press := sin(PI * _phase / PRESS_TIME)
		_hero_keycap.scale = Vector2.ONE * (1.0 - PULSE_SCALE * press)
	else:
		_hero_keycap.scale = Vector2.ONE
	if _phase <= RIPPLE_TIME:
		_ripple.phase = _phase
		_ripple.queue_redraw()
	elif _ripple.phase >= 0.0:
		_ripple.phase = -1.0
		_ripple.queue_redraw()

func _build_ui() -> void:
	_title = Label.new()
	_title.name = "Title"
	_title.text = "No panes"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", UiTokens.FS_HERO)
	add_child(_title)

	_subtitle = Label.new()
	_subtitle.name = "Subtitle"
	_subtitle.text = "Every shortcut the window answers, in one place."
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.theme_type_variation = UiTheme.MUTED_LABEL
	_subtitle.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	add_child(_subtitle)

	_hero = Control.new()
	_hero.name = "Hero"
	_hero.custom_minimum_size.y = HERO_HEIGHT
	_hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hero)

	_ripple = Ripple.new()
	_ripple.name = "Ripple"
	_ripple.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hero.add_child(_ripple)
	_ripple.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var centre := CenterContainer.new()
	centre.name = "HeroCenter"
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hero.add_child(centre)
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var column := VBoxContainer.new()
	column.name = "HeroColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	centre.add_child(column)

	_hero_keycap = PanelContainer.new()
	_hero_keycap.name = "HeroKeycap"
	_hero_keycap.theme_type_variation = UiTheme.RAISED_PANEL
	_hero_keycap.custom_minimum_size = Vector2(190, 48)
	_hero_keycap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_hero_keycap)

	_hero_chord = Label.new()
	_hero_chord.name = "HeroChord"
	_hero_chord.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_chord.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hero_chord.clip_text = true
	_hero_chord.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	_hero_chord.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hero_keycap.add_child(_hero_chord)

	_hero_caption = Label.new()
	_hero_caption.name = "HeroCaption"
	_hero_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_caption.theme_type_variation = UiTheme.ACCENT_LABEL
	_hero_caption.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
	_hero_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_hero_caption)

	_ripple.target = _hero_keycap

	_primary_row = HBoxContainer.new()
	_primary_row.name = "PrimaryRow"
	_primary_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_primary_row.add_theme_constant_override("separation", UiTokens.SPACE_LG)
	add_child(_primary_row)

	_primary_button = Button.new()
	_primary_button.name = "PrimaryAction"
	_primary_button.text = "Open a Terminal"
	_primary_button.pressed.connect(func(): new_pane_requested.emit(str(_primary.get("type", ""))))
	_primary_row.add_child(_primary_button)

	_primary_chip = PanelContainer.new()
	_primary_chip.name = "PrimaryChordChip"
	_primary_chip.theme_type_variation = UiTheme.RAISED_PANEL
	_primary_chip.custom_minimum_size.y = 24
	_primary_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_primary_row.add_child(_primary_chip)

	_primary_chord = Label.new()
	_primary_chord.name = "PrimaryChord"
	_primary_chord.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_primary_chord.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_primary_chord.theme_type_variation = UiTheme.ACCENT_LABEL
	_primary_chord.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
	_primary_chord.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_primary_chip.add_child(_primary_chord)

	_atlas_heading = Label.new()
	_atlas_heading.name = "AtlasHeading"
	_atlas_heading.text = "Keyboard shortcuts"
	_atlas_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_atlas_heading.theme_type_variation = UiTheme.MUTED_LABEL
	_atlas_heading.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	add_child(_atlas_heading)

	_atlas = HBoxContainer.new()
	_atlas.name = "Atlas"
	_atlas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_atlas.add_theme_constant_override("separation", UiTokens.SPACE_XL)
	add_child(_atlas)
	for i in 2:
		var atlas_column := VBoxContainer.new()
		atlas_column.name = "AtlasColumn%d" % (i + 1)
		atlas_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		atlas_column.add_theme_constant_override("separation", UiTokens.SPACE_XL)
		_atlas.add_child(atlas_column)
		_atlas_columns.append(atlas_column)

func _rebuild_atlas() -> void:
	for column in _atlas_columns:
		for child in column.get_children():
			column.remove_child(child)
			child.free()
	var groups := group_rows(_rows)
	var parts := split_groups(groups, _columns)
	for i in _atlas_columns.size():
		var column := _atlas_columns[i]
		var part: Array = parts[i] if i < parts.size() else []
		for group in part:
			column.add_child(_build_group_card(group))
		column.visible = not part.is_empty()
	_atlas.visible = not groups.is_empty()
	_atlas_heading.visible = not groups.is_empty()

func _build_group_card(group: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = UiTheme.RAISED_PANEL
	panel.custom_minimum_size.x = CARD_MIN_WIDTH
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Informational only: keeping the card mouse-transparent lets the wheel
	# reach the caller's ScrollContainer over it.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var margin := MarginContainer.new()
	UiTheme.margins(margin, UiTokens.SPACE_LG)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	margin.add_child(column)

	var heading := Label.new()
	heading.text = str(group.get("title", ""))
	heading.theme_type_variation = UiTheme.MUTED_LABEL
	heading.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(heading)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", UiTokens.SPACE_XL)
	grid.add_theme_constant_override("v_separation", UiTokens.SPACE_XS)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(grid)

	for row in group.get("rows", []):
		if not row is Dictionary:
			continue
		var chord := Label.new()
		chord.text = str(row.get("chord", ""))
		chord.custom_minimum_size.x = CHORD_COLUMN
		chord.theme_type_variation = UiTheme.ACCENT_LABEL
		chord.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
		chord.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(chord)

		var label := Label.new()
		label.text = str(row.get("label", ""))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(label)
	return panel
