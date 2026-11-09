extends GutTest
# The one keyboard-entry walk (`KeyboardFocus.first_reachable`): which control a
# subtree focuses when it takes the keyboard. An overlay calls it on open (so a
# typed character lands inside instead of in the pane behind it) and pane chrome
# calls it when handing the keyboard back to a read-only pane's content, so the
# walk must agree with Godot's own traversal — the first control Tab would
# reach, in tree order, skipping anything that cannot take focus.

func _row(children: Array) -> Control:
	var box := VBoxContainer.new()
	for child in children:
		box.add_child(child)
	add_child_autofree(box)
	return box

func test_the_first_reachable_button_wins():
	var first := Button.new()
	var second := Button.new()
	var root := _row([Label.new(), first, second])
	assert_same(KeyboardFocus.first_reachable(root), first,
		"a label cannot take focus, so the first button is the entry point")

func test_containers_are_walked_before_later_siblings():
	var nested := Button.new()
	var inner := HBoxContainer.new()
	inner.add_child(nested)
	var later := Button.new()
	var root := _row([inner, later])
	assert_same(KeyboardFocus.first_reachable(root), nested,
		"tree order, not sibling order: the nested button comes first")

func test_a_hidden_branch_is_not_searched():
	var hidden := Button.new()
	hidden.visible = false
	var shown := Button.new()
	var inner := HBoxContainer.new()
	inner.add_child(hidden)
	var root := _row([inner, shown])
	assert_same(KeyboardFocus.first_reachable(root), shown,
		"a hidden branch cannot take focus, so its button is skipped")

func test_a_disabled_button_is_skipped_but_its_siblings_are_not():
	var disabled := Button.new()
	disabled.disabled = true
	var enabled := Button.new()
	var root := _row([disabled, enabled])
	assert_same(KeyboardFocus.first_reachable(root), enabled,
		"a disabled button keeps its focus mode but traversal skips it")

func test_focus_none_controls_are_skipped():
	var none_mode := Button.new()
	none_mode.focus_mode = Control.FOCUS_NONE
	var reachable := Button.new()
	var root := _row([none_mode, reachable])
	assert_same(KeyboardFocus.first_reachable(root), reachable,
		"FOCUS_NONE is mouse-only by definition")

func test_a_tree_with_no_reachable_control_answers_null():
	var root := _row([Label.new(), HSeparator.new()])
	assert_null(KeyboardFocus.first_reachable(root),
		"an overlay with no focusable control has no entry point")


## A ring caps a walk, so one start sees one ring — which is why an audit that
## walked from one control reported 5 of the wiki state's 178 controls. The map
## is every component, in the caller's order.
func test_tab_components_maps_every_ring():
	var a := Button.new()
	var b := Button.new()
	var c := Button.new()
	var d := Button.new()
	var e := Button.new()
	_row([a, b, c, d, e])
	KeyboardFocus.ring([a, b, c])
	KeyboardFocus.ring([d, e])

	var components := KeyboardFocus.tab_components([a, d])
	assert_eq(components.size(), 2, "two rings are two components")
	var first: Array = components[0]["controls"]
	var second: Array = components[1]["controls"]
	assert_eq(first.size(), 3, "the first ring is three stops")
	assert_eq(second.size(), 2, "the second ring is two stops")
	assert_true(components[0]["closed"], "a ring closes on its own first member")
	assert_true(components[1]["closed"], "the second ring closes too")
	assert_same(second[0], d, "components keep the caller's order")


func test_tab_components_skips_members_a_component_already_claimed():
	var a := Button.new()
	var b := Button.new()
	_row([a, b])
	KeyboardFocus.ring([a, b])
	var components := KeyboardFocus.tab_components([a, b, b])
	assert_eq(components.size(), 1, "a second start inside the ring adds nothing")
	assert_eq((components[0]["controls"] as Array).size(), 2)

## A toolbar whose second button is disabled or hidden is one stop: it must be
## focusable (Escape's return target and `first_reachable` both need it), but it
## must not carry a `"."` self-path, which the engine resolves back to itself
## and which no wrap test can distinguish from a real ring.
func test_a_one_member_ring_is_a_stop_without_a_wrap():
	var only := Button.new()
	only.focus_mode = Control.FOCUS_NONE
	_row([only])
	KeyboardFocus.ring([only])
	assert_eq(only.focus_mode, Control.FOCUS_ALL, "the single member is a stop")
	assert_eq(only.focus_next, NodePath(), "no self-referential wrap")
	assert_eq(only.focus_previous, NodePath())

## The CLI view rebuilds its ring whenever a button becomes disabled or
## enabled, so a member that loses its partner must lose the path to it too: a
## stale path would keep a disabled button in the tab walk (measured: the
## `cli-view-content` capture's audit printed both Restart and Stop after the
## child had exited).
func test_shrinking_a_ring_clears_the_path_to_the_gone_member():
	var first := Button.new()
	var second := Button.new()
	_row([first, second])
	KeyboardFocus.ring([first, second])
	assert_ne(first.focus_next, NodePath())
	KeyboardFocus.ring([first])
	assert_eq(first.focus_next, NodePath(), "the stale partner is cleared")
	assert_eq(first.focus_previous, NodePath())


## The one clamped cursor step (`next_index`), shared by the command palette and
## the terminal's history results: the ends are stops, not wraps, and a cursor
## that is not on anything yet starts at the end the arrow points from.
func test_next_index_clamps_at_the_ends():
	assert_eq(KeyboardFocus.next_index(0, 3, -1), 0, "the first row stays put")
	assert_eq(KeyboardFocus.next_index(2, 3, 1), 2, "the last row stays put")
	assert_eq(KeyboardFocus.next_index(1, 3, 1), 2, "a middle step moves one row")
	assert_eq(KeyboardFocus.next_index(1, 3, -1), 0, "and moves back by one")

func test_next_index_starts_at_the_first_or_last_row_from_none():
	assert_eq(KeyboardFocus.next_index(-1, 3, 1), 0, "Down from nothing selects the first row")
	assert_eq(KeyboardFocus.next_index(-1, 3, -1), 2, "Up from nothing selects the last row")
	assert_eq(KeyboardFocus.next_index(-1, 0, 1), -1, "an empty list has no cursor")
	assert_eq(KeyboardFocus.next_index(0, 3, 0), -1, "a zero step is not a move")

## The declaration the focus audit reads: a control that leaves its action to a
## chord names the keyboard path, and an empty reason clears it again.
func test_a_declared_mouse_only_button_reports_its_reason():
	var btn := Button.new()
	assert_eq(KeyboardFocus.mouse_only_reason(btn), "",
		"a control that never declared itself has no reason")
	KeyboardFocus.declare_mouse_only(btn, "Enter acts from the field")
	assert_eq(KeyboardFocus.mouse_only_reason(btn), "Enter acts from the field",
		"the reason is what the audit prints")
	KeyboardFocus.declare_mouse_only(btn, "")
	assert_eq(KeyboardFocus.mouse_only_reason(btn), "",
		"an empty reason clears the declaration")
	btn.free()
