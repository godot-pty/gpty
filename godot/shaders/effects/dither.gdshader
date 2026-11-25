shader_type canvas_item;
// A static 4x4 ordered-dither backdrop for a terminal pane's ground.
//
// The Bayer value is derived arithmetically from the quad's own pixels rather
// than a const array: dynamic const-array indexing is the one construct that
// has surprised the Compatibility renderer before, and the two-level formula
// is exact (B4 = B2(a/2)/4 + B2(a) reproduces the 4x4 matrix scaled to
// 0..15/16). The pattern is anchored to the quad, never FRAGCOORD, so it does
// not slide when the pane or window moves.
//
// Nothing here is `TIME`-driven: the layer is redrawn only when the pane
// changes, so the cost is paid once per change, not per frame.

uniform float strength : hint_range(0.0, 1.0) = 0.5;
uniform vec2 quad_px = vec2(1920.0, 1080.0);

// The 2x2 Bayer value (0, 0.5, 0.75, 0.25) at integer cell `a`.
float bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

void fragment() {
	vec3 base = COLOR.rgb;
	vec2 px = floor(UV * quad_px);
	// 0..15/16, the 4x4 matrix normalised to [0, 1).
	float bayer = bayer2(px * 0.5) * 0.25 + bayer2(px);
	vec3 rgb = base + vec3((bayer - 0.5) * 0.06 * strength);
	COLOR = vec4(rgb, COLOR.a);
}
