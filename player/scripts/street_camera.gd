class_name StreetCamera
extends Camera3D
## The street-level camera. It follows an OrbitRig, glides between rigs (on foot <-> car),
## and flies the signature zoom: from any camera transform (the mayor view) down to a
## character on the sidewalk, and back up, with no cut.
##
## The zoom eases altitude in log space, so it reads like one continuous dive: fast
## through the empty sky, slowing as rooftops get close, then swinging in behind the
## character's shoulder.
##
## Feel: the view widens with speed (`fov_boost`), rolls a little into corners (`lean`),
## and shakes on hits, shots, crashes and blasts (`shake()`): a smooth noise shake whose
## strength falls off quickly, so small knocks read as a jolt and big ones as a rumble.

signal flight_finished

enum Mode { IDLE, FOLLOW, FLY, BLEND }

@export var street_fov := 68.0
@export var speed_fov := 14.0           # extra FOV at a car's top speed

var mode := Mode.IDLE
var rig: OrbitRig
var fov_boost := 0.0                     # 0..1, set by StreetMode from speed
var lean := 0.0                          # radians of roll, set by StreetMode in corners

var _t := 0.0
var _dur := 1.0
var _from := Transform3D()
var _from_fov := 45.0
var _from_focus := Vector3.ZERO
var _to_xf := Transform3D()              # used when not flying to a rig
var _to_fov := 45.0
var _to_rig: OrbitRig
var _shake := 0.0                        # trauma, 0..1.5
var _lean := 0.0
var _noise := FastNoiseLite.new()
var _nt := 0.0


func _ready() -> void:
	near = 0.08
	far = 4000.0
	fov = street_fov
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_noise.seed = randi()


func follow(r: OrbitRig) -> void:
	rig = r
	mode = Mode.FOLLOW


func blend_to(r: OrbitRig, duration := 0.6) -> void:
	## Short glide between two rigs (getting in or out of a car).
	_from = global_transform
	_from_fov = fov
	_to_rig = r
	_t = 0.0
	_dur = maxf(duration, 0.01)
	mode = Mode.BLEND


func dive_to(r: OrbitRig, from: Transform3D, from_fov: float, duration := 3.2) -> void:
	## The mayor -> street zoom. `from` is the mayor camera's transform.
	global_transform = from
	fov = from_fov
	_start_flight(from, from_fov, duration)
	_to_rig = r
	_to_fov = street_fov


func rise_to(to: Transform3D, to_fov: float, duration := 2.6) -> void:
	## The street -> mayor zoom. The caller makes its own camera current on `flight_finished`.
	_start_flight(global_transform, fov, duration)
	_to_rig = null
	_to_xf = to
	_to_fov = to_fov


func shake(amount: float) -> void:
	## Adds trauma: 0.2 a light knock, 0.5 a punch or a pistol, 1+ a blast.
	_shake = minf(maxf(_shake, amount) + amount * 0.25, 1.5)


func _start_flight(from: Transform3D, from_fov: float, duration: float) -> void:
	_from = from
	_from_fov = from_fov
	# Where the start camera is looking, on the ground plane (flat map metres on msp, where
	# the whole flight is worked out on the flat map and stood up on the ball).
	from = Planet.flat_xform(from)
	var d := -from.basis.z
	var t := (-from.origin.y / d.y) if d.y < -0.01 else 100.0
	_from_focus = from.origin + d * clampf(t, 1.0, 3000.0)
	_t = 0.0
	_dur = duration
	mode = Mode.FLY


func _target_xf() -> Transform3D:
	return _to_rig.eye.global_transform if _to_rig else _to_xf


func _process(delta: float) -> void:
	match mode:
		Mode.FOLLOW:
			if rig:
				global_transform = rig.eye.global_transform
				fov = lerpf(fov, street_fov + speed_fov * fov_boost, 1.0 - exp(-4.0 * delta))
		Mode.BLEND:
			_t += delta / _dur
			var e := _smooth(clampf(_t, 0.0, 1.0))
			var goal := _to_rig.eye.global_transform
			global_transform = _from.interpolate_with(goal, e)
			fov = lerpf(_from_fov, street_fov + speed_fov * fov_boost, e)
			if _t >= 1.0:
				follow(_to_rig)
		Mode.FLY:
			_t += delta / _dur
			var k := clampf(_t, 0.0, 1.0)
			global_transform = _fly_xf(k)
			fov = lerpf(_from_fov, _to_fov, _smooth(k))
			if _t >= 1.0:
				if _to_rig:
					follow(_to_rig)
				else:
					mode = Mode.IDLE
				flight_finished.emit()
	# Roll into corners (follow only; flights stay level).
	_lean = lerpf(_lean, lean if mode == Mode.FOLLOW else 0.0, 1.0 - exp(-3.0 * delta))
	var roll := _lean
	if _shake > 0.0:
		_shake = maxf(_shake - delta * 1.6, 0.0)
		_nt += delta * (18.0 + 10.0 * _shake)
		var j := _shake * _shake
		h_offset = _noise.get_noise_2d(_nt, 0.0) * j * 0.09
		v_offset = _noise.get_noise_2d(0.0, _nt) * j * 0.09
		roll += _noise.get_noise_2d(_nt, 50.0) * j * 0.03
	else:
		h_offset = 0.0
		v_offset = 0.0
	if absf(roll) > 0.0001 and mode != Mode.IDLE:
		rotate_object_local(Vector3.FORWARD, roll)


func _fly_xf(k: float) -> Transform3D:
	var to := Planet.flat_xform(_target_xf())
	var from := Planet.flat_xform(_from)
	var a := from.origin
	var b := to.origin
	if Planet.on:  # across the seam the short way
		b.x = a.x + Planet.dx(a.x, b.x)
		to.origin = b
	var diving := _to_rig != null
	# Altitude in log space: big steps up high, fine steps near the ground.
	var e_h := _smooth(k)
	var ha := maxf(a.y, 0.5)
	var hb := maxf(b.y, 0.5)
	var h := exp(lerpf(log(ha), log(hb), e_h))
	# Horizontal: on the way down, close in early so we drop onto the character;
	# on the way up, leave the ground first, then drift out.
	var e_xz := _ease_out(k) if diving else _ease_in(k)
	var p := Vector3(lerpf(a.x, b.x, e_xz), h, lerpf(a.z, b.z, e_xz))
	# Look at a point that slides from the old focus to the new one.
	var to_focus := b + (-to.basis.z) * 12.0
	var e_look := _smooth(clampf(k * 1.25, 0.0, 1.0)) if diving else _smooth(k)
	var focus := _from_focus.lerp(to_focus, e_look)
	var dir := focus - p
	var xf := Transform3D(Basis.looking_at(dir.normalized() if dir.length() > 0.01 else -to.basis.z, Vector3.UP), p)
	# Settle exactly onto the target over the last stretch.
	var settle := _smooth(clampf((k - 0.8) / 0.2, 0.0, 1.0))
	xf.basis = xf.basis.slerp(to.basis.orthonormalized(), settle) if settle > 0.0 else xf.basis
	xf.origin = xf.origin.lerp(b, settle)
	return Planet.xf_rigid(xf)


static func _smooth(x: float) -> float:
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)


static func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - x, 2.4)


static func _ease_in(x: float) -> float:
	return pow(x, 2.0)
