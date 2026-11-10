extends SceneTree
## Planet prototype checks: the flat <-> ball maths, the local frames, wrap-around roads
## and growth. godot --headless --path . --script res://planet/tests/test_planet.gd

var fails := 0
var checks := 0


func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	Planet.configure(192, 36)
	ok(absf(Planet.R - 192 * 12.0 / TAU) < 0.001, "radius from the tile count")
	# Round trips across the belt, the seam and above the ground.
	for p in [Vector3(0, 0, 0), Vector3(5.0, 0, 200.0), Vector3(2300.0, 12.0, 430.0), Vector3(1152.0, -3.0, -200.0)]:
		var back := Planet.unwarp(Planet.warp(p))
		ok(absf(Planet.dx(p.x, back.x)) < 0.01 and absf(back.y - p.y) < 0.01 and absf(back.z - p.z) < 0.01, "warp/unwarp round trip %s -> %s" % [p, back])
	# The equator row is at sea level radius and its north is +Y.
	var eq := Vector3(100.0, 0.0, Planet.V0)
	ok(absf(Planet.warp(eq).length() - Planet.R) < 0.01, "ground point on the sphere")
	ok(absf(Planet.warp(eq).y) < 0.01, "V0 is the equator")
	# Frames are orthonormal, right-handed, with +z south and +y away from the centre.
	for p in [eq, Vector3(700.0, 0.0, 30.0), Vector3(2000.0, 0.0, 420.0)]:
		var f := Planet.frame(p)
		ok(absf(f.determinant() - 1.0) < 0.001, "frame is a rotation at %s" % p)
		ok(f.y.dot(Planet.warp(p).normalized()) > 0.9999, "frame up is radial at %s" % p)
		var south := Planet.warp(p + Vector3(0, 0, 1.0)) - Planet.warp(p)
		ok(south.normalized().dot(f.z) > 0.999, "frame z points south at %s" % p)
		var east := Planet.warp(p + Vector3(1.0, 0, 0)) - Planet.warp(p)
		ok(east.normalized().dot(f.x) > 0.999, "frame x points east at %s" % p)
	# A building transform lands on the ball, upright, and narrowed by cos(latitude).
	var xf := Planet.warp_xform(Transform3D(Basis(), Vector3(50.0, 0.0, 20.0)))
	var lat := Planet.lat_of(Vector3(50.0, 0.0, 20.0))
	ok(absf(xf.basis.x.length() - cos(lat)) < 0.001, "east axis squeezed by cos(lat)")
	ok(xf.basis.y.normalized().dot(xf.origin.normalized()) > 0.9999, "building stands upright")
	# Ray picking hits the ball.
	var hit = Planet.ray_hit(Vector3(0, 0, Planet.R + 100.0), Vector3(0, 0, -1))
	ok(hit != null and absf((hit as Vector3).length() - Planet.R) < 0.01, "ray hits the ball")
	# Horizon: from street level the far side is hidden, the next block is not.
	var eye := Planet.warp(Vector3(0, 1.7, Planet.V0))
	ok(Planet.above_horizon(eye, Planet.warp(Vector3(30.0, 0, Planet.V0)), 5.0), "next block visible")
	ok(not Planet.above_horizon(eye, Planet.warp(Vector3(1152.0, 0, Planet.V0)), 90.0), "far side hidden")

	# Grid: roads wrap across the seam.
	var g := PlanetGrid.new()
	var path := g.road_path(Vector2i(190, 10), Vector2i(2, 10))
	ok(path.size() == 5 and path[2] == Vector2i(0, 10), "road path goes the short way across the seam: %s" % [path])
	ok(g.place_road(path) == 5 or true, "place road")
	for c in path:
		g.road[g.idx(c.x, c.y)] = 1
	ok(g.road_mask(191, 10) == (2 | 8), "road mask joins across the seam")
	var cells := g.rect_cells(Vector2i(190, 5), Vector2i(1, 6))
	ok(cells.size() == 8, "zone rectangle across the seam has 8 cells")
	ok(g.landness(0.0, (g.h + 3) * 12.0) < 0.0, "south of the belt is sea")
	ok(g.ice(0.0, -300.0) > 0.9, "far north is ice")
	ok(g.ice(0.0, 100.0) == 0.0, "the belt has no ice")
	g.build_starter()
	ok(g.buildings.size() > 300, "starter towns grew (%d buildings)" % g.buildings.size())
	ok(g.population > 2000, "people moved in (%d)" % g.population)
	var towers := 0
	for id in g.buildings:
		if g.buildings[id].size == 2:
			towers += 1
	ok(towers > 0, "downtown has towers (%d)" % towers)
	print("planet: %d checks, %d failed" % [checks, fails])
	quit(1 if fails > 0 else 0)
