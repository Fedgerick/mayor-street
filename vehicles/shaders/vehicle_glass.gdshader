// Car windows: tinted, see-through in the middle, mirror-like at grazing angles.
// UV.x = 1 on cracked glass (damage stages).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

varying vec3 opos;
varying float cracked;

void vertex() {
	opos = VERTEX;
	cracked = UV.x;
}

float crack_lines(vec2 p) {
	// Cheap shatter pattern: distance to the nearest cell edge of a jittered grid,
	// plus spokes out from an impact point.
	vec2 i = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0, d2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 c = o + vec2(hash12(i + o), hash12(i + o + 17.0)) - f;
			float d = dot(c, c);
			if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
		}
	}
	return 1.0 - smoothstep(0.0, 0.06, sqrt(d2) - sqrt(d1));
}

void fragment() {
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 alb = vec3(0.05, 0.07, 0.085);
	float a = mix(0.34, 0.92, f);
	if (cracked > 0.5) {
		vec2 p = vec2(opos.x + opos.z, opos.y) * 7.0;
		float c = crack_lines(p) * 0.8 + crack_lines(p * 2.3) * 0.4;
		alb = mix(alb, vec3(0.75, 0.8, 0.82), clamp(c, 0.0, 1.0));
		a = max(a, clamp(c, 0.0, 0.85) + 0.15);
	}
	ALBEDO = alb;
	ALPHA = a;
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.9;
}
