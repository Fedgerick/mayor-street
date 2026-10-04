// Umbrellas over people in the rain: one MultiMesh of UmbrellaMesh in person space.
// INSTANCE_CUSTOM.x = colour index, y = walk phase, z = stride (for a little bob).
shader_type spatial;
render_mode depth_draw_opaque, cull_disabled;

#include "res://shaders/common.gdshaderinc"

const vec3 COLS[6] = {vec3(0.06, 0.06, 0.07), vec3(0.1, 0.16, 0.36), vec3(0.75, 0.1, 0.1), vec3(0.95, 0.75, 0.1), vec3(0.2, 0.5, 0.3), vec3(0.85, 0.85, 0.88)};

varying vec3 alb;
varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	int part = int(UV.x + 0.5);
	VERTEX.y += abs(cos(INSTANCE_CUSTOM.y)) * 0.03 * INSTANCE_CUSTOM.z;
	alb = part == 1 ? vec3(0.15) : COLS[int(INSTANCE_CUSTOM.x + 0.5) % 6];
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// The underside is in its own shade.
	vec3 a = FRONT_FACING ? alb : alb * 0.55;
	ALBEDO = a;
	ROUGHNESS = 0.35;
	SPECULAR = 0.6;
	EMISSION = a * lamp_light(wpos, normalize(wnrm)) * 0.6;
}
