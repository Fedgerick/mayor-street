// Shared by hero_skin.gdshader and hero_cloth.gdshader: the player's close-up materials.
// HeroLook (characters/scripts/hero_look.gd) bakes each vertex's rest-pose position into
// UV (x, y) and UV2.x (z), and its rest normal into COLOR, so painted detail sticks to the
// body while the skeleton moves it. Detail is a height in metres turned into a normal
// with screen-space derivatives (no tangents or textures needed), and fades out when a
// pattern gets finer than a few pixels, so it never shimmers.

uniform vec4 albedo : source_color = vec4(0.8, 0.8, 0.8, 1.0);
uniform vec4 accent : source_color = vec4(0.3, 0.18, 0.08, 1.0);
uniform float rough = 0.7;
uniform int kind = 0;
uniform float detail = 1.0;   // 0 turns the painted detail off (Low graphics)

varying vec3 rest_pos;
varying vec3 rest_nrm;

void vertex() {
	rest_pos = vec3(UV.x, UV.y, UV2.x);
	rest_nrm = COLOR.rgb * 2.0 - 1.0;
}

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
			mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
			mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.03) * 0.3 + vnoise(p * 4.1) * 0.15;
}

// 1 while a pattern with this period (metres) spans several pixels, 0 once it would alias.
float keep(float period, float px) {
	return clamp((period / max(px, 1e-6) - 2.0) / 3.0, 0.0, 1.0);
}

// Perturb a view-space normal by a height field (Mikkelsen's surface gradient).
vec3 bumped(vec3 n, vec3 pos, float h) {
	vec3 dpdx = dFdx(pos);
	vec3 dpdy = dFdy(pos);
	vec3 r1 = cross(dpdy, n);
	vec3 r2 = cross(n, dpdx);
	float det = dot(dpdx, r1);
	vec3 g = sign(det) * (dFdx(h) * r1 + dFdy(h) * r2);
	return normalize(abs(det) * n - g);
}

// Stitches: a dashed line where `d` (distance from the seam, metres) is near zero.
float stitch(float d, float along, float px) {
	float line = 1.0 - smoothstep(0.0006, 0.0012 + px, abs(d));
	float dash = step(0.45, fract(along / 0.004));
	return line * dash * keep(0.004, px);
}
