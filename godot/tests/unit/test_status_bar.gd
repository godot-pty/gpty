extends GutTest
# Status bar — version must appear in the right label as the rightmost entry.

var _bar: StatusBar

func before_each():
	MockAutoloads.setup()
	_bar = StatusBar.new()
	add_child_autofree(_bar)
	await get_tree().process_frame

func after_each():
	MockAutoloads.teardown()

# ── version in right label ─────────────────────────────────────────────

func test_right_label_contains_app_version():
	var expected := GptyTerminal.get_app_version()
	assert_string_contains(
		_bar._right_label.text,
		expected,
		"Right label must contain the live version from get_app_version()"
	)

func test_version_is_rightmost_segment():
	# The version segment must be the last pipe-delimited token.
	var parts := _bar._right_label.text.split("  |  ")
	assert_true(parts.size() >= 1, "Right label must have at least one segment")
	var last := parts[parts.size() - 1]
	assert_true(
		last.begins_with("v"),
		"Rightmost segment must begin with 'v' (got '%s')" % last
	)
	assert_string_contains(last, GptyTerminal.get_app_version())

func test_pane_label_starts_at_left_edge():
	# Restoring the original offset — pane info should not be displaced.
	assert_eq(_bar._pane_label.offset_left, 8.0)
