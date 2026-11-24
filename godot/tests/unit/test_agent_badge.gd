extends GutTest
# AgentBadge — the title bar's agent-state badge. The badge exists so a state
# is readable with the hue removed, so what is asserted here is the silhouette
# contract (`working` is a closed band with one notch, not the font's thin arc
# that measured at half its siblings' ink) and the two paths a user who cannot
# see the shape at all depends on: the pointer's tooltip and the reader's name.
# The state table's own contents (four shapes, three glyphs, roles, labels) are
# asserted once, in the integration test, so nothing is pinned twice.

func before_each():
	# The badge reads the live Motion setting; a developer's own store must not
	# decide whether these assertions see frames.
	SettingsManager.cfg_motion = UiMotion.SUBTLE

func after_each():
	SettingsManager.cfg_motion = UiMotion.SUBTLE


# ── Silhouette ─────────────────────────────────────────────────────────

func test_the_working_ring_is_a_closed_band_with_one_notch():
	var span := AgentBadge.ring_angles(0.0)
	assert_almost_eq(span.y - span.x, TAU - AgentBadge.RING_GAP, 0.001,
		"the band spans the whole circle but the notch")
	assert_lt(AgentBadge.RING_GAP, TAU / 3.0,
		"the gap is a notch, not half a ring: the open arc read as a smudge at badge size")

func test_the_notch_advances_with_the_animation_phase():
	assert_almost_eq(AgentBadge.ring_angles(0.4).x - AgentBadge.ring_angles(0.0).x, 0.4,
		0.0001, "the notch travels the phase it is given")

func test_only_the_two_animated_states_tick():
	assert_true(AgentBadge.animated("working"), "the working notch turns")
	assert_true(AgentBadge.animated("needs-attention"), "the attention triangle pulses")
	for state in ["completed", "failed", ""]:
		assert_false(AgentBadge.animated(state), "%s is a still silhouette" % state)


# ── Words ──────────────────────────────────────────────────────────────

## A private-use codepoint is unreadable to a screen reader, so the state's
## words are the badge's accessible name; and a tooltip only resolves for the
## control under the pointer, which is what `mouse_filter` decides.
func test_a_state_names_itself_for_the_pointer_and_the_reader():
	var badge := AgentBadge.new()
	add_child_autofree(badge)
	badge.show_state("needs-attention")
	assert_true(badge.visible, "a declared state shows the badge")
	assert_eq(badge.state(), "needs-attention")
	assert_eq(badge.tooltip_text, "Needs attention", "the tooltip names the state")
	assert_eq(badge.accessibility_name, "Needs attention",
		"the accessible name names the state, not a codepoint")
	assert_eq(badge.accessibility_live, A11y.LIVE_POLITE,
		"a state change must reach a screen reader without focus")
	assert_ne(badge.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"a tooltip needs the badge to be the control under the pointer")
	assert_true(badge.is_processing(), "the pulse needs frames")

	badge.show_state("completed")
	assert_false(badge.is_processing(), "a still silhouette costs no frames")
	assert_eq(badge.tooltip_text, "Completed")

	badge.show_state("")
	assert_false(badge.visible, "idle hides the badge")
	assert_eq(badge.tooltip_text, "", "a hidden badge keeps no tooltip")
	assert_eq(badge.accessibility_name, "", "a hidden badge announces nothing")
	assert_false(badge.is_processing(), "a hidden badge costs no frames")


# ── The Motion setting ─────────────────────────────────────────────────

## Motion Off is a promise about the screen, not about the next restart: the
## badge keeps the silhouette a capture pins (phase 0) and gives up its frames
## the moment the setting moves.
func test_motion_off_stops_the_clock_at_the_pinned_frame():
	SettingsManager.cfg_motion = UiMotion.OFF
	var badge := AgentBadge.new()
	add_child_autofree(badge)
	badge.show_state("working")
	assert_false(badge.is_processing(), "Off draws a still notch")
	assert_eq(badge._phase, 0.0, "the frame a capture pins")
	assert_true(badge.visible)

	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.settings_changed.emit()
	assert_true(badge.is_processing(), "turning Motion back on restarts the turn")

	SettingsManager.cfg_motion = UiMotion.OFF
	SettingsManager.settings_changed.emit()
	assert_false(badge.is_processing())
	assert_eq(badge._phase, 0.0)
