// Dogs on leads: one MultiMesh of DogMesh, trotting in the vertex shader.
// INSTANCE_CUSTOM: x = trot phase, y = stride (0 standing .. 1 trotting), z = coat index.
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

const vec3 COATS[5] = {vec3(0.55, 0.36, 0.2), vec3(0.12, 0.1, 0.09), vec3(0.9, 0.85, 0.75), vec3(0.78, 0.55, 0.28), vec3(0.45, 0.45, 0.47)};

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
	vec3 v = VERTEX;
	vec3 n = NORMAL;
	if (part >= 2 && part <= 5) {
		// Diagonal pairs move together, like a trot.
		float sgn = (part == 2 || part == 5) ? 1.0 : -1.0;
		float a = sin(phase) * 0.5 * stride * sgn;
		float pz = part <= 3 ? -0.24 : 0.22;
		v.z -= pz;
		v = rot_x(v, 0.3, a);
		v.z += pz;
		n = rot_x(n, 0.0, a);
	} else if (part == 6) {
		v.x += sin(TIME * 9.0 + INSTANCE_CUSTOM.z) * 0.6 * (v.y - 0.44);
	} else if (part == 1) {
		v.y += sin(TIME * 1.3 + INSTANCE_CUSTOM.z) * 0.01;
	}
	v.y += abs(cos(phase)) * 0.025 * stride;
	VERTEX = v;
	NORMAL = n;
	vec3 coat = COATS[int(INSTANCE_CUSTOM.z + 0.5) % 5];
	alb = part == 1 && v.z < -0.55 ? coat * 0.35 : coat;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = alb;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = alb * lamp_light(wpos, normalize(wnrm)) + alb * rim * 0.12 * (1.0 - night);
}
