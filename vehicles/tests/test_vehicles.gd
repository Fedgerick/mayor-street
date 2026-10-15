extends SceneTree
## Headless checks for the car kit:
##   godot --headless --path . -s res://vehicles/tests/test_vehicles.gd
## Every model loads at every LOD and damage stage, stays inside its triangle budget,
## uses at most two surfaces with the vehicle shaders, and has specs the game can use.

const BUDGET := [7000, 1750, 450]          # cars (LOD0 ~6k, LOD1 ~1.5k, LOD2 ~300)
const BIG_BUDGET := [8500, 1900, 500]      # bus, trucks, fire engine
const BIG := ["car_bus", "car_truck", "car_garbage", "car_firetruck", "car_ambulance", "car_tow"]

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func tris(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return n


func _initialize() -> void:
	var mats := VehicleKit.materials()
	for model in VehicleKit.MODELS:
		var budget: Array = BIG_BUDGET if model in BIG else BUDGET
		for lod in 3:
			var m := VehicleKit.mesh(model, lod)
			check(m != null, "%s lod%d loads" % [model, lod])
			if m == null:
				continue
			var t := tris(m)
			check(t <= budget[lod], "%s lod%d has %d triangles (budget %d)" % [model, lod, t, budget[lod]])
			check(m.get_surface_count() <= (2 if lod == 0 else 1), "%s lod%d surfaces %d" % [model, lod, m.get_surface_count()])
			for s in m.get_surface_count():
				check(m.surface_get_material(s) in mats, "%s lod%d surface %d uses a vehicle shader" % [model, lod, s])
			print("  %-14s lod%d %5d tris" % [model, lod, t])
		for stage in [1, 2, 3]:
			var d := VehicleKit.damaged(model, stage)
			check(d != null, "%s damage %d loads" % [model, stage])
		var sp := VehicleKit.spec(model)
		check(not sp.is_empty(), "%s has specs" % model)
		if sp.is_empty():
			continue
		var lod0 := VehicleKit.mesh(model)
		var box := lod0.get_aabb()
		# Faces -Z, sits on the ground, size matches its specs.
		check(absf(box.position.y) < 0.05, "%s sits on the ground (min y %.2f)" % [model, box.position.y])
		check(absf(box.size.z - float(sp.length)) < 0.6, "%s length %.2f vs spec %.2f" % [model, box.size.z, sp.length])
		check(sp.axles[0].z < 0.0 and sp.axles[0].steer, "%s front axle is at -Z and steers" % model)
	# The four old kit names still exist with the same axles the drivable car expects.
	var old := {"car_sedan": [1.4, -1.35, 0.36], "car_hatch": [1.1, -1.05, 0.36], "car_van": [1.6, -1.55, 0.36], "car_truck": [2.6, -2.55, 0.48]}
	for k in old:
		var sp := VehicleKit.spec(k)
		check(is_equal_approx(-float(sp.axles[0].z), old[k][0]) and is_equal_approx(-float(sp.axles[1].z), old[k][1]) and is_equal_approx(float(sp.wheel_radius), old[k][2]),
			"%s keeps the old axle layout" % k)
	# Custom data packing.
	var c := VehicleKit.custom(true, true, true, false, 7.0, 0.2, 0.5)
	check(int(c.r) == VehicleKit.SIREN | VehicleKit.BRAKE | VehicleKit.EMPTY, "custom flags")
	check(is_equal_approx(c.g, fmod(7.0, TAU)) and is_equal_approx(c.b, 0.2) and is_equal_approx(c.a, 0.5), "custom wheel/steer/seed")
	check(VehicleKit.lod_for(5.0) == 0 and VehicleKit.lod_for(50.0) == 1 and VehicleKit.lod_for(200.0) == 2, "lod_for")
	# Drop-in install into something shaped like the Kit autoload.
	var fake := FakeKit.new()
	VehicleKit.install(fake)
	check(fake.meshes.has("car_sedan") and fake.meshes.has("car_firetruck_lod2") and fake.meshes.has("car_bus_dmg3"), "install fills Kit.meshes")
	fake.free()
	print("vehicles: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails else 0)


class FakeKit extends Node:
	var meshes := {}
