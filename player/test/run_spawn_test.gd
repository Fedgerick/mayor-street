extends SceneTree
## Headless check that the player never lands on a street lamp or signal pole:
##   godot --headless -s res://player/test/run_spawn_test.gd
## Every sidewalk spot StreetMode picks (enter, respawn, drops) must clear the lamp posts
## by the player's capsule radius. Exits with code 1 on any failure.

const CAPSULE_RADIUS := 0.3
const POLE_RADIUS := 0.14

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


func _run() -> void:
	var scene: PackedScene = load("res://player/test/street_test.tscn")
	t = scene.instantiate()
	t.with_life = true
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var city: City = t.city
	var col: CityCollision = street.collision
	var bad := 0
	var checked := 0
	var worst := INF
	for y in City.SIZE:
		for x in City.SIZE:
			if not city.is_road(x, y):
				continue
			var c := city.cell_center(x, y)
			var spot := street.sidewalk_spawn(c)
			checked += 1
			var d := INF
			for body in col.get_children():
				for cs in body.get_children():
					if cs is CollisionShape3D and cs.shape is CylinderShape3D:
						var o: Vector3 = cs.global_position
						d = minf(d, Vector2(o.x - spot.x, o.z - spot.z).length())
			worst = minf(worst, d)
			if d < CAPSULE_RADIUS + POLE_RADIUS:
				bad += 1
	print("spawn spots checked %d, on or inside a pole %d, closest pole %.2f m" % [checked, bad, worst])
	check(checked > 0, "the demo city has road cells to spawn on")
	check(bad == 0, "no sidewalk spawn lands on a street lamp or signal pole")
	print("\n%s" % ("ALL PASSED" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails > 0 else 0)
