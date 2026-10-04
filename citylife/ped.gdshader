// Pedestrians: one MultiMesh of PersonMesh. Walk cycle in the vertex shader.
// INSTANCE_CUSTOM: x = walk phase (radians), y = stride (0 standing, 1 walking, 1.5
// running) + 4 * pose, z = shirt + pants * 8, w = skin + hair * 8 + shoes * 64 (palette
// indices). Poses: 0 none, 1 sitting, 2 phone in hand, 3 chatting, 4 umbrella up,
// 5 dog lead in hand.
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

// Palettes come from CharacterModel (set by Crowd), so cheap and full models match.
uniform vec3 shirts[8];
uniform vec3 pants[5];
uniform vec3 skins[5];
uniform vec3 hairs[5];
uniform vec3 shoes[4];

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
	int pose = int(floor(INSTANCE_CUSTOM.y * 0.25 + 0.001));
	float stride = INSTANCE_CUSTOM.y - float(pose) * 4.0;
	int look = int(INSTANCE_CUSTOM.z + 0.5);
	int look2 = int(INSTANCE_CUSTOM.w + 0.5);
	float seed = INSTANCE_CUSTOM.z * 1.7 + INSTANCE_CUSTOM.w * 0.31;
	float swing = sin(phase) * 0.45 * stride;
	// Leg and arm angles (positive swings forward). Arms default to the walk swing.
	float leg_l = swing;
	float leg_r = -swing;
	float arm_l = -swing * 0.8;
	float arm_r = swing * 0.8;
	float head = 0.0;
	float drop = 0.0;
	if (pose == 1) {          // sitting: legs forward and down, hands on the knees
		leg_l = 1.05;
		leg_r = 1.05;
		arm_l = 0.4;
		arm_r = 0.4;
		drop = 0.42;
	} else if (pose == 2) {   // looking at a phone held in the right hand
		arm_r = 1.15;
		head = -0.32;
	} else if (pose == 3) {   // talking with the hands now and then
		float talk = smoothstep(0.2, 0.6, sin(TIME * 0.7 + seed));
		arm_r = mix(0.05, 0.55 + 0.35 * sin(TIME * 2.6 + seed), talk);
		arm_l = mix(0.0, 0.25 + 0.2 * sin(TIME * 1.9 + seed * 2.0), talk * 0.6);
		head = 0.08 * sin(TIME * 1.3 + seed);
	} else if (pose == 4) {   // umbrella held up in the right hand
		arm_r = 1.3;
	} else if (pose == 5) {   // dog lead in the right hand
		arm_r = 0.45;
	}
	vec3 v = VERTEX;
	float oy = VERTEX.y;
	vec3 n = NORMAL;
	if (part == 0 || part == 1) {
		float a = part == 0 ? leg_l : leg_r;
		v = rot_x(v, 0.9, a);
		n = rot_x(n, 0.0, a);
	} else if (part == 3 || part == 4) {
		float a = part == 3 ? arm_l : arm_r;
		v = rot_x(v, 1.4, a);
		n = rot_x(n, 0.0, a);
	} else if (part >= 5 && head != 0.0) {
		v = rot_x(v, 1.5, head);
		n = rot_x(n, 0.0, head);
	}
	// Body bob and a little sway while walking; idle people breathe.
	v.y += abs(cos(phase)) * 0.035 * stride;
	if (part >= 2) {
		v.x += sin(phase) * 0.015 * stride;
		v.y += (1.0 - min(stride, 1.0)) * sin(TIME * 1.7 + INSTANCE_CUSTOM.z) * 0.006 * (v.y - 0.9);
	}
	v.y -= drop;
	VERTEX = v;
	NORMAL = n;

	vec3 shirt = shirts[look % 8];
	vec3 pant = pants[(look / 8) % 5];
	vec3 skin = skins[look2 % 8 % 5];
	vec3 hair = hairs[(look2 / 8) % 8 % 5];
	vec3 shoe = shoes[(look2 / 64) % 4];
	if (part <= 1) {
		alb = oy < 0.075 ? shoe : pant;
	} else if (part == 2) {
		alb = shirt;
	} else if (part <= 4) {
		alb = oy < 0.92 ? skin : shirt * 0.92;
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
