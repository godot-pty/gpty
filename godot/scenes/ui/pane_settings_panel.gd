extends OverlayPanel
class_name PaneSettingsPanel
# Type-aware pane settings overlay. Builds a shared shell (header, close, ESC)
# and delegates content to the target pane's _build_pane_settings_ui().

## Emitted after the target pane's settings were applied. The panel has no
## view of the workspace, so anything the apply can invalidate across panes —
## `attachment_id` above all, which is how IPC addresses a pane — is the
## owner's to re-check. `settings` is the gathered dict that was applied, and
## `previous_id` the pane's id before the apply, so the owner can re-key
## per-pane state (the env store) when the id changed.
signal settings_applied(body: Control, settings: Dictionary, previous_id: String)

## The card's design size. A smaller window clamps it (`fit_card`), and the
## content scroll container inside it takes the slack the same way a Settings
## tab does.
const CARD_SIZE := Vector2(380, 420)

var _target: Control
var _debounce_timer: Timer
var _gather_func: Callable
## The card, so a window resize while the panel is open re-clamps it.
var _card: Panel = null

func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

## The card is rebuilt on every open, so only a resize while the panel is open
## needs the clamp recomputed.
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _card != null:
		fit_card(_card, CARD_SIZE)

## `open_for` has just rebuilt the card at its design size; this is where the
## window it has to fit in is known.
func _before_open() -> void:
	fit_card(_card, CARD_SIZE)

func _process(_delta: float):
	# The popup is a shared workspace-level overlay: its target pane can be
	# torn down through kill, type swap, reset, workspace close, or layout
	# restore without the popup being told. A freed target makes every
	# interaction a script error (dead popup). Auto-close as soon as the
	# target dies — covers every pane type and teardown path.
	if visible and (_target == null or not is_instance_valid(_target)):
		close()

func open_for(body: Control):
	_target = body
	if _target == null or not is_instance_valid(_target):
		close()
		return
	_build_ui()
	# Godot 4 GUI input picking ignores z_index: among siblings, the LAST
	# child in tree order receives clicks first (reverse tree order).
	# Rendering DOES honor z_index, which is why the popup drew on top
	# while later-added workspace grids/sidebar/status bar ate its input.
	# Move to the end of the workspace's children so it is topmost for
	# both picking and rendering while open.
	if get_parent():
		get_parent().move_child(self, -1)
	open()

func _after_close() -> void:
	_target = null
	_gather_func = Callable()

func _build_ui():
	# Free immediately: queue_free would leave the previous build's subtree
	# (with its stale target wiring) alive and interactive for a frame when
	# reopening for another pane.
	for c in get_children():
		c.free()
	_card = null

	var cc = CenterContainer.new()
	add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg = Panel.new()
	bg.name = "Card"
	# The design size; clamped to the window on open and on a resize while open
	# (`fit_card`), because `open_for` builds this card while the panel is still
	# hidden.
	_card = bg
	_card.custom_minimum_size = CARD_SIZE
	cc.add_child(bg)

	var mc = MarginContainer.new()
	UiTheme.margins(mc, UiTokens.SPACE_XXL)
	bg.add_child(mc)
	mc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	mc.add_child(v)

	# Header with close button
	var h = HBoxContainer.new()
	var t = Label.new(); t.text = "Pane Settings"
	t.add_theme_font_size_override("font_size", UiTokens.FS_TITLE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(t)
	var x = Button.new()
	Icons.icon_button(x, Icons.CLOSE, "Close pane settings")
	x.pressed.connect(close); h.add_child(x)
	v.add_child(h)
	v.add_child(HSeparator.new())

	# Scrollable content area — filled by the pane type
	var sc = ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)

	var content = _target._build_pane_settings_ui(self)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)

	# Debounce timer — fires _apply_to_target after user stops typing
	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true; _debounce_timer.wait_time = 0.15
	_debounce_timer.timeout.connect(_apply_to_target)
	bg.add_child(_debounce_timer)

func _apply_to_target():
	if _target == null or not is_instance_valid(_target): return
	if not _gather_func.is_valid(): return
	var settings: Dictionary = _gather_func.call()
	var previous_id: String = str(_target.attachment_id)
	_target.apply_settings(settings)
	settings_applied.emit(_target, settings, previous_id)
