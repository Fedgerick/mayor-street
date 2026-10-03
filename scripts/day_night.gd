class_name DayNight
extends Node3D
## Sun, moon, sky and post-processing driven by the city clock.

const SKY_SHADER := preload("res://shaders/sky.gdshader")

var env: Environment
var sky_mat: ShaderMaterial
var light: DirectionalLight3D
var world_env: WorldEnvironment

# Keyframes over the day: hour -> [sky top, horizon, light colour, light energy, ambient energy]
const KEYS := [
	[0.0, Color(0.01, 0.02, 0.06), Color(0.05, 0.08, 0.16), Color(0.55, 0.65, 1.0), 0.18, 0.12],
	[4.8, Color(0.02, 0.03, 0.08), Color(0.08, 0.1, 0.2), Color(0.55, 0.65, 1.0), 0.16, 0.12],
	[6.0, Color(0.2, 0.3, 0.55), Color(0.95, 0.6, 0.45), Color(1.0, 0.6, 0.35), 0.9, 0.3],
	[7.5, Color(0.2, 0.42, 0.8), Color(0.72, 0.8, 0.9), Color(1.0, 0.86, 0.7), 1.7, 0.35],
	[12.0, Color(0.16, 0.38, 0.82), Color(0.62, 0.76, 0.92), Color(1.0, 0.97, 0.92), 2.0, 0.38],
	[17.0, Color(0.18, 0.38, 0.78), Color(0.75, 0.76, 0.82), Color(1.0, 0.85, 0.65), 1.8, 0.35],
	[18.8, Color(0.25, 0.28, 0.5), Color(1.0, 0.52, 0.3), Color(1.0, 0.5, 0.25), 1.0, 0.3],
	[20.0, Color(0.05, 0.07, 0.18), Color(0.25, 0.2, 0.3), Color(0.55, 0.65, 1.0), 0.2, 0.14],
	[24.0, Color(0.01, 0.02, 0.06), Color(0.05, 0.08, 0.16), Color(0.55, 0.65, 1.0), 0.18, 0.12],
]


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
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 2.6
	env.ssao_power = 1.6
	env.ssao_detail = 0.3
	env.ssao_light_affect = 0.15
	env.glow_enabled = true
	env.glow_normalized = false
	env.glow_intensity = 0.7
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.set_glow_level(0, 0.0)
	env.set_glow_level(1, 1.0)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 0.6)
	env.set_glow_level(4, 0.3)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.0006
	env.fog_aerial_perspective = 0.15
	env.fog_sky_affect = 0.25
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.18
	env.adjustment_contrast = 1.06
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	light = DirectionalLight3D.new()
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	light.directional_shadow_max_distance = 400.0
	light.directional_shadow_blend_splits = true
	light.shadow_blur = 1.2
	light.shadow_bias = 0.04
	light.shadow_normal_bias = 1.2
	light.light_angular_distance = 0.6
	add_child(light)


func _sample(hour: float) -> Array:
	for k in KEYS.size() - 1:
		var a: Array = KEYS[k]
		var b: Array = KEYS[k + 1]
		if hour >= a[0] and hour <= b[0]:
			var t: float = (hour - a[0]) / (b[0] - a[0])
			t = t * t * (3.0 - 2.0 * t)
			return [a[1].lerp(b[1], t), a[2].lerp(b[2], t), a[3].lerp(b[3], t), lerpf(a[4], b[4], t), lerpf(a[5], b[5], t)]
	return [KEYS[0][1], KEYS[0][2], KEYS[0][3], KEYS[0][4], KEYS[0][5]]


func update_time(hour: float) -> void:
	var k := _sample(hour)
	# Sun arc: rises 6:00 in the east (+X), sets 19:00 in the west, tilted south.
	var day_t := (hour - 6.0) / 13.0
	var sun_up := day_t >= 0.0 and day_t <= 1.0
	var elev := sin(clampf(day_t, 0.0, 1.0) * PI)
	var night := 1.0 - smoothstep(-0.02, 0.22, elev if sun_up else -1.0)
	var dir: Vector3
	if night < 0.5:
		var az := lerpf(-1.25, 1.25, clampf(day_t, 0.0, 1.0))
		dir = Vector3(-sin(az) * cos(asin(maxf(elev, 0.08))), -maxf(elev, 0.08), -cos(az) * 0.55).normalized()
	else:
		# Moon: a high arc through the night.
		var nt := fposmod(hour - 19.0, 24.0) / 11.0
		var az := lerpf(-1.0, 1.0, clampf(nt, 0.0, 1.0))
		dir = Vector3(-sin(az) * 0.5, -0.75, 0.45).normalized()
	light.basis = Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	light.light_color = k[2]
	light.light_energy = k[3]
	env.ambient_light_energy = k[4]
	env.ambient_light_sky_contribution = 1.0
	sky_mat.set_shader_parameter("top_color", Vector3(k[0].r, k[0].g, k[0].b))
	sky_mat.set_shader_parameter("horizon_color", Vector3(k[1].r, k[1].g, k[1].b))
	var sunset := clampf(1.0 - absf(hour - 18.9) / 1.4, 0.0, 1.0) + clampf(1.0 - absf(hour - 6.0) / 1.2, 0.0, 1.0)
	sky_mat.set_shader_parameter("sunset", sunset)
	sky_mat.set_shader_parameter("night", night)
	env.fog_light_color = k[1].lerp(k[0], 0.3)
	env.glow_intensity = lerpf(0.25, 0.9, night)
	env.tonemap_exposure = lerpf(0.9, 1.3, night)
	RenderingServer.global_shader_parameter_set("night", night)
	RenderingServer.global_shader_parameter_set("sun_dir", -dir)
	# Fraction of lit windows over the day.
	var lit := 0.12
	if hour >= 17.0 and hour < 23.0:
		lit = lerpf(0.25, 0.42, smoothstep(17.0, 20.0, hour))
	elif hour >= 23.0 or hour < 5.0:
		lit = 0.22
	elif hour >= 5.0 and hour < 8.0:
		lit = lerpf(0.5, 0.15, smoothstep(5.0, 8.0, hour))
	RenderingServer.global_shader_parameter_set("window_lit", lit)


func set_view_distance(dist: float) -> void:
	light.directional_shadow_max_distance = clampf(dist * 2.4, 140.0, 1300.0)
	env.fog_density = clampf(0.09 / (dist + 300.0), 0.00008, 0.0004)


func apply_quality(level: int) -> void:
	## 0 low, 1 medium, 2 high.
	var vp := get_viewport()
	env.ssao_enabled = level >= 1
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if level == 0 else (
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if level == 1 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
	RenderingServer.directional_shadow_atlas_set_size(2048 if level == 0 else 4096, true)
	RenderingServer.environment_set_ssao_quality(
		RenderingServer.ENV_SSAO_QUALITY_LOW if level < 2 else RenderingServer.ENV_SSAO_QUALITY_MEDIUM, level < 2, 0.5, 2, 50, 300)
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = [0.67, 0.8, 1.0][level]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	vp.mesh_lod_threshold = [4.0, 2.0, 1.0][level]
