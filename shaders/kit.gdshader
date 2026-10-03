// One shader for every kit mesh (buildings, roads, props, cars). Each Blender material
// name maps to a ShaderMaterial of this shader with its own uniforms (see kit.gd).
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

uniform vec3 base_color : source_color = vec3(0.9);
uniform int tint_src = 0;          // 0 none, 1 instance COLOR, 2 instance CUSTOM.rgb
uniform float tint_amount = 1.0;
// 0 plain, 1 stucco, 2 brick, 3 concrete panels, 4 corrugated metal, 5 roof tiles,
// 6 paving, 7 grass, 8 asphalt, 9 awning stripes, 10 sidewalk, 11 gravel roof
uniform int pattern = 0;
// 0 solid, 1 lit glass, 2 sign, 3 lamp, 4 foliage, 5 headlight, 6 taillight, 7 plain glass
uniform int kind = 0;
uniform float rough = 0.85;
uniform float metal = 0.0;
uniform float spec = 0.5;
uniform bool wind = false;
uniform bool ground_level = false;  // receives tool previews and overlays like the ground

varying vec3 opos;
varying vec3 onrm;
varying vec3 wpos;
varying vec3 wnrm;
varying vec4 icolor;
varying vec4 icustom;
varying vec3 origin;

void vertex() {
	opos = VERTEX;
	onrm = NORMAL;
	icolor = COLOR;
	icustom = INSTANCE_CUSTOM;
	origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	if (wind) {
		float h = max(VERTEX.y - 1.2, 0.0);
		float t = TIME * 1.4 + origin.x * 0.05 + origin.z * 0.07;
		VERTEX.x += sin(t) * 0.035 * h;
		VERTEX.z += cos(t * 0.83) * 0.03 * h;
	}
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float aa_fade(vec2 uv) {
	vec2 w = fwidth(uv);
	return clamp(1.0 - max(w.x, w.y) * 1.6, 0.0, 1.0);
}

float grid_line(vec2 uv, vec2 width) {
	vec2 f = fract(uv);
	vec2 d = min(f, 1.0 - f);
	vec2 l = 1.0 - smoothstep(width * 0.5, width * 0.5 + fwidth(uv) * 1.2, d);
	return max(l.x, l.y);
}

void fragment() {
	vec3 n = normalize(onrm);
	vec3 tint = tint_src == 1 ? icolor.rgb : (tint_src == 2 ? icustom.rgb : vec3(1.0));
	vec3 alb = base_color * mix(vec3(1.0), tint, tint_amount);
	float r = rough;
	float m = metal;
	float seed = icustom.a;
	vec2 wuv = abs(n.x) > abs(n.z) ? vec2(opos.z, opos.y) : vec2(opos.x, opos.y);
	vec3 emit = vec3(0.0);

	if (pattern == 1 || pattern == 11) {
		alb *= 0.92 + 0.12 * fbm(wuv * 1.1 + opos.xz * 0.7 + seed * 40.0);
		if (pattern == 11) alb *= 0.9 + 0.2 * vnoise(opos.xz * 3.0);
	} else if (pattern == 2) {
		vec2 uv = wuv / vec2(0.55, 0.24);
		float row = floor(uv.y);
		uv.x += mod(row, 2.0) * 0.5;
		vec2 cell = floor(uv);
		float fade = aa_fade(uv);
		float mortar = grid_line(uv, vec2(0.08, 0.14)) * fade;
		float bh = hash12(cell + seed * 13.0);
		alb *= mix(1.0, 0.82 + 0.3 * bh, fade);
		alb = mix(alb, vec3(0.78, 0.75, 0.7), mortar * 0.75);
	} else if (pattern == 3) {
		vec2 uv = wuv / vec2(3.0, 1.55);
		float fade = aa_fade(uv * 4.0);
		alb *= 1.0 - grid_line(uv, vec2(0.012, 0.025)) * 0.3 * fade;
		alb *= 0.94 + 0.1 * hash12(floor(uv) + seed * 7.0) * fade;
		alb *= 0.95 + 0.08 * fbm(wuv * 0.8);
	} else if (pattern == 4) {
		float c = wuv.x / 0.22;
		float fade = aa_fade(vec2(c));
		alb *= 1.0 + sin(c * 6.2832) * 0.09 * fade;
		r = mix(r, r * 0.7, 0.5 + 0.5 * sin(c * 6.2832));
	} else if (pattern == 5) {
		vec2 uv = vec2(wuv.x + opos.x + opos.z, opos.y) / vec2(0.45, 0.3);
		uv.x += mod(floor(uv.y), 2.0) * 0.5;
		float fade = aa_fade(uv);
		alb *= 1.0 - grid_line(uv, vec2(0.04, 0.2)) * 0.35 * fade;
		alb *= mix(1.0, 0.85 + 0.25 * hash12(floor(uv) + seed), fade);
	} else if (pattern == 6 || pattern == 10) {
		vec2 uv = (pattern == 10 ? wpos.xz : opos.xz) / (pattern == 10 ? 1.5 : 1.0);
		float fade = aa_fade(uv);
		alb *= 1.0 - grid_line(uv, vec2(0.04)) * 0.22 * fade;
		alb *= mix(1.0, 0.93 + 0.12 * hash12(floor(uv)), fade);
		alb *= 0.94 + 0.1 * fbm(wpos.xz * 0.3);
	} else if (pattern == 7) {
		float g = fbm(wpos.xz * 0.08);
		alb = mix(vec3(0.27, 0.48, 0.16), vec3(0.42, 0.58, 0.2), g);
		alb *= 0.9 + 0.2 * vnoise(wpos.xz * 1.7);
	} else if (pattern == 8) {
		alb *= 0.85 + 0.25 * fbm(wpos.xz * 0.6);
		alb *= 0.92 + 0.12 * vnoise(wpos.xz * 9.0);
		float patch = smoothstep(0.62, 0.66, fbm(wpos.xz * 0.12 + 3.0));
		alb *= 1.0 - patch * 0.18;
	} else if (pattern == 9) {
		float s = step(0.5, fract((opos.x + opos.z) / 0.9));
		alb = mix(vec3(0.95, 0.94, 0.9), alb, s);
	}

	// Ground contact shadow and a gentle bottom-to-top gradient on walls.
	if (abs(n.y) < 0.5 && !ground_level && kind == 0) {
		alb *= mix(0.68, 1.0, smoothstep(0.0, 1.8, opos.y));
		alb *= 1.0 + clamp(opos.y / 120.0, 0.0, 0.12);
	}

	if (kind == 1) {
		vec3 wid = floor(vec3(opos.x / 2.0, opos.y / 3.2, opos.z / 2.0) + n * 0.5);
		float h = hash13(wid + vec3(seed * 91.7));
		float lit = step(h, window_lit);
		float cool = step(0.82, hash13(wid * 1.7 + 3.1));
		vec3 warm = mix(vec3(1.0, 0.62, 0.3), vec3(0.6, 0.78, 1.0), cool) * (0.6 + 0.6 * hash13(wid * 3.7));
		float ceiling = 0.55 + 0.45 * smoothstep(0.2, 0.95, fract(opos.y / 3.2));
		// Fake sky reflection: darker toward the ground, bright sky blue looking up.
		vec3 vdir = normalize(wpos - CAMERA_POSITION_WORLD);
		vec3 rf = reflect(vdir, normalize(wnrm));
		vec3 sky = mix(vec3(0.05, 0.08, 0.12), vec3(0.42, 0.6, 0.82), smoothstep(-0.15, 0.5, rf.y));
		alb = sky * (0.75 + 0.5 * h) * mix(1.0, 0.25, night);
		r = 0.08;
		m = 0.1;
		emit += warm * lit * ceiling * smoothstep(0.05, 0.5, night) * 1.1;
	} else if (kind == 7) {
		alb = vec3(0.05, 0.07, 0.09);
		r = 0.04;
		m = 0.3;
	} else if (kind == 2) {
		emit += alb * (0.2 + 1.4 * smoothstep(0.1, 0.6, night));
	} else if (kind == 3) {
		emit += vec3(1.0, 0.82, 0.55) * smoothstep(0.1, 0.5, night) * 9.0;
	} else if (kind == 5) {
		emit += vec3(1.0, 0.95, 0.8) * (0.2 + smoothstep(0.1, 0.5, night) * 5.0);
	} else if (kind == 6) {
		emit += vec3(1.0, 0.05, 0.03) * (0.4 + smoothstep(0.1, 0.5, night) * 2.5);
	}

	// Map overlays.
	ivec2 cell = cell_of(ground_level ? wpos : origin + (wpos - origin) * vec3(0.98, 0.0, 0.98));
	if (overlay_mode > 0) {
		vec4 cm = city_at(cell);
		float lum = dot(alb, vec3(0.3, 0.59, 0.11));
		vec3 grey = vec3(lum * 0.6 + 0.25);
		if (overlay_mode == 1) {
			int z = zone_of(cm);
			alb = z > 0 ? mix(grey, zone_rgb(z), 0.6) : grey;
		} else if (overlay_mode == 2) {
			alb = (pattern == 8 && cm.r > 0.5) ? heat(cm.b * 2.0) * 0.8 : grey;
		} else if (overlay_mode == 3) {
			alb = cm.r > 0.5 ? grey : mix(grey, heat(1.0 - cm.a), 0.65);
		}
	}

	ALBEDO = alb;
	ROUGHNESS = r;
	METALLIC = m;
	SPECULAR = spec;
	if (kind == 4) {
		BACKLIGHT = alb * 0.45;
	}
	if (kind != 3) {
		emit += alb * lamp_light(wpos, wnrm);
	}
	emit += preview_tint(wpos) * (ground_level ? 1.0 : 0.5);
	EMISSION = emit;
}
