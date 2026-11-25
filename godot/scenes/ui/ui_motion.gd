class_name UiMotion
## The one motion policy every animation reads.
##
## Settings > Appearance > Motion stores `SettingsManager.cfg_motion`; this class
## is the only place that interprets it. Nothing is cached: a settings save
## applies to the next transition without a restart.
##
## The three levels are about amplitude, not a switch plus a speed. Off draws
## the final frame; Subtle eases with no overshoot; Full lets each animation use
## its declared overshoot, capped at `MAX_OVERSHOOT_PCT` so a transition can
## never wander far enough to overlap a neighbour visibly.

const OFF := 0
const SUBTLE := 1
const FULL := 2
const LABELS := ["Off", "Subtle", "Full"]
## The ceiling on an animation's own `overshoot_pct`. The settings schema caps
## the stored value at the same number; this is the runtime clamp, so a
## hand-edited store cannot exceed it either.
const MAX_OVERSHOOT_PCT := 3.0
const HINT := "Off draws every pane change in one frame. Subtle eases without overshoot. Full allows each animation's overshoot, capped at 3 %."

static func level() -> int:
	return clampi(SettingsManager.cfg_motion, OFF, FULL)

static func enabled() -> bool:
	return level() != OFF

static func allows_overshoot() -> bool:
	return level() == FULL

## The fractional overshoot an animation's declared percent may use: zero at
## Subtle (and Off), the declared value capped at `MAX_OVERSHOOT_PCT` at Full.
static func overshoot(declared_pct: float) -> float:
	if not allows_overshoot():
		return 0.0
	return clampf(declared_pct, 0.0, MAX_OVERSHOOT_PCT) / 100.0

# ── Durations and arrivals ─────────────────────────────────────────────
#
# The one arrival: a surface that appears (an empty state, a created row, an
# opened tab). Content being read never animates, and a filtered list is an
# update, not an arrival. Durations live here so a consumer chooses a surface,
# not a curve; `arrive` is the only implementation.

## The shared fade; at Full a caller may ask for a rise.
const ARRIVAL_MS := 120.0
const ARRIVAL_RISE_PX := 4.0
## A created row's stagger. At most three rows stagger; a restore never does.
const ARRIVAL_STAGGER_MS := 30.0
const ARRIVAL_MAX_STAGGERED := 3
const ARRIVAL_META := "gpty_arrival"

## `declared_s` when any motion is on, zero at Off: the conversion for a
## duration a caller declares (a toast's fade, the focus sweep). A path with
## its own clock (the guide's reveal) or its own tween (an arrival)
## short-circuits at Off instead.
static func duration_s(declared_s: float) -> float:
	if not enabled():
		return 0.0
	return maxf(declared_s, 0.0)

## Fade `node` in from its own alpha; at Full, rise `rise_px` into place.
## Returns the tween (pinnable by `pin_arrival`), or null when the final frame
## is already drawn: Off, a zero duration, or a node not inside the tree (a
## surface built off-tree arrives final rather than freezing at alpha 0).
static func arrive(node: Control, duration_ms := ARRIVAL_MS, rise_px := 0.0,
		delay_ms := 0.0) -> Tween:
	if node == null or not is_instance_valid(node) or not enabled():
		return null
	if not node.is_inside_tree():
		return null
	var duration := maxf(float(duration_ms), 0.0) / 1000.0
	if duration <= 0.0:
		return null
	var target: Color = node.modulate
	node.set_meta(ARRIVAL_META, {
		"duration": duration,
		"delay": maxf(float(delay_ms), 0.0) / 1000.0,
		"rise": float(rise_px) if level() == FULL else 0.0,
		"base_y": node.position.y,
		"alpha": target.a,
		"rgb": target,
	})
	return _play_arrival(node)

## Rebuild and start the arrival recorded on `node`. The one builder: `arrive`
## and `pin_arrival` both use it, so a pinned frame is the shipped curve.
static func _play_arrival(node: Control) -> Tween:
	if not node.has_meta(ARRIVAL_META):
		return null
	var record: Dictionary = node.get_meta(ARRIVAL_META)
	var old = record.get("tween")
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()
	var target: Color = record["rgb"]
	var duration := float(record["duration"])
	var delay := float(record["delay"])
	var rise := float(record["rise"])
	var base_y := float(record["base_y"])
	node.modulate = Color(target.r, target.g, target.b, 0.0)
	node.position.y = base_y + rise
	var tw := node.create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "modulate:a", target.a, duration).set_delay(delay)
	if rise > 0.0:
		tw.tween_property(node, "position:y", base_y, duration) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	record["tween"] = tw
	return tw

## Freeze a staged arrival at `progress` (0-1) for a capture, whether it is
## still running or already finished: rebuild it and step it while paused, so
## the pinned frame is the shipped curve, not a copy of its easing.
static func pin_arrival(node: Control, progress: float) -> void:
	if node == null or not is_instance_valid(node) or not node.has_meta(ARRIVAL_META):
		return
	if not node.is_inside_tree():
		return
	var record: Dictionary = node.get_meta(ARRIVAL_META)
	var tw := _play_arrival(node)
	if tw == null:
		return
	tw.pause()
	tw.custom_step(float(record["duration"]) * clampf(progress, 0.0, 1.0))
