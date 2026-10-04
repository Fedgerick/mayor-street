extends SceneTree
## End to end: demo city, place the bank, walk into its door, check the room loads, walk
## back out, check the player is on the street again.
##     godot --headless --path . --script res://interiors/tests/door_e2e_test.gd -- --demo

var main: Node
var mgr: InteriorManager


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _fail(msg: String) -> void:
	print("FAIL: ", msg)
	quit(1)


func _run() -> void:
	await _frames(5)
	var city: City = main.city
	mgr = InteriorManager.new()
	mgr.fade_seconds = 0.05
	main.add_child(mgr)
	mgr.setup(city, main.street)
	# A free lot next to a road, near the middle.
	var c: Vector2i = city.center_cell()
	var id := -1
	for r in range(1, 30):
		for y in range(c.y - r, c.y + r):
			for x in range(c.x - r, c.x + r):
				if id < 0 and city.can_place_special("bank", Vector2i(x, y), true) == "":
					id = city.place_special("bank", Vector2i(x, y), -1, true)
		if id >= 0:
			break
	if id < 0:
		return _fail("no lot for the bank")
	if not mgr.doors.has(id):
		return _fail("bank has no door trigger")
	print("bank placed: ", city.buildings[id].x, ",", city.buildings[id].y, " rot ", city.buildings[id].rot)
	var door: DoorTrigger = mgr.doors[id]
	main.cam.focus = door.global_position
	main.go_street()
	await main.street.street_entered
	await _frames(10)
	var p: StreetPlayer = main.street.player
	var xf := door.global_transform
	var inward := -xf.basis.z
	p.place(xf.origin + xf.basis.z * 0.4 + Vector3.UP * 0.1, atan2(-inward.x, -inward.z))
	var entered := [false]
	mgr.interior_entered.connect(func(i, _b): entered[0] = true; print("entered ", i))
	for i in 120:
		await physics_frame
		if entered[0]:
			break
	if not entered[0]:
		return _fail("walking into the door did not enter (player at %s, door at %s)" % [p.global_position, xf.origin])
	if not mgr.is_inside() or mgr.current.marker("vault") == null:
		return _fail("inside state or vault marker missing")
	await _frames(20)
	var y := p.global_position.y
	print("player inside at ", p.global_position, " (floor ~", InteriorManager.ORIGIN.y, ")")
	if absf(y - InteriorManager.ORIGIN.y) > 1.5:
		return _fail("player fell through the floor or is off the room")
	# Walk out: step onto the exit marker.
	await create_timer(0.8).timeout
	var ex := mgr.current.marker("exit").global_transform
	var exited := [false]
	mgr.interior_exited.connect(func(i, _b): exited[0] = true; print("exited ", i))
	p.place(ex.origin + Vector3.UP * 0.1, 0.0)
	for i in 120:
		await physics_frame
		if exited[0]:
			break
	if not exited[0]:
		return _fail("walking onto the exit did not leave")
	await _frames(10)
	var d := p.global_position.distance_to(door.outside.origin)
	print("player back outside at ", p.global_position, ", ", snappedf(d, 0.01), " m from the door spot")
	if d > 1.0:
		return _fail("player not back at the door")
	# Every room: enter directly (as missions will), stand for a moment, leave.
	for rid in ["home", "bank", "bunker", "shop_gas", "shop_pawn", "shop_diner", "nightclub", "police"]:
		await create_timer(0.3).timeout
		if not await mgr.enter(rid):
			return _fail("enter(%s) refused" % rid)
		await _frames(40)
		var h := p.global_position.y - InteriorManager.ORIGIN.y
		print("%s: player at height %.2f, %d markers" % [rid, h, mgr.current.marker_names().size()])
		if h < -0.2 or h > 0.6 or not p.is_on_floor():
			return _fail("%s: player not standing on the floor" % rid)
		await mgr.exit()
	print("RESULT: ok")
	quit(0)
