class_name Planet
extends RefCounted
## The ball the city lives on. Everything else keeps thinking in flat map metres:
## x runs east (wrapping all the way round), z runs south across the buildable belt,
## y is height above sea level. Planet turns those into points and frames on the sphere
## and back again.
##
## The belt is W tiles around the equator and H tiles from its north edge to its south
## edge, centred on the equator. Every row is one tile deep; east to west a tile is
## cos(latitude) as wide as at the equator. North of the belt is the ice cap, south of it
## the polar ocean, so the squeezed grid near the poles is never built on.

const TILE := 12.0

## True once configure() has run: the game is on a planet (msp). False on the flat island
## (ms), where every helper below that is not about the ball is the identity.
static var on := false

static var W := 288            # tiles around the equator (Large, Fedge's pick)
static var H := 52             # tiles from the belt's north edge to its south edge
static var R := 288 * TILE / TAU  # radius at sea level, metres
static var V0 := 52 * TILE * 0.5  # flat z of the equator


static func configure(cols: int, rows: int) -> void:
	on = true
	W = cols
	H = rows
	R = W * TILE / TAU
	V0 = H * TILE * 0.5
	City.W = cols
	City.H = rows
	RenderingServer.global_shader_parameter_set("planet_radius", R)
	RenderingServer.global_shader_parameter_set("planet_v0", V0)


static func circumference() -> float:
	return W * TILE


# ------------------------------------------------- identity on the flat island ---

## Flat map metres -> world position (the same point on the flat island).
static func place(p: Vector3) -> Vector3:
	return warp(p) if on else p


## World position -> flat map metres.
static func flat(w: Vector3) -> Vector3:
	return unwarp(w) if on else w


## A flat map transform -> world transform.
static func xf(t: Transform3D) -> Transform3D:
	return warp_xform(t) if on else t


## A flat transform -> world, kept rigid (no east-west squeeze): for bodies and cameras.
static func xf_rigid(t: Transform3D) -> Transform3D:
	return Transform3D(frame(t.origin) * t.basis, warp(t.origin)) if on else t


## Up at a world position.
static func up(w: Vector3) -> Vector3:
	return up_at(w) if on else Vector3.UP


## Local frame (x east, y up, z south) at a world position.
static func basis(w: Vector3) -> Basis:
	return frame_world(w) if on else Basis.IDENTITY


## A flat-map direction (x east, z south) at a world point -> world direction.
static func dir(w: Vector3, d: Vector3) -> Vector3:
	return frame_world(w) * d if on else d


## A world direction at a world point -> flat-map direction.
static func to_local(w: Vector3, d: Vector3) -> Vector3:
	return frame_world(w).inverse() * d if on else d


# ------------------------------------------------------------- the ball ---

## Latitude (radians, + north) and longitude (radians, 0..TAU) of a flat point.
static func lat_of(p: Vector3) -> float:
	return (V0 - p.z) / R


static func lon_of(p: Vector3) -> float:
	return p.x / R


static func dir_at(lat: float, lon: float) -> Vector3:
	var c := cos(lat)
	return Vector3(c * sin(lon), sin(lat), c * cos(lon))


## Flat map metres -> world point on (or above) the ball.
static func warp(p: Vector3) -> Vector3:
	return dir_at(lat_of(p), lon_of(p)) * (R + p.y)


## World point -> flat map metres (x wrapped into 0..circumference).
static func unwarp(w: Vector3) -> Vector3:
	var r := w.length()
	if r < 0.001:
		return Vector3.ZERO
	var lat := asin(clampf(w.y / r, -1.0, 1.0))
	var lon := fposmod(atan2(w.x, w.z), TAU)
	return Vector3(lon * R, r - R, V0 - lat * R)


## Local frame at a flat point: x = east, y = up, z = south (the flat map's axes).
static func frame(p: Vector3) -> Basis:
	return frame_at(lat_of(p), lon_of(p))


static func frame_at(lat: float, lon: float) -> Basis:
	var up := dir_at(lat, lon)
	var east := Vector3(cos(lon), 0.0, -sin(lon))
	var south := east.cross(up)
	return Basis(east, up, south)


## Local frame at a world point.
static func frame_world(w: Vector3) -> Basis:
	var r := w.length()
	if r < 0.001:
		return Basis.IDENTITY
	var lat := asin(clampf(w.y / r, -1.0, 1.0))
	var lon := atan2(w.x, w.z)
	return frame_at(lat, lon)


static func up_at(w: Vector3) -> Vector3:
	return w.normalized() if w.length() > 0.001 else Vector3.UP


## A flat transform (as CityView builds them) stood up on the ball. East-west is narrowed
## by cos(latitude) so a row of tiles still fits side by side away from the equator.
static func warp_xform(xf: Transform3D) -> Transform3D:
	var lat := lat_of(xf.origin)
	var f := frame_at(lat, lon_of(xf.origin))
	f.x *= cos(lat)
	return Transform3D(f * xf.basis, warp(xf.origin))


## Wrap a flat x into 0..circumference.
static func wrap_x(x: float) -> float:
	return fposmod(x, W * TILE)


## Shortest east-west flat difference from a to b, across the seam if that is shorter.
static func dx(a: float, b: float) -> float:
	var c := W * TILE
	return fposmod(b - a + c * 0.5, c) - c * 0.5


## Where a ray meets the ball at height h, or null.
static func ray_hit(from: Vector3, dir: Vector3, h := 0.0) -> Variant:
	var r := R + h
	var b := from.dot(dir)
	var c := from.length_squared() - r * r
	var disc := b * b - c
	if disc < 0.0:
		return null
	var t := -b - sqrt(disc)
	if t < 0.0:
		t = -b + sqrt(disc)
		if t < 0.0:
			return null
	return from + dir * t


## Horizon test: can something up to `top` metres tall at world point w be seen from eye?
static func above_horizon(eye: Vector3, w: Vector3, top: float) -> bool:
	var he := maxf(eye.length() - R, 0.5)
	var reach := acos(clampf(R / (R + he), -1.0, 1.0)) + acos(clampf(R / (R + maxf(top, 0.5)), -1.0, 1.0))
	return eye.normalized().angle_to(w.normalized()) < reach


## A sheet over the whole belt at height h, one quad per tile, with UVs 0..1 across the
## map (u east, v south): the planet stand-in for a flat PlaneMesh laid over the grid.
static func belt_mesh(h: float, per_tile := 1) -> ArrayMesh:
	var cols := W * per_tile
	var rows := H * per_tile
	var step := TILE / per_tile
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	for j in rows + 1:
		for i in cols + 1:
			var p := Vector3(i * step, h, j * step)
			var w := warp(p)
			verts.append(w)
			norms.append(w.normalized())
			uvs.append(Vector2(float(i) / cols, float(j) / rows))
	var idx := PackedInt32Array()
	for j in rows:
		for i in cols:
			var a := j * (cols + 1) + i
			var b := a + cols + 1
			idx.append_array([a, a + 1, b, a + 1, b + 1, b])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Point gravity toward the centre for everything physical (cars, falling things): the
## space's own default area pulls toward the origin instead of down -Y.
static func point_gravity(space: RID) -> void:
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_IS_POINT, true)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3.ZERO)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_POINT_UNIT_DISTANCE, 0.0)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY, 9.8)
