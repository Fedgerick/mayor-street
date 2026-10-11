// The player's skin, close up: soft wrap lighting with a warm terminator (cheap fake
// subsurface), self-shadows lifted so the nose and brows don't cut hard dark patches into
// the face, warmer cheeks, nose, ears and lips, slightly shaded eye sockets, fine pores. Rest-pose landmarks match
// characters/tools/build_hero.py (Godot axes: +Y up, +Z the face's front).
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://characters/shaders/hero_common.gdshaderinc"

float blob(vec3 p, vec3 c, vec3 r) {
	vec3 d = (p - c) / r;
	return clamp(1.0 - dot(d, d), 0.0, 1.0);
}

void fragment() {
	vec3 p = rest_pos;
	float px = length(fwidth(p));
	vec3 col = albedo.rgb;
	float r = rough;
	float h = 0.0;
	if (kind == 18) {   // stubble: fine dark dots over the skin tone
		float dots = smoothstep(0.55, 0.8, vnoise(p * 1400.0)) * keep(0.0008, px);
		col = mix(col, col * 0.45, dots * 0.7);
		h = dots * 0.00012;
		r = 0.95;
	} else {
		float x = abs(p.x);
		vec3 q = vec3(x, p.y, p.z);
		float blush = blob(q, vec3(0.06, 1.61, 0.1), vec3(0.04, 0.03, 0.05)) * 0.6
			+ blob(q, vec3(0.0, 1.632, 0.168), vec3(0.022, 0.02, 0.02)) * 0.55
			+ blob(q, vec3(0.146, 1.655, -0.005), vec3(0.03, 0.045, 0.04)) * 0.5;
		float lips = blob(q, vec3(0.0, 1.59, 0.145), vec3(0.026, 0.012, 0.02));
		col = mix(col, col * vec3(1.05, 0.72, 0.68), clamp(blush, 0.0, 1.0) * 0.32);
		col = mix(col, col * vec3(0.92, 0.66, 0.64), smoothstep(0.15, 0.6, lips) * 0.45);
		float socket = blob(q, vec3(0.053, 1.68, 0.135), vec3(0.04, 0.03, 0.03));
		col *= 1.0 - socket * 0.12;
		col *= 0.98 + 0.04 * vnoise(p * 60.0);   // faint unevenness, so skin isn't plastic
		float pores = (vnoise(p * 2200.0) - 0.5) * keep(0.0005, px);
		h = pores * 0.00004 * detail;
		r = rough - lips * 0.18 + blush * 0.05;
	}
	ALBEDO = col;
	ROUGHNESS = clamp(r, 0.05, 1.0);
	SPECULAR = 0.4;
	NORMAL = bumped(NORMAL, VERTEX, h);
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrap = clamp((ndl + 0.4) / 1.4, 0.0, 1.0);
	float lit = max(ndl, 0.0);
	float shade = mix(0.5, 1.0, ATTENUATION);   // self-shadow on skin stays soft
	vec3 warm = vec3(1.0, 0.42, 0.28) * (wrap - lit) * 0.55;   // red-orange where light wraps round
	DIFFUSE_LIGHT += LIGHT_COLOR * (vec3(wrap) + warm) * shade / PI;
	vec3 hv = normalize(LIGHT + VIEW);
	float sp = pow(max(dot(NORMAL, hv), 0.0), mix(64.0, 8.0, ROUGHNESS)) * (1.0 - ROUGHNESS) * 0.35;
	SPECULAR_LIGHT += LIGHT_COLOR * sp * lit * ATTENUATION / PI;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0) * 0.3;
	DIFFUSE_LIGHT += LIGHT_COLOR * rim * mix(vec3(1.0), ALBEDO, 0.5) * wrap * shade / PI;
}
