extends GutTest
# ShortcutManager's chord spelling — the pair the palette prints.
#
# The formatter must mirror the parser `register` accepts, or a surface shows a
# chord that names no binding. Pure round trip; no InputMap mutation, so the
# suite's global input state is left alone.

func test_a_chord_round_trips_through_the_parser_and_the_formatter():
	for literal in ["Ctrl+Shift+W", "Ctrl+P", "F11", "Ctrl+Alt+Y"]:
		assert_eq(ShortcutManager.format_chord(ShortcutManager._parse_bind(literal)), literal,
			"'%s' survives the round trip" % literal)

func test_an_unregistered_action_has_no_chord():
	assert_eq(ShortcutManager.chord("app:does_not_exist"), "",
		"an unknown action names no shortcut instead of erroring")

func test_modifier_order_is_the_literal_order():
	assert_eq(ShortcutManager.format_chord(ShortcutManager._parse_bind("Shift+Ctrl+P")),
		"Ctrl+Shift+P",
		"the spelling is stable regardless of how the literal ordered its modifiers")


# ── Declared chords (the terminal's own keys) ──────────────────────────

func test_a_declared_chord_is_spelled_but_is_not_a_workspace_shortcut():
	# The terminal's chords live here so a surface can print them, while the
	# terminal's own handler stays the one that acts on them: `is_shortcut` is
	# the workspace's gate, and answering true would consume the key before the
	# pane sees it.
	assert_eq(ShortcutManager.chord("term:copy"), "Ctrl+Shift+C",
		"the declared chord is what Settings > About prints")
	var ev := ShortcutManager._parse_bind(ShortcutManager.chord("term:copy"))
	ev.pressed = true
	assert_false(ShortcutManager.is_shortcut(ev),
		"a pane-local chord must reach the pane, not a workspace action")


func test_a_registered_action_is_a_workspace_shortcut_and_is_not_after_erasing():
	var action := "test:registry_probe"
	ShortcutManager.register(action, "Ctrl+Alt+F12", func(): pass)
	var ev := ShortcutManager._parse_bind("Ctrl+Alt+F12")
	ev.pressed = true
	assert_eq(ShortcutManager.chord(action), "Ctrl+Alt+F12")
	assert_true(ShortcutManager.is_shortcut(ev),
		"a callback action is what the workspace's gate claims")
	# Leave the process InputMap and the registry as they were: a stray
	# Ctrl+Alt+F12 in a later suite must not fire this test's lambda.
	ShortcutManager._actions.erase(action)
	ShortcutManager._survives_overlay.erase(action)
	InputMap.erase_action(action)
	assert_false(ShortcutManager.is_shortcut(ev), "and none once it is gone")
