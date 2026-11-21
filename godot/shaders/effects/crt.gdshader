shader_type canvas_item;
// A static CRT backdrop for a terminal pane's ground.
//
// The pane paints this quad from its own EFFECT layer with the ground colour in
// COLOR. A material on the grid itself would run per draw command - the glyph
// atlas as TEXTURE, each rect's tint in COLOR - so the effect lives on one
// full-pane rect and never touches the text bands.
//
// Every term is derived from the quad's own pixels (`quad_px`/`rows`), never
// from SCREEN_PIXEL_SIZE, so the pattern is resolution-independent and does not
// shift when the window or the pane is resized. `rows` is the number of
// scanline periods across the quad: `PaneEffects` derives it from the pane
// height and the terminal's cell height. `strength` is 0.5 at the Subtle
// setting and 1.0 at Full.
//
// Nothing here is `TIME`-driven: the layer is redrawn only when the pane
// changes, so the cost is paid once per change, not per frame.

uniform float strength : hint_range(0.0, 1.0) = 0.5;
uniform float rows = 360.0;
uniform vec2 quad_px = vec2(1920.0, 1080.0);

void fragment() {
	vec3 base = COLOR.rgb;
	// Scanlines: one lit band and one gap per period in UV space. The lit band
	// ADDS light, the way a CRT's beam does - a term that only multiplies the
	// ground is invisible on a black terminal - and the gap darkens on grounds
	// that carry light, so the comb reads on both themes.
	float band = fract(UV.y * rows);
	float gap = smoothstep(0.5, 0.95, band);
	float lit = 1.0 - gap;
	// Phosphor mask: soft per-column channel gains, three logical pixels apart;
	// it tints the added beam.
	float column = mod(floor(UV.x * quad_px.x), 3.0);
	vec3 mask = vec3(1.0);
	if (column < 1.0) {
		mask = vec3(1.04, 0.98, 0.96);
	} else if (column < 2.0) {
		mask = vec3(0.98, 1.04, 0.98);
	} else {
		mask = vec3(0.96, 0.98, 1.04);
	}
	mask = mix(vec3(1.0), mask, strength);
	vec3 beam = vec3(0.10) * mask * lit * strength;
	vec3 rgb = base * (1.0 - 0.22 * strength * gap) + beam;
	// Vignette: circular in the quad's own pixels, quadratic falloff. It only
	// removes light, so it shows on a lit ground and is inert on a black one.
	vec2 p = (UV - 0.5) * quad_px;
	float radius = length(p) / (0.5 * length(quad_px));
	float vig = 1.0 - smoothstep(0.45, 1.0, radius) * 0.20 * strength;
	COLOR = vec4(rgb * vig, COLOR.a);
}
