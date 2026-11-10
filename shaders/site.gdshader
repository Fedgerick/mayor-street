// Construction site props (scaffolding, cranes, hoardings): vertex colours, cut off above
// clip_top so one mesh serves a building at every height. UV.x > 0.5 marks debris netting.
shader_type spatial;
render_mode cull_disabled;

instance uniform float clip_top = 1000.0;

varying float oy;

void vertex() {
	oy = VERTEX.y;
}

void fragment() {
	if (oy > clip_top) {
		discard;
	}
	if (UV.x > 0.5) {
		// Netting: a screen-door weave.
		ivec2 px = ivec2(FRAGCOORD.xy);
		if (((px.x + px.y) & 1) == 0) {
			discard;
		}
	}
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.8;
	SPECULAR = 0.3;
}
