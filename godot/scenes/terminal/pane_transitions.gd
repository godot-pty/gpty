class_name PaneTransitions
extends RefCounted
## Pane motion: the animation registry, the stored-choice resolution and the
## tween runner every pane create, close and position swap goes through.
##
## An animation is one entry in `ANIMATIONS`: the transitions it serves, the
## channels it touches, and the properties the settings panel exposes as rows.
## Adding one is that entry plus, for a channel the runner does not have yet,
## one branch in the `create`/`close`/`swap` path - never code in the workspace
## or the settings panel.
##
## The workspace owns one instance. It holds the live tweens and the wrapper of
## a closing pane (the "ghost") until the exit finishes; one instance per
## workspace means a ghost or a tween dies with the grid it came from.

const KINDS := ["create", "close", "swap"]

## The animation a transition plays until the user picks another.
const DEFAULTS := {"create": "fade_scale", "close": "fade_scale", "swap": "move"}

## Registry order is the picker order, `none` first. `channels` is the closed
## vocabulary the runner draws: "alpha", "scale" and "slide" for create/close;
## a swap always moves the wrapper between rects, and declares "fade" when it
## dissolves through the midpoint instead of sliding between them.
const ANIMATIONS := {
	"none": {
		"label": "None",
		"kinds": ["create", "close", "swap"],
		"channels": [],
		"params": [],
	},
	"fade": {
		"label": "Fade",
		"kinds": ["create", "close"],
		"channels": ["alpha"],
		"params": [
			{"key": "duration_ms", "label": "Duration (ms)", "default": 120.0, "min": 40.0, "max": 600.0, "step": 10.0},
		],
	},
	"fade_scale": {
		"label": "Fade and Scale",
		"kinds": ["create", "close"],
		"channels": ["alpha", "scale"],
		"params": [
			{"key": "duration_ms", "label": "Duration (ms)", "default": 160.0, "min": 40.0, "max": 600.0, "step": 10.0},
			{"key": "scale_from", "label": "Scale from", "default": 0.92, "min": 0.80, "max": 1.0, "step": 0.01},
			{"key": "overshoot_pct", "label": "Overshoot (%)", "default": 2.0, "min": 0.0, "max": 3.0, "step": 0.5},
		],
	},
	"slide": {
		"label": "Slide",
		"kinds": ["create", "close"],
		"channels": ["alpha", "slide"],
		"params": [
			{"key": "duration_ms", "label": "Duration (ms)", "default": 200.0, "min": 40.0, "max": 600.0, "step": 10.0},
			{"key": "distance_px", "label": "Distance (px)", "default": 48.0, "min": 8.0, "max": 240.0, "step": 4.0},
		],
	},
	"pop": {
		"label": "Pop",
		"kinds": ["create", "close"],
		"channels": ["alpha", "scale"],
		"params": [
			{"key": "duration_ms", "label": "Duration (ms)", "default": 120.0, "min": 40.0, "max": 600.0, "step": 10.0},
			{"key": "scale_from", "label": "Scale from", "default": 0.55, "min": 0.2, "max": 1.0, "step": 0.01},
			{"key": "overshoot_pct", "label": "Overshoot (%)", "default": 3.0, "min": 0.0, "max": 3.0, "step": 0.5},
		],
	},
	"move": {
		"label": "Move",
		"kinds": ["swap"],
		"channels": [],
		"params": [
			{"key": "duration_ms", "label": "Duration (ms)", "default": 180.0, "min": 40.0, "max": 600.0, "step": 10.0},
		],
	},
	"crossfade": {
		"label": "Crossfade",
		"kinds": ["swap"],
		"channels": ["fade"],
		"params": [
			{"key": "duration_ms", "label": "Duration (ms)", "default": 220.0, "min": 40.0, "max": 600.0, "step": 10.0},
		],
	},
}

# ── Registry and stored settings (static, no state) ─────────────────────

## Every animation id that serves `kind`, in registry order.
static func animations_for(kind: String) -> Array[String]:
	var out: Array[String] = []
	for id in ANIMATIONS:
		var def: Dictionary = ANIMATIONS[id]
		if (def["kinds"] as Array).has(kind):
			out.append(str(id))
	return out

static func animation_label(id: String) -> String:
	if not ANIMATIONS.has(id):
		return id
	return str(ANIMATIONS[id]["label"])

static func is_valid(kind: String, id: String) -> bool:
	if not KINDS.has(kind) or not ANIMATIONS.has(id):
		return false
	return (ANIMATIONS[id]["kinds"] as Array).has(kind)

## The id `kind` will play right now: the stored choice when it serves that
## transition, otherwise the kind's default. Unknown ids in the store (an old
## build, a hand-edited file) never reach the runner.
static func choice(kind: String) -> String:
	var id := str(SettingsManager.cfg_pane_animation.get(kind, ""))
	if is_valid(kind, id):
		return id
	return str(DEFAULTS.get(kind, "none"))

## The property schema `kind` exposes for `id` (empty for `none`/unknown).
static func param_schema(kind: String, id: String) -> Array:
	if not is_valid(kind, id):
		return []
	return ANIMATIONS[id]["params"]

## The values a transition runs with: schema defaults overlaid by the stored
## `"<kind>:<id>"` entry, every value clamped to its schema range.
static func param_values(kind: String, id: String) -> Dictionary:
	var stored := {}
	var raw = SettingsManager.cfg_pane_animation_params.get(kind + ":" + id, {})
	if raw is Dictionary:
		stored = raw
	var out := {}
	for p in param_schema(kind, id):
		var key := str(p["key"])
		out[key] = _param_value(p, stored.get(key, p["default"]))
	return out

## A complete `{kind: id}` map for any stored value: missing, unknown and
## wrong-kind ids all fall back to the kind's default.
static func sanitize_choices(raw: Dictionary) -> Dictionary:
	var out := {}
	for kind in KINDS:
		var k := str(kind)
		var id := str(raw.get(k, ""))
		out[k] = id if is_valid(k, id) else str(DEFAULTS[k])
	return out

## A stored parameter map reduced to what a transition can use: keys are
## `"<kind>:<id>"` pairs the registry declares, and each value is a declared
## property clamped to its range. Anything else is a store from another build.
static func sanitize_params_store(raw: Dictionary) -> Dictionary:
	var out := {}
	for raw_key in raw:
		var key := str(raw_key)
		var sep := key.find(":")
		if sep <= 0 or sep >= key.length() - 1:
			continue
		var kind := key.substr(0, sep)
		var id := key.substr(sep + 1)
		if not is_valid(kind, id):
			continue
		var stored = raw[raw_key]
		if not (stored is Dictionary):
			continue
		var clean := {}
		for p in param_schema(kind, id):
			var param_key := str(p["key"])
			clean[param_key] = _param_value(p, stored.get(param_key, p["default"]))
		if not clean.is_empty():
			out[key] = clean
	return out

static func _param_value(p: Dictionary, v) -> float:
	if not (v is float or v is int):
		return float(p["default"])
	var f := float(v)
	if not is_finite(f):
		return float(p["default"])
	return clampf(f, float(p["min"]), float(p["max"]))

## The displacement a slide starts at, in the wrapper's parent space:
## `distance` px toward the tile's split edge, so the pane enters from the seam
## it was carved along. Clamped to the parent, so a ghost whose tile has since
## moved never slides outside its grid. An unknown or absent edge (a restored
## tile) returns zero and the slide channel draws nothing.
static func _slide_offset(w: Control, edge: String, distance: float) -> Vector2:
	var off := Vector2.ZERO
	match edge:
		"right": off = Vector2(-distance, 0.0)
		"left": off = Vector2(distance, 0.0)
		"bottom": off = Vector2(0.0, -distance)
		"top": off = Vector2(0.0, distance)
	if off == Vector2.ZERO:
		return off
	var parent := w.get_parent()
	if not (parent is Control):
		return off
	var area := (parent as Control).size
	var room_left := maxf(w.position.x, 0.0)
	var room_right := maxf(area.x - w.position.x - w.size.x, 0.0)
	var room_top := maxf(w.position.y, 0.0)
	var room_bottom := maxf(area.y - w.position.y - w.size.y, 0.0)
	off.x = clampf(off.x, -room_left, room_right)
	off.y = clampf(off.y, -room_top, room_bottom)
	return off

# ── Runner (instance: the live tweens and ghosts) ───────────────────────

## wrapper -> {tween, kind, to: Rect2, base_modulate: Color}.
var _entries := {}

## How many transitions are playing. Prunes wrappers a teardown freed first, so
## a test reads the real number.
func playing() -> int:
	_prune()
	return _entries.size()

## Freeze every playing transition at `progress` (0-1) for a capture. Each entry
## carries the duration its tween was built with, so the pinned frame is the
## shipped curve rather than a re-derived one.
func pin(progress: float) -> void:
	_prune()
	var t := clampf(progress, 0.0, 1.0)
	for w in _entries:
		var entry: Dictionary = _entries[w]
		var tw = entry.get("tween")
		if tw is Tween and (tw as Tween).is_valid():
			(tw as Tween).pause()
			(tw as Tween).custom_step(float(entry.get("duration", 0.0)) * t)

## Draw a newly spawned wrapper with the selected create animation. `edge` is
## the tile's split side (`left`/`right`/`top`/`bottom`), which a slide enters
## from; `""` for a tile no split carved. False means the final frame is
## already drawn (motion off, `none`, or nothing to animate).
func create(w: Control, allowed: bool, edge: String = "") -> bool:
	if not _animatable(w, allowed, "create") or _dying(w):
		return false
	var id := choice("create")
	var def: Dictionary = ANIMATIONS[id]
	var p := param_values("create", id)
	var channels: Array = def["channels"]
	var base: Color = w.modulate
	var d := float(p.get("duration_ms", 160.0)) / 1000.0

	_claim(w, true)
	var to := Rect2(w.position, w.size)
	w.pivot_offset = w.size * 0.5
	var tw := w.create_tween()
	tw.set_parallel(true)
	if channels.has("alpha"):
		w.modulate = Color(base.r, base.g, base.b, 0.0)
		tw.tween_property(w, "modulate:a", base.a, d)
	if channels.has("slide"):
		var off := _slide_offset(w, edge, float(p.get("distance_px", 48.0)))
		if off != Vector2.ZERO:
			w.position = to.position + off
			tw.tween_property(w, "position", to.position, d) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if channels.has("scale"):
		var from := float(p.get("scale_from", 1.0))
		w.scale = Vector2(from, from)
		var peak := 1.0 + UiMotion.overshoot(float(p.get("overshoot_pct", 0.0)))
		if peak > 1.0:
			tw.tween_property(w, "scale", Vector2(peak, peak), d * 0.75) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.chain()
			tw.tween_property(w, "scale", Vector2.ONE, d * 0.25) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		else:
			tw.tween_property(w, "scale", Vector2.ONE, d) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.finished.connect(_finish.bind(w))
	_entries[w] = {"tween": tw, "kind": "create", "to": to, "base_modulate": base, "duration": d}
	return true

## Play a closing wrapper's exit and free it when the transition ends. This
## owns the free on every path: when the animation is off, `none`, or the
## wrapper cannot animate, it is freed at once and this answers false. `edge`
## is the closed tile's split side, which a slide exit moves toward.
func close(w: Control, allowed: bool, edge: String = "") -> bool:
	if not is_instance_valid(w):
		return false
	if not _animatable(w, allowed, "close"):
		w.queue_free()
		return false
	var id := choice("close")
	var def: Dictionary = ANIMATIONS[id]
	var p := param_values("close", id)
	var channels: Array = def["channels"]
	var base: Color = w.modulate
	var d := float(p.get("duration_ms", 160.0)) / 1000.0

	# No snap: a pane closed while its create is still playing must fade from
	# where it is, not flash to full opacity first.
	_claim(w, false)
	_make_inert(w)
	w.pivot_offset = w.size * 0.5
	var tw := w.create_tween()
	tw.set_parallel(true)
	if channels.has("alpha"):
		tw.tween_property(w, "modulate:a", 0.0, d)
	if channels.has("scale"):
		var to := float(p.get("scale_from", 1.0))
		tw.tween_property(w, "scale", Vector2(to, to), d) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	if channels.has("slide"):
		var off := _slide_offset(w, edge, float(p.get("distance_px", 48.0)))
		if off != Vector2.ZERO:
			tw.tween_property(w, "position", w.position + off, d) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.finished.connect(_finish.bind(w))
	_entries[w] = {"tween": tw, "kind": "close", "to": Rect2(w.position, w.size), "base_modulate": base, "duration": d}
	return true

## Ease two wrappers between the rects they were drawn at (`before`) and the
## rects the layout just gave them; a `fade` animation dissolves them through
## the midpoint instead.
func swap(before: Dictionary, allowed: bool) -> bool:
	var id := choice("swap")
	if not allowed or not UiMotion.enabled() or id == "none":
		return false
	var def: Dictionary = ANIMATIONS[id]
	var fade: bool = (def["channels"] as Array).has("fade")
	var d := float(param_values("swap", id).get("duration_ms", 180.0)) / 1000.0
	var started := false
	for w in before:
		if not (w is Control) or not is_instance_valid(w):
			continue
		var wrapper := w as Control
		if _dying(wrapper):
			continue
		if not wrapper.is_inside_tree() or not wrapper.is_visible_in_tree():
			continue
		var from: Rect2 = before[w]
		var to := Rect2(wrapper.position, wrapper.size)
		if from.is_equal_approx(to):
			continue
		_claim(wrapper, true)
		var base: Color = wrapper.modulate
		wrapper.position = from.position
		wrapper.size = from.size
		var tw := wrapper.create_tween()
		if fade:
			# Crossfade: both panes dissolve out where they were drawn, trade
			# rects at the midpoint (invisible), and dissolve back in.
			tw.tween_property(wrapper, "modulate:a", 0.0, d * 0.5) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
			tw.tween_callback(_set_rect.bind(wrapper, to))
			tw.tween_property(wrapper, "modulate:a", base.a, d * 0.5) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		else:
			tw.set_parallel(true)
			tw.tween_property(wrapper, "position", to.position, d) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(wrapper, "size", to.size, d) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		tw.finished.connect(_finish.bind(wrapper))
		_entries[wrapper] = {"tween": tw, "kind": "swap", "to": to, "base_modulate": base, "duration": d}
		started = true
	return started

## A layout pass ran: create and swap transitions snap to the rects the pass
## just wrote. A close ghost's rect is already final and is left alone.
func finish_layout_sensitive() -> void:
	_prune()
	_finish_matching(["create", "swap"])

## Everything resolves now - settings turned motion off, the workspace is
## leaving the tree. Close ghosts are freed here.
func finish_all() -> void:
	_prune()
	_finish_matching(KINDS)

# ── Internals ──────────────────────────────────────────────────────────

func _animatable(w: Control, allowed: bool, kind: String) -> bool:
	if not allowed or not UiMotion.enabled():
		return false
	if not is_instance_valid(w) or not w.is_inside_tree() or not w.is_visible_in_tree():
		return false
	if w.size.x < 1.0 or w.size.y < 1.0:
		return false
	return choice(kind) != "none"

## A wrapper already playing its exit. Nothing may start a second transition on
## it: the close owns its free.
func _dying(w: Control) -> bool:
	if not _entries.has(w):
		return false
	return str(_entries[w].get("kind", "")) == "close"

## Take ownership of `w`'s channels: kill a running tween first, optionally
## snapping it to its final state.
func _claim(w: Control, snap: bool) -> void:
	if not _entries.has(w):
		return
	var e: Dictionary = _entries[w]
	_entries.erase(w)
	var tw = e.get("tween")
	if tw is Tween:
		(tw as Tween).kill()
	if snap:
		_snap(w, e)

func _finish(w) -> void:
	if not _entries.has(w):
		return
	var e: Dictionary = _entries[w]
	_entries.erase(w)
	if str(e.get("kind", "")) == "close":
		if is_instance_valid(w):
			(w as Control).queue_free()
		return
	_snap(w, e)

func _finish_matching(kinds: Array) -> void:
	for w in _entries.keys():
		if not _entries.has(w):
			continue
		var e: Dictionary = _entries[w]
		if not kinds.has(str(e.get("kind", ""))):
			continue
		_entries.erase(w)
		var tw = e.get("tween")
		if tw is Tween:
			(tw as Tween).kill()
		_snap(w, e)

func _set_rect(w: Control, to: Rect2) -> void:
	w.position = to.position
	w.size = to.size

## The exact final state of an entry. A close entry is its own free.
func _snap(w, e: Dictionary) -> void:
	if not is_instance_valid(w):
		return
	var c := w as Control
	var to: Rect2 = e.get("to", Rect2(c.position, c.size))
	match str(e.get("kind", "")):
		"create":
			c.position = to.position
			c.scale = Vector2.ONE
			c.modulate = e.get("base_modulate", Color.WHITE)
			c.pivot_offset = Vector2.ZERO
		"swap":
			c.position = to.position
			c.size = to.size
			c.modulate = e.get("base_modulate", Color.WHITE)
		"close":
			c.queue_free()

## Drop entries whose wrapper a teardown freed (their tween died with it).
func _prune() -> void:
	for w in _entries.keys():
		if not is_instance_valid(w):
			_entries.erase(w)

## A closing pane must not take a click or the keyboard: it is no longer in the
## tile list, so an input landing on it would focus a pane the app has closed.
static func _make_inert(node: Node) -> void:
	if node is Control:
		var c := node as Control
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_make_inert(child)
