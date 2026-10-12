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

static var W := 288            # tiles around the equator (Large, Fedge's pick)
static var H := 52             # tiles from the belt's north edge to its south edge
static var R := 288 * TILE / TAU  # radius at sea level, metres
static var V0 := 52 * TILE * 0.5  # flat z of the equator


static func configure(cols: int, rows: int) -> void:
	W = cols
	H = rows
	R = W * TILE / TAU
	V0 = H * TILE * 0.5
	RenderingServer.global_shader_parameter_set("planet_radius", R)
	RenderingServer.global_shader_parameter_set("planet_v0", V0)


static func circumference() -> float:
	return W * TILE


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
