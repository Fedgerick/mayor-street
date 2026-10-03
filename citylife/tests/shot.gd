extends SceneTree
## Renders the demo city with traffic and people from a street-level camera.
## godot --path . --script res://citylife/tests/shot.gd -- --demo --hour=17.5 --out=shot.png --cam=x,y,z,yawdeg,pitchdeg

var args := {}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	change_scene_to_file("res://scenes/main.tscn")
	for i in 5:
		await process_frame
	var main: Node = current_scene
	var city: City = main.city
	if args.has("hour"):
		city.minutes = float(city.game_day()) * 1440.0 + float(args["hour"]) * 60.0
	var life := CityLife.new()
	main.add_child(life)
	life.setup(city, main.cam)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.2
	cam.far = 3000.0
	main.add_child(cam)
	var c := city.center_cell()
	var p: Vector3 = city.cell_center(c.x + 6, c.y + 3)
	var v := [p.x + 5.3, 1.7, p.z + 30.0, 8.0, -3.0]
	if args.has("cam"):
		v = Array(args["cam"].split(",")).map(func(s): return float(s))
	cam.position = Vector3(v[0], v[1], v[2])
	cam.rotation_degrees = Vector3(v[4], v[3], 0)
	cam.make_current()
	life.set_camera(cam)
	for i in int(args.get("frames", "240")):
		await process_frame
	var img := root.get_texture().get_image()
	img.save_png(args.get("out", "user://citylife_shot.png"))
	print("cars %d people %d" % [life.traffic.cars.size(), life.crowd.peds.size()])
	quit()
