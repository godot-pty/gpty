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
const HINT := "Draws a GPU effect behind the terminal text. Off by default; text, selection and coloured cells stay opaque. A translucent window is the System tab's Window opacity, not an effect."
## The shader's own amplitudes are its constants; the setting scales them.
const STRENGTH := {SUBTLE: 0.5, FULL: 1.0}

## Registry order is the picker order. `budget_ms_*` are upper bounds borrowed
## from the v0.8.6 Dynamic Shaders row's measured FBM tree (0.29 ms at 1080p,
## 1.02 ms at 4K on an RTX 5070 Ti): this shader is strictly cheaper (one hash,
## half resolution at 30 Hz), and `effect_bench.gd` is the harness that will
## replace the borrowed figure when it runs on a real GPU. A static effect
## declares 0: its layer is redrawn only when the pane changes, never per frame.
const AMBIENT_IDS := ["crt", "grain"]
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
		"budget_ms_1080p": 0.29,
		"budget_ms_4k": 1.02,
		"hint": "Animated film grain in a half-resolution buffer at 30 Hz.",
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
