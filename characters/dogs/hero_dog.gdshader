// Street dogs: HeroDog's mesh in citylife's dog MultiMesh. The vertex animation is
// citylife/dog.gdshader's (same INSTANCE_CUSTOM contract: x = trot phase, y = stride,
// z = coat index), plus five breeds with markings, fur, a wet nose, glossy eyes and a
// collar. UV.x = part (0 body, 1 head, 2..5 legs, 6 tail), UV.y = material (0 coat,
// 1 nose, 2 eye, 3 collar, 4 tongue).
shader_type spatial;
render_mode depth_draw_opaque, cull_back;

#include "res://shaders/common.gdshaderinc"

// Breeds, by coat index: lab, border collie, golden, beagle, husky.
const vec3 BASE[5] = {vec3(0.5, 0.32, 0.17), vec3(0.07, 0.065, 0.065), vec3(0.86, 0.68, 0.42), vec3(0.68, 0.42, 0.18), vec3(0.42, 0.43, 0.47)};
const vec3 MARK[5] = {vec3(0.6, 0.42, 0.25), vec3(0.93, 0.92, 0.9), vec3(0.95, 0.88, 0.72), vec3(0.94, 0.92, 0.88), vec3(0.94, 0.94, 0.95)};
const vec3 COLLAR[5] = {vec3(0.75, 0.14, 0.12), vec3(0.15, 0.35, 0.75), vec3(0.15, 0.55, 0.3), vec3(0.85, 0.65, 0.12), vec3(0.5, 0.2, 0.6)};

varying vec3 lpos;
varying flat int part;
varying flat int mat;
varying flat int breed;
varying vec3 wpos;
varying vec3 wnrm;

vec3 rot_x(vec3 v, float pivot_y, float a) {
	float c = cos(a), s = sin(a);
	float y = v.y - pivot_y;
	return vec3(v.x, pivot_y + y * c - v.z * s, y * s + v.z * c);
}

void vertex() {
	part = int(UV.x + 0.5);
	mat = int(UV.y + 0.5);
	breed = int(INSTANCE_CUSTOM.z + 0.5) % 5;
	lpos = VERTEX;
	float phase = INSTANCE_CUSTOM.x;
	float stride = INSTANCE_CUSTOM.y;
	vec3 v = VERTEX;
	vec3 n = NORMAL;
	if (part >= 2 && part <= 5) {
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
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float h3(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419)) * 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float n3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1, 0, 0)), f.x), mix(h3(i + vec3(0, 1, 0)), h3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h3(i + vec3(0, 0, 1)), h3(i + vec3(1, 0, 1)), f.x), mix(h3(i + vec3(0, 1, 1)), h3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// How much of the marking colour shows at this point, per breed.
float marking(vec3 p) {
	bool body = part == 0;
	bool head = part == 1;
	bool leg = part >= 2 && part <= 5;
	float belly = body ? smoothstep(0.38, 0.33, p.y) : 0.0;
	float chest = body ? smoothstep(0.05, -0.12, p.z) * smoothstep(0.46, 0.38, p.y) : 0.0;
	float muzzle = head ? smoothstep(-0.47, -0.52, p.z) : 0.0;
	float socks = leg ? smoothstep(0.13, 0.09, p.y) : 0.0;
	float tip = part == 6 ? smoothstep(0.57, 0.6, p.y) : 0.0;
	if (breed == 0) return muzzle * 0.25 + belly * 0.4;
	if (breed == 1) {   // border collie: white blaze, chest, belly, socks and tail tip
		float blaze = head ? (1.0 - smoothstep(0.006, 0.014, abs(p.x))) * smoothstep(-0.4, -0.47, p.z) : 0.0;
		return max(max(max(chest, belly), max(muzzle, socks)), max(tip, blaze));
	}
	if (breed == 2) return belly * 0.6 + muzzle * 0.3;
	if (breed == 3) return max(max(chest, belly), max(max(muzzle, socks), tip));
	// husky: white mask under the eyes, chest, belly and legs
	float mask = head ? smoothstep(0.62, 0.59, p.y) : 0.0;
	return max(max(chest, belly), max(mask, leg ? smoothstep(0.3, 0.2, p.y) : 0.0));
}

void fragment() {
	vec3 p = lpos;
	vec3 col;
	float rough = 0.85;
	float spec = 0.25;
	float h = 0.0;
	if (mat == 1) {          // nose: wet leather
		col = vec3(0.04, 0.035, 0.035);
		rough = 0.25;
		spec = 0.6;
		h = n3(p * 900.0) * 0.0002;
	} else if (mat == 2) {   // eye: glossy dark brown
		col = vec3(0.07, 0.04, 0.025);
		rough = 0.05;
		spec = 0.9;
	} else if (mat == 3) {   // collar and tag
		col = p.y < 0.478 ? vec3(0.85, 0.72, 0.3) : COLLAR[breed];
		rough = p.y < 0.478 ? 0.3 : 0.6;
		spec = p.y < 0.478 ? 0.8 : 0.4;
	} else if (mat == 4) {
		col = vec3(0.8, 0.36, 0.38);
		rough = 0.35;
	} else {
		col = mix(BASE[breed], MARK[breed], clamp(marking(p), 0.0, 1.0));
		if (breed == 3) {    // beagle: black saddle over the back
			float saddle = float(part == 0) * smoothstep(0.44, 0.48, p.y) * smoothstep(-0.2, -0.12, p.z) * smoothstep(0.24, 0.16, p.z);
			col = mix(col, vec3(0.06, 0.05, 0.05), saddle);
		}
		if (breed == 4) {    // husky: darker along the back
			col *= mix(1.0, 0.65, smoothstep(0.45, 0.52, p.y) * float(part == 0));
		}
		// Fur: strands running back along the body and down the legs.
		vec3 q = (part >= 2 && part <= 5) ? vec3(p.x * 260.0, p.y * 40.0, p.z * 260.0) : vec3(p.x * 260.0, p.y * 260.0, p.z * 40.0);
		float strands = n3(q);
		float tufts = n3(p * 60.0);
		col *= 0.86 + 0.2 * strands + 0.08 * tufts;
		float px = length(fwidth(p));
		h = (strands * 0.0005 * clamp(0.004 / max(px, 1e-5) - 1.0, 0.0, 1.0) + tufts * 0.0012);
	}
	// Bump from the height (screen-space derivatives; no tangents needed).
	vec3 dpdx = dFdx(VERTEX), dpdy = dFdy(VERTEX);
	vec3 r1 = cross(dpdy, NORMAL), r2 = cross(NORMAL, dpdx);
	float det = dot(dpdx, r1);
	NORMAL = normalize(abs(det) * NORMAL - sign(det) * (dFdx(h) * r1 + dFdy(h) * r2));
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = spec;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = col * lamp_light(wpos, normalize(wnrm)) + col * rim * 0.12 * (1.0 - night) * float(mat == 0);
}
