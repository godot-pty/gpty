extends GutTest
# UiTokens — the design tokens and the contrast table they carry.
#
# The table is the enforcement: a chrome colour used as text on a surface has to
# clear 4.5:1 on every surface it can appear on, and this suite is what makes
# that a build failure instead of a review note. The two rows the 0.8.0 work
# fixed measured 4.15:1 (the status bar's right-hand text) and 3.49:1 (Close
# All) on the 0.7.2 build.

func test_every_contrast_pair_clears_its_minimum():
	for pair in UiTokens.CONTRAST_PAIRS:
		var fg: Color = pair[0]
		var bg: Color = pair[1]
		var minimum: float = pair[2]
		var label: String = pair[3]
		var ratio := UiTokens.contrast_ratio(fg, bg)
		assert_gte(ratio, minimum, "%s measures %.2f:1, needs %.1f:1" % [label, ratio, minimum])

func test_the_maths_matches_the_wcag_reference_points():
	# White on black is the scale's ceiling and a colour on itself its floor;
	# a formula that is off by a constant is right at neither.
	assert_almost_eq(UiTokens.contrast_ratio(Color.WHITE, Color.BLACK), 21.0, 0.01)
	assert_almost_eq(UiTokens.contrast_ratio(UiTokens.TEXT, UiTokens.TEXT), 1.0, 0.001)
	# 50 % white over black composites to mid grey: 5.28:1.
	assert_almost_eq(UiTokens.contrast_ratio(Color(1, 1, 1, 0.5), Color.BLACK), 5.28, 0.02)

func test_a_failing_pair_would_be_caught():
	# The table only means something if a bad colour actually fails it. Pure red
	# is the natural candidate: it is the colour a "red enough" literal lands on
	# and it cannot reach 4.5:1 on these backgrounds.
	assert_lt(UiTokens.contrast_ratio(Color("ff0000"), UiTokens.SURFACE), 4.5,
		"pure red must fail the minimum, or the table proves nothing")
	# The shipped DANGER is that red, lifted until it passes.
	assert_gte(UiTokens.contrast_ratio(UiTokens.DANGER, UiTokens.SURFACE), 4.5)

func test_the_surfaces_are_opaque():
	# Translucent chrome is what let pane content show through the Settings and
	# Pane Settings cards (the stock theme's panels were 60 % opaque).
	for surface in [UiTokens.BG, UiTokens.SURFACE, UiTokens.SURFACE_RAISED, UiTokens.SIDEBAR]:
		assert_eq(surface.a, 1.0, "a chrome surface must be opaque")

func test_the_type_scale_is_ordered_and_unique():
	var scale := [
		UiTokens.FS_CAPTION, UiTokens.FS_SMALL, UiTokens.FS_CONTROL,
		UiTokens.FS_BODY, UiTokens.FS_HEADING, UiTokens.FS_TITLE, UiTokens.FS_HERO,
	]
	for i in range(1, scale.size()):
		assert_gt(scale[i], scale[i - 1], "step %d is larger than the one before" % i)

func test_the_spacing_scale_is_ordered():
	var scale := [
		UiTokens.SPACE_HAIR, UiTokens.SPACE_XS, UiTokens.SPACE_SM,
		UiTokens.SPACE_MD, UiTokens.SPACE_LG, UiTokens.SPACE_XL, UiTokens.SPACE_XXL,
	]
	for i in range(1, scale.size()):
		assert_gt(scale[i], scale[i - 1], "step %d is larger than the one before" % i)

func test_the_two_measured_failures_are_fixed():
	# The numbers the roadmap row quotes, re-measured against the tokens so a
	# later tweak cannot quietly undo them: the status bar's muted text on the
	# raised bar, and the sidebar's destructive action on the sidebar.
	assert_gte(UiTokens.contrast_ratio(UiTokens.TEXT_MUTED, UiTokens.SURFACE_RAISED), 4.5)
	assert_gte(UiTokens.contrast_ratio(UiTokens.DANGER, UiTokens.SIDEBAR), 4.5)
