class_name GraphTheme
## The vault graph's own closed theme table.
##
## The graph is a canvas with its own ground, nodes and links, so it carries its
## own themes instead of borrowing the chrome's [UiPalette] wholesale: a theme
## may recolour the canvas to near-black space while the pane's buttons stay on
## the app palette. Only [VaultGraphView] and [VaultGraph3D] read this table.
##
## Every theme has a complete dark and light style, selected by the app
## appearance at the moment it is applied. `default` derives from
## [UiPalette] and reproduces the shipped look; every other entry is a sparse
## override layer on top of it, so a new theme is one entry here plus its ids in
## [constant IDS]. The keys are closed: [constant STYLE_KEYS] is the schema test's
## source of truth, and every returned style carries all of them.
##
## Colours are resolved inside [method style] and cached by the views, never in a
## class-body initializer: the palette changes at runtime.

## The theme vocabulary. The order is the picker's order.
const IDS := ["default", "planetary"]
const LABELS := {"default": "Default", "planetary": "Planetary"}

## The deterministic backdrop star field's seed. Same count, same stars.
const STAR_SEED := 0x73746172
## Most notes that may carry a planet ring; the busiest win, ties by id.
const MAX_PLANET_RINGS := 256

## Every key a style carries. The order is documentation, not iteration order.
const STYLE_KEYS := [
	"background", "text", "muted", "hint", "accent",
	"node", "node_hover", "node_selected", "ghost",
	"planet_tint", "planet_saturation", "planet_value", "node_shape",
	"sun_energy", "sun_color", "ambient_energy", "ambient_color",
	"halo", "halo_alpha", "halo_scale",
	"ring", "ring_ratio", "ring_scale",
	"edge", "edge_related", "edge_declared",
	"dust", "dust_alpha", "dust_count",
	"stars", "star_alpha",
	"fog_density", "glow_intensity", "glow_strength", "glow_bloom",
	"glow_threshold", "vignette_alpha",
]

## `id -> {"dark": {key: value}, "light": {key: value}}`, overlaid on
## [method _default_style]. An omitted key keeps the default value.
const THEMES := {
	"planetary": {
		"dark": {
			"background": Color("05070f"), "text": Color("e8ecf8"),
			"muted": Color(0.91, 0.93, 0.97, 0.62),
			"hint": Color(0.78, 0.83, 0.94, 0.62),
			"accent": Color("ffc861"),
			"node": Color("f3dfae"), "node_hover": Color("fff4d9"),
			"node_selected": Color("ffc861"),
			"ghost": Color(0.72, 0.78, 0.92, 0.72),
			"planet_tint": 1.0, "planet_saturation": 0.45, "planet_value": 0.92,
			"node_shape": "sphere", "sun_energy": 1.25,
			"sun_color": Color("fff0cf"),
			"ambient_energy": 0.35, "ambient_color": Color("2a3a66"),
			"halo": Color("ffd9a0"), "halo_alpha": 0.18, "halo_scale": 2.6,
			"ring": Color(0.95, 0.86, 0.62, 0.55),
			"ring_ratio": 0.5, "ring_scale": 2.6,
			"edge": Color(0.55, 0.66, 0.95, 0.32),
			"edge_related": Color(1.0, 0.78, 0.38, 0.85),
			"edge_declared": Color(0.62, 0.85, 1.0, 0.55),
			"dust": Color("dfe8ff"), "dust_alpha": 0.5, "dust_count": 160,
			"stars": 140, "star_alpha": 0.55,
			"fog_density": 0.00010, "glow_intensity": 0.55,
			"glow_strength": 1.0, "glow_bloom": 0.12,
			"glow_threshold": 0.35, "vignette_alpha": 0.22,
		},
		"light": {
			"background": Color("eef2fb"), "text": Color("1f2740"),
			"muted": Color(0.12, 0.15, 0.25, 0.62),
			"hint": Color(0.29, 0.34, 0.45, 0.62),
			"accent": Color("a65c00"),
			"node": Color("31456b"), "node_hover": Color("1f3050"),
			"node_selected": Color("a65c00"),
			"ghost": Color(0.36, 0.42, 0.54, 0.72),
			"planet_tint": 1.0, "planet_saturation": 0.35, "planet_value": 0.62,
			"node_shape": "sphere", "sun_energy": 1.0,
			"sun_color": Color("fff3dd"),
			"ambient_energy": 0.5, "ambient_color": Color("dfe7fb"),
			"halo": Color("e0b060"), "halo_alpha": 0.10, "halo_scale": 2.3,
			"ring": Color(0.62, 0.50, 0.26, 0.5),
			"ring_ratio": 0.5, "ring_scale": 2.6,
			"edge": Color(0.36, 0.45, 0.63, 0.34),
			"edge_related": Color(0.65, 0.36, 0.0, 0.85),
			"edge_declared": Color(0.2, 0.45, 0.7, 0.6),
			"dust": Color("8fa2c9"), "dust_alpha": 0.20, "dust_count": 64,
			"stars": 0, "star_alpha": 0.0,
			"fog_density": 0.00006, "glow_intensity": 0.0,
			"glow_strength": 0.9, "glow_bloom": 0.0,
			"glow_threshold": 0.45, "vignette_alpha": 0.05,
		},
	},
}


## The canonical id: a value no theme names falls back to `default`, so a
## hand-edited layout cannot leave a view without a style.
static func normalize(id: String) -> String:
	return id if LABELS.has(id) else "default"


## The complete style for `id` under one appearance. A snapshot is read-only;
## the views cache it and rebuild it when the theme or the appearance changes.
static func style(id: String, dark: bool) -> Dictionary:
	var out := _default_style(dark)
	var theme: Dictionary = THEMES.get(id, {})
	var patch: Dictionary = theme.get("dark" if dark else "light", {})
	for key in patch:
		out[key] = patch[key]
	return out


## The base style: the chrome palette's graph presentation, preserved from the
## shipped constants. Split by appearance because the halo and vignette differ.
static func _default_style(dark: bool) -> Dictionary:
	var palette := UiPalette.dark() if dark else UiPalette.light()
	return {
		"background": palette.BG,
		"text": palette.TEXT,
		"muted": Color(palette.TEXT, 0.6),
		"hint": Color(palette.TEXT, 0.55),
		"accent": palette.ACCENT,
		"node": Color(palette.TEXT, 0.8),
		"node_hover": Color(palette.TEXT, 1.0),
		"node_selected": palette.ACCENT,
		"ghost": Color(palette.TEXT, 0.6),
		"planet_tint": 0.0,
		"planet_saturation": 0.0,
		"planet_value": 1.0,
		"node_shape": "billboard",
		"sun_energy": 0.0,
		"sun_color": palette.WARNING,
		"ambient_energy": 0.0,
		"ambient_color": palette.BG,
		"halo": palette.TEXT,
		"halo_alpha": 0.13 if dark else 0.09,
		"halo_scale": 2.3,
		"ring": Color(palette.TEXT, 0.0),
		"ring_ratio": 0.0,
		"ring_scale": 2.6,
		"edge": Color(palette.TEXT, 0.42),
		"edge_related": Color(palette.ACCENT, 0.85),
		"edge_declared": Color(palette.ACCENT, 0.5),
		"dust": palette.TEXT,
		"dust_alpha": 0.05,
		"dust_count": 64,
		"stars": 0,
		"star_alpha": 0.0,
		"fog_density": 0.00012,
		"glow_intensity": 0.35,
		"glow_strength": 0.9,
		"glow_bloom": 0.05,
		"glow_threshold": 0.45,
		"vignette_alpha": 0.10 if dark else 0.05,
	}


## `count` deterministic backdrop stars in normalized view space:
## `{at: Vector2(0..1, 0..1), r: float, a: float}`. The backdrop is drawn by
## both canvases, so it lives here rather than in either one.
static func stars(count: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED
	var out: Array = []
	for i in maxi(0, count):
		out.append({
			"at": Vector2(rng.randf(), rng.randf()),
			"r": rng.randf_range(0.6, 1.7),
			"a": rng.randf_range(0.25, 1.0),
		})
	return out


## A note's fill: the theme's node colour, pulled toward the note's own
## deterministic hue when the theme paints worlds. The tint is presentation
## only — the same id always answers the same colour, and a declaration or a
## selection never changes the seed.
static func note_color(id: String, style: Dictionary) -> Color:
	var base: Color = style["node"]
	var tint := float(style["planet_tint"])
	if tint <= 0.0:
		return base
	var planet := Color.from_hsv(
		VaultGraphModel.hue_for(id),
		float(style["planet_saturation"]),
		float(style["planet_value"])
	)
	return base.lerp(planet, tint)


## The notes that carry a planet ring: `{id: true}`, capped at
## [constant MAX_PLANET_RINGS]. Only `ids` (the notes, never the ghosts) can be
## ringed; the busiest win, ties by id ascending, so both presentations ring
## the same notes.
static func ringed(
		ids: Array, degrees: Dictionary, max_degree: int, style: Dictionary
) -> Dictionary:
	var out := {}
	var ratio := float(style["ring_ratio"])
	if ratio <= 0.0:
		return out
	var threshold := maxi(2, int(ceilf(float(max_degree) * ratio)))
	var candidates: Array = []
	for id in ids:
		var entry: Dictionary = degrees.get(id, {})
		var degree := int(entry.get("in", 0)) + int(entry.get("out", 0))
		if degree >= threshold:
			candidates.append([degree, str(id)])
	candidates.sort_custom(func(a, b):
		if int(a[0]) != int(b[0]):
			return int(a[0]) > int(b[0])
		return str(a[1]) < str(b[1])
	)
	var kept := mini(candidates.size(), MAX_PLANET_RINGS)
	for i in kept:
		out[str(candidates[i][1])] = true
	return out
