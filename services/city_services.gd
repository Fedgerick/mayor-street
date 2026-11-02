class_name CityServices
extends RefCounted
## City services: power, parks, sanitation, police and fire, on a radius model over the City grid.
## No rendering here (see ServicesView), so it runs headless in tests.
##
## Coverage and the power grid are recomputed only when something changes (a road, zone, building
## or power line); the City signals mark them dirty and the next read or update() rebuilds them.
## Garbage, crime, happiness and approval run once per game day and go to Progress.set_stats.

signal coverage_changed            ## coverage maps or the power grid were rebuilt
signal stats_changed               ## the daily numbers were updated
signal facilities_changed          ## a service building was added or removed
signal police_stations_changed     ## the list from police_stations() changed

var N := City.W * City.H  # set when made; Planet.configure runs first on msp
## Below this population the city may grow without power, so a new game can get going.
const POWER_GRACE_POP := 100
## Days without power (or this unhappy) before a building drops a stage or empties out.
const DECAY_DAYS := 6
const UNHAPPY := 0.15
const MAX_DECAY_PER_DAY := 12
## Uncollected garbage above this level (0..1) shows as piles on the street.
const PILE_LEVEL := 0.34

enum Overlay { NONE, POWER, PARKS, GARBAGE, POLICE, FIRE, CRIME, HAPPINESS }
const OVERLAY_NAMES := ["None", "Power", "Parks", "Garbage", "Police", "Fire", "Crime", "Happiness"]

var city: City
## Used when there's no Progress store (tests): the Resident's goodness, -100 .. 100.
var goodness := 0.0
## Scales every plant's output (1 = normal). Events like a failing substation can lower it.
var supply_scale := 1.0:
	set(v):
		supply_scale = v
		_dirty_power = true

var facilities := {}  # building id -> kind, for catalog buildings with service numbers
var power_line := PackedByteArray()  # 1 = power line on this cell

# Per-cell maps, all N long.
var power := PackedByteArray()        # 0 nothing, 1 grid or building without power, 2 powered
var park := PackedFloat32Array()      # 0..1 park effect
var police := PackedFloat32Array()    # 0..1 police coverage
var fire := PackedFloat32Array()      # 0..1 fire coverage
var garbage_reach := PackedFloat32Array()  # 0..1 inside a depot's range
var garbage := PackedFloat32Array()   # 0..1 uncollected garbage
var crime := PackedFloat32Array()     # 0..1
var fire_risk := PackedFloat32Array() # 0..1
var happiness := PackedFloat32Array() # 0..1, on built cells

# Per-building state (building id -> value).
var backlog := {}         # tons of uncollected garbage
var unpowered_days := {}
var unhappy_days := {}

# Daily numbers.
var supply_mw := 0.0
var demand_mw := 0.0
var power_pct := 100.0     # share of demand that gets power
var garbage_pct := 100.0   # share of garbage collected
var garbage_tons := 0.0    # produced per day
var crime_avg := 0.0       # 0..1, weighted by people
var happiness_avg := 0.5   # 0..1, residents
var approval := 55.0       # 0..100, the Mayor's rating
var income_per_resident := 0.0  # $ / year
var last_upkeep := 0.0

var _dirty_cov := true
var _dirty_power := true


func _init(c: City) -> void:
	city = c
	for a in [power_line, power]:
		a.resize(N)
	for a in [park, police, fire, garbage_reach, garbage, crime, fire_risk, happiness]:
		a.resize(N)
	city.cells_changed.connect(_on_cells_changed)
	city.building_added.connect(_on_building_added)
	city.building_removed.connect(_on_building_removed)
	city.day_passed.connect(_on_day)
	city.growth_check = _growth_check
	city.land_value_computed.connect(_on_land_value)
	rescan()


# ------------------------------------------------------------------ signals ---

func _on_cells_changed(_r: Rect2i) -> void:
	_dirty_power = true


func _on_building_added(id: int, _animate: bool) -> void:
	if ServiceDefs.has(String(city.buildings[id].get("kind", ""))):
		_register(id)
	_dirty_power = true


func _on_building_removed(id: int) -> void:
	backlog.erase(id)
	unpowered_days.erase(id)
	unhappy_days.erase(id)
	if facilities.has(id):
		_unregister(id)
	_dirty_power = true


func _register(id: int) -> void:
	var b: Dictionary = city.buildings[id]
	facilities[id] = String(b.kind)
	_dirty_cov = true
	_dirty_power = true
	if ServiceDefs.service_of(b.kind) == "police":
		police_stations_changed.emit()
	facilities_changed.emit()


func _unregister(id: int) -> void:
	var kind: String = facilities[id]
	facilities.erase(id)
	_dirty_cov = true
	_dirty_power = true
	if ServiceDefs.service_of(kind) == "police":
		police_stations_changed.emit()
	facilities_changed.emit()


## Re-reads every service building from City.buildings (after loading a save).
func rescan() -> void:
	facilities.clear()
	for b in city.buildings.values():
		if ServiceDefs.has(String(b.get("kind", ""))):
			facilities[b.id] = String(b.kind)
	_dirty_cov = true
	_dirty_power = true
	facilities_changed.emit()
	police_stations_changed.emit()


## Rebuilds whatever is out of date. Cheap when nothing changed; call it every frame or so.
func update() -> void:
	if not (_dirty_cov or _dirty_power):
		return
	if _dirty_cov:
		_compute_coverage()
	if _dirty_power:
		_compute_power()
	_dirty_cov = false
	_dirty_power = false
	coverage_changed.emit()


# ---------------------------------------------------------------- placement ---

## "" when a catalog building can go there, otherwise the reason it can't (City's rules).
func can_place(kind: String, cell: Vector2i, free := false) -> String:
	return city.can_place_special(kind, cell, free)


## Buys and places a catalog building with its top-left tile at cell. Returns its id, or -1.
## Service buildings register themselves through City.building_added.
func place_facility(kind: String, cell: Vector2i, free := false) -> int:
	var id := city.place_special(kind, cell, -1, free)
	update()
	return id


func line_cost(path: Array[Vector2i]) -> int:
	var n := 0
	for c in path:
		if city.inside(c.x, c.y):
			var i := city.idx(c.x, c.y)
			if city.land[i] == 1 and city.road[i] == 0 and power_line[i] == 0 and city.bld[i] < 0:
				n += 1
	return n * int(Catalog.get_def("power_line").get("cost", 5))


## Power lines carry power across land without roads or buildings. Path as from City.road_path().
func place_power_line(path: Array[Vector2i]) -> bool:
	var cost := line_cost(path)
	if cost == 0 or not city.spend(cost):
		return false
	for c in path:
		if city.inside(c.x, c.y):
			var i := city.idx(c.x, c.y)
			if city.land[i] == 1 and city.road[i] == 0 and city.bld[i] < 0:
				power_line[i] = 1
	_dirty_power = true
	update()
	return true


## Removes power lines in a rectangle (call it from the bulldoze tool). Returns how many went.
func bulldoze_lines(r: Rect2i) -> int:
	var n := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if city.inside(x, y) and power_line[city.idx(x, y)] == 1:
				power_line[city.idx(x, y)] = 0
				n += 1
	if n > 0:
		_dirty_power = true
		update()
	return n


# ------------------------------------------------------------------ queries ---

## Service buildings of one service ("power", "park", "garbage", "police", "fire").
## Each entry: id, kind, name, cell (top-left), size, center (world), door (world point on the
## nearest road, or the center), radius_m (coverage radius in metres, 0 if none), tags.
func stations(service: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in facilities:
		var d := ServiceDefs.get_def(facilities[id])
		if d.service != service or not city.buildings.has(id):
			continue
		var b: Dictionary = city.buildings[id]
		out.append({
			"id": id, "kind": facilities[id], "name": b.get("name", ""), "cell": Vector2i(b.x, b.y), "size": b.size,
			"center": city.building_center(b), "door": city.door_position(b), "road": _road_point(b),
			"radius_m": float(d.get("radius", 0.0)) * City.TILE, "tags": b.get("tags", []),
		})
	return out


func police_stations() -> Array[Dictionary]:
	return stations("police")


func fire_stations() -> Array[Dictionary]:
	return stations("fire")


func garbage_depots() -> Array[Dictionary]:
	return stations("garbage")


## The centre of the road tile nearest the building (where vehicles leave from).
func _road_point(b: Dictionary) -> Vector3:
	var best := Vector2i(-1, -1)
	var bd := 1e9
	var s: int = b.size
	var mid := Vector2(b.x + s * 0.5, b.y + s * 0.5)
	for y in range(b.y - 2, b.y + s + 2):
		for x in range(b.x - 2, b.x + s + 2):
			if city.is_road(x, y):
				var dd := Vector2(x + 0.5, y + 0.5).distance_squared_to(mid)
				if dd < bd:
					bd = dd
					best = Vector2i(x, y)
	if best.x < 0:
		return city.building_center(b)
	return city.cell_center(best.x, best.y)


func _cell_of(world: Vector3) -> int:
	var c := city.world_to_cell(world)
	if not city.inside(c.x, c.y):
		return -1
	return city.idx(c.x, c.y)


## Coverage 0..1 of "power" (1 if powered), "park", "garbage", "police" or "fire" at a world point.
func coverage_at(service: String, world: Vector3) -> float:
	update()
	var i := _cell_of(world)
	if i < 0:
		return 0.0
	match service:
		"power": return 1.0 if power[i] == 2 else 0.0
		"park": return park[i]
		"garbage": return garbage_reach[i]
		"police": return police[i]
		"fire": return fire[i]
	return 0.0


func crime_at(world: Vector3) -> float:
	var i := _cell_of(world)
	return crime[i] if i >= 0 else 0.0


func is_powered(id: int) -> bool:
	return city.buildings.has(id) and bool(city.buildings[id].get("powered", true))


## Whether power matters yet: once the city has a plant or passes the grace population.
func power_in_play() -> bool:
	if city.population >= POWER_GRACE_POP:
		return true
	for id in facilities:
		if ServiceDefs.service_of(facilities[id]) == "power":
			return true
	return false


## City.growth_check: may the lot at (x, y) grow a building or a stage now? Not without power.
func _growth_check(x: int, y: int) -> bool:
	return growth_ok(city.idx(x, y))


func growth_ok(i: int) -> bool:
	if not power_in_play():
		return true
	return power[i] == 2


## What parks, garbage and crime add to land value at cell index i.
func land_value_delta(i: int) -> float:
	return park[i] * 0.18 - garbage[i] * 0.15 - crime[i] * 0.12


func _on_land_value() -> void:
	update()
	for i in N:
		if city.land[i] == 1:
			city.land_value[i] = clampf(city.land_value[i] + land_value_delta(i), 0.0, 1.0)


## The Resident's goodness from the Progress store, or the local value in tests.
func current_goodness() -> float:
	if city.progress != null:
		return float(city.progress.goodness)
	return goodness


## World points for garbage bags and piles on the sidewalk, in front of buildings whose trash
## isn't collected. Up to three per building, more as it piles up.
func garbage_piles() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for id in backlog:
		if not city.buildings.has(id):
			continue
		var b: Dictionary = city.buildings[id]
		var lvl := garbage[city.idx(b.x, b.y)]
		if lvl < PILE_LEVEL:
			continue
		var n := 1 + int((lvl - PILE_LEVEL) / (1.0 - PILE_LEVEL) * 2.99)
		var dir: Vector2i = City.DIRS[int(b.rot)]
		var front: Vector3 = city.building_center(b) + Vector3(dir.x, 0, dir.y) * (b.size * City.TILE * 0.5 + 0.6)
		var side := Vector3(-dir.y, 0, dir.x)
		for k in n:
			var h := fposmod(sin(float(id * 7 + k * 13)) * 43758.5453, 1.0)
			out.append(front + side * ((h - 0.5) * b.size * City.TILE * 0.7))
	return out


## The daily numbers. The first six keys go to Progress.set_stats; all 0..100 except income.
func stats() -> Dictionary:
	return {
		"power_pct": power_pct, "garbage_pct": garbage_pct, "crime": crime_avg * 100.0,
		"happiness": happiness_avg * 100.0, "approval": approval, "income_per_resident": income_per_resident,
		"supply_mw": supply_mw, "demand_mw": demand_mw, "garbage_tons": garbage_tons,
		"line_upkeep": last_upkeep,
	}


## Values 0..1 per cell for an Overlay mode, for the map overlay.
func overlay_values(mode: int) -> PackedFloat32Array:
	update()
	match mode:
		Overlay.POWER:
			var out := PackedFloat32Array()
			out.resize(N)
			for i in N:
				out[i] = [0.0, 0.25, 1.0][power[i]] if power_line[i] == 0 or power[i] != 0 else 0.6
			return out
		Overlay.PARKS: return park
		Overlay.POLICE: return police
		Overlay.FIRE: return fire
		# Per-building numbers spread onto the streets around them, so they show between towers.
		Overlay.GARBAGE: return _spread(garbage)
		Overlay.CRIME: return _spread(crime)
		Overlay.HAPPINESS: return _spread(happiness)
	return PackedFloat32Array()


## Average of the built cells around each cell (radius 1), 0 where nothing is built nearby.
func _spread(f: PackedFloat32Array) -> PackedFloat32Array:
	var built := PackedFloat32Array()
	built.resize(N)
	for i in N:
		if city.bld[i] >= 0:
			built[i] = 1.0
	var sum := city._blur(f, 1)
	var cnt := city._blur(built, 1)
	var out := PackedFloat32Array()
	out.resize(N)
	for i in N:
		out[i] = sum[i] / cnt[i] if cnt[i] > 0.01 else 0.0
	return out


# ------------------------------------------------------------------ coverage ---

func _compute_coverage() -> void:
	park.fill(0.0)
	police.fill(0.0)
	fire.fill(0.0)
	garbage_reach.fill(0.0)
	for id in facilities:
		if not city.buildings.has(id):
			continue
		var d := ServiceDefs.get_def(facilities[id])
		var b: Dictionary = city.buildings[id]
		var cx: float = b.x + b.size * 0.5
		var cy: float = b.y + b.size * 0.5
		var r: float = d.get("radius", 0.0)
		match d.service:
			"park": _stamp(park, cx, cy, r, d.strength, false)
			"police": _stamp(police, cx, cy, r, d.strength, false)
			"fire": _stamp(fire, cx, cy, r, d.strength, false)
			"garbage": _stamp(garbage_reach, cx, cy, r, 1.0, true)
	for f in [park, police, fire, garbage_reach]:
		for i in N:
			f[i] = minf(f[i], 1.0)


## Adds a radial falloff (or a flat disc with a soft rim) around a point in tile units.
func _stamp(field: PackedFloat32Array, cx: float, cy: float, r: float, s: float, flat: bool) -> void:
	if r <= 0.0:
		return
	for y in range(maxi(0, floori(cy - r)), mini(City.H, ceili(cy + r) + 1)):
		var x0 := floori(cx - r) if Planet.on else maxi(0, floori(cx - r))
		var x1 := ceili(cx + r) + 1 if Planet.on else mini(City.W, ceili(cx + r) + 1)
		for x in range(x0, x1):
			var t := Vector2(x + 0.5 - cx, y + 0.5 - cy).length() / r
			if t >= 1.0:
				continue
			var v := s * (clampf((1.0 - t) * 5.0, 0.0, 1.0) if flat else 1.0 - t * t)
			field[y * City.W + posmod(x, City.W)] += v


# --------------------------------------------------------------------- power ---

func _demand(b: Dictionary) -> float:
	if b.has("kind"):
		if ServiceDefs.service_of(b.kind) == "power":
			return 0.0
		return ServiceDefs.SPECIAL_MW * maxi(int(b.size), 1)
	return city.capacity(b) * ServiceDefs.MW_PER_CAP[b.zone]


## Plants feed every building connected to them through roads, power lines, zoned land and other
## buildings. Each connected network pools its plants' output; when demand is higher, the
## buildings nearest a plant get power first.
func _compute_power() -> void:
	var cond := PackedByteArray()
	cond.resize(N)
	for i in N:
		if city.road[i] == 1 or power_line[i] == 1 or city.bld[i] >= 0 or city.zone[i] != City.Zone.NONE:
			cond[i] = 1
	var comp := PackedInt32Array()
	comp.resize(N)
	comp.fill(-1)
	var label := 0
	for s0 in N:
		if cond[s0] == 0 or comp[s0] >= 0:
			continue
		var stack := PackedInt32Array([s0])
		comp[s0] = label
		while not stack.is_empty():
			var c: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			for j in _neighbours(c):
				if cond[j] == 1 and comp[j] < 0:
					comp[j] = label
					stack.append(j)
		label += 1
	var remaining := {}
	var q := PackedInt32Array()
	var seen := PackedByteArray()
	seen.resize(N)
	supply_mw = 0.0
	for id in facilities:
		var d := ServiceDefs.get_def(facilities[id])
		if d.service != "power" or not city.buildings.has(id):
			continue
		var b: Dictionary = city.buildings[id]
		var lab := comp[city.idx(b.x, b.y)]
		var mw := float(d.mw) * supply_scale
		remaining[lab] = float(remaining.get(lab, 0.0)) + mw
		supply_mw += mw
		for dy in b.size:
			for dx in b.size:
				var i := city.idx(b.x + dx, b.y + dy)
				if seen[i] == 0:
					seen[i] = 1
					q.append(i)
	var got := {}
	demand_mw = 0.0
	for b in city.buildings.values():
		demand_mw += _demand(b)
	var served := 0.0
	var head := 0
	while head < q.size():
		var c: int = q[head]
		head += 1
		var bid := city.bld[c]
		if bid >= 0 and not got.has(bid):
			var need := _demand(city.buildings[bid])
			var lab := comp[c]
			var left: float = remaining.get(lab, 0.0)
			got[bid] = left >= need
			if left >= need:
				remaining[lab] = left - need
				served += need
		for j in _neighbours(c):
			if cond[j] == 1 and seen[j] == 0:
				seen[j] = 1
				q.append(j)
	for b in city.buildings.values():
		b["powered"] = bool(got.get(b.id, false))
	for i in N:
		var bid := city.bld[i]
		if bid >= 0:
			power[i] = 2 if got.get(bid, false) else 1
		elif cond[i] == 1:
			power[i] = 2 if float(remaining.get(comp[i], 0.0)) > 0.5 and seen[i] == 1 else 1
		else:
			power[i] = 0
	power_pct = 100.0 if demand_mw <= 0.0 else served / demand_mw * 100.0


func _neighbours(c: int) -> PackedInt32Array:
	var x := c % City.W
	var y := c / City.W
	var out := PackedInt32Array()
	if x > 0: out.append(c - 1)
	elif Planet.on: out.append(c + City.W - 1)
	if x < City.W - 1: out.append(c + 1)
	elif Planet.on: out.append(c - City.W + 1)
	if y > 0: out.append(c - City.W)
	if y < City.H - 1: out.append(c + City.W)
	return out


# ----------------------------------------------------------------- the day ---

func _on_day() -> void:
	update()
	_garbage_day()
	_crime_and_happiness()
	_upkeep()
	_decay()
	# City._day_tick just re-derived "connected"; unpowered buildings can't upgrade either.
	if power_in_play():
		for b in city.buildings.values():
			if not b.get("powered", true):
				b.connected = false
	if city.progress != null:
		var st := stats()
		city.progress.set_stats({"power_pct": st.power_pct, "garbage_pct": st.garbage_pct, "crime": st.crime,
			"happiness": st.happiness, "approval": st.approval, "income_per_resident": st.income_per_resident})
	stats_changed.emit()


func _garbage_day() -> void:
	var depots: Array[Dictionary] = []
	for id in facilities:
		var d := ServiceDefs.get_def(facilities[id])
		if d.service == "garbage" and city.buildings.has(id):
			var b: Dictionary = city.buildings[id]
			depots.append({"x": b.x + b.size * 0.5, "y": b.y + b.size * 0.5, "r": float(d.radius),
				"left": float(d.tons)})
	garbage.fill(0.0)
	var made := 0.0
	var taken := 0.0
	for b in city.buildings.values():
		var prod: float = ServiceDefs.SPECIAL_TONS * maxi(int(b.size), 1) if b.has("kind") else city.capacity(b) * ServiceDefs.TONS_PER_CAP[b.zone]
		if prod <= 0.0:
			continue
		var need: float = backlog.get(b.id, 0.0) + prod
		var bx: float = b.x + b.size * 0.5
		var by: float = b.y + b.size * 0.5
		var near: Array = []
		for dp in depots:
			var dist := Vector2(bx - dp.x, by - dp.y).length()
			if dist <= dp.r and dp.left > 0.0:
				near.append([dist, dp])
		near.sort_custom(func(a, c): return a[0] < c[0])
		var got := 0.0
		for e in near:
			var dp: Dictionary = e[1]
			var t := minf(need - got, dp.left)
			dp.left -= t
			got += t
			if got >= need:
				break
		made += prod
		taken += minf(got, prod)
		var left := minf(need - got, prod * 10.0)
		if left > 0.001:
			backlog[b.id] = left
		else:
			backlog.erase(b.id)
		var lvl := clampf(left / maxf(prod * 4.0, 0.05), 0.0, 1.0)
		for dy in b.size:
			for dx in b.size:
				garbage[city.idx(b.x + dx, b.y + dy)] = lvl
	garbage_tons = made
	garbage_pct = 100.0 if made <= 0.0 else taken / made * 100.0


func _crime_and_happiness() -> void:
	var dens := PackedFloat32Array()
	dens.resize(N)
	for b in city.buildings.values():
		if b.size == 0:
			continue
		var c := float(city.capacity(b)) / float(b.size * b.size)
		for dy in b.size:
			for dx in b.size:
				dens[city.idx(b.x + dx, b.y + dy)] = minf(c / 140.0, 1.5)
	dens = city._blur(dens, 2)
	var workers := city.population * 0.55
	var jobs := float(city.jobs_c + city.jobs_i)
	var jobless := clampf((workers - jobs) / maxf(workers, 1.0), 0.0, 1.0) if workers > 0 else 0.0
	var good := current_goodness()
	var good_bias := -good / 100.0 * 0.2
	var tax_pen := maxf(city.tax_rate - 0.07, 0.0) * 2.5
	# Street results from missions/ (a busted crime den, a good Game day), when present.
	var fx: Object = city.get_meta("street_effects", null)
	crime.fill(0.0)
	fire_risk.fill(0.0)
	happiness.fill(0.0)
	var crime_w := 0.0
	var happy_w := 0.0
	var people := 0.0
	var res_people := 0.0
	for b in city.buildings.values():
		if b.size == 0:
			continue
		var i := city.idx(b.x, b.y)
		var lv := city.land_value[i]
		var base := 0.12 + 0.35 * minf(dens[i], 1.0) + 0.3 * (1.0 - lv) + 0.25 * jobless + good_bias + 0.1 * garbage[i]
		var cr := clampf(base - 0.75 * police[i], 0.0, 1.0)
		if fx != null:
			cr *= fx.crime_mult(b.x, b.y)
		var fr := clampf((0.15 + 0.4 * minf(dens[i], 1.0) + (0.25 if b.zone == City.Zone.IND else 0.0)) * (1.0 - 0.85 * fire[i]), 0.0, 1.0)
		var h := 0.45 + 0.2 * lv + 0.25 * park[i] - 0.35 * cr - 0.25 * garbage[i] - 0.1 * fr - tax_pen
		if power_in_play() and not b.get("powered", true):
			h -= 0.35
		if fx != null:
			h += fx.happiness_add(b.x, b.y)
		h = clampf(h, 0.0, 1.0)
		for dy in b.size:
			for dx in b.size:
				var j := city.idx(b.x + dx, b.y + dy)
				crime[j] = cr
				fire_risk[j] = fr
				happiness[j] = h
		var cap := float(city.capacity(b))
		people += cap
		crime_w += cr * cap
		if b.zone == City.Zone.RES:
			res_people += cap
			happy_w += h * cap
	crime_avg = crime_w / people if people > 0.0 else 0.0
	happiness_avg = happy_w / res_people if res_people > 0.0 else 0.5
	var target := 100.0 * (0.75 * happiness_avg + 0.25 * (0.5 + good / 200.0)) - maxf(city.tax_rate - 0.09, 0.0) * 300.0
	approval = clampf(approval + (target - approval) * 0.3, 0.0, 100.0)
	# Income per resident ($ / year): richer homes and more jobs mean a richer city.
	if city.population > 0:
		var lv_sum := 0.0
		for b in city.buildings.values():
			if b.zone == City.Zone.RES:
				lv_sum += city.land_value[city.idx(b.x, b.y)] * city.capacity(b)
		var emp := clampf(jobs / maxf(workers, 1.0), 0.0, 1.0)
		income_per_resident = 22000.0 + 55000.0 * (lv_sum / float(city.population)) * emp
	else:
		income_per_resident = 0.0


## City charges catalog buildings' upkeep; power lines are services' own.
func _upkeep() -> void:
	var u := 0.0
	for i in N:
		u += power_line[i] * ServiceDefs.POWER_LINE_UPKEEP
	city.funds -= u
	city.last_expense += u
	last_upkeep = u


## Buildings without power, or whose people are miserable, slowly empty out.
func _decay() -> void:
	var in_play := power_in_play()
	var drop: Array[Dictionary] = []
	var dark := 0
	for b in city.buildings.values():
		if b.has("kind") or b.zone == City.Zone.NONE:
			continue
		var id: int = b.id
		if in_play and not b.get("powered", true):
			unpowered_days[id] = int(unpowered_days.get(id, 0)) + 1
			dark += 1
		else:
			unpowered_days.erase(id)
		if b.zone == City.Zone.RES and happiness[city.idx(b.x, b.y)] < UNHAPPY:
			unhappy_days[id] = int(unhappy_days.get(id, 0)) + 1
		else:
			unhappy_days.erase(id)
		if int(unpowered_days.get(id, 0)) >= DECAY_DAYS or int(unhappy_days.get(id, 0)) >= DECAY_DAYS:
			drop.append(b)
	if dark > 0 and city.game_day() % 3 == 0:
		city.message.emit("%d buildings have no power. Build a power plant or more capacity." % dark)
	drop.shuffle()
	for k in mini(drop.size(), MAX_DECAY_PER_DAY):
		var b: Dictionary = drop[k]
		city.remove_building(b.id)
		if b.size == 1 and b.stage > 1:
			city.add_building(b.x, b.y, 1, b.zone, b.stage - 1, b.rot, false)


# ------------------------------------------------------------------- saving ---

func to_dict() -> Dictionary:
	var lines := PackedInt32Array()
	for i in N:
		if power_line[i] == 1:
			lines.append(i)
	return {
		"lines": Array(lines), "backlog": _keys_to_str(backlog), "unpowered": _keys_to_str(unpowered_days),
		"unhappy": _keys_to_str(unhappy_days), "approval": approval,
	}


## Call after the City itself is loaded (its buildings carry the "kind" keys).
func from_dict(d: Dictionary) -> void:
	power_line.fill(0)
	for i in d.get("lines", []):
		power_line[int(i)] = 1
	backlog = _keys_to_int(d.get("backlog", {}))
	unpowered_days = _keys_to_int(d.get("unpowered", {}))
	unhappy_days = _keys_to_int(d.get("unhappy", {}))
	approval = float(d.get("approval", 55.0))
	rescan()
	update()


static func _keys_to_str(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src:
		out[str(k)] = src[k]
	return out


static func _keys_to_int(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src:
		out[int(k)] = src[k]
	return out


# -------------------------------------------------------------------- demo ---

## Gives the pre-built demo city enough services to run: plants, depots, police, fire and parks
## on free land near the edges of its districts, free of charge and whatever is unlocked.
func build_demo_services() -> void:
	var c := city.center_cell()
	var want := [["coal_plant", Vector2i(-26, -22)], ["coal_plant", Vector2i(-26, 20)], ["coal_plant", Vector2i(26, -22)],
		["coal_plant", Vector2i(26, 20)], ["gas_plant", Vector2i(-28, 0)], ["gas_plant", Vector2i(28, 0)],
		["garbage_depot", Vector2i(-24, -10)], ["garbage_depot", Vector2i(-20, 0)], ["garbage_depot", Vector2i(20, 0)],
		["garbage_depot", Vector2i(0, -20)], ["garbage_depot", Vector2i(0, 20)],
		["police_station", Vector2i(-12, -10)], ["police_station", Vector2i(12, 10)],
		["police_station", Vector2i(-12, 12)], ["police_station", Vector2i(12, -12)], ["police_station", Vector2i(0, 0)],
		["fire_station", Vector2i(-16, 4)], ["fire_station", Vector2i(16, -4)], ["fire_station", Vector2i(0, -14)],
		["fire_station", Vector2i(2, 15)],
		["small_park", Vector2i(-5, -5)], ["small_park", Vector2i(5, 5)], ["small_park", Vector2i(-8, 8)],
		["small_park", Vector2i(8, -8)], ["small_park", Vector2i(-18, -12)], ["small_park", Vector2i(18, 12)]]
	for w in want:
		var spot := _free_spot_near(w[0], c + w[1])
		if spot.x >= 0:
			_take_lot(w[0], spot)
			place_facility(w[0], spot, true)
	update()


func _free_spot_near(kind: String, at: Vector2i) -> Vector2i:
	## Nearest top-left cell where the footprint is land with no road (buildings are bulldozed).
	var s: int = Catalog.get_def(kind).size
	for r in 8:
		for y in range(at.y - r, at.y + r + 1):
			for x in range(at.x - r, at.x + r + 1):
				if maxi(absi(x - at.x), absi(y - at.y)) != r:
					continue
				var ok := true
				for dy in s:
					for dx in s:
						var cx := x + dx
						var cy := y + dy
						if not city.inside(cx, cy) or city.land[city.idx(cx, cy)] == 0 or city.road[city.idx(cx, cy)] == 1 \
								or (city.bld[city.idx(cx, cy)] >= 0 and city.buildings[city.bld[city.idx(cx, cy)]].has("kind")):
							ok = false
				if ok and city.road_access_dir(x, y) >= 0:
					return Vector2i(x, y)
	return Vector2i(-1, -1)


func _take_lot(kind: String, at: Vector2i) -> void:
	var s: int = Catalog.get_def(kind).size
	for dy in s:
		for dx in s:
			var bid := city.bld[city.idx(at.x + dx, at.y + dy)]
			if bid >= 0:
				city.remove_building(bid)
