extends SceneTree
## Renders the demo city with traffic and people from a street-level camera.
## godot --path . --script res://citylife/tests/shot.gd -- --demo --hour=17.5 --out=shot.png --cam=x,y,z,yawdeg,pitchdeg

var args := {}


class Suspect:
	extends RefCounted
	var wanted_stars := 0
	var pos := Vector3.ZERO
	func suspect_position() -> Vector3:
		return pos
	func suspect_velocity() -> Vector3:
		return Vector3(5, 0, 0)
	func suspect_in_vehicle() -> bool:
		return false


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
	var life: CityLife = main.get("life")
	if life == null:
		life = CityLife.new()
		main.add_child(life)
		life.setup(city, main.cam)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.2
	cam.far = 3000.0
	main.add_child(cam)
	var c := city.center_cell()
	var p: Vector3 = city.cell_center(c.x + 6, c.y + 3)
	var v := [p.x + 3.2, 2.6, p.z + 22.0, 8.0, -9.0]
	if args.has("cam"):
		v = Array(args["cam"].split(",")).map(func(s): return float(s))
	cam.position = Vector3(v[0], v[1], v[2])
	cam.rotation_degrees = Vector3(v[4], v[3], 0)
	if args.has("spot"):
		# Look at the bench or bus stop nearest the middle from across the street.
		var kind := StreetSpots.Kind.STOP if args["spot"] == "stop" else StreetSpots.Kind.BENCH
		var best: StreetSpots.Spot = null
		var mid := city.cell_center(c.x, c.y)
		for s in life.spots.spots:
			if s.kind == kind and (best == null or s.xform.origin.distance_to(mid) < best.xform.origin.distance_to(mid)):
				best = s
		var o := best.xform.origin
		var face := best.xform.basis.z
		var along := best.xform.basis.x
		cam.position = o + face * float(args.get("dist", "8")) - along * 5.0 + Vector3(0, 1.8, 0)
		cam.look_at(o + Vector3(0, 0.9, 0))
	cam.make_current()
	life.set_camera(cam)
	if args.has("stars"):
		# A wanted suspect on the sidewalk ahead of the camera, for chase shots.
		var sus := Suspect.new()
		sus.wanted_stars = int(args["stars"])
		sus.pos = cam.global_position - cam.global_basis.z * 28.0
		sus.pos.y = 0.17
		life.set_suspect(sus)
	for i in int(args.get("frames", "240")):
		await process_frame
	var img := root.get_texture().get_image()
	img.save_png(args.get("out", "user://citylife_shot.png"))
	print("cars %d people %d" % [life.traffic.cars.size(), life.crowd.peds.size()])
	quit()
