extends SceneTree
## Triangles, vertices and surfaces of every kit mesh, heaviest first: where the city's
## triangle budget goes. Headless is fine:
##   godot --headless --path . --script res://tests/kit_stats.gd

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var kit: Node = root.get_node("Kit")
	var rows := []
	for nm in kit.meshes:
		var m: Mesh = kit.meshes[nm]
		var tris := 0
		var verts := 0
		for s in m.get_surface_count():
			var a := m.surface_get_arrays(s)
			verts += a[Mesh.ARRAY_VERTEX].size()
			var idx = a[Mesh.ARRAY_INDEX]
			tris += (idx.size() if idx != null and idx.size() > 0 else a[Mesh.ARRAY_VERTEX].size()) / 3
		rows.append([nm, m.get_surface_count(), tris, verts])
	rows.sort_custom(func(a, b): return a[2] > b[2])
	print("%-28s %5s %8s %8s" % ["mesh", "surf", "tris", "verts"])
	var total := 0
	for r in rows:
		total += r[2]
		if not (r[0] as String).contains("_lod") and not (r[0] as String).contains("_dmg"):
			print("%-28s %5d %8d %8d" % r)
	print("kit: %d meshes, %d surfaces in all, merge_surfaces=%s" % [rows.size(), rows.reduce(func(a, r): return a + r[1], 0), kit.merge_surfaces])
	quit()
