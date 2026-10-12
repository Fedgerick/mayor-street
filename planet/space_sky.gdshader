// Space round the planet, seen from orbit: near-black with a scatter of stars.
shader_type sky;

float h31(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

void sky() {
	vec3 d = EYEDIR;
	vec3 cell = floor(d * 260.0);
	float s = h31(cell);
	float star = step(0.9965, s) * (0.4 + 0.6 * h31(cell + 7.0));
	float band = exp(-pow(d.y * 3.0 + d.x * 0.8, 2.0)) * 0.012;
	COLOR = vec3(0.006, 0.008, 0.02) + vec3(0.06, 0.05, 0.08) * band * 10.0 + vec3(star);
}
