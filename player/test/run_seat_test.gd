extends SceneTree
## Headless check of sitting down (player/scripts/street_seating.gd):
##   godot --headless -s res://player/test/run_seat_test.gd
## A real street bench from citylife's StreetSpots, a chair in a loaded room, getting hurt,
## busted and killed while seated, and riding a moving vehicle as a passenger.
## Exits with code 1 on any failure. Under xvfb with a renderer, `-- --shots=DIR` also
## saves DIR/bench.png and DIR/chair.png.

var fails := 0
var t: Node3D


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _wait(cond: Callable, limit := 600) -> void:
	for i in limit:
		if cond.call():
			return
		await physics_frame


func _standing(street: StreetMode, what: String) -> void:
	var p := street.player
	check(not street.seating.seated and not street.seating.busy and not p.puppet and not p.visual._sitting,
		"%s: standing (seated=%s busy=%s puppet=%s sitting=%s)" % [what, street.seating.seated,
			street.seating.busy, p.puppet, p.visual._sitting])


func _shot(name: String) -> void:
	var dir := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			dir = a.substr(8)
	if dir == "" or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	await frames(30)
	root.get_texture().get_image().save_png(dir + "/" + name + ".png")
	print("saved ", dir + "/" + name + ".png")


func _sit_on(street: StreetMode, seat: Dictionary, what: String) -> void:
	var p := street.player
	var xf: Transform3D = seat.xform
	var fwd := -xf.basis.z
	p.place(xf.origin + fwd * 0.7 + Planet.up(xf.origin) * 0.05, p.facing_yaw())
	await frames(10)
	street._on_interact()
	await _wait(func(): return street.seating.seated)
	check(street.seating.seated, "%s: seated" % what)
	await frames(20)
	check(p.global_position.distance_to(xf.origin) < 0.05, "%s: on the seat (%.2f m off)" % [what,
		p.global_position.distance_to(xf.origin)])
	var face := -p.visual.global_basis.z
	check(face.dot(fwd) > 0.95, "%s: facing out from the seat (%.2f)" % [what, face.dot(fwd)])
	check(p.visual._sitting and p.visual._sit_kind == "bench" and p.visual._sit > 0.99, "%s: in the seated pose" % what)
	check(street._hint.text == "E  stand up", "%s: hint says stand up ('%s')" % [what, street._hint.text])


func _run() -> void:
	var scene: PackedScene = load("res://player/test/street_test.tscn")
	t = scene.instantiate()
	t.with_life = true
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var p: StreetPlayer = street.player
	t.go_street()
	await frames(int(street.dive_seconds * 60.0) + 40)
	check(street.active, "on the street")
	street.parked_cars_per_drop = 0
	for v in get_nodes_in_group("vehicles"):
		v.queue_free()   # keep E for the seats
	await frames(2)

	# --- A street bench ---------------------------------------------------------------
	var spots: StreetSpots = t.life.spots
	var bench: StreetSpots.Spot = null
	for s in spots.spots:
		if s.kind == StreetSpots.Kind.BENCH and s.taken[0] == null and s.taken[1] == null:
			bench = s
			break
	check(bench != null, "the city has a free bench (%d spots)" % spots.spots.size())
	if bench:
		var p0 := Planet.xf_rigid(Transform3D(Basis.IDENTITY, bench.seats[0])).origin
		var seat := street.seating.find(p0, 0.3)
		check(not seat.is_empty() and seat.kind == "bench" and seat.has("park") and seat.spot == bench,
			"found the bench seat (%s)" % [seat.get("kind")])
		if not seat.is_empty():
			await _sit_on(street, seat, "bench")
			p.rig.yaw = p.facing_yaw() + 2.6
			p.rig.pitch = deg_to_rad(-12.0)
			await _shot("bench")
			check(bench.taken[seat.slot] == p, "the crowd sees the seat taken")
			var sat := [false]
			street.seating.stood_up.connect(func(_s): sat[0] = true, CONNECT_ONE_SHOT)
			street.seating.stand()
			await _wait(func(): return not street.seating.busy and not street.seating.seated)
			await frames(5)
			_standing(street, "stood up")
			check(sat[0], "stood_up fired")
			check(bench.taken[seat.slot] == null, "seat free again")
			check(p.global_position.distance_to((seat.xform as Transform3D).origin) > 0.3,
				"standing in front of the bench")
			# Hurt while seated: up you get.
			await _sit_on(street, street.seating.find(p0, 0.3), "bench again")
			p.hurt(10.0)
			await _wait(func(): return not street.seating.busy and not street.seating.seated)
			_standing(street, "hurt on the bench")
			# Busted while seated.
			await _sit_on(street, street.seating.find(p0, 0.3), "bench, then busted")
			street.set_wanted(1)
			street.bust()
			await frames(60 * 7)
			await frames(30)
			_standing(street, "busted on the bench")
			check(bench.taken[0] != p and bench.taken[1] != p, "busted: seat let go")

	# --- A chair indoors ------------------------------------------------------------------
	var room := Interior.create("home")
	room.transform = InteriorManager.room_transform()
	t.add_child(room)
	await frames(2)
	check(room.seats.size() >= 4, "home has seats (%d)" % room.seats.size())
	var chair := {}
	for i in room.seats.size():
		if room.seats[i][1] == "chair":
			chair = room.seats_near((room.global_transform * (room.seats[i][0] as Transform3D)).origin, 0.1)[0]
			break
	check(not chair.is_empty(), "found a kitchen chair")
	if not chair.is_empty():
		await _sit_on(street, chair, "kitchen chair")
		p.rig.yaw = p.facing_yaw() + 2.4
		await _shot("chair")
		room.queue_free()   # leave the room while seated (missions can call exit())
		await frames(5)
		_standing(street, "room unloaded while seated")

	# --- A passenger seat on something moving -------------------------------------------------
	var bus := Node3D.new()
	t.add_child(bus)
	var start := p.global_position + Planet.up(p.global_position) * 0.3
	bus.global_transform = Transform3D(Planet.basis(start), start)
	check(street.seating.ride(bus, Transform3D(Basis.IDENTITY, Vector3(0.5, 0.9, -1.0))), "ride started")
	for i in 60:
		bus.global_position += bus.global_basis.z * -0.1
		await physics_frame
	var want := (bus.global_transform * Vector3(0.5, 0.9, -1.0)) - bus.global_basis.y * StreetSeating.SEAT_HEIGHT
	check(p.global_position.distance_to(want) < 0.15, "riding along (%.2f m off)" % p.global_position.distance_to(want))
	check(p.visual._sitting and p.puppet, "seated on the ride")
	street._on_interact()
	await frames(5)
	check(street.seating.riding == bus, "E doesn't get off a ride")
	street.seating.end_ride(bus.global_position + bus.global_basis.x * 2.0)
	await frames(10)
	_standing(street, "ride over")

	print("\n%s (%d failed)" % ["ALL PASS" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
