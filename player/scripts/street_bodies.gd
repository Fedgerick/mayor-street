class_name StreetBodies
extends Node3D
## Solid stand-ins for citylife's traffic, people and police near the player. Those are
## plain data (MultiMesh drawn), so on their own the player walks and drives through
## them. Each physics frame the closest few get a kinematic box or capsule that follows
## them, and the street layer tells traffic and walkers where the real bodies are:
##   - the player on foot is blocked by cars, cop cars, people and officers;
##   - the player's car hits traffic like a wall; a hard hit swaps the AI car for a real
##     physics car (Traffic.knock_out) that gets shoved, spins and stays as a wreck;
##   - the player's car knocks people and officers down (StreetMode.hurt_person);
##   - a moving AI or cop car that runs into the player on foot hurts and throws them;
##   - traffic brakes for, or steers round, the player, the player's car and parked cars
##     (Traffic.obstacles), and walkers stop and step aside for the player (Crowd.blockers).
## Only things near the player are touched, and selection runs at 10 Hz, so far crowds
## cost nothing.

const TRAFFIC_LAYER := 16     # physics layer 5: stand-ins for AI and cop cars
const PEOPLE_LAYER := 8       # physics layer 4: stand-ins for walkers and officers
const CAR_PROXIES := 16
const PEOPLE_PROXIES := 12
const CAR_RADIUS := 45.0      # AI cars within this of the player get a body
const PEOPLE_RADIUS := 14.0
const OBSTACLE_RADIUS := 70.0
const PICK_INTERVAL := 0.1
const KNOCK_SPEED := 7.0      # closing speed (m/s, about 25 km/h) at which an AI car turns into a real one
const RUN_OVER_SPEED := 3.0   # the player's car hurts people above this
const HIT_PLAYER_SPEED := 3.0 # an AI car hurts the player on foot above this
const MAX_WRECKS := 10        # knocked-out AI cars kept in the world
const WRECK_KEEP := 220.0     # ... and dropped once this far from the player

var street: Node              # StreetMode
var spots: Object = null      # citylife StreetSpots: benches and bus shelters
var signals: Object = null    # citylife Signals: a pole on each junction approach
var traffic: Object = null    # citylife Traffic
var crowd: Object = null      # citylife Crowd
var police: Object = null     # citylife Police

var knocked := 0              # AI cars turned into physics cars (for tests)
var run_over := 0             # people hit by the player's car (for tests)

var _car_bodies: Array[AnimatableBody3D] = []
var _car_of: Array = []        # proxy index -> traffic Car / police CopCar (or null)
var _people_bodies: Array[AnimatableBody3D] = []
var _person_of: Array = []     # proxy index -> crowd Ped / police Officer (or null)
var _pick_timer := 0.0
var _near_cars: Array = []     # [data object, is_cop] picked this round
var _near_people: Array = []   # [data object, is_officer]
var _cooldown := {}            # data object -> seconds before it can be hit again
var _player_hit_cd := 0.0
var _wrecks: Array[Node3D] = []
var _fixtures := {}            # fixture key -> static body RID (benches, shelters, signal poles)
var _fixture_shapes := {}      # shared shape resources, kept alive while bodies use them
var _fixture_key := ""
var _fixture_timer := 0.0
var _fixture_at := Vector3.INF  # flat point the fixtures were gathered round (INF: whole city)
# Only fixtures this near the player get bodies: the whole city's (hundreds of shapes) took
# ~60 ms to rebuild each time the city grew a bus stop, a hitch on Fedge's laptop. Each
# fixture is its own small static body made straight on the physics server, and a move
# only adds the ones that came into range and frees those that left: one StaticBody3D with
# hundreds of CollisionShape3D children still cost 66-86 ms on the laptop (msp 0.4.1).
const FIXTURE_RADIUS := 140.0
const FIXTURE_MOVE := 50.0  # rebuild after the player has gone this far


func setup(street_mode: Node) -> void:
	street = street_mode
	for i in CAR_PROXIES:
		var b := _make_body("Car%d" % i, TRAFFIC_LAYER, BoxShape3D.new())
		_car_bodies.append(b)
		_car_of.append(null)
	for i in PEOPLE_PROXIES:
		var cap := CapsuleShape3D.new()
		cap.radius = 0.28
		cap.height = 1.7
		var b := _make_body("Person%d" % i, PEOPLE_LAYER, cap)
		(b.get_child(0) as CollisionShape3D).position.y = 0.85
		_people_bodies.append(b)
		_person_of.append(null)


func set_life(l: Node) -> void:
	traffic = l.get("traffic") if l else null
	crowd = l.get("crowd") if l else null
	police = l.get("police") if l else null
	spots = l.get("spots") if l else null
	signals = l.get("signals") if l else null
	_fixture_key = ""


func _make_body(nm: String, layer: int, shape: Shape3D) -> AnimatableBody3D:
	var b := AnimatableBody3D.new()
	b.name = nm
	b.collision_layer = layer
	b.collision_mask = 0
	b.sync_to_physics = false   # placed straight from the data every physics frame
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.disabled = true
	b.add_child(cs)
	add_child(b)
	return b


func _physics_process(dt: float) -> void:
	_fixture_timer -= dt
	if _fixture_timer <= 0.0:
		_fixture_timer = 1.0
		_check_fixtures()
	if street == null or traffic == null or not street.active:
		_idle()
		return
	# Worked out on the flat map, where traffic and people live (citylife/); the proxy
	# bodies are stood up on the ball on msp.
	var focus: Vector3 = Planet.flat(street.player_position())
	_pick_timer -= dt
	if _pick_timer <= 0.0:
		_pick_timer = PICK_INTERVAL
		_pick(focus)
	for k in _cooldown.keys():
		_cooldown[k] -= dt
		if _cooldown[k] <= 0.0:
			_cooldown.erase(k)
	_player_hit_cd = maxf(_player_hit_cd - dt, 0.0)
	_place_cars()
	_place_people()
	_feed_obstacles(focus)
	if street.car != null and not street.switching:
		_car_hits(street.car)
	elif not street.player.in_vehicle and not street.player.dead:
		_player_hits()
	_tidy_wrecks(focus)


func _idle() -> void:
	for i in CAR_PROXIES:
		_release_car(i)
	for i in PEOPLE_PROXIES:
		_release_person(i)
	if traffic:
		traffic.obstacles = []
	if crowd:
		crowd.blockers.clear()


# ------------------------------------------------------------------- fixtures ---

func _check_fixtures() -> void:
	var key := "%d/%d" % [spots.spots.size() if spots else -1, signals.heads.size() if signals else -1]
	if street == null or not street.active:
		# Nobody on the street to bump into them.
		if not _fixtures.is_empty():
			_clear_fixtures()
		_fixture_at = Vector3.INF
		_fixture_key = ""
		return
	var at: Vector3 = Planet.flat(street.player_position())
	var moved := not _fixture_at.is_finite() or Vector2(Planet.fdx(_fixture_at.x, at.x), at.z - _fixture_at.z).length() > FIXTURE_MOVE
	if key != _fixture_key or moved:
		_fixture_key = key
		rebuild_fixtures(at)


## Benches, bus shelters and signal poles: a static body each for those within
## FIXTURE_RADIUS of `at` (a flat point), or for the whole city when `at` is INF. Bodies
## already standing are kept, so only the change is paid for.
func rebuild_fixtures(at := Vector3.INF) -> void:
	_fixture_at = at
	if _fixture_shapes.is_empty():
		var bench := BoxShape3D.new()
		bench.size = Vector3(1.8, 0.85, 0.6)
		var panel := BoxShape3D.new()      # shelter back wall
		panel.size = Vector3(3.6, 2.5, 0.15)
		var post := CylinderShape3D.new()  # shelter front posts
		post.radius = 0.08
		post.height = 2.5
		var pole := CylinderShape3D.new()  # signal poles
		pole.radius = 0.12
		pole.height = 3.6
		_fixture_shapes = {"bench": bench, "panel": panel, "post": post, "pole": pole}
	var r2 := FIXTURE_RADIUS * FIXTURE_RADIUS if at.is_finite() else INF
	var want := {}
	if spots:
		for sp in spots.spots:
			var xf: Transform3D = sp.xform
			if r2 < INF and Vector2(Planet.fdx(at.x, xf.origin.x), xf.origin.z - at.z).length_squared() > r2:
				continue
			want[_fixture_id(1 + int(sp.kind), xf.origin)] = [0, xf] if sp.kind == StreetSpots.Kind.BENCH else [1, xf]
	if signals:
		for h in signals.heads:
			var xf: Transform3D = h[2]
			if r2 < INF and Vector2(Planet.fdx(at.x, xf.origin.x), xf.origin.z - at.z).length_squared() > r2:
				continue
			want[_fixture_id(0, xf.origin)] = [2, xf]
	for k in _fixtures.keys():
		if not want.has(k):
			PhysicsServer3D.free_rid(_fixtures[k])
			_fixtures.erase(k)
	if not is_inside_tree():
		return
	var space := get_world_3d().space
	for k in want:
		if _fixtures.has(k):
			continue
		var kind: int = want[k][0]
		var xf: Transform3D = want[k][1]
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(body, 1)
		PhysicsServer3D.body_set_collision_mask(body, 0)
		match kind:
			0:
				_add_shape(body, "bench", xf * Transform3D(Basis.IDENTITY, Vector3(0, 0.42, -0.1)))
			1:
				_add_shape(body, "panel", xf * Transform3D(Basis.IDENTITY, Vector3(0, 1.25, -1.25)))
				for sx in [-1.7, 1.7]:
					_add_shape(body, "post", xf * Transform3D(Basis.IDENTITY, Vector3(sx, 1.25, 0.1)))
			_:
				_add_shape(body, "pole", Transform3D(Basis.IDENTITY, xf.origin + Vector3(0, 1.8, 0)))
		PhysicsServer3D.body_set_space(body, space)
		_fixtures[k] = body


## How many fixture bodies stand now (for tests).
func fixture_count() -> int:
	return _fixtures.size()


func _fixture_id(kind: int, o: Vector3) -> Vector4i:
	return Vector4i(kind, roundi(o.x * 10.0), roundi(o.y * 10.0), roundi(o.z * 10.0))


func _add_shape(body: RID, shape: String, flat_xf: Transform3D) -> void:
	var s: Shape3D = _fixture_shapes[shape]
	PhysicsServer3D.body_add_shape(body, s.get_rid(), Planet.xf_rigid(flat_xf))


func _clear_fixtures() -> void:
	for k in _fixtures:
		PhysicsServer3D.free_rid(_fixtures[k])
	_fixtures.clear()


func _exit_tree() -> void:
	_clear_fixtures()
	_fixture_key = ""
	_fixture_at = Vector3.INF


func _pick(focus: Vector3) -> void:
	var cand: Array = []
	var r2 := CAR_RADIUS * CAR_RADIUS
	for c in traffic.cars:
		var d: float = c.pos.distance_squared_to(focus)
		if d < r2:
			cand.append([d, c, false])
	if police:
		for c in police.cars:
			var d: float = c.pos.distance_squared_to(focus)
			if d < r2:
				cand.append([d, c, true])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	_near_cars.clear()
	for k in mini(cand.size(), CAR_PROXIES):
		_near_cars.append([cand[k][1], cand[k][2]])
	cand.clear()
	r2 = PEOPLE_RADIUS * PEOPLE_RADIUS
	if crowd:
		for p in crowd.peds:
			var d: float = p.pos.distance_squared_to(focus)
			if d < r2:
				cand.append([d, p, false])
	if police:
		for o in police.officers:
			var d: float = o.pos.distance_squared_to(focus)
			if d < r2:
				cand.append([d, o, true])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	_near_people.clear()
	for k in mini(cand.size(), PEOPLE_PROXIES):
		_near_people.append([cand[k][1], cand[k][2]])
	# Keep each data object on the proxy it already has, so bodies don't jump.
	_assign(_car_of, _near_cars, CAR_PROXIES, _release_car)
	_assign(_person_of, _near_people, PEOPLE_PROXIES, _release_person)


func _assign(owner_of: Array, near: Array, count: int, release: Callable) -> void:
	var want := {}
	for n in near:
		want[n[0]] = true
	for i in count:
		if owner_of[i] != null and not want.has(owner_of[i]):
			release.call(i)
	var have := {}
	for i in count:
		if owner_of[i] != null:
			have[owner_of[i]] = true
	var free_i := 0
	for n in near:
		if have.has(n[0]):
			continue
		while free_i < count and owner_of[free_i] != null:
			free_i += 1
		if free_i >= count:
			break
		owner_of[free_i] = n[0]
		free_i += 1


func _release_car(i: int) -> void:
	_car_of[i] = null
	(_car_bodies[i].get_child(0) as CollisionShape3D).disabled = true


func _release_person(i: int) -> void:
	_person_of[i] = null
	(_people_bodies[i].get_child(0) as CollisionShape3D).disabled = true


# ------------------------------------------------------------------ placement ---

## Half extents (x, y, z) of an AI or cop car's box.
func _half(c: Object) -> Vector3:
	var length: float = Traffic.LENGTHS[c.model] if c.get("model") != null else Police.CAR_LEN
	var w := 0.95 if length < 6.0 else 1.3
	var h := 0.8 if length < 6.0 else 1.5
	return Vector3(w, h, length * 0.5)


func _car_xform(c: Object) -> Transform3D:
	var fwd: Vector3 = c.fwd
	var back := -Vector3(fwd.x, 0, fwd.z).normalized()
	var right := Vector3.UP.cross(back)
	return Transform3D(Basis(right, Vector3.UP, back), c.pos)


func _place_cars() -> void:
	for i in CAR_PROXIES:
		var c = _car_of[i]
		if c == null:
			continue
		var body := _car_bodies[i]
		var cs := body.get_child(0) as CollisionShape3D
		var half := _half(c)
		var box := cs.shape as BoxShape3D
		if not box.size.is_equal_approx(half * 2.0):
			box.size = half * 2.0
			cs.position = Vector3(0, 0.3 + half.y, 0)
		body.global_transform = Planet.xf_rigid(_car_xform(c))
		cs.disabled = false


func _place_people() -> void:
	for i in PEOPLE_PROXIES:
		var p = _person_of[i]
		if p == null:
			continue
		var body := _people_bodies[i]
		body.global_transform = Planet.xf_rigid(Transform3D(Basis.IDENTITY, p.pos))
		(body.get_child(0) as CollisionShape3D).disabled = false


# ------------------------------------------------------------------ obstacles ---

func _feed_obstacles(focus: Vector3) -> void:
	var obs: Array = []
	var r2 := OBSTACLE_RADIUS * OBSTACLE_RADIUS
	for v in get_tree().get_nodes_in_group("vehicles"):
		var car := v as DrivableCar
		if car == null or not car.is_inside_tree():
			continue
		var w := car.global_position
		var p := Planet.flat(w)
		if p.distance_squared_to(focus) > r2:
			continue
		var half := _vehicle_half(car)
		obs.append([p, Planet.to_local(w, car.global_basis.x).normalized() * half.x,
			Planet.to_local(w, car.global_basis.z).normalized() * half.z, Planet.to_local(w, car.linear_velocity)])
	if street.car == null and not street.player.in_vehicle:
		var pw: Vector3 = street.player.global_position
		var pp := Planet.flat(pw)
		obs.append([pp, Vector3(0.45, 0, 0), Vector3(0, 0, 0.45), Planet.to_local(pw, street.player.velocity)])
		crowd_block(pp)
	elif crowd:
		crowd.blockers.clear()
	traffic.obstacles = obs
	traffic.obstacle_focus = focus


func crowd_block(p: Vector3) -> void:
	if crowd == null:
		return
	crowd.blockers.clear()
	crowd.blockers.append(p)


static func _vehicle_half(car: DrivableCar) -> Vector3:
	var s = car.get_node_or_null("Shape")
	if s and s.shape is BoxShape3D:
		return (s.shape as BoxShape3D).size * 0.5
	return Vector3(0.95, 0.7, 2.3)


# ----------------------------------------------------------------------- hits ---

## True when two flat boxes (centre, unit axes, half extents) overlap, with a margin.
static func _boxes_touch(pa: Vector3, xa: Vector3, za: Vector3, ha: Vector2, pb: Vector3, xb: Vector3, zb: Vector3, hb: Vector2, margin: float) -> bool:
	var d := Vector3(pb.x - pa.x, 0, pb.z - pa.z)
	for axis in [xa, za, xb, zb]:
		var ra := ha.x * absf(xa.dot(axis)) + ha.y * absf(za.dot(axis))
		var rb := hb.x * absf(xb.dot(axis)) + hb.y * absf(zb.dot(axis))
		if absf(d.dot(axis)) > ra + rb + margin:
			return false
	return true


func _car_hits(car: DrivableCar) -> void:
	# On the flat map, like the AI cars and people it is tested against.
	var cw := car.global_position
	var cp := Planet.flat(cw)
	var bx := Planet.to_local(cw, car.global_basis.x)
	var bz := Planet.to_local(cw, car.global_basis.z)
	var cx := Vector3(bx.x, 0, bx.z).normalized()
	var cz := Vector3(bz.x, 0, bz.z).normalized()
	var ch3 := _vehicle_half(car)
	var ch := Vector2(ch3.x, ch3.z)
	var vel := Planet.to_local(cw, car.linear_velocity)
	# AI cars: a real knock turns the stand-in into a physics car.
	for n in _near_cars.duplicate():
		var c = n[0]
		if n[1]:
			continue   # cop cars stay under police control: solid, but not knocked out
		var xf := _car_xform(c)
		var h := _half(c)
		var rel: Vector3 = vel - (c.fwd as Vector3) * float(c.v)
		var to := Vector3(xf.origin.x - cp.x, 0, xf.origin.z - cp.z)
		var closing: float = rel.dot(to.normalized()) if to.length_squared() > 0.01 else rel.length()
		if closing < KNOCK_SPEED:
			continue
		# Swap in the real car a frame or two before contact, so the crash is between two
		# physics bodies and momentum carries over (the stand-in alone is an immovable wall).
		var margin: float = 0.25 + closing * get_physics_process_delta_time() * 2.0
		if _boxes_touch(cp, cx, cz, ch, xf.origin, xf.basis.x, xf.basis.z, Vector2(h.x, h.z), margin):
			_knock_out(c)
	# People: knocked down by the player's car.
	var speed := Vector3(vel.x, 0, vel.z).length()
	if speed < RUN_OVER_SPEED:
		return
	for n in _near_people.duplicate():
		var p = n[0]
		if _cooldown.has(p):
			continue
		var local := Vector3(p.pos.x - cp.x, 0, p.pos.z - cp.z)
		if absf(local.dot(cx)) > ch.x + 0.3 or absf(local.dot(cz)) > ch.y + 0.3:
			continue
		_cooldown[p] = 1.5
		run_over += 1
		var dmg := speed * speed * 1.2   # ~11 km/h bruises, ~30 km/h kills
		var dir := Planet.dir(cw, Vector3(vel.x, 0, vel.z).normalized() + Vector3.UP * 0.3)  # world, for the hit
		if n[1]:
			street.hurt_officer(p, dmg, dir, &"car")
		else:
			street.hurt_person(p, dmg, dir, &"car")


func _knock_out(c: Object) -> void:
	for i in CAR_PROXIES:
		if _car_of[i] == c:
			_release_car(i)
	for k in _near_cars.size():
		if _near_cars[k][0] == c:
			_near_cars.remove_at(k)
			break
	var info: Dictionary = traffic.knock_out(c)
	var xf: Transform3D = info.xform  # flat map
	var fwd := -xf.basis.z
	var pos := xf.origin
	pos.y = maxf(pos.y, 0.0) + 0.1
	pos = Planet.place(pos)
	fwd = Planet.dir(pos, fwd)
	var lf := Planet.to_local(pos, fwd)
	var wreck: DrivableCar = street.spawn_car(info.model, pos, atan2(lf.x, lf.z), info.tint)
	wreck.set_meta("parked", true)        # someone's car: taking it is still theft
	wreck.set_meta("from_traffic", true)
	wreck.linear_velocity = fwd * float(info.get("v", 0.0))
	wreck.set_meta("hit_by_player", true)
	_wrecks.append(wreck)
	knocked += 1


func _player_hits() -> void:
	## AI and cop cars that run into the player on foot.
	if _player_hit_cd > 0.0:
		return
	var pw: Vector3 = street.player.global_position
	var pp := Planet.flat(pw)
	for n in _near_cars:
		var c = n[0]
		if c.v < HIT_PLAYER_SPEED:
			continue
		var xf := _car_xform(c)
		var h := _half(c)
		var local := Vector3(pp.x - xf.origin.x, 0, pp.z - xf.origin.z)
		if absf(local.dot(xf.basis.x)) > h.x + 0.35 or absf(local.dot(xf.basis.z)) > h.z + 0.35:
			continue
		_player_hit_cd = 1.2
		var fwd: Vector3 = c.fwd
		street.player.hurt(c.v * c.v * 0.5, Planet.place(xf.origin))
		street.player.velocity += Planet.dir(pw, fwd * c.v * 0.9 + Vector3.UP * minf(2.0 + c.v * 0.3, 6.0))
		return


func _tidy_wrecks(focus: Vector3) -> void:
	for w in _wrecks.duplicate():
		if not is_instance_valid(w) or w == street.car:
			_wrecks.erase(w)
			continue
		if Planet.flat(w.global_position).distance_to(focus) > WRECK_KEEP:
			_wrecks.erase(w)
			w.queue_free()
	while _wrecks.size() > MAX_WRECKS:
		var far: Node3D = _wrecks[0]
		for w in _wrecks:
			if Planet.flat(w.global_position).distance_squared_to(focus) > Planet.flat(far.global_position).distance_squared_to(focus):
				far = w
		_wrecks.erase(far)
		far.queue_free()
