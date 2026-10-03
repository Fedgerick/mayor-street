"""Render preview images of the Blender kit, so the look can be judged without Godot.

Run headless with the `bpy` pip module (same as tools/blender/build_kit.py):

    python3 art/tools/render_previews.py              # all shots
    python3 art/tools/render_previews.py -- sheet     # just one: sheet | street | night | props

Images land in art/previews/. Materials approximate the Godot kit shader
(scripts/kit.gd): same base colours and per-building wall/accent tints, flat
stylized shading, warm sun and a sky. Patterns such as brick courses are only
hinted at here; the game shader draws them properly.
"""
import math
import os
import random
import sys

import bpy
from mathutils import Euler, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.normpath(os.path.join(HERE, "..", ".."))
KIT = os.path.join(GAME, "assets", "kit")
OUT = os.path.join(GAME, "art", "previews")
TILE = 12.0

# Mirrors scripts/kit.gd so the previews read like the game.
BASE = {
    "Wall": (0.97, 0.95, 0.9), "Accent": (0.85, 0.82, 0.78), "Brick": (0.78, 0.42, 0.32),
    "Concrete": (0.72, 0.71, 0.69), "Trim": (0.93, 0.92, 0.88), "Roof": (0.3, 0.31, 0.33),
    "RoofTile": (0.62, 0.36, 0.3), "Glass": (0.1, 0.14, 0.18), "Door": (0.55, 0.4, 0.3),
    "Metal": (0.64, 0.67, 0.7), "Awning": (1, 1, 1), "Sign": (1, 1, 1), "Grass": (0.35, 0.55, 0.2),
    "Paving": (0.74, 0.72, 0.68), "Asphalt": (0.2, 0.2, 0.22), "Sidewalk": (0.7, 0.69, 0.66),
    "Curb": (0.8, 0.8, 0.78), "Marking": (0.93, 0.93, 0.9), "MarkingYellow": (0.95, 0.75, 0.2),
    "Bark": (0.4, 0.29, 0.2), "Leaves": (1, 1, 1), "Lamp": (1.0, 0.95, 0.85), "CarBody": (1, 1, 1),
    "Tire": (0.07, 0.07, 0.08), "Headlight": (1.0, 1.0, 0.95), "Taillight": (0.7, 0.05, 0.05),
    "Water": (0.2, 0.5, 0.7),
}
# tint source: 1 = instance wall colour, 2 = instance accent colour, with amount
TINT = {"Wall": (1, 1.0), "Accent": (1, 0.8), "Brick": (1, 0.35), "RoofTile": (2, 0.45),
        "Door": (2, 0.6), "Awning": (2, 1.0), "Sign": (2, 1.0), "Leaves": (3, 1.0), "CarBody": (4, 1.0)}
ROUGH = {"Glass": 0.08, "Metal": 0.45, "CarBody": 0.3, "Headlight": 0.2, "Sign": 0.4}
METAL = {"Metal": 0.45, "CarBody": 0.25, "Glass": 0.1}
WALLS = {
    "r": [(0.98, 0.93, 0.82), (0.86, 0.93, 0.98), (0.93, 0.85, 0.72), (0.82, 0.9, 0.8),
          (0.98, 0.82, 0.74), (1.0, 0.98, 0.95), (0.85, 0.85, 0.88), (0.96, 0.9, 0.6)],
    "c": [(0.95, 0.95, 0.95), (0.85, 0.87, 0.9), (0.93, 0.88, 0.78), (0.8, 0.62, 0.5),
          (0.7, 0.78, 0.88), (0.98, 0.96, 0.9), (0.75, 0.75, 0.75), (0.9, 0.8, 0.7)],
    "i": [(0.75, 0.75, 0.73), (0.62, 0.66, 0.7), (0.7, 0.55, 0.45), (0.62, 0.68, 0.58),
          (0.8, 0.78, 0.7), (0.55, 0.6, 0.68), (0.68, 0.68, 0.66), (0.75, 0.65, 0.5)],
}
ACCENTS = [(0.85, 0.22, 0.2), (0.1, 0.6, 0.62), (0.18, 0.3, 0.6), (0.95, 0.55, 0.12),
           (0.25, 0.6, 0.3), (0.55, 0.3, 0.65), (0.95, 0.8, 0.2), (0.55, 0.35, 0.22)]
LEAVES = [(0.36, 0.6, 0.22), (0.3, 0.52, 0.2), (0.45, 0.62, 0.22), (0.26, 0.46, 0.22),
          (0.55, 0.62, 0.2), (0.32, 0.56, 0.3)]
CARS = [(0.85, 0.12, 0.1), (0.95, 0.95, 0.95), (0.12, 0.12, 0.14), (0.15, 0.3, 0.7),
        (0.7, 0.72, 0.75), (0.95, 0.75, 0.1), (0.1, 0.45, 0.3), (0.55, 0.1, 0.15)]

NIGHT = False
_mat_cache = {}


def srgb_to_lin(c):
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def mul(a, b):
    return tuple(a[i] * b[i] for i in range(3))


def make_mat(name, col, rough, metal, emit=None, windows=False, brick=False):
    key = (name, col, emit, windows, NIGHT)
    if key in _mat_cache:
        return _mat_cache[key]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    lin = srgb_to_lin(col)
    bsdf.inputs["Base Color"].default_value = (*lin, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if brick:
        # subtle brick courses so walls aren't flat slabs
        tc = nt.nodes.new("ShaderNodeTexCoord")
        bt = nt.nodes.new("ShaderNodeTexBrick")
        bt.inputs["Scale"].default_value = 1.0
        bt.inputs["Brick Width"].default_value = 0.25
        bt.inputs["Row Height"].default_value = 0.09
        bt.inputs["Mortar Size"].default_value = 0.012
        bt.inputs["Color1"].default_value = (*lin, 1)
        bt.inputs["Color2"].default_value = (*[x * 0.82 for x in lin], 1)
        bt.inputs["Mortar"].default_value = (*[min(1, x * 1.5 + 0.1) for x in lin], 1)
        nt.links.new(tc.outputs["Object"], bt.inputs["Vector"])
        nt.links.new(bt.outputs["Color"], bsdf.inputs["Base Color"])
    if emit is not None:
        bsdf.inputs["Emission Color"].default_value = (*srgb_to_lin(emit[0]), 1)
        bsdf.inputs["Emission Strength"].default_value = emit[1]
    if windows and NIGHT:
        # ~45% of windows lit, warm or cool, picked per 2 m cell of object space
        tc = nt.nodes.new("ShaderNodeTexCoord")
        sc = nt.nodes.new("ShaderNodeVectorMath"); sc.operation = "SCALE"; sc.inputs["Scale"].default_value = 0.55
        fl = nt.nodes.new("ShaderNodeVectorMath"); fl.operation = "FLOOR"
        wn = nt.nodes.new("ShaderNodeTexWhiteNoise"); wn.noise_dimensions = "3D"
        cr = nt.nodes.new("ShaderNodeValToRGB")
        cr.color_ramp.interpolation = "CONSTANT"
        cr.color_ramp.elements[0].color = (0, 0, 0, 1)
        cr.color_ramp.elements[1].position = 0.68
        cr.color_ramp.elements[1].color = (1.0, 0.62, 0.3, 1)
        e = cr.color_ramp.elements.new(0.93); e.color = (0.75, 0.85, 1.0, 1)
        nt.links.new(tc.outputs["Object"], sc.inputs[0])
        nt.links.new(sc.outputs[0], fl.inputs[0])
        nt.links.new(fl.outputs[0], wn.inputs["Vector"])
        nt.links.new(wn.outputs["Value"], cr.inputs["Fac"])
        nt.links.new(cr.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 1.6
    _mat_cache[key] = m
    return m


def restyle(obj, zone, rng):
    """Swap the kit's placeholder materials for preview ones, like kit.gd does in Godot."""
    wall = rng.choice(WALLS.get(zone, WALLS["c"]))
    accent = rng.choice(ACCENTS)
    leaf = rng.choice(LEAVES)
    car = rng.choice(CARS)
    for ob in [obj] + list(obj.children_recursive):
        if ob.type != "MESH":
            continue
        for slot in ob.material_slots:
            if not slot.material:
                continue
            nm = slot.material.name.split(".")[0]
            base = BASE.get(nm, (0.8, 0.8, 0.8))
            col = base
            if nm in TINT:
                src, amt = TINT[nm]
                tint = {1: wall, 2: accent, 3: leaf, 4: car}[src]
                col = mix(base, mul(base, tint), amt)
            emit = None
            if nm == "Lamp":
                emit = ((1.0, 0.85, 0.6), 12.0 if NIGHT else 0.0)
            elif nm == "Headlight":
                emit = ((1, 1, 0.9), 6.0 if NIGHT else 0.0)
            elif nm == "Taillight":
                emit = ((1, 0.1, 0.05), 4.0 if NIGHT else 0.0)
            elif nm == "Sign":
                emit = (col, 3.0 if NIGHT else 0.15)
            slot.material = make_mat(f"pv_{nm}", col, ROUGH.get(nm, 0.85), METAL.get(nm, 0.0),
                                     emit=emit, windows=(nm == "Glass" and zone in "rci"),
                                     brick=(nm == "Brick"))


def load(sub, name, loc=(0, 0, 0), rot=0.0, zone=None, seed=0):
    path = os.path.join(KIT, sub, name + ".glb")
    if not os.path.exists(path):
        return None
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    root = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(root)
    for o in new:
        if o.parent is None:
            o.parent = root
    root.location = loc
    root.rotation_euler = Euler((0, 0, math.radians(rot)))
    restyle(root, zone or name[0], random.Random(hash((name, seed, loc))))
    return root


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mat_cache.clear()


def setup_render(res=(1600, 900), samples=48):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = int(os.environ.get("PREVIEW_SAMPLES", samples))
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = int(os.environ.get("PREVIEW_PCT", "100"))
    sc.render.image_settings.file_format = "JPEG"
    sc.render.image_settings.quality = 88
    sc.view_settings.view_transform = "AgX"
    sc.view_settings.look = "AgX - Punchy"
    sc.render.film_transparent = False
    sc.view_settings.exposure = float(os.environ.get("PREVIEW_EXPOSURE", "0.3"))


def world(night=False):
    w = bpy.data.worlds.new("World")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes["Background"]
    # simple vertical gradient sky: hazy horizon to clear blue zenith
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    lo, hi = ((0.03, 0.04, 0.09), (0.005, 0.008, 0.025)) if night else ((0.78, 0.84, 0.9), (0.28, 0.48, 0.85))
    ramp.color_ramp.elements[0].color = (*lo, 1)
    ramp.color_ramp.elements[1].position = 0.6
    ramp.color_ramp.elements[1].color = (*hi, 1)
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 1.0 if night else 1.6
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 0.15 if night else 5.5
    sun.color = (0.6, 0.7, 1.0) if night else (1.0, 0.88, 0.72)
    sun.angle = math.radians(1.5)
    so = bpy.data.objects.new("Sun", sun)
    so.rotation_euler = Euler((math.radians(58), 0, math.radians(35 if not night else -60)))
    bpy.context.scene.collection.objects.link(so)


def ground(size=400, col=(0.33, 0.47, 0.25)):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, -0.01))
    g = bpy.context.active_object
    g.data.materials.append(make_mat("pv_ground", col, 0.95, 0.0))


def camera(loc, target, lens=50, ortho=None):
    cam = bpy.data.cameras.new("Cam")
    cam.lens = lens
    cam.clip_end = 2000
    if ortho:
        cam.type = "ORTHO"
        cam.ortho_scale = ortho
    co = bpy.data.objects.new("Cam", cam)
    bpy.context.scene.collection.objects.link(co)
    co.location = loc
    d = Vector(target) - Vector(loc)
    co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = co


def lamp_light(loc, power=900):
    li = bpy.data.lights.new("Lamp", "SPOT")
    li.energy = power
    li.color = (1.0, 0.8, 0.55)
    li.spot_size = math.radians(110)
    li.spot_blend = 0.6
    lo = bpy.data.objects.new("LampL", li)
    lo.location = loc
    bpy.context.scene.collection.objects.link(lo)


def render(name):
    os.makedirs(OUT, exist_ok=True)
    bpy.context.scene.render.filepath = os.path.join(OUT, name + ".jpg")
    bpy.ops.render.render(write_still=True)
    print("wrote", bpy.context.scene.render.filepath)


# ----------------------------------------------------------------- shots ---

def kit_names(sub):
    d = os.path.join(KIT, sub)
    return sorted(f[:-4] for f in os.listdir(d) if f.endswith(".glb")) if os.path.isdir(d) else []


def shot_sheet():
    """Every building, one row per zone and size, columns by stage then variant."""
    global NIGHT
    NIGHT = False
    reset()
    setup_render((2400, 1350), samples=40)
    world()
    ground(800, (0.62, 0.62, 0.6))
    names = kit_names("buildings")
    rows = {}
    for n in names:
        z, st, sz, v = n.split("_")
        rows.setdefault((z, sz), []).append(n)
    order = [("r", "1"), ("r", "2"), ("c", "1"), ("c", "2"), ("i", "1"), ("i", "2")]
    y = 0.0
    maxx = 0.0
    for key in order:
        items = rows.get(key, [])
        if not items:
            continue
        step = 15.0 if key[1] == "1" else 28.0
        x = 0.0
        for n in items:
            load("buildings", n, (x, y, 0), zone=key[0])
            x += step
        maxx = max(maxx, x)
        y += step + 4
    cx, cy = maxx / 2 - 7, y / 2 - 8
    camera((cx + 150, cy - 230, 190), (cx, cy, 10), lens=50)
    render("kit_sheet")


def road_tile(i, j, kind, rot):
    load("roads", kind, (i * TILE, j * TILE, 0), rot, zone="x")


def shot_street(night=False, name="street"):
    """A small downtown crossroads with every zone around it."""
    global NIGHT
    NIGHT = night
    reset()
    setup_render((1920, 1080), samples=64 if night else 48)
    world(night)
    ground(600)
    # roads: E-W along j=0, N-S along i=0
    for i in range(-5, 6):
        if i != 0:
            road_tile(i, 0, "road_straight", 90)
    for j in range(-5, 6):
        if j != 0:
            road_tile(0, j, "road_straight", 0)
    road_tile(0, 0, "road_cross", 0)
    north = {-5: "r_1_1_f", -4: "r_2_1_e", -3: "c_1_1_e", -2: "c_2_1_d", -1: "c_3_1_d",
             1: "c_3_1_a", 2: "c_2_1_c", 3: "c_1_1_b", 4: "c_2_1_b", 5: "r_2_1_d"}
    south = {-5: "r_1_1_c", -4: "r_1_1_a", -3: "r_2_1_b", -2: "c_1_1_c", -1: "c_2_1_b",
             1: "c_1_1_d", 2: "i_1_1_a", 3: "i_2_1_a", 4: "i_1_1_c", 5: "i_2_1_b"}
    for i, n in north.items():
        load("buildings", n, (i * TILE, TILE, 0), 0)
    for i, n in south.items():
        load("buildings", n, (i * TILE, -TILE, 0), 180)
    # along the N-S road, facing it
    east = {2: "c_2_1_c", 3: "r_2_1_c", 4: "r_1_1_d", -2: "i_1_1_b", -3: "i_2_1_c", -4: "i_1_1_a"}
    west = {2: "c_3_1_c", 3: "r_3_1_a", 4: "r_2_1_b", -3: "r_2_1_a", -4: "r_1_1_b"}
    for j, n in east.items():
        load("buildings", n, (TILE, j * TILE, 0), 90)
    for j, n in west.items():
        load("buildings", n, (-TILE, j * TILE, 0), -90)
    # skyline behind
    load("buildings", "c_3_2_c", (-1.5 * TILE, 2.5 * TILE, 0), 0)
    load("civic", "park", (-TILE, -2 * TILE, 0), -90, zone="c")
    load("civic", "fire_station", (TILE, -5 * TILE, 0), 90, zone="c")
    for i in (-4, -2, 2, 4):
        load("props", "bench", (i * TILE + 1.5, 5.3, 0.17), 180, zone="x")
        load("props", "trash_bin", (i * TILE - 1.0, -5.2, 0.17), 0, zone="x")
    load("props", "hydrant", (-8.0, -5.0, 0.17), 0, zone="x")
    load("props", "bus_stop", (-2.5 * TILE, 5.6, 0.17), 180, zone="x")
    load("buildings", "c_3_2_a", (1.5 * TILE, 2.5 * TILE, 0), 0)
    load("buildings", "r_3_2_a", (3.5 * TILE, 2.5 * TILE, 0), 0)
    load("buildings", "r_3_2_b", (-3.5 * TILE, 2.5 * TILE, 0), 0)
    load("buildings", "c_3_1_c", (-5 * TILE, 2 * TILE, 0), 0)
    # street furniture: lamps on the north sidewalk of the E-W road, trees between
    for k, i in enumerate(range(-5, 6)):
        if i == 0:
            continue
        x = i * TILE
        load("props", "street_lamp", (x - 3, 5.0, 0.17), 90, zone="x")
        load("props", "street_lamp", (x + 3, -5.0, 0.17), -90, zone="x", seed=1)
        tree = ["tree_puffy_a", "tree_puffy_b", "tree_puffy_c"][k % 3]
        load("props", tree, (x + 3, 5.2, 0.17), k * 37, zone="x", seed=k)
        if night:
            lamp_light((x - 3 + 0, 5.0 - 1.4, 6.0))
            lamp_light((x + 3, -5.0 + 1.4, 6.0))
    for j in (-5, -4, -3, -2, -1, 1, 2, 3, 4, 5):
        load("props", "street_lamp", (5.0, j * TILE - 3, 0.17), 0 + 180, zone="x", seed=j)
        if night:
            lamp_light((5.0 - 1.4, j * TILE - 3, 6.0))
    load("props", "traffic_light", (4.6, -4.6, 0.17), 180, zone="x")
    load("props", "traffic_light", (-4.6, 4.6, 0.17), 0, zone="x")
    # traffic
    cars = ["car_sedan", "car_hatch", "car_van", "car_truck"]
    rng = random.Random(4)
    for i, x in enumerate((-50, -34, -20, 14, 30, 47)):
        load("cars", cars[i % 4], (x, -1.8, 0.05), -90, zone="x", seed=i)
    for i, x in enumerate((-44, -26, 22, 40, 58)):
        load("cars", cars[(i + 1) % 4], (x, 1.8, 0.05), 90, zone="x", seed=i + 10)
    for i, y in enumerate((-40, -22, 18, 36)):
        load("cars", cars[(i + 2) % 4], (1.8, y, 0.05), 0, zone="x", seed=i + 20)
        load("cars", cars[(i + 3) % 4], (-1.8, y + 8, 0.05), 180, zone="x", seed=i + 30)
    if night:
        camera((58, -70, 40), (0, 6, 12), lens=30)
    else:
        camera((72, -88, 46), (-4, 12, 14), lens=30)
    render(name)


def shot_props():
    global NIGHT
    NIGHT = False
    reset()
    setup_render((1600, 700), samples=40)
    world()
    ground(200, (0.62, 0.62, 0.6))
    x = 0.0
    for n in kit_names("props") + kit_names("cars"):
        sub = "props" if n in kit_names("props") else "cars"
        load(sub, n, (x, 0, 0), 30 if sub == "cars" else 0, zone="x")
        x += 7.0
    camera((x / 2, -38, 14), (x / 2, 0, 3), lens=40)
    render("kit_props")


def shot_extras():
    """The pieces added by build_extra.py: new variants, civic buildings, props."""
    global NIGHT
    NIGHT = False
    reset()
    setup_render((2400, 1350), samples=40)
    world()
    ground(800, (0.62, 0.62, 0.6))
    sys.path.insert(0, HERE)
    import build_extra
    rows = {"small": [], "big": [], "civic": [], "props": []}
    for name, sub, _ in build_extra.JOBS:
        if sub == "props":
            rows["props"].append((sub, name))
        elif sub == "civic":
            rows["civic"].append((sub, name))
        elif name.split("_")[2] == "2":
            rows["big"].append((sub, name))
        else:
            rows["small"].append((sub, name))
    y = 0.0
    for key, step, gap in (("props", 5.0, 8), ("small", 15.0, 18), ("civic", 18.0, 30), ("big", 28.0, 30)):
        x = 0.0
        for sub, n in rows[key]:
            if key == "civic" and n == "hospital":
                x += 6
            load(sub, n, (x, y, 0), zone=n[0] if sub == "buildings" else "c", seed=3)
            x += step if not (key == "civic" and n == "hospital") else 30
        y += gap
    camera((95, -120, 95), (95, 40, 8), lens=38)
    render("kit_extras")


def frame(root, res, yaw=-35.0, pitch=28.0, lens=50, pad=1.08):
    """Point a camera at root's bounding sphere from a 3/4 view."""
    pts = []
    for ob in [root] + list(root.children_recursive):
        if ob.type == "MESH":
            pts += [ob.matrix_world @ Vector(c) for c in ob.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    c = (lo + hi) / 2
    r = (hi - lo).length / 2
    fov = 2 * math.atan(18 / lens)  # vertical, 36 mm sensor fit
    aspect = res[0] / res[1]
    fov = min(fov, 2 * math.atan(math.tan(fov / 2) * aspect)) if aspect < 1 else fov
    dist = r * pad / math.sin(fov / 2)
    yw, pt = math.radians(yaw), math.radians(pitch)
    d = Vector((math.sin(yw) * math.cos(pt), -math.cos(yw) * math.cos(pt), math.sin(pt)))
    camera(c + d * dist, c, lens=lens)


def shot_thumbs(names=None, out="kit_thumbs", cols=6, cell=(480, 400)):
    """One framed render per asset, tiled into a labelled contact sheet."""
    global NIGHT
    NIGHT = False
    from PIL import Image, ImageDraw
    if names is None:
        sys.path.insert(0, HERE)
        import build_extra
        names = [(sub, n) for n, sub, _ in build_extra.JOBS]
    tiles = []
    for sub, n in names:
        reset()
        setup_render(cell, samples=24)
        world()
        ground(4000, (0.5, 0.54, 0.46))
        root = load(sub, n, (0, 0, 0), zone=n[0] if sub == "buildings" else "c", seed=5)
        frame(root, cell)
        tmp = os.path.join(OUT, "_tmp_" + n)
        bpy.context.scene.render.filepath = tmp + ".jpg"
        bpy.ops.render.render(write_still=True)
        im = Image.open(tmp + ".jpg").convert("RGB")
        ImageDraw.Draw(im).rectangle((0, cell[1] - 30, cell[0], cell[1]), fill=(20, 22, 26))
        ImageDraw.Draw(im).text((10, cell[1] - 24), f"{sub}/{n}", fill=(235, 235, 235))
        tiles.append(im)
        os.remove(tmp + ".jpg")
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell[0], rows * cell[1]), (20, 22, 26))
    for i, im in enumerate(tiles):
        sheet.paste(im, ((i % cols) * cell[0], (i // cols) * cell[1]))
    sheet.save(os.path.join(OUT, out + ".jpg"), quality=85)
    print("wrote", out)


SHOTS = {"thumbs": shot_thumbs, "extras": shot_extras, "sheet": shot_sheet, "street": shot_street, "props": shot_props,
         "night": lambda: shot_street(True, "street_night")}

if __name__ == "__main__":
    want = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(SHOTS)
    for s in want:
        SHOTS[s]()
