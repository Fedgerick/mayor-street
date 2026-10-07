// A whole person in one draw call: CharacterModel's LOD1 mesh carries every material slot
// in one surface, with the slot number in vertex COLOR.r, and each person's colours come
// in as per-instance uniforms (rgb = colour, a = roughness).
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

instance uniform vec4 c_skin : source_color = vec4(0.89, 0.66, 0.5, 0.55);
instance uniform vec4 c_shirt : source_color = vec4(0.2, 0.47, 0.86, 0.78);
instance uniform vec4 c_jacket : source_color = vec4(0.16, 0.13, 0.11, 0.55);
instance uniform vec4 c_pants : source_color = vec4(0.17, 0.22, 0.38, 0.85);
instance uniform vec4 c_shoes : source_color = vec4(0.96, 0.96, 0.96, 0.45);
instance uniform vec4 c_hair : source_color = vec4(0.12, 0.09, 0.07, 0.85);
instance uniform vec4 c_brows : source_color = vec4(0.1, 0.08, 0.06, 0.85);
instance uniform vec4 c_eyes : source_color = vec4(0.03, 0.03, 0.04, 0.15);
instance uniform vec4 c_eyewhite : source_color = vec4(0.92, 0.91, 0.88, 0.3);
instance uniform vec4 c_hat : source_color = vec4(0.12, 0.12, 0.14, 0.7);
instance uniform vec4 c_stubble : source_color = vec4(0.5, 0.36, 0.28, 0.95);

varying flat int slot;

void vertex() {
	slot = int(COLOR.r * 15.0 + 0.5);
}

void fragment() {
	vec4 c = c_skin;
	if (slot == 1) c = c_shirt;
	else if (slot == 2) c = c_jacket;
	else if (slot == 3) c = c_pants;
	else if (slot == 4) c = c_shoes;
	else if (slot == 5) c = c_hair;
	else if (slot == 6) c = c_brows;
	else if (slot == 7) c = c_eyes;
	else if (slot == 8) c = c_eyewhite;
	else if (slot == 9) c = c_hat;
	else if (slot == 10) c = c_stubble;
	ALBEDO = c.rgb;
	ROUGHNESS = c.a;
	RIM = 0.3;
	RIM_TINT = 0.5;
}
