// Stylized sea: depth colour from the island height field, shore foam, sparkly normals.
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable; // R = terrain height / -16
uniform vec4 height_rect;   // xy origin, zw size (world XZ)
uniform sampler2D wave_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wave_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 shallow : source_color = vec3(0.25, 0.78, 0.72);
uniform vec3 mid : source_color = vec3(0.06, 0.48, 0.6);
uniform vec3 deep : source_color = vec3(0.02, 0.2, 0.36);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 huv = (wpos.xz - height_rect.xy) / height_rect.zw;
	float th = -16.0;
	if (huv.x > 0.0 && huv.y > 0.0 && huv.x < 1.0 && huv.y < 1.0) {
		th = texture(height_tex, huv).r * -16.0;
	}
	float depth = max(wpos.y - th, 0.0);
	vec3 col = mix(shallow, mid, smoothstep(0.0, 3.0, depth));
	col = mix(col, deep, smoothstep(3.0, 13.0, depth));
	float t = TIME;
	// Foam: a band at the shore plus waves rolling in.
	float n = fbm(wpos.xz * 0.35 + vec2(t * 0.15, t * 0.1));
	float shore = 1.0 - smoothstep(0.0, 0.35 + n * 0.3, depth);
	float rings = smoothstep(0.75, 0.95, sin(depth * 5.0 - t * 1.6 + n * 3.0)) * (1.0 - smoothstep(0.2, 1.6, depth));
	float foam = clamp(shore + rings * 0.8, 0.0, 1.0) * smoothstep(0.35, 0.55, n + shore * 0.5);
	col = mix(col, vec3(0.95, 0.98, 1.0), foam);
	col *= mix(1.0, 0.35, night);
	ALBEDO = col;
	vec3 na = texture(wave_a, wpos.xz * 0.018 + vec2(t * 0.012, t * 0.007)).rgb;
	vec3 nb = texture(wave_b, wpos.xz * 0.041 - vec2(t * 0.009, -t * 0.014)).rgb;
	NORMAL_MAP = normalize(mix(na, nb, 0.5));
	NORMAL_MAP_DEPTH = 0.55;
	ROUGHNESS = mix(0.04, 0.6, foam);
	METALLIC = 0.0;
	SPECULAR = 0.65;
}
