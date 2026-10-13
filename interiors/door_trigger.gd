class_name DoorTrigger
extends Area3D
## A doorway on an enterable building. Walking into it (on foot, heading for the door)
## asks the InteriorManager to take the player inside. Made by InteriorManager.

signal entered_by_player(door: DoorTrigger)

const SIZE := Vector3(1.8, 2.4, 1.6)

var interior_id := ""
var building_id := -1
var label := ""
var outside := Transform3D()    # where to put the player when they come back out, facing the street


func _init() -> void:
	monitorable = false
	collision_layer = 0
	collision_mask = 0xFFFFFFFF
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	cs.shape = box
	cs.position = Vector3(0, SIZE.y * 0.5, SIZE.z * 0.5)   # just outside the facade
	add_child(cs)


func _physics_process(_delta: float) -> void:
	for b in get_overlapping_bodies():
		if b is StreetPlayer:
			var p := b as StreetPlayer
			# local -Z points into the building: go in when facing the door and walking
			# toward it, or pressed up against it (walls zero the velocity there).
			var inward := -global_basis.z
			var yaw := p.facing_yaw()
			var facing := Planet.dir(p.global_position, Vector3(-sin(yaw), 0.0, -cos(yaw)))
			if facing.dot(inward) < 0.6:
				return
			var up := Planet.up(p.global_position)
			var v := p.velocity - up * p.velocity.dot(up)
			var depth := to_local(p.global_position).z
			if (v.length() > 0.8 and v.normalized().dot(inward) > 0.55) or depth < 0.7:
				entered_by_player.emit(self)
			return


func player_inside() -> bool:
	for b in get_overlapping_bodies():
		if b is StreetPlayer:
			return true
	return false
