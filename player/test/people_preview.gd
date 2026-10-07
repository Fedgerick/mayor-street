extends Node3D
## Before/after shots and numbers for the people rebuild. Saves three images and prints
## triangles and draw calls for a crowd of rigged people:
##   godot --rendering-driver vulkan -w res://player/test/people_preview.tscn -- --out=DIR [--clip=Idle] [--t=0.3]
## DIR/close.png    two people, head and shoulders
## DIR/lineup.png   eight outfits, full body
## DIR/poses.png    the new clips, frozen mid-move
## DIR/hands.png    close on a wave and a fist
## DIR/cars.png     the player seated in kit cars, and the four damage stages
## DIR/crowd.png    24 people (what Crowd keeps rigged near the camera), with the numbers

var args := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var out: String = args.get("out", "user://people")
	DirAccess.make_dir_recursive_absolute(out)
	_stage()
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	var models: Array = []
	# Close-up: two people.
	for i in 2:
		models.append(_person(11 + i * 6, Vector3(-0.32 + i * 0.64, 0, 0), -0.35 + i * 0.7))
	cam.fov = 30
	cam.position = Vector3(0, 1.55, 1.9)
	cam.look_at(Vector3(0, 1.5, 0))
	await _shot(out + "/close.png", models)
	_clear(models)
	# Lineup: eight people.
	for i in 8:
		models.append(_person(3 + i * 5, Vector3((i - 3.5) * 0.85, 0, 0), 0.25 * sin(i)))
	cam.fov = 40
	cam.position = Vector3(0, 1.2, 6.2)
	cam.look_at(Vector3(0, 0.95, 0))
	await _shot(out + "/lineup.png", models)
	_clear(models)
	# Poses: one clip each.
	var poses := [["Wave", 0.45], ["Phone", 0.3], ["IdleArms", 0.3], ["Talk", 0.3], ["SitBench", 0.3],
		["Jab", 0.36], ["Hook", 0.42], ["ReloadPistol", 0.5], ["ReloadShotgun", 0.3], ["Stumble", 0.4],
		["FallBack", 1.0], ["Umbrella", 0.3]]
	for i in poses.size():
		var m := _person(40 + i * 3, Vector3((i - 5.5) * 0.95, 0, 0), 0.35, poses[i][0], poses[i][1])
		models.append(m)
		var l := Label3D.new()
		l.text = poses[i][0]
		l.position = Vector3((i - 5.5) * 0.95, 2.05, 0)
		l.pixel_size = 0.003
		add_child(l)
		models.append(l)
	cam.fov = 40
	cam.position = Vector3(0, 1.4, 9.0)
	cam.look_at(Vector3(0, 0.9, 0))
	await _shot(out + "/poses.png", models)
	_clear(models)
	# Hands: a wave and a hook, close.
	models.append(_person(31, Vector3(-0.25, 0, 0), 0.0, "Wave", 0.45))
	models.append(_person(32, Vector3(0.55, 0, 0.1), -0.6, "Hook", 0.36))
	cam.fov = 30
	cam.position = Vector3(0.1, 1.6, 2.1)
	cam.look_at(Vector3(0.1, 1.45, 0))
	await _shot(out + "/hands.png", models)
	_clear(models)
	# Cars: seated in a sedan, a pickup and a bus; a taxi at each damage stage.
	var seats := [["car_sedan", Vector3(-7.0, 0, 0)], ["car_pickup", Vector3(-1.0, 0, 0)], ["car_bus", Vector3(8.0, 0, -1.5)]]
	for sp in seats:
		var c := DrivableCar.new()
		c.model = sp[0]
		c.freeze = true
		add_child(c)
		c.global_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), sp[1])
		models.append(c)
		var d := _person(60 + models.size(), Vector3.ZERO, 0.0, "Sit", 0.3)
		d.global_position = c.seat_point()
		d.rotation.y = c.heading_yaw()
		models.append(d)
	for st in 4:
		var t := DrivableCar.new()
		t.model = "car_taxi"
		t.freeze = true
		add_child(t)
		t.global_transform = Transform3D(Basis(Vector3.UP, 0.6), Vector3(-6.0 + st * 3.6, 0, 7.0))
		if st > 0:
			t._set_damage(st)
		models.append(t)
	cam.fov = 50
	cam.position = Vector3(0, 6.5, 19.0)
	cam.look_at(Vector3(-0.5, 0.8, 3.0))
	await _shot(out + "/cars.png", models)
	cam.fov = 35
	cam.position = Vector3(-6.5, 1.9, 4.2)
	cam.look_at(Vector3(-7.0, 1.0, 0.0))
	await _shot(out + "/seat.png", models)
	_clear(models)
	# Crowd: 24 rigged people in a loose block, numbers printed.
	for i in 24:
		var p := Vector3((i % 6 - 2.5) * 1.6 + (i / 6 % 2) * 0.6, 0, -float(i / 6) * 4.0)
		models.append(_person(100 + i * 7, p, randf_range(-0.6, 0.6), "", -1.0, -1))
	cam.fov = 55
	cam.position = Vector3(0, 2.4, 6.5)
	cam.look_at(Vector3(0, 1.0, -5.0))
	await _shot(out + "/crowd.png", models)
	var rs := RenderingServer
	var tris := rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var calls := rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var per := 0
	for mi in models[0].find_children("*", "MeshInstance3D", true, false):
		var m := (mi as MeshInstance3D)
		if m.visible and m.mesh:
			for s in m.mesh.get_surface_count():
				per += m.mesh.surface_get_array_index_len(s) / 3
	var line := "people: 24 rigged, frame %d triangles, %d draw calls (incl. shadows); one person %d triangles" % [tris, calls, per]
	print(line)
	var f := FileAccess.open(out + "/numbers.txt", FileAccess.WRITE)
	f.store_line(line)
	get_tree().quit()


func _stage() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.58, 0.66, 0.76)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.8, 0.9)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.ssao_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 28, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.5, 0.5, 0.52)
	floor_mi.material_override = fm
	add_child(floor_mi)


func _person(seed_value: int, pos: Vector3, yaw: float, clip := "", t := -1.0, level := 0) -> CharacterModel:
	var m := CharacterModel.new()
	m.seed_value = seed_value
	add_child(m)
	m.position = pos
	m.rotation.y = yaw + PI   # face the camera (+Z)
	m.lod = level
	if clip == "":
		clip = args.get("clip", "")
	if t < 0.0:
		t = float(args.get("t", "0.3"))
	if clip != "" and m.anim.has_animation(clip):
		m.tree.active = false
		m.anim.play(clip)
		m.anim.seek(m.anim.current_animation_length * t, true)
		m.anim.pause()
	return m


func _shot(path: String, models: Array) -> void:
	for k in 6:
		for m in models:
			if m is CharacterModel:
				(m as CharacterModel).animate(0.05, 0.0, true, 0.0, 0.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)


func _clear(models: Array) -> void:
	for m in models:
		m.queue_free()
	models.clear()
