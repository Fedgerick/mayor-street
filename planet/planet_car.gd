class_name PlanetCar
extends DrivableCar
## DrivableCar on the ball: up points away from the centre, and gravity (a point-gravity
## area set up by PlanetMain) pulls toward it.


func _up() -> Vector3:
	return Planet.up_at(global_position)


func reset_upright() -> void:
	var up := _up()
	var f := forward()
	f = (f - up * f.dot(up)).normalized()
	if f.length() < 0.1:
		f = Planet.frame_world(global_position).x
	var p := Planet.unwarp(global_position)
	p.y = maxf(p.y, 0.0) + 1.0
	global_transform = Transform3D(Basis(up.cross(f), up, f), Planet.warp(p))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_vel = Vector3.ZERO
	_accel = Vector3.ZERO
	_upside_down = 0.0
