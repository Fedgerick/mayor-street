extends Node3D
## Before/after shots of the player character: a full-body line-up and face close-ups,
## lit like a sunny street (sky ambient, low sun, ACES), at Med settings.
##   godot --rendering-driver vulkan -w res://characters/test/hero_preview.tscn -- --out=DIR [--plain]
## --plain skips HeroLook, which gives the "before" shots; --flat turns painted detail off;
## --noshadow turns the sun's shadows off.

const LOOKS := [
	{"top": "tee", "bottom": "jeans", "shoes": "sneakers", "hat": "", "hair": "short", "face": "clean",
		"colors": {"Skin": Color(0.89, 0.66, 0.5), "Shirt": Color(0.2, 0.47, 0.86), "Pants": Color(0.17, 0.22, 0.38), "Hair": Color(0.36, 0.21, 0.1), "Shoes": Color(0.96, 0.96, 0.96)}},
	{"top": "hoodie", "bottom": "jeans", "shoes": "boots", "hat": "cap", "hair": "buzz", "face": "beard",
		"colors": {"Skin": Color(0.47, 0.31, 0.21), "Shirt": Color(0.9, 0.28, 0.22), "Pants": Color(0.14, 0.14, 0.16), "Hair": Color(0.12, 0.09, 0.07), "Hat": Color(0.15, 0.3, 0.6), "Shoes": Color(0.1, 0.1, 0.11)}},
	{"top": "jacket", "bottom": "skirt", "shoes": "sneakers", "hat": "", "hair": "ponytail", "face": "glasses",
		"colors": {"Skin": Color(0.98, 0.8, 0.66), "Shirt": Color(0.95, 0.95, 0.93), "Jacket": Color(0.6, 0.12, 0.1), "Pants": Color(0.3, 0.32, 0.36), "Hair": Color(0.8, 0.6, 0.32), "Shoes": Color(0.85, 0.2, 0.2)}},
	{"top": "tank", "bottom": "shorts", "shoes": "sneakers", "hat": "", "hair": "afro", "face": "clean",
		"colors": {"Skin": Color(0.7, 0.48, 0.34), "Shirt": Color(0.98, 0.78, 0.2), "Pants": Color(0.47, 0.39, 0.28), "Hair": Color(0.12, 0.09, 0.07), "Shoes": Color(0.1, 0.1, 0.11)}},
]

var args := {}
var models: Array[Node3D] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var out: String = args.get("out", "user://hero")
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.32, 0.5, 0.8)
	sm.sky_horizon_color = Color(0.7, 0.76, 0.85)
	sm.ground_bottom_color = Color(0.2, 0.18, 0.16)
	sm.ground_horizon_color = Color(0.5, 0.48, 0.45)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.0
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_white = 6.0
	e.ssao_enabled = true
	e.glow_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 1.6
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = not args.has("noshadow")
	sun.directional_shadow_max_distance = 30.0
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.55, 0.54, 0.52)
	floor_mi.material_override = fm
	add_child(floor_mi)
	for i in LOOKS.size():
		var cm := CharacterModel.new()
		cm.lod = 0
		cm.seed_value = 5 + i * 31
		cm.auto_idle = false
		cm.position = Vector3((i - 1.5) * 1.0, 0, 0)
		cm.rotation.y = PI
		add_child(cm)
		cm.set_outfit(LOOKS[i])
		if not args.has("plain"):
			var hl = load("res://characters/scripts/hero_look.gd").new()
			if args.has("flat"):
				hl.detail = 0.0
			hl.mid = args.has("mid")
			cm.add_child(hl)
		models.append(cm)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	for k in 30:
		await get_tree().process_frame
	# Full body line-up.
	cam.fov = 40
	cam.position = Vector3(0, 1.0, 5.6)
	cam.look_at(Vector3(0, 0.9, 0))
	await _shot(out + "/lineup.png")
	# Face close-ups.
	for i in models.size():
		cam.fov = 30
		var p := models[i].global_position
		cam.position = p + Vector3(0.25, 1.68, 1.25)
		cam.look_at(p + Vector3(0, 1.62, 0))
		await _shot(out + "/face_%d.png" % i)
	# Three-quarter torso.
	cam.fov = 35
	var p0 := models[1].global_position
	cam.position = p0 + Vector3(-0.9, 1.4, 2.0)
	cam.look_at(p0 + Vector3(0, 1.15, 0))
	await _shot(out + "/torso.png")
	# Over the shoulder, where the street camera sits.
	cam.fov = 60
	cam.position = p0 + Vector3(0.6, 1.9, -3.2)
	cam.look_at(p0 + Vector3(0, 1.3, 0))
	await _shot(out + "/street_cam.png")
	cam.position = p0 + Vector3(-1.2, 1.7, 2.6)
	cam.look_at(p0 + Vector3(0, 1.1, 0))
	await _shot(out + "/street_front.png")
	# Triangle and draw report.
	for i in models.size():
		print("model %d tris %d" % [i, models[i].triangle_count()])
	get_tree().quit()


func _shot(path: String) -> void:
	for k in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
