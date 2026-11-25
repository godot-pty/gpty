shader_type canvas_item;
// A static vignette for a terminal pane's ground.
//
// The effect layer draws one full-pane quad with the ground colour in COLOR, so
// this shader only reshapes that quad. A centre lift plus an edge falloff reads
// on a near-black ground (the lift is visible) and on a light one (the falloff
// is), which is why it is both an add and a multiply rather than one term.
//
// Nothing here is `TIME`-driven: the layer is redrawn only when the pane
// changes, so the cost is paid once per change, not per frame.
//
// `strength` is 0.5 at the Subtle setting and 1.0 at Full.

uniform float strength : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec3 base = COLOR.rgb;
	vec2 p = (UV - 0.5) * 2.0;
	// Slightly taller than wide, so the oval follows the pane's own shape
	// instead of a perfect circle that clips left and right.
	float radius = length(p * vec2(1.0, 1.15));
	float edge = smoothstep(0.55, 1.35, radius);
	vec3 rgb = base * (1.0 - 0.35 * strength * edge)
		+ vec3(0.04) * strength * (1.0 - edge);
	COLOR = vec4(rgb, COLOR.a);
}
