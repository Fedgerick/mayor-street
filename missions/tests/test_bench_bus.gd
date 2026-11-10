extends SceneTree
## msp: the hidden bus job. Sit on a park bench, a bus pulls up and takes you on board, you
## ride it to the marked stop and get paid; getting off early loses the job.
##   godot --headless --path . -s missions/tests/test_bench_bus.gd -- --demo --nosave

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _until(f: Callable, seconds: float) -> bool:
	var t := 0.0
	while not f.call():
		await process_frame
		t += root.get_process_delta_time() * Engine.time_scale
		if t > seconds:
			return false
	return true


func _sit_on_park_bench(main: Node) -> Dictionary:
	var street: StreetMode = main.street
	var p := street.player
	var spots: StreetSpots = main.life.spots
	var best: StreetSpots.Spot = null
	var best_d := INF
	for s in spots.spots:
		if s.kind != StreetSpots.Kind.BENCH or s.taken[0] != null:
			continue
		var d := Planet.fdist(s.seats[0], Planet.flat(p.global_position))
		if d < best_d:
			best_d = d
			best = s
	if best == null:
		return {}
	best.park = true   # the test needs a park bench wherever the nearest one is
	var at := Planet.xf_rigid(Transform3D(Basis.IDENTITY, best.seats[0])).origin
	p.place(at + Planet.up(at) * 0.2, p.rig.yaw)
	await create_timer(0.3).timeout
	var seat := street.seating.find(at, 0.3)
	if seat.is_empty() or not await street.seating.sit(seat):
		return {}
	await _until(func(): return street.seating.seated and not street.seating.busy, 6.0)
	return seat


func _run() -> void:
	print("hidden bus job tests")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	main.go_street()
	var street: StreetMode = main.street
	while not street.active:
		await process_frame
	await create_timer(0.5).timeout
	var bus: BenchBus = main.bench_bus
	check(bus != null, "BenchBus is wired")
	var prog: Node = root.get_node("/root/Progress")

	# An ordinary bench: no bus.
	var seat := await _sit_on_park_bench(main)
	check(not seat.is_empty() and seat.park, "sitting on a park bench")
	check(bus.state == BenchBus.WAIT, "the bench is noticed")
	street.seating.stand()
	await _until(func(): return not street.seating.seated and not street.seating.busy, 4.0)
	check(bus.state == BenchBus.IDLE, "standing up before the bus comes calls it off")

	# Sit again, and this time a bus comes.
	Engine.time_scale = 3.0
	bus.force = true
	bus._cool = 0.0
	seat = await _sit_on_park_bench(main)
	check(await _until(func(): return bus.state in [BenchBus.COMING, BenchBus.BOARD], 20.0), "a bus is on its way")
	check(await _until(func(): return bus.state == BenchBus.BOARD, 60.0), "it pulls up at the bench")
	var bench_at: Vector3 = (seat.xform as Transform3D).origin
	check(bus._node.global_position.distance_to(bench_at) < 8.0,
		"it stopped beside the bench (%.1f m)" % bus._node.global_position.distance_to(bench_at))
	check(await _until(func(): return bus.state == BenchBus.RIDE, 5.0), "you are taken on board")
	check(street.seating.riding == bus._node and street.car == null, "riding, not driving")
	check(bus._goal != Vector3.INF and bus._beacon.visible, "the stop is marked")
	var nav = get_first_node_in_group("city_nav")
	if nav and nav.has_method("has_mark"):
		check(nav.has_mark("bus:stop"), "the stop is on the minimap")
	var goal := bus._goal
	await create_timer(1.0).timeout
	check(street.player.global_position.distance_to(bus._node.global_position) < 6.0, "you move with the bus")
	var cash0: int = prog.cash
	check(await _until(func(): return bus.state != BenchBus.RIDE and bus.state != BenchBus.DROP, 240.0),
		"the bus gets to the stop")
	check(bus.rides == 1 and prog.cash > cash0, "the stranger pays ($%d)" % (prog.cash - cash0))
	check(street.seating.riding == null and not street.player.puppet, "you are off the bus, on foot")
	check(Planet.fdist(Planet.flat(street.player.global_position), goal) < 14.0, "dropped at the marked stop")
	check(prog.get_flag("found:bench_bus", false), "the hidden job is counted as found")
	check(await _until(func(): return bus.state == BenchBus.IDLE, 60.0), "the bus drives off")

	# Get off early: the job is lost.
	bus.force = true
	bus._cool = 0.0
	seat = await _sit_on_park_bench(main)
	check(await _until(func(): return bus.state == BenchBus.RIDE, 70.0), "a second bus picks you up")
	var lost := [false]
	bus.failed.connect(func(_r): lost[0] = true, CONNECT_ONE_SHOT)
	var e := InputEventAction.new()
	e.action = "street_interact"
	e.pressed = true
	bus._unhandled_input(e)
	await process_frame
	check(lost[0] and street.seating.riding == null and bus.rides == 1, "getting off early loses the job")
	check(not bus._beacon.visible, "the stop is unmarked")
	Engine.time_scale = 1.0
	print("ALL PASSED" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
