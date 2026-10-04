class_name StreetFx
extends RefCounted
## Small, cheap one-shot effects for street action: tracers, muzzle flashes, impact and
## blood puffs, smoke, fire and explosions. Everything is unshaded and short-lived so it
## costs next to nothing on integrated graphics.

static var _mats := {}


static func _mat(key: String, col: Color, additive := false) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mats[key] = m
	return m


static func _fade_and_free(n: Node3D, mat: StandardMaterial3D, seconds: float, grow := 1.0) -> void:
	var t := n.create_tween()
	t.set_parallel(true)
	if mat:
		var c := mat.albedo_color
		t.tween_property(mat, "albedo_color", Color(c.r, c.g, c.b, 0.0), seconds)
	if grow != 1.0:
		t.tween_property(n, "scale", n.scale * grow, seconds).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.chain().tween_callback(n.queue_free)


static func tracer(parent: Node, from: Vector3, to: Vector3) -> void:
	var len := from.distance_to(to)
	if len < 0.2:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.025, 0.025, len)
	mi.mesh = bm
	var mat: StandardMaterial3D = _mat("tracer", Color(1.0, 0.85, 0.5, 0.9), true).duplicate()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_transform = Transform3D(Basis.looking_at(to - from, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT), (from + to) * 0.5)
	_fade_and_free(mi, mat, 0.07)


static func muzzle(parent: Node, pos: Vector3, dir: Vector3, big := false) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.09 if not big else 0.16
	sm.height = sm.radius * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	mi.mesh = sm
	var mat: StandardMaterial3D = _mat("muzzle", Color(1.0, 0.75, 0.3, 1.0), true).duplicate()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos + dir * 0.05
	mi.scale = Vector3(1, 1, 2.2)
	if dir.length() > 0.1:
		mi.look_at(pos + dir, Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.RIGHT)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.7, 0.35)
	l.light_energy = 3.0
	l.omni_range = 4.0
	l.shadow_enabled = false
	mi.add_child(l)
	_fade_and_free(mi, mat, 0.06)


static func puff(parent: Node, pos: Vector3, col: Color, size := 0.25, seconds := 0.35) -> void:
	## A small cloud: dust on walls, red on people, sparks on cars.
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = 10
	p.lifetime = seconds
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 2.6
	p.gravity = Vector3(0, -3.0, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var sm := SphereMesh.new()
	sm.radius = size * 0.5
	sm.height = size
	sm.radial_segments = 6
	sm.rings = 3
	var mat: StandardMaterial3D = _mat("puff", Color(1, 1, 1, 1)).duplicate()
	mat.albedo_color = col
	sm.material = mat
	p.mesh = sm
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


static func smoke(dark := false) -> CPUParticles3D:
	## A continuous smoke plume (damaged car engine); the caller parents and toggles it.
	var p := CPUParticles3D.new()
	p.amount = 18
	p.lifetime = 1.8
	p.direction = Vector3.UP
	p.spread = 12.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 1.8
	p.gravity = Vector3(0, 0.6, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.4))
	curve.add_point(Vector2(1, 1.6))
	p.scale_amount_curve = curve
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	sm.radial_segments = 6
	sm.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.12, 0.12, 0.12, 0.7) if dark else Color(0.6, 0.6, 0.62, 0.5)
	sm.material = mat
	p.mesh = sm
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.9))
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


static func fire() -> CPUParticles3D:
	var p := smoke(false)
	p.amount = 24
	p.lifetime = 0.7
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 2.6
	var mat: StandardMaterial3D = (p.mesh as SphereMesh).material
	mat.albedo_color = Color(1.0, 0.45, 0.1, 0.9)
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return p


static func explosion(parent: Node, pos: Vector3) -> void:
	# A cluster of fireballs that bloom and fade at slightly different times, a flash,
	# flying debris, and a smoke cloud left behind.
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 12
	sm.rings = 6
	for i in 7:
		var ball := MeshInstance3D.new()
		ball.mesh = sm
		var hot := Color(1.0, 0.85, 0.35, 0.95) if i < 3 else Color(1.0, 0.42, 0.1, 0.85)
		var mat: StandardMaterial3D = _mat("boom", Color.WHITE, true).duplicate()
		mat.albedo_color = hot
		ball.material_override = mat
		ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(ball)
		var off := Vector3(randf_range(-1.3, 1.3), randf_range(0.4, 2.0), randf_range(-1.3, 1.3)) * (0.3 if i < 3 else 1.0)
		ball.global_position = pos + off
		ball.scale = Vector3.ONE * randf_range(0.3, 0.6)
		var t := ball.create_tween()
		t.tween_interval(i * 0.035)
		t.set_parallel(true)
		t.tween_property(ball, "scale", Vector3.ONE * randf_range(1.6, 2.6), 0.45).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		t.tween_property(ball, "global_position", pos + off * 1.6 + Vector3.UP * 1.2, 0.6)
		t.tween_property(mat, "albedo_color", Color(0.5, 0.12, 0.04, 0.0), 0.6).set_ease(Tween.EASE_IN)
		t.chain().tween_callback(ball.queue_free)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.6, 0.25)
	l.light_energy = 12.0
	l.omni_range = 22.0
	parent.add_child(l)
	l.global_position = pos + Vector3.UP * 2.0
	var lt := l.create_tween()
	lt.tween_property(l, "light_energy", 0.0, 0.9)
	lt.tween_callback(l.queue_free)
	# Debris: dark chunks thrown out and falling back.
	var d := CPUParticles3D.new()
	d.one_shot = true
	d.emitting = false
	d.amount = 24
	d.lifetime = 1.4
	d.explosiveness = 1.0
	d.direction = Vector3.UP
	d.spread = 80.0
	d.initial_velocity_min = 5.0
	d.initial_velocity_max = 11.0
	d.gravity = Vector3(0, -14.0, 0)
	d.angular_velocity_min = -400.0
	d.angular_velocity_max = 400.0
	var bm := BoxMesh.new()
	bm.size = Vector3(0.18, 0.08, 0.14)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.08, 0.07, 0.07)
	bm.material = dm
	d.mesh = bm
	parent.add_child(d)
	d.global_position = pos + Vector3.UP
	d.emitting = true
	d.finished.connect(d.queue_free)
	puff(parent, pos + Vector3.UP * 1.5, Color(0.16, 0.15, 0.15, 0.85), 2.2, 2.2)
