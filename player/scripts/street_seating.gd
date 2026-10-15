class_name StreetSeating
extends Node
## Sitting down: street benches and bus-stop seats (citylife StreetSpots) and the chairs,
## sofas, benches and stools in enterable rooms (interiors/ Interior). Anything in the
## "seat_sources" group that has seats_near(world_pos, radius) -> Array of seat
## dictionaries, claim_seat(seat, who) and release_seat(seat, who) is a place to sit.
##
## StreetMode makes one (`street.seating`). E next to a free seat walks over, turns and
## sits; E, a move or a jump stands back up. Getting hurt stands up too.
##
## A seat dictionary always has "xform" (world; origin on the floor under the seat, raised
## by "lift" for tall seats; -Z the way a sitter faces), "kind" ("bench", "bus_stop",
## "chair", "sofa", "stool"), "lift" and "park" (a street bench by a park). Street seats
## add "flat" (flat-map point), "cell", "side" and "spot" (StreetSpots.Spot); room seats
## add "interior" (the room id).
##
## Missions can also put the player in a moving seat: ride(vehicle, local_seat) keeps them
## seated on a Node3D (a bus) until end_ride(). local_seat is the cushion point in the
## vehicle's space, -Z facing forward.

signal sat_down(seat: Dictionary)
signal stood_up(seat: Dictionary)
signal ride_started(vehicle: Node3D)
signal ride_ended(vehicle: Node3D)

const SIT_RADIUS := 1.6        # how close to a seat E works
const WALK_IN := 2.2           # m/s walking over to the seat
const SEAT_HEIGHT := 0.45      # the sitting clips' seat height

var street: StreetMode
var seated := false
var busy := false              # sitting down or standing up
var seat := {}                 # the seat in use (see above)
var riding: Node3D = null      # the vehicle being ridden, if any

var _root := Vector3.ZERO      # player origin while seated
var _stand := Vector3.ZERO     # where they stand up to
var _yaw := 0.0
var _local_seat := Transform3D()
var _scan := 0.0
var _near := {}


func setup(s: StreetMode) -> void:
	street = s
	street.player.damaged.connect(func(_a, _from) -> void:
		if seated and not busy and riding == null:
			stand())


## The nearest free seat within reach of the player, or {}. Cached for a few frames.
func nearest() -> Dictionary:
	if _scan > 0.0:
		return _near
	_scan = 0.15
	_near = find(street.player.global_position)
	return _near


func find(pos: Vector3, radius := SIT_RADIUS) -> Dictionary:
	var best := {}
	var best_d := radius
	for src in street.get_tree().get_nodes_in_group("seat_sources"):
		if not src.has_method("seats_near"):
			continue
		for s in src.seats_near(pos, radius):
			var d := (s.xform as Transform3D).origin.distance_to(pos)
			if d < best_d:
				best = s
				best_d = d
	return best


func _process(delta: float) -> void:
	_scan -= delta


# ------------------------------------------------------------------- sitting ---

## Walk to the seat, turn round and sit. Returns false if it was taken or we're busy.
func sit(s: Dictionary) -> bool:
	if busy or seated or s.is_empty() or not is_instance_valid(s.source):
		return false
	var p := street.player
	if not s.source.claim_seat(s, p):
		return false
	busy = true
	seat = s
	_near = {}
	var xf: Transform3D = s.xform
	var up := Planet.up(xf.origin)
	var fwd := -xf.basis.z
	var lift: float = s.get("lift", 0.0)
	_root = xf.origin
	_stand = xf.origin - up * lift + fwd * CharacterModel.SEAT_SHIFT
	var f := Planet.to_local(_stand, fwd)
	_yaw = atan2(-f.x, -f.z)
	p.set_puppet(true)
	p.rig.input_enabled = p.controls_enabled   # the camera still turns while seated
	p.visual.set_aim(CharacterModel.Aim.NONE)
	# Over to the spot in front of the seat, turning to face away from it on the way.
	var start := p.global_position
	var dist := start.distance_to(_stand)
	var steps := maxi(int(dist / WALK_IN * 60.0), 12)
	var travel := atan2(-Planet.to_local(start, _stand - start).x, -Planet.to_local(start, _stand - start).z)
	for i in steps:
		var k := float(i + 1) / steps
		p.global_position = start.lerp(_stand, k)
		var yaw := _yaw if dist < 0.3 else lerp_angle(travel, _yaw, smoothstep(0.45, 1.0, k))
		p.face(lerp_angle(p.facing_yaw(), yaw, 0.35))
		p.visual.animate(1.0 / 60.0, dist / (steps / 60.0) * (1.0 - smoothstep(0.7, 1.0, k)), true, 0.0, 0.0)
		await get_tree().physics_frame
		if not busy:
			return false   # stood up at once (hurt badly, busted, gone to the mayor view)
	# Back and down onto the seat; the clip keeps the feet still while the origin slides.
	p.face(_yaw)
	p.visual.sit_down()
	var dur := p.visual.clip_length("SitDown")
	var t := 0.0
	while t < dur:
		t += get_physics_process_delta_time()
		p.global_position = _stand.lerp(_root, CharacterModel.seat_k(minf(t / dur, 1.0)))
		p.face(_yaw)
		p.visual.animate(get_physics_process_delta_time(), 0.0, true, 0.0, 0.0)
		await get_tree().physics_frame
		if not busy:
			return false
	p.global_position = _root
	busy = false
	seated = true
	sat_down.emit(seat)
	return true


## Get up. instant skips the clip (killed, busted, leaving the street).
func stand(instant := false) -> void:
	if not seated and not busy:
		return
	var p := street.player
	var s := seat
	var was_seated := seated
	seated = false
	if instant or not was_seated:
		busy = false
		_finish(s)
		p.visual.set_sitting(false)
		if is_instance_valid(s.get("source")):
			p.place(_stand, _yaw)
		p.set_puppet(false)
		if was_seated:
			stood_up.emit(s)
		return
	busy = true
	p.visual.stand_up()
	var dur := p.visual.clip_length("StandUp")
	var t := 0.0
	while t < dur:
		t += get_physics_process_delta_time()
		p.global_position = _root.lerp(_stand, CharacterModel.seat_k(minf(t / dur, 1.0)))
		p.face(_yaw)
		p.visual.animate(get_physics_process_delta_time(), 0.0, true, 0.0, 0.0)
		await get_tree().physics_frame
		if not busy:
			return   # an instant stand took over
	busy = false
	_finish(s)
	p.place(_stand, _yaw)
	p.set_puppet(false)
	stood_up.emit(s)


func _finish(s: Dictionary) -> void:
	if is_instance_valid(s.get("source")):
		s.source.release_seat(s, street.player)
	seat = {}


func _physics_process(delta: float) -> void:
	if riding:
		_follow_vehicle(delta)
		return
	if not seated or busy:
		return
	var p := street.player
	if not is_instance_valid(seat.get("source")):
		# The room went away under us (left the interior): just be standing.
		seated = false
		p.visual.set_sitting(false)
		p.set_puppet(false)
		var s := seat
		seat = {}
		stood_up.emit(s)
		return
	p.rig.input_enabled = p.controls_enabled
	p.global_position = _root
	p.face(_yaw)
	p.visual.animate(delta, 0.0, true, 0.0, 0.0)
	if p.controls_enabled and (StreetInput.move_vector().length() > 0.5 or Input.is_action_just_pressed("street_jump")):
		stand()


func _unhandled_input(e: InputEvent) -> void:
	if seated and not busy and riding == null and street.player.controls_enabled \
			and e.is_action_pressed("street_interact"):
		get_viewport().set_input_as_handled()
		stand()


# -------------------------------------------------------------------- riding ---

## Ride as a passenger: seated on `vehicle` at local_seat (the cushion point in its space,
## -Z forward) until end_ride(). No walking in, no standing up on E.
func ride(vehicle: Node3D, local_seat: Transform3D) -> bool:
	if vehicle == null or riding:
		return false
	if seated or busy:
		stand(true)
	var p := street.player
	riding = vehicle
	_local_seat = local_seat
	p.set_puppet(true)
	p.visual.set_aim(CharacterModel.Aim.NONE)
	p.visual.set_sitting(true, "bench")
	_follow_vehicle(0.0)
	ride_started.emit(vehicle)
	return true


## Off the vehicle and on foot at `at` (world), facing face_yaw (or the way the seat faced).
func end_ride(at: Vector3, face_yaw := NAN) -> void:
	if riding == null:
		return
	var v := riding
	riding = null
	var p := street.player
	p.visual.set_sitting(false)
	p.place(at, _yaw if is_nan(face_yaw) else face_yaw)
	p.set_puppet(false)
	ride_ended.emit(v)


func _follow_vehicle(delta: float) -> void:
	var p := street.player
	if not is_instance_valid(riding):
		riding = null
		p.visual.set_sitting(false)
		p.set_puppet(false)
		return
	var xf := riding.global_transform * _local_seat
	var root := xf.origin - xf.basis.y.normalized() * SEAT_HEIGHT
	p.global_position = root
	var f := Planet.to_local(root, -xf.basis.z)
	_yaw = atan2(-f.x, -f.z)
	p.face(_yaw)
	p.rig.input_enabled = p.controls_enabled
	p.visual.animate(delta, 0.0, true, 0.0, 0.0)
