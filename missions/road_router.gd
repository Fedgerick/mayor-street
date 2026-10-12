class_name RoadRouter
extends RefCounted
## Shortest routes over the road grid, for mission pay and for the fleeing car.
## City.road_path is the L-shaped drawing helper; this one follows real roads (BFS,
## 4-connected, every road tile costs the same). The grid is 80x80, so a full search is
## a few thousand steps and needs no cache beyond the last field.

var city: City
var _field_from := Vector2i(-1, -1)
var _field := PackedInt32Array()  # parent index per cell for the last BFS, -1 unvisited


func _init(c: City) -> void:
	city = c
	c.cells_changed.connect(func(_r): _field_from = Vector2i(-1, -1))


func access_cell(b: Dictionary) -> Vector2i:
	## The road tile a building opens onto: the nearest road cell touching its footprint.
	var best := Vector2i(-1, -1)
	var best_d := 1 << 30
	var center := Vector2(b.x + b.size * 0.5, b.y + b.size * 0.5)
	for ring in [1, 2, 3]:
		for y in range(b.y - ring, b.y + b.size + ring):
			for x in range(b.x - ring, b.x + b.size + ring):
				if not city.is_road(x, y):
					continue
				var d := int((Vector2(x + 0.5, y + 0.5) - center).length_squared() * 100.0)
				if d < best_d:
					best_d = d
					best = Vector2i(x, y)
		if best.x >= 0:
			return best
	return best


func nearest_road(cell: Vector2i, max_ring := 6) -> Vector2i:
	if city.is_road(cell.x, cell.y):
		return cell
	for ring in range(1, max_ring + 1):
		for y in range(cell.y - ring, cell.y + ring + 1):
			for x in range(cell.x - ring, cell.x + ring + 1):
				if (absi(x - cell.x) == ring or absi(y - cell.y) == ring) and city.is_road(x, y):
					return Vector2i(x, y)
	return Vector2i(-1, -1)


func _bfs(from: Vector2i) -> void:
	if from == _field_from:
		return
	_field_from = from
	var n := City.W * City.H
	_field.resize(n)
	_field.fill(-1)
	var start := city.idx(from.x, from.y)
	_field[start] = start
	var queue := PackedInt32Array([start])
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % City.W
		var y := i / City.W
		for d: Vector2i in City.DIRS:
			var nx := x + d.x
			var ny := y + d.y
			if not city.is_road(nx, ny):
				continue
			var j := city.idx(nx, ny)
			if _field[j] == -1:
				_field[j] = i
				queue.append(j)


func route(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	## Road cells from a to b inclusive; empty when they are not connected.
	var out: Array[Vector2i] = []
	if not city.is_road(a.x, a.y) or not city.is_road(b.x, b.y):
		return out
	_bfs(a)
	var i := city.idx(b.x, b.y)
	if _field[i] == -1:
		return out
	var start := city.idx(a.x, a.y)
	while true:
		out.append(Vector2i(i % City.W, i / City.W))
		if i == start:
			break
		i = _field[i]
	out.reverse()
	return out


func reachable(from: Vector2i) -> PackedInt32Array:
	## Road distance in tiles from `from` to every cell, -1 where unreachable.
	var dist := PackedInt32Array()
	dist.resize(City.W * City.H)
	dist.fill(-1)
	if not city.is_road(from.x, from.y):
		return dist
	var start := city.idx(from.x, from.y)
	dist[start] = 0
	var queue := PackedInt32Array([start])
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % City.W
		var y := i / City.W
		for d: Vector2i in City.DIRS:
			if city.is_road(x + d.x, y + d.y):
				var j := city.idx(x + d.x, y + d.y)
				if dist[j] == -1:
					dist[j] = dist[i] + 1
					queue.append(j)
	return dist


static func length_m(path: Array[Vector2i]) -> float:
	return maxf(0.0, path.size() - 1) * City.TILE
