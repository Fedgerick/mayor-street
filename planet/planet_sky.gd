class_name PlanetSky
extends Node3D
## msp: the sun and sky follow the spot the player is looking at, so street level looks
## like the flat game and from orbit the far side of the ball falls into night. Adds the
## atmosphere shell and swaps to a starry space sky high up. Call follow() each frame
## after DayNight.update_time().

var day_night: DayNight
var _atmo: ShaderMaterial
var _space_sky: Sky
var _day_sky: Sky


func setup(dn: DayNight) -> void:
	day_night = dn
	var shell := SphereMesh.new()
	shell.radius = Planet.R * 1.07
	shell.height = Planet.R * 2.14
	shell.radial_segments = 96
	shell.rings = 48
	_atmo = ShaderMaterial.new()
	_atmo.shader = preload("res://planet/atmosphere.gdshader")
	shell.material = _atmo
	var mi := MeshInstance3D.new()
	mi.name = "Atmosphere"
	mi.mesh = shell
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_space_sky = Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://planet/space_sky.gdshader")
	_space_sky.sky_material = sm
	_day_sky = day_night.env.sky


## where: the world point the view is about (the mayor focus, or the player); eye: the camera.
func follow(where: Vector3, eye: Vector3) -> void:
	var q := Planet.frame_world(where)
	day_night.light.basis = q * day_night.light.basis
	RenderingServer.global_shader_parameter_set("sun_dir", day_night.light.basis.z)
	var env := day_night.env
	env.sky_rotation = q.get_euler()
	var alt := eye.length() - Planet.R
	var space := smoothstep(350.0, 900.0, alt)
	env.fog_enabled = space < 0.5
	var want_sky := _space_sky if space > 0.5 else _day_sky
	if env.sky != want_sky:
		env.sky = want_sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR if space > 0.5 else Environment.AMBIENT_SOURCE_SKY
	if space > 0.5:
		env.ambient_light_color = Color(0.35, 0.38, 0.45)
		env.ambient_light_energy = 0.6
	_atmo.set_shader_parameter("strength", smoothstep(250.0, 700.0, alt))
	_atmo.set_shader_parameter("sun_world", day_night.light.basis.z)
