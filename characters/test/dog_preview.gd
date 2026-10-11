extends Node3D
## Before/after shots of the street dogs: all five coats in a MultiMesh like citylife's,
## two of them mid-trot.
##   godot --rendering-driver vulkan -w res://characters/test/dog_preview.tscn -- --out=DIR [--plain] [--lod=1]

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var out: String = args.get("out", "user://dogs")
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.ssao_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	add_child(sun)
	var fl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	fl.mesh = pm
	add_child(fl)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	if args.has("plain"):
		mm.mesh = DogMesh.build()
		var dm := ShaderMaterial.new()
		dm.shader = load("res://citylife/dog.gdshader")
		mm.mesh.surface_set_material(0, dm)
	else:
		mm.mesh = HeroDog.build(int(args.get("lod", "0")))
		print("dog triangles: lod0 %d  lod1 %d" % [HeroDog.triangle_count(0), HeroDog.triangle_count(1)])
	mm.instance_count = 5
	for i in 5:
		# Turned three-quarters to the camera; the last two mid-trot.
		var b := Basis(Vector3.UP, deg_to_rad(-120.0 + i * 10.0))
		mm.set_instance_transform(i, Transform3D(b, Vector3((i - 2) * 0.9, 0, 0)))
		mm.set_instance_custom_data(i, Color(1.2 if i >= 3 else 0.0, 1.0 if i >= 3 else 0.0, float(i), 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	cam.fov = 35
	cam.position = Vector3(0, 1.3, 4.6)
	cam.look_at(Vector3(0, 0.35, 0))
	for k in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/dogs.png")
	cam.fov = 22
	cam.position = Vector3(-0.6, 0.85, 1.6)
	cam.look_at(Vector3(-0.9, 0.45, 0))
	for k in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/dog_close.png")
	get_tree().quit()
