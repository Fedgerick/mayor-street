extends SceneTree
## Look-dev shots of the car kit, before and after.
##   xvfb-run godot --rendering-driver vulkan --resolution 1280x720 -s res://vehicles/tools/preview.gd -- --shots=DIR [--only=lineup,closeup,...]
## Shots: lineup, closeup, police, service, damage, lods, night, old (the previous kit cars).

const TINTS := [Color(0.85, 0.12, 0.1), Color(0.15, 0.3, 0.7), Color(0.95, 0.95, 0.95), Color(0.1, 0.45, 0.3),
	Color(0.12, 0.12, 0.14), Color(0.7, 0.72, 0.75), Color(0.95, 0.75, 0.1), Color(0.55, 0.1, 0.15)]

var out_dir := "user://car_shots"
var only := []
var world: Node3D
var cam: Camera3D
var sun: DirectionalLight3D
var env: Environment


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			out_dir = a.substr(8)
		elif a.begins_with("--only="):
			only = a.substr(7).split(",")
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _stage() -> void:
	if world:
		world.free()
	world = Node3D.new()
	root.add_child(world)
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.32, 0.5, 0.78)
	mat.sky_horizon_color = Color(0.72, 0.8, 0.88)
	mat.ground_horizon_color = Color(0.6, 0.62, 0.62)
	mat.ground_bottom_color = Color(0.3, 0.3, 0.3)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 1.2
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -35, 0)
	sun.light_energy = 1.25
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	world.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.2, 0.2, 0.21)
	gm.roughness = 0.9
	ground.material_override = gm
	world.add_child(ground)
	cam = Camera3D.new()
	cam.fov = 50.0
	world.add_child(cam)
	RenderingServer.global_shader_parameter_set("night", 0.0)


func _night(on: bool) -> void:
	RenderingServer.global_shader_parameter_set("night", 1.0 if on else 0.0)
	if on:
		sun.light_energy = 0.05
		env.background_energy_multiplier = 0.06
		env.ambient_light_energy = 0.25
		var l := OmniLight3D.new()
		l.position = Vector3(0, 7, 6)
		l.omni_range = 30.0
		l.light_energy = 2.0
		l.light_color = Color(1.0, 0.75, 0.5)
		world.add_child(l)


func car(mesh: Mesh, pos: Vector3, yaw: float, tint := Color.WHITE, custom := Color(0, 0, 0, 0.3)) -> void:
	if mesh == null:
		push_warning("missing mesh")
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis(Vector3.UP, yaw), pos))
	mm.set_instance_color(0, tint)
	mm.set_instance_custom_data(0, custom)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	world.add_child(mmi)


func look(from: Vector3, at: Vector3, fov := 50.0) -> void:
	cam.position = from
	cam.look_at(at)
	cam.fov = fov


func shot(name: String) -> void:
	for i in 12:
		await process_frame
	var img := root.get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("shot ", name)


func want(n: String) -> bool:
	return only.is_empty() or n in only


func _run() -> void:
	var kit := root.get_node_or_null("Kit")
	if want("lineup"):
		_stage()
		var i := 0
		for m in VehicleKit.MODELS:
			var sp := VehicleKit.spec(m)
			var row := i / 6
			var col := i % 6
			car(VehicleKit.mesh(m), Vector3(col * 4.2 - 10.5, 0, row * 13.0 - 4.0), deg_to_rad(150), TINTS[i % TINTS.size()], VehicleKit.custom(false, false, false, false, 0.0, 0.0, i * 0.13))
			i += 1
		look(Vector3(-16, 9, 22), Vector3(0, 0.5, 1), 52)
		await shot("lineup")
	if want("gallery"):
		for m in VehicleKit.MODELS:
			_stage()
			var sp := VehicleKit.spec(m)
			var L: float = sp.get("length", 4.5)
			var zc: float = sp.get("axles", [{"z": 0.0}])[0]["z"] * 0.0
			car(VehicleKit.mesh(m), Vector3(0, 0, 0), deg_to_rad(145), TINTS[0], VehicleKit.custom(m in ["car_police", "car_ambulance", "car_firetruck"], false, false, false, 0.0, 0.25, 0.37))
			var d := L * 0.85 + 2.5
			look(Vector3(d * 0.62, sp.get("height", 1.5) * 0.9 + 0.6, d), Vector3(0, sp.get("height", 1.5) * 0.4, 0), 45)
			await shot("gallery_" + m)
	if want("closeup"):
		_stage()
		car(VehicleKit.mesh("car_sedan"), Vector3(0, 0, 0), deg_to_rad(145), TINTS[0], VehicleKit.custom(false, false, false, false, 0.0, 0.3, 0.4))
		car(VehicleKit.mesh("car_hatch"), Vector3(-5.5, 0, -3), deg_to_rad(145), TINTS[1], VehicleKit.custom(false, false, false, false, 0.0, 0.0, 0.7))
		car(VehicleKit.mesh("car_van"), Vector3(5, 0, -4), deg_to_rad(145), TINTS[6], VehicleKit.custom(false, false, false, false, 0.0, 0.0, 0.2))
		look(Vector3(-3.5, 2.4, 7.0), Vector3(0, 0.7, -0.5), 48)
		await shot("closeup")
	if want("police"):
		_stage()
		car(VehicleKit.mesh("car_police"), Vector3(0, 0, 0), deg_to_rad(145), Color.WHITE, VehicleKit.custom(true, false, false, false, 0.0, 0.0, 0.0))
		car(VehicleKit.mesh("car_taxi"), Vector3(-5.5, 0, -3), deg_to_rad(145), Color.WHITE, VehicleKit.custom(false, false, false, false, 0.0, 0.0, 0.55))
		look(Vector3(-3.5, 2.6, 7.0), Vector3(0, 0.8, -0.5), 48)
		await shot("police")
	if want("service"):
		_stage()
		car(VehicleKit.mesh("car_firetruck"), Vector3(-5, 0, 0), deg_to_rad(150), Color.WHITE, VehicleKit.custom(true))
		car(VehicleKit.mesh("car_ambulance"), Vector3(1.5, 0, 2), deg_to_rad(150), Color.WHITE, VehicleKit.custom(true))
		car(VehicleKit.mesh("car_bus"), Vector3(8, 0, -4), deg_to_rad(150), Color.WHITE, VehicleKit.custom(false, false, false, false, 0.0, 0.0, 0.3))
		car(VehicleKit.mesh("car_garbage"), Vector3(-11, 0, -6), deg_to_rad(150), Color.WHITE)
		look(Vector3(-6, 6, 16), Vector3(0, 1.2, -1), 55)
		await shot("service")
	if want("damage"):
		_stage()
		for s in 4:
			var me: Mesh = VehicleKit.damaged("car_sedan", s)
			car(me, Vector3(s * 3.4 - 5.1, 0, 0), deg_to_rad(155), TINTS[1])
		look(Vector3(-4, 3.5, 8.5), Vector3(0, 0.6, 0), 55)
		await shot("damage")
	if want("lods"):
		_stage()
		for l in 3:
			car(VehicleKit.mesh("car_sedan", l), Vector3(l * 3.0 - 3.0, 0, 0), deg_to_rad(150), TINTS[0])
		look(Vector3(-2, 2.6, 7.5), Vector3(0, 0.6, 0), 50)
		await shot("lods")
	if want("night"):
		_stage()
		_night(true)
		car(VehicleKit.mesh("car_police"), Vector3(0, 0, 0), deg_to_rad(145), Color.WHITE, VehicleKit.custom(true, true))
		car(VehicleKit.mesh("car_sedan"), Vector3(-5.5, 0, -3), deg_to_rad(-35), TINTS[1], VehicleKit.custom(false, true))
		car(VehicleKit.mesh("car_taxi"), Vector3(5, 0, -4), deg_to_rad(145), Color.WHITE)
		look(Vector3(-3.5, 2.6, 8.0), Vector3(0, 0.8, -1), 52)
		await shot("night")
	if want("tow"):
		_stage()
		var yaw := deg_to_rad(150)
		var b := Basis(Vector3.UP, yaw)
		car(VehicleKit.mesh("car_tow"), Vector3(0, 0, 0), yaw, Color.WHITE, VehicleKit.custom(true, false, false, false, 0.0, 0.2, 0.0))
		car(VehicleKit.mesh("car_sedan"), b * Vector3(0, 1.12, 1.575), yaw, TINTS[1])
		car(VehicleKit.damaged("car_pickup", 3), Vector3(-8.5, 0, -3), deg_to_rad(110), TINTS[0])
		look(Vector3(11.0, 4.2, -9.0), Vector3(-1.5, 1.2, 0.5), 50)
		await shot("tow")
		_night(true)
		look(Vector3(8.0, 3.4, -8.5), Vector3(0, 1.4, 0.5), 50)
		await shot("tow_night")
	if want("old") and kit:
		_stage()
		car(kit.mesh("car_sedan") if kit.meshes.has("car_sedan") else null, Vector3(0, 0, 0), deg_to_rad(145), TINTS[0])
		car(kit.mesh("car_hatch"), Vector3(-5.5, 0, -3), deg_to_rad(145), TINTS[1])
		car(kit.mesh("car_van"), Vector3(5, 0, -4), deg_to_rad(145), TINTS[6])
		look(Vector3(-3.5, 2.4, 7.0), Vector3(0, 0.7, -0.5), 48)
		await shot("old")
	quit()
