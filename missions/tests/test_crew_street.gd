extends SceneTree
## Mission crews against the real street player: models appear, shots and punches land
## through StreetMode.trace_shot, the hit marker shows, they hurt you back, and a good job's
## fight doesn't earn stars for gunfire.
##   godot --headless --path . --script res://missions/tests/test_crew_street.gd

var fails := 0
var t: Node3D


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	print("Crew on the street tests")
	t = load("res://player/test/street_test.tscn").instantiate()
	t.with_life = true
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var p: StreetPlayer = street.player
	t.go_street()
	await frames(int(street.dive_seconds * 60.0) + 40)
	check(street.active, "on the street")

	var link := StreetLink.new(street)
	var crew := MissionCrew.new()
	root.add_child(crew)
	crew.setup(t.city, link)
	var ahead := -street.camera.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized()
	var at := p.global_position + ahead * 8.0
	crew.spawn(at, 1, "pistol")
	var e: MissionCrew.Enemy = crew.enemies[0]
	check(e.model != null and e.model is CharacterModel, "the gunman has a body")

	# A shot along the line to them is a hit on the crew.
	# Shoot from just beside them, so a lamp post or a wall can't get in the way.
	var from := e.pos + Vector3(1.6, 1.3, 0.4)
	var dir := (e.pos + Vector3.UP * 1.2 - from).normalized()
	var hit := street.trace_shot(from, dir, 40.0)
	check(hit.kind == &"target" and hit.target == e, "trace_shot finds the crew (%s)" % hit.kind)
	var hp0 := e.hp
	street.apply_hit(hit, 25.0, dir, &"pistol")
	check(e.hp == hp0 - 25.0, "the hit hurts them (%.0f -> %.0f)" % [hp0, e.hp])
	check(street.hud.hitmark > 0.0, "hit marker shows")
	check(crew.alert, "and the crew is alerted")

	# They shoot back.
	var h0 := p.health + p.armor
	for i in 900:
		await process_frame
		if p.health + p.armor < h0:
			break
	check(p.health + p.armor < h0, "the gunman hurt the player (%.0f -> %.0f, %.0f m apart, clear line %s)" % [
		h0, p.health + p.armor, e.pos.distance_to(p.global_position), crew._clear(e.pos, p.global_position)])

	# Sanctioned gunfire (a good job) isn't reported; ordinary gunfire is.
	street.heat.clear()
	street.sanctioned = true
	street.on_shot_fired(&"pistol", p.global_position)
	await frames(5)
	check(street.wanted == 0, "a good job's gunfire earns no stars")
	street.sanctioned = false

	var died := []
	crew.died.connect(func(x): died.append(x))
	street.apply_hit(street.trace_shot(from, dir, 40.0), 999.0, dir, &"pistol")
	check(e.dead and died.size() == 1, "a big hit puts them down")
	check(street.trace_shot(from, dir, 40.0).kind != &"target", "the dead aren't targets")
	crew.clear()

	print("Crew on the street: %s" % ("all passed" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails else 0)
