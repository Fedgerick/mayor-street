// Pedestrians: one MultiMesh of PersonMesh. Walk cycle in the vertex shader.
// INSTANCE_CUSTOM: x = walk phase (radians), y = stride (0 standing, 1 walking),
// z = shirt + pants * 8, w = skin + hair * 8 (palette indices).
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

const vec3 SHIRTS[8] = vec3[8](
	vec3(0.85, 0.2, 0.18), vec3(0.15, 0.45, 0.75), vec3(0.95, 0.93, 0.88), vec3(0.2, 0.55, 0.35),
	vec3(0.95, 0.7, 0.15), vec3(0.45, 0.25, 0.6), vec3(0.12, 0.13, 0.15), vec3(0.95, 0.5, 0.55));
const vec3 PANTS[6] = vec3[6](
	vec3(0.15, 0.2, 0.35), vec3(0.1, 0.1, 0.12), vec3(0.55, 0.47, 0.35), vec3(0.3, 0.32, 0.35),
	vec3(0.25, 0.35, 0.55), vec3(0.4, 0.25, 0.18));
const vec3 SKINS[5] = vec3[5](
	vec3(0.98, 0.8, 0.66), vec3(0.88, 0.66, 0.5), vec3(0.7, 0.48, 0.33), vec3(0.5, 0.33, 0.22),
	vec3(0.35, 0.22, 0.15));
const vec3 HAIRS[5] = vec3[5](
	vec3(0.08, 0.06, 0.05), vec3(0.3, 0.18, 0.1), vec3(0.75, 0.6, 0.35), vec3(0.55, 0.25, 0.12),
	vec3(0.6, 0.6, 0.6));

varying vec3 alb;
varying vec3 wpos;
varying vec3 wnrm;

vec3 rot_x(vec3 v, float pivot_y, float a) {
	float c = cos(a), s = sin(a);
	float y = v.y - pivot_y;
	return vec3(v.x, pivot_y + y * c - v.z * s, y * s + v.z * c);
}

void vertex() {
	int part = int(UV.x + 0.5);
	float phase = INSTANCE_CUSTOM.x;
	float stride = INSTANCE_CUSTOM.y;
	int look = int(INSTANCE_CUSTOM.z + 0.5);
	int look2 = int(INSTANCE_CUSTOM.w + 0.5);
	float swing = sin(phase) * 0.45 * stride;
	vec3 v = VERTEX;
	vec3 n = NORMAL;
	if (part == 0 || part == 1) {
		float a = part == 0 ? swing : -swing;
		v = rot_x(v, 0.9, a);
		n = rot_x(n, 0.0, a);
	} else if (part == 3 || part == 4) {
		float a = (part == 3 ? -swing : swing) * 0.8;
		v = rot_x(v, 1.4, a);
		n = rot_x(n, 0.0, a);
	}
	// Body bob and a little sway while walking; idle people breathe.
	v.y += abs(cos(phase)) * 0.035 * stride;
	if (part >= 2) {
		v.x += sin(phase) * 0.015 * stride;
		v.y += (1.0 - stride) * sin(TIME * 1.7 + INSTANCE_CUSTOM.z) * 0.006 * (v.y - 0.9);
	}
	VERTEX = v;
	NORMAL = n;

	vec3 shirt = SHIRTS[look % 8];
	vec3 pants = PANTS[(look / 8) % 6];
	vec3 skin = SKINS[look2 % 5];
	vec3 hair = HAIRS[(look2 / 8) % 5];
	if (part <= 1) {
		alb = VERTEX.y < 0.075 ? vec3(0.1, 0.09, 0.09) : pants;
	} else if (part == 2) {
		alb = shirt;
	} else if (part <= 4) {
		alb = VERTEX.y < 0.92 ? skin : shirt * 0.92;
	} else if (part == 5) {
		alb = skin;
	} else {
		alb = hair;
	}
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = alb;
	ROUGHNESS = 0.8;
	SPECULAR = 0.35;
	// Soft rim so people read against the street at a distance.
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = alb * lamp_light(wpos, normalize(wnrm)) + alb * rim * 0.15 * (1.0 - night);
}
