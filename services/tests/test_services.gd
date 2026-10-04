extends SceneTree
## Headless checks for city services:
##   godot --headless --path . --script res://services/tests/test_services.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _init() -> void:
	print("City services tests")
	var c := City.new()
	c.build_starter()
	c.funds = 200000.0
	var s := CityServices.new(c)
	var mid := c.center_cell()

	# A strip of homes along the avenue, nothing powered yet.
	c.place_zone(Rect2i(mid.x - 12, mid.y + 1, 10, 2), City.Zone.RES)
	c.place_zone(Rect2i(mid.x + 2, mid.y + 1, 8, 2), City.Zone.COM)
	c.place_zone(Rect2i(mid.x + 2, mid.y - 2, 8, 2), City.Zone.IND)
	s.update()
	check(s.power[c.idx(mid.x - 5, mid.y + 1)] == 1, "zoned lot without a plant has no power")
	check(s.growth_ok(c.idx(mid.x - 5, mid.y + 1)), "a tiny city may still grow without power")

	check(s.can_place("coal_plant", Vector2i(mid.x, mid.y)) != "", "nothing goes on a road")

	# A coal plant next to the avenue powers the whole connected network.
	var plant_at := Vector2i(mid.x - 12, mid.y - 2)
	var f0 := c.funds
	var pid := s.place_facility("coal_plant", plant_at)
	check(pid > 0, "coal plant placed")
	check(c.funds < f0, "coal plant costs money")
	check(c.buildings[pid].kind == "coal_plant" and c.buildings[pid].zone == City.Zone.NONE, "plant is a zone-less building with a kind")
	check(s.stations("power").size() == 1, "one power station listed")
	check(s.power[c.idx(mid.x - 5, mid.y + 1)] == 2, "zoned lot on the grid is powered")
	check(s.power[c.idx(mid.x + 20, mid.y)] == 2, "avenue far away is powered too (roads conduct)")

	c.simulate_hours(24 * 12)
	s.update()
	check(c.population > 0, "homes grew (%d people)" % c.population)
	var unpowered := 0
	for b in c.buildings.values():
		if not b.get("powered", true):
			unpowered += 1
	check(unpowered == 0, "every building is powered (%d without)" % unpowered)
	check(s.power_pct > 99.0, "power 100%% (%.1f)" % s.power_pct)
	check(s.demand_mw > 0.0 and s.supply_mw == 80.0, "supply 80 MW, demand %.1f MW" % s.demand_mw)

	# Capacity: a tiny supply can't power everything, nearest buildings first.
	s.supply_scale = s.demand_mw * 0.4 / 80.0
	s.update()
	check(s.power_pct < 60.0 and s.power_pct > 10.0, "short supply powers part of the city (%.0f%%)" % s.power_pct)
	s.supply_scale = 1.0
	s.update()

	# An island grid with no plant: a power line joins it.
	var far := Vector2i(mid.x - 2, mid.y + 12)
	c.place_road(c.road_path(far + Vector2i(-6, 0), far + Vector2i(-6, 4)))
	s.update()
	var island := c.idx(far.x - 6, far.y + 4)
	check(s.power[island] == 1, "a road not joined to the grid has no power")
	var gap_from := Vector2i(mid.x, mid.y + 12)  # end of the starter cross street
	check(s.place_power_line(c.road_path(gap_from, far + Vector2i(-6, 0))), "power line placed")
	check(s.power[island] == 2, "power line carries power to it")
	check(s.bulldoze_lines(Rect2i(far.x - 5, far.y, 4, 1)) > 0, "bulldoze removes power lines")
	check(s.power[island] == 1, "and the island goes dark again")

	# Coverage: police station covers around it, falling off with distance.
	var pol := s.place_facility("police_station", Vector2i(mid.x + 12, mid.y + 1))
	check(pol > 0, "police station placed")
	var near := c.cell_center(mid.x + 13, mid.y + 3)
	var away := c.cell_center(mid.x - 12, mid.y + 1)
	check(s.coverage_at("police", near) > 0.8, "police coverage next to the station (%.2f)" % s.coverage_at("police", near))
	check(s.coverage_at("police", away) == 0.0, "no police coverage across town")
	var ps := s.police_stations()
	check(ps.size() == 1 and ps[0].id == pol, "police station list has it")
	check(ps[0].door.distance_to(ps[0].center) < 30.0, "station door is on a nearby road")

	# Garbage: no depot -> piles; a depot clears them.
	c.simulate_hours(24 * 6)
	check(s.garbage_pct < 1.0, "no depot, no garbage collected (%.0f%%)" % s.garbage_pct)
	check(not s.garbage_piles().is_empty(), "uncollected garbage shows as piles (%d)" % s.garbage_piles().size())
	var dep := s.place_facility("garbage_depot", Vector2i(mid.x - 1, mid.y - 4))
	check(dep > 0, "garbage depot placed")
	c.simulate_hours(24 * 6)
	check(s.garbage_pct > 95.0, "depot collects it (%.0f%%)" % s.garbage_pct)
	check(s.garbage_piles().is_empty(), "piles are gone")

	# Stats and growth hooks.
	var st := s.stats()
	check(st.happiness > 0.0 and st.approval > 0.0, "happiness %.0f, approval %.0f, crime %.0f" % [st.happiness, st.approval, st.crime])
	check(st.income_per_resident > 0.0, "income per resident $%d" % int(st.income_per_resident))
	var pk := s.place_facility("small_park", Vector2i(mid.x - 7, mid.y - 1))
	check(pk > 0 and s.land_value_delta(c.idx(mid.x - 8, mid.y - 1)) > 0.05, "park raises land value nearby")

	# Bulldozing a service building removes it from the lists.
	c.bulldoze(Rect2i(mid.x + 12, mid.y + 1, 2, 2))
	check(s.police_stations().is_empty(), "bulldozed police station is gone from the list")

	# Unpowered decay: a city past the grace size with its plant gone empties out slowly.
	var b0 := c.buildings.size()
	c.bulldoze(Rect2i(plant_at, Vector2i(3, 3)))
	c.simulate_hours(24 * 9)
	check(s.power_pct == 0.0, "no plant, no power")
	check(c.population < 400 and c.buildings.size() <= b0, "unpowered buildings empty out (%d people)" % c.population)

	# Save and load round trip.
	var d := s.to_dict()
	var s2 := CityServices.new(c)
	s2.from_dict(JSON.parse_string(JSON.stringify(d)))
	check(s2.facilities.size() == s.facilities.size(), "facilities found again after load (%d)" % s2.facilities.size())
	check(s2.power_line == s.power_line, "power lines saved")

	# Demo city: services cover it.
	var dc := City.new()
	dc.build_demo(24 * 30)
	var ds := CityServices.new(dc)
	var t0 := Time.get_ticks_usec()
	ds.build_demo_services()
	print("  demo services placed in %d ms" % ((Time.get_ticks_usec() - t0) / 1000))
	t0 = Time.get_ticks_usec()
	ds._dirty_power = true
	ds._dirty_cov = true
	ds.update()
	print("  full recompute %d ms" % ((Time.get_ticks_usec() - t0) / 1000))
	dc.simulate_hours(24 * 3)
	var ds_st := ds.stats()
	print("  demo: pop %d, power %.0f%% (%.0f/%.0f MW), garbage %.0f%%, crime %.0f, happy %.0f, approval %.0f, income $%d" % [
		dc.population, ds_st.power_pct, ds_st.demand_mw, ds_st.supply_mw, ds_st.garbage_pct, ds_st.crime,
		ds_st.happiness, ds_st.approval, int(ds_st.income_per_resident)])
	check(ds_st.power_pct > 95.0, "demo city is powered")
	check(ds.police_stations().size() >= 3, "demo city has police stations (%d)" % ds.police_stations().size())

	print("FAILURES: %d" % failures)
	quit(1 if failures > 0 else 0)
