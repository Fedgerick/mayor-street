class_name RainFX
extends Node3D
## Falling rain and splashes in a box around the street camera: two GPU particle systems,
## two draw calls, scaled by Weather.rain. Off from the mayor view (above MAX_HEIGHT) and
## inside interiors (which sit far above the city), where no rain should fall.

const MAX_HEIGHT := 140.0
const BOX := Vector3(46.0, 24.0, 46.0)  # rain volume around the camera
const DROPS := 5000                     # at full rain on High; set `quality` 0..2
const SPLASHES := 900

var weather: Weather
var camera: Camera3D
var quality := 1                         # 0 low, 1 medium, 2 high

var _drops: GPUParticles3D
var _splash: GPUParticles3D


func setup(w: Weather, cam: Camera3D) -> void:
	weather = w
	camera = cam
	_drops = _make_drops()
	_splash = _make_splashes()
	add_child(_drops)
	add_child(_splash)
	set_quality(quality)


func set_camera(cam: Camera3D) -> void:
	camera = cam


func set_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	var share: float = [0.35, 0.6, 1.0][quality]
	_drops.amount = int(DROPS * share)
	_splash.amount = int(SPLASHES * share)


func _make_drops() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Drops"
	p.lifetime = 1.2
	p.preprocess = 1.2
	p.fixed_fps = 0
	p.local_coords = false
	p.visibility_aabb = AABB(-BOX * 0.5 - Vector3(0, 30, 0), BOX + Vector3(0, 40, 0))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(BOX.x * 0.5, 2.0, BOX.z * 0.5)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 2.0
	pm.initial_velocity_min = 20.0
	pm.initial_velocity_max = 24.0
	pm.gravity = Vector3(0, -6, 0)
	pm.particle_flag_align_y = true
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.018, 0.6)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	m.albedo_color = Color(0.8, 0.84, 0.92, 0.42)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = m
	p.draw_pass_1 = q
	return p


func _make_splashes() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Splashes"
	p.lifetime = 0.25
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-25, -2, -25), Vector3(50, 4, 50))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(18.0, 0.0, 18.0)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.2
	pm.gravity = Vector3(0, -9.8, 0)
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	var curve := CurveTexture.new()
	var c := Curve.new()
	c.add_point(Vector2(0, 0.3))
	c.add_point(Vector2(0.4, 1.0))
	c.add_point(Vector2(1, 0.0))
	curve.curve = c
	pm.scale_curve = curve
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.07, 0.05)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(0.85, 0.88, 0.95, 0.35)
	m.albedo_texture = _soft_dot()  # round, soft-edged splash rather than a grey square
	q.material = m
	p.draw_pass_1 = q
	return p


func _soft_dot() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 32
	t.height = 32
	return t


func _process(_delta: float) -> void:
	if weather == null or camera == null or not camera.is_inside_tree():
		visible = false
		return
	var eye := Planet.flat(camera.global_position)  # flat map metres (y = height above sea)
	var r := weather.rain
	var on := r > 0.02 and eye.y < MAX_HEIGHT and eye.y > -5.0
	visible = on
	_drops.emitting = on
	_splash.emitting = on
	if not on:
		return
	_drops.amount_ratio = r
	_splash.amount_ratio = r
	# Centre the volume a little ahead of the camera, where you look.
	var ahead := Planet.to_local(camera.global_position, -camera.global_basis.z)
	ahead.y = 0.0
	var c := eye + ahead.normalized() * 10.0
	_drops.global_transform = Planet.xf_rigid(Transform3D(Basis.IDENTITY, Vector3(c.x, eye.y + BOX.y * 0.55, c.z)))
	_splash.global_transform = Planet.xf_rigid(Transform3D(Basis.IDENTITY, Vector3(c.x, 0.18, c.z)))
	var pm := _drops.process_material as ParticleProcessMaterial
	if Planet.on:  # gravity is in world space: point it at the ground under the camera
		var down := -_drops.global_basis.y
		pm.gravity = down * 6.0
		(_splash.process_material as ParticleProcessMaterial).gravity = down * 9.8
	var slant := Vector3(weather.wind * 0.35, -1.0, weather.wind * 0.12).normalized()
	pm.direction = slant
