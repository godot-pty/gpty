shader_type canvas_item;
// Animated aurora ribbons for a terminal pane's ground.
//
// PaneEffects renders this in a half-resolution SubViewport at 30 Hz and draws
// the result stretched over the full-pane effect layer, the budget its table
// entry declares. `phase` is a uniform rather than a read of TIME: speed is
// independent of the frame rate, and a capture can pin one deterministic frame.
//
// Two sine ribbons, no loop and no per-pixel fractal passes. The tint is added
// to the base colour, and the amplitudes stay under 0.12 at Full so text and
// non-default cells remain legible above it.

uniform float strength : hint_range(0.0, 1.0) = 0.5;
uniform float phase = 0.0;

void fragment() {
	vec3 base = COLOR.rgb;
	float a = sin(UV.x * 6.0 + phase * 2.0 + sin(UV.y * 3.0 + phase) * 0.8);
	float b = sin(UV.x * 4.0 - phase * 1.3 + UV.y * 2.0);
	float band = smoothstep(0.35, 1.0, (0.5 + 0.5 * a) * (0.5 + 0.5 * b));
	vec3 tint = mix(vec3(0.10, 0.45, 0.55), vec3(0.25, 0.75, 0.55), UV.y);
	COLOR = vec4(base + tint * band * 0.12 * strength, COLOR.a);
}
