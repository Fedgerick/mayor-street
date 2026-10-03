extends SceneTree
## Headless checks for the city sim:  godot --headless --path . --script res://tests/run_tests.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _init() -> void:
	print("City sandbox tests")
	var c := City.new()
	var land := 0
	for v in c.land:
		land += v
	check(land > 2500, "island has buildable land (%d tiles)" % land)
	var mid := c.center_cell()
	check(c.land[c.idx(mid.x, mid.y)] == 1, "centre cell is land")

	# Roads and zoning cost money and change the grid.
	var f0 := c.funds
	var path := c.road_path(mid + Vector2i(-5, 0), mid + Vector2i(5, 3))
	check(path.size() == 14, "L-shaped road path has 14 cells (%d)" % path.size())
	check(c.place_road(path), "place road")
	check(c.funds < f0, "road costs money")
	check(c.road_mask(mid.x, mid.y) == 10, "east-west road mask (%d)" % c.road_mask(mid.x, mid.y))
	var r := Rect2i(mid.x - 5, mid.y + 1, 10, 2)
	check(c.place_zone(r, City.Zone.RES), "zone residential")
	check(c.zone[c.idx(mid.x, mid.y + 1)] == City.Zone.RES, "zone stored")
	check(c.zone[c.idx(mid.x, mid.y)] == 0, "roads are never zoned")

	# Growth: a zoned strip next to a road fills up.
	c.place_zone(Rect2i(mid.x - 5, mid.y - 2, 5, 2), City.Zone.IND)
	c.place_zone(Rect2i(mid.x, mid.y - 2, 5, 2), City.Zone.COM)
	c.simulate_hours(24 * 10)
	check(c.buildings.size() > 10, "buildings grew (%d)" % c.buildings.size())
	check(c.population > 0, "population > 0 (%d)" % c.population)
	check(c.jobs_c + c.jobs_i > 0, "jobs > 0 (%d)" % (c.jobs_c + c.jobs_i))
	var traffic := 0.0
	for v in c.traffic:
		traffic += v
	check(traffic > 0.0, "commuters create traffic")

	# Bulldozing clears buildings.
	var n := c.buildings.size()
	c.bulldoze(r)
	check(c.buildings.size() < n, "bulldoze removes buildings")
	check(c.zone[c.idx(mid.x, mid.y + 1)] == 0, "bulldoze clears zones")

	# The demo city grows into a real city with some towers.
	var d := City.new()
	var t0 := Time.get_ticks_msec()
	d.build_demo()
	var towers := 0
	var big := 0
	for b in d.buildings.values():
		if b.stage == 3:
			towers += 1
		if b.size == 2:
			big += 1
	print("  demo: pop %d, jobs %d, buildings %d, stage-3 %d, 2x2 %d, funds %d, %d ms" % [
		d.population, d.jobs_c + d.jobs_i, d.buildings.size(), towers, big, d.funds, Time.get_ticks_msec() - t0])
	print("  demand R %.2f C %.2f I %.2f, income %.0f expense %.0f" % [d.demand[1], d.demand[2], d.demand[3], d.last_income, d.last_expense])
	check(d.population > 5000, "demo population > 5000")
	check(towers > 20, "demo has towers")
	check(d.last_income > d.last_expense, "demo city is profitable")
	print("FAILED %d" % failures if failures else "ALL PASSED")
	quit(1 if failures else 0)
