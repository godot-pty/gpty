extends GutTest
# The closed terminal-effect table: ids, the intensity policy and the two
# sanitizers behind Settings -> Appearance -> Effects and the concept cues.
#
# The seam test at the top is the one that matters most: `pane_types.gd` carries
# a literal copy of the id list because that script is compiled by `-s` entry
# points before autoloads exist (and `UiEffects` names `SettingsManager`). A new
# effect id has to reach both places, and this is what says so.

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_reactive_effects = {}

func after_each():
	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_reactive_effects = {}
	MockAutoloads.teardown()

func test_the_ambient_ids_are_the_pane_schema_values():
	assert_eq(PaneTypes.TERMINAL_SETTINGS["effect"]["values"], UiEffects.AMBIENT_IDS,
		"the pane schema and the effect table must list the same ids")
	assert_eq(int(PaneTypes.TERMINAL_SETTINGS["effect_intensity"]["max"]), UiEffects.FULL,
		"the schema ceiling is the intensity vocabulary's top")

func test_an_unknown_effect_falls_back_to_the_default():
	assert_eq(UiEffects.sanitize_ambient("blur"), UiEffects.DEFAULT_AMBIENT)
	assert_eq(UiEffects.sanitize_ambient(""), UiEffects.DEFAULT_AMBIENT)
	assert_eq(UiEffects.sanitize_ambient("grain"), "grain")
	SettingsManager.cfg_effect = "nonsense"
	assert_eq(UiEffects.ambient_id(), UiEffects.DEFAULT_AMBIENT,
		"the reader sanitizes a store another build wrote")

func test_the_level_clamps_and_strength_is_half_at_subtle():
	SettingsManager.cfg_effect_intensity = 99
	assert_eq(UiEffects.level(), UiEffects.FULL, "the level clamps from above")
	assert_eq(UiEffects.strength(), 1.0, "Full is the shader's declared amplitude")
	SettingsManager.cfg_effect_intensity = UiEffects.SUBTLE
	assert_eq(UiEffects.strength(), 0.5, "Subtle is half of it")
	SettingsManager.cfg_effect_intensity = -5
	assert_eq(UiEffects.level(), UiEffects.OFF, "the level clamps from below")
	assert_eq(UiEffects.strength(), 0.0, "Off draws no effect")

func test_every_ambient_entry_declares_a_shader_a_budget_and_a_rate():
	for id in UiEffects.AMBIENT_IDS:
		var entry: Dictionary = UiEffects.AMBIENT[id]
		assert_true(entry["shader"] is Shader, "%s must preload a Shader" % id)
		if bool(entry["animated"]):
			assert_gt(float(entry["budget_ms_1080p"]), 0.0,
				"%s must declare a 1080p frame budget" % id)
			assert_gt(float(entry["budget_ms_4k"]), 0.0,
				"%s must declare a 4K frame budget" % id)
			assert_true(int(entry["hz"]) > 0 and int(entry["hz"]) <= 30,
				"%s is animated and must render at 30 Hz or less" % id)
		else:
			assert_eq(float(entry["budget_ms_1080p"]), 0.0,
				"%s is static: it is not evaluated per frame" % id)
			assert_eq(float(entry["budget_ms_4k"]), 0.0)
			assert_eq(int(entry["hz"]), 0, "%s is static and must not tick" % id)

func test_sanitize_reactive_keeps_known_effects_and_refuses_the_rest():
	var clean := UiEffects.sanitize_reactive({
		"cat_command": "tint",
		"cargo_check": "particles",
		"git_log": "blur",
		"": "pulse",
		7: "pulse",
		"bad\u0007name": "pulse",
	})
	assert_eq(clean.size(), 2, "only the two known effect ids survive")
	assert_eq(clean.get("cat_command", ""), "tint")
	assert_eq(clean.get("cargo_check", ""), "particles")
	assert_false(clean.has("git_log"), "an id outside the table is not a cue")
	assert_false(clean.has(""), "an empty concept name is not a rule")
	assert_false(clean.has("bad\u0007name"), "a control character is not a concept name")
	assert_eq(UiEffects.sanitize_reactive("nope"), {},
		"a non-dictionary store answers an empty map")

func test_sanitize_reactive_caps_the_table():
	var raw := {}
	for i in UiEffects.MAX_RULES + 4:
		raw["concept_%d" % i] = "pulse"
	assert_eq(UiEffects.sanitize_reactive(raw).size(), UiEffects.MAX_RULES)

func test_reactive_for_reads_the_stored_mapping():
	SettingsManager.cfg_reactive_effects = {"cat_command": "tint"}
	assert_eq(UiEffects.reactive_for("cat_command"), "tint")
	assert_eq(UiEffects.reactive_for("git_log"), "", "an unmapped concept cues nothing")
	assert_eq(UiEffects.reactive_for(""), "", "an empty name never looks up")
	SettingsManager.cfg_reactive_effects = {"cat_command": "blur"}
	assert_eq(UiEffects.reactive_for("cat_command"), "",
		"a stored id outside the table never reaches a cue")
