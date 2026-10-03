// Stylized sky: deep zenith to hazy horizon, warm dusk band and glow around the sun, lit
// puffy clouds (computed at quarter resolution), stars, moon and the city's glow at night.
// Colours come from DayNight, keyed on the sun's elevation.
shader_type sky;
render_mode use_quarter_res_pass;

uniform vec3 zenith : source_color = vec3(0.08, 0.28, 0.75);
uniform vec3 horizon : source_color = vec3(0.5, 0.68, 0.9);
uniform vec3 dusk : source_color = vec3(1.0, 0.5, 0.25);    // horizon tint toward the sun
uniform vec3 ground : source_color = vec3(0.2, 0.2, 0.19);  // below the horizon (bounce light)
uniform vec3 sun_light = vec3(2.5, 2.3, 2.1);                // sun colour x energy, lights clouds
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);                  // toward the sun (even below the horizon)
uniform vec3 moon_dir = vec3(0.0, 1.0, 0.0);
uniform float sunset = 0.0;       // strength of the dawn/dusk colours
uniform float night = 0.0;
uniform float cloud_cover = 0.42;
uniform float pollution = 0.0;    // orange city glow low on the night sky
uniform int detail = 1;           // graphics level: 0 low, 1 medium, 2 high

float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float h31(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float n2(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y);
}

float fbm(vec2 p, int oct) {
	float s = 0.0, a = 0.5;
	for (int i = 0; i < oct; i++) { s += n2(p) * a; p = p * 2.03 + vec2(17.1, 3.7); a *= 0.5; }
	return s;
}

vec3 atmosphere(vec3 d) {
	float h = max(d.y, 0.0);
	vec3 col = mix(horizon, zenith, pow(h, 0.5));
	// Haze band hugging the horizon.
	col = mix(col, horizon * 1.06, exp(-h * 22.0) * 0.5);
	// Dawn and dusk: warm toward the sun's side of the horizon, cooler and pinker away from it.
	vec2 dh = normalize(d.xz + vec2(1e-5));
	vec2 sh = normalize(sun_dir.xz + vec2(1e-5));
	float side = 0.5 + 0.5 * dot(dh, sh);
	float band = exp(-h * 5.0) * sunset;
	col = mix(col, dusk, clamp(band * (0.25 + 0.75 * side * side * side), 0.0, 1.0));
	col = mix(col, col * vec3(1.0, 0.82, 1.05), band * (1.0 - side) * 0.5);
	// Glow around the sun.
	float sd = max(dot(d, sun_dir), 0.0);
	float day = 1.0 - night;
	col += dusk * pow(sd, 6.0) * (0.12 + 0.9 * sunset) * day;
	col += sun_light * pow(sd, 90.0) * 0.12 * day;
	// The city lights up the low sky at night.
	col += vec3(1.0, 0.5, 0.25) * pollution * exp(-h * 7.0) * 0.045;
	// Below the horizon: ground bounce, seen in reflections and used for ambient light.
	return mix(col, ground, smoothstep(0.0, -0.1, d.y));
}

vec4 clouds(vec3 d, int oct) {
	if (d.y < 0.005) {
		return vec4(0.0);
	}
	// A cloud deck ~2 km up, drifting slowly.
	vec2 p = d.xz / (d.y + 0.06) * 1.1 + vec2(TIME * 0.0035, TIME * 0.0015);
	vec2 w = vec2(fbm(p * 0.5, 3), fbm(p * 0.5 + vec2(5.2, 1.3), 3));
	float shape = fbm(p * 0.75 + w * 1.4, oct);
	float lo = 1.0 - cloud_cover;
	float cov = smoothstep(lo - 0.04, lo + 0.22, shape);
	if (cov <= 0.001) {
		return vec4(0.0);
	}
	// Self-shadowing: compare with the density a little way toward the sun.
	vec2 toward = normalize(sun_dir.xz + vec2(1e-4)) * 0.18;
	float ahead = fbm((p + toward) * 0.75 + w * 1.4, oct);
	float lit = clamp(0.62 + (shape - ahead) * 4.0, 0.0, 1.0);
	lit *= smoothstep(-0.25, 0.1, sun_dir.y);
	float edge = 1.0 - smoothstep(lo, lo + 0.3, shape);  // thin edges catch more light
	vec3 amb = mix(horizon, zenith, 0.4) * 0.85 + ground * 0.25;
	vec3 sun_c = sun_light * (0.42 + 0.18 * edge);
	vec3 col = amb + sun_c * lit;
	// Silver lining toward the sun.
	float sd = max(dot(d, sun_dir), 0.0);
	col += sun_light * pow(sd, 10.0) * edge * 0.5;
	// Night: moonlit tops, city glow underneath near the horizon.
	col = mix(col, amb * 1.6 + vec3(0.04, 0.035, 0.045), night);
	col += vec3(1.0, 0.5, 0.25) * pollution * exp(-d.y * 6.0) * 0.06;
	return vec4(col, cov * smoothstep(0.005, 0.14, d.y));
}

void sky() {
	vec3 d = EYEDIR;
	if (AT_QUARTER_RES_PASS) {
		vec4 c = clouds(d, detail >= 2 ? 6 : 5);
		COLOR = c.rgb;
		ALPHA = c.a;
	} else {
		vec3 col = atmosphere(d);
		vec4 cl = AT_CUBEMAP_PASS ? clouds(d, 3) : QUARTER_RES_COLOR;
		if (!AT_CUBEMAP_PASS && d.y > 0.0) {
			// Stars, hidden behind clouds.
			vec3 sp = d * 260.0;
			vec3 cell = floor(sp);
			float hs = h31(cell);
			if (hs > 0.9965) {
				vec3 f = fract(sp) - 0.5;
				float tw = 0.65 + 0.35 * sin(TIME * (1.5 + hs * 3.0) + hs * 80.0);
				float st = smoothstep(0.3, 0.0, length(f)) * tw * (hs - 0.9965) / 0.0035;
				col += vec3(0.8, 0.88, 1.0) * st * 2.2 * night * smoothstep(0.0, 0.2, d.y) * (1.0 - cl.a);
			}
			// Moon.
			float md = dot(d, moon_dir);
			if (md > 0.999) {
				vec3 mt = normalize(cross(moon_dir, vec3(0.0, 1.0, 0.0)) + vec3(1e-4));
				vec3 mb = cross(mt, moon_dir);
				vec2 mp = vec2(dot(d, mt), dot(d, mb)) / 0.026;
				float disc = 1.0 - smoothstep(0.92, 1.0, length(mp));
				float mare = 0.82 + 0.18 * smoothstep(0.35, 0.7, n2(mp * 3.0 + 7.0));
				col = mix(col, vec3(1.3, 1.32, 1.38) * mare, disc * night * (1.0 - cl.a * 0.85));
			}
			col += vec3(0.6, 0.7, 1.0) * pow(max(md, 0.0), 500.0) * 0.6 * night;
			// Sun disc (kept out of reflections: the light adds its own highlight).
			float sd = dot(d, sun_dir);
			float disc = smoothstep(0.99982, 0.99988, sd);
			col += sun_light * 14.0 * disc * (1.0 - night) * (1.0 - cl.a);
		}
		COLOR = mix(col, cl.rgb, cl.a);
	}
}
