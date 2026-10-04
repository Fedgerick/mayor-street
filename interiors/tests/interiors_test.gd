extends SceneTree
## Headless check of every interior: markers, collision, lights, door data.
##     godot --headless --path . --script res://interiors/tests/interiors_test.gd

const IDS := ["home", "bank", "bunker", "shop_gas", "shop_pawn", "shop_diner", "nightclub", "police"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var fails := 0
	for id in IDS:
		if not Interior.exists(id):
			print("FAIL %s: no model" % id)
			fails += 1
			continue
		var r := Interior.create(id)
		root.add_child(r)
		var bodies := r.find_children("*", "StaticBody3D", true, false)
		var lights := r.find_children("*", "OmniLight3D", true, false)
		var ok := r.marker("spawn") != null and r.marker("exit") != null and bodies.size() > 0 and lights.size() > 0
		print("%s %s: markers=%s bodies=%d lights=%d" % ["ok  " if ok else "FAIL", id, r.marker_names(), bodies.size(), lights.size()])
		if not ok:
			_dump(r, 0)
			fails += 1
		r.free()
	for kind in ["bank", "bunker", "police_station", "nightclub", "warehouse"]:
		print("door %s -> %s" % [kind, InteriorManager.door_info(kind)])
	print("RESULT: %d failures" % fails)
	quit(1 if fails else 0)


func _dump(n: Node, d: int) -> void:
	if d > 3:
		return
	print("  ".repeat(d + 1), n.name, " <", n.get_class(), ">")
	for c in n.get_children():
		_dump(c, d + 1)
