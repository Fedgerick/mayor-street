shader_type spatial;
// A rain streak: a quad that turns to face the camera around the drop's own Y axis, which
// the particles align to its fall (particle_flag_align_y). The built-in fixed-Y billboard
// keeps streaks upright in world Y, which on msp (Planet.on) is sideways to the ground.
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec4 albedo : source_color = vec4(0.8, 0.84, 0.92, 0.42);

void vertex() {
	vec3 y = MODEL_MATRIX[1].xyz;
	vec3 at = MODEL_MATRIX[3].xyz;
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - at;
	vec3 x = cross(normalize(y), to_cam);
	x = length(x) > 1e-4 ? normalize(x) : INV_VIEW_MATRIX[0].xyz;
	x *= length(MODEL_MATRIX[0].xyz);
	vec3 z = normalize(cross(x, y));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(x, 0.0), vec4(y, 0.0), vec4(z, 0.0), vec4(at, 1.0));
}

void fragment() {
	ALBEDO = albedo.rgb;
	ALPHA = albedo.a;
}
