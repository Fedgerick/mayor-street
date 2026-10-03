// Day/night sky: gradient, sun or moon disc, drifting clouds and stars.
shader_type sky;
render_mode use_quarter_res_pass;

uniform vec3 top_color : source_color = vec3(0.24, 0.48, 0.85);
uniform vec3 horizon_color : source_color = vec3(0.72, 0.84, 0.95);
uniform vec3 sunset_color : source_color = vec3(1.0, 0.55, 0.25);
uniform float sunset = 0.0;
uniform float night = 0.0;
uniform float cloud_cover = 0.45;

float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float n2(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y);
}

float fbm2(vec2 p) {
	float s = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) { s += n2(p) * a; p = p * 2.02 + 17.0; a *= 0.5; }
	return s;
}

void sky() {
	vec3 d = EYEDIR;
	float up = clamp(d.y, -1.0, 1.0);
	vec3 L = LIGHT0_DIRECTION;
	float sd = dot(d, L);
	vec3 hor = horizon_color;
	float glow = pow(max(sd, 0.0), 6.0) * sunset;
	hor = mix(hor, sunset_color, clamp(sunset * 0.55 + glow, 0.0, 1.0));
	vec3 col = mix(hor, top_color, pow(max(up, 0.0), 0.55));
	col += sunset_color * pow(max(sd, 0.0), 24.0) * sunset * 0.8;
	if (up < 0.0) col = mix(hor, hor * 0.55, smoothstep(0.0, -0.3, up));
	if (LIGHT0_ENABLED) {
		float disc = smoothstep(0.9993, 0.9997, sd);
		vec3 dc = night > 0.5 ? vec3(0.9, 0.93, 1.0) * 1.4 : LIGHT0_COLOR * 18.0;
		col += dc * disc;
		col += LIGHT0_COLOR * pow(max(sd, 0.0), 300.0) * (1.0 - night) * 1.5;
	}
	if (!AT_CUBEMAP_PASS && up > 0.0) {
		// Stars.
		vec3 sp = d * 350.0;
		float st = h21(floor(sp.xz + sp.y * 3.1));
		float star = step(0.9965, st) * smoothstep(0.0, 0.25, up);
		col += vec3(star) * night * (0.6 + 0.4 * sin(TIME * 2.0 + st * 100.0));
	}
	if (up > 0.0) {
		// Clouds on a flat layer.
		vec2 cp = d.xz / (up + 0.12) * 1.4 + vec2(TIME * 0.006, TIME * 0.003);
		float c = fbm2(cp);
		float cov = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.28, c);
		float shade = 0.75 + 0.25 * smoothstep(0.3, 0.8, fbm2(cp * 1.7 + 4.0));
		vec3 cc = mix(vec3(1.0, 0.98, 0.95), sunset_color * 1.1, sunset * 0.6) * shade;
		cc = mix(cc, vec3(0.08, 0.1, 0.16), night * 0.92);
		col = mix(col, cc, cov * smoothstep(0.0, 0.18, up) * 0.9);
	}
	COLOR = col;
}
