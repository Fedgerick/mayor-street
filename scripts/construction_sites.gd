class_name ConstructionSites
extends Node3D
## Draws the buildings City has under construction (City.sites): a fenced dirt lot, then the
## building rising storey by storey as a bare frame with the finished facade following it up,
## scaffolding round it, and a tower crane on tall ones. When the job is done City adds the
## real building and CityView draws it like any other.
##
## The building itself is its own kit mesh drawn with a variant of kit.gdshader that cuts
## everything above a height (build_top) and shows raw concrete above another (build_done),
## so no extra models are needed. Scaffold, crane and fence meshes are made here from boxes
## and cached by shape, so fifty sites share a handful of meshes.

const SITE_SHADER := preload("res://shaders/site.gdshader")
const KIT_SHADER := preload("res://shaders/kit.gdshader")

## Parts of the job, as fractions of `built`.
const SETUP := 0.08     # the lot is fenced and dug
const TOPPED := 0.80    # the frame reaches full height
const CLAD := 0.92      # the facade catches up; then scaffold and crane come down
const CRANE_OVER := 22.0  # metres: taller buildings get a tower crane

const STEEL := Color(0.52, 0.54, 0.56)
const WOOD := Color(0.62, 0.47, 0.28)
const NET := Color(0.1, 0.42, 0.3)
const CRANE := Color(0.95, 0.7, 0.08)
const DIRT := Color(0.4, 0.32, 0.22)
const CONCRETE := Color(0.6, 0.59, 0.56)

var city: City
var view: Node3D  # CityView: its chunks say what is behind the horizon on msp
var chunk := 4
var _sites := {}      # id -> {root, body, bld, cap, scaffold, mast, head, fence, h, prof, seed}
var _variants := {}   # kit material -> the same material on the construction shader
var _variant_meshes := {}  # mesh name -> copy of a several-material mesh on those variants
var _shader: Shader
var _site_mat: ShaderMaterial
var _cap_mat: StandardMaterial3D
var _scaffolds := {}  # mesh name -> ArrayMesh
var _fences := {}     # lot size -> ArrayMesh
var _masts := {}      # height -> ArrayMesh
var _heads := {}      # jib length -> ArrayMesh
var _profiles := {}   # mesh name -> {h, levels: PackedFloat32Array of x0, x1, z0, z1 per metre}
var _vis_t := 0.0


func setup(c: City, v: Node3D, chunk_size: int) -> void:
	city = c
	view = v
	chunk = chunk_size
	_shader = Shader.new()
	_shader.code = "#define CONSTRUCTION\n" + KIT_SHADER.code
	_site_mat = ShaderMaterial.new()
	_site_mat.shader = SITE_SHADER
	_cap_mat = StandardMaterial3D.new()
	_cap_mat.albedo_color = CONCRETE
	_cap_mat.roughness = 0.9
	city.site_started.connect(_add)
	city.site_ended.connect(func(id: int, _done: bool): _remove(id))
	for id in city.sites:
		_add(id)


func count() -> int:
	return _sites.size()


func _process(delta: float) -> void:
	if _sites.is_empty():
		return
	_vis_t -= delta
	var check := _vis_t <= 0.0
	if check:
		_vis_t = 0.25
	var now := Time.get_ticks_msec() / 1000.0
	for id in _sites:
		var s: Dictionary = _sites[id]
		if check:
			var b: Dictionary = city.sites[id]
			var ch: Node3D = view.chunks.get(Vector2i(b.x / chunk, b.y / chunk)) if view else null
			s.root.visible = ch == null or ch.visible
		if s.root.visible:
			_pose(id, s, now)


# ------------------------------------------------------------------- a site ---

func _add(id: int) -> void:
	if _sites.has(id) or not city.sites.has(id):
		return
	var b: Dictionary = city.sites[id]
	var nm: String = Kit.special_mesh_name(b.kind, b.size, b.variant) if b.has("kind") \
		else Kit.building_mesh_name(b.zone, b.stage, b.size, b.variant)
	var mesh: Mesh = Kit.mesh(nm) if nm != "" else null
	var xf := Transform3D(Basis(Vector3.UP, b.rot * PI * 0.5), city.building_center(b))
	var root := Node3D.new()
	root.name = "Site_%d" % id
	root.transform = Planet.xf(xf)
	add_child(root)
	var s := {"root": root, "h": 0.0, "seed": float(b.seed), "built": -1.0}
	var half: float = b.size * City.TILE * 0.5

	var fence := MeshInstance3D.new()
	fence.mesh = _fence_mesh(b.size)
	fence.material_override = _site_mat
	root.add_child(fence)
	s["fence"] = fence

	# Nobody walks or drives through the job: the hoarding is solid.
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(half * 2.0 - 0.7, 3.0, half * 2.0 - 0.7)
	cs.shape = box
	cs.position = Vector3(0, 1.5, 0)
	body.add_child(cs)
	body.transform = Planet.xf_rigid(xf)
	add_child(body)
	s["body"] = body

	if mesh != null:
		var prof := _profile(nm, mesh)
		s["prof"] = prof
		s["h"] = prof.h
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		mm.set_instance_color(0, view._wall_tint(b) if view else Color.WHITE)
		mm.set_instance_custom_data(0, view._accent(b) if view else Color(1, 1, 1, b.seed))
		var bld := MultiMeshInstance3D.new()
		bld.multimesh = mm
		if mesh.get_surface_count() == 1:
			bld.material_override = _variant(mesh.surface_get_material(0))
		else:
			mm.mesh = _variant_mesh(nm, mesh)
		bld.custom_aabb = mesh.get_aabb()
		root.add_child(bld)
		s["bld"] = bld

		var cap := MeshInstance3D.new()
		var slab := BoxMesh.new()
		slab.size = Vector3.ONE
		cap.mesh = slab
		cap.material_override = _cap_mat
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(cap)
		s["cap"] = cap

		var sc := MeshInstance3D.new()
		sc.mesh = _scaffold_mesh(nm, prof)
		sc.material_override = _site_mat
		sc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(sc)
		s["scaffold"] = sc

		if prof.h > CRANE_OVER:
			var mast := MeshInstance3D.new()
			mast.mesh = _mast_mesh(prof.h + 16.0)
			mast.material_override = _site_mat
			var c := _centre(prof, prof.h * 0.5)
			mast.position = Vector3(c.x, 0, c.y)
			root.add_child(mast)
			s["mast"] = mast
			var head := MeshInstance3D.new()
			head.mesh = _head_mesh(10.0 + 9.0 * b.size)
			head.material_override = _site_mat
			head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mast.add_child(head)
			s["head"] = head
	_sites[id] = s
	_pose(id, s, 0.0)


func _remove(id: int) -> void:
	if not _sites.has(id):
		return
	var s: Dictionary = _sites[id]
	s.root.queue_free()
	s.body.queue_free()
	_sites.erase(id)


## Where the job stands at `built`: heights in metres above the lot for a building h tall.
## Kept apart from the drawing so tests can read it.
static func stage(built: float, h: float) -> Dictionary:
	var band := clampf(h * 0.3, 3.5, 12.0)
	var rise := clampf((built - SETUP) / (TOPPED - SETUP), 0.0, 1.0)
	var top := -1.0 if built < SETUP else lerpf(0.4, h + 0.2, rise)
	var done := top - band
	if built >= TOPPED:
		done = lerpf(h - band, h + 1.0, clampf((built - TOPPED) / (CLAD - TOPPED), 0.0, 1.0))
	var strike := clampf((built - CLAD) / (0.99 - CLAD), 0.0, 1.0)  # scaffold and crane coming down
	var scaffold := -1.0 if built < SETUP else lerpf(top + 1.6, -1.0, strike)
	var crane := lerpf(maxf(top + 9.0, 12.0), -1.0, strike)
	if built < SETUP * 0.6:
		crane = lerpf(-1.0, 12.0, built / (SETUP * 0.6))
	return {"top": top, "done": done, "scaffold": scaffold, "crane": crane,
		"fence": lerpf(0.0, 2.4, clampf(built / (SETUP * 0.5), 0.0, 1.0))}


func _pose(id: int, s: Dictionary, now: float) -> void:
	var b: Dictionary = city.sites.get(id, {})
	if b.is_empty():
		return
	var built: float = b.built
	if s.has("head") and s.head.visible:
		# The jib swings whether or not the job moved on.
		s.head.rotation.y = s.seed * TAU + sin(now * 0.13 + s.seed * 40.0) * 1.3
	if is_equal_approx(built, s.built):
		return
	s.built = built
	var st := stage(built, s.h)
	s.fence.set_instance_shader_parameter(&"clip_top", st.fence)
	if not s.has("bld"):
		return
	s.bld.visible = st.top > 0.0
	s.bld.set_instance_shader_parameter(&"build_top", st.top)
	s.bld.set_instance_shader_parameter(&"build_done", st.done)
	s.scaffold.visible = st.scaffold > 0.0
	s.scaffold.set_instance_shader_parameter(&"clip_top", st.scaffold)
	# The working deck: a slab closing the open top of the frame.
	var cap: MeshInstance3D = s.cap
	cap.visible = st.top > 0.0 and built < TOPPED
	if cap.visible:
		var r := _section(s.prof, st.top)
		cap.position = Vector3((r[0] + r[1]) * 0.5, st.top - 0.15, (r[2] + r[3]) * 0.5)
		cap.scale = Vector3(maxf(r[1] - r[0] - 0.1, 0.5), 0.3, maxf(r[3] - r[2] - 0.1, 0.5))
	if s.has("mast"):
		s.mast.visible = st.crane > 3.0
		s.mast.set_instance_shader_parameter(&"clip_top", st.crane)
		s.head.position.y = st.crane


func _variant_mesh(nm: String, mesh: Mesh) -> Mesh:
	## A mesh with several materials: a copy wearing the construction variant of each.
	if not _variant_meshes.has(nm):
		var copy: Mesh = mesh.duplicate()
		for k in copy.get_surface_count():
			copy.surface_set_material(k, _variant(mesh.surface_get_material(k)))
		_variant_meshes[nm] = copy
	return _variant_meshes[nm]


func _variant(m: Material) -> Material:
	## The kit material with the same look, on the shader that can cut a building short.
	if not m is ShaderMaterial or (m as ShaderMaterial).shader != KIT_SHADER:
		return m
	if not _variants.has(m):
		var v := ShaderMaterial.new()
		v.shader = _shader
		for u in KIT_SHADER.get_shader_uniform_list():
			var val: Variant = (m as ShaderMaterial).get_shader_parameter(u.name)
			if val != null:
				v.set_shader_parameter(u.name, val)
		_variants[m] = v
	return _variants[m]


# ------------------------------------------------------------ mesh profile ---

func _profile(nm: String, mesh: Mesh) -> Dictionary:
	## For each metre of height, the box round everything at or above it: the building's
	## plan at that height (towers step in as they go up).
	if _profiles.has(nm):
		return _profiles[nm]
	var faces := mesh.get_faces()
	var h := 0.0
	for v in faces:
		h = maxf(h, v.y)
	var n := int(ceil(h)) + 1
	var lv := PackedFloat32Array()
	lv.resize(n * 4)
	for k in n:
		lv[k * 4] = INF
		lv[k * 4 + 1] = -INF
		lv[k * 4 + 2] = INF
		lv[k * 4 + 3] = -INF
	for v in faces:
		var k := clampi(int(v.y), 0, n - 1)
		lv[k * 4] = minf(lv[k * 4], v.x)
		lv[k * 4 + 1] = maxf(lv[k * 4 + 1], v.x)
		lv[k * 4 + 2] = minf(lv[k * 4 + 2], v.z)
		lv[k * 4 + 3] = maxf(lv[k * 4 + 3], v.z)
	for k in range(n - 2, -1, -1):
		lv[k * 4] = minf(lv[k * 4], lv[k * 4 + 4])
		lv[k * 4 + 1] = maxf(lv[k * 4 + 1], lv[k * 4 + 5])
		lv[k * 4 + 2] = minf(lv[k * 4 + 2], lv[k * 4 + 6])
		lv[k * 4 + 3] = maxf(lv[k * 4 + 3], lv[k * 4 + 7])
	for k in range(1, n):   # nothing reaches the top metre: it has the plan of the one below
		if lv[k * 4] == INF:
			for j in 4:
				lv[k * 4 + j] = lv[k * 4 - 4 + j]
	if lv[0] == INF:
		lv = PackedFloat32Array([-1.0, 1.0, -1.0, 1.0])
	var p := {"h": h, "levels": lv}
	_profiles[nm] = p
	return p


func _section(prof: Dictionary, y: float) -> Array:
	var lv: PackedFloat32Array = prof.levels
	var k := clampi(int(ceil(y)), 0, lv.size() / 4 - 1)
	return [lv[k * 4], lv[k * 4 + 1], lv[k * 4 + 2], lv[k * 4 + 3]]


func _centre(prof: Dictionary, y: float) -> Vector2:
	var r := _section(prof, y)
	return Vector2((r[0] + r[1]) * 0.5, (r[2] + r[3]) * 0.5)


# ------------------------------------------------------------------ meshes ---

class Boxes:
	## Collects boxes and beams into one mesh with vertex colours.
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()

	func box(centre: Vector3, size: Vector3, col: Color, net := false) -> void:
		_add(Transform3D(Basis.from_scale(size), centre), col, net)

	func beam(a: Vector3, b: Vector3, thick: float, col: Color) -> void:
		var d := b - a
		var l := d.length()
		if l < 0.001:
			return
		var z := d / l
		var x := z.cross(Vector3.UP if absf(z.y) < 0.95 else Vector3.RIGHT).normalized()
		var y := z.cross(x)
		_add(Transform3D(Basis(x * thick, y * thick, z * l), (a + b) * 0.5), col, false)

	func _add(xf: Transform3D, col: Color, net: bool) -> void:
		const F := [
			[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)], [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
			[Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)], [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
			[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)], [Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)]]
		var nb := xf.basis.inverse().transposed()
		for f in F:
			var o: Vector3 = f[0] * 0.5
			var a: Vector3 = f[1] * 0.5
			var b: Vector3 = f[2] * 0.5
			var nn := (nb * (f[0] as Vector3)).normalized()
			for p in [o - a - b, o + a - b, o + a + b, o - a - b, o + a + b, o - a + b]:
				v.append(xf * (p as Vector3))
				n.append(nn)
				c.append(col)
				uv.append(Vector2(1.0 if net else 0.0, 0.0))

	func mesh() -> ArrayMesh:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m


static func _h01(a: float, b: float) -> float:
	return fposmod(sin(a * 12.9898 + b * 78.233) * 43758.5453, 1.0)


func _scaffold_mesh(nm: String, prof: Dictionary) -> ArrayMesh:
	if _scaffolds.has(nm):
		return _scaffolds[nm]
	var bx := Boxes.new()
	var r := _section(prof, 2.0)
	var top: float = prof.h + 1.6
	var levels := int(top / 2.0)
	# Four sides: along axis u from a to b, standing off the wall along axis w.
	var sides := [
		[Vector3(1, 0, 0), r[0], r[1], Vector3(0, 0, 1), r[3]], [Vector3(1, 0, 0), r[0], r[1], Vector3(0, 0, -1), -r[2]],
		[Vector3(0, 0, 1), r[2], r[3], Vector3(1, 0, 0), r[1]], [Vector3(0, 0, 1), r[2], r[3], Vector3(-1, 0, 0), -r[0]]]
	for si in sides.size():
		var sd: Array = sides[si]
		var u: Vector3 = sd[0]
		var w: Vector3 = sd[3]
		var a: float = sd[1] - 1.1
		var b: float = sd[2] + 1.1
		var inner: Vector3 = w * (sd[4] + 0.3)
		var outer: Vector3 = w * (sd[4] + 1.1)
		var bays := maxi(int(ceil((b - a) / 2.5)), 1)
		var step := (b - a) / bays
		for k in bays + 1:
			var at := u * (a + step * k)
			bx.box(at + inner + Vector3(0, top * 0.5, 0), Vector3(0.07, top, 0.07), STEEL)
			bx.box(at + outer + Vector3(0, top * 0.5, 0), Vector3(0.07, top, 0.07), STEEL)
		var mid := u * ((a + b) * 0.5)
		var along := u * (b - a)
		for l in range(1, levels + 1):
			var y := l * 2.0
			bx.box(mid + (inner + outer) * 0.5 + Vector3(0, y, 0), along + w.abs() * 0.75 + Vector3(0, 0.05, 0), WOOD)
			bx.box(mid + outer + Vector3(0, y + 1.0, 0), along + w.abs() * 0.05 + Vector3(0, 0.05, 0), STEEL)
			for k in bays:
				var p0 := u * (a + step * k) + outer
				var p1 := u * (a + step * (k + 1)) + outer
				var hsh := _h01(si * 7.0 + k, l * 3.0 + prof.h)
				if (k + l) % 3 == 0:
					bx.beam(p0 + Vector3(0, y - 2.0, 0), p1 + Vector3(0, y, 0), 0.05, STEEL)
				if hsh < 0.4 and l > 1:
					# A sheet of debris netting over this bay.
					bx.box((p0 + p1) * 0.5 + w * 0.06 + Vector3(0, y - 1.0, 0), u * step + Vector3(0, 2.0, 0) + w.abs() * 0.01, NET, true)
	var m := bx.mesh()
	_scaffolds[nm] = m
	return m


func _fence_mesh(size: int) -> ArrayMesh:
	if _fences.has(size):
		return _fences[size]
	var bx := Boxes.new()
	var half := size * City.TILE * 0.5 - 0.35
	# Bare earth over the lot, and footings poured in a grid.
	bx.box(Vector3(0, 0.1, 0), Vector3(half * 2.0, 0.2, half * 2.0), DIRT)
	var g := half - 2.2
	var nx := maxi(int(g * 2.0 / 3.2), 1)
	for iz in nx + 1:
		for ix in nx + 1:
			var p := Vector3(-g + g * 2.0 * ix / nx, 0.3, -g + g * 2.0 * iz / nx)
			bx.box(p, Vector3(0.9, 0.35, 0.9), CONCRETE)
			for q in [Vector3(0.25, 0, 0.25), Vector3(-0.25, 0, 0.25), Vector3(0.25, 0, -0.25), Vector3(-0.25, 0, -0.25)]:
				bx.box(p + q + Vector3(0, 0.6, 0), Vector3(0.04, 0.9, 0.04), Color(0.45, 0.25, 0.16))
	# Hoarding: painted boards on posts, with a gap for the gate on the street side (+Z).
	var panels := maxi(int(half * 2.0 / 2.0), 1)
	var pw := half * 2.0 / panels
	for side in 4:
		var u := Vector3(1, 0, 0) if side < 2 else Vector3(0, 0, 1)
		var w := Vector3(0, 0, 1 if side == 0 else -1) if side < 2 else Vector3(1 if side == 2 else -1, 0, 0)
		for k in panels:
			var c := -half + pw * (k + 0.5)
			if side == 0 and absf(c) < 2.2:
				continue  # the gate
			var col := Color(0.2, 0.36, 0.62) if (k + side) % 2 == 0 else Color(0.86, 0.86, 0.84)
			bx.box(u * c + w * half + Vector3(0, 1.1, 0), u * (pw - 0.04) + Vector3(0, 2.0, 0) + w.abs() * 0.06, col)
		for k in panels + 1:
			bx.box(u * (-half + pw * k) + w * half + Vector3(0, 1.15, 0), Vector3(0.1, 2.3, 0.1), STEEL)
	# Stacks of materials just inside the gate.
	bx.box(Vector3(half - 1.6, 0.6, half - 1.4), Vector3(1.6, 0.8, 1.0), WOOD)
	bx.box(Vector3(-half + 1.5, 0.5, half - 1.3), Vector3(1.2, 0.6, 1.2), Color(0.7, 0.3, 0.2))
	var m := bx.mesh()
	_fences[size] = m
	return m


func _mast_mesh(height: float) -> ArrayMesh:
	var h := ceilf(height / 4.0) * 4.0
	if _masts.has(h):
		return _masts[h]
	var bx := Boxes.new()
	const W := 0.85
	var corners := [Vector3(W, 0, W), Vector3(-W, 0, W), Vector3(-W, 0, -W), Vector3(W, 0, -W)]
	for c in corners:
		bx.box(c + Vector3(0, h * 0.5, 0), Vector3(0.14, h, 0.14), CRANE)
	for l in int(h / 2.0):
		var y := l * 2.0
		for k in 4:
			var a: Vector3 = corners[k]
			var b: Vector3 = corners[(k + 1) % 4]
			bx.beam(a + Vector3(0, y + 2.0, 0), b + Vector3(0, y + 2.0, 0), 0.07, CRANE)
			if (l + k) % 2 == 0:
				bx.beam(a + Vector3(0, y, 0), b + Vector3(0, y + 2.0, 0), 0.06, CRANE)
			else:
				bx.beam(b + Vector3(0, y, 0), a + Vector3(0, y + 2.0, 0), 0.06, CRANE)
	var m := bx.mesh()
	_masts[h] = m
	return m


func _head_mesh(jib: float) -> ArrayMesh:
	## The top of a tower crane, turning about its origin: jib along +X, counterweight on -X.
	if _heads.has(jib):
		return _heads[jib]
	var bx := Boxes.new()
	bx.box(Vector3(0, 0.5, 0), Vector3(2.2, 1.0, 2.2), STEEL)                 # slewing ring
	bx.box(Vector3(0.4, 1.9, 1.5), Vector3(1.6, 1.8, 1.3), Color(0.9, 0.9, 0.88))  # cab
	bx.box(Vector3(1.22, 2.1, 1.5), Vector3(0.04, 1.0, 1.1), Color(0.1, 0.14, 0.18))  # its window
	var peak := Vector3(0, 7.5, 0)
	for c in [Vector3(0.6, 1, 0.6), Vector3(-0.6, 1, 0.6), Vector3(-0.6, 1, -0.6), Vector3(0.6, 1, -0.6)]:
		bx.beam(c, peak, 0.12, CRANE)
	# Jib: two bottom chords and a top chord, laced.
	var jy := 1.6
	bx.beam(Vector3(0, jy, 0.5), Vector3(jib, jy, 0.5), 0.1, CRANE)
	bx.beam(Vector3(0, jy, -0.5), Vector3(jib, jy, -0.5), 0.1, CRANE)
	bx.beam(Vector3(0, jy + 1.0, 0), Vector3(jib, jy + 1.0, 0), 0.1, CRANE)
	var n := int(jib / 2.0)
	for k in n:
		var x0 := jib * k / n
		var x1 := jib * (k + 1) / n
		bx.beam(Vector3(x0, jy, 0.5), Vector3(x1, jy + 1.0, 0), 0.05, CRANE)
		bx.beam(Vector3(x0, jy, -0.5), Vector3(x1, jy + 1.0, 0), 0.05, CRANE)
		bx.beam(Vector3(x1, jy, 0.5), Vector3(x1, jy, -0.5), 0.05, CRANE)
	# Counter-jib and its weights.
	bx.box(Vector3(-4.0, jy, 0), Vector3(8.0, 0.25, 1.2), CRANE)
	bx.box(Vector3(-6.8, jy + 0.1, 0), Vector3(2.0, 1.7, 1.5), CONCRETE)
	# Ties from the peak.
	bx.beam(peak, Vector3(jib * 0.75, jy + 1.0, 0), 0.04, STEEL)
	bx.beam(peak, Vector3(-7.5, jy + 0.2, 0), 0.04, STEEL)
	# Trolley, cable and hook block, with a load on it.
	var tx := jib * 0.62
	bx.box(Vector3(tx, jy - 0.15, 0), Vector3(1.0, 0.25, 1.1), STEEL)
	bx.box(Vector3(tx, jy - 4.3, 0), Vector3(0.05, 8.0, 0.05), Color(0.12, 0.12, 0.12))
	bx.box(Vector3(tx, jy - 8.5, 0), Vector3(0.4, 0.5, 0.4), CRANE)
	bx.box(Vector3(tx, jy - 9.4, 0), Vector3(2.4, 0.5, 1.2), WOOD)
	var m := bx.mesh()
	_heads[jib] = m
	return m
