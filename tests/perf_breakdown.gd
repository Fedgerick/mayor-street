extends SceneTree
## What each part of the scene costs the GPU: draw calls and triangles of each group of
## objects shown on its own, at the benchmark's street spot and over the island. Needs a
## renderer, so not headless:
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver vulkan --resolution 1280x720 \
##       --path . --script res://tests/perf_breakdown.gd [-- --quality=1]

var main: Node
var kit: Node  # the Kit autoload (autoload names can't be used in a --script)
var quality := 1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--quality="):
			quality = int(a.trim_prefix("--quality="))
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func measure() -> Dictionary:
	## Draw calls and triangles of the last frame: in total (every viewport), and for the main
	## viewport split into the normal passes (depth prepass, colour), the shadow maps and 2D.
	await frames(4)
	var rs := RenderingServer
	var vp := root.get_viewport_rid()
	var d := {"draws": rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"tris": rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)}
	for t in [["visible", rs.VIEWPORT_RENDER_INFO_TYPE_VISIBLE], ["shadow", rs.VIEWPORT_RENDER_INFO_TYPE_SHADOW],
			["canvas", rs.VIEWPORT_RENDER_INFO_TYPE_CANVAS]]:
		d[t[0]] = rs.viewport_get_render_info(vp, t[1], rs.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		d[t[0] + "_tris"] = rs.viewport_get_render_info(vp, t[1], rs.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	return d


func _run() -> void:
	root.get_node("Progress").autosave_enabled = false
	kit = root.get_node("Kit")
	main = load("res://scenes/main.tscn").instantiate()
	main.skip_creator = true
	root.add_child(main)
	current_scene = main
	await frames(3)
	main.hud._close_start(true)
	await frames(10)
	main._set_quality(quality)
	main._set_speed(0)
	main.city.minutes = float(main.city.game_day()) * 1440.0 + 11.0 * 60.0
	var c: Vector3 = main.city.cell_center(main.city.center_cell().x, main.city.center_cell().y)

	print("== mayor view, 260 m over downtown ==")
	main.cam.set_view(c, 260.0, deg_to_rad(-35.0))
	await frames(30)
	await _breakdown()

	print("== street level, the benchmark's walk ==")
	main.cam.set_view(Vector3(462, 0, 492), 70.0, -PI * 0.5)
	main.go_street()
	await main.street.street_entered
	main._set_speed(0)
	var p: StreetPlayer = main.street.player
	p.set_controls(false)
	p.rig.yaw = -PI * 0.5 + 0.12
	p.rig.pitch = deg_to_rad(-8.0)
	for i in 60:
		main.life.step(0.05)
		await process_frame
	await _breakdown()
	quit()


func _groups() -> Dictionary:
	## Name -> the nodes that make it up. DayNight (the sun) and the cameras stay on throughout.
	var g := {"buildings": [], "roads": [], "lamps and lights": [], "trees and bushes": [], "beacons": [],
		"terrain": [], "sea": []}
	for n in main.view.get_children():
		if n.name == "Terrain":
			g.terrain.append(n)
		elif n.name == "Sea":
			g.sea.append(n)
		elif String(n.name).begins_with("Chunk_") or (n.get_child_count() > 0 and n.get_child(0) is MultiMeshInstance3D):
			# (a chunk that was rebuilt is renamed "@Node3D@N" while its old twin waits to be freed)
			for mmi in n.get_children():
				var mesh: Mesh = mmi.multimesh.mesh if mmi is MultiMeshInstance3D else null
				var nm := _mesh_name(mesh)
				if nm.begins_with("road_"):
					g.roads.append(mmi)
				elif nm in ["street_lamp", "traffic_light"]:
					g["lamps and lights"].append(mmi)
				elif nm.begins_with("tree") or nm in ["palm", "bush"]:
					g["trees and bushes"].append(mmi)
				elif mesh is SphereMesh:
					g.beacons.append(mmi)
				else:
					g.buildings.append(mmi)
		else:
			g["view/" + String(n.name)] = [n]
	for n in main.get_children():
		if n == main.view or n == main.day_night or n is Camera3D:
			continue
		if n == main.life:
			for c in n.get_children():  # traffic, crowd, police apart
				g["life/" + String(c.name)] = [c]
			continue
		g["main/" + _label(n)] = [n]
	for n in root.get_children():
		if n != main:
			g["autoload/" + String(n.name)] = [n]
	return g


func _label(n: Node) -> String:
	if not String(n.name).begins_with("@"):
		return String(n.name)
	var sc: Script = n.get_script()
	return sc.get_global_name() if sc and sc.get_global_name() != &"" else n.get_class()


func _set_shown(nodes: Array, on: bool) -> void:
	for n in nodes:
		_show(n, on)


func _show(n: Node, on: bool) -> void:
	## Show or hide n, or the nearest things under it that can be hidden.
	if n is Node3D or n is CanvasLayer or n is CanvasItem:
		n.visible = on
		return
	for c in n.get_children():
		_show(c, on)


func _mesh_name(m: Mesh) -> String:
	if m == null:
		return ""
	for k in kit.meshes:
		if kit.meshes[k] == m:
			return k
	return ""


func _breakdown() -> void:
	## Everything on, then nothing (the sky, the post effects), then one group at a time on
	## top of nothing: each group's own cost, its shadows included.
	var all := await measure()
	_line("everything", all)
	var groups := _groups()
	var was := {}
	for k in groups:
		for n in groups[k]:
			was[n] = n.visible if (n is Node3D or n is CanvasLayer or n is CanvasItem) else true
		_set_shown(groups[k], false)
	var none := await measure()
	_line("nothing (sky, post effects)", none)
	var sum := {}
	for k in groups:
		if groups[k].is_empty():
			continue
		var on: Array = groups[k].filter(func(n): return was[n])
		if on.is_empty():
			continue
		_set_shown(on, true)
		var m := await measure()
		_set_shown(on, false)
		var d := {}
		for f in m:
			d[f] = m[f] - none[f]
			sum[f] = sum.get(f, 0) + d[f]
		if d.draws != 0 or d.tris > 1000:
			_line("  " + k + " (%d)" % on.size(), d)
	_line("sum of the groups", sum)
	for k in groups:
		for n in groups[k]:
			if was[n]:
				_show(n, true)
	main.day_night.light.shadow_enabled = false
	var no_shadow := await measure()
	main.day_night.light.shadow_enabled = true
	_line("sun shadows off", no_shadow)
	var vps := root.find_children("*", "SubViewport", true, false)
	print("  sub-viewports in the tree: %d %s" % [vps.size(), vps.map(func(v): return String(v.get_path()))])
	var surf := 0
	var nmesh := 0
	for k in kit.meshes:
		surf += kit.meshes[k].get_surface_count()
		nmesh += 1
	print("  kit: %d meshes with %d surfaces (%.1f per mesh)" % [nmesh, surf, float(surf) / maxi(nmesh, 1)])


func _line(label: String, d: Dictionary) -> void:
	print("%-36s %5d draws (%5d colour+depth, %5d shadow, %4d 2D)  %6dk tris (%5dk shadow)" % [label,
		d.get("draws", 0), d.get("visible", 0), d.get("shadow", 0), d.get("canvas", 0),
		d.get("tris", 0) / 1000, d.get("shadow_tris", 0) / 1000])
