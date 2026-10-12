// Stylized sea over the island's height field: light filters down to a sandy bottom with
// caustics in the shallows and fades to deep blue offshore, surf rolls in at the shore, and
// the surface reflects more sky at grazing angles, with a sun glitter path far out.
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable; // R = terrain height / -16
uniform vec4 height_rect;   // xy origin, zw size (world XZ)
uniform sampler2D wave_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wave_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 deep : source_color = vec3(0.02, 0.17, 0.32);  // open water: no light comes back from the bottom
uniform vec3 absorb = vec3(0.9, 0.2, 0.14);                   // per metre of depth, down and back up
uniform vec3 bed : source_color = vec3(0.7, 0.68, 0.58);     // pale sand on the bottom

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float floor_height(vec2 xz) {
	vec2 huv = (xz - height_rect.xy) / height_rect.zw;
	if (huv.x > 0.0 && huv.y > 0.0 && huv.x < 1.0 && huv.y < 1.0) {
		return texture(height_tex, huv).r * -16.0;
	}
	return -16.0;
}

float caustics(vec2 p, float t) {
	// A bright web where two drifting noise fields cross.
	float a = vnoise(p + vec2(t * 0.35, t * 0.21));
	float b = vnoise(p * 1.13 + vec2(-t * 0.27, t * 0.31) + 17.0);
	return pow(1.0 - abs(a - b), 10.0);
}

void fragment() {
	vec3 mpos = map_pos(wpos);  // flat map metres (planet/ unwraps the ball)
	float t = TIME;
	float far_k = smoothstep(60.0, 900.0, length(CAMERA_POSITION_WORLD - wpos));
	vec3 na = texture(wave_a, mpos.xz * 0.018 + vec2(t * 0.012, t * 0.007)).rgb;
	vec3 nb = texture(wave_b, mpos.xz * 0.041 - vec2(t * 0.009, -t * 0.014)).rgb;
	vec3 nm = mix(na, nb, 0.5);
	if (gfx_quality > 0) {
		// Small ripples near the camera catch the sun.
		vec3 nc = texture(wave_b, mpos.xz * 0.19 + vec2(t * 0.03, t * 0.021)).rgb;
		nm = mix(nm, nc, 0.4 * (1.0 - far_k));
	}

	float depth = max(mpos.y - floor_height(mpos.xz), 0.0);
	float day = 1.0 - night;

	// The bottom, seen through the water and bent a little by the waves.
	vec2 bp = mpos.xz + (nm.xy - 0.5) * min(depth, 4.0) * 0.5;
	vec2 fw = fwidth(bp);
	float px = max(fw.x, fw.y);  // metres per pixel
	vec3 sand = bed * (0.86 + 0.22 * vnoise(bp * 0.45));
	sand *= 1.0 - 0.08 * clamp(1.0 - px * 1.5, 0.0, 1.0)
			* smoothstep(0.3, 1.0, sin(dot(bp, vec2(2.3, 3.1)) + vnoise(bp * 0.3) * 6.0));
	if (gfx_quality > 0) {
		float c = caustics(bp * 0.85, t) + caustics(bp * 1.7 + 9.0, t * 1.3) * 0.5;
		sand += vec3(0.85, 0.95, 1.0) * c * 0.55 * day * clamp(1.0 - px * 3.0, 0.0, 1.0)
				* (1.0 - smoothstep(0.5, 5.0, depth));
	}
	vec3 tr = exp(-absorb * depth);
	vec3 col = sand * tr + deep * (1.0 - tr);

	// Surf: foam at the water's edge and lines of breaking waves rolling in.
	float n = fbm(mpos.xz * 0.35 + vec2(t * 0.15, t * 0.1));
	float shore = 1.0 - smoothstep(0.0, 0.25 + n * 0.35, depth);
	float wave = smoothstep(0.8, 0.97, sin(depth * 4.0 - t * 1.4 + n * 4.0)) * (1.0 - smoothstep(0.2, 1.8, depth));
	vec2 fp = mpos.xz * 1.5 + vec2(t * 0.35, -t * 0.25);
	float bubbles = mix(0.55, vnoise(fp) * 0.6 + vnoise(fp * 2.7) * 0.4, clamp(1.0 - px * 2.0, 0.0, 1.0));
	float foam = clamp(shore + wave * 0.85, 0.0, 1.0) * smoothstep(0.3, 0.62, bubbles + shore * 0.35 + n * 0.2);
	col = mix(col, vec3(0.92, 0.96, 1.0), foam);
	col *= mix(1.0, 0.35, night);

	// At grazing angles the surface mostly reflects the sky.
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = col * (1.0 - fres * 0.75 * (1.0 - foam));
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = mix(0.65, 0.22, far_k) * (1.0 - foam * 0.7);
	// Far out the waves are too small to see: a rougher surface spreads the sun into a glitter path.
	ROUGHNESS = mix(mix(0.03, 0.13, far_k), 0.6, foam);
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
