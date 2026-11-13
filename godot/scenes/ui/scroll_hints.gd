class_name ScrollHints
extends Control
## The two scroll chevrons a pane overlays on its scrolling body: the
## top-right one jumps to the start of the content, the bottom-right one to the
## end.
##
## Each chevron is visible only while its direction has somewhere to go, so a
## body that fits its viewport shows neither. They are chrome, not input: no
## focus, no tab stop, and a press never reaches the pane's child, because the
## buttons take the click themselves.
##
## One widget per scrolling surface. A pane binds it to its own scroller -
## `bind_bar` for a `ScrollBar` (a `ScrollContainer`, `TextEdit`, `CodeEdit` or
## `RichTextLabel`), `bind_tree` for a `Tree`, or `bind_custom` for a surface
## with no `Range` behind it (the terminal grid). The widget syncs itself on the
## scroller's own signals; a pane whose binding has none (the tree's content,
## the terminal's offset) calls `sync()` after it changes something.

## Distance between a chevron and the body's own edge.
const EDGE := 6
## The chevron's square.
const SIZE := 24
## Why the chevrons never take the keyboard: the wheel moves the same view on
## every surface they are bound to.
const MOUSE_ONLY_REASON := "the wheel moves the same view"

var top_button: Button
var bottom_button: Button

var _region: Control = null
var _can_up := Callable()
var _can_down := Callable()
var _to_top := Callable()
var _to_bottom := Callable()
var _bar: ScrollBar = null
var _tree: Tree = null
## A bound bar or tree draws its own column at the region's right edge; the
## chevrons step left of it so the bar stays draggable end to end.
var _clears_scrollbar := false

## Build the pair over `region` and add it to `pane` as its topmost child.
##
## `region` is the scrolling body's own rect (the `ScrollContainer`, the
## `TextEdit`, the `Tree`, or the pane itself for an edge-to-edge grid), and
## `pane` is the control every position is measured inside - the same node for
## the terminal, the content host for a pane with a header above its body.
static func attach(pane: Control, region: Control,
		up_name := "Jump to the top",
		down_name := "Jump to the bottom") -> ScrollHints:
	var hints := ScrollHints.new()
	hints.name = "ScrollHints"
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints._region = region
	hints.top_button = hints._build_button(
		"ScrollToTop", Icons.CARET_UP, up_name, hints._on_top_pressed)
	hints.bottom_button = hints._build_button(
		"ScrollToBottom", Icons.CARET_DOWN, down_name, hints._on_bottom_pressed)
	hints.add_child(hints.top_button)
	hints.add_child(hints.bottom_button)
	pane.add_child(hints)
	hints.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Topmost sibling: a pane that adds its own overlays (a search strip, an
	# empty-state host) must not paint over the chevrons.
	pane.move_child(hints, -1)
	if region != null:
		region.item_rect_changed.connect(hints.sync)
		region.visibility_changed.connect(hints.sync)
	pane.resized.connect(hints.sync)
	hints.sync()
	return hints

## The chevron's shape: a 24x24 icon button that never takes focus and always
## declares why the keyboard route is elsewhere (the focus audit counts an
## undeclared one as an oversight).
func _build_button(node_name: String, glyph: String, text: String,
		handler: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.visible = false
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = text
	KeyboardFocus.declare_mouse_only(button, MOUSE_ONLY_REASON)
	Icons.icon_button(button, glyph, text)
	button.size = Vector2(SIZE, SIZE)
	button.pressed.connect(handler)
	return button

## Bind to a scroll bar: a `ScrollContainer`'s, a `TextEdit`/`CodeEdit`'s, or a
## `RichTextLabel`'s own bar. `changed` fires when the range grows (content
## arriving, a pane resized) and `value_changed` when it moves, so the pair
## follows both without polling.
func bind_bar(bar: ScrollBar) -> void:
	_unbind()
	_bar = bar
	_clears_scrollbar = true
	_can_up = Callable(self, "_bar_can_up")
	_can_down = Callable(self, "_bar_can_down")
	_to_top = Callable(self, "_bar_to_top")
	_to_bottom = Callable(self, "_bar_to_bottom")
	if _bar != null:
		_bar.value_changed.connect(_on_bar_value_changed)
		_bar.changed.connect(_on_bar_changed)
	sync()

## Bind to a `Tree`. Its rows are not a `Range`: the ends come from the tree's
## scroll position and the item rects, which the tree computes from its items
## (so they are correct before the first draw). The pane calls `sync()` after a
## rebuild or a lazy populate, because the tree emits nothing for those.
func bind_tree(tree: Tree) -> void:
	_unbind()
	_tree = tree
	_clears_scrollbar = true
	_can_up = Callable(self, "_tree_can_up")
	_can_down = Callable(self, "_tree_can_down")
	_to_top = Callable(self, "_tree_to_top")
	_to_bottom = Callable(self, "_tree_to_bottom")
	if _tree != null:
		_tree.item_collapsed.connect(_on_tree_item_collapsed)
	sync()

## Bind to a surface the caller owns: the four callables answer "can it move
## this way" and "move it", and the pane syncs when something changed.
func bind_custom(can_up: Callable, can_down: Callable,
		to_top: Callable, to_bottom: Callable) -> void:
	_unbind()
	_clears_scrollbar = false
	_can_up = can_up
	_can_down = can_down
	_to_top = to_top
	_to_bottom = to_bottom
	sync()

## Re-read the bound scroller and show exactly the chevrons that have content
## to reach. Cheap: two property reads plus the placement.
func sync() -> void:
	if top_button == null:
		return
	var live := _region != null and _region.is_visible_in_tree() and _region.size.y > 0.0
	top_button.visible = live and _can_up.is_valid() and _can_up.call()
	bottom_button.visible = live and _can_down.is_valid() and _can_down.call()
	_place()

## Position both buttons inside the region's rect. Canvas coordinates are the
## only transform involved: panes are not scaled or rotated.
func _place() -> void:
	if _region == null:
		return
	var pane_rect := get_global_rect()
	var region_rect := _region.get_global_rect()
	var left := region_rect.position.x - pane_rect.position.x
	var top := region_rect.position.y - pane_rect.position.y
	var inset := EDGE + (UiTokens.SCROLLBAR_THICKNESS if _clears_scrollbar else 0)
	var x := left + region_rect.size.x - inset - SIZE
	top_button.position = Vector2(x, top + EDGE)
	top_button.size = Vector2(SIZE, SIZE)
	bottom_button.position = Vector2(x, top + region_rect.size.y - EDGE - SIZE)
	bottom_button.size = Vector2(SIZE, SIZE)

func _unbind() -> void:
	if _bar != null:
		if _bar.value_changed.is_connected(_on_bar_value_changed):
			_bar.value_changed.disconnect(_on_bar_value_changed)
		if _bar.changed.is_connected(_on_bar_changed):
			_bar.changed.disconnect(_on_bar_changed)
	if _tree != null and _tree.item_collapsed.is_connected(_on_tree_item_collapsed):
		_tree.item_collapsed.disconnect(_on_tree_item_collapsed)
	_bar = null
	_tree = null
	_can_up = Callable()
	_can_down = Callable()
	_to_top = Callable()
	_to_bottom = Callable()

func _on_bar_value_changed(_value: float) -> void:
	sync()

func _on_bar_changed() -> void:
	sync()

func _on_tree_item_collapsed(_item: TreeItem) -> void:
	sync()

func _on_top_pressed() -> void:
	if _to_top.is_valid():
		_to_top.call()
	sync()

func _on_bottom_pressed() -> void:
	if _to_bottom.is_valid():
		_to_bottom.call()
	sync()

# ── ScrollBar binding ────────────────────────────────────────────────────

func _bar_can_up() -> bool:
	return _bar != null and _bar.value > _bar.min_value + 0.5

func _bar_can_down() -> bool:
	return _bar != null and _bar.value + _bar.page < _bar.max_value - 0.5

func _bar_to_top() -> void:
	if _bar != null:
		_bar.value = _bar.min_value

func _bar_to_bottom() -> void:
	if _bar != null:
		_bar.value = _bar.max_value

# ── Tree binding ─────────────────────────────────────────────────────────

func _tree_can_up() -> bool:
	return _tree != null and _tree.get_scroll().y > 0.5

func _tree_can_down() -> bool:
	var last := _tree_last_visible_item()
	if last == null:
		return false
	# `get_item_area_rect` is scrolled-relative (item offset minus the tree's
	# scroll position), so a row ending past the viewport's edge is content
	# below. At the tree's own end the last row sits flush with that edge, so
	# "flush" is not content below.
	var rect := _tree.get_item_area_rect(last)
	return rect.position.y + rect.size.y > _tree.size.y + 0.5

func _tree_to_top() -> void:
	_tree_scroll_to(_tree_first_visible_item())

func _tree_to_bottom() -> void:
	_tree_scroll_to(_tree_last_visible_item())

## `scroll_to_item` refreshes the tree's cached scroll offset *before* it
## moves, so one call leaves `get_item_area_rect` reporting the previous
## position until the tree's next draw, and the pair would disagree with the
## view for that frame. A second call is a no-op on a row already at an end and
## refreshes the cache, which is what makes the immediate `sync()` truthful.
func _tree_scroll_to(item: TreeItem) -> void:
	if item != null:
		_tree.scroll_to_item(item, false)
		_tree.scroll_to_item(item, false)

func _tree_first_visible_item() -> TreeItem:
	if _tree == null:
		return null
	var item := _tree.get_root()
	if item == null:
		return null
	return item.get_first_child() if _tree.hide_root else item

func _tree_last_visible_item() -> TreeItem:
	if _tree == null:
		return null
	var item := _tree.get_root()
	if item == null:
		return null
	if _tree.hide_root:
		item = _tree_last_child(item)
		if item == null:
			return null
	while item.get_child_count() > 0 and not item.collapsed:
		item = _tree_last_child(item)
	return item

## `TreeItem` has no last-child getter; the count plus an index is the API.
func _tree_last_child(item: TreeItem) -> TreeItem:
	var count := item.get_child_count()
	return item.get_child(count - 1) if count > 0 else null


