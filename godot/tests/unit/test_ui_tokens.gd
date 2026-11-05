extends GutTest
# UiTokens — the tokens that do not change with the mode, and the WCAG maths.
#
# Colours moved to `ui_palette.gd`: its suite grades both colour sets, so this
# one keeps the type scale, the spacing scale and the contrast formula honest.
# `contrast_ratio()` is the single implementation the palette test grades with,
# so a measured number in a roadmap row and the test's verdict cannot disagree.

func test_the_maths_matches_the_wcag_reference_points():
	# White on black is the scale's ceiling and a colour on itself its floor;
	# a formula that is off by a constant is right at neither.
	assert_almost_eq(UiTokens.contrast_ratio(Color.WHITE, Color.BLACK), 21.0, 0.01)
	assert_almost_eq(UiTokens.contrast_ratio(UiPalette.dark().TEXT, UiPalette.dark().TEXT), 1.0, 0.001)
	# 50 % white over black composites to mid grey: 5.28:1.
	assert_almost_eq(UiTokens.contrast_ratio(Color(1, 1, 1, 0.5), Color.BLACK), 5.28, 0.02)

func test_a_failing_pair_would_be_caught():
	# The table only means something if a bad colour actually fails it. Pure red
	# is the natural candidate: it is the colour a "red enough" literal lands on
	# and it cannot reach 4.5:1 on these backgrounds.
	assert_lt(UiTokens.contrast_ratio(Color("ff0000"), UiPalette.dark().SURFACE), 4.5,
		"pure red must fail the minimum, or the table proves nothing")
	# The shipped DANGER is that red, lifted until it passes.
	assert_gte(UiTokens.contrast_ratio(UiPalette.dark().DANGER, UiPalette.dark().SURFACE), 4.5)

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
