class_name VehicleKit
extends RefCounted
## The round-3 car kit: loads the Blender-built vehicles in vehicles/assets/, gives them
## the vehicle shaders, and answers questions about them (size, axles, seat, LODs).
##
##   VehicleKit.mesh("car_taxi")            LOD0
##   VehicleKit.mesh("car_taxi", 2)         LOD2
##   VehicleKit.damaged("car_taxi", 3)      burnt-out wreck (1 dented, 2 smashed, 3 burnt)
##   VehicleKit.spec("car_taxi")            {length, width, height, axles, seat, ...}
##   VehicleKit.custom(...)                 MultiMesh custom data (siren, brake, empty, wheels)
##   VehicleKit.install(kit)                drop-in: Kit.mesh("car_sedan") etc. return the new cars
##
## Cars face -Z with the origin on the ground under the car, like the old kit cars.

const ROOT := "res://vehicles/assets/"
const BODY_SHADER := preload("res://vehicles/shaders/vehicle.gdshader")
const GLASS_SHADER := preload("res://vehicles/shaders/vehicle_glass.gdshader")

const MODELS := [
	"car_sedan", "car_hatch", "car_taxi", "car_sports", "car_pickup", "car_van",
	"car_bus", "car_police", "car_ambulance", "car_firetruck", "car_garbage", "car_truck", "car_tow",
]
## Everyday traffic (tinted by the instance colour) and the service vehicles (fixed livery).
const CIVILIAN := ["car_sedan", "car_hatch", "car_sports", "car_pickup", "car_van", "car_truck"]
const SERVICE := ["car_taxi", "car_bus", "car_police", "car_ambulance", "car_firetruck", "car_garbage", "car_tow"]

## Distances (m) where traffic should switch to LOD1 and LOD2.
const LOD_DISTANCES := [28.0, 80.0]

## Custom-data flags (INSTANCE_CUSTOM.r).
const SIREN := 1
const BRAKE := 2
const EMPTY := 4
const HEADLIGHTS := 8

static var _meshes := {}
static var _specs := {}
static var _body: ShaderMaterial
static var _glass: ShaderMaterial


static func materials() -> Array:
	if _body == null:
		_body = ShaderMaterial.new()
		_body.shader = BODY_SHADER
		_body.resource_name = "VehBody"
		_glass = ShaderMaterial.new()
		_glass.shader = GLASS_SHADER
		_glass.resource_name = "VehGlass"
		_glass.render_priority = 1
	return [_body, _glass]


static func _load(nm: String) -> Mesh:
	if _meshes.has(nm):
		return _meshes[nm]
	var path := ROOT + nm + ".glb"
	if not ResourceLoader.exists(path):
		_meshes[nm] = null
		return null
	var scene: PackedScene = load(path)
	var inst := scene.instantiate()
	var mi := _find_mesh(inst)
	var mesh: Mesh = mi.mesh if mi else null
	inst.free()
	if mesh:
		var mats := materials()
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			var glass := mat != null and mat.resource_name == "VehGlass"
			mesh.surface_set_material(s, mats[1] if glass else mats[0])
	_meshes[nm] = mesh
	return mesh


static func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r:
			return r
	return null


## A car's mesh at LOD 0, 1 or 2.
static func mesh(model: String, lod := 0) -> Mesh:
	return _load(model if lod <= 0 else "%s_lod%d" % [model, mini(lod, 2)])


## A damaged LOD0 mesh: 1 dented, 2 smashed (cracked glass, broken lights), 3 burnt wreck.
static func damaged(model: String, stage: int) -> Mesh:
	if stage <= 0:
		return mesh(model)
	return _load("%s_dmg%d" % [model, mini(stage, 3)])


## The LOD to draw a car at, from its distance to the camera.
static func lod_for(distance: float) -> int:
	if distance < LOD_DISTANCES[0]:
		return 0
	return 1 if distance < LOD_DISTANCES[1] else 2


static func spec(model: String) -> Dictionary:
	if _specs.is_empty():
		var f := FileAccess.open(ROOT + "specs.json", FileAccess.READ)
		if f:
			_specs = JSON.parse_string(f.get_as_text())
	return _specs.get(model, {})


## MultiMesh custom data for one car. wheel_angle grows as the car rolls forward
## (distance / wheel radius); steer is the front wheels' angle, + to the left.
static func custom(siren := false, brake := false, empty := false, lights := false,
		wheel_angle := 0.0, steer := 0.0, seed := 0.0) -> Color:
	var fl := (SIREN if siren else 0) | (BRAKE if brake else 0) | (EMPTY if empty else 0) | (HEADLIGHTS if lights else 0)
	return Color(float(fl), fmod(wheel_angle, TAU), steer, seed)


## Drop-in for the city kit: after this, Kit.mesh(name) returns the new car for every
## model in MODELS (and the _lod1/_lod2/_dmgN variants), including the four old names.
static func install(kit: Node) -> void:
	for m in MODELS:
		for nm in [m, m + "_lod1", m + "_lod2", m + "_dmg1", m + "_dmg2", m + "_dmg3"]:
			var me := _load(nm)
			if me:
				kit.meshes[nm] = me
