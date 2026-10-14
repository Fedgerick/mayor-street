class_name PlanetSky
extends Node3D
## msp: one sun for the whole ball. The game clock is the time at the starter town; east of
## it the day is further on (local_hour()), so street level anywhere looks like the flat
## game at its own hour. From orbit the real sun lights the ball, so its day and night sides
## sweep round with the clock, and the stars turn with the sun the way they do in Dyson
## Sphere Program. Adds the atmosphere shell and swaps to a starry space sky high up.
## Feed DayNight.update_time() local_hour() of the view, then call follow() each frame.

const SUN_TILT := -0.2  # radians: the sun crosses a little south of the equator
const SPACE_AMBIENT := 0.22  # night side from orbit: dark, not black

var day_night: DayNight
var _atmo: ShaderMaterial
var _space_sky: Sky
var _day_sky: Sky
var _space_mat: ShaderMaterial
var _clouds: MeshInstance3D
var _cloud_mat: ShaderMaterial
const CLOUD_HEIGHT := 70.0   # metres over sea level; only seen from higher than this
const CLOUD_DRIFT := 0.35     # radians a game day the banks turn eastward round the ball
const STORM_DEG_PER_HOUR := 12.0  # how fast a coming storm closes on the city, eastward


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
	var cs := SphereMesh.new()
	cs.radius = Planet.R + CLOUD_HEIGHT
	cs.height = cs.radius * 2.0
	cs.radial_segments = 96
	cs.rings = 48
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = preload("res://planet/clouds.gdshader")
	cs.material = _cloud_mat
	_clouds = MeshInstance3D.new()
	_clouds.name = "Clouds"
	_clouds.mesh = cs
	_clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_clouds.visible = false
	add_child(_clouds)
	_space_sky = Sky.new()
	_space_mat = ShaderMaterial.new()
	_space_mat.shader = preload("res://planet/space_sky.gdshader")
	_space_sky.sky_material = _space_mat
	_day_sky = day_night.env.sky


## Longitude of the starter town (the clock's own meridian): it sits halfway round the map.
static func town_lon() -> float:
	return Planet.lon_of(Vector3(Planet.circumference() * 0.5, 0.0, Planet.V0))


## The hour at a world point when the clock says `clock` at the town.
static func local_hour(clock: float, where: Vector3) -> float:
	var lon := atan2(where.x, where.z)
	return fposmod(clock + wrapf(lon - town_lon(), -PI, PI) * 24.0 / TAU, 24.0)


## Where the sun stands over the ball (world direction toward it) at clock time `clock`:
## overhead the town at noon, moving west an hour's worth of longitude each hour.
static func sun_world(clock: float) -> Vector3:
	return Planet.dir_at(SUN_TILT, town_lon() - (clock - 12.0) / 24.0 * TAU)


## where: the world point the view is about (the mayor focus, or the player); eye: the
## camera; clock: the game clock's hour.
func follow(where: Vector3, eye: Vector3, clock := 12.0) -> void:
	var q := Planet.frame_world(where)
	var env := day_night.env
	var alt := eye.length() - Planet.R
	var space := smoothstep(350.0, 900.0, alt)
	if space > 0.5:
		# From orbit the real sun lights the ball; the stars keep still against it.
		var sun := sun_world(clock)
		day_night.light.basis = Basis.looking_at(-sun, Vector3.UP if absf(sun.y) < 0.99 else Vector3.RIGHT)
		day_night.light.light_color = Color(1.0, 0.97, 0.92)
		day_night.light.light_energy = 1.25
		day_night.light.visible = true
		# The sun runs west round the ball; turn the sky with it (EYEDIR = rotation^-1 * dir).
		env.sky_rotation = Vector3(0.0, -(clock - 12.0) / 24.0 * TAU, 0.0)
	else:
		day_night.light.basis = q * day_night.light.basis
		env.sky_rotation = q.get_euler()
	RenderingServer.global_shader_parameter_set("sun_dir", day_night.light.basis.z)
	RenderingServer.global_shader_parameter_set("orbit_view", 1.0 if space > 0.5 else 0.0)
	env.fog_enabled = space < 0.5
	var want_sky := _space_sky if space > 0.5 else _day_sky
	if env.sky != want_sky:
		env.sky = want_sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR if space > 0.5 else Environment.AMBIENT_SOURCE_SKY
	if space > 0.5:
		env.ambient_light_color = Color(0.35, 0.38, 0.45)
		env.ambient_light_energy = SPACE_AMBIENT
		_space_mat.set_shader_parameter("sun_sky", Basis.from_euler(env.sky_rotation).inverse() * day_night.light.basis.z)
	_atmo.set_shader_parameter("strength", smoothstep(250.0, 700.0, alt))
	_update_clouds(alt)
	_atmo.set_shader_parameter("sun_world", day_night.light.basis.z)


## The cloud layer from high up. Away from the city the banks drift on their own; over it
## they follow Weather, and a rainy spell on the calendar shows as a storm closing in from
## the west, reaching the city as the rain starts.
func _update_clouds(alt: float) -> void:
	var k := smoothstep(500.0, 950.0, alt)  # the mayor view stays clear; from orbit they show
	_clouds.visible = k > 0.0
	if not _clouds.visible:
		return
	var w: Weather = day_night.weather
	var minutes: float = w.city.minutes if w and w.city else 720.0
	_cloud_mat.set_shader_parameter("strength", k)
	_cloud_mat.set_shader_parameter("sun_world", day_night.light.basis.z)
	_cloud_mat.set_shader_parameter("drift", -minutes / 1440.0 * CLOUD_DRIFT)
	_cloud_mat.set_shader_parameter("cover", 0.3 + 0.25 * (w.cloud if w else 0.0))
	var lon := town_lon()
	var power := 0.0
	if w:
		power = maxf(w.rain, 0.0)
		if power < 0.3:
			# Next quarter's weather: storms come from the west. scheduled() also sets the
			# rain's intensity, so keep the current spell's.
			var keep := w.intensity
			var next := (floorf(minutes / 360.0) + 1.0) * 360.0
			if w.scheduled(next) == Weather.Kind.RAIN:
				var hours := (next - minutes) / 60.0
				lon -= deg_to_rad(hours * STORM_DEG_PER_HOUR)
				power = maxf(power, 1.0 - hours / 6.0 * 0.6)
			w.intensity = keep
	var at := Planet.dir_at(0.0, lon)
	_cloud_mat.set_shader_parameter("storm", Vector4(at.x, at.y, at.z, power))
