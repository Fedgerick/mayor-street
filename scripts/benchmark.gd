class_name Benchmark
extends Node
## The benchmark: a fixed two-minute tour of the demo city that measures how well this
## computer runs the game, part by part, and writes the numbers to benchmark.txt next to
## the saves (%APPDATA%\MayorStreet on Windows).
##
## The tour: the island from above, downtown on foot, a drive through traffic, a police
## chase, and the same downtown street at night in the rain (clear skies until then). Every frame it records how long the frame
## took, the draw calls and triangles the GPU was asked for, and how long the GPU, the
## render thread and the game scripts spent on it.
##
## main.gd starts it from the title screen, from the Esc menu (after an autosave, by
## restarting the scene with `pending` set) or with `-- --benchmark`, which quits when done.
## The budgets it checks against are in PERFORMANCE.md.

signal finished(report: String)

## Set before restarting the main scene into a benchmark run, with the graphics level to use.
static var pending := false
static var pending_quality := -1

const FILE := "user://benchmark.txt"
const HISTORY := "user://benchmark-history.txt"
const SETTLE := 0.6  # seconds at the start of each part that aren't counted

# Budgets for Med at 1080p (PERFORMANCE.md).
const FPS_TARGET := 30.0
const SPIKE_MS := 100.0  # a frame this slow is a visible hitch
const COST_SECONDS := 2.0  # each step of the cost check
const STREET_DRAWS := 2000
const STREET_TRIS := 4000000
const MAYOR_DRAWS := 2500

# key, title, seconds measured, at street level
const PARTS := [
	["overview", "Island from above", 17.0, false],
	["street", "Downtown on foot", 16.0, true],
	["drive", "Driving through traffic", 16.0, true],
	["chase", "Police chase", 16.0, true],
	["night", "Downtown at night, rain", 16.0, true],
]
const DAY_HOUR := 11.0
const NIGHT_HOUR := 22.0

# The tour, in demo city cells (City.build_demo: streets every 6 cells east-west and every
# 3 cells north-south around the centre at 40, 40).
const WALK_ROW := 40            # the walk follows the north sidewalk of this street ...
const WALK_FROM := 38           # ... eastwards from this cell
const WALK_SPEED := 5.0         # a jog, m/s
const DRIVE_FROM := Vector2i(45, 40)   # heading east, then round the ring of avenues
const DRIVE_TURNS := {Vector2i(52, 40): 0, Vector2i(52, 34): 3, Vector2i(28, 34): 2,
	Vector2i(28, 46): 1, Vector2i(52, 46): 0}  # cell -> new heading (0 N, 1 E, 2 S, 3 W)
const DRIVE_SPEED := 13.0       # m/s on the straights
const CHASE_SPEED := 18.0
const TURN_SPEED := 7.5
const CHASE_STARS := 3

# The route cells above are for the island, whose town centre is cell (40, 40). On msp the
# demo town is laid out the same way round its own centre, so the route moves with it.
# Positions below are flat map metres; Planet.place / xf_rigid stand them on the ball.
var _shift := Vector2i.ZERO

var main: Node
var running := false
var quit_when_done := false     # started from the command line
var shots_dir := ""             # look-dev: save a frame from the middle of each part here
var report := ""
var results: Array[Dictionary] = []

var _part := -1
var _measuring := false
var _t0 := 0
var _last := 0
var _rec: Dictionary
var _vp_rid: RID
var _vsync_before := DisplayServer.VSYNC_ENABLED
var _banner: Label
var _layer: CanvasLayer
var _stopped := false
var _started_at := ""
var _results_shown := false

# The car on its route: cell index, heading in, heading out, metres into the cell's curve.
# Script time: this node runs first in every process and physics step, the _Tail child last.
var _proc_start := 0
var _proc_end := 0
var _phys_start := 0
var _phys_acc := 0
var _phys_frame := 0
# Script time by system: a _Probe sits just before each system in the tree, so the time from
# one probe to the next is that system's. Prof.lap() splits city life's own step further.
var _probes: Array[Node] = []
var _sys_key := ""
var _sys_t := 0
var _sysf := {}  # this frame's microseconds by system

var _car: Node3D
var _car_y := 0.0
var _cell := 0
var _din := 1
var _dout := 1
var _s := 0.0
var _v := 0.0
var _top := DRIVE_SPEED
var _driving := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000000
	process_physics_priority = -1000000
	var tail := _Tail.new()
	tail.bench = self
	add_child(tail)
	_layer = CanvasLayer.new()
	_layer.layer = 70
	add_child(_layer)
	_banner = Label.new()
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_top = 14
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 18)
	_banner.add_theme_color_override("font_color", Color(1.0, 0.88, 0.55))
	_banner.add_theme_stylebox_override("normal", Hud.panel_style(Color(0.06, 0.08, 0.12, 0.8), 10))
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_banner)


## Runs the whole tour on main's demo city, then writes the report and shows it.
func run(m: Node) -> void:
	main = m
	running = true
	_started_at = Time.get_datetime_string_from_system(false, true)
	seed(20261004)
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_vsync_before = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)  # measure the headroom, not the screen
	main.hud.visible = false
	main.menu.show_hint(&"")
	main._set_speed(0)  # a still clock keeps the light the same; main still steps traffic
	_set_weather(Weather.Kind.CLEAR)
	await _frames(20)

	# 1. The island from above: a slow orbit, then a swoop down over downtown.
	_set_hour(DAY_HOUR)
	if Planet.on:
		_shift = main.city.center_cell() - Vector2i(40, 40)
	var c: Vector3 = main.city.cell_center(main.city.center_cell().x, main.city.center_cell().y)
	_fly(c, 0.0)
	await _frames(30)  # the sky catches up with the jump in time of day
	if not await _part_run(0, func(t: float): _fly(c, t)):
		return

	# 2. Downtown on foot: dive to the sidewalk, then jog east along it.
	var walk_a := _walk_point(0.0)
	main.cam.set_view(walk_a, 70.0, -PI * 0.5)
	_banner_text("Going down to the street")
	main.go_street()
	await main.street.street_entered
	main._set_speed(0)
	_set_hour(DAY_HOUR)
	var p: StreetPlayer = main.street.player
	p.set_controls(false)
	p.set_puppet(true)
	_place_walker(0.0)
	await _frames(10)
	if not await _part_run(1, func(t: float): _place_walker(t)):
		return

	# 3. A drive through traffic, from the end of the walk round the ring of avenues.
	_banner_text("Getting in a car")
	await _get_in_car()
	if _stopped:
		return
	if not await _part_run(2, func(_t: float): pass):
		return

	# 4. A police chase: three stars, and the cars that come after them.
	_banner_text("Here come the police")
	_top = CHASE_SPEED
	_hold_arrests(true)  # the tour films a chase; being busted would jail the rest of it
	main.street.set_wanted(CHASE_STARS)
	await _seconds(3.0)
	if _stopped:
		_hold_arrests(false)
		return
	var chased := await _part_run(3, func(_t: float): _keep_car_whole())
	main.street.set_wanted(0)
	_hold_arrests(false)
	if not chased:
		return

	# 5. The walk again at night.
	_banner_text("Waiting for nightfall")
	main.street.set_wanted(0)
	_driving = false
	await _back_outside()
	if _stopped:
		return
	if main.street.car:
		main.street._leave_car()
		await _seconds(1.4)
	p.set_controls(false)
	p.place(Planet.place(_walk_point(0.0)), -PI * 0.5)
	p.set_puppet(true)
	_set_hour(NIGHT_HOUR)
	_set_weather(Weather.Kind.RAIN)  # the heaviest street: lamps, wet roads, rain and umbrellas
	_place_walker(0.0)
	p.rig.snap()
	await _frames(30)
	if not await _part_run(4, func(t: float): _place_walker(t)):
		return

	# 6. Standing still downtown by day, switch one thing off at a time to see what it costs.
	_banner_text("Checking what costs the most")
	_set_hour(DAY_HOUR)
	_set_weather(Weather.Kind.CLEAR)
	_place_walker(0.25)
	await _frames(30)
	if not await _cost_check():
		return
	_finish()


var render_thread := ""  # "separate" when relaunched with rendering on its own thread
var costs: Array[Dictionary] = []  # the cost check: what turning each thing off saves


func _cost_check() -> bool:
	## Measures the same view with one graphics feature or system off at a time.
	var dn: DayNight = main.day_night
	var vp := get_viewport()
	var scale := vp.scaling_3d_scale
	var shadow_mode := dn.light.directional_shadow_mode
	var q: int = main.quality
	var checks := [
		["Everything on (Med)", func(): pass, func(): pass],
		["No ambient occlusion (SSAO)", func(): dn.env.ssao_enabled = false, func(): dn.env.ssao_enabled = true],
		["No glow", func(): dn.env.glow_enabled = false, func(): dn.env.glow_enabled = true],
		["No fog", func(): dn.env.fog_enabled = false, func(): dn.env.fog_enabled = true],
		["No sun shadows", func(): dn.light.shadow_enabled = false, func(): dn.light.shadow_enabled = true],
		["One shadow map, not two splits", func(): dn.light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL,
			func(): dn.light.directional_shadow_mode = shadow_mode],
		["3D drawn at 67%, not 80%", func(): vp.scaling_3d_scale = 0.67, func(): vp.scaling_3d_scale = scale],
		["3D drawn at 50%", func(): vp.scaling_3d_scale = 0.5, func(): vp.scaling_3d_scale = scale],
		["No cars or people drawn", func(): main.life.visible = false, func(): main.life.visible = true],
		["No street props drawn", func(): if main.dresser: main.dresser.visible = false,
			func(): if main.dresser: main.dresser.visible = true],
		["No buildings or roads drawn", func(): main.view.visible = false, func(): main.view.visible = true],
		["Low graphics", func(): main._set_quality(0), func(): main._set_quality(q)],
		["Everything on again", func(): pass, func(): pass],
	]
	costs.clear()
	for c in checks:
		_banner_text("What costs the most: %s" % c[0])
		c[1].call()
		var r: Dictionary = await _measure(COST_SECONDS)
		c[2].call()
		if _stopped:
			return false
		r.title = c[0]
		costs.append(r)
	return true


func _measure(secs: float) -> Dictionary:
	## Frames over secs seconds (after SETTLE), standing still.
	_rec = {"key": "cost", "title": "", "street": true, "ms": PackedFloat32Array(), "sys": {}, "worst_sys": {},
		"spikes": 0, "draws": 0, "draws_max": 0, "tris": 0, "tris_max": 0, "objects": 0, "gpu": 0.0, "cpu": 0.0,
		"game": 0.0, "physics": 0.0, "cars": 0, "people": 0, "cops": 0, "samples": 0, "seconds": secs}
	var start := Time.get_ticks_usec()
	_last = start
	while not _stopped:
		var t := float(Time.get_ticks_usec() - start) / 1e6
		if t >= secs + SETTLE:
			break
		_measuring = t >= SETTLE
		await get_tree().process_frame
	_measuring = false
	var r := _rec
	r.merge(_stats(r), true)
	return r


## Stop early (Esc): the parts measured so far still go in the report.
func stop() -> void:
	if not running or _stopped:
		return
	_stopped = true
	_measuring = false
	_finish()


# ------------------------------------------------------------------ the tour ---

func _part_run(i: int, step: Callable) -> bool:
	## Runs part i for its seconds, calling step(t) every frame with t from 0 to 1, and
	## records every frame after the first SETTLE seconds. False when stopped.
	_part = i
	var secs: float = PARTS[i][2]
	_banner_text("%d/%d  %s" % [i + 1, PARTS.size(), PARTS[i][1]])
	_install_probes()
	_rec = {"key": PARTS[i][0], "title": PARTS[i][1], "street": PARTS[i][3], "ms": PackedFloat32Array(),
		"sys": {}, "worst_sys": {}, "spikes": 0,
		"draws": 0, "draws_max": 0, "tris": 0, "tris_max": 0, "objects": 0, "gpu": 0.0, "cpu": 0.0,
		"game": 0.0, "physics": 0.0, "cars": 0, "people": 0, "cops": 0, "samples": 0, "seconds": 0.0}
	var start := Time.get_ticks_usec()
	_last = start
	var shot := shots_dir != ""
	while true:
		var t := float(Time.get_ticks_usec() - start) / 1e6 / (secs + SETTLE)
		if t >= 1.0 or _stopped:
			break
		step.call(t)
		_measuring = t * (secs + SETTLE) >= SETTLE
		await get_tree().process_frame
		if shot and t >= 0.5:
			shot = false
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute(shots_dir)
			get_viewport().get_texture().get_image().save_png(shots_dir.path_join("%d_%s.png" % [i + 1, PARTS[i][0]]))
			_last = Time.get_ticks_usec()
	_measuring = false
	if _stopped:
		return false
	_rec.seconds = secs
	results.append(_rec)
	return true


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var proc := float(_proc_end - _proc_start) / 1000.0 if _proc_end > _proc_start else 0.0
	var phys := float(_phys_frame) / 1000.0
	_phys_frame = _phys_acc
	_phys_acc = 0
	_proc_start = now
	_sys_close()
	var frame_sys := _take_sys()
	_sys_key = "engine and autoloads"
	_sys_t = now
	if _measuring:
		var rs := RenderingServer
		var r := _rec
		var frame_ms := float(now - _last) / 1000.0
		r.ms.append(frame_ms)
		for k in frame_sys:
			r.sys[k] = r.sys.get(k, 0.0) + frame_sys[k]
		if frame_ms > SPIKE_MS:
			r.spikes += 1
		if r.ms.size() == 1 or frame_ms > r.get("worst_frame", 0.0):
			r.worst_frame = frame_ms
			r.worst_sys = frame_sys
		var d := rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var tr := rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		r.draws += d
		r.draws_max = maxi(r.draws_max, d)
		r.tris += tr
		r.tris_max = maxi(r.tris_max, tr)
		r.objects += rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		r.gpu += rs.viewport_get_measured_render_time_gpu(_vp_rid)
		r.cpu += rs.viewport_get_measured_render_time_cpu(_vp_rid)
		r.game += proc
		r.physics += phys
		r.samples += 1
		if main.life:
			r.cars = maxi(r.cars, main.life.traffic.cars.size())
			r.people = maxi(r.people, main.life.crowd.peds.size())
			if main.life.police:
				r.cops = maxi(r.cops, main.life.police.cop_count())
	_last = now


func _physics_process(delta: float) -> void:
	_phys_start = Time.get_ticks_usec()
	_sys_key = "engine and autoloads"
	_sys_t = _phys_start
	if _driving and is_instance_valid(_car):
		_drive(delta)


class _Tail extends Node:
	## Runs after every other node's _process and _physics_process, to time the scripts.
	var bench: Benchmark

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1000000
		process_physics_priority = 1000000

	func _process(_delta: float) -> void:
		bench._proc_end = Time.get_ticks_usec()
		bench._sys_close()

	func _physics_process(_delta: float) -> void:
		bench._phys_acc += Time.get_ticks_usec() - bench._phys_start
		bench._sys_close()


class _Probe extends Node:
	## Marks where one system's turn starts, in both process and physics.
	var bench: Benchmark
	var key := ""

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		bench._sys_mark(key)

	func _physics_process(_delta: float) -> void:
		bench._sys_mark(key)


func _install_probes() -> void:
	## A probe before main and before each of its children, and one level further down in
	## the busy ones. Put in again at the start of each part, since the street adds nodes.
	for pr in _probes:
		if is_instance_valid(pr):
			pr.get_parent().remove_child(pr)
			pr.free()
	_probes.clear()
	Prof.on = true
	Prof.acc.clear()
	_add_probe(main, "main")
	for c in main.get_children():
		if c == self or c is _Probe:
			continue
		_add_probe(c, _sys_name(c))
		if c in [main.life, main.street, main.missions, main.nav, main.resident]:
			for g in c.get_children():
				if not g is _Probe:
					_add_probe(g, _sys_name(c) + " / " + _sys_name(g))


func _add_probe(before: Node, key: String) -> void:
	var pr := _Probe.new()
	pr.bench = self
	pr.key = key
	pr.name = "_Probe"
	var parent := before.get_parent()
	parent.add_child(pr, false, Node.INTERNAL_MODE_DISABLED)
	parent.move_child(pr, before.get_index())
	_probes.append(pr)


static func _sys_name(n: Node) -> String:
	var s: Script = n.get_script()
	if s and s.get_global_name() != &"":
		return String(s.get_global_name())
	return String(n.name).trim_prefix("@").get_slice("@", 0)


func _sys_mark(key: String) -> void:
	var t := Time.get_ticks_usec()
	if _sys_key != "":
		_sysf[_sys_key] = _sysf.get(_sys_key, 0) + t - _sys_t
	_sys_key = key
	_sys_t = t


func _sys_close() -> void:
	_sys_mark("")


func _take_sys() -> Dictionary:
	## This frame's script time by system in ms, with city life's own step split by Prof.
	var out := {}
	for k in _sysf:
		out[k] = _sysf[k] / 1000.0
	_sysf.clear()
	if not Prof.acc.is_empty():
		var life_key := _sys_name(main.life) if main.life else ""
		var split := 0.0
		for k in Prof.acc:
			out[k] = out.get(k, 0.0) + Prof.acc[k] / 1000.0
			split += Prof.acc[k] / 1000.0
		Prof.acc.clear()
		# The laps ran inside whichever system called life.step: city life itself, or main.
		for k in [life_key, "main"]:
			var take: float = minf(out.get(k, 0.0), split)
			if take > 0.0:
				out[k] -= take
				split -= take
	return out


func _fly(c: Vector3, t: float) -> void:
	## The mayor camera: a slow orbit high over the island, then down over downtown.
	var k := smoothstep(0.35, 1.0, t)
	var focus := c.lerp(c + Vector3(30, 0, 40), k)
	var dist := lerpf(850.0, 230.0, k)
	var yaw := deg_to_rad(lerpf(-60.0, 40.0, t))
	main.cam.set_view(focus, dist, yaw)


func _walk_point(t: float) -> Vector3:
	# The outer half of the sidewalk, clear of the shop awnings, with the street to the right.
	var road_z := (WALK_ROW + _shift.y + 0.5) * City.TILE
	var x := (WALK_FROM + _shift.x + 0.5) * City.TILE + t * WALK_SPEED * PARTS[1][2]
	return Vector3(x, 0.17, road_z - 5.3)


func _place_walker(t: float) -> void:
	## Jog along the sidewalk with the camera behind, looking down the street.
	var p: StreetPlayer = main.street.player
	p.global_position = Planet.place(_walk_point(t))
	p.face(-PI * 0.5)
	p.visual.animate(get_process_delta_time(), WALK_SPEED, true, 0.0, 0.0)
	p.rig.yaw = -PI * 0.5 - 0.1
	p.rig.pitch = deg_to_rad(-8.0)


func _get_in_car() -> void:
	## A car at the kerb where the walk ended, already ours, then off round the avenues.
	var st: Node = main.street
	var net: RoadNet = main.life.net
	_cell = main.city.idx(DRIVE_FROM.x + _shift.x, DRIVE_FROM.y + _shift.y)
	_din = 1
	_dout = _exit_for(_cell, 1)
	_s = 2.0
	var smp := net.sample(_din * 4 + _dout, _s)
	var at: Vector3 = net.center(_cell) + smp[0]
	_car = st.spawn_car("car_sedan", Planet.place(at + Vector3.UP * 0.6), _body_yaw(smp[1]), Color(0.85, 0.12, 0.1))
	_car.set_meta("player_owned", true)  # no theft, no stars
	for i in 45:  # let it settle on its wheels to learn the ride height
		await get_tree().physics_frame
	if _stopped:
		return
	_car_y = Planet.flat(_car.global_position).y - at.y
	var p: StreetPlayer = st.player
	p.set_puppet(false)
	p.place(_car.exit_point(), _car.heading_yaw())
	st._enter_car(_car)
	while st.switching and not _stopped:
		await get_tree().process_frame
	_car.rig.input_enabled = false
	_car.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_car.freeze = true
	_v = 4.0
	_top = DRIVE_SPEED
	_driving = true


func _drive(dt: float) -> void:
	## Follow the traffic lanes of the road network: straight on, turning at DRIVE_TURNS,
	## braking for corners like the police cars do. The car is kinematic, so nothing in
	## the street can push it off the route.
	var net: RoadNet = main.life.net
	var m := _din * 4 + _dout
	var want := _top
	if net.is_turn(m):
		want = TURN_SPEED
	else:
		var nxt := net.neighbor(_cell, _dout)
		if net.is_road(nxt) and _exit_for(nxt, _dout) != _dout:
			want = lerpf(TURN_SPEED, _top, clampf((net.move_len[m] - _s) / 30.0, 0.0, 1.0))
	_v = move_toward(_v, want, (4.5 if want > _v else 9.0) * dt)
	_s += _v * dt
	while _s >= net.move_len[m]:
		_s -= net.move_len[m]
		_cell = net.neighbor(_cell, _dout)
		_din = _dout
		_dout = _exit_for(_cell, _din)
		m = _din * 4 + _dout
	var smp := net.sample(m, _s)
	var fwd: Vector3 = smp[1]
	_car.global_transform = Planet.xf_rigid(Transform3D(Basis(Vector3.UP, _body_yaw(fwd)),
		net.center(_cell) + smp[0] + Vector3.UP * _car_y))
	_car.rig.heading = _car.heading_yaw()


func _exit_for(cell: int, din: int) -> int:
	var net: RoadNet = main.life.net
	var c := Vector2i(cell % City.W, cell / City.W)
	var d: int = DRIVE_TURNS.get(c - _shift, din)
	if net.has_arm(cell, d):
		return d
	return net.exits(cell, din)[0]


static func _body_yaw(fwd: Vector3) -> float:
	## The yaw that points a DrivableCar along fwd (the body drives along its +Z).
	return atan2(fwd.x, fwd.z)


func _keep_car_whole() -> void:
	## Police fire from three stars; the tour shouldn't end in a burning wreck or a dead driver.
	if is_instance_valid(_car) and _car.health < DrivableCar.MAX_HEALTH * 0.9:
		_car.health = DrivableCar.MAX_HEALTH
	var p: StreetPlayer = main.street.player
	if p and not p.dead and p.health < StreetPlayer.MAX_HEALTH * 0.9:
		p.health = StreetPlayer.MAX_HEALTH


func _back_outside() -> void:
	## If anything still sent the player down or indoors, wait it out and walk back out, so
	## the night walk and the cost check measure the street.
	var t := 0.0
	while main.street.down and t < 20.0 and not _stopped:
		await get_tree().process_frame
		t += get_process_delta_time()
	var inside = main.get("interiors")
	if inside and inside.is_inside():
		while inside.busy and not _stopped:
			await get_tree().process_frame
		await inside.exit()


func _hold_arrests(on: bool) -> void:
	## While on, the police still chase and shoot but can't arrest (0.4.6 on the laptop: they
	## caught the car, and the night walk and cost check were measured in the cells).
	var police = main.life.get("police") if main.life else null
	if police == null or not police.has_signal("busted"):
		return
	var bust := Callable(main.street, "bust")
	if on and police.busted.is_connected(bust):
		police.busted.disconnect(bust)
	elif not on and not police.busted.is_connected(bust):
		police.busted.connect(bust)


func _set_hour(h: float) -> void:
	main.city.minutes = float(main.city.game_day()) * 1440.0 + h * 60.0
	main.view._map_dirty = true


func _set_weather(kind: int) -> void:
	## The same sky on every run, whatever the weather calendar says.
	var w: Weather = main.weather
	if w:
		w.intensity = 0.8
		w.set_weather(kind, true)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _seconds(s: float) -> void:
	var end := Time.get_ticks_usec() + int(s * 1e6)
	while Time.get_ticks_usec() < end and not _stopped:
		_keep_car_whole()
		await get_tree().process_frame


func _banner_text(t: String) -> void:
	_banner.text = "  BENCHMARK   %s   ·   Esc to stop  " % t
	_banner.reset_size()


# -------------------------------------------------------------------- report ---

func _finish() -> void:
	running = false
	_driving = false
	_banner.visible = false
	RenderingServer.viewport_set_measure_render_time(_vp_rid, false)
	DisplayServer.window_set_vsync_mode(_vsync_before)
	report = make_report()
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f:
		f.store_string(report)
		f.close()
	var h := FileAccess.open(HISTORY, FileAccess.READ_WRITE if FileAccess.file_exists(HISTORY) else FileAccess.WRITE)
	if h:
		h.seek_end()
		h.store_string(report + "\n" + "=".repeat(100) + "\n\n")
		h.close()
	print(report)
	finished.emit(report)
	if quit_when_done:
		get_tree().quit()
	else:
		_show_results()


func make_report() -> String:
	var q: int = main.quality
	var vp := get_viewport()
	var lines := PackedStringArray()
	lines.append("MAYOR STREET BENCHMARK   version %s, %s%s" % [ProjectSettings.get_setting("application/config/version", "?"),
		_started_at.replace("T", " ").left(16), "   (stopped early)" if _stopped else ""])
	lines.append("")
	if render_thread != "":
		lines.append("Rendering on its own thread (--render-thread %s)" % render_thread)
	lines.append("Graphics  %s: 3D drawn at %d%% and upscaled with FSR, %s" % [["Low", "Med", "High"][q],
		roundi(vp.scaling_3d_scale * 100.0), ["FXAA, 1 shadow map", "FXAA, SSAO, glow, 2 shadow splits",
		"SMAA, SSAO, SSIL, SSR, glow, 4 shadow splits"][q]])
	var w := get_window()
	var full := w.mode == Window.MODE_FULLSCREEN or w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN
	var hz := roundi(DisplayServer.screen_get_refresh_rate(w.current_screen))
	lines.append("Screen    %dx%d %s, %s screen (vsync off during the run)" % [w.size.x, w.size.y,
		"full screen" if full else "window", ("%d Hz" % hz) if hz > 0 else "unknown Hz"])
	var rs := RenderingServer
	var kinds := ["", ", integrated", ", discrete", ", virtual", ", CPU"]
	var t: int = rs.get_video_adapter_type()
	var drv := OS.get_video_adapter_driver_info()
	lines.append("GPU       %s%s, %s %s%s" % [rs.get_video_adapter_name(), kinds[clampi(t, 0, 4)],
		rs.get_current_rendering_driver_name(), rs.get_video_adapter_api_version(),
		(", driver " + " ".join(drv)) if not drv.is_empty() else ""])
	var mem: Dictionary = OS.get_memory_info()
	var gb := float(mem.get("physical", -1)) / 1073741824.0
	lines.append("CPU       %s, %d threads%s" % [OS.get_processor_name(), OS.get_processor_count(),
		(", %.1f GB RAM" % gb) if gb > 0.0 else ""])
	lines.append("System    %s %s, video memory in use %d MB" % [OS.get_name(), OS.get_version(),
		rs.get_rendering_info(rs.RENDERING_INFO_VIDEO_MEM_USED) / 1048576])
	# Kept-around people meshes and materials: each one holds a few GPU buffers.
	lines.append("Caches    %d people meshes, %d close-up outfits, %d people materials, %d resources" % [
		CharacterModel._merged.size(), HeroLook._built.size(),
		CharacterModel._mat_cache.size() + HeroLook._mats.size(),
		Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)])
	lines.append("")
	lines.append("%-24s %6s %7s %8s %13s %10s %7s %7s %7s %5s %6s" % ["Part", "fps", "1% low", "worst ms",
		"draw calls", "triangles", "GPU ms", "CPU ms", "game ms", "cars", "people"])
	var all := PackedFloat32Array()
	var tot := {"draws": 0, "tris": 0, "gpu": 0.0, "cpu": 0.0, "game": 0.0, "physics": 0.0, "samples": 0}
	for r in results:
		var s := _stats(r)
		r.merge(s, true)
		all.append_array(r.ms)
		for k in tot:
			tot[k] += r[k]
		lines.append("%-24s %6.1f %7.1f %8.1f %13s %10s %7.1f %7.1f %7.1f %5d %6d" % [r.title, s.fps, s.low,
			s.worst, _int(s.draws_avg), _mil(s.tris_avg), s.gpu_avg, s.cpu_avg, s.game_avg, r.cars, r.people])
	if results.size() > 1:
		var whole := _stats({"ms": all, "draws": tot.draws, "tris": tot.tris, "gpu": tot.gpu, "cpu": tot.cpu,
			"game": tot.game, "physics": tot.physics, "samples": tot.samples})
		lines.append("%-24s %6.1f %7.1f %8.1f %13s %10s %7.1f %7.1f %7.1f" % ["Whole tour", whole.fps,
			whole.low, whole.worst, _int(whole.draws_avg), _mil(whole.tris_avg), whole.gpu_avg, whole.cpu_avg,
			whole.game_avg])
	lines.append("")
	lines.append("fps is the average frame rate; 1% low is the frame rate of the slowest 1% of frames. GPU ms")
	lines.append("is the graphics chip's time per frame, CPU ms the render thread's, game ms the game's scripts.")
	lines.append("")
	lines.append("Budget for Med at 1080p: 30 fps or better everywhere, street level under 2,000 draw calls")
	lines.append("and 4 million triangles, the mayor view under 2,500 draw calls.")
	for r in results:
		var over := PackedStringArray()
		if r.fps < FPS_TARGET:
			over.append("too slow (%.1f fps)" % r.fps)
		var dmax := STREET_DRAWS if r.street else MAYOR_DRAWS
		if r.draws_avg > dmax:
			over.append("%s draw calls (budget %s)" % [_int(r.draws_avg), _int(dmax)])
		if r.street and r.tris_avg > STREET_TRIS:
			over.append("%s triangles (budget %s)" % [_mil(r.tris_avg), _mil(STREET_TRIS)])
		lines.append("  %-24s %s" % [r.title, "within budget" if over.is_empty() else ", ".join(over)])
	lines.append("")
	lines.append(_limit_line())
	lines.append("")
	if not costs.is_empty():
		var base: Dictionary = costs[0]
		lines.append("What each thing costs, standing downtown by day (one switched off at a time):")
		lines.append("  %-34s %6s %8s %8s %8s %10s" % ["", "fps", "frame ms", "GPU ms", "game ms", "triangles"])
		for c in costs:
			if c.ms.is_empty():
				lines.append("  %-34s no frames finished in %.0f seconds" % [c.title, COST_SECONDS])
				continue
			var frame := 1000.0 / maxf(c.fps, 0.001)
			lines.append("  %-34s %6.1f %8.1f %8.1f %8.1f %10s%s" % [c.title, c.fps, frame, c.gpu_avg, c.game_avg,
				_mil(c.tris_avg), "" if c == base else "   (GPU %+.1f ms)" % (c.gpu_avg - base.gpu_avg)])
		lines.append("")
	lines.append("Game script time by system, ms a frame (most first), and what the slowest frame spent it on:")
	for r in results:
		lines.append("  %s: %s" % [r.title, _sys_line(r.sys, float(maxi(r.samples, 1)), 8)])
		lines.append("    slowest frame %.0f ms (%d frames over %d ms): %s" % [r.get("worst_frame", 0.0), r.spikes,
			roundi(SPIKE_MS), _sys_line(r.worst_sys, 1.0, 5)])
	lines.append("")
	lines.append("Raw numbers, for comparing runs:")
	for r in results:
		lines.append("  %s fps=%.2f low1=%.2f worst_ms=%.1f draws=%d draws_max=%d tris=%d tris_max=%d objects=%d gpu_ms=%.2f cpu_ms=%.2f game_ms=%.2f physics_ms=%.2f cars=%d people=%d cops=%d frames=%d" % [
			r.key, r.fps, r.low, r.worst, roundi(r.draws_avg), r.draws_max, roundi(r.tris_avg), r.tris_max,
			roundi(r.objects_avg), r.gpu_avg, r.cpu_avg, r.game_avg, r.physics_avg, r.cars, r.people, r.cops, r.samples])
	return "\n".join(lines) + "\n"


static func _sys_line(sys: Dictionary, frames: float, most: int) -> String:
	var keys := sys.keys()
	keys.sort_custom(func(a, b): return sys[a] > sys[b])
	var parts := PackedStringArray()
	for k in keys.slice(0, most):
		if sys[k] / frames >= 0.05:
			parts.append("%s %.1f" % [k, sys[k] / frames])
	return ", ".join(parts) if not parts.is_empty() else "nothing measurable"


static func _stats(r: Dictionary) -> Dictionary:
	var ms: PackedFloat32Array = r.ms
	var n := maxi(ms.size(), 1)
	var total := 0.0
	var worst := 0.0
	for v in ms:
		total += v
		worst = maxf(worst, v)
	var sorted := ms.duplicate()
	sorted.sort()
	var p99: float = sorted[clampi(int(ceil(sorted.size() * 0.99)) - 1, 0, sorted.size() - 1)] if sorted.size() > 0 else 0.0
	var k := float(maxi(int(r.get("samples", n)), 1))
	return {"fps": 1000.0 * ms.size() / maxf(total, 0.001), "low": 1000.0 / maxf(p99, 0.001), "worst": worst,
		"draws_avg": r.draws / k, "tris_avg": r.tris / k, "objects_avg": r.get("objects", 0) / k,
		"gpu_avg": r.gpu / k, "cpu_avg": r.cpu / k, "game_avg": r.game / k, "physics_avg": r.physics / k}


func _limit_line() -> String:
	## Whether the graphics chip or the processor sets the frame rate.
	if results.is_empty():
		return "No part finished, so there are no results."
	var frame := 0.0
	for r in results:
		frame += 1000.0 / maxf(r.fps, 0.001)
	frame /= results.size()
	var gpu := _avg("gpu_avg")
	if gpu <= 0.0:
		return "This renderer can't time the GPU, so it's unknown whether the GPU or the processor holds the frame rate back."
	if gpu >= frame * 0.7:
		return "What holds it back: the graphics chip. The GPU is busy %d%% of each frame." % roundi(100.0 * minf(gpu / frame, 1.0))
	return "What holds it back: the processor. Game scripts take %.1f ms and the render thread %.1f ms a frame, and the GPU is busy %d%% of each frame." % [
		_avg("game_avg") + _avg("physics_avg"), _avg("cpu_avg"), roundi(100.0 * gpu / frame)]


func _avg(key: String) -> float:
	var s := 0.0
	for r in results:
		s += r[key]
	return s / maxf(results.size(), 1)


static func _int(v: float) -> String:
	var s := str(roundi(v))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


static func _mil(v: float) -> String:
	return ("%.1fM" % (v / 1e6)) if v >= 1e6 else ("%dk" % roundi(v / 1000.0))


# ------------------------------------------------------------------- results ---

func _input(e: InputEvent) -> void:
	## The benchmark is the last child of main, so it sees input before the rest of the game.
	var k := e as InputEventKey
	var esc := k != null and k.pressed and not k.echo and k.keycode == KEY_ESCAPE
	if running:
		# The tour drives itself: Esc stops it, and every other key, click or stick is ignored
		# (V would open the city map and pause the game).
		get_viewport().set_input_as_handled()
		if esc or GameMenu.is_start_button(e):
			stop()
	elif _results_shown and esc:
		get_viewport().set_input_as_handled()
		leave()


func _show_results() -> void:
	## The report over the frozen street, with ways to send it.
	_results_shown = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = Hud.make_theme()
	_layer.add_child(root)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.7)
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	var ps := Hud.panel_style(Color(0.07, 0.09, 0.13, 0.96), 16)
	ps.content_margin_left = 32
	ps.content_margin_right = 32
	ps.content_margin_top = 24
	ps.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)
	var title := Label.new()
	title.text = "BENCHMARK RESULTS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	v.add_child(title)
	# The results go on the clipboard straight away, and the buttons sit above the report:
	# a long report used to push them off the bottom of the screen.
	DisplayServer.clipboard_set(report)
	var where := Label.new()
	where.text = "The results are copied. Click in the project chat and press Ctrl+V to paste them.\nThey are also saved to %s." % ProjectSettings.globalize_path(FILE)
	where.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	where.custom_minimum_size = Vector2(900, 0)
	where.add_theme_font_size_override("font_size", 17)
	where.add_theme_color_override("font_color", Color(0.75, 0.95, 0.75))
	v.add_child(where)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	var copy := _button(row, "Copy results again")
	copy.pressed.connect(func():
		DisplayServer.clipboard_set(report)
		copy.text = "Copied")
	_button(row, "Open the folder").pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path("user://")))
	if render_thread == "" and not OS.has_feature("editor"):
		# Godot can only choose this at start-up, so the game starts again to try it.
		_button(row, "Run again, rendering on its own thread").pressed.connect(func():
			OS.create_process(OS.get_executable_path(), ["--render-thread", "separate", "--", "--benchmark",
				"--bench-render-thread=separate"])
			get_tree().quit())
	var body := Label.new()
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"])
	body.add_theme_font_override("font", mono)
	body.add_theme_font_size_override("font_size", 13)
	body.text = report.split("\nRaw numbers")[0].strip_edges()
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	var vs := get_viewport().get_visible_rect().size
	scroll.custom_minimum_size = Vector2(minf(1180.0, vs.x - 120.0), maxf(vs.y - 330.0, 200.0))
	scroll.add_child(body)
	v.add_child(scroll)
	var done := _button(row, "Back to the title screen")
	done.pressed.connect(leave)
	done.grab_focus()


func _button(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(250, 50)
	parent.add_child(b)
	return b


func leave() -> void:
	## Back to the title screen, where Continue loads the game that was autosaved.
	var p := Hud.progress()
	p.playing = false
	p.autosave_enabled = true
	get_tree().paused = false
	get_tree().reload_current_scene()
