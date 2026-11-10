extends SceneTree
## Buildings go up over time: a placed or grown building is first a construction site that
## holds its lot, counts nobody and has no door, then becomes the building.
##   godot --headless --path . -s planet/tests/test_construction.gd -- --demo --nosave

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _free_lot(city: City, size: int) -> Vector2i:
	## An empty lot of size x size tiles with a road along it, near the town.
	var c := city.center_cell()
	for r in range(2, 60):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var cell := Vector2i(posmod(c.x + dx, City.W), c.y + dy)
				var ok := true
				for y in range(cell.y, cell.y + size):
					for x in range(cell.x, cell.x + size):
						if not city.inside(x, y) or city.land[city.idx(x, y)] == 0 or city.road[city.idx(x, y)] == 1 \
								or city.bld[city.idx(x, y)] >= 0 or city.site_at[city.idx(x, y)] >= 0:
							ok = false
				if ok and city.front_side(cell, size) >= 0:
					return cell
	return Vector2i(-1, -1)


func _run() -> void:
	print("construction tests")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	var city: City = main.city
	var view: Node3D = main.view
	var sites: Node3D = view.sites
	check(sites != null and city.sites.is_empty(), "the demo city starts with nothing under construction")
	city.growth_check = func(_x, _y): return false  # nothing grows on its own while this runs
	var stage_of: Callable = sites.get_script().stage
	check(city.animate_growth and city.construction, "live play builds over time")

	# A catalog building.
	var cell := _free_lot(city, 2)
	check(cell.x >= 0, "found an empty 2x2 lot")
	var kind := ""
	for k in ["police_station", "fire_station", "hospital", "school", "bank"]:
		if not Catalog.get_def(k).is_empty() and int(Catalog.get_def(k).size) == 2 and Catalog.get_def(k).placement != "street":
			kind = k
			break
	if kind == "":
		for k in ["park", "small_park", "salvage_yard", "gun_shop"]:
			if not Catalog.get_def(k).is_empty():
				kind = k
				cell = _free_lot(city, int(Catalog.get_def(k).size))
				break
	var size: int = Catalog.get_def(kind).size
	var pop0 := city.population
	var started := [0]
	var added := [0]
	city.site_started.connect(func(_id): started[0] += 1)
	city.building_added.connect(func(_id, _a): added[0] += 1)
	city.funds = 1e7
	if city.progress != null and city.progress.has_method("unlock"):
		city.progress.unlock(kind)
	var id := city.place_special(kind, cell)
	check(id >= 0 and city.sites.has(id) and not city.buildings.has(id), "placing %s starts a site, not a building" % kind)
	check(started[0] == 1 and added[0] == 0, "site_started fired, building_added did not")
	check(city.bld[city.idx(cell.x, cell.y)] < 0 and city.site_at[city.idx(cell.x, cell.y)] == id, "the lot is held by the site")
	check(city.can_place_special(kind, cell, true) != "", "nothing else can be placed on it (%s)" % city.can_place_special(kind, cell, true))
	check(city.specials_of(kind).filter(func(b): return b.id == id).is_empty(), "missions and services don't see it yet")
	await process_frame
	await process_frame
	check(sites.count() == 1, "the site is drawn")
	var s: Dictionary = sites._sites[id]
	check(s.has("bld") and s.h > 2.0, "its building mesh is %.1f m tall" % s.h)
	check(not s.bld.visible, "at the start only the fenced lot shows")
	var body: StaticBody3D = s.body
	check(body.get_child_count() == 1, "the hoarding is solid")

	# Half way: the frame is up part of the way with scaffolding round it.
	var dur: float = city.sites[id].dur
	check(is_equal_approx(dur, city.build_minutes(city.sites[id])) and dur >= 300.0, "the job takes %.0f game hours" % (dur / 60.0))
	city._advance_sites(dur * 0.45)
	await process_frame
	await process_frame
	var st: Dictionary = stage_of.call(city.sites[id].built, s.h)
	check(st.top > 1.0 and st.top < s.h and st.done < st.top, "half way: frame at %.1f m of %.1f, facade to %.1f" % [st.top, s.h, maxf(st.done, 0.0)])
	check(s.bld.visible and s.scaffold.visible and s.cap.visible, "building, scaffold and working deck show")
	check(is_equal_approx(s.bld.get_instance_shader_parameter(&"build_top"), st.top), "the shader cuts the building at the frame height")

	# The stages only ever move forward.
	var mono := true
	var last: Dictionary = stage_of.call(0.0, 60.0)
	for k in range(1, 81):
		var cur: Dictionary = stage_of.call(k / 100.0, 60.0)
		if cur.top < last.top - 0.001 or (k > 8 and cur.done < last.done - 0.001):
			mono = false
		last = cur
	check(mono, "the frame and facade only rise")
	var endst: Dictionary = stage_of.call(0.995, 60.0)
	check(endst.scaffold < 0.0 and endst.crane < 3.0 and endst.done > 60.0, "by the end the scaffold and crane are down")

	# Saved and loaded mid-job.
	var d: Dictionary = JSON.parse_string(JSON.stringify(city.to_dict()))
	var c2 := City.new(city.map_seed)
	check(c2.from_dict(d), "a city with a site loads")
	check(c2.sites.has(id) and absf(c2.sites[id].built - city.sites[id].built) < 0.001 and not c2.buildings.has(id),
		"the site comes back %d%% built" % int(c2.sites.get(id, {}).get("built", 0.0) * 100.0))
	check(c2.site_at[c2.idx(cell.x, cell.y)] == id and c2.population == city.population, "it holds its lot and counts nobody")

	# Finished.
	city._advance_sites(dur * 0.6)
	await process_frame
	check(city.buildings.has(id) and not city.sites.has(id), "when the time is up it is a building")
	check(added[0] == 1 and city.bld[city.idx(cell.x, cell.y)] == id, "building_added fired and the lot is built on")
	check(not city.buildings[id].has("built") and not city.buildings[id].has("dur"), "the entry carries no site fields")
	check(sites.count() == 0, "the site is cleared away")
	check(not city.specials_of(kind).filter(func(b): return b.id == id).is_empty(), "now missions and services see it")

	# A zone building: nobody lives there until it is done.
	var i0 := -1
	for i in city.zone.size():
		if city.zone[i] == City.Zone.RES and city.bld[i] < 0 and city.road[i] == 0 and city.site_at[i] < 0 \
				and city.road_access_dir(i % City.W, i / City.W) >= 0:
			i0 = i
			break
	if i0 < 0:
		# No empty residential lot left: clear one.
		for b in city.buildings.values():
			if b.zone == City.Zone.RES and b.size == 1 and not b.has("kind"):
				i0 = city.idx(b.x, b.y)
				city.remove_building(b.id)
				break
	pop0 = city.population
	var hid := city.add_building(i0 % City.W, i0 / City.W, 1, City.Zone.RES, 1, maxi(city.road_access_dir(i0 % City.W, i0 / City.W), 0))
	check(city.sites.has(hid) and city.population == pop0, "a house going up houses nobody")
	check(is_equal_approx(city.sites[hid].dur, 360.0), "a house takes 6 game hours")
	city.advance(30.0, 1.0)   # half a minute of play at 1x: 3 game hours
	check(city.sites.has(hid) and absf(city.sites[hid].built - 0.5) < 0.02, "the clock moves the job on (%d%% after 3 hours)" % int(city.sites[hid].built * 100.0))
	city.advance(31.0, 1.0)
	var counted := 0
	for b in city.buildings.values():
		if b.zone == City.Zone.RES:
			counted += city.capacity(b)
	check(city.buildings.has(hid) and city.capacity(city.buildings[hid]) > 0 and city.population == counted, "done, and people move in")

	# Bulldozing a site calls the job off.
	var jid := -1
	city.remove_building(hid)
	jid = city.add_building(i0 % City.W, i0 / City.W, 1, City.Zone.RES, 1, 0)
	await process_frame
	check(city.sites.has(jid) and sites.count() == 1, "a new job on the same lot")
	city.funds = 1e6
	check(city.bulldoze(Rect2i(i0 % City.W, i0 / City.W, 1, 1)), "the bulldozer takes a site")
	await process_frame
	check(not city.sites.has(jid) and not city.buildings.has(jid) and city.site_at[i0] < 0 and sites.count() == 0, "the job is called off and the lot is clear")

	# With construction off (tests, the demo) buildings appear as before.
	city.construction = false
	var kid := city.add_building(i0 % City.W, i0 / City.W, 1, City.Zone.RES, 1, 0)
	check(city.buildings.has(kid) and city.sites.is_empty(), "construction off: the building is there at once")
	print("ALL PASSED" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
