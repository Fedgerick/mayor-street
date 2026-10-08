class_name DayNight
extends Node3D
## Sun, moon, sky, fog and post-processing, driven by the city clock and the graphics level.

const SKY_SHADER := preload("res://shaders/sky.gdshader")
const VIGNETTE_SHADER := preload("res://shaders/vignette.gdshader")

# The sun rises at 6:00, sets at 19:00 and peaks at SUN_MAX_ELEV degrees. Its noon bearing
# (degrees clockwise from north, -Z) side-lights the default mayor view, and it sets behind it.
const SUNRISE := 6.0
const SUNSET := 19.0
const SUN_MAX_ELEV := 55.0
const SUN_NOON_BEARING := 125.0
const SUN_SWEEP := 110.0

# Sun elevation (degrees) -> [sunlight colour, energy]
const SUN_KEYS := [
	[-4.5, Color(1.0, 0.32, 0.1), 0.0],
	[0.0, Color(1.0, 0.4, 0.16), 0.45],
	[4.0, Color(1.0, 0.52, 0.27), 1.2],
	[10.0, Color(1.0, 0.68, 0.45), 1.9],
	[20.0, Color(1.0, 0.82, 0.64), 2.4],
	[35.0, Color(1.0, 0.9, 0.77), 2.7],
	[60.0, Color(1.0, 0.93, 0.84), 2.8],
]
# Sun elevation -> [zenith, horizon, dusk tint, ambient energy, exposure]
const SKY_KEYS := [
	[-20.0, Color(0.006, 0.009, 0.022), Color(0.022, 0.026, 0.045), Color(0.05, 0.04, 0.07), 1.8, 1.55],
	[-9.0, Color(0.009, 0.015, 0.038), Color(0.04, 0.043, 0.08), Color(0.12, 0.07, 0.11), 1.8, 1.45],
	[-4.0, Color(0.02, 0.035, 0.1), Color(0.15, 0.11, 0.16), Color(0.55, 0.2, 0.14), 1.6, 1.1],
	[0.0, Color(0.05, 0.09, 0.22), Color(0.48, 0.34, 0.3), Color(1.0, 0.4, 0.15), 1.3, 0.85],
	[5.0, Color(0.08, 0.17, 0.4), Color(0.7, 0.58, 0.5), Color(1.0, 0.52, 0.24), 1.1, 0.68],
	[14.0, Color(0.08, 0.24, 0.6), Color(0.6, 0.68, 0.8), Color(1.0, 0.72, 0.48), 1.0, 0.6],
	[30.0, Color(0.07, 0.27, 0.72), Color(0.5, 0.68, 0.9), Color(1.0, 0.84, 0.68), 1.0, 0.56],
	[60.0, Color(0.06, 0.26, 0.74), Color(0.48, 0.67, 0.9), Color(1.0, 0.86, 0.72), 1.0, 0.55],
]
const MOON_COLOR := Color(0.62, 0.7, 0.95)
const MOON_ENERGY := 0.16

var env: Environment
var sky_mat: ShaderMaterial
var light: DirectionalLight3D
var world_env: WorldEnvironment
var vignette: ColorRect
var quality := 1
# Street level turns both up: down in a street canyon most of the view is shade, lit by
# light bounced off the sunlit walls across the street.
var exposure_scale := 1.0
var ambient_scale := 1.0
## weather/ Weather (cloud, rain, fog, each 0..1): grey skies, a weaker sun with softer
## shadows, thicker fog. Null keeps the sky to the day-to-day cloud cover.
var weather: Object
var _glow_night := 0.22
var _fog_base := 0.0003


func _ready() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.45
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.ssao_radius = 1.2
	env.ssao_intensity = 2.0
	env.ssao_power = 1.5
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.2
	env.ssil_radius = 5.0
	env.ssil_intensity = 1.0
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0
	env.ssr_max_steps = 48
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.6
	# Bloom mixed in before tonemapping, so it doesn't wash out the dark parts of the frame.
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_MIX
	env.glow_normalized = true
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 0.95
	env.glow_hdr_scale = 2.5
	for i in 7:
		env.set_glow_level(i, [0.0, 0.6, 1.0, 1.0, 0.7, 0.4, 0.0][i])
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_aerial_perspective = 0.5
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_color_correction = _make_grade_lut()
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	light = DirectionalLight3D.new()
	light.shadow_enabled = true
	light.directional_shadow_blend_splits = true
	light.shadow_blur = 1.0
	light.shadow_bias = 0.04
	light.shadow_normal_bias = 1.2
	add_child(light)

	var layer := CanvasLayer.new()
	layer.layer = -1  # under every HUD
	add_child(layer)
	vignette = ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vm := ShaderMaterial.new()
	vm.shader = VIGNETTE_SHADER
	vignette.material = vm
	layer.add_child(vignette)


# ------------------------------------------------------------------- clock ---

static func _keyed(keys: Array, x: float) -> Array:
	## Smoothly interpolates the rows of a key table (first column is the key).
	if x <= keys[0][0]:
		return keys[0].slice(1)
	for k in keys.size() - 1:
		var a: Array = keys[k]
		var b: Array = keys[k + 1]
		if x <= b[0]:
			var t: float = (x - a[0]) / (b[0] - a[0])
			t = t * t * (3.0 - 2.0 * t)
			var out := []
			for i in range(1, a.size()):
				if a[i] is Color:
					out.append((a[i] as Color).lerp(b[i], t))
				else:
					out.append(lerpf(a[i], b[i], t))
			return out
	return keys[keys.size() - 1].slice(1)


static func sun_position(hour: float) -> Vector3:
	## Unit vector toward the sun; below the horizon at night.
	var t := (hour - SUNRISE) / (SUNSET - SUNRISE)
	if t > 1.5:
		t -= 24.0 / (SUNSET - SUNRISE)
	var elev := deg_to_rad(SUN_MAX_ELEV * sin(t * PI))
	var bearing := deg_to_rad(SUN_NOON_BEARING + (t - 0.5) * 2.0 * SUN_SWEEP)
	return Vector3(sin(bearing) * cos(elev), sin(elev), -cos(bearing) * cos(elev))


func update_time(hour: float, day := 0) -> void:
	var sun := sun_position(hour)
	var elev := rad_to_deg(asin(sun.y))
	var s := _keyed(SUN_KEYS, elev)
	var k := _keyed(SKY_KEYS, elev)
	var night := 1.0 - smoothstep(-5.0, 9.0, elev)
	var sun_energy: float = s[1]
	var cloud := 0.0
	var fog := 0.0
	var rain := 0.0
	if weather:
		cloud = clampf(weather.cloud, 0.0, 1.0)
		fog = clampf(weather.fog, 0.0, 1.0)
		rain = clampf(weather.rain, 0.0, 1.0)
	var overcast := smoothstep(0.1, 0.9, maxf(cloud, fog * 0.8))  # a clear day's 0.08 stays clear
	sun_energy *= 1.0 - 0.62 * overcast
	var moon_k := smoothstep(-4.5, -10.0, elev)
	# The moon trails the sun by half a day, at a fixed height.
	var moon := Vector3(-sun.x, 0.0, -sun.z)
	moon = (moon.normalized() * cos(deg_to_rad(38.0)) + Vector3.UP * sin(deg_to_rad(38.0))) if moon.length() > 0.01 else Vector3.UP
	var to_light := sun
	if sun_energy > 0.0:
		# Keep a minimum height so dawn light doesn't graze the ground forever.
		var flat := Vector3(sun.x, 0.0, sun.z).normalized()
		var e := deg_to_rad(maxf(elev, 4.0))
		to_light = flat * cos(e) + Vector3.UP * sin(e)
		light.light_color = (s[0] as Color).lerp(Color(0.9, 0.93, 1.0), overcast * 0.6)
		light.light_energy = sun_energy
	else:
		to_light = moon
		light.light_color = MOON_COLOR
		light.light_energy = MOON_ENERGY * moon_k
	light.visible = light.light_energy > 0.001
	light.shadow_opacity = 1.0 - 0.6 * overcast  # overcast light comes from the whole sky
	light.basis = Basis.looking_at(-to_light, Vector3.UP)

	var zenith: Color = k[0]
	var horizon: Color = k[1]
	var dusk: Color = k[2]
	if overcast > 0.0:
		# Grey the sky toward its own brightness, a little darker under rain clouds.
		var dim := 1.0 - 0.25 * rain
		zenith = zenith.lerp(Color.WHITE * (zenith.get_luminance() * 1.15 * dim), overcast * 0.8)
		horizon = horizon.lerp(Color.WHITE * (horizon.get_luminance() * dim), overcast * 0.75)
		dusk = dusk.lerp(horizon, overcast * 0.7)
	var sunset := clampf(1.0 - absf(elev - 1.0) / 13.0, 0.0, 1.0)
	sunset = sunset * sunset * (3.0 - 2.0 * sunset)
	sky_mat.set_shader_parameter("zenith", _v3(zenith))
	sky_mat.set_shader_parameter("horizon", _v3(horizon))
	sky_mat.set_shader_parameter("dusk", _v3(dusk))
	var ground := horizon.lerp(Color(0.36, 0.35, 0.32), 0.5) * (0.35 + 0.1 * sun_energy)
	sky_mat.set_shader_parameter("ground", _v3(ground))
	sky_mat.set_shader_parameter("sun_light", _v3(s[0]) * sun_energy * 0.55)
	sky_mat.set_shader_parameter("sun_dir", sun)
	sky_mat.set_shader_parameter("moon_dir", moon)
	sky_mat.set_shader_parameter("sunset", sunset)
	sky_mat.set_shader_parameter("night", night)
	sky_mat.set_shader_parameter("pollution", night)
	# Some days are clearer than others; blend across midnight so the sky never jumps.
	var cover := lerpf(_cloud_cover(day), _cloud_cover(day + 1), hour / 24.0)
	sky_mat.set_shader_parameter("cloud_cover", lerpf(cover, 0.95, overcast))

	env.ambient_light_energy = k[3] * ambient_scale * (1.0 + 0.3 * overcast)
	# Over half the ambient is a neutral, warm version of the sky (light bounced off the
	# sunlit city), so shade reads blue-grey rather than saturated blue.
	var grey := horizon.get_luminance() * 0.6 + zenith.get_luminance() * 0.4
	env.ambient_light_color = Color(grey * 1.1, grey, grey * 0.85)
	var glow := lerpf(0.05, _glow_night, night) if env.glow_enabled else 0.0
	env.glow_intensity = glow
	env.tonemap_exposure = k[4] / (1.0 - glow) * exposure_scale
	env.fog_light_color = horizon.lerp(dusk, sunset * 0.35)
	env.fog_density = _fog_base * (1.0 + 9.0 * fog + 1.5 * rain)
	env.fog_sun_scatter = 0.06 + 0.2 * sunset
	RenderingServer.global_shader_parameter_set("night", night)
	RenderingServer.global_shader_parameter_set("sun_dir", to_light)
	# Fraction of lit windows over the day.
	var lit := 0.12
	if hour >= 17.0 and hour < 23.0:
		lit = lerpf(0.25, 0.42, smoothstep(17.0, 20.0, hour))
	elif hour >= 23.0 or hour < 5.0:
		lit = 0.22
	elif hour >= 5.0 and hour < 8.0:
		lit = lerpf(0.5, 0.15, smoothstep(5.0, 8.0, hour))
	RenderingServer.global_shader_parameter_set("window_lit", lit)


static func _cloud_cover(day: int) -> float:
	var h := fposmod(sin(float(day) * 12.9898) * 43758.5453, 1.0)
	return lerpf(0.3, 0.52, h)


static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


func set_view_distance(dist: float) -> void:
	# High over the island the shadow maps would hold every building; Low and Med stop sooner.
	light.directional_shadow_max_distance = clampf(dist * 2.4, 140.0, [450.0, 800.0, 1300.0][clampi(quality, 0, 2)])
	_fog_base = clampf(0.11 / (dist + 300.0), 0.0001, 0.00045)
	env.fog_density = _fog_base


# ---------------------------------------------------------------- grading ---

func _make_grade_lut() -> ImageTexture3D:
	## The final colour grade as a 3D LUT: a gentle S-curve, vibrance, cool shadows and
	## warm highlights. Applied by the tonemapper, so it costs nothing per frame.
	const N := 32
	var slices: Array[Image] = []
	for b in N:
		var data := PackedByteArray()
		data.resize(N * N * 3)
		var i := 0
		for g in N:
			for r in N:
				var c := _grade(Vector3(r, g, b) / float(N - 1))
				data[i] = clampi(roundi(c.x * 255.0), 0, 255)
				data[i + 1] = clampi(roundi(c.y * 255.0), 0, 255)
				data[i + 2] = clampi(roundi(c.z * 255.0), 0, 255)
				i += 3
		slices.append(Image.create_from_data(N, N, false, Image.FORMAT_RGB8, data))
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGB8, N, N, N, false, slices)
	return tex


static func _grade(c: Vector3) -> Vector3:
	## One colour through the grade (display-referred sRGB in, sRGB out).
	var luma := c.dot(Vector3(0.2126, 0.7152, 0.0722))
	var grey := Vector3(luma, luma, luma)
	var sat := maxf(c.x, maxf(c.y, c.z)) - minf(c.x, minf(c.y, c.z))
	c = grey + (c - grey) * (1.0 + 0.3 * (1.0 - sat))
	var shadows := 4.0 * luma * (1.0 - luma) * (1.0 - luma)
	c += Vector3(-0.018, 0.0, 0.03) * shadows + Vector3(0.03, 0.012, -0.025) * luma * luma
	c = c.clamp(Vector3.ZERO, Vector3.ONE)
	var curve := c * c * (Vector3(3.0, 3.0, 3.0) - 2.0 * c)
	return c.lerp(curve, 0.2)


# ---------------------------------------------------------------- quality ---

func apply_quality(level: int) -> void:
	## 0 low, 1 medium, 2 high.
	quality = level
	var vp := get_viewport()
	env.ssao_enabled = level >= 1
	env.ssil_enabled = level >= 2
	# The city reflected in the sea and in glass towers.
	env.ssr_enabled = level >= 2
	env.glow_enabled = level >= 1
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if level == 0 else (
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if level == 1 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
	# Soft contact-hardening shadows only on High.
	light.light_angular_distance = 0.5 if level >= 2 else 0.0
	RenderingServer.directional_shadow_atlas_set_size(2048 if level == 0 else 4096, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		[RenderingServer.SHADOW_QUALITY_HARD, RenderingServer.SHADOW_QUALITY_SOFT_LOW, RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM][level])
	RenderingServer.environment_set_ssao_quality(
		RenderingServer.ENV_SSAO_QUALITY_LOW if level < 2 else RenderingServer.ENV_SSAO_QUALITY_MEDIUM, level < 2, 0.5, 2, 50, 300)
	RenderingServer.environment_set_ssil_quality(RenderingServer.ENV_SSIL_QUALITY_LOW, true, 0.5, 2, 50, 300)
	sky_mat.set_shader_parameter("detail", level)
	vignette.visible = level >= 1
	RenderingServer.global_shader_parameter_set("gfx_quality", level)
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = [0.67, 0.8, 1.0][level]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA if level >= 2 else Viewport.SCREEN_SPACE_AA_FXAA
	vp.mesh_lod_threshold = [4.0, 2.0, 1.0][level]
