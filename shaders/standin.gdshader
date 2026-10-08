shader_type spatial;
// Distant buildings as plain boxes (CityView stand-ins): the wall colour, a grid of
// windows that light up at night like the kit's, and a darker roof. One draw call per
// chunk, a few triangles per building, no shadows.
render_mode cull_back;

#include "res://shaders/common.gdshaderinc"

varying vec3 wcol;
varying flat float seed;

void vertex() {
	wcol = COLOR.rgb;
	seed = UV2.x;
}

void fragment() {
	bool roof = UV.y < 0.0;
	vec3 alb = wcol * 0.78;
	float glass = 0.0;
	float lit = 0.0;
	if (roof) {
		alb = wcol * 0.42;
	} else {
		// Windows every 3 m up and 2.6 m along, above a 4 m ground floor.
		vec2 cell = vec2(UV.x / 2.6, (UV.y - 4.0) / 3.0);
		vec2 f = fract(cell);
		glass = step(0.0, cell.y) * step(0.18, f.x) * step(f.x, 0.82) * step(0.22, f.y) * step(f.y, 0.8);
		float rid = floor(cell.y) * 37.0 + floor(cell.x) + seed * 1000.0;
		lit = glass * step(hash12(vec2(rid, 9.1)), window_lit);
		alb = mix(alb, vec3(0.16, 0.2, 0.25), glass * 0.8);
	}
	ALBEDO = alb;
	ROUGHNESS = mix(0.85, 0.2, glass);
	SPECULAR = mix(0.3, 0.6, glass);
	EMISSION = lit * night * vec3(1.0, 0.78, 0.5) * 1.6;
}
