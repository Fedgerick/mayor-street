shader_type spatial;
// A rain streak: a quad that turns to face the camera around the drop's own Y axis, which
// the particles align to its fall (particle_flag_align_y). The built-in fixed-Y billboard
// keeps streaks upright in world Y, which on msp (Planet.on) is sideways to the ground.
// Every division is guarded: unused particles come in with an all-zero transform, and a
// NaN vertex there can upset the GPU driver.
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec4 albedo : source_color = vec4(0.8, 0.84, 0.92, 0.42);

vec3 safe_unit(vec3 v, vec3 fallback) {
	float l = length(v);
	return l > 1e-5 ? v / l : fallback;
}

void vertex() {
	vec3 y = MODEL_MATRIX[1].xyz;
	float width = length(MODEL_MATRIX[0].xyz);
	vec3 at = MODEL_MATRIX[3].xyz;
	vec3 yu = safe_unit(y, vec3(0.0, 1.0, 0.0));
	vec3 to_cam = safe_unit(INV_VIEW_MATRIX[3].xyz - at, INV_VIEW_MATRIX[2].xyz);
	vec3 xu = safe_unit(cross(yu, to_cam), INV_VIEW_MATRIX[0].xyz);
	vec3 zu = cross(xu, yu);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(xu * width, 0.0), vec4(y, 0.0), vec4(zu, 0.0), vec4(at, 1.0));
}

void fragment() {
	ALBEDO = albedo.rgb;
	ALPHA = albedo.a;
}
