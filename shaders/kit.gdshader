// One shader for every kit mesh (buildings, roads, props, cars). Each Blender material
// name maps to a ShaderMaterial of this shader with its own uniforms (see kit.gd).
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

// A mesh has either one of these materials per surface (the u_ uniforms), or, merged by
// kit.gd, a single surface whose vertices carry a material number in CUSTOM0 that picks a
// row from the mat_ tables (one draw call instead of one per material).
uniform bool merged = false;
uniform vec4 mat_a[32];  // base colour, tint amount
uniform vec4 mat_b[32];  // roughness, metallic, specular, tint source
uniform vec4 mat_c[32];  // pattern, kind, wind, ground level
uniform vec3 u_base_color : source_color = vec3(0.9);
uniform int u_tint_src = 0;          // 0 none, 1 instance COLOR, 2 instance CUSTOM.rgb
uniform float u_tint_amount = 1.0;
// 0 plain, 1 stucco, 2 brick, 3 concrete panels, 4 corrugated metal, 5 roof tiles,
// 6 paving, 7 grass, 8 asphalt, 9 awning stripes, 10 sidewalk, 11 gravel roof
uniform int u_pattern = 0;
// 0 solid, 1 window glass, 2 sign, 3 lamp, 4 foliage, 5 headlight, 6 taillight, 7 plain glass
uniform int u_kind = 0;
uniform float u_rough = 0.85;
uniform float u_metal = 0.0;
uniform float u_spec = 0.5;
uniform bool u_wind = false;
uniform bool u_ground_level = false;  // receives tool previews and overlays like the ground

varying vec3 opos;
varying vec3 onrm;
varying vec3 wpos;
varying vec3 wnrm;
varying vec4 icolor;
varying vec4 icustom;
varying vec3 origin;
varying vec3 oview;  // camera -> vertex in object space (window glass only)
varying flat vec4 m_a;  // this surface's row of the tables: base colour and tint amount,
varying flat vec4 m_b;  // roughness, metallic, specular and tint source,
varying flat vec4 m_c;  // pattern, kind, wind and ground level

void vertex() {
	if (merged) {
		int mid = int(CUSTOM0.r + 0.5);
		m_a = mat_a[mid];
		m_b = mat_b[mid];
		m_c = mat_c[mid];
	} else {
		m_a = vec4(u_base_color, u_tint_amount);
		m_b = vec4(u_rough, u_metal, u_spec, float(u_tint_src));
		m_c = vec4(float(u_pattern), float(u_kind), u_wind ? 1.0 : 0.0, u_ground_level ? 1.0 : 0.0);
	}
	int kind = int(m_c.y + 0.5);
	bool wind = m_c.z > 0.5;
	opos = VERTEX;
	onrm = NORMAL;
	icolor = COLOR;
	icustom = INSTANCE_CUSTOM;
	origin = MODEL_MATRIX[3].xyz;
	oview = vec3(0.0);
	if (kind == 1) {
		oview = VERTEX - inverse(mat3(MODEL_MATRIX)) * (CAMERA_POSITION_WORLD - origin);
	}
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
	// 1 when a pattern of this frequency is well resolved, 0 when it would alias.
	vec2 w = fwidth(uv);
	return clamp(1.0 - max(w.x, w.y) * 1.6, 0.0, 1.0);
}

float grid_line(vec2 uv, vec2 width) {
	vec2 f = fract(uv);
	vec2 d = min(f, 1.0 - f);
	vec2 l = 1.0 - smoothstep(width * 0.5, width * 0.5 + fwidth(uv) * 1.2, d);
	return max(l.x, l.y);
}

float in_box(vec2 p, vec2 a, vec2 b) {
	return step(a.x, p.x) * step(p.x, b.x) * step(a.y, p.y) * step(p.y, b.y);
}

// ------------------------------------------------------------ window rooms ---
// Interior mapping: each pane looks into a room box behind it. pane = metres from the
// pane's bottom-left and size = the pane's size (both from the kit's UVs); d = view ray in
// pane space (x right, y up, z into the building).

const vec3 ROOM_WALLS[8] = vec3[8](
	vec3(0.78, 0.72, 0.6), vec3(0.82, 0.82, 0.8), vec3(0.52, 0.62, 0.74), vec3(0.56, 0.66, 0.5),
	vec3(0.86, 0.6, 0.5), vec3(0.6, 0.58, 0.6), vec3(0.86, 0.76, 0.46), vec3(0.75, 0.78, 0.8));
const vec3 ROOM_FLOORS[5] = vec3[5](
	vec3(0.42, 0.26, 0.14), vec3(0.22, 0.13, 0.07), vec3(0.32, 0.32, 0.35), vec3(0.2, 0.24, 0.38),
	vec3(0.68, 0.66, 0.62));
const vec3 FURNITURE[6] = vec3[6](
	vec3(0.55, 0.2, 0.16), vec3(0.2, 0.32, 0.5), vec3(0.3, 0.3, 0.32), vec3(0.62, 0.5, 0.36),
	vec3(0.18, 0.4, 0.3), vec3(0.75, 0.72, 0.68));

vec2 bay_size(vec2 size) {
	// Curtain walls (panes taller than a storey) split into storeys and bays.
	return size / max(vec2(1.0), floor(size / vec2(3.8, 3.4) + 0.5));
}

vec3 room(vec2 pane, vec2 size, vec3 d, float rid, bool shop, float detail, out float depth_k) {
	vec3 p = vec3(pane, 0.0);
	vec3 bmin = vec3(0.0);
	vec3 bmax;
	float deep = 3.2 + 2.4 * hash12(vec2(rid, 3.1));
	if (size.y < 4.5) {
		float w = max(size.x + 1.4, 2.8);
		bmin = vec3(-(w - size.x) * 0.5, shop ? -0.15 : -0.9, 0.0);
		bmax = vec3(bmin.x + w, size.y + (shop ? 0.7 : 0.45), deep + (shop ? 3.0 : 0.0));
	} else {
		vec2 c = bay_size(size);
		p.xy = pane - floor(pane / c) * c;
		bmax = vec3(c, deep + 2.0);
	}
	float h1 = hash12(vec2(rid, 1.7));
	float h2 = hash12(vec2(rid, 5.3));
	vec3 wall = ROOM_WALLS[int(h1 * 7.99)];
	vec3 flr = ROOM_FLOORS[int(h2 * 4.99)] * 0.85;
	// Seen from far away the room is just its average colour.
	vec3 avg = wall * 0.7 + flr * 0.15 + vec3(0.13);
	depth_k = 0.5;
	if (detail <= 0.0) {
		return avg;
	}
	d = vec3(abs(d.x) < 1e-4 ? 1e-4 : d.x, abs(d.y) < 1e-4 ? 1e-4 : d.y, max(d.z, 1e-4));
	vec3 tp = (mix(bmin, bmax, step(vec3(0.0), d)) - p) / d;
	float t = min(tp.x, min(tp.y, tp.z));
	vec3 hit = p + d * t;
	vec3 col;
	if (t == tp.z) {
		// Back wall, with a piece of furniture and sometimes a picture.
		col = wall * 0.9;
		if (shop) {
			// Shelves of goods behind the counter.
			float sy = hit.y - bmin.y;
			vec2 cell = vec2(floor(hit.x / 0.4), floor(sy / 0.45));
			float goods = step(0.3, sy) * step(sy, 2.1) * step(0.18, fract(sy / 0.45));
			col = mix(col, FURNITURE[int(hash12(cell + vec2(rid * 13.0)) * 5.99)] * 1.15, goods * 0.9);
		}
		float fx0 = mix(bmin.x, bmax.x, 0.1 + 0.3 * h2);
		float fx1 = fx0 + (bmax.x - bmin.x) * (0.3 + 0.3 * h1);
		float fh = shop ? 1.3 : 0.55 + 0.5 * h2;
		col = mix(col, FURNITURE[int(h2 * 5.99)], in_box(hit.xy, vec2(fx0, bmin.y), vec2(fx1, bmin.y + fh)) * 0.85);
		vec2 pc = vec2(mix(bmin.x, bmax.x, 0.3 + 0.4 * h1), bmin.y + 1.6);
		col = mix(col, FURNITURE[int(h1 * 5.99)] * 1.2, in_box(hit.xy, pc - vec2(0.35, 0.25), pc + vec2(0.35, 0.25)) * step(0.4, h2) * 0.8);
	} else if (t == tp.y) {
		col = d.y < 0.0 ? flr : vec3(0.86, 0.85, 0.82);
	} else {
		col = wall * 0.78;
		// A tall cupboard against a side wall in some rooms.
		col = mix(col, FURNITURE[int(h1 * 5.99)] * 0.8, step(0.6, h1) * step(hit.y, bmin.y + 1.9) * step(hit.z, bmax.z * 0.45) * 0.85);
	}
	depth_k = clamp(hit.z / bmax.z, 0.0, 1.0);
	return mix(avg, col, detail);
}

// Balcony rails and the thin edges of glass slabs have no room behind them. Drawn dark like a
// window they turned every balcony into a black blot; frosted glass catches the light instead.
const vec3 RAIL_GLASS = vec3(0.46, 0.53, 0.55);

bool is_rail(vec2 size) {
	return size.y < 1.06 || size.x < 0.2;
}

float pane_id(vec2 pane, vec3 p_obj, vec3 t, vec3 b, float seed) {
	// Stable per pane: where its corner sits in the building, plus the building's seed. Both
	// are snapped to whole numbers first. Interpolation leaves the last bits of a float
	// wobbling from pixel to pixel, and hashing that would pick a new room on every pixel.
	vec3 corner = p_obj - t * pane.x - b * pane.y;
	return hash13(floor(corner * 2.0 + 0.371) + floor(fract(seed) * 4096.0));
}

vec3 window_glass(vec2 uv, vec2 uv2, vec3 n, vec3 p_obj, vec3 view, float seed, out vec3 emit_out, out float tall_k, out float clear_k) {
	vec2 pane = vec2(uv.x, 1.0 - uv.y);
	vec2 size = vec2(uv2.x, 1.0 - uv2.y);
	tall_k = 0.0;
	clear_k = 0.0;
	if (is_rail(size)) {
		emit_out = vec3(0.0);
		return RAIL_GLASS;
	}
	vec3 t = abs(n.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : normalize(cross(-n, vec3(0.0, 1.0, 0.0)));
	vec3 b = normalize(cross(n, t));
	vec3 v = normalize(view);
	vec3 d = vec3(dot(v, t), dot(v, b), dot(v, -n));
	float rid = pane_id(pane, p_obj, t, b, seed);
	bool tall = size.y >= 4.5;
	if (tall) {
		rid = hash12(floor(pane / bay_size(size)) + vec2(rid * 31.0));
	}
	// Wide panes at street level are shop windows.
	bool shop = !tall && size.x > 2.6 && (p_obj.y - pane.y) < 1.5;
	// Metres per pixel across the pane: interiors fade to a flat colour before they alias.
	vec2 fw = fwidth(pane);
	float detail = clamp(1.6 - max(fw.x, fw.y) * 9.0, 0.0, 1.0);
	float depth_k;
	vec3 col = room(pane, size, d, rid, shop, detail, depth_k);
	// Lit at night; shops stay lit through the evening.
	float lit = step(hash12(vec2(rid, 9.1)), window_lit);
	if (shop) {
		lit = max(lit, step(0.3, night) * step(0.24, window_lit));
	}
	float cool = step(0.8, hash12(vec2(rid, 4.4)));
	vec3 lamp = mix(vec3(1.0, 0.7, 0.42), vec3(0.72, 0.84, 1.0), cool) * (0.75 + 0.5 * hash12(vec2(rid, 6.6)));
	// Blinds or curtains on some panes, in front of the room.
	float kind_h = hash12(vec2(rid, 2.2));
	float cover = 0.0;
	vec3 cloth = vec3(0.0);
	float px = max(fw.x, fw.y);
	if (!shop) {
		if (kind_h < 0.3) {
			// Slats 7 cm apart: only drawn while they span a few pixels.
			float lvl = size.y * (0.25 + 0.6 * hash12(vec2(rid, 8.8)));
			cover = step(size.y - lvl, pane.y);
			float slats = clamp(1.0 - px / 0.07 * 2.5, 0.0, 1.0);
			cloth = vec3(0.86, 0.83, 0.76) * (1.0 - 0.14 * slats * (0.5 + 0.5 * sin(pane.y / 0.07 * 6.2832)));
		} else if (kind_h < 0.5 && !tall) {
			float cw = size.x * (0.18 + 0.12 * hash12(vec2(rid, 7.7)));
			cover = 1.0 - step(cw, pane.x) * step(pane.x, size.x - cw);
			float folds = clamp(1.0 - px / 0.35 * 2.5, 0.0, 1.0);
			cloth = FURNITURE[int(hash12(vec2(rid, 5.5)) * 5.99)] * (1.0 - 0.15 * folds * (0.5 + 0.5 * sin(pane.x * 18.0)));
		}
	}
	float day = 1.0 - night;
	// By day rooms are darker than the street outside; lit shops less so.
	vec3 inside = col * day * (0.13 * mix(1.0, 0.4, depth_k) + (shop ? 0.15 : 0.0));
	inside += col * lamp * lit * night * mix(1.0, 0.6, depth_k) * (shop ? 1.5 : 1.0);
	vec3 front = cloth * (0.3 * day + lamp * lit * night * 0.6);
	emit_out = mix(inside, front, cover);
	tall_k = tall ? 1.0 : 0.0;
	clear_k = 1.0 - cover;
	return mix(vec3(0.02), cloth * 0.3, cover);
}

vec3 window_flat(vec2 uv, vec2 uv2, vec3 n, vec3 p_obj, float seed, out vec3 emit_out) {
	// Low graphics level: one flat colour per pane, lit or not.
	vec2 pane = vec2(uv.x, 1.0 - uv.y);
	if (is_rail(vec2(uv2.x, 1.0 - uv2.y))) {
		emit_out = vec3(0.0);
		return RAIL_GLASS;
	}
	vec3 t = abs(n.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : normalize(cross(-n, vec3(0.0, 1.0, 0.0)));
	vec3 b = normalize(cross(n, t));
	float rid = pane_id(pane, p_obj, t, b, seed);
	float lit = step(hash12(vec2(rid, 9.1)), window_lit);
	vec3 lamp = vec3(1.0, 0.72, 0.45) * (0.75 + 0.5 * hash12(vec2(rid, 6.6)));
	float ceiling = 0.6 + 0.4 * smoothstep(0.2, 1.0, pane.y / max(1.0 - uv2.y, 0.5));
	emit_out = lamp * lit * night * ceiling + vec3(0.03, 0.04, 0.05) * (1.0 - night);
	return vec3(0.03);
}

void fragment() {
	vec3 base_color = m_a.rgb;
	float tint_amount = m_a.w;
	float rough = m_b.x;
	float metal = m_b.y;
	float spec = m_b.z;
	int tint_src = int(m_b.w + 0.5);
	int pattern = int(m_c.x + 0.5);
	int kind = int(m_c.y + 0.5);
	bool ground_level = m_c.w > 0.5;
	vec3 n = normalize(onrm);
	vec3 tint = tint_src == 1 ? icolor.rgb : (tint_src == 2 ? icustom.rgb : vec3(1.0));
	vec3 alb = base_color * mix(vec3(1.0), tint, tint_amount);
	float r = rough;
	float m = metal;
	float sp = spec;
	float seed = icustom.a;
	vec2 wuv = abs(n.x) > abs(n.z) ? vec2(opos.z, opos.y) : vec2(opos.x, opos.y);
	vec3 emit = vec3(0.0);
	bool wall = abs(n.y) < 0.5 && !ground_level && kind == 0;

	if (pattern == 1 || pattern == 11) {
		// Render or gravel: broad blotches, fine grain only up close.
		alb *= 0.93 + 0.12 * fbm(wuv * 0.35 + opos.xz * 0.2 + seed * 40.0);
		if (pattern == 11) {
			alb *= 0.88 + 0.22 * fbm(opos.xz * 0.25 + seed * 9.0);
			alb *= mix(1.0, 0.92 + 0.16 * vnoise(opos.xz * 3.0), aa_fade(opos.xz * 3.0));
			// From tar-dark to pale membrane roofs, some warmer, some cooler.
			alb *= 0.5 + 0.62 * fract(seed * 5.31);
			alb *= mix(vec3(1.07, 1.0, 0.9), vec3(0.94, 0.98, 1.05), fract(seed * 3.77));
		}
	} else if (pattern == 2) {
		vec2 uv = wuv / vec2(0.55, 0.24);
		float row = floor(uv.y);
		uv.x += mod(row, 2.0) * 0.5;
		vec2 cell = floor(uv);
		float fade = aa_fade(uv);
		float mortar = grid_line(uv, vec2(0.08, 0.14)) * fade;
		float bh = hash12(cell + seed * 13.0);
		alb *= mix(1.0, 0.82 + 0.3 * bh, fade);
		alb *= 0.92 + 0.14 * fbm(wuv * 0.3 + seed * 7.0);
		alb = mix(alb, vec3(0.62, 0.6, 0.56), mortar * 0.6);
	} else if (pattern == 3) {
		vec2 uv = wuv / vec2(3.0, 1.55);
		float fade = aa_fade(uv * 4.0);
		alb *= 1.0 - grid_line(uv, vec2(0.012, 0.025)) * 0.3 * fade;
		alb *= 0.94 + 0.1 * hash12(floor(uv) + seed * 7.0) * fade;
		alb *= 0.95 + 0.08 * fbm(wuv * 0.5);
	} else if (pattern == 4) {
		float c = wuv.x / 0.22;
		float fade = aa_fade(vec2(c));
		alb *= 1.0 + sin(c * 6.2832) * 0.09 * fade;
		r = mix(r, r * 0.7, (0.5 + 0.5 * sin(c * 6.2832)) * fade);
		// Rust and grime on old sheds.
		float rust = smoothstep(0.55, 0.8, fbm(wuv * 0.4 + seed * 17.0));
		alb = mix(alb, vec3(0.42, 0.24, 0.14), rust * 0.45);
	} else if (pattern == 5) {
		vec2 uv = vec2(wuv.x + opos.x + opos.z, opos.y) / vec2(0.45, 0.3);
		uv.x += mod(floor(uv.y), 2.0) * 0.5;
		float fade = aa_fade(uv);
		alb *= 1.0 - grid_line(uv, vec2(0.04, 0.2)) * 0.35 * fade;
		alb *= mix(1.0, 0.85 + 0.25 * hash12(floor(uv) + seed), fade);
		alb *= 0.9 + 0.15 * fbm(opos.xz * 0.4 + seed * 5.0);
	} else if (pattern == 6 || pattern == 10) {
		vec2 uv = (pattern == 10 ? wpos.xz : opos.xz) / (pattern == 10 ? 1.5 : 1.0);
		float fade = aa_fade(uv);
		alb *= 1.0 - grid_line(uv, vec2(0.04)) * 0.22 * fade;
		alb *= mix(1.0, 0.93 + 0.12 * hash12(floor(uv)), fade);
		alb *= 0.9 + 0.14 * fbm(wpos.xz * 0.25);
		// Gum spots and stains.
		alb *= 1.0 - smoothstep(0.62, 0.72, fbm(wpos.xz * 0.9 + 4.0)) * 0.12 * aa_fade(wpos.xz * 0.9);
	} else if (pattern == 7) {
		// Lawn: rich greens with mowing stripes.
		float g = fbm(wpos.xz * 0.06);
		alb = mix(vec3(0.1, 0.25, 0.045), vec3(0.2, 0.36, 0.07), g);
		float stripe = step(0.5, fract(opos.x / 1.4));
		alb *= mix(1.0, 0.88 + 0.2 * stripe, aa_fade(opos.xz / 1.4));
		alb *= mix(1.0, 0.9 + 0.2 * vnoise(wpos.xz * 2.0), aa_fade(wpos.xz * 2.0));
		alb = mix(alb, vec3(0.32, 0.3, 0.12), smoothstep(0.66, 0.8, fbm(wpos.xz * 0.15 + 9.0)) * 0.4);
	} else if (pattern == 8) {
		alb *= 0.86 + 0.22 * fbm(wpos.xz * 0.4);
		alb *= mix(1.0, 0.92 + 0.12 * vnoise(wpos.xz * 9.0), aa_fade(wpos.xz * 9.0));
		float patch = smoothstep(0.62, 0.66, fbm(wpos.xz * 0.12 + 3.0));
		alb *= 1.0 - patch * 0.16;
		// Faint cracks in a few worn stretches.
		float worn = smoothstep(0.58, 0.7, fbm(wpos.xz * 0.04 + 7.0));
		float crack = 1.0 - smoothstep(0.0, 0.012, abs(fbm(wpos.xz * 0.7 + 11.0) - 0.5));
		alb *= 1.0 - crack * worn * 0.2 * aa_fade(wpos.xz * 5.6);
		r = mix(r, 0.6, patch * 0.5);
	} else if (pattern == 9) {
		float s = step(0.5, fract((opos.x + opos.z) / 0.9));
		alb = mix(vec3(0.95, 0.94, 0.9), alb, s);
	}

	if (wall) {
		// Weathering: grime near the ground, rain streaks, broad stains, paler toward the top.
		float base = smoothstep(0.0, 2.4 + vnoise(vec2(wuv.x * 0.8 + seed * 9.0, seed)) * 1.2, opos.y);
		alb *= mix(0.6, 1.0, base);
		float streak = vnoise(vec2(wuv.x * 2.2 + seed * 31.0, opos.y * 0.12));
		alb *= 1.0 - smoothstep(0.5, 0.95, streak) * 0.14 * aa_fade(vec2(wuv.x * 2.2));
		alb *= 0.94 + 0.1 * fbm(wuv * 0.12 + seed * 3.0);
		alb *= 1.0 + clamp(opos.y / 120.0, 0.0, 0.1);
	}

	if (kind == 1) {
		vec3 e;
		float tall_k = 0.0;
		float clear_k = 0.0;
		// Glass is flat shaded, so n is the same all over a pane and so is the room picked
		// from it (a normal from screen derivatives is too noisy for that).
		if (gfx_quality == 0) {
			alb = window_flat(UV, UV2, n, opos, seed, e);
		} else {
			alb = window_glass(UV, UV2, n, opos, oview, seed, e, tall_k, clear_k);
		}
		emit += e;
		r = 0.06;
		sp = 0.5;
		// Office curtain walls: tinted, more mirror-like glass.
		m = tall_k * 0.55;
		// Glass is nearly black, so metallic barely changes its look, but it keeps Godot's specular
		// occlusion (driven by SSAO) from blotting out the sky reflection in the recessed panes.
		m = max(m, 0.5 * clear_k);
		alb = mix(alb, vec3(0.16, 0.26, 0.3), tall_k * 0.5);
	} else if (kind == 7) {
		alb = vec3(0.05, 0.07, 0.09);
		r = 0.04;
		m = 0.3;
	} else if (kind == 2) {
		emit += alb * (0.25 + 1.2 * smoothstep(0.1, 0.6, night));
	} else if (kind == 3) {
		emit += vec3(1.0, 0.8, 0.55) * smoothstep(0.1, 0.5, night) * 5.0;
	} else if (kind == 5) {
		emit += vec3(1.0, 0.95, 0.82) * (0.15 + smoothstep(0.1, 0.5, night) * 4.0);
	} else if (kind == 6) {
		emit += vec3(1.0, 0.05, 0.03) * (0.35 + smoothstep(0.1, 0.5, night) * 2.2);
	}
	// A building without power keeps its windows, signs and lamps dark at night.
	if (kind >= 1 && kind <= 3 && dark_of(city_at(cell_of(origin)))) {
		emit *= 1.0 - smoothstep(0.1, 0.5, night);
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
		emit *= 0.3;
	}

	// Rain: what faces up darkens and turns glossy, puddles gather on roads and paving, and
	// walls darken a little. The sky's reflection in the gloss is the wet sheen.
	float wet_k = 0.0;
	if (weather_wet > 0.001 && kind == 0) {
		float up = smoothstep(0.5, 0.9, wnrm.y) * (pattern == 7 ? 0.25 : 1.0);
		wet_k = weather_wet * mix(0.3, 1.0, up);
		alb *= 1.0 - wet_k * (pattern == 0 || pattern == 4 ? 0.2 : 0.36);
		r = mix(r, 0.14, weather_wet * up);
		sp = mix(sp, 0.6, weather_wet * up);
		if (pattern == 8 || pattern == 6 || pattern == 10) {
			float puddle = smoothstep(0.56, 0.62, fbm(wpos.xz * 0.11 + 21.0))
				* smoothstep(0.35, 0.9, weather_wet) * up;
			alb *= 1.0 - puddle * 0.4;
			r = mix(r, 0.03, puddle);
			wet_k = max(wet_k, puddle);
		}
	}

	ALBEDO = alb;
	ROUGHNESS = r;
	METALLIC = m;
	SPECULAR = sp;
	if (kind == 4) {
		BACKLIGHT = alb * 0.45;
	}
	if (kind != 3) {
		// Lamp pools spread and shine on wet ground.
		emit += alb * lamp_light(wpos, wnrm) * (1.0 + wet_k * 1.5);
	}
	emit += preview_tint(wpos) * (ground_level ? 1.0 : 0.5);
	EMISSION = emit;
}
