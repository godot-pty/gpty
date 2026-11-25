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
# opened tab). A dismissal is its mirror: a surface that goes away (a closed
# search strip, a chevron with nothing left in its direction). Content being
# read never animates, and a filtered list is an update, not an arrival.
# Durations live here so a consumer chooses a surface, not a curve; `arrive`
# and `dismiss` are the only implementations.

## The shared fade; at Full a caller may ask for a rise.
const ARRIVAL_MS := 120.0
const ARRIVAL_RISE_PX := 4.0
## A created row's stagger. At most three rows stagger; a restore never does.
const ARRIVAL_STAGGER_MS := 30.0
const ARRIVAL_MAX_STAGGERED := 3
## The companion fade for a surface leaving; no rise either way.
const DISMISS_MS := 100.0
const ARRIVAL_META := "gpty_arrival"

## `declared_s` when any motion is on, zero at Off: the conversion for a
## duration a caller declares (a toast's fade, the focus sweep). A path with
## its own clock (the guide's reveal) or its own tween (an arrival)
## short-circuits at Off instead.
static func duration_s(declared_s: float) -> float:
	if not enabled():
		return 0.0
	return maxf(declared_s, 0.0)

## The stagger for the `slot`th appended row: zero unless Full, and only the
## first `ARRIVAL_MAX_STAGGERED` rows may stagger.
static func stagger_ms(slot: int) -> float:
	if not allows_overshoot() or slot < 0 or slot >= ARRIVAL_MAX_STAGGERED:
		return 0.0
	return float(slot) * ARRIVAL_STAGGER_MS

## The appended rows of a grown list, or an empty array. Only a pure append to
## a non-empty list is an arrival: a first render, a restore, a replacement, a
## reorder and a rename all return nothing, and a list that grew by more than
## `ARRIVAL_MAX_STAGGERED` rows is a content change, not a created row.
static func appended_indices(previous: Array, next: Array) -> Array[int]:
	var out: Array[int] = []
	if previous.is_empty() or next.size() <= previous.size():
		return out
	if next.size() > previous.size() + ARRIVAL_MAX_STAGGERED:
		return out
	for i in previous.size():
		if previous[i] != next[i]:
			return out
	for i in range(previous.size(), next.size()):
		out.append(i)
	return out

## Fade `node` in from its own alpha; at Full, rise `rise_px` into place.
## Returns the tween (pinnable by `pin_arrival`), or null when the final frame
## is already drawn: Off, a zero duration, or a node not inside the tree (a
## surface built off-tree arrives final rather than freezing at alpha 0).
##
## Interrupting a running ramp reverses from the alpha on screen and keeps the
## surface's settled colour as the target; a repeat arrival on a settled
## surface still starts transparent, so a re-shown surface fades again.
static func arrive(node: Control, duration_ms := ARRIVAL_MS, rise_px := 0.0,
		delay_ms := 0.0) -> Tween:
	if node == null or not is_instance_valid(node):
		return null
	var previous := _record_of(node)
	if not previous.is_empty():
		_kill(previous)
	var settled: Color = node.modulate
	if previous.get("rgb") is Color:
		settled = previous["rgb"]
	var duration := maxf(float(duration_ms), 0.0) / 1000.0
	if duration <= 0.0 or not enabled() or not node.is_inside_tree():
		node.modulate = settled
		# Keep the settled colour (a later ramp reads it), but record the final
		# frame so a settled surface is not mistaken for an interrupted ramp.
		if not previous.is_empty():
			previous["from"] = settled.a
			previous["to"] = settled.a
			previous["rgb"] = settled
			previous["rise"] = 0.0
			previous["base_y"] = node.position.y
			previous["tween"] = null
			node.set_meta(ARRIVAL_META, previous)
		return null
	var start := 0.0
	if not previous.is_empty() \
			and absf(node.modulate.a - float(previous.get("to", node.modulate.a))) > 0.001:
		start = node.modulate.a
	node.set_meta(ARRIVAL_META, {
		"duration": duration,
		"delay": maxf(float(delay_ms), 0.0) / 1000.0,
		"rise": float(rise_px) if level() == FULL else 0.0,
		"base_y": node.position.y,
		"rgb": settled,
		"from": start,
		"to": settled.a,
	})
	return _play_arrival(node)

## Fade `node` out and hide it; `finished` runs once the node is hidden (and
## immediately at Off). The node's settled alpha is kept in the record, so a
## later `arrive` brings it back to full rather than to whatever the fade left.
static func dismiss(node: Control, duration_ms := DISMISS_MS,
		finished := Callable()) -> Tween:
	if node == null or not is_instance_valid(node):
		return null
	var previous := _record_of(node)
	if not previous.is_empty():
		_kill(previous)
	var settled: Color = node.modulate
	if previous.get("rgb") is Color:
		settled = previous["rgb"]
	var duration := maxf(float(duration_ms), 0.0) / 1000.0
	if duration <= 0.0 or not enabled() or not node.is_inside_tree():
		node.modulate.a = 0.0
		node.visible = false
		# The settled colour must survive the instant hide: a later arrival
		# restores it instead of restoring alpha 0.
		if not previous.is_empty():
			previous["from"] = 0.0
			previous["to"] = 0.0
			previous["rgb"] = settled
			previous["rise"] = 0.0
			previous["tween"] = null
			node.set_meta(ARRIVAL_META, previous)
		if finished.is_valid():
			finished.call()
		return null
	node.set_meta(ARRIVAL_META, {
		"duration": duration,
		"delay": 0.0,
		"rise": 0.0,
		"base_y": node.position.y,
		"rgb": settled,
		"from": node.modulate.a,
		"to": 0.0,
	})
	var tw := _play_arrival(node)
	if tw == null:
		node.visible = false
		if finished.is_valid():
			finished.call()
		return null
	# `_play_arrival` runs its tweeners in parallel; `chain` puts the hide after
	# the longest of them.
	tw.chain().tween_callback(func():
		node.visible = false
		if finished.is_valid():
			finished.call())
	return tw

## The record an earlier `arrive`/`dismiss` left on `node`, or `{}`.
static func _record_of(node: Control) -> Dictionary:
	if not node.has_meta(ARRIVAL_META):
		return {}
	var record = node.get_meta(ARRIVAL_META)
	return record if record is Dictionary else {}

## Kill the ramp a record names. Called before every new ramp, so an interrupted
## surface leaves exactly one tween.
static func _kill(record: Dictionary) -> void:
	var old = record.get("tween")
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()

## Rebuild and start the ramp recorded on `node`. The one builder: `arrive`,
## `dismiss` and `pin_arrival` all use it, so a pinned frame is the shipped
## curve.
static func _play_arrival(node: Control) -> Tween:
	if not node.has_meta(ARRIVAL_META):
		return null
	var record: Dictionary = node.get_meta(ARRIVAL_META)
	_kill(record)
	var rgb: Color = record["rgb"]
	var from := float(record["from"])
	var to := float(record["to"])
	var duration := float(record["duration"])
	var delay := float(record["delay"])
	var rise := float(record["rise"])
	var base_y := float(record["base_y"])
	node.modulate = Color(rgb.r, rgb.g, rgb.b, from)
	node.position.y = base_y + rise
	var tw := node.create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "modulate:a", to, duration).set_delay(delay)
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
