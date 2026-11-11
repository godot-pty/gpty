class_name AgentBadge
extends Control
## A terminal's agent-state badge: the display-only projection of the tiered
## AgentState tracker, drawn in the tile's title bar.
##
## Every state must be tellable apart with the hue removed - by a protan or
## deutan reader, in a monochrome screenshot, in a greyscale print - so the
## silhouette is the signal and the palette role only reinforces it. Three
## states draw a Phosphor glyph (`check-circle`, `x-circle`, `warning`: one
## closed ring with a mark, one with a cross, one triangle). `working` is
## **painted**, not a glyph: the font's available spinner shapes are thin arcs
## and dashes, and at badge size their partial pixel coverage faded the state
## to a smudge - measured on 0.8.0's release image at 11.7 ink pixels against
## 23.9-26.5 for the other three. A 2 px band reads as a ring at the same size
## and the moving notch carries the motion.
##
## Colour is read at draw time from `UiPalette.active()`, never cached: the
## palette switches at runtime.

## The badge's own footprint: the floor every icon-only control in the bar
## takes, so the badge matches the three buttons beside it.
const SIZE := Vector2(UiTokens.BUTTON_MIN_WIDTH, UiTokens.BUTTON_MIN_HEIGHT)

## The ring `working` paints: the outer edge of a 1.75 px band on a 6 px
## radius, with one notch of RING_GAP radians so the band reads as a closed ring
## rather than an open arc. One turn takes WORKING_TURN. The stroke is 1.75
## rather than the 2 the mock used because at 2 px the band measured 67 ink
## pixels against 48-51 for the 16 px glyphs - bolder than its siblings instead
## of equal to them - and 1.75 lands within the glyphs' range while keeping the
## notch open.
const RING_RADIUS := 6.0
const RING_STROKE := 1.75
const RING_GAP := 1.75
const RING_START := -PI / 2.0
const WORKING_TURN := 0.9
const PULSE_HZ := 1.2

## Every visible state, in one table. `kind` names the silhouette (asserted
## distinct: four states, four shapes); `glyph` is the Phosphor codepoint for
## the drawn states and empty for `working`, whose silhouette is geometry;
## `role` is the palette token, resolved when the badge paints; `label` is both
## the hover tooltip and the accessible name - a screen reader gets the words,
## never a private-use codepoint. `idle` is absent on purpose: it hides the
## badge.
const STATES := {
	"completed": {"kind": "check", "glyph": Icons.CHECK_CIRCLE, "role": "SUCCESS", "label": "Completed"},
	"failed": {"kind": "cross", "glyph": Icons.X_CIRCLE, "role": "DANGER", "label": "Failed"},
	"needs-attention": {"kind": "warning", "glyph": Icons.WARNING, "role": "WARNING", "label": "Needs attention"},
	"working": {"kind": "ring", "glyph": "", "role": "ACCENT", "label": "Working"},
}

var _state := ""
var _phase := 0.0

func _init() -> void:
	# PASS, not IGNORE: the tooltip is the state's words, and Godot resolves a
	# tooltip only for the control under the pointer.
	mouse_filter = MOUSE_FILTER_PASS
	custom_minimum_size = SIZE
	# A private-use glyph never reaches an assistive technology; the state's
	# words are the name, and `live` carries a change without focus.
	accessibility_live = A11y.LIVE_POLITE
	# Idle is the absence of a state, not a fifth silhouette: a badge nobody
	# declared anything to shows nothing.
	visible = false
	set_process(false)

## What this badge is showing, `""` while hidden.
func state() -> String:
	return _state

## A state animates itself: `working` turns its notch, `needs-attention`
## pulses. The other three are static, so they cost no frames.
static func animated(state: String) -> bool:
	return state == "working" or state == "needs-attention"

## The arc `working` paints for an animation phase, as (from, to) radians.
static func ring_angles(phase: float) -> Vector2:
	var from := RING_START + phase
	return Vector2(from, from + TAU - RING_GAP)

## Show `state` from its first frame: the clock resets, so a badge that lights
## up always does so at the same silhouette.
func show_state(state: String) -> void:
	_state = state
	_phase = 0.0
	var spec: Dictionary = STATES.get(state, {})
	if spec.is_empty():
		visible = false
		tooltip_text = ""
		accessibility_name = ""
		set_process(false)
		queue_redraw()
		return
	visible = true
	tooltip_text = str(spec["label"])
	accessibility_name = str(spec["label"])
	set_process(animated(_state))
	queue_redraw()

func _process(delta: float) -> void:
	_phase += delta
	queue_redraw()

## A palette switch rebuilds the one `Theme` at the workspace root, which
## reaches this node as a theme change; the tint is read at draw time, so the
## change only needs a repaint.
func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()

func _draw() -> void:
	var spec: Dictionary = STATES.get(_state, {})
	if spec.is_empty():
		return
	var colour: Color = UiPalette.active().color(str(spec["role"]))
	if _state == "needs-attention":
		# Pulsing amber; phase 0 is the frame the badge appears at.
		colour.a = 0.55 + 0.45 * sin(_phase * TAU * PULSE_HZ)
	if str(spec["kind"]) == "ring":
		var span := ring_angles(_phase * TAU / WORKING_TURN)
		draw_arc(size * 0.5, RING_RADIUS, span.x, span.y, 24, colour, RING_STROKE, true)
		return
	_draw_glyph(str(spec["glyph"]), colour)

## Centre a Phosphor glyph in the box: the codepoint is an icon, so its ink box
## is the only thing to centre, not the font's line box.
func _draw_glyph(glyph: String, colour: Color) -> void:
	var font: Font = Icons.font_resource
	var ascent := font.get_ascent(UiTokens.FS_HEADING)
	var height := ascent + font.get_descent(UiTokens.FS_HEADING)
	var width := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1,
		UiTokens.FS_HEADING).x
	draw_string(font, Vector2((size.x - width) * 0.5, (size.y - height) * 0.5 + ascent),
		glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTokens.FS_HEADING, colour)
