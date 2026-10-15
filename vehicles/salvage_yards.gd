class_name SalvageYards
extends Node
## The tow trucks belong to salvage yards (catalog "salvage_yard", unlocked at 1,000 people).
## Each yard owns TRUCKS_PER_YARD trucks. A truck at home is parked at the kerb in front of
## its yard (a real DrivableCar, so it can be stolen) while the player is near enough to
## see it. TowService asks here how many trucks are free, takes one when it sends a truck
## out (the parked one leaves the kerb) and gives it back when the truck gets home.
##
## A parked truck the player drives off is gone: the yard buys a new one after a while.
##
## Wiring (scripts/main.gd, after `street` exists):
##   yards = SalvageYards.new(); yards.setup(city, street); add_child(yards); tow.yards = yards

const KIND := "salvage_yard"
const TRUCKS_PER_YARD := 2
const SHOW_RADIUS := 230.0      # parked trucks stand at the kerb while the player is this near
const HIDE_RADIUS := 280.0
const REPLACE_SECONDS := 240.0  # a stolen truck is replaced after this long
const PARK_OUT := 2.85          # as StreetMode parks cars: kerbside, traffic can squeeze past
const SPACING := 4.4            # the two trucks stand this far either side of the yard's middle
const TRUCK_COLOR := Color(0.95, 0.62, 0.12)

enum Slot { HOME, OUT, GONE }

var city: City
var street: Node
var _yards := {}                # building id -> {slots: [Slot], cars: [DrivableCar], wait: [float]}
var _scan := 0.0


func setup(c: City, street_mode: Node) -> void:
	city = c
	street = street_mode
	city.building_added.connect(func(_id, _a): _sync())
	city.building_removed.connect(func(_id): _sync())
	_sync()


## Yard building ids, in placement order.
func ids() -> Array:
	return _yards.keys()


## Trucks parked at home across all yards: the ones TowService may send out.
func free_trucks() -> int:
	var n := 0
	for id in _yards:
		for s in _yards[id].slots:
			n += 1 if s == Slot.HOME else 0
	return n


## Trucks out on jobs.
func out_trucks() -> int:
	var n := 0
	for id in _yards:
		for s in _yards[id].slots:
			n += 1 if s == Slot.OUT else 0
	return n


## The yard with a free truck nearest a flat map point, or -1.
func nearest_free(at: Vector3) -> int:
	var best := -1
	var best_d := INF
	for id in _yards:
		if not Slot.HOME in _yards[id].slots:
			continue
		var d := Planet.fdist(city.building_center(city.buildings[id]), at)
		if d < best_d:
			best_d = d
			best = id
	return best


## The nearest yard (free truck or not) to a flat map point, or -1.
func nearest(at: Vector3) -> int:
	var best := -1
	var best_d := INF
	for id in _yards:
		var d := Planet.fdist(city.building_center(city.buildings[id]), at)
		if d < best_d:
			best_d = d
			best = id
	return best


## Send one of a yard's trucks out. Returns the flat point it leaves from (its kerb spot),
## or Vector3.INF when the yard has none at home.
func take(id: int) -> Vector3:
	var y: Dictionary = _yards.get(id, {})
	if y.is_empty():
		return Vector3.INF
	var i: int = y.slots.find(Slot.HOME)
	if i < 0:
		return Vector3.INF
	y.slots[i] = Slot.OUT
	var car: DrivableCar = y.cars[i]
	if car != null and is_instance_valid(car):
		car.queue_free()
	y.cars[i] = null
	return spot(id, i).origin


## A truck is back (or was lost on the way, which the yard shrugs off).
func back(id: int) -> void:
	var y: Dictionary = _yards.get(id, {})
	if y.is_empty():
		return
	var i: int = y.slots.find(Slot.OUT)
	if i >= 0:
		y.slots[i] = Slot.HOME


## The road cell in front of a yard, where trucks come and go.
func gate_cell(id: int) -> Vector2i:
	var b: Dictionary = city.buildings.get(id, {})
	if b.is_empty():
		return Vector2i(-1, -1)
	var d: Vector2i = City.DIRS[int(b.rot)]
	var front: Vector3 = city.building_center(b) + Vector3(d.x, 0, d.y) * (b.size * City.TILE * 0.5 + City.TILE * 0.5)
	var cell := city.flat_to_cell(front)
	if city.is_road(cell.x, cell.y):
		return cell
	return Vector2i(-1, -1)


## Flat transform of parking spot i in front of yard id (origin on the road surface, -Z
## the way the truck faces).
func spot(id: int, i: int) -> Transform3D:
	var b: Dictionary = city.buildings[id]
	var d: Vector2i = City.DIRS[int(b.rot)]
	var cell := gate_cell(id)
	var c: Vector3
	if cell.x >= 0:
		c = city.cell_center(cell.x, cell.y)
	else:
		c = city.building_center(b) + Vector3(d.x, 0, d.y) * (b.size * City.TILE * 0.5 + City.TILE * 0.5)
	var along := SPACING * (-1.0 if i == 0 else 1.0)
	var pos: Vector3
	var yaw: float
	if d.x == 0:      # the yard faces north or south: the road runs along X
		var side := -float(d.y)
		pos = c + Vector3(along, 0.15, side * PARK_OUT)
		yaw = PI * 0.5 if side > 0.0 else -PI * 0.5
	else:             # faces east or west: the road runs along Z
		var side := -float(d.x)
		pos = c + Vector3(side * PARK_OUT, 0.15, along)
		yaw = 0.0 if side < 0.0 else PI
	return Transform3D(Basis(Vector3.UP, yaw), pos)


func _sync() -> void:
	## Yards placed or bulldozed: keep one entry per yard.
	var have := {}
	for b in city.specials_of(KIND):
		have[b.id] = true
		if not _yards.has(b.id):
			var slots := []
			var cars := []
			var wait := []
			for i in TRUCKS_PER_YARD:
				slots.append(Slot.HOME)
				cars.append(null)
				wait.append(0.0)
			_yards[b.id] = {"slots": slots, "cars": cars, "wait": wait}
	for id in _yards.keys():
		if not have.has(id):
			for car in _yards[id].cars:
				if car != null and is_instance_valid(car) and car.driver == null:
					car.queue_free()
			_yards.erase(id)


func _process(dt: float) -> void:
	for id in _yards:
		var y: Dictionary = _yards[id]
		for i in y.slots.size():
			if y.slots[i] == Slot.GONE:
				y.wait[i] -= dt
				if y.wait[i] <= 0.0:
					y.slots[i] = Slot.HOME
	_scan -= dt
	if _scan > 0.0:
		return
	_scan = 0.5
	if street == null or not street.get("active"):
		_park_none()
		return
	var p := Planet.flat(street.player_position())
	for id in _yards:
		var y: Dictionary = _yards[id]
		var d := Planet.fdist(city.building_center(city.buildings[id]), p)
		for i in y.slots.size():
			var car = y.cars[i]
			if car != null and not is_instance_valid(car):
				car = null
				y.cars[i] = null
				if y.slots[i] == Slot.HOME and d < HIDE_RADIUS:
					_lose(y, i)   # blown up or towed off while parked here
					continue
			if car != null and (car.driver != null or car.get_meta("towing", false)
					or Planet.flat(car.global_position).distance_to(spot(id, i).origin) > 8.0):
				# Someone drove it off (or it was shoved away): it isn't the yard's any more.
				car.remove_meta("yard_truck")
				y.cars[i] = null
				_lose(y, i)
				continue
			if y.slots[i] == Slot.HOME and car == null and d < SHOW_RADIUS:
				y.cars[i] = _park(id, i)
			elif car != null and d > HIDE_RADIUS:
				car.queue_free()
				y.cars[i] = null


func _lose(y: Dictionary, i: int) -> void:
	y.slots[i] = Slot.GONE
	y.wait[i] = REPLACE_SECONDS


func _park(id: int, i: int) -> DrivableCar:
	var sp := spot(id, i)
	var pos := Planet.place(sp.origin)
	for v in get_tree().get_nodes_in_group("vehicles"):
		if (v as Node3D).global_position.distance_to(pos) < 4.0:
			return null   # something is in the way; try again later
	var yaw := sp.basis.get_euler().y
	var car: DrivableCar = street.spawn_car("car_tow", pos, yaw, TRUCK_COLOR)
	if car == null:
		return null
	car.set_meta("parked", true)      # the yard's: taking it is theft
	car.set_meta("yard_truck", id)
	return car


func _park_none() -> void:
	for id in _yards:
		var y: Dictionary = _yards[id]
		for i in y.cars.size():
			var car = y.cars[i]
			if car != null and is_instance_valid(car) and car.driver == null:
				car.queue_free()
			y.cars[i] = null
