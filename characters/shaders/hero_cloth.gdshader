// Everything on the player that isn't skin: fabrics, hair, eyes, shoes and accessories,
// picked by `kind` (HeroLook sets it per material slot):
//   1 jersey   2 fleece   3 jacket   4 denim   5 skirt   6 shoe upper   7 hair
//   8 brows and lashes    9 iris     10 eye white   11 mouth   12 frame / buttons
//   13 lens    14 sole    15 laces   16 ribbed trim 17 knit hat 19 cotton cap
shader_type spatial;
render_mode cull_back, depth_draw_opaque, specular_schlick_ggx;

#include "res://characters/shaders/hero_common.gdshaderinc"

const vec2 EYE = vec2(0.053, 1.673);

float ribs(vec3 p, float period) {
	// Vertical ribs around whatever the ring wraps: angle around the local vertical.
	return sin((p.x * 0.7 + p.z) / period * 6.2831853);
}

void fragment() {
	vec3 p = rest_pos;
	vec3 n = normalize(rest_nrm);
	float px = length(fwidth(p));
	vec3 col = albedo.rgb;
	float r = rough;
	float h = 0.0;
	float spec = 0.5;
	float metal = 0.0;
	vec3 glow = vec3(0.0);
	float rim = 0.3;   // Godot narrows rim light as roughness drops; keep the street look's 0.3
	float x = abs(p.x);
	if (kind == 1 || kind == 2) {   // jersey and fleece
		float k = keep(0.002, px);
		float knit = sin(p.x * 3141.6 + sin(p.y * 1570.8) * 0.8) * 0.5 + 0.5;
		float fuzz = fbm(p * 240.0);
		h = (knit * k * 0.00006 + fuzz * 0.00012) * detail;
		col *= 0.93 + 0.1 * fuzz;
		if (kind == 2) {
			col *= 0.95 + 0.08 * vnoise(p * 900.0);
			r = max(r, 0.9);
		}
		// Side seams down the torso and the shoulder seam.
		float side = smoothstep(0.93, 0.99, abs(n.x)) * step(p.y, 1.36) * step(0.95, p.y) * step(x, 0.24);
		col *= 1.0 - side * 0.12;
		h -= side * 0.0003;
		// Folds where the arms bend and round the waist.
		float folds = fbm(vec3(p.x * 40.0, p.y * 9.0, p.z * 40.0));
		h += folds * 0.0012 * detail;
		col *= 0.94 + folds * 0.1;
	} else if (kind == 3) {   // jacket: worn canvas-leather
		float grain = fbm(p * 500.0);
		float crease = 1.0 - abs(fbm(vec3(p.x * 30.0, p.y * 14.0, p.z * 30.0)) * 2.0 - 1.0);
		h = (grain * 0.0002 + pow(crease, 6.0) * 0.0009) * detail;
		col *= 0.88 + 0.18 * grain - pow(crease, 6.0) * 0.1;
		r = rough - 0.1 + grain * 0.15;
		spec = 0.55;
		float front = smoothstep(0.012, 0.0, x) * step(0.0, p.z);
		col *= 1.0 - front * 0.35;   // the zip line
		h -= front * 0.0006;
		col += stitch(x - 0.012, p.y, px) * 0.12 * step(0.05, p.z);
	} else if (kind == 4) {   // denim: diagonal twill, fading, side seams
		float k = keep(0.0025, px);
		float twill = sin((p.y * 1.0 + p.x * 0.7 + p.z * 0.7) * 2513.0) * 0.5 + 0.5;
		float fade = fbm(vec3(p.x * 20.0, p.y * 6.0, p.z * 20.0));
		float thread = vnoise(vec3(p.x * 2000.0, p.y * 160.0, p.z * 2000.0));
		col *= mix(0.85, 1.08, twill * k) * (0.9 + 0.22 * fade) * (0.94 + 0.1 * thread);
		// Lighter where denim wears: front of the thighs and the knees.
		float wear = smoothstep(0.03, 0.12, p.z) * smoothstep(0.35, 0.75, p.y) * step(p.y, 0.9);
		col = mix(col, col * 1.35 + vec3(0.03), wear * 0.35 * fade);
		h = (twill * k * 0.00012 + fade * 0.0008) * detail;
		// Seams down the outside and inside of each leg, with orange stitching beside them.
		float leg = step(p.y, 0.92) * step(0.14, p.y);
		float side = (abs(n.x) - 0.985) * 0.06;
		float seam = leg * (1.0 - smoothstep(0.0, 0.0008 + px, abs(side)));
		col *= 1.0 - seam * 0.25;
		h -= seam * 0.0003;
		col = mix(col, vec3(0.75, 0.48, 0.2), stitch(side - 0.0022, p.y, px) * leg * 0.8);
		// Waistband stitching.
		col = mix(col, vec3(0.75, 0.48, 0.2), stitch(p.y - 0.986, x + p.z, px) * 0.8);
		col = mix(col, vec3(0.75, 0.48, 0.2), stitch(p.y - 1.014, x + p.z, px) * 0.8);
		r = 0.88;
	} else if (kind == 5) {   // skirt: soft wool twill and pleat shading
		float pleat = sin(atan(p.x, p.z) * 14.0) * smoothstep(0.88, 0.68, p.y);
		h = (pleat * 0.002 + fbm(p * 400.0) * 0.0002) * detail;
		col *= 0.92 + pleat * 0.06 + fbm(p * 400.0) * 0.08;
	} else if (kind == 6) {   // shoe upper: leather or canvas, toe cap and stitching
		float grain = fbm(p * 700.0);
		h = grain * 0.00015 * detail;
		col *= 0.9 + grain * 0.15;
		float toe = smoothstep(0.06, 0.09, p.z);
		col *= 1.0 - toe * 0.06;
		col = mix(col, col * 0.6, stitch(p.y - 0.05, p.z + p.x, px) * 0.8);
		spec = 0.6;
	} else if (kind == 7) {   // hair: strands, root shade, a moving sheen
		float strands = vnoise(vec3(p.x * 900.0, p.y * 55.0, p.z * 900.0));
		float clumps = fbm(vec3(p.x * 70.0, p.y * 18.0, p.z * 70.0));
		float k = keep(0.0015, px);
		h = (strands * k * 0.00005 + clumps * 0.0012) * detail;
		col *= mix(0.85, 1.15, strands * k + (1.0 - k) * 0.5) * (0.88 + clumps * 0.24);
		r = rough + (strands - 0.5) * 0.1;
		spec = 0.55;
	} else if (kind == 8) {   // brows and lashes
		float s = vnoise(vec3(p.x * 1600.0, p.y * 300.0, p.z * 1600.0));
		col *= 0.75 + 0.4 * s;
		h = s * 0.00002 * detail;
	} else if (kind == 9) {   // iris: pupil, radial fibres, a dark limbal ring, a catchlight
		vec2 c = vec2(sign(p.x) * EYE.x, EYE.y);
		vec2 d = p.xy - c;
		float rr = length(d);
		float ang = atan(d.y, d.x);
		float fib = vnoise(vec3(ang * 9.0, rr * 900.0, 0.0));
		vec3 iris = accent.rgb * (0.65 + 0.7 * fib) * mix(1.25, 0.6, smoothstep(0.0035, 0.011, rr));
		iris = mix(iris, accent.rgb * 0.25, smoothstep(0.0102, 0.0124, rr));
		col = mix(vec3(0.01), iris, smoothstep(0.0040, 0.0049, rr));
		col = mix(col, vec3(0.9, 0.88, 0.85), smoothstep(0.0128, 0.0142, rr));
		float catch_ = 1.0 - smoothstep(0.0009, 0.0014, length(d - vec2(0.0034, 0.0038)));
		glow = vec3(1.0) * catch_ * 1.2;
		r = 0.04;
		spec = 0.9;
		rim = 0.0;
	} else if (kind == 10) {   // eye white: veins toward the edge, shaded under the lid
		vec2 c = vec2(sign(p.x) * EYE.x, EYE.y);
		float rr = length(p.xy - c);
		col = mix(col, col * vec3(1.0, 0.82, 0.8), smoothstep(0.014, 0.027, rr) * 0.5);
		col *= 1.0 - smoothstep(-0.005, 0.02, p.y - EYE.y) * 0.3;
		r = 0.08;
		spec = 0.8;
		rim = 0.0;
	} else if (kind == 11) {   // mouth line
		r = 0.4;
		rim = 0.0;
	} else if (kind == 12) {   // frames and buttons: glossy plastic
		r = 0.18;
		spec = 0.7;
	} else if (kind == 13) {   // lens: dark glass with a mirror sheen
		r = 0.03;
		metal = 0.6;
		spec = 1.0;
	} else if (kind == 14) {   // rubber sole with tread lines
		float tread = step(0.5, fract(p.z / 0.008)) * smoothstep(0.012, 0.002, p.y);
		col *= 1.0 - tread * 0.25;
		h = (tread * 0.0005 + vnoise(p * 900.0) * 0.0001) * detail;
		r = 0.75;
	} else if (kind == 15) {   // laces and drawstrings: twisted cord
		float tw = sin((p.x + p.y + p.z) * 3000.0) * 0.5 + 0.5;
		col *= 0.88 + tw * 0.14 * keep(0.002, px);
		r = 0.85;
	} else if (kind == 16 || kind == 17) {   // ribbed knit: cuffs, collars, beanies
		float k = keep(0.004, px);
		float rb = ribs(p, kind == 17 ? 0.006 : 0.004) * k;
		h = (rb * 0.0003 + vnoise(p * 900.0) * 0.0001) * detail;
		col *= 0.92 + rb * 0.06 + vnoise(p * 300.0) * 0.06;
		r = 0.9;
	} else if (kind == 19) {   // cotton cap: panel seams from the button
		float panels = abs(sin(atan(p.x, p.z) * 3.0));
		float seam = smoothstep(0.06, 0.0, panels) * step(1.73, p.y);
		h = (fbm(p * 500.0) * 0.00015 - seam * 0.0005) * detail;
		col *= (0.92 + fbm(p * 500.0) * 0.1) * (1.0 - seam * 0.2);
	}
	ALBEDO = col;
	ROUGHNESS = clamp(r, 0.03, 1.0);
	SPECULAR = spec;
	METALLIC = metal;
	EMISSION = glow;
	RIM = rim;
	RIM_TINT = 0.5;
	NORMAL = bumped(NORMAL, VERTEX, h);
}
