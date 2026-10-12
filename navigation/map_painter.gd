class_name MapPainter
extends RefCounted
## Paints the city as a flat map image for the minimap and the full city map: sea, beach,
## land, zoned lots, buildings, parks, trees and roads. One picture of the whole island,
## PX pixels per 12 m tile, repainted (at most a few times a second) when the city changes.
## Reads City only, so it runs headless in tests.

const PX := 12  # pixels per tile: 80 tiles -> a 960 x 960 map

const SEA := Color(0.13, 0.22, 0.31)
const SEA_SHALLOW := Color(0.18, 0.3, 0.38)
const SAND := Color(0.55, 0.52, 0.42)
const LAND := Color(0.21, 0.25, 0.22)
const ZONE_TINT := [Color(0, 0, 0, 0), Color(0.3, 0.55, 0.32, 0.22), Color(0.3, 0.45, 0.7, 0.22), Color(0.75, 0.62, 0.3, 0.22)]
const BUILDING := [Color(0.36, 0.37, 0.39), Color(0.42, 0.45, 0.4), Color(0.37, 0.41, 0.48), Color(0.45, 0.41, 0.33)]
const PARK := Color(0.2, 0.38, 0.22)
const TREE := Color(0.14, 0.3, 0.16)
const ROAD := Color(0.74, 0.76, 0.79)
const ROAD_EDGE := Color(0.13, 0.14, 0.15)
const POWER_LINE := Color(0.62, 0.55, 0.28)


static func paint(city: City) -> Image:
	var img := Image.create(City.W * PX, City.H * PX, false, Image.FORMAT_RGBA8)
	paint_rect(img, city, Rect2i(0, 0, City.W, City.H))
	return img


## Repaints the tiles in rect (grid cells) after the city changed there.
static func paint_rect(img: Image, city: City, rect: Rect2i) -> void:
	rect = rect.intersection(Rect2i(0, 0, City.W, City.H))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var ids := {}
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			_ground(img, city, x, y)
			var id := city.bld[city.idx(x, y)]
			if id >= 0:
				ids[id] = true
	for id in ids:
		if city.buildings.has(id):
			_building(img, city, city.buildings[id])
	# Roads last, so they read on top: a dark edge first, then the light strip.
	for pass_i in 2:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if city.road[city.idx(x, y)] == 1:
					_road(img, city, x, y, pass_i == 0)


static func _ground(img: Image, city: City, x: int, y: int) -> void:
	var i := city.idx(x, y)
	var r := Rect2i(x * PX, y * PX, PX, PX)
	if city.land[i] == 0:
		var l := city.height[i]
		if l < -0.2 or l > 0.3:
			img.fill_rect(r, SEA if l < 0.0 else SAND)
			return
		# Near the shore: shade 4 px blocks by the island's own shape for a smooth coastline.
		var q := PX / 3
		for sy in 3:
			for sx in 3:
				var wx := (x + (sx + 0.5) / 3.0) * City.TILE
				var wz := (y + (sy + 0.5) / 3.0) * City.TILE
				img.fill_rect(Rect2i(x * PX + sx * q, y * PX + sy * q, q, q), _shore(city.landness(wx, wz)))
		return
	img.fill_rect(r, LAND)
	var z := city.zone[i]
	if z > 0 and city.bld[i] < 0:
		img.fill_rect(r.grow(-1), LAND.blend(ZONE_TINT[z]))
	var t := city.trees[i]
	if t > 0 and city.bld[i] < 0 and city.road[i] == 0:
		var spots := [Vector2i(3, 3), Vector2i(8, 7), Vector2i(4, 8)]
		for k in mini(t, 3):
			var p: Vector2i = spots[(k + x + y) % 3]
			img.fill_rect(Rect2i(x * PX + p.x - 1, y * PX + p.y - 1, 3, 3), TREE)


static func _shore(l: float) -> Color:
	if l > 0.06:
		return LAND.lerp(SAND, 0.35)
	if l > 0.0:
		return SAND
	if l > -0.06:
		return SEA_SHALLOW
	return SEA


static func _building(img: Image, city: City, b: Dictionary) -> void:
	var s: int = b.size
	if s <= 0:
		return  # street props (payphones) are blips, not buildings
	var col: Color
	var kind: String = b.get("kind", "")
	if kind != "":
		var d := Catalog.get_def(kind)
		if kind == "power_line":
			img.fill_rect(Rect2i(b.x * PX + PX / 2 - 1, b.y * PX + PX / 2 - 1, 2, 2), POWER_LINE)
			return
		if d.get("group", "") == "parks":
			img.fill_rect(Rect2i(b.x * PX, b.y * PX, s * PX, s * PX).grow(-1), PARK)
			return
		var accent: Color = d.get("accent", Catalog.RED)
		col = BUILDING[0].lerp(accent, 0.55)
	else:
		col = BUILDING[clampi(int(b.zone), 0, 3)]
		col = col.lightened(0.06 * float(b.get("stage", 1)))
	var r := Rect2i(b.x * PX, b.y * PX, s * PX, s * PX).grow(-2)
	img.fill_rect(r, col.darkened(0.35))
	img.fill_rect(r.grow(-1), col)


static func _road(img: Image, city: City, x: int, y: int, edge: bool) -> void:
	## A strip down the middle of the tile plus an arm toward each joined neighbour.
	var w := 6 if edge else 4
	var lo := (PX - w) / 2
	var col := ROAD_EDGE if edge else ROAD
	var ox := x * PX
	var oy := y * PX
	img.fill_rect(Rect2i(ox + lo, oy + lo, w, w), col)
	var m := city.road_mask(x, y)
	if m & 1: img.fill_rect(Rect2i(ox + lo, oy, w, lo), col)                # north
	if m & 4: img.fill_rect(Rect2i(ox + lo, oy + lo + w, w, PX - lo - w), col)  # south
	if m & 8: img.fill_rect(Rect2i(ox, oy + lo, lo, w), col)                # west
	if m & 2: img.fill_rect(Rect2i(ox + lo + w, oy + lo, PX - lo - w, w), col)  # east
