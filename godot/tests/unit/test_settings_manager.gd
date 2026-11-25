extends GutTest
# Unit tests for SettingsManager — settings application to terminals,
# serialization, and signal emission.

var _scene: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

func after_each():
	# The palette and the seam are process-global: a test that left the chrome
	# light (or a desktop answer stubbed) would re-theme every later suite. A fold
	# is the same kind of leak through `SettingsManager`'s own field.
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.cfg_sidebar_folded.clear()
	SettingsManager.cfg_sidebar_mode = SettingsManager.SIDEBAR_EXPANDED
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_window_opacity = SettingsManager.OPACITY_DEFAULT
	SettingsManager.cfg_terminal_padding = PaneTypes.TERMINAL_PADDING_DEFAULT
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}
	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	SettingsManager.cfg_reactive_effects = {}
	SettingsManager.cfg_backdrop = SettingsManager.BACKDROP_FLAT
	SettingsManager.system_is_dark = func() -> bool:
		return DisplayServer.is_dark_mode() if DisplayServer.is_dark_mode_supported() else true
	SettingsManager.apply_appearance()
	for c in _scene.get_children():
		c.queue_free()
	MockAutoloads.teardown()
	if _scene:
		_scene.queue_free()

# ── apply_to_terminal ──────────────────────────────────────────────────

func test_apply_to_terminal_sets_font_size():
	var body = PaneBody.new()
	_scene.add_child(body)

	SettingsManager.cfg_font_size = 16
	SettingsManager.apply_to_terminal(body)

	# font_size is declared on PaneBody, so the setter fires.
	assert_eq(body.font_size, 16)
	# cursor_shape, cursor_blink, scroll_lines are TerminalPane
	# properties; setting them on bare PaneBody via set() is a no-op
	# in Godot 4 (Control.set only handles known properties).
	# Those are covered by integration tests with real TerminalPanes.

func test_apply_pane_settings_delegates():
	var body = PaneBody.new()
	_scene.add_child(body)

	SettingsManager.apply_pane_settings(body, {"pane_name": "x"})
	assert_eq(body.pane_name, "x")

func test_apply_to_terminal_passes_the_padding():
	var body = TerminalPane.new()
	_scene.add_child(body)

	SettingsManager.cfg_terminal_padding = 12
	SettingsManager.apply_to_terminal(body)

	assert_eq(body.terminal_padding, 12,
		"the global padding must reach a live terminal's fit")

# ── Settings changed signal ────────────────────────────────────────────

func test_settings_changed_emits_on_save():
	watch_signals(SettingsManager)
	SettingsManager.save_settings()
	assert_signal_emitted(SettingsManager, "settings_changed")

# ── Save/load roundtrip ────────────────────────────────────────────────

func test_save_load_roundtrip():
	SettingsManager.cfg_shell_command = "/bin/zsh"
	SettingsManager.cfg_font_size = 20
	SettingsManager.cfg_cursor_shape = 2  # underline
	SettingsManager.save_settings()

	# Overwrite and reload — should restore saved values
	SettingsManager.cfg_shell_command = "overwritten"
	SettingsManager.cfg_font_size = 0
	SettingsManager.cfg_cursor_shape = 0
	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_shell_command, "/bin/zsh")
	assert_eq(SettingsManager.cfg_font_size, 20)
	assert_eq(SettingsManager.cfg_cursor_shape, 2)

func test_save_load_window_mode():
	# Bug: cfg_window_mode was missing from load_settings (fixed 589a485)
	SettingsManager.cfg_window_mode = 2  # fullscreen
	SettingsManager.save_settings()
	SettingsManager.cfg_window_mode = 0
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_window_mode, 2)

func test_save_load_show_titlebar():
	# Bug: cfg_show_titlebar needed decoupling from global titlebar (071b650)
	SettingsManager.cfg_show_titlebar = false
	SettingsManager.save_settings()
	SettingsManager.cfg_show_titlebar = true
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_show_titlebar, false)

func test_window_fit_settings_roundtrip():
	SettingsManager.cfg_window_opacity = 75
	SettingsManager.cfg_terminal_padding = 12
	SettingsManager.save_settings()

	SettingsManager.cfg_window_opacity = SettingsManager.OPACITY_DEFAULT
	SettingsManager.cfg_terminal_padding = PaneTypes.TERMINAL_PADDING_DEFAULT
	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_window_opacity, 75, "opacity must survive a restart")
	assert_eq(SettingsManager.cfg_terminal_padding, 12, "padding must survive a restart")

func test_hand_edited_window_fit_values_clamp():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE,
		{"window_opacity": 5, "terminal_padding": 999})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_window_opacity, SettingsManager.OPACITY_MIN,
		"an opacity below the floor clamps to it")
	assert_eq(SettingsManager.cfg_terminal_padding, PaneTypes.TERMINAL_PADDING_MAX,
		"padding past the ceiling clamps to it")

	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE,
		{"window_opacity": 500, "terminal_padding": -3})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_window_opacity, SettingsManager.OPACITY_MAX,
		"an opacity past the ceiling clamps to it")
	assert_eq(SettingsManager.cfg_terminal_padding, 0,
		"negative padding clamps to zero")

func test_load_settings_uses_defaults_when_empty():
	# Clear store and load — should keep compiled defaults
	SettingsManager.cfg_font_size = 14  # set a known default
	SettingsManager.load_settings()  # store is empty, so nothing changes
	assert_eq(SettingsManager.cfg_font_size, 14, "default should persist when no saved data")

# ── Appearance mode ────────────────────────────────────────────────────

func test_appearance_mode_roundtrips():
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.save_settings()
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_appearance_mode, SettingsManager.APPEARANCE_LIGHT)

func test_a_hand_edited_appearance_mode_is_clamped():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"appearance_mode": 9})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_appearance_mode, SettingsManager.APPEARANCE_SYSTEM,
		"a mode past the last entry clamps to Follow system")
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"appearance_mode": -5})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_appearance_mode, SettingsManager.APPEARANCE_DARK,
		"a mode below the first entry clamps to Dark")

func test_light_selects_the_light_palette():
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.apply_appearance()
	assert_false(SettingsManager.is_dark_appearance())
	assert_eq(UiPalette.active().BG, UiPalette.light().BG)
	assert_eq(UiPalette.active().TEXT, UiPalette.light().TEXT)

func test_follow_system_uses_the_desktop_answer():
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_SYSTEM
	SettingsManager.system_is_dark = func() -> bool: return false
	SettingsManager.apply_appearance()
	assert_false(SettingsManager.is_dark_appearance(), "the desktop said light")
	assert_eq(UiPalette.active().SURFACE, UiPalette.light().SURFACE)

	SettingsManager.system_is_dark = func() -> bool: return true
	SettingsManager.apply_appearance()
	assert_true(SettingsManager.is_dark_appearance(), "the desktop said dark")
	assert_eq(UiPalette.active().SURFACE, UiPalette.dark().SURFACE)

func test_apply_appearance_is_idempotent():
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	watch_signals(SettingsManager)
	SettingsManager.apply_appearance()
	assert_signal_not_emitted(SettingsManager, "appearance_changed",
		"a save that did not move the mode must not cost a theme rebuild")
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.apply_appearance()
	assert_signal_emitted(SettingsManager, "appearance_changed")

## A value equal to either set's default has never been chosen, so it follows
## the palette: a store written by a light run still renders dark on a dark one.
func test_an_uncustomised_chrome_colour_follows_the_palette():
	SettingsManager.cfg_title_bar_bg = UiPalette.light().SURFACE_RAISED
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.save_settings()
	assert_eq(SettingsManager.cfg_title_bar_bg, UiPalette.dark().SURFACE_RAISED)
	assert_eq(SettingsManager.cfg_wrapper_bg, UiPalette.dark().BG)

## ...while a colour the user actually picked is theirs to keep.
func test_a_custom_chrome_colour_survives_a_palette_switch():
	SettingsManager.cfg_title_bar_bg = Color(0.9, 0.1, 0.1)
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.save_settings()
	assert_eq(SettingsManager.cfg_title_bar_bg, Color(0.9, 0.1, 0.1))
	assert_eq(SettingsManager.cfg_sidebar_bg, UiPalette.light().SIDEBAR,
		"the untouched colours still follow")

# ── Sidebar section folds ──────────────────────────────────────────────

func test_the_sidebar_fold_store_is_a_closed_vocabulary():
	# A store written by another build, or hand-edited, may name a section this
	# build has no header for, repeat one, or hold a non-string.
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE,
		{"sidebar_folded": ["panes", "bogus", "panes", 3, "workspaces"]})
	SettingsManager.load_settings()
	var expected: Array[String] = ["workspaces", "panes"]
	assert_eq(SettingsManager.cfg_sidebar_folded, expected,
		"registry ids only, in registry order, without duplicates")

func test_a_fold_is_saved_and_cleared():
	SettingsManager.set_sidebar_folded("panes", true)
	assert_true(SettingsManager.is_sidebar_folded("panes"))
	SettingsManager.set_sidebar_folded("bogus", true)
	assert_false(SettingsManager.is_sidebar_folded("bogus"),
		"an id this build has no section for is refused")
	var stored: Dictionary = MockAutoloads.get_store(SettingsManager.SETTINGS_FILE)
	assert_eq(stored.get("sidebar_folded"), ["panes"], "the toggle writes the store")
	SettingsManager.set_sidebar_folded("panes", false)
	assert_false(SettingsManager.is_sidebar_folded("panes"))

func test_a_fold_does_not_broadcast_settings_changed():
	# `settings_changed` re-applies terminal settings to every pane in every
	# workspace; a fold changes no pane.
	watch_signals(SettingsManager)
	SettingsManager.set_sidebar_folded("profiles", true)
	assert_signal_not_emitted(SettingsManager, "settings_changed")

# ── Pane motion ────────────────────────────────────────────────────────

func test_motion_settings_roundtrip():
	SettingsManager.cfg_motion = UiMotion.FULL
	SettingsManager.cfg_pane_animation = {"create": "fade", "close": "fade", "swap": "move"}
	SettingsManager.cfg_pane_animation_params = {"create:fade": {"duration_ms": 300.0}}
	SettingsManager.save_settings()

	SettingsManager.cfg_motion = UiMotion.OFF
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}
	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_motion, UiMotion.FULL)
	assert_eq(str(SettingsManager.cfg_pane_animation["create"]), "fade")
	assert_eq(str(SettingsManager.cfg_pane_animation["close"]), "fade")
	assert_eq(str(SettingsManager.cfg_pane_animation["swap"]), "move")
	assert_almost_eq(
		float(SettingsManager.cfg_pane_animation_params["create:fade"]["duration_ms"]),
		300.0, 0.001)

func test_damaged_motion_settings_fall_back_to_defaults():
	# Values a hand-edited file or another build can carry: an out-of-range
	# level, ids that do not serve their transition, and parameter keys the
	# registry never declared.
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {
		"motion": 99,
		"pane_animations": {"create": "move", "swap": "fade_scale"},
		"pane_animation_params": {
			"create:nope": {"x": 1},
			"create:move": {"duration_ms": 99999},
		},
	})
	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_motion, UiMotion.FULL, "the level clamps")
	assert_eq(str(SettingsManager.cfg_pane_animation["create"]), "fade_scale",
		"a swap animation cannot serve a create")
	assert_eq(str(SettingsManager.cfg_pane_animation["swap"]), "move",
		"a create animation cannot serve a swap")
	assert_eq(str(SettingsManager.cfg_pane_animation["close"]), "fade_scale",
		"a missing kind takes its default")
	assert_true(SettingsManager.cfg_pane_animation_params.is_empty(),
		"no parameter pair survives: one names an unknown id, one the wrong kind")

func test_the_effect_and_its_intensity_survive_a_restart():
	SettingsManager.cfg_effect = "grain"
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	SettingsManager.cfg_reactive_effects = {
		"cat_command": "tint", "cargo_check": "particles"}
	SettingsManager.save_settings()

	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_reactive_effects = {}
	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_effect, "grain", "the effect id must survive a restart")
	assert_eq(SettingsManager.cfg_effect_intensity, UiEffects.FULL,
		"the intensity must survive a restart")
	assert_eq(str(SettingsManager.cfg_reactive_effects.get("cat_command", "")), "tint")
	assert_eq(str(SettingsManager.cfg_reactive_effects.get("cargo_check", "")), "particles")

func test_an_unknown_stored_effect_loads_as_the_default():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {
		"effect": "blur",
		"effect_intensity": 99,
	})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_effect, UiEffects.DEFAULT_AMBIENT,
		"an id outside the table falls back")
	assert_eq(SettingsManager.cfg_effect_intensity, UiEffects.FULL,
		"the intensity clamps to the picker's top")

func test_the_effect_scope_round_trips():
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_BOTH
	SettingsManager.save_settings()

	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_effect_scope, UiEffects.SCOPE_BOTH,
		"the scope must survive a restart")

func test_a_stored_scope_outside_the_vocabulary_clamps():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"effect_scope": 99})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_effect_scope, UiEffects.SCOPE_SIDEBAR,
		"a value above the picker clamps to its top")
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"effect_scope": -5})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_effect_scope, UiEffects.SCOPE_PANES,
		"a value below the picker clamps to panes")

func test_the_sidebar_mode_round_trips_and_clamps():
	SettingsManager.set_sidebar_mode(SettingsManager.SIDEBAR_ICONS)
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_ICONS)
	SettingsManager.cfg_sidebar_mode = SettingsManager.SIDEBAR_EXPANDED
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_ICONS,
		"the mode must survive a restart")
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"sidebar_mode": 99})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_COLLAPSED,
		"a value above the picker clamps to collapsed")
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"sidebar_mode": -5})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_EXPANDED,
		"a value below the picker clamps to expanded")

func test_reactive_rules_drop_unknown_effects_on_load():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {
		"reactive_effects": {"cat_command": "tint", "git_log": "blur", 7: "pulse"},
	})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_reactive_effects.size(), 1,
		"only the rule with a known effect id survives")
	assert_eq(str(SettingsManager.cfg_reactive_effects.get("cat_command", "")), "tint")

## The v0.8.7 backdrop is a closed two-value vocabulary: it survives a restart
## and a hand-edited file can only clamp into it.
func test_the_backdrop_survives_a_restart_and_clamps():
	SettingsManager.cfg_backdrop = SettingsManager.BACKDROP_GRADIENT
	SettingsManager.save_settings()

	SettingsManager.cfg_backdrop = SettingsManager.BACKDROP_FLAT
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_backdrop, SettingsManager.BACKDROP_GRADIENT,
		"the backdrop must survive a restart")

	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"backdrop": 9})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_backdrop, SettingsManager.BACKDROP_GRADIENT,
		"a value above the table clamps to the top")

	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"backdrop": -1})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_backdrop, SettingsManager.BACKDROP_FLAT,
		"a negative value clamps to flat")
