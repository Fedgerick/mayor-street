extends Node
## Cost of HeroLook on the street: the street test bed (player/test/street_test.tscn) with
## traffic and people, at street level, measured with and without the hero look.
##   godot --rendering-driver vulkan -w res://characters/test/hero_perf.tscn -- --street --life [--hero] [--dogs] [--shot=PATH]
## --hero installs HeroLook on everyone; --dogs swaps the crowd's dogs for HeroDog.
## Prints draw calls, triangles and frame time over 30 frames after a settle.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--hero" in args:
		HeroLook.install(get_tree())
	var bed: Node = load("res://player/test/street_test.tscn").instantiate()
	add_child(bed)
	for i in 100:
		await get_tree().process_frame
	if "--dogs" in args and bed.life:
		for n in bed.life.find_children("Dogs", "MultiMeshInstance3D", true, false):
			n.multimesh.mesh = HeroDog.build()
	var heroes := 0
	for n in bed.find_children("HeroLook", "", true, false):
		heroes += 1
	print("hero looks: ", heroes)
	var player: Node = bed.street.player
	print("hero look on: ", player.visual.has_node("HeroLook"), "  player tris: ", player.visual.triangle_count())
	var draws := 0.0
	var prims := 0.0
	var ms := 0.0
	var n := 30
	for i in n:
		var t := Time.get_ticks_usec()
		await get_tree().process_frame
		ms += (Time.get_ticks_usec() - t) / 1000.0
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	print("RESULT draws %.0f  tris %.0f  frame %.1f ms" % [draws / n, prims / n, ms / n])
	for a in args:
		if a.begins_with("--shot="):
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(a.trim_prefix("--shot="))
	get_tree().quit()
