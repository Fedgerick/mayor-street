// Island terrain: grass, beach, sea floor, zone hints, tool previews and lamp pools.
shader_type spatial;

#include "res://shaders/common.gdshaderinc"

varying vec3 wpos;
varying float landness;
varying float ice;  // planet/: 0 none .. 1 polar ice cap

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	landness = COLOR.r;
	ice = COLOR.g;
}

void fragment() {
	vec3 mpos = map_pos(wpos);  // flat map metres (planet/ unwraps the ball)
	float g = fbm(mpos.xz * 0.012);
	float g2 = fbm(mpos.xz * 0.09 + 11.0);
	vec3 grass = mix(vec3(0.12, 0.25, 0.06), vec3(0.23, 0.36, 0.1), g);
	grass = mix(grass, vec3(0.4, 0.38, 0.16), smoothstep(0.6, 0.8, g2) * 0.55);
	grass = mix(grass, vec3(0.06, 0.17, 0.04), smoothstep(0.62, 0.78, fbm(mpos.xz * 0.03 + 5.0)) * 0.5);
	vec2 fw = fwidth(mpos.xz * 1.3);
	grass *= mix(1.0, 0.88 + 0.24 * vnoise(mpos.xz * 1.3), clamp(1.0 - max(fw.x, fw.y) * 1.6, 0.0, 1.0));
	vec3 sand = mix(vec3(0.84, 0.75, 0.55), vec3(0.76, 0.67, 0.47), vnoise(mpos.xz * 0.5));
	vec3 wet = vec3(0.6, 0.53, 0.38);
	vec3 seabed = vec3(0.45, 0.48, 0.36);
	float beach = 1.0 - smoothstep(0.065, 0.1, landness + (g2 - 0.5) * 0.02);
	vec3 alb = mix(grass, sand, beach);
	// Sand darkens where the swash keeps it wet, just above the waterline (-0.7).
	alb = mix(alb, wet, smoothstep(-0.35, -0.62, mpos.y) * 0.8);
	alb = mix(alb, seabed, smoothstep(-1.5, -5.0, mpos.y));
	if (ice > 0.0) {
		// Tundra, then snow, then blue-white ice toward the pole.
		vec3 tundra = mix(vec3(0.42, 0.4, 0.3), vec3(0.5, 0.48, 0.4), g2);
		vec3 snow = vec3(0.92, 0.95, 1.0) * (0.92 + 0.08 * vnoise(mpos.xz * 0.2));
		vec3 glacier = mix(vec3(0.7, 0.85, 0.95), vec3(0.85, 0.93, 1.0), fbm(mpos.xz * 0.02));
		alb = mix(alb, tundra, smoothstep(0.0, 0.25, ice));
		alb = mix(alb, snow, smoothstep(0.25, 0.55, ice + (g - 0.5) * 0.15));
		alb = mix(alb, glacier, smoothstep(0.7, 1.0, ice + (g2 - 0.5) * 0.2));
	}

	ivec2 c = cell_of(wpos);
	vec4 cm = city_at(c);
	int z = zone_of(cm);
	vec2 f = fract(mpos.xz / tile_size);
	float edge = max(abs(f.x - 0.5), abs(f.y - 0.5));
	vec3 emit = vec3(0.0);
	if (z > 0 && !built_of(cm)) {
		// Empty zoned lot: tinted with a bright border, like a SimCity plot.
		float border = smoothstep(0.4, 0.47, edge);
		alb = mix(alb, zone_rgb(z) * 0.8, 0.28 + border * 0.5);
	}
	if (grid_alpha > 0.0 && cm.r < 0.5 && mpos.y > -0.1) {
		alb *= 1.0 - smoothstep(0.475, 0.497, edge) * 0.35 * grid_alpha;
	}
	if (overlay_mode > 0) {
		float lum = dot(alb, vec3(0.3, 0.59, 0.11));
		vec3 grey = vec3(lum * 0.6 + 0.25);
		if (overlay_mode == 1) alb = z > 0 ? mix(grey, zone_rgb(z), 0.6) : grey;
		else if (overlay_mode == 3 && mpos.y > -0.1) alb = mix(grey, heat(1.0 - cm.a), 0.6);
		else alb = grey;
	}
	ALBEDO = alb;
	ROUGHNESS = mix(mix(0.95, 0.6, smoothstep(-0.3, -0.8, mpos.y)), 0.35, smoothstep(0.6, 1.0, ice));
	SPECULAR = 0.3;
	emit += alb * lamp_light(wpos, up_at(wpos));
	emit += preview_tint(wpos);
	EMISSION = emit;
}
