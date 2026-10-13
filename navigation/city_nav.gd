class_name CityNav
extends Node
## Navigation: the street-level minimap, the GPS route and the full city map with a waypoint,
## plus a small API for anything that wants a target on the map (missions, quests, specials).
## See navigation/README.md for the wiring and the API. main.gd creates it last:
##
##     nav = CityNav.new()
##     nav.name = "Navigation"
##     add_child(nav)
##     nav.setup(city, street, {"life": life, "missions": missions, "resident": resident, "interiors": interiors})
##
## V opens and closes the city map in either view; main's Esc menu can call open_map().

signal waypoint_changed(pos: Vector3)   ## Vector3.INF when cleared
signal arrived(id: String)              ## the GPS target was reached ("waypoint" or a mark id)
signal map_toggled(open: bool)

const MAP_KEY := KEY_V  # M is music, G calls crew backup (missions perk)
const ARRIVE_M := 18.0             # the waypoint clears this close
const WALK_RADIUS_M := 120.0       # minimap range on foot ...
const DRIVE_RADIUS_M := 240.0      # ... and at full speed in a car
const REPAINT_SECONDS := 0.5       # at most this often after the city changes
const COP_RANGE_M := 500.0

var city: City
var street: Node                   # StreetMode (player/)
var life: Node                     # CityLife (citylife/), for the police
var missions: Node                 # Missions (missions/), for payphones and its beacon
var resident: Node                 # Resident (creator/), for the home
var interiors: Node                # InteriorManager (interiors/): no minimap indoors

var texture: ImageTexture
var route: GpsRoute
var me := Vector3.ZERO             # you (street level), or the mayor camera's focus
var heading := 0.0                 # the way you are going: 0 north (-Z), clockwise
var view_angle := 0.0              # the way the camera looks, same convention
var radius_m := WALK_RADIUS_M
var waypoint := Vector3.INF
var blips: Array[Dictionary] = []
var marks := {}                    # id -> {where, kind, color, label, gps, priority, radius, order}
var map_open := false

var _img: Image
var _dirty_rect := Rect2i()
var _repaint_t := 0.0
var _rects := {}                   # building id -> Rect2i of its footprint (for removals)
var _places: Array[Dictionary] = []
var _places_dirty := true
var _order := 0
var _missions_api := false         # Missions marks its own targets; stop reading its beacon
var _gps_id := ""                  # what the route goes to: "waypoint", a mark id, or ""
var _last_pos := Vector3.INF
var _speed := 0.0
var _hud_layer: CanvasLayer
var _map_layer: CanvasLayer
var minimap: Minimap
var map_screen: CityMap
var _mouse_before := Input.MOUSE_MODE_VISIBLE
var _paused_by_map := false


## Finds the CityNav in a running game (for missions/ and anything else), or null.
static func find(tree: SceneTree) -> CityNav:
	return tree.get_first_node_in_group("city_nav") as CityNav if tree else null


func setup(c: City, street_mode: Node = null, parts := {}) -> void:
	city = c
	street = street_mode
	life = parts.get("life", street.get("life") if street else null)
	missions = parts.get("missions")
	resident = parts.get("resident")
	interiors = parts.get("interiors")
	add_to_group("city_nav")
	process_mode = Node.PROCESS_MODE_ALWAYS   # V and Esc still work on the paused map
	route = GpsRoute.new(city)
	_img = MapPainter.paint(city)
	texture = ImageTexture.create_from_image(_mipmapped())
	for b: Dictionary in city.buildings.values():
		_rects[b.id] = _footprint(b)
	city.cells_changed.connect(_mark_dirty)
	city.building_added.connect(func(id, _a):
		if city.buildings.has(id):
			_rects[id] = _footprint(city.buildings[id])
			_mark_dirty(_rects[id])
		_places_dirty = true)
	city.building_removed.connect(func(id):
		if _rects.has(id):
			_mark_dirty(_rects[id])
			_rects.erase(id)
		_places_dirty = true)
	_build_ui()
	var progress := get_node_or_null("/root/Progress")
	if progress and progress.has_method("register_section"):
		progress.register_section("navigation", self)


# ------------------------------------------------------------------------ API ---

## Puts a target on the minimap and the city map. `where` is a Vector3 (flat map metres;
## the same as the world on ms) or a Node3D to follow.
## opts (all optional):
##   color     Color (default yellow)
##   kind      blip symbol: "job" (default), "car", "pickup", "enemy", "phone", "place", "home"
##   label     name shown on the city map
##   gps       true (default): the GPS route can lead here
##   priority  int (default 0): the highest gps mark gets the route; ties go to the newest
##   radius    metres: clear it automatically when you get this close (0, the default, never)
## Marking the same id again moves or restyles it.
func mark(id: String, where: Variant, opts := {}) -> void:
	if id.begins_with("mission"):
		_missions_api = true
	_order += 1
	marks[id] = {
		"where": where,
		"kind": opts.get("kind", "job"),
		"color": opts.get("color", Blips.JOB),
		"label": opts.get("label", ""),
		"gps": opts.get("gps", true),
		"priority": int(opts.get("priority", 0)),
		"radius": float(opts.get("radius", 0.0)),
		"order": marks[id].order if marks.has(id) else _order,
	}


func unmark(id: String) -> void:
	marks.erase(id)


## Clears every mark whose id starts with prefix, e.g. "mission:" at the end of a job.
func unmark_prefix(prefix: String) -> void:
	for id in marks.keys():
		if String(id).begins_with(prefix):
			marks.erase(id)


func has_mark(id: String) -> bool:
	return marks.has(id)


## Lets missions/ say it marks its own targets, so the minimap stops reading its 3D beacon.
func missions_mark_their_own() -> void:
	_missions_api = true


func set_waypoint(pos: Vector3) -> void:
	waypoint = Vector3(pos.x, 0.0, pos.z)
	waypoint_changed.emit(waypoint)


func clear_waypoint() -> void:
	if waypoint.is_finite():
		waypoint = Vector3.INF
		waypoint_changed.emit(waypoint)


## World XZ points of the GPS route (you, each turn, the target); empty when there is none.
func route_points() -> PackedVector2Array:
	return route.points if _gps_id != "" and street_active() else PackedVector2Array()


## Metres left along the GPS route, or 0 with no route.
func route_length() -> float:
	return route.length_m if _gps_id != "" and street_active() else 0.0


func route_color() -> Color:
	if _gps_id == "waypoint":
		return Blips.WAYPOINT
	if _gps_id == "_beacon":
		return _beacon_color()
	return marks[_gps_id].color if marks.has(_gps_id) else Blips.JOB


## What the GPS leads to: "waypoint", a mark id, "_beacon" (the missions fallback), or "".
func gps_target_id() -> String:
	return _gps_id


func street_active() -> bool:
	return street != null and bool(street.get("active"))


func indoors() -> bool:
	return interiors != null and String(interiors.get("current_id")) != ""


func open_map() -> void:
	if map_open:
		return
	map_open = true
	_mouse_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not get_tree().paused:
		get_tree().paused = true
		_paused_by_map = true
	_refresh_places()
	_collect_blips()
	map_screen.open_at(Vector2(me.x, me.z) if street_active() else Vector2.INF)
	_map_layer.visible = true
	map_toggled.emit(true)


func close_map() -> void:
	if not map_open:
		return
	map_open = false
	_map_layer.visible = false
	if _paused_by_map:
		get_tree().paused = false
		_paused_by_map = false
	Input.mouse_mode = _mouse_before
	map_toggled.emit(false)


func toggle_map() -> void:
	if map_open:
		close_map()
	else:
		open_map()


## The name of the special building (or your home) at a world point, for the city map.
func place_name(w: Vector3) -> String:
	var cell := city.flat_to_cell(w)  # map points are flat map metres
	if not city.inside(cell.x, cell.y):
		return ""
	var id := city.bld[city.idx(cell.x, cell.y)]
	if id < 0 or not city.buildings.has(id):
		return ""
	var b: Dictionary = city.buildings[id]
	var home := _home_building()
	if not home.is_empty() and home.id == id:
		return "Your home"
	if b.has("kind") and b.kind != "power_line":
		return String(b.get("name", ""))
	return ""


# -------------------------------------------------------------- save section ---

func to_dict() -> Dictionary:
	return {"waypoint": [waypoint.x, waypoint.z] if waypoint.is_finite() else []}


func from_dict(d: Dictionary) -> void:
	var w: Array = d.get("waypoint", [])
	waypoint = Vector3(float(w[0]), 0.0, float(w[1])) if w.size() == 2 else Vector3.INF


# ------------------------------------------------------------------ per frame ---

func _input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if map_open and (k.keycode == MAP_KEY or k.keycode == KEY_ESCAPE):
		close_map()
		get_viewport().set_input_as_handled()
	elif k.keycode == MAP_KEY and not map_open and _can_open():
		open_map()
		get_viewport().set_input_as_handled()


func _can_open() -> bool:
	if get_tree().paused:
		return false  # the Esc menu has the game; it opens the map with its own button
	if resident and resident.get("_busy") == true:
		return false  # the character creator or the home picker is up
	var focus := get_viewport().gui_get_focus_owner()
	return not (focus is LineEdit or focus is TextEdit)


func _process(delta: float) -> void:
	if city == null:
		return
	var real_dt := delta if not get_tree().paused else 0.0
	_follow(real_dt)
	_repaint(delta)
	if _places_dirty:
		_refresh_places()
	_collect_blips()
	_update_gps()
	minimap.visible = street_active() and not indoors() and not map_open
	_hud_layer.visible = minimap.visible


func _follow(dt: float) -> void:
	# The maps are the flat map, so on msp the camera and player are read back onto it.
	var cam := get_viewport().get_camera_3d()
	if cam:
		var f := Planet.to_local(cam.global_position, -cam.global_basis.z)
		if Vector2(f.x, f.z).length() > 0.05:
			view_angle = atan2(f.x, -f.z)
	if street_active():
		me = Planet.flat(street.player_position())
	elif cam:
		# The mayor view: the point the camera looks at on the ground.
		var o := Planet.flat(cam.global_position)
		var f := Planet.to_local(cam.global_position, -cam.global_basis.z)
		me = o - f * (o.y / f.y) if f.y < -0.05 else Vector3(o.x, 0.0, o.z)
	if dt > 0.0 and _last_pos.is_finite():
		var d := me - _last_pos
		d.y = 0.0
		if d.length() < 40.0:  # not a teleport
			_speed = lerpf(_speed, d.length() / dt, clampf(dt * 3.0, 0.0, 1.0))
			if d.length() > 0.02:
				var h := atan2(d.x, -d.z)
				heading = lerp_angle(heading, h, clampf(dt * 10.0, 0.0, 1.0))
	_last_pos = me
	var want := lerpf(WALK_RADIUS_M, DRIVE_RADIUS_M, clampf((_speed - 6.0) / 24.0, 0.0, 1.0))
	if dt > 0.0:
		radius_m = lerpf(radius_m, want, clampf(dt * 1.5, 0.0, 1.0))


func _mark_dirty(r: Rect2i) -> void:
	_dirty_rect = r if _dirty_rect.size == Vector2i.ZERO else _dirty_rect.merge(r)


func _repaint(delta: float) -> void:
	_repaint_t -= delta
	if _dirty_rect.size == Vector2i.ZERO or _repaint_t > 0.0:
		return
	# Nobody looking: no need to keep the picture fresh until someone is.
	if not map_open and not (street_active() and not indoors()):
		return
	_repaint_t = REPAINT_SECONDS
	MapPainter.paint_rect(_img, city, _dirty_rect.grow(1))
	_dirty_rect = Rect2i()
	texture.update(_mipmapped())


## The map picture with mipmaps, so the zoomed-out minimap doesn't shimmer.
func _mipmapped() -> Image:
	var m := _img.duplicate() as Image
	m.generate_mipmaps()
	return m


static func _footprint(b: Dictionary) -> Rect2i:
	return Rect2i(int(b.x), int(b.y), maxi(int(b.size), 1), maxi(int(b.size), 1))


func _home_building() -> Dictionary:
	if resident == null:
		return {}
	var home = resident.get("home")
	return home.building() if home and home.has_method("building") else {}


func _refresh_places() -> void:
	_places_dirty = false
	_places.clear()
	for b: Dictionary in city.buildings.values():
		var kind: String = b.get("kind", "")
		if kind == "" or kind == "power_line" or int(b.size) <= 0:
			continue
		var d := Catalog.get_def(kind)
		if d.get("group", "") == "parks" and not d.get("unique", false):
			continue  # small parks are on the map picture already
		_places.append({"pos": city.door_position(b), "kind": "place",
			"color": d.get("accent", Catalog.RED), "label": b.get("name", d.get("name", "")), "edge": false})


func _collect_blips() -> void:
	blips.clear()
	blips.append_array(_places)
	if missions:
		var phones = missions.get("phones")
		if phones is Array:
			for p: Vector3 in phones:
				blips.append({"pos": p, "kind": "phone", "color": Blips.PHONE, "label": "Payphone", "edge": false})
	var home := _home_building()
	if not home.is_empty():
		blips.append({"pos": resident.home.door_position(), "kind": "home", "color": Blips.HOME,
			"label": "Your home", "edge": street_active()})
	_collect_cops()
	for id in marks.keys():
		var m: Dictionary = marks[id]
		var p := _where(m.where)
		if not p.is_finite():
			continue
		blips.append({"pos": p, "kind": m.kind, "color": m.color, "label": m.label, "edge": true, "id": id})
	var beacon := _beacon_pos()
	if beacon.is_finite():
		blips.append({"pos": beacon, "kind": "job", "color": _beacon_color(), "label": "Job", "edge": true, "id": "_beacon"})
	if waypoint.is_finite():
		blips.append({"pos": waypoint, "kind": "waypoint", "color": Blips.WAYPOINT, "label": "Waypoint", "edge": true, "id": "waypoint"})


func _collect_cops() -> void:
	var police = life.get("police") if life else null
	if police == null:
		return
	var wanted := int(street.get("wanted")) if street and street.get("wanted") != null else 0
	var flash := int(Time.get_ticks_msec() / 250) % 2 == 0
	var col := (Blips.COP_RED if flash else Blips.COP_BLUE) if wanted > 0 else Blips.COP_BLUE
	for list_name in ["cars", "officers"]:
		var list = police.get(list_name)
		if not list is Array:
			continue
		for o in list:
			var p: Vector3 = o.pos
			if p.distance_to(me) < COP_RANGE_M:
				blips.append({"pos": p, "kind": "cop", "color": col, "label": "Police", "edge": false})


## A mark's place on the flat map: a Vector3 already is; a node is read back from the world.
static func _where(w: Variant) -> Vector3:
	if w is Vector3:
		return w
	if typeof(w) == TYPE_OBJECT and is_instance_valid(w) and w is Node3D and (w as Node3D).is_inside_tree():
		return Planet.flat((w as Node3D).global_position)
	return Vector3.INF


## Until missions/ marks its own targets: the 3D beacon it shows over the next objective or
## the ringing payphone.
func _beacon() -> Node3D:
	if _missions_api or missions == null:
		return null
	var b = missions.get("_beacon")
	return b if b is Node3D and is_instance_valid(b) and (b as Node3D).visible else null


func _beacon_pos() -> Vector3:
	var b := _beacon()
	return Planet.flat(b.global_position) * Vector3(1, 0, 1) if b else Vector3.INF


func _beacon_color() -> Color:
	var b := _beacon() as MeshInstance3D
	if b and b.material_override is StandardMaterial3D:
		var c: Color = (b.material_override as StandardMaterial3D).albedo_color
		return Color(c.r, c.g, c.b, 1.0)
	return Blips.JOB


func _update_gps() -> void:
	# The waypoint wins (you set it yourself), then the highest-priority mark, then the beacon.
	var id := ""
	var goal := Vector3.INF
	if waypoint.is_finite():
		id = "waypoint"
		goal = waypoint
	else:
		var best_p := -2147483647
		var best_o := -1
		for mid in marks.keys():
			var m: Dictionary = marks[mid]
			if not m.gps:
				continue
			var p := _where(m.where)
			if not p.is_finite():
				continue
			if m.priority > best_p or (m.priority == best_p and m.order > best_o):
				best_p = m.priority
				best_o = m.order
				id = mid
				goal = p
		if id == "":
			goal = _beacon_pos()
			if goal.is_finite():
				id = "_beacon"
	if id != _gps_id:
		_gps_id = id
		route.clear()
	if id == "" or not street_active():
		return
	route.update(me, goal)
	# Arrival.
	var flat := Vector2(goal.x - me.x, goal.z - me.z).length()
	if id == "waypoint" and flat < ARRIVE_M:
		clear_waypoint()
		arrived.emit(id)
	# Marks with a radius clear on arrival, whether or not the GPS leads to them.
	for mid in marks.keys():
		var m: Dictionary = marks[mid]
		if m.radius > 0.0:
			var p := _where(m.where)
			if p.is_finite() and Vector2(p.x - me.x, p.z - me.z).length() < m.radius:
				marks.erase(mid)
				arrived.emit(mid)


# ------------------------------------------------------------------------- UI ---

func _build_ui() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "MinimapLayer"
	_hud_layer.layer = 4   # under the missions HUD (5) and the Esc menu (60)
	add_child(_hud_layer)
	minimap = Minimap.new()
	minimap.nav = self
	_hud_layer.add_child(minimap)
	_map_layer = CanvasLayer.new()
	_map_layer.name = "CityMapLayer"
	_map_layer.layer = 70  # over the Esc menu, so its "City map" button can open it
	_map_layer.visible = false
	_map_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_map_layer)
	map_screen = CityMap.new()
	map_screen.nav = self
	_map_layer.add_child(map_screen)
