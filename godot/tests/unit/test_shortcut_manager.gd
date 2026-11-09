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
