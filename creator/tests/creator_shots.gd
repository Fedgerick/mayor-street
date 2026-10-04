extends SceneTree
## Screenshots of the creator screen and a spread of looks, for checking the art:
##   xvfb-run godot --rendering-driver vulkan --path . --resolution 1600x900 \
##     -s res://creator/tests/creator_shots.gd -- --shots=DIR

const LOOKS := [
	["you", "You", {}],
	["look_afro_shades", "Look", {"hair": "afro", "face": "shades", "skin": 6, "hair_color": 0, "top": 5, "bottom": 1, "body": "athletic"}],
	["look_ponytail_glasses", "Look", {"hair": "ponytail", "face": "glasses", "skin": 1, "hair_color": 5, "top": 7, "body": "slim"}],
	["look_beard_buzz", "Look", {"hair": "buzz", "face": "beard", "skin": 3, "hair_color": 2, "top": 1, "bottom": 9, "body": "heavy"}],
	["look_mohawk", "Look", {"hair": "mohawk", "face": "stubble", "skin": 4, "hair_color": 9, "top": 0, "body": "average"}],
	["look_long_mustache", "Look", {"hair": "long", "face": "mustache", "skin": 7, "hair_color": 4, "top": 6}],
	["look_bun", "Look", {"hair": "bun", "face": "clean", "skin": 0, "hair_color": 1, "top": 3}],
	["clothes", "Clothes", {"hair": "bald", "face": "clean", "skin": 5, "top": 4, "bottom": 2, "shoes": 5}],
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var dir := "user://creator_shots"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			dir = a.trim_prefix("--shots=")
	DirAccess.make_dir_recursive_absolute(dir)
	var cc := CharacterCreator.new()
	var p := ResidentProfile.new()
	p.name = "Danny Ortiz"
	p.background = "hustler"
	cc.profile = p
	root.add_child(cc)
	for s in LOOKS:
		cc.profile.look = CharacterLook.from_dict(s[2])
		cc._refresh_model()
		cc._show_page(s[1])
		cc._yaw = 0.35 if s[0] != "look_ponytail_glasses" and s[0] != "look_long_mustache" else 1.1
		for i in 40:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(dir.path_join(s[0] + ".png"))
		print("saved ", s[0])
	quit()
