// The planet's cloud layer, seen from high up: drifting banks from 3D noise, a storm cell
// where Weather says it is raining (or about to), lit by the real sun so the night side's
// clouds go dark. Unshaded and alpha-blended: one draw call, no shadows.
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never, shadows_disabled;

uniform float strength = 0.0;            // 0 hidden .. 1 fully seen (fades in with height)
uniform vec3 sun_world = vec3(0.0, 1.0, 0.0);
uniform float drift = 0.0;               // radians the banks have turned round the axis
uniform float cover = 0.35;              // how much of the sky is cloud away from storms
uniform vec4 storm = vec4(0.0, 0.0, 1.0, 0.0);  // xyz: direction of the storm's centre, w: strength

varying vec3 dir;

float h3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1, 0, 0)), f.x), mix(h3(i + vec3(0, 1, 0)), h3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h3(i + vec3(0, 0, 1)), h3(i + vec3(1, 0, 1)), f.x), mix(h3(i + vec3(0, 1, 1)), h3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	dir = normalize((MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz);
}

void fragment() {
	vec3 d = normalize(dir);
	// Turn the banks round the axis; the bands near the poles stretch a little east-west.
	float c = cos(drift), s = sin(drift);
	vec3 p = vec3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z) * vec3(5.0, 7.5, 5.0);
	float n = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { n += a * vnoise3(p); p = p * 2.07 + 11.3; a *= 0.5; }
	float banks = smoothstep(1.0 - cover, 1.15 - cover * 0.6, n + 0.12);
	float st = storm.w * smoothstep(0.80, 0.97, dot(d, normalize(storm.xyz)));
	float alpha = clamp(max(banks * 0.8, st * (0.55 + 0.45 * n)), 0.0, 0.95);
	float lit = smoothstep(-0.15, 0.35, dot(d, sun_world));
	vec3 col = mix(vec3(0.03, 0.035, 0.05), vec3(0.97, 0.97, 1.0), lit);
	col = mix(col, col * vec3(0.55, 0.58, 0.65), st);   // storm clouds are grey
	// A warm edge where the sun sets on them.
	col += vec3(0.5, 0.25, 0.08) * (1.0 - abs(dot(d, sun_world)) * 4.0) * step(abs(dot(d, sun_world)), 0.25) * 0.4;
	ALBEDO = col;
	ALPHA = alpha * strength;
}
