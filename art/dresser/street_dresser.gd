class_name StreetDresser
extends Node3D
## Street dressing: trees, hydrants, bins, meters, signs, neon, café tables, planters,
## shop fronts on blank ground floors, ground wear, graffiti, grass and rocks. Everything
## is worked out from the City data, so it follows whatever the Mayor builds, and only
## drawn near the camera at street level (nothing in the mayor view, which keeps the
## kit's own trees and lamps).
##
## Wiring (main.gd, once the City exists; services is optional):
##     var dresser := StreetDresser.new()
##     add_child(dresser)
##     dresser.setup(city, services, life.spots)
##
## Each prop type is one MultiMesh over the whole dressed area, so the dressing costs
## roughly one draw call per prop type and material (about 60 to 90 in all), not one per
## prop. Placement is deterministic per cell: the same city always gets the same street.
##
## Benches and bus shelters belong to citylife (StreetSpots, where people sit and wait); the
## dresser reads their spots and keeps its own props clear of them.

signal dressed(center: Vector3, props: int)

const STREET := "res://assets/kit/street/"
const PROPS := "res://assets/kit/props/"
const DECALS := preload("res://art/dresser/decals.png")
const DECAL_SHADER := preload("res://art/dresser/decal.gdshader")

const SWH := 0.17            # sidewalk top
const LOT := 0.12            # lot paving top
const CURB := 4.3            # metres from a road tile's centre line: kerbside props
const WALL := 5.45           # ... and props against the lots
const SLOTS := [-3.4, 3.4]   # along the sidewalk; lamps and payphones stand at 0

## Name -> [folder, draw radius, casts shadow, collider]. Small things only appear close up.
const TYPES := {
	"tree_street_a": ["street", 170.0, true, "trunk"],
	"tree_street_b": ["street", 170.0, true, "trunk"],
	"tree_street_c": ["street", 170.0, true, "trunk"],
	"bush_low": ["street", 90.0, false, ""],
	"grass_tuft_a": ["street", 45.0, false, ""],
	"grass_tuft_b": ["street", 45.0, false, ""],
	"flowers": ["street", 60.0, false, ""],
	"rock_a": ["street", 140.0, true, "rock"],
	"rock_b": ["street", 140.0, true, "rock"],
	"rock_c": ["street", 90.0, false, ""],
	"trash_overflow": ["street", 80.0, false, "bin"],
	"trash_bags": ["street", 70.0, false, ""],
	"parking_meter": ["street", 60.0, false, "post"],
	"street_sign": ["street", 110.0, false, "post"],
	"cafe_set": ["street", 100.0, true, "cafe"],
	"neon_bar": ["street", 170.0, false, ""],
	"neon_open": ["street", 170.0, false, ""],
	"neon_hotel": ["street", 170.0, false, ""],
	"neon_pizza": ["street", 170.0, false, ""],
	"neon_24h": ["street", 170.0, false, ""],
	"storefront_a": ["street", 190.0, true, "shopfront"],
	"storefront_b": ["street", 190.0, true, "shopfront"],
	"storefront_c": ["street", 190.0, true, "shopfront"],
	"storefront_d": ["street", 190.0, true, "shopfront"],
	"storefront_half": ["street", 190.0, true, "shopfront_half"],
	"hydrant": ["props", 70.0, false, "post"],
	"trash_bin": ["props", 70.0, false, "bin"],
	"mailbox": ["props", 70.0, false, "bin"],
	"news_box": ["props", 70.0, false, "bin"],
	"planter": ["props", 90.0, false, "bin"],
	"bollard": ["props", 60.0, false, "post"],
	"billboard": ["props", 200.0, true, "billboard"],
}
const STOREFRONTS := ["storefront_a", "storefront_b", "storefront_c", "storefront_d"]
const NEONS := ["neon_bar", "neon_open", "neon_hotel", "neon_pizza", "neon_24h"]
const NEON_COLORS := [Color(1.0, 0.2, 0.55), Color(0.2, 0.85, 1.0), Color(1.0, 0.85, 0.2),
	Color(0.4, 1.0, 0.35), Color(1.0, 0.5, 0.15), Color(0.75, 0.35, 1.0)]
const FLOWER_COLORS := [Color(1.0, 0.45, 0.6), Color(1.0, 0.85, 0.25), Color(0.95, 0.95, 0.95),
	Color(0.7, 0.45, 1.0), Color(1.0, 0.5, 0.2)]
const DECAL_RADIUS := 70.0

@export var max_height := 70.0      ## camera height above which nothing is dressed (mayor view)
@export var rebuild_distance := 24.0
@export var collision_radius := 60.0
@export var enabled := true

var city: City
var services: Object = null          ## CityServices, for garbage and crime (optional)
var spots: Object = null             ## citylife StreetSpots: benches and bus shelters (optional)
var center := Vector3(INF, 0, INF)   ## where the dressed area is centred now
var prop_count := 0

var _meshes := {}                    # type -> Mesh
var _mmis := {}                      # type -> MultiMeshInstance3D
var _decal_mmi: MultiMeshInstance3D
var _cells := {}                     # Vector2i -> {"props": [...], "decals": [...]}
var _bands := {}                     # building mesh name -> Rect2 of the ground floor (x, z)
var _body: StaticBody3D
var _shapes := {}
var _dirty := true
var _spot_at := {}                   # road cell index -> Array of [position, keep-clear radius]
var _spot_count := -1


func setup(c: City, svc: Object = null, street_spots: Object = null) -> void:
	## street_spots: citylife's StreetSpots (life.spots), so props keep off benches and stops.
	city = c
	services = svc
	spots = street_spots
	city.cells_changed.connect(_invalidate_rect)
	city.building_added.connect(func(id: int, _a: bool) -> void: _invalidate_building(id))
	city.building_removed.connect(func(_id: int) -> void: _forget_all())
	if services and services.has_signal("stats_changed"):
		services.stats_changed.connect(_forget_all)  # garbage and crime move once a day
	_load_meshes()
	_make_shapes()
	_forget_all()


func _forget_all() -> void:
	_cells.clear()
	_dirty = true
	_spot_at.clear()
	_spot_count = -1
	if spots and spots.get("spots") != null:
		_spot_count = spots.spots.size()
		for sp in spots.spots:
			if not _spot_at.has(sp.cell):
				_spot_at[sp.cell] = []
			# keep clear: a bench is 1.8 m long, a shelter 3.6 m plus its sign pole
			_spot_at[sp.cell].append([sp.xform.origin, 1.9 if sp.kind == 0 else 3.1])


func _clear_of_spots(i: int, p: Vector3) -> bool:
	for s in _spot_at.get(i, []):
		var q: Vector3 = s[0]
		if Vector2(p.x - q.x, p.z - q.z).length() < s[1]:
			return false
	return true


func _invalidate_rect(r: Rect2i) -> void:
	for y in range(r.position.y - 1, r.end.y + 1):
		for x in range(r.position.x - 1, r.end.x + 1):
			_cells.erase(Vector2i(x, y))
	_dirty = true


func _invalidate_building(id: int) -> void:
	var b: Dictionary = city.buildings.get(id, {})
	if b.is_empty():
		return
	var s := maxi(int(b.size), 1)
	_invalidate_rect(Rect2i(b.x, b.y, s, s))


# ----------------------------------------------------------------- update ---

func _process(_delta: float) -> void:
	if city == null:
		return
	var cam := get_viewport().get_camera_3d()
	var eye := Planet.flat(cam.global_position) if cam else Vector3.ZERO
	var show := enabled and cam != null and eye.y < max_height
	visible = show
	if _body:
		_body.process_mode = Node.PROCESS_MODE_INHERIT if show else Node.PROCESS_MODE_DISABLED
	if not show:
		return
	if spots and spots.get("spots") != null and spots.spots.size() != _spot_count:
		_forget_all()   # citylife moved its benches and stops (road edits, a new day)
	var fwd := Planet.to_local(cam.global_position, -cam.global_basis.z)  # flat map axes
	fwd.y = 0.0
	var at := eye + (fwd.normalized() * 25.0 if fwd.length() > 0.01 else Vector3.ZERO)
	at.y = 0.0
	if _dirty or Planet.fdist(at, center) > rebuild_distance:
		rebuild(at)


func rebuild(at: Vector3) -> void:
	## Re-dress around a point. Called on its own as the camera moves; tests call it directly.
	## Everything here is flat map metres; _fill and _build_collision put it on the ball.
	center = at
	_dirty = false
	var groups := {}
	var decals: Array = []
	var cr := Vector2i(floori(at.x / City.TILE), floori(at.z / City.TILE))
	var reach := int(ceil(200.0 / City.TILE))
	var colliders: Array = []
	prop_count = 0
	for y in range(cr.y - reach, cr.y + reach + 1):
		for xx in range(cr.x - reach, cr.x + reach + 1):
			var x := posmod(xx, City.W) if Planet.on else xx  # msp: wrap across the seam
			if not city.inside(x, y):
				continue
			var cc := city.cell_center(x, y)
			var dc := Planet.fdist(at, cc)
			if dc > 205.0:
				continue
			var data := cell(x, y)
			for it in data.props:
				var t: Array = TYPES[it[0]]
				var p: Vector3 = it[1].origin
				var d := Planet.fdist(at, p)
				if d > t[1]:
					continue
				if not groups.has(it[0]):
					groups[it[0]] = []
				groups[it[0]].append(it)
				if t[3] != "" and d < collision_radius:
					colliders.append([t[3], it[1]])
			if dc < DECAL_RADIUS + 10.0:
				for dd in data.decals:
					var q: Vector3 = dd[1].origin
					if Planet.fdist(at, q) < DECAL_RADIUS:
						decals.append(dd)
	for nm in _mmis:
		if not groups.has(nm):
			_mmis[nm].multimesh.instance_count = 0
	for nm in groups:
		_fill(nm, groups[nm])
		prop_count += groups[nm].size()
	_fill_decals(decals)
	_build_collision(colliders)
	dressed.emit(at, prop_count)


func _fill(nm: String, items: Array) -> void:
	var mmi: MultiMeshInstance3D = _mmis.get(nm)
	if mmi == null:
		var mesh: Mesh = _meshes.get(nm)
		if mesh == null:
			return
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mmi = MultiMeshInstance3D.new()
		mmi.name = nm
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if TYPES[nm][2] \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_mmis[nm] = mmi
	var m := mmi.multimesh
	m.instance_count = items.size()
	for k in items.size():
		var it: Array = items[k]
		m.set_instance_transform(k, Planet.xf_rigid(it[1]))
		m.set_instance_color(k, it[2])
		m.set_instance_custom_data(k, it[3])
	# Bounds for culling: the whole dressed area.
	mmi.custom_aabb = _bounds(210.0, 40.0)


func _fill_decals(items: Array) -> void:
	if _decal_mmi == null:
		var quad := QuadMesh.new()
		quad.orientation = PlaneMesh.FACE_Y
		quad.size = Vector2(1, 1)
		var mat := ShaderMaterial.new()
		mat.shader = DECAL_SHADER
		mat.set_shader_parameter("atlas", DECALS)
		quad.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = quad
		_decal_mmi = MultiMeshInstance3D.new()
		_decal_mmi.name = "decals"
		_decal_mmi.multimesh = mm
		_decal_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_decal_mmi)
	var m := _decal_mmi.multimesh
	m.instance_count = items.size()
	for k in items.size():
		var d: Array = items[k]
		m.set_instance_transform(k, Planet.xf_rigid(d[1]))
		m.set_instance_color(k, d[2])
		m.set_instance_custom_data(k, Color(float(d[0]), d[3], 0, 0))
	_decal_mmi.custom_aabb = _bounds(80.0, 30.0)


func _bounds(half: float, tall: float) -> AABB:
	## Culling box for the dressed area (on msp, around the warped centre, any way up).
	if Planet.on:
		return AABB(Planet.place(center) - Vector3.ONE * (half + tall), Vector3.ONE * (half + tall) * 2.0)
	return AABB(center - Vector3(half, 5, half), Vector3(half * 2.0, tall, half * 2.0))


# ---------------------------------------------------------------- collision ---

func _make_shapes() -> void:
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.2
	trunk.height = 3.0
	var post := CylinderShape3D.new()
	post.radius = 0.12
	post.height = 1.2
	var bin := CylinderShape3D.new()
	bin.radius = 0.35
	bin.height = 1.1
	var rock := SphereShape3D.new()
	rock.radius = 0.65
	var cafe := CylinderShape3D.new()
	cafe.radius = 0.8
	cafe.height = 1.0
	var board := BoxShape3D.new()
	board.size = Vector3(4.4, 5.0, 0.4)
	var front := BoxShape3D.new()
	front.size = Vector3(12.0, 4.0, 0.5)
	var half := BoxShape3D.new()
	half.size = Vector3(6.0, 4.0, 0.5)
	# kind -> [shape, offset in the prop's own space]
	_shapes = {
		"trunk": [trunk, Vector3(0, 1.5, 0)], "post": [post, Vector3(0, 0.6, 0)],
		"bin": [bin, Vector3(0, 0.55, 0)], "rock": [rock, Vector3(0, 0.2, 0)],
		"cafe": [cafe, Vector3(0, 0.5, 0)], "billboard": [board, Vector3(0, 2.5, 0)],
		"shopfront": [front, Vector3(0, 2.0, -0.05)], "shopfront_half": [half, Vector3(0, 2.0, -0.05)],
	}


func _build_collision(colliders: Array) -> void:
	if _body:
		_body.queue_free()
	_body = StaticBody3D.new()
	_body.name = "DressingCollision"
	_body.collision_layer = 1
	_body.collision_mask = 0
	for c in colliders:
		var s: Array = _shapes[c[0]]
		var cs := CollisionShape3D.new()
		cs.shape = s[0]
		var xf: Transform3D = Planet.xf_rigid(c[1])
		cs.transform = Transform3D(xf.basis.orthonormalized(), xf * s[1])
		_body.add_child(cs)
	add_child(_body)


# ------------------------------------------------------------- placement ---

func cell(x: int, y: int) -> Dictionary:
	## The props and decals of one cell: {"props": [[type, Transform3D, color, custom]],
	## "decals": [[tile, Transform3D, tint, opacity]]}. Cached until the city changes there.
	var key := Vector2i(x, y)
	if _cells.has(key):
		return _cells[key]
	var out := {"props": [], "decals": []}
	var i := city.idx(x, y)
	if city.road[i] == 1:
		_dress_road(out, x, y)
	elif city.bld[i] >= 0:
		var b: Dictionary = city.buildings[city.bld[i]]
		if b.x == x and b.y == y:
			_dress_building(out, b)
	elif city.land[i] == 1:
		_dress_land(out, x, y)
	elif city.height[i] > 0.02:
		_dress_shore(out, x, y)
	_cells[key] = out
	return out


func _h(x: int, y: int, k: int) -> float:
	return float(hash(Vector3i(x, y, k + 9100)) % 100000) / 100000.0


static func _yaw_facing(dir: Vector3) -> Basis:
	## A basis whose +Z (the front of every kit prop) points along dir.
	return Basis(Vector3.UP, atan2(dir.x, dir.z))


func _add(out: Dictionary, nm: String, xf: Transform3D, col := Color.WHITE, custom := Color(0, 0, 0, 0)) -> void:
	out.props.append([nm, xf, col, custom])


func _decal(out: Dictionary, tile: int, xf: Transform3D, alpha: float, tint := Color.WHITE) -> void:
	out.decals.append([tile, xf, tint, alpha])


func _ground_decal(out: Dictionary, tile: int, p: Vector3, size: float, yaw: float, alpha: float) -> void:
	_decal(out, tile, Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(size, 1, size)), p), alpha)


func _lot_info(x: int, y: int) -> Dictionary:
	## What the sidewalk at this cell's edge looks onto: zone, building, garbage, crime.
	var info := {"kind": "none", "zone": 0, "garbage": 0.0, "crime": 0.0, "b": {}}
	if not city.inside(x, y):
		return info
	var i := city.idx(x, y)
	if services:
		info.garbage = services.garbage[i] if services.garbage.size() > i else 0.0
		info.crime = services.crime[i] if services.crime.size() > i else 0.0
	else:
		info.crime = clampf(0.6 - city.land_value[i], 0.0, 1.0) if city.land_value.size() > i else 0.2
	if city.land[i] == 0:
		info.kind = "sea"
	elif city.bld[i] >= 0:
		var b: Dictionary = city.buildings[city.bld[i]]
		info.b = b
		if b.has("kind"):
			info.kind = "park" if "park" in b.get("tags", []) or b.kind in ["city_park", "plaza", "park"] else "special"
		else:
			info.kind = ["none", "r", "c", "i"][int(b.zone)]
	elif city.zone[i] > 0:
		info.kind = "lot"
		info.zone = int(city.zone[i])
	else:
		info.kind = "empty"
	return info


func _dress_road(out: Dictionary, x: int, y: int) -> void:
	var c := city.cell_center(x, y)
	var mask := city.road_mask(x, y)
	var n := 0
	for bit in [1, 2, 4, 8]:
		if mask & bit:
			n += 1
	var straight := mask == 5 or mask == 10
	var i := city.idx(x, y)
	var has_props := not city.props_at(i).is_empty()
	# Ground wear on the asphalt.
	for k in 2:
		if _h(x, y, 60 + k) < 0.45:
			var tile: int = [0, 1, 2, 3, 4, 6, 7][int(_h(x, y, 62 + k) * 6.99)]
			var p := c + Vector3(_h(x, y, 64 + k) * 6.0 - 3.0, 0.072 + k * 0.002, _h(x, y, 66 + k) * 6.0 - 3.0)
			_ground_decal(out, tile, p, 2.0 + _h(x, y, 68 + k) * 2.5, _h(x, y, 70 + k) * TAU, 0.55 + _h(x, y, 72 + k) * 0.35)
	if n >= 3:
		# A street-name sign on one corner of a junction.
		var cx := 1.0 if _h(x, y, 80) < 0.5 else -1.0
		var cz := 1.0 if _h(x, y, 81) < 0.5 else -1.0
		_add(out, "street_sign", Transform3D(Basis(Vector3.UP, _h(x, y, 82) * TAU), c + Vector3(cx * 5.35, SWH, cz * 5.35)),
			Color.WHITE, Color(0.12, 0.45, 0.2, 0.0))
		if _h(x, y, 83) < 0.5:
			_add(out, "hydrant", Transform3D(Basis(), c + Vector3(-cx * 5.0, SWH, cz * 4.6)), Color.WHITE, Color(0.85, 0.15, 0.1))
		return
	for r in 4:
		var d: Vector2i = City.DIRS[r]
		var nx := x + d.x
		var ny := y + d.y
		if city.is_road(nx, ny):
			continue
		var out_dir := Vector3(d.x, 0, d.y)   # from the road toward the lot
		var along := Vector3(-d.y, 0, d.x)
		var face := _yaw_facing(-out_dir)    # props face the road
		var lot := _lot_info(nx, ny)
		if lot.kind == "sea":
			continue
		var sidewalk_crack := _h(x, y, 90 + r) < 0.3
		if sidewalk_crack:
			var t := _h(x, y, 94 + r) * 8.0 - 4.0
			_ground_decal(out, [0, 1, 5][int(_h(x, y, 98 + r) * 2.99)], c + out_dir * 4.9 + along * t + Vector3(0, SWH + 0.004, 0),
				1.6, _h(x, y, 102 + r) * TAU, 0.5)
		for s in SLOTS.size():
			var t: float = SLOTS[s]
			var k := r * 10 + s
			var curb := c + out_dir * CURB + along * t + Vector3(0, SWH, 0)
			var wall := c + out_dir * WALL + along * t + Vector3(0, SWH, 0)
			if _clear_of_spots(i, curb):
				_curb_item(out, x, y, k, lot, curb, face)
			if _clear_of_spots(i, wall) and not (has_props and absf(t) < 1.5):
				_wall_item(out, x, y, k, lot, wall, face, along)


func _curb_item(out: Dictionary, x: int, y: int, k: int, lot: Dictionary, p: Vector3, face: Basis) -> void:
	var tree_odds := {"r": 0.6, "c": 0.4, "park": 0.6, "empty": 0.35, "lot": 0.45, "special": 0.35, "i": 0.1}
	var h := _h(x, y, 200 + k)
	if h < tree_odds.get(lot.kind, 0.3):
		var pick := _h(x, y, 210 + k)
		var nm := "tree_street_a" if pick < 0.42 else ("tree_street_b" if pick < 0.8 else "tree_street_c")
		var s := 0.9 + _h(x, y, 220 + k) * 0.25
		var tint: Color = Kit.LEAF_TINTS[int(_h(x, y, 230 + k) * 5.99)]
		_add(out, nm, Transform3D(Basis(Vector3.UP, _h(x, y, 240 + k) * TAU).scaled(Vector3.ONE * s), p), tint)
		return
	var u := _h(x, y, 250 + k)
	if lot.kind == "c" or lot.kind == "special":
		if u < 0.35:
			_add(out, "parking_meter", Transform3D(face, p))
		elif u < 0.5:
			_add(out, "news_box", Transform3D(face, p), Color.WHITE, Kit.ACCENTS[int(_h(x, y, 260 + k) * 7.99)])
		elif u < 0.65:
			_bin(out, x, y, k, lot, p, face)
		elif u < 0.75:
			_add(out, "hydrant", Transform3D(face, p), Color.WHITE, Color(0.85, 0.15, 0.1))
	elif lot.kind == "i":
		if u < 0.4:
			for o in [-0.8, 0.8]:
				_add(out, "bollard", Transform3D(face, p + face * Vector3(o, 0, 0)))
		elif u < 0.6:
			_bin(out, x, y, k, lot, p, face)
	else:
		if u < 0.15:
			_add(out, "hydrant", Transform3D(face, p), Color.WHITE, Color(0.85, 0.15, 0.1) if u < 0.1 else Color(0.95, 0.75, 0.1))
		elif u < 0.25:
			_add(out, "mailbox", Transform3D(face, p), Color.WHITE, Color(0.15, 0.3, 0.65))
		elif u < 0.4:
			_bin(out, x, y, k, lot, p, face)


func _bin(out: Dictionary, x: int, y: int, k: int, lot: Dictionary, p: Vector3, face: Basis) -> void:
	if lot.garbage > 0.5:
		_add(out, "trash_overflow", Transform3D(face * Basis(Vector3.UP, _h(x, y, 270 + k) * 0.6 - 0.3), p))
	else:
		_add(out, "trash_bin", Transform3D(face, p), Color.WHITE, Color(0.2, 0.45, 0.25))


func _wall_item(out: Dictionary, x: int, y: int, k: int, lot: Dictionary, p: Vector3, face: Basis, along: Vector3) -> void:
	var u := _h(x, y, 300 + k)
	if lot.garbage > 0.45 and u < 0.2 + lot.garbage * 0.4:
		_add(out, "trash_bags", Transform3D(face * Basis(Vector3.UP, _h(x, y, 310 + k) * TAU), p))
		return
	match lot.kind:
		"c":
			var b: Dictionary = lot.b
			if u < 0.22 and int(b.get("stage", 1)) <= 2:
				var tint: Color = Kit.ACCENTS[int(_h(x, y, 320 + k) * 7.99)]
				_add(out, "cafe_set", Transform3D(face * Basis(Vector3.UP, _h(x, y, 330 + k) * TAU), p), Color.WHITE, tint)
			elif u < 0.45:
				_add(out, "planter", Transform3D(face, p), Kit.LEAF_TINTS[int(_h(x, y, 340 + k) * 5.99)])
		"r":
			if u < 0.35:
				_add(out, "bush_low", Transform3D(Basis(Vector3.UP, _h(x, y, 350 + k) * TAU), p), Kit.LEAF_TINTS[int(_h(x, y, 360 + k) * 5.99)])
		"park", "empty":
			if u < 0.35:
				_add(out, "bush_low", Transform3D(Basis(Vector3.UP, _h(x, y, 355 + k) * TAU), p), Kit.LEAF_TINTS[int(_h(x, y, 365 + k) * 5.99)])
		"special":
			if u < 0.25:
				_add(out, "planter", Transform3D(face, p), Kit.LEAF_TINTS[int(_h(x, y, 370 + k) * 5.99)])


# ------------------------------------------------------------- buildings ---

func _band(nm: String) -> Rect2:
	## The ground floor's footprint in the model's own x/z: walls between 0.5 and 2.2 m.
	if _bands.has(nm):
		return _bands[nm]
	var r := Rect2()
	var mesh := Kit.mesh(nm)
	var first := true
	if mesh is ArrayMesh:
		for s in mesh.get_surface_count():
			for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				if v.y > 0.5 and v.y < 2.2:
					if first:
						r = Rect2(v.x, v.z, 0, 0)
						first = false
					else:
						r = r.expand(Vector2(v.x, v.z))
	_bands[nm] = r
	return r


func _dress_building(out: Dictionary, b: Dictionary) -> void:
	if int(b.size) == 0 or b.has("kind"):
		return
	var nm := Kit.building_mesh_name(int(b.zone), int(b.stage), int(b.size), int(b.variant))
	if nm == "":
		return
	var band := _band(nm)
	if band.size.x < 2.0:
		return
	var basis := Basis(Vector3.UP, int(b.rot) * PI * 0.5)
	var bxf := Transform3D(basis, city.building_center(b))
	var lot := _lot_info(b.x, b.y)
	var tall: bool = Kit.mesh(nm).get_aabb().end.y > 7.0
	var s := int(b.size)
	var bid := int(b.id)
	for r in 4:
		# Is this side on a street?
		var roads := 0
		for k in s:
			var p: Vector2i
			match r:
				0: p = Vector2i(b.x + k, b.y + s)
				1: p = Vector2i(b.x + s, b.y + k)
				2: p = Vector2i(b.x + k, b.y - 1)
				_: p = Vector2i(b.x - 1, b.y + k)
			if city.is_road(p.x, p.y):
				roads += 1
		if roads * 2 < s:
			continue
		var wd: Vector2i = City.DIRS[r]
		var local := basis.inverse() * Vector3(wd.x, 0, wd.y)   # this side in the model's space
		local = Vector3(roundf(local.x), 0, roundf(local.z))
		var dist: float
		var span: Vector2   # extent along the face, in the model's space
		var tangent: Vector3
		if absf(local.x) > 0.5:
			dist = band.end.x if local.x > 0 else -band.position.x
			span = Vector2(band.position.y, band.end.y)
			tangent = Vector3(0, 0, 1)
		else:
			dist = band.end.y if local.z > 0 else -band.position.y
			span = Vector2(band.position.x, band.end.x)
			tangent = Vector3(1, 0, 0)
		var front := int(b.rot) == r
		var fb := _yaw_facing(local)
		var mid := (span.x + span.y) * 0.5
		var length := span.y - span.x
		var hseed := bid * 7 + r
		if int(b.zone) == City.Zone.COM and not front:
			# Shop fronts on the blank side walls of commercial buildings: 12 m modules
			# stretched or squeezed a little to fill the wall, or one 6 m shop on a short wall.
			if length >= 4.5:
				var n := maxi(int(roundf(length / 12.0)), 1) if length >= 9.0 else 1
				var w := length / n
				var x0 := span.x
				for k in n:
					var mnm: String = STOREFRONTS[int(_h(bid, r, 400 + k) * 3.99)] if w >= 9.0 else "storefront_half"
					var sx := w / (12.0 if w >= 9.0 else 6.0)
					var o := local * dist + tangent * (x0 + w * 0.5) + Vector3(0, LOT, 0)
					_add(out, mnm, bxf * Transform3D(fb * Basis().scaled(Vector3(sx, 1, 1)), o), Color.WHITE,
						Kit.ACCENTS[int(_h(bid, r, 410 + k) * 7.99)])
					x0 += w
		if int(b.zone) == City.Zone.COM and tall and _h(bid, r, 420) < (0.6 if front else 0.3):
			# A neon blade near one corner, reading along the street.
			var side := 1.0 if _h(bid, r, 421) < 0.5 else -1.0
			var o := local * (dist + 0.02) + tangent * (mid + side * (length * 0.5 - 1.2)) + Vector3(0, LOT, 0)
			var col: Color = NEON_COLORS[int(_h(bid, r, 422) * 5.99)]
			_add(out, NEONS[int(_h(bid, r, 423) * 4.99)], bxf * Transform3D(fb, o), Color.WHITE, col)
		if lot.crime > 0.3 or (int(b.zone) == City.Zone.IND and _h(bid, r, 430) < 0.5):
			# Graffiti on street walls in rough blocks (and on factories anyway).
			var odds: float = clampf((lot.crime - 0.3) * 2.0, 0.0, 0.9) + (0.35 if int(b.zone) == City.Zone.IND else 0.0)
			for k in 2:
				if _h(bid, r, 440 + k) < odds:
					var along := mid + (_h(bid, r, 450 + k) - 0.5) * (length - 3.0)
					var o := local * (dist + 0.03 + (0.25 if int(b.zone) == City.Zone.COM and not front else 0.0)) \
						+ tangent * along + Vector3(0, LOT + 1.25 + _h(bid, r, 460 + k) * 0.4, 0)
					var wall := Transform3D(fb * Basis(Vector3.RIGHT, PI * 0.5) * Basis().scaled(Vector3(2.6, 1, 1.3)), o)
					_decal(out, 8 + int(_h(bid, r, 470 + k) * 7.99), bxf * wall, 0.85)


# ----------------------------------------------------------- land and sea ---

func _dress_land(out: Dictionary, x: int, y: int) -> void:
	var c := city.cell_center(x, y)
	var i := city.idx(x, y)
	var zoned := city.zone[i] > 0
	# Grass tufts and flowers over empty and not-yet-built lots.
	var tufts := 5 if zoned else 9
	for k in tufts:
		var p := c + Vector3(_h(x, y, 500 + k) * 11.0 - 5.5, 0, _h(x, y, 520 + k) * 11.0 - 5.5)
		p.y = city.terrain_height(p.x, p.z)
		var tint: Color = Kit.LEAF_TINTS[int(_h(x, y, 540 + k) * 5.99)]
		var s := 0.8 + _h(x, y, 560 + k) * 0.7
		_add(out, "grass_tuft_a" if k % 2 == 0 else "grass_tuft_b",
			Transform3D(Basis(Vector3.UP, _h(x, y, 580 + k) * TAU).scaled(Vector3.ONE * s), p), tint)
	if _h(x, y, 600) < (0.25 if zoned else 0.5):
		for k in 1 + int(_h(x, y, 601) * 3.0):
			var p := c + Vector3(_h(x, y, 610 + k) * 10.0 - 5.0, 0, _h(x, y, 620 + k) * 10.0 - 5.0)
			p.y = city.terrain_height(p.x, p.z)
			_add(out, "flowers", Transform3D(Basis(Vector3.UP, _h(x, y, 630 + k) * TAU), p),
				Kit.LEAF_TINTS[int(_h(x, y, 640 + k) * 5.99)], FLOWER_COLORS[int(_h(x, y, 650 + k) * 4.99)])
	if not zoned and _h(x, y, 660) < 0.35:
		var p := c + Vector3(_h(x, y, 661) * 8.0 - 4.0, 0, _h(x, y, 662) * 8.0 - 4.0)
		p.y = city.terrain_height(p.x, p.z)
		_add(out, "bush_low", Transform3D(Basis(Vector3.UP, _h(x, y, 663) * TAU), p), Kit.LEAF_TINTS[int(_h(x, y, 664) * 5.99)])
	# Rocks near the island's edge.
	if city.coast_dist[i] <= 2.0 and _h(x, y, 670) < 0.55:
		_rock(out, x, y, c, 0)
	# A billboard on empty land facing a road, now and then.
	if not zoned and _h(x, y, 680) < 0.12:
		for r in 4:
			var d: Vector2i = City.DIRS[r]
			if city.is_road(x + d.x, y + d.y):
				var dir := Vector3(d.x, 0, d.y)
				_add(out, "billboard", Transform3D(_yaw_facing(dir), c + dir * 3.0), Color.WHITE, Kit.ACCENTS[int(_h(x, y, 681) * 7.99)])
				break


func _dress_shore(out: Dictionary, x: int, y: int) -> void:
	var c := city.cell_center(x, y)
	if _h(x, y, 700) < 0.45:
		_rock(out, x, y, c, 1)


func _rock(out: Dictionary, x: int, y: int, c: Vector3, k: int) -> void:
	for j in 1 + int(_h(x, y, 710 + k) * 2.5):
		var p := c + Vector3(_h(x, y, 720 + j + k * 5) * 10.0 - 5.0, 0, _h(x, y, 730 + j + k * 5) * 10.0 - 5.0)
		if city.landness(p.x, p.z) < -0.02:
			continue  # under water
		p.y = city.terrain_height(p.x, p.z) - 0.15
		var pick := _h(x, y, 740 + j)
		var nm := "rock_a" if pick < 0.4 else ("rock_b" if pick < 0.6 else "rock_c")
		var s := 0.7 + _h(x, y, 750 + j) * 0.8
		var grey := 0.75 + _h(x, y, 760 + j) * 0.25
		_add(out, nm, Transform3D(Basis(Vector3.UP, _h(x, y, 770 + j) * TAU).scaled(Vector3.ONE * s), p),
			Color(grey, grey * 0.98, grey * 0.94))


# ----------------------------------------------------------------- meshes ---

func _load_meshes() -> void:
	for nm in TYPES:
		var path: String = (STREET if TYPES[nm][0] == "street" else PROPS) + nm + ".glb"
		if not ResourceLoader.exists(path):
			push_warning("StreetDresser: missing %s" % path)
			continue
		var inst: Node = (load(path) as PackedScene).instantiate()
		var mi := _find_mesh(inst)
		if mi:
			var mesh: Mesh = mi.mesh.duplicate()
			for s in mesh.get_surface_count():
				var mat := mesh.surface_get_material(s)
				var key := mat.resource_name if mat else "Wall"
				if key == "Leaves":
					key = "LeavesWind"
				if Kit.materials.has(key):
					mesh.surface_set_material(s, Kit.materials[key])
			_meshes[nm] = mesh
		inst.free()


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r:
			return r
	return null
