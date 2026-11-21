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
