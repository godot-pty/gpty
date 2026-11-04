extends GutTest
# The overlay keyboard contract's pure half: which control an overlay focuses
# when it takes the keyboard. `Workspace` uses this to move focus off the pane
# behind an overlay, so the walk must agree with Godot's own traversal — the
# first control Tab would reach, in tree order, skipping anything that cannot
# take focus.

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
	assert_same(OverlayPanel.first_focusable(root), first,
		"a label cannot take focus, so the first button is the entry point")

func test_containers_are_walked_before_later_siblings():
	var nested := Button.new()
	var inner := HBoxContainer.new()
	inner.add_child(nested)
	var later := Button.new()
	var root := _row([inner, later])
	assert_same(OverlayPanel.first_focusable(root), nested,
		"tree order, not sibling order: the nested button comes first")

func test_a_hidden_branch_is_not_searched():
	var hidden := Button.new()
	hidden.visible = false
	var shown := Button.new()
	var inner := HBoxContainer.new()
	inner.add_child(hidden)
	var root := _row([inner, shown])
	assert_same(OverlayPanel.first_focusable(root), shown,
		"a hidden branch cannot take focus, so its button is skipped")

func test_a_disabled_button_is_skipped_but_its_siblings_are_not():
	var disabled := Button.new()
	disabled.disabled = true
	var enabled := Button.new()
	var root := _row([disabled, enabled])
	assert_same(OverlayPanel.first_focusable(root), enabled,
		"a disabled button keeps its focus mode but traversal skips it")

func test_focus_none_controls_are_skipped():
	var none_mode := Button.new()
	none_mode.focus_mode = Control.FOCUS_NONE
	var reachable := Button.new()
	var root := _row([none_mode, reachable])
	assert_same(OverlayPanel.first_focusable(root), reachable,
		"FOCUS_NONE is mouse-only by definition")

func test_a_tree_with_no_reachable_control_answers_null():
	var root := _row([Label.new(), HSeparator.new()])
	assert_null(OverlayPanel.first_focusable(root),
		"an overlay with no focusable control has no entry point")
