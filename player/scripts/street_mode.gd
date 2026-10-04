class_name StreetMode
extends Node3D
## Street level in one node: the character, the street camera, enterable cars, collision
## built from the City, and a small HUD. The mayor view stays outside; it hands over with
## `enter_street()` and takes the camera back after `exit_street()`.
##
## Integration (main scene):
##     var street := preload("res://player/scenes/street_mode.tscn").instantiate()
##     add_child(street)
##     street.setup(city)
##     # Mayor -> street, dropping onto whatever the mayor camera looks at:
##     street.enter_street(mayor_camera, mayor_camera.focus)
##     # Street -> mayor: give the transform/FOV the mayor camera should end on.
##     street.exit_street(mayor_target_xform, mayor_camera.fov)
##     street.street_exited.connect(func(): mayor_camera.make_current())
##     street.set_life(life)         # traffic, people and police (carjacking, cops, targets)
##
## Street action (round 2): fists, pistol and shotgun (StreetCombat), health and armor,
## pickups, carjacking, car damage, wanted stars (Wanted, in `heat`), and Wasted / Busted
## with a respawn at the hospital or police station that costs some cash.
##
## For the police (citylife/Police) this node is the suspect: `wanted_stars`,
## `suspect_position()`, `suspect_velocity()`, `suspect_in_vehicle()`; they can call
## `damage_player()` and `bust()`. For missions/: `wanted`, `set_wanted()`, and the
## signals `wanted_changed`, `crime`, `goodness_action`, `wasted`, `busted`.

signal street_entered
signal street_exited
signal vehicle_changed(car: DrivableCar)
signal wanted_changed(stars: int)
signal crime(kind: StringName)              # every crime the player commits (Wanted.CRIMES kinds)
signal goodness_action(kind: StringName)    # Goodness.ACTIONS kinds: steal_car, hit_person, kill_person, hit_cop, flee_police
signal wasted
signal busted

const CAR_MODELS := ["car_sedan", "car_hatch", "car_van", "car_sedan", "car_truck"]
const CAR_COLORS := [Color(0.85, 0.12, 0.1), Color(0.95, 0.95, 0.95), Color(0.12, 0.12, 0.14), Color(0.15, 0.3, 0.7),
	Color(0.7, 0.72, 0.75), Color(0.95, 0.75, 0.1), Color(0.1, 0.45, 0.3), Color(0.55, 0.1, 0.15)]

@export var dive_seconds := 3.2
@export var rise_seconds := 2.6
@export var parked_cars_per_drop := 4
@export var enter_radius := 3.2
@export var carjack_radius := 4.5
@export var pickups_per_drop := 4

const PED_HEALTH := 40.0
const OFFICER_HEALTH := 70.0
const MAX_CORPSES := 10
const CORPSE_SECONDS := 40.0
const WASTED_FEE := [0.1, 100]   # fraction of cash, minimum
const BUSTED_FEE := [0.2, 150]
const BLAST_RADIUS := 8.0

var city: City
var player: StreetPlayer
var camera: StreetCamera
var collision: CityCollision
var car: DrivableCar = null         # the car being driven, if any
var active := false                 # player has control at street level
var busy := false                   # a zoom is playing
var switching := false              # getting into or out of a car
var down := false                   # Wasted or Busted is playing
var heat: Wanted                    # wanted level; `wanted` / `wanted_stars` read it
var combat: StreetCombat
var hud: StreetHud
var life: Node = null               # CityLife, for traffic, people and police
var hospitals: Array[Vector3] = []  # respawn overrides; otherwise read from the city
var stations: Array[Vector3] = []
## Optional: where Busted wakes the player instead of the station door, e.g.
## `func(): await interiors.enter("police", null, "busted")` (the cells inside).
var busted_wake: Callable

var wanted: int:
	get: return heat.level if heat else 0
var wanted_stars: int:
	get: return wanted

var _hud: CanvasLayer
var _hint: Label
var _speedo: Label
var _cars_root: Node3D
var _rng := RandomNumberGenerator.new()
var _fx_root: Node3D
var _corpses: Array[Node3D] = []
var _hp := {}                        # Ped / Officer -> health left
var _shot_report := 0.0
var _panic_report := 0.0
var _local_cash := 250              # used when there is no Progress autoload (tests)
var _last_stars := 0


func _ready() -> void:
	StreetInput.ensure()
	_rng.seed = 4242
	_cars_root = Node3D.new()
	_cars_root.name = "Cars"
	add_child(_cars_root)
	player = StreetPlayer.new()
	player.name = "Player"
	add_child(player)
	player.interact_requested.connect(_on_interact)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	player.died.connect(_on_player_died)
	camera = StreetCamera.new()
	camera.name = "StreetCamera"
	add_child(camera)
	_fx_root = Node3D.new()
	_fx_root.name = "Fx"
	add_child(_fx_root)
	heat = Wanted.new()
	heat.name = "Wanted"
	add_child(heat)
	heat._witness_check = _witnessed
	heat.wanted_changed.connect(_on_wanted_changed)
	combat = StreetCombat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self)
	_build_hud()
	player.damaged.connect(func(a, _from): hud.hurt(a))


func setup(c: City) -> void:
	city = c
	collision = CityCollision.new()
	collision.name = "Collision"
	add_child(collision)
	collision.setup(c)
	var progress := _progress()
	if progress and progress.has_method("register_section"):
		progress.register_section("street", self)


func set_life(l: Node) -> void:
	## CityLife: traffic to carjack, people and police to fight, and the cops who chase.
	life = l
	if l == null:
		return
	if l.has_method("set_suspect"):
		l.set_suspect(self)
	var police = l.get("police")
	if police and police.has_signal("busted") and not police.busted.is_connected(bust):
		police.busted.connect(bust)


func set_respawn_points(hospital_points: Array, police_points: Array) -> void:
	## Optional overrides; by default these come from buildings tagged hospital / police.
	hospitals.assign(hospital_points)
	stations.assign(police_points)


# ------------------------------------------------------------------ mode switch ---

func enter_street(from_camera: Camera3D, ground_point: Vector3) -> void:
	if busy or active:
		return
	busy = true
	var spot := sidewalk_spawn(ground_point)
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.visible = true
	refresh_perks()
	player.set_in_vehicle(false)
	player.set_controls(false)
	# Face the way the mayor camera looks, so the dive swings in from the same side.
	var f := -from_camera.global_basis.z
	var yaw := atan2(-f.x, -f.z)
	player.place(spot, yaw)
	player.rig.pitch = deg_to_rad(-14.0)
	player.rig.snap()
	if parked_cars_per_drop > 0:
		spawn_parked_cars_near(spot, parked_cars_per_drop)
	if pickups_per_drop > 0:
		scatter_pickups(spot, pickups_per_drop)
	camera.make_current()
	camera.dive_to(player.rig, from_camera.global_transform, from_camera.fov, dive_seconds)
	await camera.flight_finished
	busy = false
	active = true
	player.set_controls(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	street_entered.emit()


func can_exit() -> bool:
	## The mayor view is off limits mid-chase and while Wasted or Busted plays.
	return active and not busy and not down and wanted == 0


func exit_street(to: Transform3D, to_fov := 45.0) -> void:
	if busy or not active:
		return
	if not can_exit():
		if wanted > 0:
			hud.note("Lose the cops first")
		return
	busy = true
	active = false
	if car:
		_leave_car()
	player.set_controls(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	camera.rise_to(to, to_fov, rise_seconds)
	await camera.flight_finished
	busy = false
	player.process_mode = Node.PROCESS_MODE_DISABLED
	street_exited.emit()


func focus_point() -> Vector3:
	## Where the mayor camera should centre when returning.
	return car.global_position if car else player.global_position


func view_yaw() -> float:
	return (car.rig.yaw if car else player.rig.yaw)


# ----------------------------------------------------------------------- cars ---

func _on_interact() -> void:
	if not active or switching or down or player.dead:
		return
	var best := _free_car_near()
	if best:
		_enter_car(best)
		return
	var tc = _traffic_car_near()
	if tc:
		_carjack(tc)


func _free_car_near() -> DrivableCar:
	var best: DrivableCar = null
	var best_d := enter_radius
	for v in get_tree().get_nodes_in_group("vehicles"):
		var d: float = (v as Node3D).global_position.distance_to(player.global_position)
		if d < best_d and v.driver == null and not v.wrecked:
			best = v
			best_d = d
	return best


func _traffic_car_near() -> Object:
	## A slow or stopped AI car close enough to pull the driver out of.
	if life == null or life.get("traffic") == null:
		return null
	var tc = life.traffic.nearest_car(player.global_position, carjack_radius)
	if tc and absf(tc.v) < 6.0:
		return tc
	return null


func _carjack(tc: Object) -> void:
	## Swap the AI car for a real one, haul the driver out (citylife/ spawns them running
	## off) and take the wheel.
	switching = true
	player.set_puppet(true)
	var info: Dictionary = life.traffic.take_car(tc)
	var xf: Transform3D = info.xform
	var fwd := -xf.basis.z
	var pos := xf.origin
	pos.y = maxf(pos.y, 0.0) + 0.15
	var c := spawn_car(info.model, pos, atan2(fwd.x, fwd.z), info.tint)
	c.set_meta("player_owned", true)
	_commit(&"carjack", pos)
	goodness_action.emit(&"steal_car")
	await get_tree().physics_frame
	# Step to the door facing the car, then the haul-out.
	var door := c.exit_point() - Vector3.UP * 0.2
	var start := player.global_position
	var side := -c.global_basis.x
	var face := atan2(-side.x, -side.z)
	var steps := maxi(int(start.distance_to(door) / 3.5 * 60.0), 4)
	for i in steps:
		var k := float(i + 1) / steps
		player.global_position = start.lerp(door, k)
		player.face(lerp_angle(player.facing_yaw(), face, k))
		player.visual.animate(1.0 / 60.0, 3.0, true, 0.0, 0.0)
		await get_tree().physics_frame
	player.visual.play_carjack()
	var t := 0.0
	var dur := player.visual.clip_length("Carjack") * 0.9
	while t < dur:
		t += get_physics_process_delta_time()
		player.visual.animate(get_physics_process_delta_time(), 0.0, true, 0.0, 0.0)
		await get_tree().physics_frame
	switching = false
	if down or player.dead:
		player.set_puppet(false)
		return
	_enter_car(c)


func _unhandled_input(e: InputEvent) -> void:
	if active and car and not switching and not down and e.is_action_pressed("street_interact"):
		get_viewport().set_input_as_handled()
		if absf(car.speed()) < 6.0:
			_leave_car()
	if active and e is InputEventKey and e.pressed and e.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	if active and e is InputEventMouseButton and e.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _enter_car(c: DrivableCar) -> void:
	## Step to the driver's door, duck into the seat, then take the wheel.
	if switching:
		return
	switching = true
	car = c
	if c.get_meta("parked", false) and not c.get_meta("player_owned", false):
		_commit(&"car_theft", c.global_position)
		goodness_action.emit(&"steal_car")
	c.set_meta("player_owned", true)
	c.handling = float(perk("car_handling", 1.0))
	c.set_driver(player)        # the car is ours now; input is ignored until we're seated
	c.set_physics_process(false)
	vehicle_changed.emit(c)
	player.set_puppet(true)
	player.rig.spring.add_excluded_object(c.get_rid())   # don't let the car squash the camera
	var door := c.exit_point() - Vector3.UP * 0.2
	var seat := c.seat_point()
	var yaw := c.heading_yaw()
	# A quick turn-and-step to the door if we're not already there.
	var start := player.global_position
	var steps := maxi(int(start.distance_to(door) / 3.0 * 60.0), 4)
	for i in steps:
		var k := float(i + 1) / steps
		player.global_position = start.lerp(door, k)
		player.face(lerp_angle(player.facing_yaw(), yaw, k))
		player.visual.animate(1.0 / 60.0, 2.5, true, 0.0, 0.0)
		await get_tree().physics_frame
	player.visual.set_sitting(true)
	player.visual.play_enter_car()
	var dur := player.visual.clip_length("EnterCar")
	var t := 0.0
	while t < dur:
		t += get_physics_process_delta_time()
		var k := clampf(t / dur, 0.0, 1.0)
		player.global_position = door.lerp(c.seat_point(), k * k * (3.0 - 2.0 * k))
		player.face(c.heading_yaw())
		await get_tree().physics_frame
	camera.blend_to(c.rig, 0.8)
	player.rig.spring.remove_excluded_object(c.get_rid())
	player.set_in_vehicle(true)
	c.set_physics_process(true)
	switching = false


func _leave_car() -> void:
	if switching:
		return
	switching = true
	var c := car
	car = null
	var p := c.exit_point()
	# If the door side is blocked, try the other side, then the roof.
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.7
	q.shape = cap
	q.exclude = [c.get_rid()]
	var door_side := true
	for cand in [p, p - c.global_basis.x * (c._aabb.size.x + 1.4), c.global_position + Vector3.UP * (c._aabb.size.y + 1.0)]:
		q.transform = Transform3D(Basis.IDENTITY, cand + Vector3.UP * 0.9)
		if space.intersect_shape(q, 1).is_empty():
			p = cand
			break
		door_side = false
	c.set_driver(null)
	player.set_in_vehicle(false)
	player.set_puppet(true)
	player.rig.spring.add_excluded_object(c.get_rid())
	player.rig.yaw = c.rig.yaw
	player.rig.pitch = clampf(c.rig.pitch, player.rig.min_pitch, player.rig.max_pitch)
	camera.blend_to(player.rig, 0.9)
	vehicle_changed.emit(null)
	player.face(c.heading_yaw())
	if door_side:
		player.visual.set_sitting(false)
		player.visual.play_exit_car()
		var seat := c.seat_point()
		var dur := player.visual.clip_length("ExitCar")
		var t := 0.0
		while t < dur:
			t += get_physics_process_delta_time()
			var k := clampf(t / dur, 0.0, 1.0)
			player.global_position = seat.lerp(p - Vector3.UP * 0.2, k * k * (3.0 - 2.0 * k))
			player.face(c.heading_yaw())
			await get_tree().physics_frame
	else:
		player.visual.set_sitting(false)
	player.place(p, c.heading_yaw())
	player.set_puppet(false)
	player.rig.spring.remove_excluded_object(c.get_rid())
	player.set_controls(active or busy)
	switching = false


func spawn_car(model: String, pos: Vector3, yaw: float, color: Color) -> DrivableCar:
	var c := DrivableCar.new()
	c.model = model
	c.tint = color
	_cars_root.add_child(c)
	c.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	c.exploded.connect(_on_car_exploded)
	return c


func spawn_parked_cars_near(p: Vector3, count: int) -> void:
	## Park a few cars at the kerb of nearby straight roads so there's always a ride.
	if city == null:
		return
	var existing := 0
	for v in get_tree().get_nodes_in_group("vehicles"):
		if (v as Node3D).global_position.distance_to(p) < 40.0:
			existing += 1
	var need := count - existing
	if need <= 0:
		return
	var origin := city.world_to_cell(p)
	var spots: Array = []
	for r in range(0, 5):
		for y in range(origin.y - r, origin.y + r + 1):
			for x in range(origin.x - r, origin.x + r + 1):
				if maxi(absi(x - origin.x), absi(y - origin.y)) != r or not city.is_road(x, y):
					continue
				var m := city.road_mask(x, y)
				if m == 2 | 8 or m == 1 | 4:
					spots.append(Vector2i(x, y))
	for s in spots:
		if need <= 0:
			break
		var cell: Vector2i = s
		var m := city.road_mask(cell.x, cell.y)
		var c := city.cell_center(cell.x, cell.y)
		var side := 1.0 if _rng.randf() < 0.5 else -1.0
		var pos: Vector3
		var yaw: float
		if m == 2 | 8:   # road runs along X: park at a kerb, drive on the right
			pos = c + Vector3(_rng.randf_range(-2.5, 2.5), 0.15, side * 2.75)
			yaw = PI * 0.5 if side > 0.0 else -PI * 0.5
		else:            # along Z
			pos = c + Vector3(side * 2.75, 0.15, _rng.randf_range(-2.5, 2.5))
			yaw = 0.0 if side < 0.0 else PI
		var clear := true
		for v in get_tree().get_nodes_in_group("vehicles"):
			if (v as Node3D).global_position.distance_to(pos) < 6.0:
				clear = false
		if not clear:
			continue
		var model: String = CAR_MODELS[_rng.randi() % CAR_MODELS.size()]
		var parked := spawn_car(model, pos, yaw, CAR_COLORS[_rng.randi() % CAR_COLORS.size()])
		parked.set_meta("parked", true)   # someone else's: taking it is theft
		need -= 1


func sidewalk_spawn(p: Vector3) -> Vector3:
	## Nearest sidewalk to a ground point, or the point itself if there are no roads.
	if city == null:
		return p + Vector3.UP * 0.3
	var o := city.world_to_cell(p)
	for r in range(0, 12):
		var best := Vector3.ZERO
		var best_d := INF
		for y in range(o.y - r, o.y + r + 1):
			for x in range(o.x - r, o.x + r + 1):
				if maxi(absi(x - o.x), absi(y - o.y)) != r or not city.is_road(x, y):
					continue
				var c := city.cell_center(x, y)
				var m := city.road_mask(x, y)
				for cand in [Vector3(4.9, 0, 4.9), Vector3(-4.9, 0, 4.9), Vector3(4.9, 0, -4.9), Vector3(-4.9, 0, -4.9),
						Vector3(0, 0, 4.9) if not (m & 4) else Vector3(4.9, 0, 0),
						Vector3(0, 0, -4.9) if not (m & 1) else Vector3(-4.9, 0, 0)]:
					var w: Vector3 = c + cand
					var d := w.distance_squared_to(p)
					if d < best_d:
						best_d = d
						best = w
		if best_d < INF:
			return best + Vector3.UP * 0.3
	return p + Vector3.UP * 0.3


# ------------------------------------------------------------------------ HUD ---

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "HUD"
	add_child(_hud)
	hud = StreetHud.new()
	hud.name = "Status"
	hud.street = self
	_hud.add_child(hud)
	_hint = _label(22, HORIZONTAL_ALIGNMENT_CENTER)
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_top = -70
	_hint.offset_bottom = -36
	_speedo = _label(44, HORIZONTAL_ALIGNMENT_RIGHT)
	_speedo.anchor_left = 1.0
	_speedo.anchor_right = 1.0
	_speedo.anchor_top = 1.0
	_speedo.anchor_bottom = 1.0
	_speedo.offset_left = -320
	_speedo.offset_right = -40
	_speedo.offset_top = -110
	_speedo.offset_bottom = -40


func _label(size: int, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0.05, 0.06, 0.1, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(l)
	return l


func _process(delta: float) -> void:
	_hud.visible = active or down
	_shot_report = maxf(_shot_report - delta, 0.0)
	_panic_report = maxf(_panic_report - delta, 0.0)
	var police = life.get("police") if life else null
	if police and wanted > 0 and police.seen:
		heat.report_seen(Vector3.ZERO, suspect_position())
	if not active:
		return
	if down:
		_hint.text = ""
		_speedo.text = ""
		return
	if car:
		var kmh := absf(car.speed()) * 3.6
		_speedo.text = "%d km/h" % roundi(kmh)
		_hint.text = "E  get out" if absf(car.speed()) < 6.0 and not switching else ""
		camera.fov_boost = clampf(absf(car.speed()) / 35.0, 0.0, 1.0)
	else:
		_speedo.text = ""
		camera.fov_boost = 0.0
		var near := false
		for v in get_tree().get_nodes_in_group("vehicles"):
			if (v as Node3D).global_position.distance_to(player.global_position) < enter_radius:
				near = true
				break
		_hint.text = "E  get in" if near and not switching else ""
		if not near and not switching and _traffic_car_near() != null:
			_hint.text = "E  carjack"


# ------------------------------------------------------------- suspect (police) ---

func suspect_position() -> Vector3:
	return focus_point()


func suspect_velocity() -> Vector3:
	return car.linear_velocity if car else player.velocity


func suspect_in_vehicle() -> bool:
	return car != null


func player_position() -> Vector3:
	return focus_point()


func player_vehicle() -> DrivableCar:
	return car


func is_player_dead() -> bool:
	return player.dead


func set_wanted(stars: int) -> void:
	## Missions: a bank job starts the getaway at 3 stars.
	heat.set_level(stars)


func damage_player(amount: float, from_pos := Vector3.ZERO, _source := "") -> void:
	## Police (or anything else) hurting the player. In a car the car soaks it.
	if down or not active:
		return
	if car:
		car.take_hit(amount * 3.0, from_pos)
	else:
		player.hurt(amount, from_pos)


func _on_wanted_changed(level: int) -> void:
	if level == 0 and _last_stars > 0 and not down:
		goodness_action.emit(&"flee_police")   # got away
		hud.note("Lost them")
	_last_stars = level
	wanted_changed.emit(level)


func _commit(kind: StringName, pos: Vector3) -> void:
	heat.commit(kind, pos)
	crime.emit(kind)


func _witnessed(pos: Vector3) -> bool:
	## Somebody saw it: a pedestrian within 30 m or a cop within 60 m.
	if life == null:
		return true
	var crowd = life.get("crowd")
	if crowd:
		for p in crowd.peds:
			if p.pos.distance_squared_to(pos) < 900.0:
				return true
	var police = life.get("police")
	if police:
		for o in police.officers:
			if o.pos.distance_squared_to(pos) < 3600.0:
				return true
		for c in police.cars:
			if c.pos.distance_squared_to(pos) < 3600.0:
				return true
	return false


# ---------------------------------------------------------------------- combat ---

func can_fight() -> bool:
	return active and not busy and not switching and not down and car == null \
		and not player.dead and not player.puppet and not player.in_vehicle


func trace_shot(from: Vector3, dir: Vector3, reach: float, melee := false) -> Dictionary:
	## What a shot from `from` along `dir` hits first: the world, a car, a person or an
	## officer. Returns {kind, pos, target}; kind is &"none" when nothing is in reach.
	var out := {"kind": &"none", "pos": from + dir * reach, "target": null, "t": reach}
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * reach, 1 | DrivableCar.LAYER, [player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		var t := from.distance_to(hit.position)
		out = {"kind": &"car" if hit.collider is DrivableCar else &"world", "pos": hit.position,
			"target": hit.collider if hit.collider is DrivableCar else null, "t": t, "normal": hit.normal}
	var radius := 0.55 if melee else 0.32
	if life:
		var crowd = life.get("crowd")
		if crowd:
			for p in crowd.peds:
				var t := _ray_person(from, dir, p.pos, radius)
				if t >= 0.0 and t < out.t:
					out = {"kind": &"ped", "pos": from + dir * t, "target": p, "t": t}
		var police = life.get("police")
		if police:
			for o in police.officers:
				var t := _ray_person(from, dir, o.pos, radius)
				if t >= 0.0 and t < out.t:
					out = {"kind": &"officer", "pos": from + dir * t, "target": o, "t": t}
	return out


static func _ray_person(from: Vector3, dir: Vector3, base: Vector3, radius: float) -> float:
	## Distance along the ray to a standing person (a vertical capsule), or -1.
	var d := Vector2(dir.x, dir.z)
	var dd := d.length_squared()
	if dd < 1e-6:
		return -1.0
	var w := Vector2(from.x - base.x, from.z - base.z)
	var t := -w.dot(d) / dd
	if t < 0.0:
		return -1.0
	var miss := (w + d * t).length()
	if miss > radius:
		return -1.0
	# Back off to where the ray enters the capsule, and check the height.
	t = maxf(t - sqrt(maxf(radius * radius - miss * miss, 0.0)) / sqrt(dd), 0.0)
	var y := from.y + dir.y * t - base.y
	return t if y > 0.05 and y < 1.85 else -1.0


func apply_hit(hit: Dictionary, damage: float, dir: Vector3, weapon: StringName) -> void:
	var gun := weapon != &"fists"
	match hit.kind:
		&"world":
			StreetFx.puff(_fx_root, hit.pos, Color(0.75, 0.72, 0.66, 0.9), 0.14, 0.4)
		&"car":
			var c: DrivableCar = hit.target
			c.take_hit(damage * (2.5 if gun else 0.4), hit.pos, dir)
			StreetFx.puff(_fx_root, hit.pos, Color(1.0, 0.85, 0.4, 1.0), 0.06, 0.25)
			if c != car and not c.get_meta("hit_by_player", false):
				c.set_meta("hit_by_player", true)
				_commit(&"vehicle_damage", hit.pos)
		&"ped":
			hurt_person(hit.target, damage, dir, weapon)
		&"officer":
			hurt_officer(hit.target, damage, dir, weapon)


func on_shot_fired(_weapon: StringName, pos: Vector3) -> void:
	## Gunfire is a crime when someone hears it, and it clears the sidewalks.
	if _shot_report <= 0.0:
		_shot_report = 3.0
		_commit(&"shots_fired", pos)
	_scare(pos, 3)


func _scare(pos: Vector3, severity: int) -> void:
	if life and life.has_method("report_crime") and _panic_report <= 0.0:
		_panic_report = 0.5
		life.report_crime(pos, severity)


func hurt_person(p: Object, damage: float, dir: Vector3, weapon := &"fists") -> void:
	var hp: float = _hp.get(p, PED_HEALTH) - damage
	var at: Vector3 = p.pos + Vector3.UP * 1.2
	StreetFx.puff(_fx_root, at, Color(0.6, 0.02, 0.02, 0.95), 0.1, 0.4)
	if hp <= 0.0:
		_hp.erase(p)
		_spawn_corpse(p.pos, dir, p.outfit, false)
		life.crowd.remove(p)
		_commit(&"murder", p.pos)
		goodness_action.emit(&"kill_person")
	else:
		_hp[p] = hp
		if p.get("hero"):
			p.hero.play_hit()
		_commit(&"assault", p.pos)
		goodness_action.emit(&"hit_person")
	_scare(p.pos, 1 if weapon == &"fists" else 3)


func hurt_officer(o: Object, damage: float, dir: Vector3, _weapon := &"fists") -> void:
	var hp: float = _hp.get(o, OFFICER_HEALTH) - damage
	StreetFx.puff(_fx_root, o.pos + Vector3.UP * 1.2, Color(0.6, 0.02, 0.02, 0.95), 0.1, 0.4)
	goodness_action.emit(&"hit_cop")
	if hp <= 0.0:
		_hp.erase(o)
		_spawn_corpse(o.pos, dir, 777, true)
		var police = life.police
		if police.has_method("kill_officer"):
			police.kill_officer(o)
		else:
			police._remove_officer(o)
		_commit(&"cop_killed", o.pos)
	else:
		_hp[o] = hp
		if o.model:
			o.model.play_hit()
		_commit(&"cop_assault", o.pos)


func _spawn_corpse(pos: Vector3, dir: Vector3, outfit: int, cop: bool) -> void:
	if not CharacterModel.available():
		return
	var m := CharacterModel.new()
	m.seed_value = outfit
	_fx_root.add_child(m)
	if cop:
		Police._uniform(m)
	# Fall away from the hit.
	var away := Vector3(dir.x, 0.0, dir.z)
	var yaw := atan2(away.x, away.z) if away.length() > 0.01 else randf() * TAU
	m.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, maxf(pos.y, 0.05), pos.z))
	m.set_dead(true)
	_corpses.append(m)
	while _corpses.size() > MAX_CORPSES:
		var old: Node3D = _corpses.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	get_tree().create_timer(CORPSE_SECONDS).timeout.connect(func():
		if is_instance_valid(m):
			_corpses.erase(m)
			m.queue_free())


func _on_car_exploded(c: DrivableCar) -> void:
	## The blast hurts everything near it and can set off other cars.
	var at := c.global_position
	var by_player: bool = c.get_meta("hit_by_player", false) or c == car
	camera.shake(clampf(1.4 - player.global_position.distance_to(at) / 40.0, 0.0, 1.2))
	if c == car:
		_eject(c)
		player.hurt(1000.0, at)
	elif not player.in_vehicle:
		var d := player.global_position.distance_to(at)
		if d < BLAST_RADIUS:
			player.hurt(160.0 * (1.0 - d / BLAST_RADIUS), at)
			player.velocity += (player.global_position - at).normalized() * 6.0 + Vector3.UP * 4.0
	if life:
		var crowd = life.get("crowd")
		if crowd:
			for p in crowd.peds.duplicate():
				if p.pos.distance_to(at) < BLAST_RADIUS * 0.7:
					if by_player:
						hurt_person(p, 999.0, p.pos - at)
					else:
						_spawn_corpse(p.pos, p.pos - at, p.outfit, false)
						crowd.remove(p)
		var police = life.get("police")
		if police:
			for o in police.officers.duplicate():
				if o.pos.distance_to(at) < BLAST_RADIUS * 0.7:
					hurt_officer(o, 999.0, o.pos - at)
		_scare(at, 3)
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v != c and not v.wrecked:
			var d: float = v.global_position.distance_to(at)
			if d < BLAST_RADIUS:
				v.take_hit(900.0 * (1.0 - d / BLAST_RADIUS), at)
				v.apply_central_impulse((v.global_position - at).normalized() * v.mass * 3.0 + Vector3.UP * v.mass * 2.0)


# --------------------------------------------------------------------- pickups ---

func spawn_pickup(kind: StringName, pos: Vector3, respawn := 45.0) -> Pickup:
	## For missions too: a one-off drop when respawn is 0.
	var p := Pickup.new()
	p.kind = kind
	p.respawn_seconds = respawn
	p.street = self
	_fx_root.add_child(p)
	p.global_position = pos
	return p


func scatter_pickups(around: Vector3, count: int) -> void:
	## Make sure there are a few pickups on the sidewalks within a short walk.
	var near := 0
	for p in get_tree().get_nodes_in_group("pickups"):
		if (p as Node3D).global_position.distance_to(around) < 140.0:
			near += 1
	for i in range(near, count):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(20.0, 90.0)
		var at := sidewalk_spawn(around + Vector3(cos(a), 0.0, sin(a)) * r)
		spawn_pickup(Pickup.KINDS[i % Pickup.KINDS.size()], at - Vector3.UP * 0.12)


func try_pickup(kind: StringName) -> bool:
	if down or player.dead:
		return false
	var ok := false
	match kind:
		&"health":
			ok = player.heal(50.0 * player.heal_rate)
		&"armor":
			ok = player.add_armor(StreetPlayer.MAX_ARMOR)
		_:
			ok = combat.give(kind)
	if ok:
		hud.note(String(kind).capitalize())
	return ok


# ------------------------------------------------------------- wasted / busted ---

func _progress() -> Node:
	return get_node_or_null("/root/Progress")


func perk(key: String, default: Variant = 0) -> Variant:
	## A background perk from the created character (creator/ ResidentProfile).
	var p := _progress()
	if p and p.has_method("get_section"):
		var profile = p.get_section("resident")
		if profile and profile.has_method("perk"):
			return profile.perk(key, default)
	return default


func refresh_perks() -> void:
	player.heal_rate = float(perk("heal_rate", 1.0))
	if car:
		car.handling = float(perk("car_handling", 1.0))


func cash() -> int:
	var p := _progress()
	return int(p.cash) if p else _local_cash


func _take_cash(fee: Array, reason: String) -> int:
	var have := cash()
	var n := mini(have, maxi(int(have * float(fee[0])), int(fee[1])))
	var p := _progress()
	if p:
		p.add_cash(-n, reason)
	else:
		_local_cash -= n
	return n


func _eject(c: DrivableCar) -> void:
	## Out of the car at once (blown up, or the police drag you out).
	var p := c.exit_point()
	car = null
	c.set_driver(null)
	player.set_in_vehicle(false)
	player.place(p, c.heading_yaw())
	camera.blend_to(player.rig, 0.4)
	vehicle_changed.emit(null)


func _on_player_died() -> void:
	if down or not active:
		return
	down = true
	wasted.emit()
	if car:
		_eject(car)
	player.set_controls(false)
	player.visual.set_aim(CharacterModel.Aim.NONE)
	player.aiming = false
	player.visual.set_dead(true)
	camera.shake(0.5)
	await _down_sequence("WASTED", Color(0.85, 0.08, 0.06))
	var fee := _take_cash(WASTED_FEE, "hospital bill")
	await _respawn(_respawn_point(true))
	hud.note("Hospital bill  -$%d" % fee)


func bust() -> void:
	## The police caught the player: lose the guns and some cash, wake at the station.
	if down or not active or busy or player.dead:
		return
	down = true
	busted.emit()
	if switching:
		await get_tree().create_timer(0.6).timeout
	if car:
		_eject(car)
	player.set_controls(false)
	player.visual.set_aim(CharacterModel.Aim.NONE)
	player.aiming = false
	await _down_sequence("BUSTED", Color(0.3, 0.55, 1.0))
	combat.strip()
	var fee := _take_cash(BUSTED_FEE, "bail")
	await _respawn(_respawn_point(false), busted_wake)
	hud.note("Bail and fines  -$%d" % fee)


func _down_sequence(text: String, col: Color) -> void:
	hud.banner(text, col)
	player.rig.distance = 6.5
	var t := create_tween()
	t.tween_property(player.rig, "pitch", deg_to_rad(-38.0), 2.5).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(3.2).timeout
	await _fade(1.0, 0.7)


func _fade(to: float, seconds: float) -> void:
	var t := create_tween()
	t.tween_method(hud.set_black, hud._black, to, seconds)
	await t.finished


func _respawn(at: Vector3, wake := Callable()) -> void:
	heat.clear()
	_last_stars = 0
	player.revive()
	player.place(at, player.rig.yaw)
	if wake.is_valid():
		await wake.call()
	player.rig.distance = combat._base_distance
	player.rig.pitch = deg_to_rad(-12.0)
	player.rig.snap()
	camera.follow(player.rig)
	hud.clear_banner()
	await get_tree().create_timer(0.4).timeout
	down = false
	player.set_controls(active)
	await _fade(0.0, 0.6)


func _respawn_point(hospital: bool) -> Vector3:
	var pts: Array[Vector3] = []
	pts.assign(hospitals if hospital else stations)
	if pts.is_empty() and city:
		if city.has_method("find_tagged"):
			for b in city.find_tagged("hospital" if hospital else "police"):
				pts.append(city.building_center(b))
		if pts.is_empty() and not hospital and life and life.get("police"):
			for cell in life.police.stations:
				pts.append(city.cell_center(cell.x, cell.y))
		if pts.is_empty():
			# No hospital or station built yet: the middle of town (a clinic off-screen).
			var cc := city.center_cell()
			pts.append(city.cell_center(cc.x + (2 if hospital else -2), cc.y))
	if pts.is_empty():
		return player.global_position
	var from := player.global_position
	var best: Vector3 = pts[0]
	for p in pts:
		if p.distance_squared_to(from) < best.distance_squared_to(from):
			best = p
	return sidewalk_spawn(best)


# ------------------------------------------------------------------------ save ---

func to_dict() -> Dictionary:
	return {"health": player.health, "armor": player.armor,
		"pistol": combat.ammo[&"pistol"], "shotgun": combat.ammo[&"shotgun"], "weapon": String(combat.current)}


func from_dict(d: Dictionary) -> void:
	player.health = clampf(float(d.get("health", StreetPlayer.MAX_HEALTH)), 1.0, StreetPlayer.MAX_HEALTH)
	player.armor = clampf(float(d.get("armor", 0.0)), 0.0, StreetPlayer.MAX_ARMOR)
	combat.ammo[&"pistol"] = int(d.get("pistol", 0))
	combat.ammo[&"shotgun"] = int(d.get("shotgun", 0))
	combat.select(StringName(d.get("weapon", "fists")))
