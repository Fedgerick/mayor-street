class_name Weather
extends Node
## The sky's mood over the days: clear, cloudy, rain and fog. Each quarter of a game day
## (0-6, 6-12, 12-18, 18-24) picks a state from the city seed and the day, so the same
## city has the same weather when replayed, and a state eases into the next over about
## forty game minutes. Fog only rolls in at night and in the morning.
##
## Everything else reads the eased values here (0..1): `cloud`, `rain`, `fog`, `wind`,
## and `wet` (how wet the streets are, which lags the rain and dries slowly). If the
## project declares the matching global shader uniforms (weather_rain, weather_wet,
## weather_fog, weather_cloud, weather_wind), they are set every frame for the sky,
## road and building shaders. See weather/INTERFACE.md.

enum Kind { CLEAR, CLOUDY, RAIN, FOG }
const NAMES := ["Clear", "Cloudy", "Rain", "Fog"]

# Targets per state: [cloud, rain, fog, wind].
const TARGET := [
	[0.08, 0.0, 0.0, 0.2],
	[0.75, 0.0, 0.05, 0.45],
	[1.0, 1.0, 0.18, 0.7],
	[0.55, 0.0, 1.0, 0.05],
]
# Chance of each state, for day and for night/morning quarters (fog only in the latter).
const ODDS_DAY := [0.5, 0.3, 0.2, 0.0]
const ODDS_EARLY := [0.42, 0.25, 0.15, 0.18]
const EASE_MINUTES := 40.0       # game minutes to move most of the way to a new state
const WET_MINUTES := 15.0        # rain soaks the streets this fast
const DRY_MINUTES := 150.0       # and they dry this slowly
const GLOBALS := ["weather_cloud", "weather_rain", "weather_fog", "weather_wet", "weather_wind"]

signal changed(kind: int)        # the state the weather is heading for changed
signal lightning(pos: Vector3)   # a strike in heavy rain (audio plays thunder after the delay)

var city: City
var kind := Kind.CLEAR           # the state it is heading for
var forced := -1                 # a state set by set_weather() (missions, debug), or -1
var intensity := 1.0             # how hard this spell of rain is (0.4..1)
var cloud := 0.08
var rain := 0.0
var fog := 0.0
var wind := 0.2
var wet := 0.0
var auto_step := true
var focus := Vector3.ZERO        # where lightning strikes around (main sets the camera); city centre if zero
var lightning_on := true

var _rng := RandomNumberGenerator.new()
var _next_strike := 0.0           # game minutes until the next strike

var _last_minutes := -1.0
var _globals: Array[String] = []


func setup(c: City) -> void:
	city = c
	add_to_group("weather")
	_rng.seed = hash([c.map_seed, "lightning"])
	_next_strike = _rng.randf_range(4.0, 20.0)
	for g in GLOBALS:
		if ProjectSettings.has_setting("shader_globals/" + g):
			_globals.append(g)
	_last_minutes = city.minutes
	kind = scheduled(city.minutes)
	_snap()
	_push()


func _process(_delta: float) -> void:
	if auto_step and city:
		step()


## Advance to the city clock (call every frame; the game speed is the clock's).
func step() -> void:
	var m := city.minutes
	var dm := clampf(m - _last_minutes, 0.0, 120.0)
	_last_minutes = m
	var want := forced if forced >= 0 else scheduled(m)
	if want != kind:
		kind = want
		changed.emit(kind)
	advance(dm)
	_strikes(dm)
	_push()


## Heavy rain brings the odd lightning strike somewhere within a kilometre or so.
func _strikes(dm: float) -> void:
	if not lightning_on or rain < 0.7 or dm <= 0.0:
		return
	_next_strike -= dm
	if _next_strike > 0.0:
		return
	_next_strike = _rng.randf_range(3.0, 18.0) / maxf(rain, 0.1)
	var at := Planet.flat(focus)
	if focus == Vector3.ZERO and city:
		at = city.cell_center(City.W / 2, City.H / 2)
	var a := _rng.randf() * TAU
	var r := _rng.randf_range(250.0, 1400.0)
	lightning.emit(Planet.place(at + Vector3(cos(a) * r, 0.0, sin(a) * r)))


## Move the eased values on by `dm` game minutes.
func advance(dm: float) -> void:
	if dm <= 0.0:
		return
	var t: Array = TARGET[kind]
	var k := 1.0 - exp(-dm * 3.0 / EASE_MINUTES)
	cloud = lerpf(cloud, t[0], k)
	rain = lerpf(rain, t[1] * intensity, k)
	fog = lerpf(fog, t[2], k)
	wind = lerpf(wind, t[3], k)
	if rain > 0.05:
		wet = minf(wet + dm / WET_MINUTES * rain, 1.0)
	else:
		# Sun dries the streets faster than night does.
		var sun := 1.6 if city and city.time_of_day() > 9.0 and city.time_of_day() < 17.0 else 1.0
		wet = maxf(wet - dm / DRY_MINUTES * sun * (1.0 - cloud * 0.5), 0.0)


## The state the calendar has for game time `minutes` (ignores set_weather).
func scheduled(minutes: float) -> int:
	var quarter := int(floorf(minutes / 360.0))
	var seed_v: int = city.map_seed if city else 1337
	var r := RandomNumberGenerator.new()
	r.seed = hash([seed_v, quarter])
	var odds: Array = ODDS_EARLY if posmod(quarter, 4) <= 1 else ODDS_DAY
	var x := r.randf()
	var pick := 0
	for i in odds.size():
		x -= odds[i]
		if x <= 0.0:
			pick = i
			break
	# Spells carry over: a quarter often keeps the last one's weather.
	if pick != Kind.FOG and r.randf() < 0.35 and quarter > 0:
		var prev := RandomNumberGenerator.new()
		prev.seed = hash([seed_v, quarter - 1])
		var px := prev.randf()
		var po: Array = ODDS_EARLY if posmod(quarter - 1, 4) <= 1 else ODDS_DAY
		for i in po.size():
			px -= po[i]
			if px <= 0.0:
				if i != Kind.FOG:
					pick = i
				break
	intensity = 0.45 + 0.55 * r.randf() if pick == Kind.RAIN else intensity
	return pick


## Force a state (a mission's storm, the debug menu), or -1 to follow the calendar again.
## instant skips the easing.
func set_weather(k: int, instant := false) -> void:
	forced = k
	if k >= 0 and k != kind:
		kind = k
		changed.emit(kind)
	if instant:
		_snap()
		if kind == Kind.RAIN:
			wet = 1.0
	_push()


func _snap() -> void:
	var t: Array = TARGET[kind]
	cloud = t[0]
	rain = t[1] * intensity
	fog = t[2]
	wind = t[3]
	wet = 1.0 if kind == Kind.RAIN else 0.0


func _push() -> void:
	for g in _globals:
		RenderingServer.global_shader_parameter_set(g, get(g.trim_prefix("weather_")))


# -------------------------------------------------------------- gameplay ---

## Tyre grip for cars: 1 dry .. 0.7 on soaked roads.
func grip() -> float:
	return 1.0 - 0.3 * wet


## How far you can see, 1 clear .. 0.25 in thick fog.
func visibility() -> float:
	return 1.0 - 0.75 * fog


## Share of people out walking who carry an umbrella.
func umbrella_share() -> float:
	return smoothstep(0.08, 0.45, rain) * 0.8


func state_name() -> String:
	return NAMES[kind]


func to_dict() -> Dictionary:
	return {"forced": forced, "wet": wet}


func from_dict(d: Dictionary) -> void:
	forced = int(d.get("forced", -1))
	if city:
		kind = forced if forced >= 0 else scheduled(city.minutes)
		_snap()
	wet = float(d.get("wet", wet))
	_push()
