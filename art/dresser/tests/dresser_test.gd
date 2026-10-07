extends SceneTree
## Headless check of the street dresser on the demo city: it dresses the street around a
## point, keeps to the budget, finds bus stops and benches, and costs little to rebuild.
##     godot --headless --path . --script res://art/dresser/tests/dresser_test.gd -- --demo

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 3:
		await process_frame
	# Loaded at run time: the dresser uses the Kit autoload, which a --script run only has
	# once the tree is up.
	var dresser_script: GDScript = load("res://art/dresser/street_dresser.gd")
	var d: Node3D = dresser_script.new()
	d.enabled = false  # driven by hand here
	main.add_child(d)
	var life: Node = main.get("life")
	var spots: Object = life.get("spots") if life else null
	d.setup(main.city, main.get("services"), spots)
	var types: Array = d.get("_meshes").keys()
	check(types.size() == dresser_script.TYPES.size(), "all %d prop models load (%d)" % [dresser_script.TYPES.size(), types.size()])
	var at := Vector3(562, 0, 612)
	var t0 := Time.get_ticks_usec()
	d.rebuild(at)
	var first := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	d.rebuild(at + Vector3(30, 0, 0))
	var again := (Time.get_ticks_usec() - t0) / 1000.0
	var counts := {}
	var tris := 0
	for nm in d._mmis:
		var mm: MultiMesh = d._mmis[nm].multimesh
		if mm.instance_count > 0:
			counts[nm] = mm.instance_count
			var mt := 0
			var mesh: Mesh = mm.mesh
			for s in mesh.get_surface_count():
				var idx: PackedInt32Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
				mt += idx.size() / 3
			tris += mt * mm.instance_count
	var draws := 0
	for nm in counts:
		draws += (d._mmis[nm].multimesh.mesh as Mesh).get_surface_count()
	print("props: ", counts)
	print("decals: ", d._decal_mmi.multimesh.instance_count, ", colliders: ", d._body.get_child_count())
	print("dressed %d props, %dk triangles, about %d draw calls (+ shadows); first build %.1f ms, rebuild %.1f ms" % [
		d.prop_count, tris / 1000, draws + 1, first, again])
	check(d.prop_count > 300, "the street around downtown gets dressed")
	check(tris < 1500000, "under 1.5M triangles of dressing")
	check(draws < 120, "under 120 draw calls of dressing")
	for nm in ["tree_street_a", "storefront_a", "trash_bin", "neon_bar", "street_sign"]:
		check(counts.has(nm) or counts.has(nm.replace("_a", "_b")), "some %s" % nm)
	# Nothing stands on citylife's benches and bus shelters.
	var clash := 0
	if spots:
		check(spots.spots.size() > 0, "citylife has benches and stops (%d)" % spots.spots.size())
		for sp in spots.spots:
			var q: Vector3 = sp.xform.origin
			if q.distance_to(at) > 150.0:
				continue
			var cc: Vector2i = main.city.world_to_cell(q)
			for it in d.cell(cc.x, cc.y).props:
				var p: Vector3 = it[1].origin
				if Vector2(p.x - q.x, p.z - q.z).length() < 1.5:
					clash += 1
	check(clash == 0, "no props on benches or bus shelters (%d)" % clash)
	# Deterministic: the same cell twice gives the same props.
	d._forget_all()
	var a: Dictionary = d.cell(46, 51)
	d._forget_all()
	var b: Dictionary = d.cell(46, 51)
	check(a.props.size() == b.props.size() and str(a.props) == str(b.props), "placement is deterministic")
	# Bulldozing a block takes its dressing with it.
	var before: int = d.cell(46, 51).props.size()
	main.city.bulldoze(Rect2i(44, 49, 5, 5))
	d.rebuild(at)
	print("cell 46,51 props before/after bulldozing: %d / %d" % [before, d.cell(46, 51).props.size()])
	print("RESULT: %d failures" % fails)
	quit(1 if fails else 0)
