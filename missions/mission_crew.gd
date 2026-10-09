class_name MissionCrew
extends Node3D
## Armed people a job puts on the street: guards, gang members, a hit target and their
## bodyguards. They stand around until the player comes close (or one of them gets hurt),
## then fight: gunmen keep a few metres off and shoot when they can see you, brawlers run
## in and punch. Driving into one at speed knocks them down for good.
##
## The player's shots find them through the "street_targets" group: StreetMode.trace_shot
## asks every node in it for `targets()` (things with a `pos`) and calls `hurt()` on a hit.
## Without a StreetMode (tests) nothing renders and `hurt()` / `kill_all()` stand in.

signal died(e: Enemy)
signal fired(pos: Vector3)

const AGGRO_M := 32.0          # they notice you this close
const SIGHT_M := 40.0          # and shoot this far, with a clear line
const KEEP_M := 9.0            # gunmen hold off at about this range
const RUN := 4.6
const WALK := 1.6
const PUNCH_M := 1.4
const CORPSE_SECONDS := 25.0
const RUN_OVER_SPEED := 6.0    # m/s: a car this fast through one of them is a kill

class Enemy:
	extends RefCounted
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD
	var home := Vector3.ZERO
	var hp := 60.0
	var armed := true
	var boss := false
	var name := ""
	var dead := false
	var alert := false
	var speed := 0.0
	var shoot := 1.0
	var model: Node3D = null

var city: City
var link: StreetLink
var enemies: Array[Enemy] = []
var alert := false
var _next_shot := 0.0
var _time := 0.0
var _rng := RandomNumberGenerator.new()


func setup(c: City, l: StreetLink) -> void:
	city = c
	link = l
	_rng.randomize()
	add_to_group("street_targets")


## Puts `count` of them around `at` on the sidewalk. `armed`: "pistol", "fists" or "mixed".
## A `boss` name adds one tougher, named target (counted in `count`).
func spawn(at: Vector3, count: int, armed := "pistol", boss := "", hp := 60.0) -> void:
	for i in count:
		var e := Enemy.new()
		var ang := TAU * float(i) / maxf(1.0, count) + _rng.randf_range(-0.3, 0.3)
		var p := at + Vector3(cos(ang), 0.0, sin(ang)) * _rng.randf_range(2.0, 6.0)
		e.pos = link.ground_point(p) if link else p
		e.home = e.pos
		e.fwd = Vector3(-cos(ang), 0, -sin(ang))
		e.armed = armed == "pistol" or (armed == "mixed" and i % 2 == 0)
		e.hp = hp
		e.shoot = _rng.randf_range(0.6, 1.8)
		if boss != "" and i == 0:
			e.boss = true
			e.name = boss
			e.hp = hp * 2.5
			e.armed = true
		e.model = _make_model(e)
		enemies.append(e)


func alive() -> int:
	var n := 0
	for e in enemies:
		if not e.dead:
			n += 1
	return n


func boss_alive() -> bool:
	for e in enemies:
		if e.boss and not e.dead:
			return true
	return false


func nearest(to: Vector3) -> Enemy:
	## The one to point the player at: the hit target while they live, else the closest.
	var best: Enemy = null
	var bd := INF
	for e in enemies:
		if e.dead:
			continue
		if e.boss:
			return e
		var d := e.pos.distance_squared_to(to)
		if d < bd:
			bd = d
			best = e
	return best


func targets() -> Array:
	## For StreetMode.trace_shot: everyone still standing.
	var out := []
	for e in enemies:
		if not e.dead:
			out.append(e)
	return out


func hurt(e: Enemy, damage: float, dir := Vector3.ZERO, _weapon := &"") -> void:
	if e.dead:
		return
	e.hp -= damage
	_alert_all()
	if is_inside_tree():
		StreetFx.puff(self, e.pos + Vector3.UP * 1.2, Color(0.6, 0.02, 0.02, 0.95), 0.1, 0.4)
	if e.hp <= 0.0:
		_kill(e, dir)
	elif e.model and e.model.has_method("play_hit"):
		e.model.play_hit()


func kill_all() -> void:
	for e in enemies:
		if not e.dead:
			_kill(e, Vector3.ZERO)


func clear() -> void:
	for e in enemies:
		if e.model and is_instance_valid(e.model):
			e.model.queue_free()
	enemies.clear()
	alert = false


func _kill(e: Enemy, dir: Vector3) -> void:
	e.dead = true
	e.speed = 0.0
	if e.model and is_instance_valid(e.model):
		var away := Vector3(dir.x, 0.0, dir.z)
		if away.length() > 0.01:
			e.model.global_basis = Basis.looking_at(-away.normalized(), Vector3.UP)
		e.model.set_aim(CharacterModel.Aim.NONE)
		e.model.set_dead(true)
		var m := e.model
		get_tree().create_timer(CORPSE_SECONDS).timeout.connect(func():
			if is_instance_valid(m):
				m.queue_free())
		e.model = null
	died.emit(e)


func _alert_all() -> void:
	alert = true
	for e in enemies:
		e.alert = true


# ------------------------------------------------------------------- update ---

func _process(delta: float) -> void:
	tick(delta)


func tick(delta: float) -> void:
	if enemies.is_empty() or link == null:
		return
	_time += delta
	var me := link.position()
	var outside := link.inside() == "" and link.active()
	var in_car := link.car() != null
	for e in enemies:
		if e.dead:
			continue
		var to := Vector3(me.x - e.pos.x, 0.0, me.z - e.pos.z)
		var d := to.length()
		if outside and d < AGGRO_M:
			_alert_all()
		if outside and in_car and d < 2.4 and link.car_speed() > RUN_OVER_SPEED:
			hurt(e, 999.0, to.normalized() * -1.0)
			continue
		var want := 0.0
		var goal := e.home
		if e.alert and outside:
			goal = me
			if e.armed:
				want = RUN if d > KEEP_M + 4.0 else (WALK if d > KEEP_M else 0.0)
			else:
				want = RUN if d > PUNCH_M else 0.0
		else:
			var back := e.home - e.pos
			back.y = 0.0
			want = WALK if back.length() > 1.0 else 0.0
			to = back
		e.speed = move_toward(e.speed, want, 10.0 * delta)
		if to.length() > 0.01:
			var dir := to.normalized()
			e.fwd = e.fwd.slerp(dir, minf(1.0, delta * 8.0)).normalized()
			if e.speed > 0.0:
				e.pos = _walk(e.pos, dir * e.speed * delta)
		if e.alert and outside:
			_attack(e, me, d, delta)
		if e.model and is_instance_valid(e.model):
			e.model.global_position = e.pos
			if e.fwd.length_squared() > 0.01:
				e.model.global_basis = Basis.looking_at(e.fwd, Vector3.UP)
			e.model.set_aim(CharacterModel.Aim.PISTOL if e.armed and e.alert else CharacterModel.Aim.NONE)
			e.model.animate(delta, e.speed, true, 0.0, 0.0)


func _attack(e: Enemy, me: Vector3, d: float, delta: float) -> void:
	e.shoot -= delta
	if e.shoot > 0.0:
		return
	if not e.armed:
		if d < PUNCH_M:
			e.shoot = _rng.randf_range(0.8, 1.2)
			if e.model and e.model.has_method("play_punch"):
				e.model.play_punch()
			link.damage_player(7.0, e.pos)
		return
	if _time < _next_shot or d > SIGHT_M or not _clear(e.pos, me):
		return
	# Shots across the whole crew are spaced out, so five gunmen don't drop you in a second.
	e.shoot = _rng.randf_range(1.3, 2.4)
	_next_shot = _time + 0.45
	e.speed = 0.0
	fired.emit(e.pos)
	if _rng.randf() < 0.55 - d * 0.012:
		link.damage_player(8.0 if e.boss else 5.0, e.pos)


func _clear(a: Vector3, b: Vector3) -> bool:
	## No building lot between them (the same test the police use).
	if city == null:
		return true
	var dist := Vector2(b.x - a.x, b.z - a.z).length()
	var steps := int(dist / (City.TILE * 0.4)) + 1
	for k in range(1, steps):
		var cell := city.world_to_cell(a.lerp(b, float(k) / steps))
		if city.inside(cell.x, cell.y) and city.bld[city.idx(cell.x, cell.y)] >= 0:
			return false
	return true


func _walk(p: Vector3, step: Vector3) -> Vector3:
	## Move without walking into building lots; slide along them instead.
	if city == null:
		return p + step
	for cand in [step, Vector3(step.x, 0, 0), Vector3(0, 0, step.z)]:
		var q: Vector3 = p + cand
		var c := city.world_to_cell(q)
		if not city.inside(c.x, c.y) or city.bld[city.idx(c.x, c.y)] < 0:
			return q
	return p


func _make_model(e: Enemy) -> Node3D:
	if link == null or link.street == null or not CharacterModel.available():
		return null
	var m := CharacterModel.new()
	m.seed_value = _rng.randi()
	add_child(m)
	var shirt := Color(0.55, 0.08, 0.1) if not e.boss else Color(0.12, 0.12, 0.13)
	m.set_outfit({"top": "jacket" if e.boss else ("hoodie" if _rng.randf() < 0.6 else "tee"),
		"bottom": "jeans", "hat": "" if e.boss else ("beanie" if _rng.randf() < 0.4 else ""),
		"colors": {"Shirt": shirt, "Jacket": Color(0.1, 0.1, 0.11) if not e.boss else Color(0.2, 0.18, 0.16),
			"Pants": Color(0.12, 0.12, 0.14), "Hat": Color(0.08, 0.08, 0.09)}})
	m.global_position = e.pos
	return m
