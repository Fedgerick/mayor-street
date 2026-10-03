extends Node3D
## Street-level test bed on the real demo city: mayor camera, Tab to dive to the street
## and back, walk, sprint, jump, get into a car (E) and drive.
##
## Command-line options (after `--`):
##   --hour=21          set the clock (night shows headlights and lit windows)
##   --street           start at street level (skips the mayor view)
##   --shots=dir        render a sequence of screenshots into dir, then quit

var city: City
var view: CityView
var day_night: DayNight
var cam: MayorCamera
var street: StreetMode
var _args := {}
var _in_street := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	StreetInput.ensure()
	city = City.new()
	day_night = DayNight.new()
	add_child(day_night)
	view = CityView.new()
	add_child(view)
	view.setup(city)
	city.build_demo()
	city.minutes = float(city.game_day()) * 1440.0 + float(_args.get("hour", "16.5")) * 60.0
	view.rebuild_all()
	day_night.update_time(city.time_of_day())
	cam = MayorCamera.new()
	add_child(cam)
	var c := city.cell_center(city.center_cell().x, city.center_cell().y)
	cam.set_view(c + Vector3(0, 0, 30), 260.0, deg_to_rad(-35.0))
	cam.moved.connect(day_night.set_view_distance)
	cam.make_current()
	street = preload("res://player/scenes/street_mode.tscn").instantiate()
	add_child(street)
	street.setup(city)
	street.street_exited.connect(_on_street_exited)
	street.street_entered.connect(func(): day_night.set_view_distance(30.0))
	if _args.has("street"):
		go_street.call_deferred()


func go_street() -> void:
	if _in_street or street.busy:
		return
	_in_street = true
	cam.set_process(false)
	cam.set_process_unhandled_input(false)
	street.enter_street(cam, cam.focus)


func go_mayor() -> void:
	if not _in_street or street.busy:
		return
	# Frame the mayor view on where the player ended up, looking the same way.
	cam.set_view(street.focus_point(), 140.0, street.view_yaw())
	street.exit_street(cam.global_transform, cam.fov)


func _on_street_exited() -> void:
	_in_street = false
	cam.make_current()
	cam.set_process(true)
	cam.set_process_unhandled_input(true)
	day_night.set_view_distance(cam.dist)


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("street_toggle_view"):
		if _in_street:
			go_mayor()
		else:
			go_street()


func _process(delta: float) -> void:
	city.advance(delta, 1.0)
	day_night.update_time(city.time_of_day())
