// Every opaque part of a vehicle in one material. The Blender car kit writes the part id
// into UV.x and a palette index into UV.y (see vehicles/tools/build_cars.py), so a whole
// car is one draw call plus one for its glass.
//
// Per instance (MultiMesh custom data, or set_instance_shader_parameter-free defaults of 0):
//   COLOR.rgb            paint tint (P_PAINT parts)
//   INSTANCE_CUSTOM.r    flags: 1 siren on, 2 brake lights, 4 empty (hide driver and
//                        passengers), 8 headlights on in daylight
//   INSTANCE_CUSTOM.g    wheel roll angle, radians (grows while driving forward)
//   INSTANCE_CUSTOM.b    front wheel steer angle, radians (+ = left)
//   INSTANCE_CUSTOM.a    seed 0..1: driver look and siren phase
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

// Part ids (UV.x).
const int P_PAINT = 0;
const int P_SOLID = 1;
const int P_GLOSS = 2;
const int P_CHROME = 3;
const int P_TIRE = 4;
const int P_RIM = 5;
const int P_HEADLIGHT = 6;
const int P_TAILLIGHT = 7;
const int P_SIREN_R = 8;
const int P_SIREN_B = 9;
const int P_SKIN = 10;
const int P_CLOTH = 11;
const int P_HAIR = 12;
const int P_AMBER = 13;
const int P_BURNT = 14;
const int P_GLASS_OPAQUE = 15;
const int P_SIGN = 16;
const int P_REVERSE = 17;

const vec3 PALETTE[16] = vec3[16](
	vec3(0.025, 0.025, 0.028),  // 0 black
	vec3(0.09, 0.09, 0.1),      // 1 dark
	vec3(0.3, 0.3, 0.32),       // 2 grey
	vec3(0.62, 0.62, 0.6),      // 3 light grey
	vec3(0.9, 0.9, 0.88),       // 4 white
	vec3(0.98, 0.72, 0.05),     // 5 taxi yellow
	vec3(0.06, 0.08, 0.16),     // 6 navy
	vec3(0.72, 0.05, 0.04),     // 7 red
	vec3(0.1, 0.42, 0.18),      // 8 green
	vec3(0.08, 0.3, 0.68),      // 9 blue
	vec3(1.0, 0.55, 0.08),      // 10 orange
	vec3(0.42, 0.3, 0.2),       // 11 tan
	vec3(0.7, 0.71, 0.72),      // 12 silver
	vec3(0.55, 0.49, 0.4),      // 13 beige
	vec3(0.93, 0.9, 0.78),      // 14 cream
	vec3(1.0, 0.5, 0.05));      // 15 amber

const vec3 SKINS[6] = vec3[6](
	vec3(0.96, 0.78, 0.64), vec3(0.88, 0.66, 0.5), vec3(0.72, 0.5, 0.34),
	vec3(0.55, 0.36, 0.22), vec3(0.38, 0.24, 0.15), vec3(0.93, 0.72, 0.58));
const vec3 HAIRS[6] = vec3[6](
	vec3(0.06, 0.04, 0.03), vec3(0.2, 0.12, 0.06), vec3(0.45, 0.3, 0.14),
	vec3(0.78, 0.62, 0.32), vec3(0.6, 0.6, 0.6), vec3(0.5, 0.18, 0.06));
const vec3 CLOTHES[8] = vec3[8](
	vec3(0.75, 0.15, 0.12), vec3(0.15, 0.35, 0.7), vec3(0.9, 0.88, 0.82), vec3(0.18, 0.18, 0.2),
	vec3(0.2, 0.55, 0.3), vec3(0.95, 0.7, 0.15), vec3(0.5, 0.3, 0.6), vec3(0.85, 0.45, 0.25));

varying flat int part;
varying flat int pal;
varying flat int flags;
varying vec3 opos;
varying vec3 wpos;
varying vec3 wnrm;
varying vec4 tint;
varying float seed;

vec3 rot_x(vec3 p, float a) {
	float c = cos(a), s = sin(a);
	return vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

vec3 rot_y(vec3 p, float a) {
	float c = cos(a), s = sin(a);
	return vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

void vertex() {
	part = int(UV.x + 0.5);
	pal = int(UV.y + 0.5);
	flags = int(INSTANCE_CUSTOM.r + 0.5);
	seed = INSTANCE_CUSTOM.a;
	tint = COLOR;
	if (part == P_TIRE || part == P_RIM) {
		// UV.y = wheel centre x, UV2 = (centre z, centre y).
		vec3 c = vec3(UV.y, UV2.y, UV2.x);
		vec3 p = rot_x(VERTEX - c, -INSTANCE_CUSTOM.g);
		vec3 n = rot_x(NORMAL, -INSTANCE_CUSTOM.g);
		if (c.z < 0.0) {
			p = rot_y(p, INSTANCE_CUSTOM.b);
			n = rot_y(n, INSTANCE_CUSTOM.b);
		}
		VERTEX = p + c;
		NORMAL = n;
		pal = 0;
	}
	if ((flags & 4) != 0 && (part == P_SKIN || part == P_CLOTH || part == P_HAIR)) {
		VERTEX = vec3(0.0);
	}
	opos = VERTEX;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float person_hash() {
	// Passengers sit at different places, so each gets its own look.
	return hash12(vec2(seed * 97.0, floor(opos.z * 1.5) + floor(opos.x * 2.0) * 7.0));
}

void fragment() {
	vec3 alb = vec3(0.5);
	float r = 0.6;
	float m = 0.0;
	float sp = 0.5;
	float cc = 0.0;
	vec3 emit = vec3(0.0);
	float lit_k = smoothstep(0.1, 0.5, night);
	bool lights_on = lit_k > 0.0 || (flags & 8) != 0;
	float head_on = max(lit_k, float((flags & 8) != 0));
	if (part == P_PAINT || part == P_GLOSS) {
		alb = part == P_PAINT ? tint.rgb : PALETTE[pal];
		r = 0.28;
		m = 0.15;
		sp = 0.6;
		cc = 1.0;
		// Road grime toward the sills.
		alb *= mix(0.72, 1.0, smoothstep(0.25, 0.75, opos.y));
	} else if (part == P_SOLID) {
		alb = PALETTE[pal];
		r = 0.62;
		sp = 0.4;
	} else if (part == P_CHROME) {
		alb = vec3(0.85, 0.86, 0.88);
		r = 0.12;
		m = 1.0;
	} else if (part == P_TIRE) {
		alb = vec3(0.045, 0.045, 0.05);
		r = 0.88;
		sp = 0.25;
	} else if (part == P_RIM) {
		alb = vec3(0.72, 0.73, 0.75);
		r = 0.3;
		m = 0.85;
	} else if (part == P_HEADLIGHT) {
		alb = vec3(0.85, 0.88, 0.9);
		r = 0.08;
		sp = 0.9;
		emit = vec3(1.0, 0.95, 0.84) * (0.12 + head_on * 5.0);
	} else if (part == P_TAILLIGHT) {
		alb = vec3(0.55, 0.03, 0.03);
		r = 0.15;
		float brake = float((flags & 2) != 0);
		emit = vec3(1.0, 0.04, 0.02) * (0.3 + lit_k * 3.0 + brake * 5.0);
	} else if (part == P_SIREN_R || part == P_SIREN_B) {
		bool red = part == P_SIREN_R;
		alb = red ? vec3(0.6, 0.04, 0.03) : vec3(0.04, 0.1, 0.6);
		r = 0.12;
		float on = 0.0;
		if ((flags & 1) != 0) {
			// Two quick flashes per side, sides alternate.
			float t = fract(TIME * 1.6 + seed);
			float ph = red ? t : fract(t + 0.5);
			on = step(ph, 0.12) + step(0.2, ph) * step(ph, 0.32);
		}
		vec3 col = red ? vec3(1.0, 0.06, 0.03) : vec3(0.08, 0.25, 1.0);
		emit = col * (0.08 + on * 14.0);
	} else if (part == P_SKIN) {
		alb = SKINS[int(person_hash() * 5.99)];
		r = 0.7;
		sp = 0.35;
	} else if (part == P_CLOTH) {
		alb = pal == 0 ? CLOTHES[int(hash12(vec2(seed * 31.0, 2.0)) * 7.99)] :
			(pal >= 8 ? CLOTHES[int(person_hash() * 7.99)] : PALETTE[pal]);
		r = 0.85;
		sp = 0.3;
	} else if (part == P_HAIR) {
		alb = HAIRS[int(hash12(vec2(person_hash() * 13.0, 4.0)) * 5.99)];
		r = 0.75;
	} else if (part == P_AMBER) {
		alb = vec3(0.9, 0.45, 0.05);
		r = 0.15;
		emit = vec3(1.0, 0.45, 0.05) * (0.1 + lit_k * 0.4);
	} else if (part == P_BURNT) {
		float n = fbm(opos.xz * 3.0 + opos.y * 2.0);
		alb = mix(vec3(0.035, 0.03, 0.028), vec3(0.24, 0.11, 0.05), smoothstep(0.45, 0.75, n));
		alb = mix(alb, vec3(0.16, 0.15, 0.14), float(pal == 1) * 0.6 * n);
		r = 0.95;
		sp = 0.2;
	} else if (part == P_GLASS_OPAQUE) {
		alb = vec3(0.04, 0.055, 0.07);
		r = 0.06;
		m = 0.4;
		sp = 0.8;
	} else if (part == P_SIGN) {
		alb = PALETTE[pal];
		r = 0.4;
		emit = PALETTE[pal] * (0.15 + lit_k * 1.6);
	} else if (part == P_REVERSE) {
		alb = vec3(0.8);
		r = 0.1;
	}
	ALBEDO = alb;
	ROUGHNESS = r;
	METALLIC = m;
	SPECULAR = sp;
	CLEARCOAT = cc;
	CLEARCOAT_ROUGHNESS = 0.08;
	emit += alb * lamp_light(wpos, wnrm);
	EMISSION = emit;
}
