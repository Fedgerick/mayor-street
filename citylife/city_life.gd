class_name CityLife
extends Node3D
## Traffic and pedestrians for a City. Add one to the scene and call setup(city, camera).
##
## Density follows the city: cars are spawned where the sim's commuter traffic and the
## nearby buildings are, people where homes and especially shops are, both scaled by the
## time of day. Only the area around the camera is populated: a small radius at street
## level, the whole island from the mayor view, where people are dropped entirely and
## cars lose their shadows.

@export var max_cars := 260
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
const ZONE_PEDS_NIGHT := [0.0, 0.3, 1.0, 0.08]  # who is out late, by zone
const NIGHTLIFE := 6.0             # extra night draw of clubs, casinos and the like
const PED_HEIGHT := 200.0          # camera height above which people are not simulated
const STREET_FILL := 90.0          # no pop-in spawning closer than this when in view

var city: City
var camera: Camera3D
var net: RoadNet
var traffic: Traffic
var crowd: Crowd
var signals: Signals
var police: Police
var spots: StreetSpots
var weather: Object = null         # Weather (weather/weather.gd), optional
var want_garbage := 0
var want_buses := 0
var _garbage_timer := 0.0
var _bus_timer := 0.0
var boarded := 0                   # stats: people who got on a bus

var car_weight := PackedFloat32Array()
var ped_weight := PackedFloat32Array()
var ped_night := PackedFloat32Array()   # where people are late at night
var nightlife := PackedFloat32Array()   # the part of ped_night from nightlife spots
var focus := Vector3.ZERO
var cam_height := 300.0
var car_radius := 600.0
const PLANET_STREET_RADIUS := 105.0  # msp street level: life within this of the camera
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
	police = Police.new()
	police.name = "Police"
	add_child(police)
	police.setup(city, net, traffic, crowd)
	spots = StreetSpots.new()
	spots.name = "StreetSpots"
	add_child(spots)
	spots.setup(net)
	crowd.spots = spots
	traffic.stops = spots.stop_at
	traffic.car_taken.connect(_on_car_taken)
	traffic.bus_stopped.connect(_on_bus_stopped)
	traffic.camera = cam
	crowd.camera = cam
	police.camera = cam
	city.cells_changed.connect(func(_r): _roads_dirty = true)
	city.building_added.connect(func(id, _a): _add_building(id))
	city.building_removed.connect(_remove_building)
	city.day_passed.connect(_refresh_road_weights)
	city.day_passed.connect(spots.rebuild)  # new shops and parks bring benches
	compute_weights()
	_update_view()
	_update_area()
	_fill(true)


func set_camera(cam: Camera3D) -> void:
	camera = cam
	traffic.camera = cam
	crowd.camera = cam
	police.camera = cam


## The player's wanted system (see INTERFACE.md). Police chase it while it has stars.
func set_suspect(s: Object) -> void:
	police.set_suspect(s)


## Something violent happened at pos (1 punch .. 3 gunfire): nearby people run.
func report_crime(pos: Vector3, severity := 1) -> int:
	return crowd.panic(pos, 12.0 + 12.0 * clampi(severity, 1, 3), 6.0 + 3.0 * severity)


## Hand over the Weather: rain thins the crowd, brings out umbrellas, keeps people off
## wet benches and makes drivers more careful.
func set_weather(w: Object) -> void:
	weather = w


## A crash at pos: people right there jump clear, everyone else nearby stops to stare.
func report_crash(pos: Vector3, severity := 1) -> int:
	crowd.panic(pos, 4.0 + 2.0 * severity, 3.0)
	return crowd.gawk(pos, 22.0 + 8.0 * clampi(severity, 1, 3))


func _on_bus_stopped(bus: Traffic.Car, stop: Object) -> void:
	var s := stop as StreetSpots.Spot
	if s == null:
		return
	# The front door, on the kerb beside it (the bus may still be easing over).
	var door := bus.pos + bus.fwd * (Traffic.LENGTHS[Traffic.BUS] * 0.5 - 1.3)
	var out: Vector3 = RoadNet.DV[s.side]
	door += out * (3.95 - (door - net.center(s.cell)).dot(out))
	door.y = 0.17
	boarded += crowd.board(s, door)
	if cam_height < PED_HEIGHT and crowd.peds.size() < want_peds + 6:
		var n := rng.randi_range(0, 2) + (1 if crowd._commute() else 0)
		crowd.alight(s, door, n)


func _on_car_taken(pos: Vector3, fwd: Vector3) -> void:
	# The driver bails out of the kerb side and runs.
	crowd.spawn_fleeing(pos + Vector3(-fwd.z, 0, fwd.x) * 2.0, pos - fwd * 2.0)
	report_crime(pos, 2)


func _process(delta: float) -> void:
	if auto_step and city:
		step(minf(delta, 0.1))




func step(dt: float) -> void:
	net.time += dt
	var t := Prof.now()  # script time by system, for the benchmark report
	if _roads_dirty:
		_roads_dirty = false
		net.rebuild()
		traffic.validate()
		crowd.validate()
		signals.rebuild()
		police.refresh_stations()
		compute_weights()  # building contributions only land on road cells
		_area_timer = 0.0
		t = Prof.lap("life: road rebuild", t)
	_update_view()
	_area_timer -= dt
	if _area_timer <= 0.0:
		_area_timer = 0.5
		_update_area()
	_cull()
	_fill(false)
	_garbage(dt)
	_buses(dt)
	t = Prof.lap("life: spawning", t)
	crowd.hour = city.time_of_day()
	if weather != null:
		crowd.rain = weather.rain
		crowd.wet = weather.wet
		crowd.umbrella_share = weather.umbrella_share()
		traffic.wet = weather.wet
	police.step(dt)
	t = Prof.lap("police", t)
	traffic.step(dt)
	t = Prof.lap("traffic", t)
	if cam_height < PED_HEIGHT:
		crowd.step(dt)
	t = Prof.lap("crowd", t)
	signals.update(dt)
	traffic.shadows = cam_height < 140.0
	crowd.shadows = cam_height < 70.0
	crowd.visible = cam_height < PED_HEIGHT
	signals.visible = cam_height < 260.0
	spots.update_view(cam_height)
	t = Prof.lap("life: signals and spots", t)
	traffic.render()
	t = Prof.lap("traffic: drawing", t)
	police.render()
	t = Prof.lap("police", t)
	if crowd.visible:
		crowd.update_heroes(dt)
		t = Prof.lap("crowd: close-up people", t)
		crowd.render()
		t = Prof.lap("crowd: drawing", t)


# ---------------------------------------------------------------- garbage ---

## Garbage trucks run in the morning, a few per city, starting from the depots.
func _garbage(dt: float) -> void:
	_garbage_timer -= dt
	if _garbage_timer > 0.0:
		return
	_garbage_timer = 3.0
	var h := city.time_of_day()
	want_garbage = 0
	if h >= 6.0 and h < 15.0:
		want_garbage = clampi(city.buildings.size() / 250 + 1, 1, 4)
	if traffic.garbage_count() >= want_garbage or _car_cells.is_empty():
		return
	var cell := -1
	var depots := _service_cells("garbage")
	if not depots.is_empty():
		var d: Vector2i = depots[rng.randi() % depots.size()]
		cell = police._nearest_road(d)
		if cell >= 0 and net.junction[cell] == 1:
			cell = -1
	if cell < 0:
		cell = _pick(_car_cells, _car_cum)
		if cell >= 0 and _in_view(net.center(cell)):
			return
	if cell >= 0:
		traffic.spawn_garbage(cell)


# ------------------------------------------------------------------ buses ---

## Buses run from early morning to midnight, about one for every five stops around you.
func _buses(dt: float) -> void:
	_bus_timer -= dt
	if _bus_timer > 0.0:
		return
	_bus_timer = 2.0
	var h := city.time_of_day()
	want_buses = 0
	if h >= 5.5 and _car_cells.size() > 0:
		var near := 0
		var r2 := car_radius * car_radius
		for s in spots.spots:
			if s.kind == StreetSpots.Kind.STOP and s.xform.origin.distance_squared_to(focus) < r2:
				near += 1
		if near > 0:
			want_buses = clampi(near / 5 + 1, 1, 6)
	crowd.buses_running = want_buses > 0
	if traffic.bus_count() >= want_buses:
		return
	for attempt in 6:
		var cell := _pick(_car_cells, _car_cum)
		if cell >= 0 and not _in_view(net.center(cell)) and traffic.spawn_bus(cell):
			return


func _service_cells(kind: String) -> Array:
	var out := []
	var sv := police.services_object() if police else null
	if kind == "garbage" and sv != null and sv.has_method("garbage_depots"):
		for st in sv.garbage_depots():
			var p = st.get("road", st.get("center"))
			if p is Vector3:
				out.append(city.flat_to_cell(p))
		if not out.is_empty():
			return out
	if kind == "garbage" and city.has_method("find_tagged"):
		for b in city.find_tagged("garbage_depot"):
			out.append(Vector2i(b.x, b.y))
	return out


## Optional: hand over the CityServices object (otherwise read from Progress).
func set_services(s: Object) -> void:
	if police:
		police.services = s
		police.refresh_stations()


# ---------------------------------------------------------------- density ---

## How busy each road cell is, from the buildings along it and the sim's traffic.
## Weights are kept incrementally: each building adds its share to the road cells near
## it when it appears and takes it back when it goes, so a growing city costs a few
## microseconds per building instead of a full rescan. Full rebuilds only follow road edits.
var _contrib := {}             # building id -> [cells, car shares, ped shares]
var _road_car := PackedFloat32Array()
var _road_ped := PackedFloat32Array()


func compute_weights() -> void:
	var n := City.W * City.H
	car_weight.resize(n)
	ped_weight.resize(n)
	ped_night.resize(n)
	nightlife.resize(n)
	car_weight.fill(0.0)
	ped_weight.fill(0.0)
	ped_night.fill(0.0)
	nightlife.fill(0.0)
	_road_car.resize(n)
	_road_ped.resize(n)
	_road_car.fill(0.0)
	_road_ped.fill(0.0)
	_contrib.clear()
	for id in city.buildings:
		_add_building(id)
	_refresh_road_weights()
	traffic.weight = car_weight
	crowd.weight = ped_weight


func _add_building(id: int) -> void:
	if not city.buildings.has(id) or _contrib.has(id):
		return
	var b: Dictionary = city.buildings[id]
	var cap := float(city.capacity(b))
	var pw: float = sqrt(cap) * ZONE_PEDS[b.zone] * 0.12
	var cw: float = sqrt(cap) * ZONE_CARS[b.zone] * 0.05
	var nw: float = sqrt(cap) * ZONE_PEDS_NIGHT[b.zone] * 0.12
	var lw := 0.0
	var tags: Array = b.get("tags", [])
	if tags.has("nightlife"):
		lw = NIGHTLIFE * maxf(sqrt(cap), 4.0) * 0.12
	elif tags.has("park"):
		nw *= 0.3
	var cells := PackedInt32Array()
	var fs := PackedFloat32Array()
	var size: int = b.size
	var bx: int = b.x
	var by: int = b.y
	# Spread over road cells within two tiles of the lot.
	for dy in range(-2, size + 2):
		var y := by + dy
		if y < 0 or y >= City.H:
			continue
		for dx in range(-2, size + 2):
			var x := bx + dx
			if x < 0 or x >= City.W:
				continue
			var i := y * City.W + x
			if city.road[i] != 1:
				continue
			var near := dx >= -1 and dy >= -1 and dx <= size and dy <= size
			var f := 1.0 if near else 0.4
			cells.append(i)
			fs.append(f)
			car_weight[i] += cw * f
			ped_weight[i] += pw * f
			ped_night[i] += (nw + lw) * f
			nightlife[i] += lw * f
	_contrib[id] = [cells, fs, cw, pw, nw + lw, lw]


func _remove_building(id: int) -> void:
	if not _contrib.has(id):
		return
	var c: Array = _contrib[id]
	var cells: PackedInt32Array = c[0]
	var fs: PackedFloat32Array = c[1]
	for k in cells.size():
		var i := cells[k]
		car_weight[i] = maxf(car_weight[i] - c[2] * fs[k], 0.0)
		ped_weight[i] = maxf(ped_weight[i] - c[3] * fs[k], 0.0)
		ped_night[i] = maxf(ped_night[i] - c[4] * fs[k], 0.0)
		nightlife[i] = maxf(nightlife[i] - c[5] * fs[k], 0.0)
	_contrib.erase(id)


## The per-road part: a base level plus the sim's commuter flow (changes once a day).
func _refresh_road_weights() -> void:
	for i in city.road.size():
		var rc := 0.0
		var rp := 0.0
		if city.road[i] == 1:
			rc = 0.05 + minf(city.traffic[i], 2.5) * 0.45
			rp = 0.03
		car_weight[i] += rc - _road_car[i]
		ped_weight[i] += rp - _road_ped[i]
		ped_night[i] += rp - _road_ped[i]
		_road_car[i] = rc
		_road_ped[i] = rp


## 0 by day .. 1 late at night: how much people gather where the nightlife is.
func night_mix() -> float:
	var h := city.time_of_day()
	if h >= 18.0:
		return clampf((h - 18.0) / 3.0, 0.0, 1.0)
	if h < 6.0:
		return clampf((6.0 - h) / 3.0, 0.0, 1.0)
	return 0.0


func hour_factor(table: Array) -> float:
	var h := city.time_of_day()
	var a := int(h) % 24
	return lerpf(table[a], table[(a + 1) % 24], h - floorf(h))


func _update_view() -> void:
	var size := maxi(City.W, City.H) * City.TILE
	if camera == null or not camera.is_inside_tree():
		# No camera (tests, tools): populate the whole island, people included.
		focus = Vector3(City.W * City.TILE * 0.5, 0, City.H * City.TILE * 0.5)
		cam_height = 100.0
		car_radius = size
		ped_radius = size
		return
	# On msp the view is worked out on the flat map, where cars and people live.
	var o := Planet.flat(camera.global_position)
	var d := Planet.to_local(camera.global_position, -camera.global_transform.basis.z)
	cam_height = o.y
	if d.y < -0.05:
		focus = o + d * (o.y / -d.y)
	else:
		focus = o + Vector3(d.x, 0, d.z).normalized() * 120.0
	focus.y = 0.0
	# Street level: the block around you. Higher up: wider, until the whole island.
	car_radius = clampf(cam_height * 2.6 + 110.0, 150.0, size)
	ped_radius = 150.0 if cam_height < PED_HEIGHT else 0.0
	if cam_height < 40.0:
		# Close to the ground the focus is far ahead; centre on the camera instead.
		focus = Vector3(o.x, 0, o.z) + Vector3(d.x, 0, d.z).normalized() * 40.0
		if Planet.on:
			# On the ball the ground drops behind the horizon: from eye height a car or a
			# walker is out of sight past about 70-90 m, so only the ring that can be seen
			# is filled. Same density as before, about half as many cars and people.
			focus = Vector3(o.x, 0, o.z) + Vector3(d.x, 0, d.z).normalized() * 15.0
			car_radius = PLANET_STREET_RADIUS
			if ped_radius > 0.0:
				ped_radius = PLANET_STREET_RADIUS


func _update_area() -> void:
	var r2 := car_radius * car_radius
	var p2 := ped_radius * ped_radius
	_car_cells.clear()
	_car_cum.clear()
	_ped_cells.clear()
	_ped_cum.clear()
	var ct := 0.0
	var pt := 0.0
	var lt := 0.0
	var nm := night_mix()
	for i in city.road.size():
		if city.road[i] != 1:
			continue
		var cc := net.center(i)
		if Planet.on:
			cc.x = focus.x + Planet.dx(focus.x, cc.x)  # the short way round
		var d2 := cc.distance_squared_to(focus)
		if d2 < r2 and net.junction[i] == 0:
			ct += car_weight[i]
			_car_cells.append(i)
			_car_cum.append(ct)
		if d2 < p2:
			pt += lerpf(ped_weight[i], ped_night[i], nm)
			lt += nightlife[i]
			_ped_cells.append(i)
			_ped_cum.append(pt)
	# Cap the city's demand first, then apply the hour, so a big city is still quiet at 3am.
	# The caps are for the usual 150 m street ring; a smaller ring (msp) gets a smaller
	# cap, so a busy downtown is as busy as before rather than packed tighter.
	var ring := clampf(pow(minf(car_radius, ped_radius if ped_radius > 0.0 else car_radius) / 150.0, 2.0), 0.0, 1.0)
	var cap_cars := max_cars * ring
	var cap_peds := max_peds * ring
	want_cars = int(minf(ct * density * 0.55, cap_cars) * hour_factor(CAR_HOURS))
	want_peds = int(minf(pt * density * 1.4, cap_peds) * hour_factor(PED_HOURS))
	if weather != null:
		want_peds = int(want_peds * (1.0 - 0.4 * weather.rain))  # rain keeps people in
	# Clubs and the casino keep their blocks busy late.
	want_peds = mini(want_peds + int(minf(lt * density * 1.4, cap_peds * 0.35) * nm), int(cap_peds))
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
	p = Planet.place(p)  # p is flat map metres
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
		if rng.randf() < crowd.chat_share() and crowd.peds.size() + 2 <= want_peds:
			if crowd.spawn_group(cell) > 0:
				budget -= 1
				continue
		if crowd.spawn_at(cell):
			budget -= 1


func _cull() -> void:
	var cr := car_radius * 1.15
	var removed := 0
	for c in traffic.cars.duplicate():
		var far: bool = Planet.fdist(c.pos, focus) > cr
		var extra: bool = traffic.cars.size() > want_cars * 1.2 + 4 and removed < 2 and not _in_view(c.pos) and not c.garbage and not c.bus
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
		var far: bool = Planet.fdist(p.pos, focus) > pr
		var extra: bool = crowd.peds.size() > want_peds * 1.2 + 4 and removed < 3 and not _in_view(p.pos) and not p.crossing
		if far or extra:
			crowd.remove(p)
			removed += 1 if extra else 0
