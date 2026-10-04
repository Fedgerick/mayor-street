class_name GpsRoute
extends RefCounted
## The GPS: the shortest way along the roads from where you are to a target, as a few
## straight runs of road for the minimap and the city map to draw. A breadth-first search
## over road tiles (80 x 80 grid, a few thousand steps), redone only when your road tile,
## the target's road tile or the roads change. The search runs out from the target, so
## walking or driving only follows the stored arrows; a new search waits for a new target.

var city: City
var points := PackedVector2Array()  # world XZ: you, each turn along the road, the target
var length_m := 0.0                 # along the route, from you to the target
var reachable := true               # false when no road joins you to the target

var _from := Vector2i(-1, -1)
var _to := Vector2i(-1, -1)
var _cells: Array[Vector2i] = []    # road tiles at each turn, from _from to _to
var _dirty := true
var _field_to := -1                 # the road tile the stored search ran out from
var _toward := PackedInt32Array()   # per tile: the next tile toward _field_to, -1 unreached


func _init(c: City) -> void:
	city = c
	c.cells_changed.connect(func(_r):
		_dirty = true
		_field_to = -1)


func clear() -> void:
	points = PackedVector2Array()
	length_m = 0.0
	reachable = true
	_cells.clear()
	_from = Vector2i(-1, -1)
	_to = Vector2i(-1, -1)


## Recomputes the route from `me` to `goal` (world positions) when it has to, and refreshes
## its two loose ends every call. Returns true when the road part changed.
func update(me: Vector3, goal: Vector3) -> bool:
	var a := nearest_road(city.world_to_cell(me))
	var b := nearest_road(city.world_to_cell(goal))
	var changed := false
	if _dirty or a != _from or b != _to:
		_dirty = false
		_from = a
		_to = b
		_cells = _turns(find(a, b))
		reachable = a.x < 0 or b.x < 0 or a == b or not _cells.is_empty()
		changed = true
	points = PackedVector2Array([Vector2(me.x, me.z)])
	for c in _cells:
		var p := city.cell_center(c.x, c.y)
		points.append(Vector2(p.x, p.z))
	points.append(Vector2(goal.x, goal.z))
	if _cells.size() >= 2:
		# Don't double back: skip the first road tile's centre when you are already past it.
		var p0 := points[0]
		var p1 := points[1]
		var p2 := points[2]
		if (p2 - p0).length() < (p2 - p1).length():
			points.remove_at(1)
	length_m = 0.0
	for i in range(1, points.size()):
		length_m += points[i].distance_to(points[i - 1])
	return changed


## Road tiles from a to b inclusive (4-connected), or empty when they don't join up.
func find(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if a.x < 0 or b.x < 0 or not city.is_road(a.x, a.y) or not city.is_road(b.x, b.y):
		return out
	var goal := city.idx(b.x, b.y)
	if goal != _field_to:
		_search_from(goal)
	var i := city.idx(a.x, a.y)
	if _toward[i] == -1:
		return out
	while true:
		out.append(Vector2i(i % City.SIZE, i / City.SIZE))
		if i == goal:
			break
		i = _toward[i]
	return out


func _search_from(goal: int) -> void:
	## Breadth-first out from the target over the roads, storing the way back at every tile.
	_field_to = goal
	_toward.resize(City.SIZE * City.SIZE)
	_toward.fill(-1)
	_toward[goal] = goal
	var queue := PackedInt32Array([goal])
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % City.SIZE
		var y := i / City.SIZE
		for d: Vector2i in City.DIRS:
			if city.is_road(x + d.x, y + d.y):
				var j := city.idx(x + d.x, y + d.y)
				if _toward[j] == -1:
					_toward[j] = i
					queue.append(j)


## The nearest road tile to a cell, searching outward in square rings; (-1, -1) for none.
func nearest_road(cell: Vector2i, max_ring := 8) -> Vector2i:
	if city.is_road(cell.x, cell.y):
		return cell
	for ring in range(1, max_ring + 1):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for y in range(cell.y - ring, cell.y + ring + 1):
			for x in range(cell.x - ring, cell.x + ring + 1):
				if (absi(x - cell.x) == ring or absi(y - cell.y) == ring) and city.is_road(x, y):
					var d := Vector2(x - cell.x, y - cell.y).length_squared()
					if d < best_d:
						best_d = d
						best = Vector2i(x, y)
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


static func _turns(path: Array[Vector2i]) -> Array[Vector2i]:
	## Keeps the ends and every tile where the road turns.
	if path.size() <= 2:
		return path
	var out: Array[Vector2i] = [path[0]]
	for i in range(1, path.size() - 1):
		if path[i] - path[i - 1] != path[i + 1] - path[i]:
			out.append(path[i])
	out.append(path[-1])
	return out
