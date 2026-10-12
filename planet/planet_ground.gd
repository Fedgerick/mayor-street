class_name PlanetGround
extends RefCounted
## The ground and sea of a planet: one sphere terrain mesh (fine across the belt, coarse
## toward the poles, with the ice cap tinted in) plus its trimesh collision, and a sea
## sphere whose shader reads the sea floor near the south shore. Shared by the real city
## (CityView on msp) and the look-dev prototype (PlanetView).

const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")


## Builds Terrain, TerrainBody and Sea under parent. height, landness and ice are
## Callable(x, z) -> float over flat map metres. Returns the terrain's static body.
static func build(parent: Node3D, rows_h: int, height: Callable, landness: Callable, ice: Callable) -> StaticBody3D:
	var rows := _rows(rows_h)
	var cols := Planet.W * 2
	var step := Planet.circumference() / cols
	var nr := rows.size()
	var nc := cols + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colors := PackedColorArray()
	var hs := PackedFloat32Array()
	verts.resize(nr * nc)
	norms.resize(nr * nc)
	colors.resize(nr * nc)
	hs.resize(nr * nc)
	for j in nr:
		for i in nc:
			hs[j * nc + i] = height.call(i * step, rows[j]) - 0.03
	for j in nr:
		for i in nc:
			var k := j * nc + i
			var x := i * step
			var z := rows[j]
			var p := Vector3(x, hs[k], z)
			verts[k] = Planet.warp(p)
			# Normal from the neighbouring heights, in the local frame, turned onto the ball.
			var hl := hs[j * nc + maxi(i - 1, 0)]
			var hr := hs[j * nc + mini(i + 1, nc - 1)]
			var hu := hs[maxi(j - 1, 0) * nc + i]
			var hd := hs[mini(j + 1, nr - 1) * nc + i]
			var dz := maxf(rows[mini(j + 1, nr - 1)] - rows[maxi(j - 1, 0)], 0.1)
			var ln := Vector3((hl - hr) / (2.0 * step), 1.0, (hu - hd) / dz).normalized()
			norms[k] = Planet.frame(p) * ln
			colors[k] = Color(clampf(landness.call(x, z), 0.0, 1.0), ice.call(x, z), 0)
	var idx := PackedInt32Array()
	for j in nr - 1:
		for i in nc - 1:
			var a := j * nc + i
			var b := a + 1
			var c := a + nc
			var d := c + 1
			idx.append_array([a, b, c, b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	parent.add_child(body)
	_build_sea(parent, rows_h, height, nc, step)
	return body


## Rows of the terrain mesh, in flat z: coarse from the north pole to the belt, every half
## tile across the belt and its shores, coarse again to the south pole.
static func _rows(rows_h: int) -> PackedFloat32Array:
	var north := Planet.V0 - Planet.R * PI * 0.5
	var south := Planet.V0 + Planet.R * PI * 0.5
	var fine0 := -60.0
	var fine1 := rows_h * Planet.TILE + 60.0
	var rows := PackedFloat32Array()
	var z := north
	while z < fine0:
		rows.append(z)
		z += 24.0
	z = fine0
	while z < fine1:
		rows.append(z)
		z += Planet.TILE * 0.5
	z = fine1
	while z < south:
		rows.append(z)
		z += 24.0
	rows.append(south)
	return rows


static func _build_sea(parent: Node3D, rows_h: int, height: Callable, nc: int, step: float) -> void:
	# The water shader reads the sea floor from a height image over flat x/z.
	var z0 := rows_h * Planet.TILE - 120.0
	var z1 := rows_h * Planet.TILE + 300.0
	var ih := 128
	var img := Image.create_empty(nc, ih, false, Image.FORMAT_RF)
	for j in ih:
		var z := lerpf(z0, z1, float(j) / (ih - 1))
		for i in nc:
			img.set_pixel(i, j, Color(-height.call(i * step, z) / 16.0, 0, 0))
	var sphere := SphereMesh.new()
	sphere.radius = Planet.R - 0.7
	sphere.height = (Planet.R - 0.7) * 2.0
	sphere.radial_segments = 256
	sphere.rings = 128
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("height_rect", Vector4(0.0, z0, Planet.circumference(), z1 - z0))
	for p in ["wave_a", "wave_b"]:
		var nt := NoiseTexture2D.new()
		nt.width = 256
		nt.height = 256
		nt.seamless = true
		nt.as_normal_map = true
		nt.bump_strength = 6.0 if p == "wave_a" else 4.0
		var fn := FastNoiseLite.new()
		fn.frequency = 0.03 if p == "wave_a" else 0.05
		fn.seed = 3 if p == "wave_a" else 9
		nt.noise = fn
		mat.set_shader_parameter(p, nt)
	sphere.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Sea"
	mi.mesh = sphere
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
