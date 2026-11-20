shader_type canvas_item;
// The window's whole-surface opacity, applied once.
//
// The app's canvas under a transparent-background root is premultiplied: each
// surface blends over the one before it, so a per-item modulate compounds and
// a 70 % window still reads opaque (measured 0.992 with four stacked layers).
// This veil samples the finished canvas and replaces the window's alpha with
// the user's value, renormalising the premultiplied colour to it, so the
// compositor blends the app once instead of every layer blending again.
//
// `blend_disabled` is the write: a normal blend would composite over the
// opaque destination alpha and never lower it. The veil is drawn above every
// other canvas item by the workspace, with a `BackBufferCopy` immediately
// below it so the sample is this frame's canvas, not a stale backbuffer.
render_mode blend_disabled, unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float window_alpha : hint_range(0.01, 1.0) = 1.0;

void fragment() {
	vec4 under = texture(screen_texture, SCREEN_UV);
	// `under.rgb` is already multiplied by `under.a`; dividing it back out and
	// multiplying by the requested alpha gives the premultiplied colour the
	// compositor expects at that alpha. The floor keeps an untouched pixel
	// from producing an unbounded ratio.
	COLOR = vec4(under.rgb * (window_alpha / max(under.a, 0.001)), window_alpha);
}
