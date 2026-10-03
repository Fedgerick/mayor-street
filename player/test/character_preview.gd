extends Node3D
## Lines up the character once per animation, frozen mid-clip, and saves a screenshot.
##   godot --rendering-driver vulkan -w res://player/test/character_preview.tscn -- --out=preview.png [--t=0.25] [--side]

const CHAR := preload("res://player/assets/character.glb")
const ANIMS := ["Idle", "Walk", "Run", "Jump", "Fall", "Sit", "EnterCar", "ExitCar"]


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var t := float(args.get("t", "0.25"))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.62, 0.72)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.8, 0.9)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.ssao_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 10)
	floor_mi.mesh = pm
	add_child(floor_mi)
	for i in ANIMS.size():
		var c: Node3D = CHAR.instantiate()
		add_child(c)
		c.position = Vector3((i - 3.5) * 1.3, 0, 0)
		if args.has("side"):
			c.rotation.y = -PI * 0.5
		var ap: AnimationPlayer = c.find_children("*", "AnimationPlayer", true, false)[0]
		ap.play(ANIMS[i])
		ap.seek(ap.current_animation_length * t, true)
		ap.pause()
		var l := Label3D.new()
		l.text = ANIMS[i]
		l.position = Vector3((i - 3.5) * 1.3, 2.15, 0)
		l.pixel_size = 0.004
		add_child(l)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.4, 7.5)
	cam.rotation_degrees = Vector3(-6, 0, 0)
	cam.fov = 55
	add_child(cam)
	cam.make_current()
	for k in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(args.get("out", "user://preview.png"))
	get_tree().quit()
