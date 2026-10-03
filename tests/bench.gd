extends SceneTree
## Frame-cost benchmark of the full main scene (sim + renderer bookkeeping + city life).
##   godot --headless --path . --script res://tests/bench.gd -- --demo [--hour=12]
## Prints average and worst script time per frame at a few camera heights, then on foot.

const VIEWS := [["mayor wide", 700.0], ["mayor mid", 260.0], ["close", 70.0], ["street", 25.0]]


func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)


func _run(main: Node3D) -> void:
	for i in 10:
		await process_frame
	var c: Vector3 = main.city.cell_center(main.city.center_cell().x, main.city.center_cell().y)
	main._set_speed(1)
	for v in VIEWS:
		main.cam.set_view(c, v[1], deg_to_rad(-35.0))
		for i in 30:
			await process_frame
		var total := 0.0
		var worst := 0.0
		var n := 240
		for i in n:
			var t0 := Time.get_ticks_usec()
			await process_frame
			var ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			total += ms
			worst = maxf(worst, ms)
		print("%-11s process avg %.2f ms, worst %.2f ms, cars %d, people %d" % [
			v[0], total / n, worst, main.life.traffic.cars.size(), main.life.crowd.peds.size()])
	# On foot downtown, with the full crowd and its rigged characters around the player.
	main.cam.set_view(Vector3(562, 0, 612), 80.0, 0.0)
	main.go_street()
	await main.street.street_entered
	for i in 90:
		await process_frame
	var total := 0.0
	var worst := 0.0
	var phys := 0.0
	var n := 240
	for i in n:
		await process_frame
		var ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		total += ms
		worst = maxf(worst, ms)
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	print("%-11s process avg %.2f ms, worst %.2f ms, physics avg %.2f ms, cars %d, people %d, rigged %s" % [
		"on foot", total / n, worst, phys / n, main.life.traffic.cars.size(), main.life.crowd.peds.size(),
		str(main.life.crowd.get("_hero_count"))])
	quit()
