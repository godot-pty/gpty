extends GutTest
# Unit tests for GraphTheme — the closed style table both graph presentations
# read. The schema test is the drift control: a key added to one theme (or the
# default) without updating STYLE_KEYS, or a theme missing a key in one
# appearance, fails here instead of drawing with a null colour.


func _sorted(keys: Array) -> Array:
	var copy := keys.duplicate()
	copy.sort()
	return copy


func test_every_theme_has_a_label_and_unknown_ids_fall_back():
	for id in GraphTheme.IDS:
		assert_true(GraphTheme.LABELS.has(id), "%s must have a label" % id)
	assert_eq(GraphTheme.normalize(""), "default")
	assert_eq(GraphTheme.normalize("nope"), "default")
	assert_eq(GraphTheme.normalize("planetary"), "planetary")


func test_every_style_carries_the_whole_schema():
	var expected := _sorted(GraphTheme.STYLE_KEYS)
	for id in GraphTheme.IDS:
		for dark in [true, false]:
			var style := GraphTheme.style(id, dark)
			assert_eq(
				_sorted(style.keys()), expected,
				"%s (%s) must carry every STYLE_KEYS entry" % [id, "dark" if dark else "light"]
			)


func test_the_default_style_is_the_chrome_palette():
	var dark := GraphTheme.style("default", true)
	assert_eq(dark["background"], UiPalette.dark().BG)
	assert_eq(dark["text"], UiPalette.dark().TEXT)
	assert_eq(dark["edge"], Color(UiPalette.dark().TEXT, 0.42))
	assert_almost_eq(float(dark["halo_alpha"]), 0.13, 0.0001)
	assert_almost_eq(float(dark["vignette_alpha"]), 0.10, 0.0001)
	assert_almost_eq(float(dark["glow_strength"]), 0.9, 0.0001)
	assert_eq(str(dark["node_shape"]), "billboard")
	assert_almost_eq(float(dark["ring_ratio"]), 0.0, 0.0001)

	var light := GraphTheme.style("default", false)
	assert_eq(light["background"], UiPalette.light().BG)
	assert_eq(light["text"], UiPalette.light().TEXT)
	assert_almost_eq(float(light["halo_alpha"]), 0.09, 0.0001)
	assert_almost_eq(float(light["vignette_alpha"]), 0.05, 0.0001)
	assert_almost_eq(float(light["ring_ratio"]), 0.0, 0.0001)


func test_the_planetary_theme_paints_worlds():
	var dark := GraphTheme.style("planetary", true)
	assert_eq(str(dark["node_shape"]), "sphere")
	assert_gt(float(dark["ring_ratio"]), 0.0)
	assert_gt(float(dark["sun_energy"]), 0.0)
	assert_gt(float(dark["ambient_energy"]), 0.0)
	assert_gt(int(dark["stars"]), 0)
	assert_gt(float(dark["star_alpha"]), 0.0)
	assert_gt(float(dark["glow_intensity"]), 0.0)

	var light := GraphTheme.style("planetary", false)
	assert_eq(str(light["node_shape"]), "sphere")
	assert_gt(float(light["sun_energy"]), 0.0)
	assert_eq(int(light["stars"]), 0, "a daylight sky carries no stars")
	assert_almost_eq(float(light["glow_intensity"]), 0.0, 0.0001)


func test_stars_are_deterministic_and_inside_the_view():
	var first := GraphTheme.stars(12)
	var second := GraphTheme.stars(12)
	assert_eq(first.size(), 12)
	for i in first.size():
		var at: Vector2 = first[i]["at"]
		var twin: Vector2 = second[i]["at"]
		assert_eq(at, twin, "the same seed must produce the same star")
		assert_almost_eq(float(first[i]["r"]), float(second[i]["r"]), 0.000001)
		assert_almost_eq(float(first[i]["a"]), float(second[i]["a"]), 0.000001)
		assert_true(at.x >= 0.0 and at.x <= 1.0, "star x must be normalized")
		assert_true(at.y >= 0.0 and at.y <= 1.0, "star y must be normalized")
		assert_true(float(first[i]["r"]) > 0.0)
		assert_true(float(first[i]["a"]) > 0.0)
	assert_eq(GraphTheme.stars(0).size(), 0)


func test_note_colors_follow_the_note_id_only_when_the_theme_paints_worlds():
	var plastic := GraphTheme.style("default", true)
	var worlds := GraphTheme.style("planetary", true)
	assert_eq(GraphTheme.note_color("a.md", plastic), plastic["node"])
	assert_eq(GraphTheme.note_color("b.md", plastic), plastic["node"])
	assert_eq(
		GraphTheme.note_color("a.md", worlds),
		GraphTheme.note_color("a.md", worlds),
		"a note's hue is deterministic"
	)
	assert_ne(
		GraphTheme.note_color("a.md", worlds),
		GraphTheme.note_color("b.md", worlds),
		"two notes are two worlds"
	)


func test_rings_pick_the_busiest_notes_and_are_capped():
	var style := GraphTheme.style("planetary", true)
	var ids: Array = []
	var degrees := {}
	for i in 300:
		var id := "n%03d.md" % i
		ids.append(id)
		degrees[id] = {"in": 600, "out": 0}
	degrees["ghost:missing"] = {"in": 999, "out": 0}

	var capped := GraphTheme.ringed(ids, degrees, 1000, style)
	assert_eq(capped.size(), GraphTheme.MAX_PLANET_RINGS)
	assert_true(capped.has("n000.md"))
	assert_true(capped.has("n255.md"))
	assert_false(capped.has("n256.md"), "the cap keeps the lowest ids on a tie")
	assert_false(capped.has("ghost:missing"), "an id not passed in is never ringed")

	var few_ids: Array = []
	var few_degrees := {}
	for i in 60:
		var id := "m%02d.md" % i
		few_ids.append(id)
		few_degrees[id] = {"in": i, "out": 0}
	var thresholded := GraphTheme.ringed(few_ids, few_degrees, 40, style)
	assert_eq(thresholded.size(), 40, "max_degree * 0.5 = 20, so degrees 20..59 ring")
	assert_true(thresholded.has("m20.md"))
	assert_true(thresholded.has("m59.md"))
	assert_false(thresholded.has("m19.md"))

	assert_eq(GraphTheme.ringed(ids, degrees, 1000, GraphTheme.style("default", true)).size(), 0)
