class_name UiEffects
extends RefCounted
## The closed terminal-effect table and the intensity policy behind it.
##
## A shader is code, so every path the app can run is a `preload` constant in
## this table - the `PaneTypes.ALL` rule applied to effects. A profile, a
## settings file or a plugin can carry an id from here and nothing else; an id
## this build does not know falls back to the default (or to no cue).
##
## Two halves: ambient effects paint a terminal pane's ground (and are off
## until the intensity moves), reactive cues answer a concept event with one
## short pane-local flash. Nothing here is cached: a settings save applies to
## the next paint without a restart, the way `UiMotion` reads its level.

const OFF := 0
const SUBTLE := 1
const FULL := 2
const LABELS := ["Off", "Subtle", "Full"]
const HINT := "Draws a GPU effect behind the terminal text, the sidebar ground, or both (Scope below). Off by default; text, selection and coloured cells stay opaque. A translucent window is the System tab's Window opacity, not an effect."
## The shader's own amplitudes are its constants; the setting scales them.
const STRENGTH := {SUBTLE: 0.5, FULL: 1.0}

## Registry order is the picker order. `budget_ms_*` are the declared frame
## upper bounds: measured 2026-11-25 with `effect_bench.gd` on the RTX 5070 Ti
## at 1920x1080 and 3840x2160 on both renderers, every delta was at or under the
## harness's ~0.2 ms floor (raw deltas 0-26 us; the run is recorded in
## docs/content/docs/agents/testing.md, "Effect frame cost"). 0.05 is therefore
## the table's positive floor, not a claim the shader resolves below it. A
## static effect declares 0: its layer is redrawn only when the pane changes,
## never per frame.
const AMBIENT_IDS := ["crt", "grain", "vignette", "aurora", "dither"]
const DEFAULT_AMBIENT := "crt"
const AMBIENT := {
	"crt": {
		"label": "CRT scanlines",
		"shader": preload("res://shaders/effects/crt.gdshader"),
		"animated": false,
		"hz": 0,
		"budget_ms_1080p": 0.0,
		"budget_ms_4k": 0.0,
		"hint": "Scanlines, a phosphor mask and a vignette, drawn once per pane change.",
	},
	"grain": {
		"label": "Film grain",
		"shader": preload("res://shaders/effects/grain.gdshader"),
		"animated": true,
		"hz": 30,
		"budget_ms_1080p": 0.05,
		"budget_ms_4k": 0.05,
		"hint": "Animated film grain in a half-resolution buffer at 30 Hz.",
	},
	"vignette": {
		"label": "Vignette",
		"shader": preload("res://shaders/effects/vignette.gdshader"),
		"animated": false,
		"hz": 0,
		"budget_ms_1080p": 0.0,
		"budget_ms_4k": 0.0,
		"hint": "A soft edge falloff with a lifted centre, drawn once per pane change.",
	},
	"aurora": {
		"label": "Aurora",
		"shader": preload("res://shaders/effects/aurora.gdshader"),
		"animated": true,
		"hz": 30,
		"budget_ms_1080p": 0.05,
		"budget_ms_4k": 0.05,
		"hint": "Two slow ribbons of light in a half-resolution buffer at 30 Hz.",
	},
	"dither": {
		"label": "Ordered dither",
		"shader": preload("res://shaders/effects/dither.gdshader"),
		"animated": false,
		"hz": 0,
		"budget_ms_1080p": 0.0,
		"budget_ms_4k": 0.0,
		"hint": "A 4x4 ordered dither that breaks the ground into fine steps; drawn once per pane change.",
	},
}

## Reactive cues: one tone per effect, fixed here rather than per rule. Tint is
## the warning cue (a failing command), particles the success cue, pulse the
## neutral one - the examples the roadmap row names.
const REACTIVE_IDS := ["tint", "pulse", "particles"]
const MAX_RULES := 8
const MAX_CONCEPT_NAME := 64
const REACTIVE_HINT := "Cue a pane when one of its concepts matches. A pane cues at most three times a second; the effect is display-only."
const REACTIVE := {
	"tint": {
		"label": "Tint (red)",
		"tone": "DANGER",
		"hint": "A red wash over the pane, fading out.",
	},
	"pulse": {
		"label": "Pulse (accent)",
		"tone": "ACCENT",
		"hint": "A border pulse in the accent colour.",
	},
	"particles": {
		"label": "Particles (green)",
		"tone": "SUCCESS",
		"hint": "A short green spark burst from the pane's lower edge.",
	},
}

## The stored intensity, clamped: a hand-edited file cannot make a level the
## pickers cannot show.
static func level() -> int:
	return clampi(SettingsManager.cfg_effect_intensity, OFF, FULL)

## What the shader's `strength` uniform gets at the current level (0 at Off).
static func strength() -> float:
	return float(STRENGTH.get(level(), 0.0))

## The ambient effect a pane should paint: the stored id when the table knows
## it, the default otherwise.
static func ambient_id() -> String:
	return sanitize_ambient(str(SettingsManager.cfg_effect))

static func sanitize_ambient(id: String) -> String:
	return id if AMBIENT.has(id) else DEFAULT_AMBIENT

static func ambient_label(id: String) -> String:
	if not AMBIENT.has(id):
		return id
	return str(AMBIENT[id]["label"])

## Which ground carries the ambient effect. Reactive cues are pane-local answers
## to a concept event and are not affected by this scope.
const SCOPE_PANES := 0
const SCOPE_BOTH := 1
const SCOPE_SIDEBAR := 2
const SCOPE_LABELS := ["Panes", "Panes and sidebar", "Sidebar only"]
const SCOPE_HINT := "Which ground carries the ambient effect. Reactive cues always fire on panes."
const SCOPE_PANES_EXCLUDED_HINT := "Sidebar only: terminal panes draw no ambient effect until the scope includes them."

static func scope() -> int:
	return clampi(SettingsManager.cfg_effect_scope, SCOPE_PANES, SCOPE_SIDEBAR)

static func panes_in_scope() -> bool:
	return scope() != SCOPE_SIDEBAR

static func sidebar_in_scope() -> bool:
	return scope() != SCOPE_PANES

## The id a pane's ground should paint: the stored effect only when panes are in
## scope, so "sidebar only" draws no global effect in a pane even when the pane's
## own settings name one.
static func pane_ambient_id() -> String:
	return ambient_id() if panes_in_scope() else ""

static func reactive_label(id: String) -> String:
	if not REACTIVE.has(id):
		return id
	return str(REACTIVE[id]["label"])

## The stored concept -> cue map, filtered to the closed vocabulary.
##
## The keys are user-authored concept names (never a path or code): a rule for a
## concept this build does not currently carry is kept, because a disabled
## concept or an uninstalled plugin can come back. Values outside the table are
## dropped, and the table is capped so a hand-edited file cannot grow the
## settings UI without bound.
static func sanitize_reactive(raw) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for key in raw:
		if not (key is String):
			continue
		var name: String = key
		if name.is_empty() or name.length() > MAX_CONCEPT_NAME:
			continue
		if _has_control_char(name):
			continue
		var effect := str(raw[key])
		if not REACTIVE.has(effect):
			continue
		out[name] = effect
		if out.size() >= MAX_RULES:
			break
	return out

## The cue a concept event fires, or "" when no rule names it or the stored
## effect is not in the table.
static func reactive_for(concept_name: String) -> String:
	if concept_name == "":
		return ""
	var effect := str(SettingsManager.cfg_reactive_effects.get(concept_name, ""))
	return effect if REACTIVE.has(effect) else ""

## The cue's colour, read from the active palette at call time so an appearance
## switch reaches the next flash (never a class-body palette read).
static func tone_color(id: String) -> Color:
	var entry = REACTIVE.get(id)
	if entry == null:
		return UiPalette.active().TEXT
	return UiPalette.active().color(str(entry["tone"]))

static func _has_control_char(text: String) -> bool:
	for i in text.length():
		if text.unicode_at(i) < 32 or text.unicode_at(i) == 127:
			return true
	return false
