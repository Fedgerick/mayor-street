extends SceneTree
## Look-dev shots with the street dressing, for before-and-after pictures and numbers.
## Runs the game's own --shots views (scripts/main.gd LOOK_SHOTS) with a StreetDresser
## added; --nodress takes the same shots without it.
##     xvfb-run -a godot --rendering-driver vulkan --path . --script res://art/dresser/tests/dress_shots.gd \
##         -- --demo --nohud --shots=DIR --only=street,street_night [--nodress]


func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	if "--nodress" in OS.get_cmdline_user_args():
		return
	# main builds the city, services and life in _ready (possibly after a frame), so wait for them
	for i in 120:
		if main.get("city") != null and main.get("life") != null and main.get("services") != null:
			break
		await process_frame
	var d: Node3D = load("res://art/dresser/street_dresser.gd").new()
	main.add_child(d)
	d.setup(main.city, main.get("services"), main.life.spots if main.get("life") else null)
	d.dressed.connect(func(at: Vector3, n: int) -> void: print("dressed %d props around %s" % [n, at]))
