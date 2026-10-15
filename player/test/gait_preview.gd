extends SceneTree
## Film strips of the movement clips, side on, for checking poses by eye:
##   xvfb-run godot --rendering-driver vulkan -s res://player/test/gait_preview.gd -- --out=DIR
## DIR/gaits.png  Walk, Jog and Run at eight points of the cycle
## DIR/seat.png   SitDown, SitBench, StandUp and Land

var out := "user://gait"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	_run.call_deferred()


func _stage(w: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	w.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.7, 0.8)
	env.environment.ambient_light_color = Color(0.6, 0.62, 0.66)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	w.add_child(env)
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 20)
	g.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.45, 0.43)
	g.material_override = mat
	w.add_child(g)


func _pose(w: Node3D, seed_v: int, pos: Vector3, clip: String, t: float, yaw := PI * 0.5) -> CharacterModel:
	var m := CharacterModel.new()
	m.seed_value = seed_v
	m.lod = 0
	m.auto_idle = false
	w.add_child(m)
	m.position = pos
	m.rotation.y = yaw
	m.tree.active = false
	m.anim.play(clip)
	m.anim.seek(t * m.anim.current_animation_length, true)
	m.anim.pause()
	return m


func _label(w: Node3D, text: String, pos: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.pixel_size = 0.004
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	w.add_child(l)


func _shot(path: String) -> void:
	for i in 8:
		await process_frame
	root.get_texture().get_image().save_png(path)
	print("saved ", path)


func _run() -> void:
	root.size = Vector2i(1600, 900)
	var w := Node3D.new()
	root.add_child(w)
	_stage(w)
	var cam := Camera3D.new()
	w.add_child(cam)
	cam.make_current()
	cam.fov = 30
	cam.position = Vector3(0, 1.6, 15)
	cam.look_at(Vector3(0, 1.0 - 1.4, 0))
	var rows := ["Walk", "Jog", "Run"]
	for r in rows.size():
		_label(w, rows[r], Vector3(-6.8, 1.0 - 2.4 * r + 0.9, 0))
		for i in 8:
			_pose(w, 7, Vector3(-5.2 + i * 1.5, -2.4 * r, 0), rows[r], i / 8.0)
	cam.position = Vector3(0, -1.0, 17)
	cam.look_at(Vector3(0, -1.5, 0))
	await _shot(out + "/gaits.png")
	for c in w.get_children():
		if c is CharacterModel or c is Label3D:
			c.queue_free()
	await process_frame
	var row := [["SitDown", 0.0], ["SitDown", 0.3], ["SitDown", 0.5], ["SitDown", 0.7], ["SitBench", 0.0],
		["StandUp", 0.3], ["StandUp", 0.55], ["StandUp", 0.8], ["Land", 0.4]]
	for i in row.size():
		_pose(w, 21, Vector3(-6 + i * 1.5, 0, 0), row[i][0], row[i][1])
		_label(w, "%s %.1f" % row[i], Vector3(-6 + i * 1.5, 2.1, 0))
	cam.position = Vector3(0, 1.2, 15)
	cam.look_at(Vector3(0, 0.9, 0))
	await _shot(out + "/seat.png")
	quit()
