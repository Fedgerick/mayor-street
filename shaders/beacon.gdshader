// Red aircraft warning lights on top of the tallest towers: dim by day, pulsing at night.
shader_type spatial;
render_mode unshaded, shadows_disabled, cull_back;

global uniform float night;

varying float phase;

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	phase = fract(sin(dot(o.xz, vec2(12.9898, 78.233))) * 43758.5453);
	// Grow with distance so each light stays a visible point from the mayor view.
	float d = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	VERTEX *= clamp(d * 0.006, 1.0, 6.0);
}

void fragment() {
	float pulse = smoothstep(0.0, 0.15, fract(TIME * 0.5 + phase)) * (1.0 - smoothstep(0.45, 0.7, fract(TIME * 0.5 + phase)));
	float k = smoothstep(0.2, 0.6, night);
	ALBEDO = vec3(1.0, 0.07, 0.03) * mix(0.35, 0.6 + 7.0 * pulse, k);
}
