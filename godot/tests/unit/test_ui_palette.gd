extends GutTest
# UiPalette — the two chrome colour sets, and the one active set.
#
# The enforcement lives here now that colours are a mode-selected table: every
# token must exist in *both* sets (a token with no light value is a build
# failure), and every contrast pair is graded against each set, so the light
# chrome cannot ship a pair that the dark one passes. `UiTokens.contrast_ratio`
# is the one implementation of the maths.

func after_each():
	# The palette is process-global; a test that left it light would re-theme
	# every later suite.
	UiPalette.use(UiPalette.MODE_DARK)

func test_each_set_carries_every_token():
	var dark := UiPalette.DARK.keys()
	var light := UiPalette.LIGHT.keys()
	dark.sort()
	light.sort()
	assert_gt(dark.size(), 0, "the dark set exists")
	assert_eq(dark, light, "every token has a light value")

func test_every_declared_field_is_in_both_tables():
	# The reverse direction of the pair above: a new colour field declared
	# without a value in both tables would render transparent, so the fields and
	# the tables have to agree exactly.
	var sample := UiPalette.new()
	var declared := 0
	for prop in sample.get_property_list():
		if int(prop["type"]) != TYPE_COLOR:
			continue
		var token := str(prop["name"])
		declared += 1
		assert_true(UiPalette.DARK.has(token), "%s is in the dark set" % token)
		assert_true(UiPalette.LIGHT.has(token), "%s is in the light set" % token)
	assert_eq(declared, UiPalette.DARK.size(),
		"every table entry has a declared field")

func test_every_contrast_pair_clears_its_minimum_in_both_sets():
	for which in [UiPalette.MODE_DARK, UiPalette.MODE_LIGHT]:
		var palette := UiPalette.dark() if which == UiPalette.MODE_DARK else UiPalette.light()
		var mode := "dark" if which == UiPalette.MODE_DARK else "light"
		for pair in UiPalette.CONTRAST_PAIRS:
			var fg: Color = palette.color(str(pair[0]))
			var bg: Color = palette.color(str(pair[1]))
			var minimum := float(pair[2])
			var label := str(pair[3])
			var ratio := UiTokens.contrast_ratio(fg, bg)
			assert_gte(ratio, minimum,
				"%s (%s): %s measures %.2f:1, needs %.1f:1" % [label, mode, label, ratio, minimum])

func test_the_two_measured_failures_are_fixed_in_both_sets():
	# The numbers the roadmap row quotes, re-measured against both sets so a
	# later tweak cannot quietly undo them: the status bar's muted text on the
	# raised bar, and the sidebar's destructive action on the sidebar.
	for palette in [UiPalette.dark(), UiPalette.light()]:
		assert_gte(UiTokens.contrast_ratio(palette.TEXT_MUTED, palette.SURFACE_RAISED), 4.5)
		assert_gte(UiTokens.contrast_ratio(palette.DANGER, palette.SIDEBAR), 4.5)

func test_the_surfaces_are_opaque_in_both_sets():
	# Translucent chrome is what let pane content show through the Settings and
	# Pane Settings cards (the stock theme's panels were 60 % opaque).
	for palette in [UiPalette.dark(), UiPalette.light()]:
		for surface in [palette.BG, palette.SURFACE, palette.SURFACE_RAISED, palette.SIDEBAR]:
			assert_eq(surface.a, 1.0, "a chrome surface must be opaque")

func test_the_sets_differ_where_the_chrome_must():
	var dark := UiPalette.dark()
	var light := UiPalette.light()
	assert_ne(dark.BG, light.BG, "the content background turns")
	assert_ne(dark.SURFACE, light.SURFACE, "panels turn")
	assert_ne(dark.TEXT, light.TEXT, "the ink inverts")
	assert_ne(light.SURFACE, light.SURFACE_RAISED,
		"a raised surface is still distinguishable from a panel in light mode")
	assert_ne(dark.TEXT_MUTED, light.TEXT_MUTED)

func test_the_terminal_facing_colours_do_not_track_the_chrome():
	# They are drawn over the terminal's own scheme, which is chosen separately;
	# the scheme pair is its own row, so these must stay put for now.
	for token in ["SELECTION", "TERMINAL_FOCUS", "SEARCH_HIGHLIGHT", "SEARCH_ACTIVE", "SCROLLBACK_INDICATOR"]:
		assert_eq(UiPalette.dark().color(token), UiPalette.light().color(token),
			"%s is terminal-facing, not chrome" % token)

func test_an_unknown_token_is_transparent_not_a_crash():
	assert_eq(UiPalette.dark().color("NO_SUCH_TOKEN"), Color.TRANSPARENT)

func test_use_and_active_agree():
	UiPalette.use(UiPalette.MODE_DARK)
	assert_eq(UiPalette.active().BG, UiPalette.dark().BG)
	assert_eq(UiPalette.mode(), UiPalette.MODE_DARK)

	UiPalette.use(UiPalette.MODE_LIGHT)
	assert_eq(UiPalette.mode(), UiPalette.MODE_LIGHT)
	assert_eq(UiPalette.active().BG, UiPalette.light().BG)
	assert_eq(UiPalette.active().TEXT, UiPalette.light().TEXT)

func test_an_unknown_mode_falls_back_to_dark():
	UiPalette.use(99)
	assert_eq(UiPalette.mode(), UiPalette.MODE_DARK)
	assert_eq(UiPalette.active().SURFACE, UiPalette.dark().SURFACE)
