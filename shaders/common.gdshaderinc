// Shared globals and helpers for the city shaders.
global uniform float night;          // 0 = full day, 1 = full night
global uniform float window_lit;     // fraction of windows lit right now
global uniform vec3 sun_dir;
global uniform sampler2D city_map : filter_nearest;   // R road, G zone, B traffic, A land value
global uniform sampler2D lamp_map : filter_nearest;   // RG lamp head offset in tile, B has lamp
global uniform sampler2D preview_map : filter_nearest; // R = tool preview
global uniform vec4 preview_color;
global uniform int overlay_mode;     // 0 none, 1 zones, 2 traffic, 3 land value
global uniform float map_cells;
global uniform float tile_size;
global uniform float grid_alpha;     // tile grid lines while a build tool is active

const vec3 LAMP_COLOR = vec3(1.0, 0.72, 0.42);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x),
			   mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

float fbm(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < 4; i++) { s += a * vnoise(p); p *= 2.03; a *= 0.5; }
	return s;
}

ivec2 cell_of(vec3 wp) {
	return ivec2(floor(wp.xz / tile_size));
}

bool cell_ok(ivec2 c) {
	return c.x >= 0 && c.y >= 0 && float(c.x) < map_cells && float(c.y) < map_cells;
}

vec4 city_at(ivec2 c) {
	if (!cell_ok(c)) return vec4(0.0);
	return texelFetch(city_map, c, 0);
}

// city_map G channel: zone * 64 + (built ? 32 : 0)
int zone_of(vec4 cm) { return int(cm.g * 255.0 + 0.5) / 64; }
bool built_of(vec4 cm) { return (int(cm.g * 255.0 + 0.5) % 64) >= 32; }

vec3 zone_rgb(int z) {
	if (z == 1) return vec3(0.25, 0.85, 0.35);
	if (z == 2) return vec3(0.25, 0.55, 1.0);
	if (z == 3) return vec3(1.0, 0.75, 0.15);
	return vec3(0.0);
}

vec3 heat(float t) {
	t = clamp(t, 0.0, 1.0);
	return mix(mix(vec3(0.15, 0.85, 0.3), vec3(1.0, 0.85, 0.1), smoothstep(0.0, 0.5, t)),
			   vec3(1.0, 0.15, 0.1), smoothstep(0.5, 1.0, t));
}

// Street lamp light reaching a world point: sums the lamps of the 3x3 tiles around it.
// Cheap stand-in for hundreds of real lights.
vec3 lamp_light(vec3 wp, vec3 n) {
	if (night < 0.02) return vec3(0.0);
	ivec2 c = cell_of(wp);
	float acc = 0.0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 cc = c + ivec2(dx, dy);
			if (!cell_ok(cc)) continue;
			vec4 l = texelFetch(lamp_map, cc, 0);
			if (l.b < 0.5) continue;
			vec3 lp = vec3((float(cc.x) + l.r) * tile_size, 6.0, (float(cc.y) + l.g) * tile_size);
			vec3 d = lp - wp;
			float dist = length(d);
			float ndl = max(dot(n, d / dist), 0.0) * 0.7 + 0.3;
			float fall = 1.0 - smoothstep(0.0, 13.0, dist);
			acc += fall * fall * ndl;
		}
	}
	return LAMP_COLOR * acc * night * 1.6;
}

vec3 preview_tint(vec3 wp) {
	ivec2 c = cell_of(wp);
	if (!cell_ok(c)) return vec3(0.0);
	float p = texelFetch(preview_map, c, 0).r;
	if (p < 0.01) return vec3(0.0);
	vec2 f = fract(wp.xz / tile_size);
	float edge = max(smoothstep(0.42, 0.48, abs(f.x - 0.5)), smoothstep(0.42, 0.48, abs(f.y - 0.5)));
	return preview_color.rgb * (0.35 + edge * 0.65) * p;
}
