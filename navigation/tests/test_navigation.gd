extends SceneTree
## Headless checks for navigation/:  godot --headless --path . --script res://navigation/tests/test_navigation.gd

var failures := 0


class FakeStreet:
	extends Node
	var active := true
	var wanted := 0
	var pos := Vector3.ZERO
	func player_position() -> Vector3:
		return pos


class FakeMissions:
	extends Node
	var phones: Array[Vector3] = []


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	_run.call_deferred()  # nodes join the tree once it is running


func _run() -> void:
	print("Navigation tests")
	var city := City.new()
	city.animate_growth = false
	city.build_demo(24 * 20)
	check(city.population > 100, "demo city grew (%d people)" % city.population)

	# The map picture: sea in the corner, a road tile's middle is road grey.
	var img := MapPainter.paint(city)
	check(img.get_width() == City.SIZE * MapPainter.PX, "map is %d px across" % img.get_width())
	check(_same(img.get_pixel(1, 1), MapPainter.SEA), "corner is sea")
	var roads: Array[Vector2i] = []
	for y in City.SIZE:
		for x in City.SIZE:
			if city.is_road(x, y):
				roads.append(Vector2i(x, y))
	check(roads.size() > 20, "demo has roads (%d tiles)" % roads.size())
	var rc := roads[roads.size() / 2]
	var mid := img.get_pixel(rc.x * MapPainter.PX + MapPainter.PX / 2, rc.y * MapPainter.PX + MapPainter.PX / 2)
	check(_same(mid, MapPainter.ROAD), "road tile middle is road grey")

	# Repainting just a changed patch gives the same picture as painting it all again.
	var lot := Vector2i(-1, -1)
	for y in range(10, City.SIZE - 10):
		for x in range(10, City.SIZE - 10):
			var i := city.idx(x, y)
			if lot.x < 0 and city.bld[i] < 0 and city.can_place_special("police_station", Vector2i(x, y), true) == "":
				lot = Vector2i(x, y)
	check(lot.x >= 0, "found an empty lot by a road")
	var placed := city.place_special("police_station", lot, -1, true)
	check(placed >= 0, "placed a special building")
	var r := Rect2i(lot - Vector2i(3, 3), Vector2i(8, 8))
	MapPainter.paint_rect(img, city, r)
	var fresh := MapPainter.paint(city)
	check(img.get_data() == fresh.get_data(), "patch repaint matches a full repaint")

	# GPS: a route along the roads between two far apart road tiles that join up.
	var gps := GpsRoute.new(city)
	var a := roads[0]
	var dist := _reach(city, a)
	var b := a
	for c in roads:
		if dist[city.idx(c.x, c.y)] > dist[city.idx(b.x, b.y)]:
			b = c
	var path := gps.find(a, b)
	check(path.size() == dist[city.idx(b.x, b.y)] + 1, "route is the shortest (%d tiles)" % path.size())
	var ok := true
	for i in range(1, path.size()):
		if not city.is_road(path[i].x, path[i].y) or (path[i] - path[i - 1]).length_squared() != 1:
			ok = false
	check(ok, "every step is onto a neighbouring road tile")
	gps.update(city.cell_center(a.x, a.y), city.cell_center(b.x, b.y))
	check(gps.points.size() >= 2 and gps.reachable, "route has points (%d)" % gps.points.size())
	check(absf(gps.length_m - (path.size() - 1) * City.TILE) < City.TILE * 1.01, "route length %.0f m" % gps.length_m)
	var off := gps.nearest_road(Vector2i(lot.x, lot.y))
	check(off.x >= 0 and city.is_road(off.x, off.y), "nearest road to a lot")

	# CityNav: marks, priorities, waypoint and saves, driven by a fake street.
	var street := FakeStreet.new()
	street.pos = city.cell_center(a.x, a.y)
	root.add_child(street)
	var missions := FakeMissions.new()
	missions.phones = [city.cell_center(roads[3].x, roads[3].y)]
	root.add_child(missions)
	var nav := CityNav.new()
	root.add_child(nav)
	nav.setup(city, street, {"missions": missions})
	check(CityNav.find(self) == nav, "CityNav.find locates it")
	nav._process(0.016)
	check(nav.minimap.visible, "minimap shows at street level")
	check(nav.gps_target_id() == "", "no GPS target to start")
	var far_p := city.cell_center(b.x, b.y)
	nav.mark("mission:goal", far_p, {"color": Color.RED})
	nav.mark("side", city.cell_center(roads[5].x, roads[5].y), {"priority": -1})
	nav._process(0.016)
	check(nav.gps_target_id() == "mission:goal", "GPS goes to the higher-priority mark")
	check(nav.route_length() > 0.0, "route length %.0f m" % nav.route_length())
	check(nav.route_color() == Color.RED, "route takes the mark's colour")
	var kinds := {}
	for bl in nav.blips:
		kinds[bl.kind] = true
	check(kinds.has("phone") and kinds.has("job") and kinds.has("place"), "blips: phone, job, place (%s)" % str(kinds.keys()))
	nav.set_waypoint(city.cell_center(roads[7].x, roads[7].y))
	nav._process(0.016)
	check(nav.gps_target_id() == "waypoint", "a waypoint beats marks")
	var saved := nav.to_dict()
	nav.clear_waypoint()
	check(not nav.waypoint.is_finite(), "waypoint cleared")
	nav.from_dict(saved)
	check(nav.waypoint.is_finite(), "waypoint comes back from a save")
	street.pos = nav.waypoint + Vector3(3, 0, 0)
	nav._process(0.016)
	check(not nav.waypoint.is_finite(), "waypoint clears on arrival")
	nav.unmark_prefix("mission:")
	nav._process(0.016)
	check(nav.gps_target_id() == "side", "GPS falls back to the remaining mark")
	nav.mark("pickup", street.pos + Vector3(5, 0, 0), {"radius": 10.0, "gps": false})
	nav._process(0.016)
	check(not nav.has_mark("pickup"), "a mark with a radius clears when reached")
	var follow := Node3D.new()
	root.add_child(follow)
	follow.global_position = far_p
	nav.mark("car", follow, {"kind": "car", "priority": 5})
	nav._process(0.016)
	check(nav.gps_target_id() == "car", "a mark can follow a node")
	follow.free()
	nav._process(0.016)
	check(nav.gps_target_id() == "side", "a freed node drops out")
	check(nav.place_name(city.door_position(city.buildings[placed])) != "", "special building name on hover")

	# The map screen opens and closes, pausing the game only when it paused it.
	nav.open_map()
	check(nav.map_open and paused, "map opens and pauses")
	nav.close_map()
	check(not nav.map_open and not paused, "map closes and unpauses")
	street.active = false
	nav._process(0.016)
	check(not nav.minimap.visible, "no minimap in the mayor view")

	print("%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)


static func _same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


static func _reach(city: City, from: Vector2i) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(City.SIZE * City.SIZE)
	dist.fill(-1)
	var start := city.idx(from.x, from.y)
	dist[start] = 0
	var q := PackedInt32Array([start])
	var head := 0
	while head < q.size():
		var i := q[head]
		head += 1
		for d: Vector2i in City.DIRS:
			var x := i % City.SIZE + d.x
			var y := i / City.SIZE + d.y
			if city.is_road(x, y) and dist[city.idx(x, y)] == -1:
				dist[city.idx(x, y)] = dist[i] + 1
				q.append(city.idx(x, y))
	return dist
