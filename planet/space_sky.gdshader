// Space round the planet, seen from orbit: a field of stars at three brightnesses, a faint
// galaxy band, and the sun with its glow. The sky turns with the sun (PlanetSky), so the
// stars wheel past as the day goes by, like Dyson Sphere Program.
shader_type sky;

uniform vec3 sun_sky = vec3(0.0, 0.0, 1.0);  // toward the sun, in sky space

float h31(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vn3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h31(i), h31(i + vec3(1, 0, 0)), f.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), f.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// Pin-point stars: at most one per cell, a few thousandths of a radian across.
float stars(vec3 d, float scale, float keep, float size) {
	vec3 cell = floor(d * scale);
	float s = h31(cell);
	if (s < keep) {
		return 0.0;
	}
	vec3 c = normalize((cell + 0.5 + (vec3(h31(cell + 3.1), h31(cell + 5.7), h31(cell + 9.3)) - 0.5) * 0.7) / scale);
	float r = length(d - c);
	return smoothstep(size, 0.0, r) * (0.35 + 0.65 * h31(cell + 7.0));
}

void sky() {
	vec3 d = EYEDIR;
	// Galaxy band: a tilted great circle, blotchy.
	float g = dot(d, normalize(vec3(0.35, 0.82, 0.45)));
	float band = exp(-g * g * 14.0) * (0.35 + 0.65 * vn3(d * 9.0)) * (0.6 + 0.4 * vn3(d * 23.0));
	vec3 col = vec3(0.003, 0.004, 0.012) + vec3(0.035, 0.03, 0.055) * band;
	float st = stars(d, 220.0, 0.975, 0.0016) * 0.7 + stars(d, 90.0, 0.985, 0.0022) * 1.3
		+ stars(d, 40.0, 0.99, 0.0032) * 2.5 + stars(d * 1.7, 300.0, 0.95, 0.0012) * band * 1.5;
	vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.9, 0.75), h31(floor(d * 300.0) + 2.0));
	col += st * tint;
	// The sun: a white-hot disc, a warm glow round it, and a wide faint halo.
	float sd = max(dot(d, normalize(sun_sky)), 0.0);
	col += vec3(1.0, 0.96, 0.88) * smoothstep(0.99955, 0.99975, sd) * 30.0;
	col += vec3(1.0, 0.75, 0.45) * pow(sd, 900.0) * 3.0;
	col += vec3(1.0, 0.7, 0.4) * pow(sd, 60.0) * 0.08;
	COLOR = col;
}
