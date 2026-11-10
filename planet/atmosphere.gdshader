// A thin blue haze round the planet, seen from orbit: brightest at the rim, on the day side.
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled;

uniform float strength = 0.0;   // 0 at street level .. 1 from orbit
uniform vec3 sun_world = vec3(0.0, 1.0, 0.0);

varying vec3 wnrm;

void vertex() {
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float rim = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float day = smoothstep(-0.35, 0.4, dot(wnrm, sun_world));
	vec3 col = mix(vec3(0.25, 0.5, 1.0), vec3(0.6, 0.8, 1.0), rim);
	ALBEDO = col * pow(rim, 2.5) * (0.25 + 1.4 * day) * strength;
}
