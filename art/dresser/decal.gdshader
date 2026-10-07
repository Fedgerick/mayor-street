shader_type spatial;
// Ground wear and graffiti from art/dresser/decals.png (4 x 4 tiles). One MultiMesh of flat
// quads; INSTANCE_CUSTOM.r picks the tile (0..15), .g is the opacity, COLOR tints the tile.
render_mode blend_mix, depth_draw_never, cull_back, specular_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;

varying flat float tile;
varying float fade;
varying vec4 tint;

void vertex() {
	tile = INSTANCE_CUSTOM.r;
	fade = INSTANCE_CUSTOM.g;
	tint = COLOR;
}

void fragment() {
	float t = floor(tile + 0.5);
	vec2 cell = vec2(mod(t, 4.0), floor(t / 4.0));
	// keep half a texel clear of the tile edge so neighbours don't bleed in
	vec2 uv = clamp(UV, vec2(0.004), vec2(0.996));
	vec4 c = texture(atlas, (cell + uv) * 0.25);
	ALBEDO = c.rgb * tint.rgb;
	ALPHA = c.a * fade;
	ROUGHNESS = 0.9;
}
