shader_type canvas_item;
// Animated film grain for a terminal pane's ground.
//
// PaneEffects renders this in a half-resolution SubViewport at 30 Hz and draws
// the result stretched over the full-pane effect layer, the budget its table
// entry declares. `phase` is a uniform rather than a read of TIME: speed is
// independent of the frame rate, and a capture can pin one deterministic frame.
//
// One hash per pixel, no loop and no per-pixel fractal passes. The noise is
// mixed toward, not added to, the base colour, so it reads on a light scheme as
// well as a dark one.

uniform float strength : hint_range(0.0, 1.0) = 0.5;
uniform float phase = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec3 base = COLOR.rgb;
	float n = hash(FRAGCOORD.xy + vec2(phase * 37.0, phase * 91.0));
	COLOR = vec4(mix(base, vec3(n), 0.06 * strength), COLOR.a);
}
