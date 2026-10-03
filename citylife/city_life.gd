class_name CityLife
extends Node3D
## Traffic and pedestrians for a City. Add one to the scene and call setup(city, camera).
##
## Density follows the city: cars are spawned where the sim's commuter traffic and the
## nearby buildings are, people where homes and especially shops are, both scaled by the
## time of day. Only the area around the camera is populated: a small radius at street
## level, the whole island from the mayor view, where people are dropped entirely and
## cars lose their shadows.

@export var max_cars := 220
@export var max_peds := 360
@export var density := 1.0          # global multiplier, e.g. from a graphics setting
@export var auto_step := true       # false in tests, which call step() themselves

# Hourly multipliers, 0h..23h.
const CAR_HOURS := [0.2, 0.15, 0.12, 0.12, 0.15, 0.3, 0.6, 0.9, 1.0, 0.8, 0.65, 0.65,
	0.7, 0.7, 0.65, 0.7, 0.85, 1.0, 0.95, 0.75, 0.55, 0.45, 0.35, 0.25]
const PED_HOURS := [0.08, 0.05, 0.04, 0.04, 0.05, 0.1, 0.25, 0.55, 0.75, 0.7, 0.75, 0.85,
	1.0, 0.95, 0.85, 0.85, 0.9, 1.0, 0.95, 0.8, 0.6, 0.4, 0.25, 0.14]
const ZONE_PEDS := [0.0, 1.0, 1.7, 0.35]   # by City.Zone
const ZONE_CARS := [0.0, 0.8, 1.2, 1.1]
const PED_HEIGHT := 200.0          # camera height above which people are not simulated
const STREET_FILL := 90.0          # no pop-in spawning closer than this when in view

var city: City
var camera: Camera3D
var net: RoadNet
var traffic: Traffic
var crowd: Crowd
var signals: Signals

var car_weight := PackedFloat32Array()
var ped_weight := PackedFloat32Array()
var focus := Vector3.ZERO
var cam_height := 300.0
var car_radius := 600.0
var ped_radius := 140.0
var want_cars := 0
var want_peds := 0

var _roads_dirty := false
var _area_timer := 0.0
var _car_cells := PackedInt32Array()
var _car_cum := PackedFloat32Array()
var _ped_cells := PackedInt32Array()
var _ped_cum := PackedFloat32Array()
var rng := RandomNumberGenerator.new()


func setup(c: City, cam: Camera3D = null) -> void:
	city = c
	camera = cam
	rng.seed = 99
	net = RoadNet.new(city)
	traffic = Traffic.new()
	traffic.name = "Traffic"
	traffic.max_cars = max_cars
	add_child(traffic)
	traffic.setup(net)
	crowd = Crowd.new()
	crowd.name = "Crowd"
	crowd.max_peds = max_peds
	add_child(crowd)
	crowd.setup(net)
	signals = Signals.new()
	signals.name = "Signals"
	add_child(signals)
	signals.setup(net)
	traffic.camera = cam
	crowd.camera = cam
	city.cells_changed.connect(func(_r): _roads_dirty = true)
	city.building_added.connect(func(_id, _a): _weights_dirty = true)
	city.building_removed.connect(func(_id): _weights_dirty = true)
	city.day_passed.connect(func(): _weights_dirty = true)
	compute_weights()
	_update_view()
	_update_area()
	_fill(true)


func set_camera(cam: Camera3D) -> void:
	camera = cam
	traffic.camera = cam
	crowd.camera = cam


func _process(delta: float) -> void:
	if auto_step and city:
		step(minf(delta, 0.1))


var _weights_dirty := false
var _weights_timer := 0.0


func step(dt: float) -> void:
	net.time += dt
	if _roads_dirty:
		_roads_dirty = false
		net.rebuild()
		traffic.validate()
		crowd.validate()
		signals.rebuild()
		_weights_dirty = true
	_weights_timer -= dt
	if _weights_dirty and _weights_timer <= 0.0:
		# Buildings change constantly while the city grows; refresh a few times a minute.
		_weights_dirty = false
		_weights_timer = 4.0
		compute_weights()
		_area_timer = 0.0
	_update_view()
	_area_timer -= dt
	if _area_timer <= 0.0:
		_area_timer = 0.5
		_update_area()
	_cull()
	_fill(false)
	traffic.step(dt)
	if cam_height < PED_HEIGHT:
		crowd.step(dt)
	signals.update(dt)
	traffic.shadows = cam_height < 140.0
	crowd.shadows = cam_height < 70.0
	crowd.visible = cam_height < PED_HEIGHT
	signals.visible = cam_height < 260.0
	traffic.render()
	if crowd.visible:
		crowd.render()


# ---------------------------------------------------------------- density ---

## How busy each road cell is, from the buildings along it and the sim's traffic.
func compute_weights() -> void:
	var n := City.SIZE * City.SIZE
	car_weight.resize(n)
	ped_weight.resize(n)
	car_weight.fill(0.0)
	ped_weight.fill(0.0)
	for b in city.buildings.values():
		var cap := float(city.capacity(b))
		var pw: float = sqrt(cap) * ZONE_PEDS[b.zone] * 0.12
		var cw: float = sqrt(cap) * ZONE_CARS[b.zone] * 0.05
		# Spread over road cells within two tiles of the lot.
		for dy in range(-2, b.size + 2):
			for dx in range(-2, b.size + 2):
				var x: int = b.x + dx
				var y: int = b.y + dy
				if not city.inside(x, y):
					continue
				var i := city.idx(x, y)
				if city.road[i] != 1:
					continue
				var near: bool = dx >= -1 and dy >= -1 and dx <= b.size and dy <= b.size
				var f := 1.0 if near else 0.4
				ped_weight[i] += pw * f
				car_weight[i] += cw * f
	for i in n:
		if city.road[i] == 1:
			car_weight[i] += 0.05 + minf(city.traffic[i], 2.5) * 0.45
			ped_weight[i] += 0.03
	traffic.weight = car_weight
	crowd.weight = ped_weight


func hour_factor(table: Array) -> float:
	var h := city.time_of_day()
	var a := int(h) % 24
	return lerpf(table[a], table[(a + 1) % 24], h - floorf(h))


func _update_view() -> void:
	var size := City.SIZE * City.TILE
	if camera == null or not camera.is_inside_tree():
		# No camera (tests, tools): populate the whole island, people included.
		focus = Vector3(size * 0.5, 0, size * 0.5)
		cam_height = 100.0
		car_radius = size
		ped_radius = size
		return
	var o := camera.global_position
	var d := -camera.global_transform.basis.z
	cam_height = o.y
	if d.y < -0.05:
		focus = o + d * (o.y / -d.y)
	else:
		focus = o + Vector3(d.x, 0, d.z).normalized() * 120.0
	focus.y = 0.0
	# Street level: the block around you. Higher up: wider, until the whole island.
	car_radius = clampf(cam_height * 2.2 + 170.0, 200.0, size)
	ped_radius = 150.0 if cam_height < PED_HEIGHT else 0.0
	if cam_height < 40.0:
		# Close to the ground the focus is far ahead; centre on the camera instead.
		focus = Vector3(o.x, 0, o.z) + Vector3(d.x, 0, d.z).normalized() * 40.0


func _update_area() -> void:
	var r2 := car_radius * car_radius
	var p2 := ped_radius * ped_radius
	_car_cells.clear()
	_car_cum.clear()
	_ped_cells.clear()
	_ped_cum.clear()
	var ct := 0.0
	var pt := 0.0
	for i in city.road.size():
		if city.road[i] != 1:
			continue
		var d2 := net.center(i).distance_squared_to(focus)
		if d2 < r2 and net.junction[i] == 0:
			ct += car_weight[i]
			_car_cells.append(i)
			_car_cum.append(ct)
		if d2 < p2:
			pt += ped_weight[i]
			_ped_cells.append(i)
			_ped_cum.append(pt)
	want_cars = mini(int(ct * hour_factor(CAR_HOURS) * density * 0.55), max_cars)
	want_peds = mini(int(pt * hour_factor(PED_HOURS) * density * 1.4), max_peds)
	if ped_radius <= 0.0:
		want_peds = 0


func _pick(cells: PackedInt32Array, cum: PackedFloat32Array) -> int:
	if cells.is_empty() or cum[-1] <= 0.0:
		return -1
	var r := rng.randf() * cum[-1]
	var k := cum.bsearch(r)
	return cells[mini(k, cells.size() - 1)]


func _in_view(p: Vector3) -> bool:
	if camera == null or not camera.is_inside_tree():
		return false
	return camera.is_position_in_frustum(p) and camera.global_position.distance_to(p) < STREET_FILL + cam_height


func _fill(initial: bool) -> void:
	# Fill fast (anywhere) when far below target, e.g. right after a zoom; otherwise only
	# spawn out of sight so nothing pops in on screen.
	var budget := 400 if initial else 6
	var tries := budget * 3
	while traffic.cars.size() < want_cars and budget > 0 and tries > 0:
		tries -= 1
		var cell := _pick(_car_cells, _car_cum)
		if cell < 0:
			break
		var hidden_ok := initial or traffic.cars.size() < want_cars / 2
		if not hidden_ok and _in_view(net.center(cell)):
			continue
		if traffic.spawn_at(cell):
			budget -= 1
	budget = 600 if initial else 10
	tries = budget * 3
	while crowd.peds.size() < want_peds and budget > 0 and tries > 0:
		tries -= 1
		var cell := _pick(_ped_cells, _ped_cum)
		if cell < 0:
			break
		var hidden_ok := initial or crowd.peds.size() < want_peds / 2
		if not hidden_ok and _in_view(net.center(cell)):
			continue
		if crowd.spawn_at(cell):
			budget -= 1


func _cull() -> void:
	var cr := car_radius * 1.15
	var removed := 0
	for c in traffic.cars.duplicate():
		var far: bool = Vector2(c.pos.x - focus.x, c.pos.z - focus.z).length() > cr
		var extra: bool = traffic.cars.size() > want_cars * 1.2 + 4 and removed < 2 and not _in_view(c.pos)
		if far or extra:
			traffic.remove(c)
			removed += 1 if extra else 0
	if ped_radius <= 0.0:
		for p in crowd.peds.duplicate():
			crowd.remove(p)
		return
	var pr := ped_radius * 1.2
	removed = 0
	for p in crowd.peds.duplicate():
		var far: bool = Vector2(p.pos.x - focus.x, p.pos.z - focus.z).length() > pr
		var extra: bool = crowd.peds.size() > want_peds * 1.2 + 4 and removed < 3 and not _in_view(p.pos) and not p.crossing
		if far or extra:
			crowd.remove(p)
			removed += 1 if extra else 0
