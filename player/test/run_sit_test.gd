extends SceneTree
## Headless check that the player never comes back to the street stuck in the car seat pose:
##   godot --headless -s res://player/test/run_sit_test.gd
## Wasted in a car, Busted in a car, killed halfway into a car, and going up to the mayor
## view halfway into a car must all leave the player standing. Exits with code 1 on any failure.

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


func _standing(street: StreetMode, what: String) -> void:
	var p := street.player
	var v := p.visual
	check(not v._sitting and v._sit < 0.01, "%s: standing, not in the seat pose (sit %.2f)" % [what, v._sit])
	check(not p.in_vehicle and not p.puppet and p.visible and street.car == null and not street.switching,
		"%s: on foot (in_vehicle=%s puppet=%s visible=%s car=%s switching=%s)" % [what, p.in_vehicle, p.puppet, p.visible, street.car, street.switching])


func _car_by(street: StreetMode) -> DrivableCar:
	var p := street.player
	return street.spawn_car("car_sedan", p.global_position + p.rig.forward_flat() * 4.0 + Vector3.UP * 0.3,
		p.rig.yaw + 1.2, Color(0.15, 0.3, 0.7))


func _seated(street: StreetMode, c: DrivableCar) -> void:
	street._enter_car(c)
	for i in 600:
		if not street.switching:
			break
		await physics_frame
	await frames(20)


func _run() -> void:
	var scene: PackedScene = load("res://player/test/street_test.tscn")
	t = scene.instantiate()
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var p: StreetPlayer = street.player
	t.go_street()
	await frames(int(street.dive_seconds * 60.0) + 40)
	check(street.active, "on the street")

	# --- Wasted while driving ---------------------------------------------------------
	await _seated(street, _car_by(street))
	check(p.in_vehicle and p.visual._sitting, "seated in the car")
	p.hurt(999.0)
	await frames(60 * 7)
	check(not street.down, "back from the hospital")
	await frames(30)
	_standing(street, "Wasted in a car")

	# --- Busted while driving ---------------------------------------------------------
	await _seated(street, _car_by(street))
	street.set_wanted(1)
	street.bust()
	await frames(60 * 7)
	check(not street.down, "out of the cells")
	await frames(30)
	_standing(street, "Busted in a car")

	# --- Killed halfway into a car ------------------------------------------------------
	street._enter_car(_car_by(street))
	await frames(8)
	check(street.switching, "getting into the car")
	p.hurt(999.0)
	await frames(60 * 7)
	await frames(30)
	_standing(street, "killed while getting in")

	# --- Mayor view halfway into a car, then back down ---------------------------------------
	street._enter_car(_car_by(street))
	await frames(8)
	t.go_mayor()
	for i in 900:
		if not street.busy:
			break
		await physics_frame
	check(not street.active and not street.busy, "up in the mayor view")
	t.go_street()
	await frames(int(street.dive_seconds * 60.0) + 40)
	check(street.active, "back on the street")
	_standing(street, "left for the mayor view while getting in")

	print("\n%s (%d failed)" % ["ALL PASS" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
