extends GutTest
# GDExtension FFI smoke tests — exercise real GptyTerminal #[func] methods
# headless without starting a shell (no PTY spawn; that stays a manual
# checklist item). Pattern proven by test_keyboard.gd's ClassDB usage.

var _t

func before_each():
	_t = ClassDB.instantiate("GptyTerminal")
	assert_not_null(_t, "GptyTerminal must be registered (gdext loaded)")

func after_each():
	if _t:
		_t.free()
		_t = null

func test_concepts_roundtrip_through_ffi():
	_t.set_global_concepts(JSON.stringify([
		{"name": "c1", "trigger": "^testcmd", "enabled": true,
		 "capture_mode": "single_line",
		 "actions": [{"cmd": "echo {payload}", "target": "observer"}]},
	]))
	var back = _t.get_global_concepts()
	assert_eq(back.size(), 1, "one concept should roundtrip")
	assert_eq(back[0]["name"], "c1")
	assert_eq(back[0]["trigger"], "^testcmd")
	var hits = _t.match_concepts_on_line("testcmd x")
	assert_eq(hits.size(), 1, "matching line should produce one hit")
	assert_eq(hits[0]["cmd"], "echo 'testcmd'", "payload must be the full regex match, shell-quoted")

func test_key_to_bytes_arrow():
	var b = _t.key_to_bytes(KEY_LEFT, false, false, false, false)
	assert_eq(b.get_string_from_ascii(), "\u001b[D", "Left arrow maps to ESC[D")

func test_unstarted_grid_functions_are_safe():
	assert_eq(_t.get_rows(), 0, "unstarted grid has 0 rows")
	assert_eq(_t.get_cols(), 0, "unstarted grid has 0 cols")
	_t.scroll_reset()
	_t.resize_grid(30, 100)
	pass # no crash is the assertion
