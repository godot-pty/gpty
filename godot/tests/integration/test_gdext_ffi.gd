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
		 "capture_mode": "until_stop", "stop_timeout_ms": 450, "stop_on_input": false,
		 "actions": [{"target": "inspector"}]},
	]))
	var back = _t.get_global_concepts()
	assert_eq(back.size(), 1, "one concept should roundtrip")
	assert_eq(back[0]["name"], "c1")
	assert_eq(back[0]["trigger"], "^testcmd")
	assert_eq(back[0]["stop_timeout_ms"], 450, "stop timeout must roundtrip")
	assert_eq(back[0]["stop_on_input"], false, "stop-on-input must roundtrip")
	var actions: Array = back[0]["actions"]
	assert_eq(actions.size(), 1, "the routing target must roundtrip")
	assert_eq(actions[0]["target"], "inspector")
	assert_false(actions[0].has("cmd"),
		"a concept action must never carry a command template")

func test_key_to_bytes_arrow():
	var b = _t.key_to_bytes(KEY_LEFT, false, false, false, false)
	assert_eq(b.get_string_from_ascii(), "\u001b[D", "Left arrow maps to ESC[D")

func test_get_app_version_returns_semver():
	# Static method — call on the class, not an instance.
	var ver: String = GptyTerminal.get_app_version()
	assert_true(ver.length() > 0, "version must not be empty")
	# Must be a valid semver triple (e.g. "0.4.0"), never the stale literal.
	var parts := ver.split(".")
	assert_eq(parts.size(), 3, "version must have exactly three dot-separated parts")
	assert_ne(ver, "0.3.0", "version must not be the stale 0.3.0 literal")

func test_unstarted_grid_functions_are_safe():
	assert_eq(_t.get_rows(), 0, "unstarted grid has 0 rows")
	assert_eq(_t.get_cols(), 0, "unstarted grid has 0 cols")
	_t.scroll_reset()
	_t.resize_grid(30, 100)
	pass # no crash is the assertion

func test_markdown_renderer_formats_and_sanitizes():
	var renderer = ClassDB.instantiate("GptyMarkdown")
	assert_not_null(renderer, "GptyMarkdown must be registered")
	var rendered: String = renderer.render("# Title\n\n**bold** [raw]\n\n[x](javascript:bad)")
	assert_string_contains(rendered, "[font_size=26][b]Title")
	assert_string_contains(rendered, "[b]bold[/b]")
	assert_string_contains(rendered, "[lb]raw]")
	assert_false("[url=javascript:" in rendered)
