extends GutTest
# Unit tests for UpdateChecker._is_newer — pure version comparison logic.
# No network calls: OS.has_feature("editor") returns true in headless GUT runs.

# Convenience wrapper so tests stay readable.
func _is_newer(latest: String, current: String) -> bool:
	return UpdateChecker._is_newer(latest, current)

# ── equal ──────────────────────────────────────────────────────────────

func test_equal_versions_not_newer():
	assert_false(_is_newer("1.2.3", "1.2.3"))

func test_equal_single_component_not_newer():
	assert_false(_is_newer("5", "5"))

# ── newer ──────────────────────────────────────────────────────────────

func test_patch_bump_is_newer():
	assert_true(_is_newer("1.2.4", "1.2.3"))

func test_minor_bump_is_newer():
	assert_true(_is_newer("1.3.0", "1.2.9"))

func test_major_bump_is_newer():
	assert_true(_is_newer("2.0.0", "1.9.9"))

# ── older ──────────────────────────────────────────────────────────────

func test_patch_rollback_not_newer():
	assert_false(_is_newer("1.2.2", "1.2.3"))

func test_minor_rollback_not_newer():
	assert_false(_is_newer("1.1.9", "1.2.0"))

func test_major_rollback_not_newer():
	assert_false(_is_newer("0.9.9", "1.0.0"))

# ── differing lengths ──────────────────────────────────────────────────

func test_longer_latest_is_newer_when_prefix_equal():
	# "1.2.3.1" vs "1.2.3" — extra component means newer
	assert_true(_is_newer("1.2.3.1", "1.2.3"))

func test_shorter_latest_not_newer_when_prefix_equal():
	# "1.2" vs "1.2.0" — shorter with equal prefix is not newer
	assert_false(_is_newer("1.2", "1.2.0"))

func test_longer_current_not_newer():
	assert_false(_is_newer("1.2.3", "1.2.3.1"))

# ── prerelease / non-numeric strings ──────────────────────────────────
# to_int() on a non-numeric string returns 0 in GDScript.

func test_prerelease_zero_compared_numerically():
	# "1.2.0-beta" → to_int() == 0, same as "1.2.0" numeric part
	assert_false(_is_newer("1.2.0-beta", "1.2.0"))

func test_prerelease_on_current_same_numeric_not_newer():
	assert_false(_is_newer("1.2.0", "1.2.0-beta"))
