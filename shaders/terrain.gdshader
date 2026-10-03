// Island terrain: grass, beach, sea floor, zone hints, tool previews and lamp pools.
shader_type spatial;

#include "res://shaders/common.gdshaderinc"

varying vec3 wpos;
varying float landness;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	landness = COLOR.r;
}

void fragment() {
	float g = fbm(wpos.xz * 0.012);
	float g2 = fbm(wpos.xz * 0.09 + 11.0);
	vec3 grass = mix(vec3(0.25, 0.47, 0.15), vec3(0.42, 0.58, 0.19), g);
	grass = mix(grass, vec3(0.55, 0.56, 0.27), smoothstep(0.62, 0.8, g2) * 0.5);
	grass *= 0.9 + 0.2 * vnoise(wpos.xz * 1.3);
	vec3 sand = mix(vec3(0.88, 0.8, 0.6), vec3(0.8, 0.72, 0.52), vnoise(wpos.xz * 0.5));
	vec3 wet = vec3(0.6, 0.53, 0.38);
	vec3 seabed = vec3(0.45, 0.48, 0.36);
	float beach = 1.0 - smoothstep(0.065, 0.1, landness + (g2 - 0.5) * 0.02);
	vec3 alb = mix(grass, sand, beach);
	alb = mix(alb, wet, smoothstep(-0.3, -0.9, wpos.y));
	alb = mix(alb, seabed, smoothstep(-1.5, -5.0, wpos.y));

	ivec2 c = cell_of(wpos);
	vec4 cm = city_at(c);
	int z = zone_of(cm);
	vec2 f = fract(wpos.xz / tile_size);
	float edge = max(abs(f.x - 0.5), abs(f.y - 0.5));
	vec3 emit = vec3(0.0);
	if (z > 0 && !built_of(cm)) {
		// Empty zoned lot: tinted with a bright border, like a SimCity plot.
		float border = smoothstep(0.4, 0.47, edge);
		alb = mix(alb, zone_rgb(z) * 0.8, 0.28 + border * 0.5);
	}
	if (grid_alpha > 0.0 && cm.r < 0.5 && wpos.y > -0.1) {
		alb *= 1.0 - smoothstep(0.475, 0.497, edge) * 0.35 * grid_alpha;
	}
	if (overlay_mode > 0) {
		float lum = dot(alb, vec3(0.3, 0.59, 0.11));
		vec3 grey = vec3(lum * 0.6 + 0.25);
		if (overlay_mode == 1) alb = z > 0 ? mix(grey, zone_rgb(z), 0.6) : grey;
		else if (overlay_mode == 3 && wpos.y > -0.1) alb = mix(grey, heat(1.0 - cm.a), 0.6);
		else alb = grey;
	}
	ALBEDO = alb;
	ROUGHNESS = mix(0.95, 0.6, smoothstep(-0.3, -0.8, wpos.y));
	SPECULAR = 0.3;
	emit += alb * lamp_light(wpos, vec3(0.0, 1.0, 0.0));
	emit += preview_tint(wpos);
	EMISSION = emit;
}
