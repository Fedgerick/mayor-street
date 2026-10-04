"""Special and service buildings for round 2: the ones the Mayor unlocks and places.

Each is a hand-shaped model with a name sign, exported to assets/kit/specials/<id>.glb,
plus art/specials.json describing size, door spot and interior for the building catalog.

    python3 art/tools/build_specials.py              # everything
    python3 art/tools/build_specials.py -- bank      # one id

Uses only material names scripts/kit.gd maps. Name sign letters use "Lamp" (glow at
night) on a "Sign" plate (accent tinted), so a building's accent colour sets its brand.
Same conventions as build_kit.py: Blender Z up, front faces -Y (Godot +Z), 12 m tiles,
origin at the footprint centre, ground at 0.
"""
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "tools", "blender")))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import build_kit as K  # noqa: E402
from build_kit import (UP, Mesh, block_with_windows, fence, flat_roof, gable_roof, hip_roof, lot,  # noqa: E402
                       roof_clutter, storefront)
from build_extra import octagon, poly_cap, ribbon_floors, smooth_blob, trees_row  # noqa: E402
from mathutils import Vector  # noqa: E402

MANIFEST = os.path.normpath(os.path.join(HERE, "..", "specials.json"))
SPECS = {}   # id -> manifest entry, filled by @special


# --------------------------------------------------------------- helpers ---

def text_mesh(m, text, c, u, h, mat="Lamp", depth=0.025, max_w=None):
    """Extruded letters standing on point c, reading along unit u, facing u x up.
    h is the cap height in metres; max_w squeezes long names to fit."""
    cu = bpy.data.curves.new("txt", "FONT")
    cu.body = text
    cu.size = 1.0
    cu.extrude = depth / 2
    cu.resolution_u = 4
    cu.align_x = "CENTER"
    ob = bpy.data.objects.new("txt", cu)
    bpy.context.scene.collection.objects.link(ob)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    if not xs:
        ev.to_mesh_clear()
        bpy.data.objects.remove(ob)
        return 0.0
    cap = max(ys) - min(ys)
    k = h / max(cap, 1e-3)
    w = (max(xs) - min(xs)) * k
    kx = k if not max_w or w <= max_w else k * max_w / w
    xc, y0 = (max(xs) + min(xs)) / 2, min(ys)
    c, u = Vector(c), Vector(u).normalized()
    n = u.cross(UP)
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])   # letters have concave faces and holes
    for f in bm.faces:
        pts = [c + u * ((v.co.x - xc) * kx) + UP * ((v.co.y - y0) * k) + n * (v.co.z + depth / 2) for v in f.verts]
        if (pts[1] - pts[0]).cross(pts[2] - pts[0]).length > 1e-7:
            m.face(pts, mat)
    bm.free()
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    bpy.data.curves.remove(cu)
    return min(w, max_w or w)


def name_sign(m, text, c, u, h, plate="Sign", letters="Lamp", pad=0.35, max_w=None, plate_depth=0.12):
    """Letters on a backing plate. c is the bottom centre of the plate on the wall face."""
    c, u = Vector(c), Vector(u).normalized()
    n = u.cross(UP)
    w = text_mesh(m, text, c + UP * pad + n * plate_depth, u, h, letters, max_w=max_w)
    if plate:
        W = w + pad * 2
        o = c - u * (W / 2)
        m.obox(o, u * W, n * plate_depth, UP * (h + pad * 2), plate)
    return w


def door_box(m, x, y, z, w, h, mat="Door", frame="Trim"):
    """Door on a south-facing wall at y (front face), centred on x."""
    m.box(x - w / 2 - 0.15, y - 0.08, z, x + w / 2 + 0.15, y + 0.01, z + h + 0.18, frame)
    m.box(x - w / 2, y - 0.1, z, x + w / 2, y - 0.07, z + h, mat)


def column(m, x, y, z0, z1, r=0.35, mat="Trim", seg=10):
    m.box(x - r * 1.3, y - r * 1.3, z0, x + r * 1.3, y + r * 1.3, z0 + 0.3, mat)
    m.cyl(x, y, z0 + 0.3, z1 - 0.3, r, mat, seg=seg)
    m.box(x - r * 1.3, y - r * 1.3, z1 - 0.3, x + r * 1.3, y + r * 1.3, z1, mat)


def lattice_mast(m, x, y, z0, z1, w0, w1, mat="Metal", rungs=8, t=0.12):
    """Four-legged tapered lattice tower (pylons, radio masts)."""
    def leg_pos(z, sx, sy):
        f = (z - z0) / (z1 - z0)
        w = w0 + (w1 - w0) * f
        return Vector((x + sx * w / 2, y + sy * w / 2, z))
    corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    for sx, sy in corners:
        a, b = leg_pos(z0, sx, sy), leg_pos(z1, sx, sy)
        d = b - a
        side = d.cross(Vector((sx, sy, 0))).normalized() * t
        m.obox(a - side / 2 - Vector((sx, sy, 0)).normalized() * t / 2, d, side, Vector((sx, sy, 0)).normalized() * t, mat)
    for r in range(rungs + 1):
        z = z0 + (z1 - z0) * r / rungs
        for i in range(4):
            a = leg_pos(z, *corners[i])
            b = leg_pos(z, *corners[(i + 1) % 4])
            d = b - a
            nrm = d.cross(UP).normalized() * t * 0.6
            m.obox(a - nrm / 2, d, nrm, UP * t * 0.7, mat)
        if r < rungs:  # diagonal braces
            z2 = z0 + (z1 - z0) * (r + 1) / rungs
            for i in range(4):
                a = leg_pos(z, *corners[i])
                b = leg_pos(z2, *corners[(i + 1) % 4])
                d = b - a
                nrm = d.cross(UP).normalized() * t * 0.5
                m.obox(a - nrm / 2, d, nrm, (d.cross(nrm)).normalized() * t * 0.5, mat)


def lot_door(x, y, yaw=0.0):
    """Door spot in Godot local coordinates (x right, z toward the street), plus facing."""
    return {"x": round(x, 2), "z": round(-y, 2), "yaw_deg": yaw}


def special(sid, name, size, tier, tags, interior=None, door=None, folder="specials"):
    def wrap(fn):
        SPECS[sid] = {"id": sid, "name": name, "size": size, "tier": tier, "tags": tags,
                      "model": f"res://assets/kit/{folder}/{sid}.glb", "interior": interior,
                      "door": door, "fn": fn, "folder": folder}
        return fn
    return wrap


def street_trees(m, rng, half, xs, y_off=0.9):
    for x in xs:
        m.cyl(x, -half + y_off, 0.12, 1.8, 0.13, "Bark", seg=6, r_top=0.09)
        smooth_blob(m, x, -half + y_off, 2.8, 1.1, "Leaves", rng, sq=0.9, subdiv=1)


# ------------------------------------------------------------------ Town ---

@special("coal_plant", "Coal Power Plant", 2, 0, ["power", "industry"])
def coal_plant(name):
    rng = random.Random(1)
    m = Mesh()
    lot(m, 12, "Asphalt")
    # boiler house + turbine hall
    block_with_windows(m, -11, -6, 1, 6, 0.12, 2, 7.0, "Brick", win_w=1.6, win_h=3.2, pitch=3.0, mullion=True,
                       lintel="Trim")
    flat_roof(m, -11, -6, 1, 6, 14.12, parapet=0.6, rim="Concrete")
    block_with_windows(m, -11, -11, 1, -6, 0.12, 1, 8.0, "Concrete", win_h=2.0, sill=5.0, pitch=2.6,
                       front_skip=lambda f, c: c in (1, 2))
    m.box(-8.6, -11.08, 0.12, -4.4, -10.99, 6.0, "Metal")
    gable_roof(m, -11, -11, 1, -6, 8.12, 2.0, mat="Metal", gable="Concrete", over=0.3)
    name_sign(m, "CITY POWER", (-5.0, -11.0, 8.6), (1, 0, 0), 0.9, max_w=10)
    # two stacks
    for (x, y) in ((-7.5, 2.5), (-3.0, 2.5)):
        m.cyl(x, y, 14.1, 40.0, 1.5, "Concrete", seg=14, r_top=1.1, cap=False)
        for z, mat in ((36.0, "Awning"), (37.8, "Trim"), (39.0, "Awning")):
            m.cyl(x, y, z, z + 0.8, 1.2, mat, seg=14)
        m.cyl(x, y, 39.9, 40.0, 1.0, "Roof", seg=14)
    # coal yard: dark heaps and a conveyor gantry
    for (x, y, r) in ((6.5, 6.0, 4.0), (6.0, -1.5, 3.4), (9.5, 2.0, 2.5)):
        smooth_blob(m, x, y, 0.1, r, "Roof", rng, sq=0.55, subdiv=2, jitter=0.12)
    m.obox((1.0, 4.4, 11.0), (8.0, 0, -8.0), (0, 1.2, 0), (0, 0, 1.2), "Metal")
    for x in (3.0, 5.0, 7.0):
        m.box(x - 0.15, 4.6, 0.12, x + 0.15, 5.4, 11.0 - (x - 1.0), "Metal")
    # cooling fans / transformers
    for i in range(3):
        m.box(3.0 + i * 2.8, -10.0, 0.12, 5.2 + i * 2.8, -7.4, 2.4, "Metal")
        m.cyl(4.1 + i * 2.8, -8.7, 2.4, 2.6, 0.9, "Roof", seg=12)
    fence(m, -11.8, -11.8, 11.8, -11.8, h=2.2, mat="Metal", post=2.4, gap=(0.5, 0.65))
    return m.build(name)


@special("power_pylon", "Power Line Pylon", 0, 0, ["power"], folder="props")
def power_pylon(name):
    m = Mesh()
    lattice_mast(m, 0, 0, 0.0, 20.0, 3.6, 0.9, rungs=7)
    for z, w in ((15.0, 4.5), (18.0, 3.4)):
        m.box(-w, -0.15, z, w, 0.15, z + 0.3, "Metal")
        for s in (-1, 1):
            m.cyl(s * (w - 0.2), 0, z - 1.2, z, 0.1, "Trim", seg=6)
    m.box(-0.6, -0.15, 20.0, 0.6, 0.15, 21.2, "Metal")
    return m.build(name)


@special("substation", "Substation", 1, 0, ["power", "spawned"])
def substation(name):
    m = Mesh()
    lot(m, 6, "Concrete")
    m.box(-5.6, -5.6, 0.12, 5.6, 5.6, 0.2, "Paving")
    for i in range(3):
        x = -3.6 + i * 3.6
        m.box(x - 1.2, -1.0, 0.2, x + 1.2, 1.4, 2.6, "Metal")
        for k in range(3):
            m.cyl(x - 0.6 + k * 0.6, 0.2, 2.6, 3.8, 0.12, "Trim", seg=6)
            m.cyl(x - 0.6 + k * 0.6, 0.2, 3.8, 3.9, 0.22, "Trim", seg=6)
    for x in (-5.0, 5.0):
        lattice_mast(m, x, 3.8, 0.2, 7.0, 1.2, 0.8, rungs=3, t=0.1)
    m.box(-5.0, 3.7, 6.6, 5.0, 3.9, 6.8, "Metal")
    m.box(2.6, -5.4, 0.2, 5.4, -2.8, 3.0, "Concrete", top="Roof")
    name_sign(m, "SUBSTATION 7", (4.0, -5.4, 2.0), (1, 0, 0), 0.32, plate="Sign", letters="Trim", pad=0.12)
    fence(m, -5.8, -5.8, 5.8, -5.8, h=2.4, mat="Metal", post=2.0, gap=(0.2, 0.4))
    fence(m, -5.8, 5.8, 5.8, 5.8, h=2.4, mat="Metal", post=2.0)
    fence(m, -5.8, -5.8, -5.8, 5.8, h=2.4, mat="Metal", post=2.0)
    fence(m, 5.8, -5.8, 5.8, 5.8, h=2.4, mat="Metal", post=2.0)
    return m.build(name)


def garbage_truck(m, x, y, yaw90=False):
    if yaw90:
        m.box(x - 3.2, y - 1.15, 0.6, x + 1.2, y + 1.15, 3.2, "Awning")
        m.box(x + 1.2, y - 1.15, 0.6, x + 3.2, y + 1.15, 2.8, "Trim")
        m.box(x + 3.05, y - 1.0, 1.7, x + 3.22, y + 1.0, 2.6, "Glass")
        for wx in (x - 2.2, x + 2.3):
            for s in (-1, 1):
                m.box(wx - 0.5, y + s * 1.05 - 0.15, 0.12, wx + 0.5, y + s * 1.05 + 0.15, 1.0, "Tire")


@special("garbage_depot", "Garbage Depot", 1, 0, ["sanitation"])
def garbage_depot(name):
    rng = random.Random(3)
    m = Mesh()
    lot(m, 6, "Asphalt")
    x0, x1, y0, y1 = -5.6, 5.6, 0.0, 5.6
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, 6.0, "Metal", win_h=1.0, sill=4.6, pitch=2.8,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    for bx in (-3.0, 0.0, 3.0):
        m.box(bx - 1.25, y0 - 0.08, 0.12, bx + 1.25, y0 + 0.01, 4.2, "Concrete")
        for i in range(8):
            m.box(bx - 1.25, y0 - 0.1, 0.4 + i * 0.48, bx + 1.25, y0 - 0.07, 0.46 + i * 0.48, "Metal")
    gable_roof(m, x0, y0, x1, y1, 6.12, 1.2, mat="Metal", gable="Metal", over=0.25)
    name_sign(m, "SANITATION", (0.0, y0, 4.6), (1, 0, 0), 0.7, max_w=9)
    garbage_truck(m, -2.0, -2.6, True)
    for i in range(4):  # dumpsters
        m.box(-5.4 + i * 1.5, -5.6, 0.12, -4.2 + i * 1.5, -4.6, 1.3, rng.choice(["Accent", "Awning", "Leaves"]))
        m.box(-5.45 + i * 1.5, -5.65, 1.3, -4.15 + i * 1.5, -4.55, 1.4, "Roof")
    for k in range(5):
        smooth_blob(m, 3.6 + rng.uniform(-1.2, 1.2), -4.4 + rng.uniform(-0.8, 0.8), 0.2, 0.5, "Roof", rng,
                    sq=0.7, subdiv=1)
    fence(m, -5.8, -5.8, -5.8, 5.8, h=2.0, mat="Metal", post=2.0)
    return m.build(name)


@special("landfill", "Landfill", 2, 0, ["sanitation"])
def landfill(name):
    rng = random.Random(4)
    m = Mesh()
    lot(m, 12, "Bark")
    for (x, y, r) in ((-4.0, 3.0, 8.0), (5.0, 4.0, 6.0), (2.0, -4.0, 5.0)):
        smooth_blob(m, x, y, -1.0, r, "Grass", rng, sq=0.45, subdiv=2, jitter=0.1)
    for k in range(14):
        x, y = rng.uniform(-9, 9), rng.uniform(-9, 2)
        smooth_blob(m, x, y, 0.3, rng.uniform(0.4, 0.9), rng.choice(["Roof", "Awning", "Accent", "Metal"]), rng,
                    sq=0.6, subdiv=1, jitter=0.2)
    m.box(-11.5, -11.5, 0.12, -6.0, -8.0, 3.0, "Concrete", top="Roof")
    name_sign(m, "LANDFILL", (-8.75, -11.5, 1.8), (1, 0, 0), 0.5, max_w=5)
    fence(m, -11.8, -11.8, 11.8, -11.8, h=2.2, mat="Metal", post=2.4, gap=(0.3, 0.45))
    return m.build(name)


@special("police_station", "Police Station", 1, 0, ["police", "service"], interior="police",
         door=lot_door(0.0, -5.8))
def police_station(name):
    import build_extra as E
    m = Mesh()
    rng = random.Random(132)
    E_police_body(m, rng)
    name_sign(m, "POLICE", (0.0, -5.9, 5.25), (1, 0, 0), 0.62, plate=None, letters="Lamp")
    return m.build(name)


def E_police_body(m, rng):
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.2, 5.2, -3.4, 5.2
    m.box(x0, y0, 0.12, x1, y1, 0.9, "Concrete")
    block_with_windows(m, x0, y0, x1, y1, 0.9, 3, 3.3, "Concrete", win_w=1.6, win_h=1.6, pitch=2.3,
                       front_skip=lambda f, c: f == 0 and c in (1, 2))
    top = 0.9 + 3 * 3.3
    m.box(-2.6, y0 - 2.4, 0.12, 2.6, y0, 0.9, "Concrete")
    for xx in (-2.2, -0.75, 0.75, 2.2):
        m.cyl(xx, y0 - 1.9, 0.9, 4.6, 0.22, "Trim", seg=10)
    m.box(-2.7, y0 - 2.5, 4.6, 2.7, y0, 5.2, "Trim")
    m.box(-1.0, y0 - 0.06, 0.9, 1.0, y0 + 0.02, 3.4, "Glass")
    m.box(x0 - 0.05, y0 - 0.05, top - 0.9, x1 + 0.05, y1 + 0.05, top - 0.4, "Accent")
    flat_roof(m, x0, y0, x1, y1, top, parapet=0.5)
    m.cyl(3.6, 3.4, top, top + 6.0, 0.08, "Metal", seg=6)
    m.box(3.3, 3.2, top + 4.5, 3.9, 3.6, top + 5.3, "Metal")
    # light bar lamps either side of the steps
    for xx in (-2.9, 2.9):
        m.cyl(xx, y0 - 2.6, 0.12, 2.6, 0.08, "Roof", seg=6)
        m.box(xx - 0.25, y0 - 2.85, 2.6, xx + 0.25, y0 - 2.35, 3.1, "Lamp")
    for xx in (-4.4, 4.4):
        m.box(xx - 0.15, -6.0, 0.12, xx + 0.15, -5.7, 0.9, "Concrete")


@special("fire_station", "Fire Station", 1, 0, ["fire", "service"])
def fire_station(name):
    import build_extra as E
    m = copy_into(Mesh(), E.civic_fire_station(name + "_tmp", 131))
    name_sign(m, "FIRE DEPT. 1", (0.0, -3.0, 5.65), (1, 0, 0), 0.55, plate=None, letters="Lamp", max_w=6.4)
    return m.build(name)


def copy_into(m, ob):
    """Copy a built kit object's faces into Mesh m (to add signs to an existing model)."""
    me = ob.data
    for p in me.polygons:
        m.face([me.vertices[i].co.copy() for i in p.vertices], me.materials[p.material_index].name.split(".")[0])
    bpy.data.objects.remove(ob, do_unlink=True)
    return m


# ------------------------------------------------------------------ Tier 1 ---

@special("gas_station", "Gas 'n' Go", 1, 1, ["shop", "gas", "robbable"], interior="shop_gas",
         door=lot_door(0.0, 1.5))
def gas_station(name):
    rng = random.Random(11)
    m = Mesh()
    lot(m, 6, "Paving")
    m.box(-5.8, -5.8, 0.12, 5.8, 1.6, 0.14, "Asphalt")
    for px in (-3.0, 3.0):
        for py in (-4.0, -1.2):
            m.box(px - 0.22, py - 0.22, 0.14, px + 0.22, py + 0.22, 4.6, "Trim")
        # pump islands
        m.box(px - 0.7, -3.6, 0.14, px + 0.7, -1.6, 0.35, "Concrete")
        for py in (-3.1, -2.1):
            m.box(px - 0.35, py - 0.25, 0.35, px + 0.35, py + 0.25, 1.9, "Sign")
            m.box(px - 0.28, py - 0.27, 1.2, px + 0.28, py - 0.24, 1.7, "Glass")
    m.box(-5.2, -5.2, 4.6, 5.2, 0.6, 5.4, "Trim", top="Roof")
    m.box(-5.25, -5.25, 4.8, 5.25, 0.65, 5.2, "Awning")
    name_sign(m, "GAS 'N' GO", (0.0, -5.25, 4.75), (1, 0, 0), 0.38, plate=None, letters="Lamp", max_w=8)
    for x in (-4.2, -1.4, 1.4, 4.2):
        m.box(x - 0.5, -2.8, 4.55, x + 0.5, -1.8, 4.6, "Lamp")
    # shop
    block_with_windows(m, -4.4, 1.6, 4.4, 5.6, 0.12, 1, 3.8, "Wall", win_w=2.2, win_h=1.8, sill=0.6, pitch=3.0,
                       front_skip=lambda f, c: c == 1)
    storefront(m, rng, -4.4, 4.4, 1.6, 0.12, h=3.6, awning=False, sign=False)
    flat_roof(m, -4.4, 1.6, 4.4, 5.6, 3.92, parapet=0.3)
    name_sign(m, "24/7 MART", (0.0, 1.5, 3.95), (1, 0, 0), 0.45, max_w=6)
    # price pylon
    m.box(4.9, -5.6, 0.12, 5.5, -5.0, 6.5, "Trim")
    m.box(4.7, -5.7, 4.5, 5.7, -4.9, 6.8, "Sign")
    for k, z in enumerate((4.8, 5.4, 6.0)):
        m.box(4.85, -5.72, z, 5.55, -5.7, z + 0.4, "Lamp")
    m.box(-5.6, 2.0, 0.12, -4.6, 3.0, 1.6, "Accent")  # ice chest
    return m.build(name)


@special("pawn_shop", "Lucky Pawn", 1, 1, ["shop", "pawn", "fence", "robbable"], interior="shop_pawn",
         door=lot_door(1.6, -3.0))
def pawn_shop(name):
    rng = random.Random(12)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.0, 5.0, -3.0, 5.4
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, 4.2, "Brick", pitch=3.0, win_h=1.4, sill=1.8,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    block_with_windows(m, x0, y0, x1, y1, 4.32, 1, 3.4, "Brick", win_w=1.2, win_h=1.6, pitch=2.4, mullion=True,
                       lintel="Trim")
    # shop window with bars and a security shutter half down
    m.box(x0 + 0.4, y0 - 0.02, 0.12, x0 + 4.6, y0 + 0.01, 0.6, "Trim")
    m.box(x0 + 0.6, y0 - 0.03, 0.6, x0 + 4.4, y0, 3.2, "Glass")
    for i in range(10):
        x = x0 + 0.7 + i * 0.4
        m.box(x - 0.03, y0 - 0.15, 0.6, x + 0.03, y0 - 0.1, 3.2, "Metal")
    m.box(x0 + 0.5, y0 - 0.2, 3.2, x0 + 4.5, y0 - 0.05, 3.6, "Metal")
    door_box(m, 1.6, y0, 0.12, 1.2, 2.4)
    for i in range(6):
        m.box(1.0, y0 - 0.14, 0.4 + i * 0.35, 2.2, y0 - 0.12, 0.45 + i * 0.35, "Metal")
    m.box(x1 - 2.0, y0 - 0.02, 0.12, x1 - 0.4, y0 + 0.01, 3.0, "Metal")
    top = 7.72
    m.box(x0 - 0.2, y0 - 0.3, top, x1 + 0.2, y1 + 0.2, top + 0.4, "Trim")
    flat_roof(m, x0, y0, x1, y1, top + 0.4, parapet=0.3)
    name_sign(m, "LUCKY PAWN", (0.0, y0, 3.65), (1, 0, 0), 0.5, max_w=8)
    # three gold balls on a bracket
    m.box(x1 - 0.1, y0 - 1.4, 5.6, x1 + 0.0, y0, 5.7, "Metal")
    for (dx, dz) in ((-0.35, 0.0), (0.35, 0.0), (0.0, -0.6)):
        smooth_blob(m, x1 - 0.05 + 0.0, y0 - 1.2 + dx, 5.2 + dz, 0.28, "Sign", rng, subdiv=1, jitter=0.0)
    m.box(x0 + 0.3, -5.8, 0.12, x0 + 1.0, -5.1, 0.9, "Roof")  # trash can
    return m.build(name)


@special("diner", "Starlite Diner", 1, 1, ["shop", "food", "robbable"], interior="shop_diner",
         door=lot_door(-0.3, -2.9))
def diner(name):
    import build_extra as E
    m = copy_into(Mesh(), E.com_diner(name + "_tmp", 111))
    name_sign(m, "STARLITE", (4.6, -4.68, 7.55), (1, 0, 0), 0.62, plate=None, letters="Lamp", max_w=2.2)
    name_sign(m, "DINER", (-0.6, -2.6, 2.75), (1, 0, 0), 0.32, plate=None, letters="Lamp")
    return m.build(name)


@special("payphone", "Payphone", 0, 1, ["payphone", "mission_giver"], folder="props")
def payphone(name):
    m = Mesh()
    m.box(-0.08, -0.08, 0.0, 0.08, 0.08, 2.3, "Metal")
    m.box(-0.45, -0.35, 1.0, 0.45, 0.05, 2.25, "Metal")
    m.box(-0.5, -0.4, 2.25, 0.5, 0.1, 2.45, "Sign")
    m.box(-0.38, -0.36, 1.05, 0.38, -0.33, 2.2, "Accent")
    m.box(-0.18, -0.4, 1.3, 0.18, -0.36, 1.9, "Roof")      # phone body
    m.box(-0.25, -0.44, 1.75, -0.1, -0.38, 2.05, "Roof")   # handset
    m.box(-0.3, -0.42, 1.95, 0.3, -0.38, 2.15, "Lamp")      # lit header
    return m.build(name)


@special("armored_truck", "Armored Truck", 0, 2, ["vehicle", "spawned", "robbable"], folder="props")
def armored_truck(name):
    m = Mesh()
    m.box(-1.15, -2.9, 0.5, 1.15, 1.6, 2.9, "Concrete")
    m.box(-1.1, 1.6, 0.5, 1.1, 3.2, 2.2, "Concrete")
    m.box(-1.0, 3.15, 1.4, 1.0, 3.22, 2.1, "Glass")
    m.box(-1.17, 1.8, 1.5, 1.17, 2.9, 2.05, "Glass")
    m.box(-1.2, -2.6, 1.2, 1.2, 1.0, 1.5, "Awning")
    m.box(-0.9, -2.95, 0.7, 0.9, -2.9, 2.6, "Metal")
    for wy in (-1.9, 2.2):
        for s in (-1, 1):
            m.box(s * 1.05 - 0.15, wy - 0.5, 0.0, s * 1.05 + 0.15, wy + 0.5, 1.0, "Tire")
    m.box(-1.0, 3.2, 0.7, -0.6, 3.25, 0.95, "Headlight")
    m.box(0.6, 3.2, 0.7, 1.0, 3.25, 0.95, "Headlight")
    return m.build(name)


# ------------------------------------------------------------------ Tier 2 ---

@special("bank", "Second National Bank", 1, 2, ["bank", "robbable", "landmark"], interior="bank",
         door=lot_door(0.0, -4.2))
def bank(name):
    """Classical temple bank: podium steps, six columns, pediment, name on the frieze."""
    rng = random.Random(21)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.4, 5.4, -2.6, 5.6
    # podium and steps across the front
    m.box(x0 - 0.2, -4.6, 0.12, x1 + 0.2, y1 + 0.2, 1.2, "Trim")
    for i in range(4):
        m.box(x0 + 0.4, -5.8 + i * 0.3, 0.12, x1 - 0.4, -4.6, 0.12 + 0.27 * (i + 1), "Trim")
    # cella with tall arched-ish windows on the sides
    block_with_windows(m, x0, y0, x1, y1, 1.2, 1, 7.8, "Concrete", win_w=1.3, win_h=4.6, sill=1.6, pitch=2.7,
                       mullion=True, all_skip=lambda nm, f, c, cs: nm == "S")
    # front wall with bronze doors
    m.box(x0, y0 - 0.02, 1.2, x1, y0 + 0.3, 9.0, "Concrete")
    m.box(-1.5, y0 - 0.12, 1.2, 1.5, y0 + 0.0, 5.4, "Trim")
    m.box(-1.2, y0 - 0.16, 1.2, 1.2, y0 - 0.1, 4.8, "Metal")
    m.box(-0.03, y0 - 0.18, 1.2, 0.03, y0 - 0.15, 4.8, "Roof")
    for sx in (-3.6, 3.6):
        m.box(sx - 0.8, y0 - 0.06, 3.0, sx + 0.8, y0 + 0.0, 6.8, "Glass")
    # portico columns
    for i in range(6):
        x = x0 + 0.8 + i * (x1 - x0 - 1.6) / 5
        column(m, x, -3.8, 1.2, 9.0, r=0.42, mat="Trim", seg=12)
    # entablature with name, cornice, pediment
    m.box(x0 - 0.3, -4.6, 9.0, x1 + 0.3, y1 + 0.2, 10.4, "Trim")
    m.box(x0 - 0.5, -4.8, 10.4, x1 + 0.5, y1 + 0.4, 10.8, "Trim")
    text_mesh(m, "SECOND NATIONAL BANK", (0.0, -4.66 - 0.06, 9.3), (1, 0, 0), 0.62, "Metal", depth=0.03, max_w=10)
    # pediment: triangle on the front, roof slopes running back
    zt, zp = 10.8, 13.2
    m.face([(x0 - 0.5, -4.8, zt), (x1 + 0.5, -4.8, zt), (0.0, -4.8, zp)], "Trim", (0, -1, 0))
    m.face([(x0 - 0.5, y1 + 0.4, zt), (x1 + 0.5, y1 + 0.4, zt), (0.0, y1 + 0.4, zp)], "Trim", (0, 1, 0))
    m.face([(x0 - 0.6, -4.9, zt - 0.05), (0.0, -4.9, zp + 0.1), (0.0, y1 + 0.5, zp + 0.1), (x0 - 0.6, y1 + 0.5, zt - 0.05)],
           "Roof", (-1, 0, 1))
    m.face([(x1 + 0.6, -4.9, zt - 0.05), (0.0, -4.9, zp + 0.1), (0.0, y1 + 0.5, zp + 0.1), (x1 + 0.6, y1 + 0.5, zt - 0.05)],
           "Roof", (1, 0, 1))
    m.obox((-0.55, -4.86, 11.3), (1.1, 0, 0), (0, 0.06, 0), (0, 0, 1.1), "Sign")  # clock/medallion
    # lamps either side of the steps, planters, ATM
    for sx in (-5.0, 5.0):
        m.cyl(sx, -5.4, 0.12, 3.4, 0.1, "Roof", seg=8)
        smooth_blob(m, sx, -5.4, 3.6, 0.28, "Lamp", rng, subdiv=1, jitter=0)
    m.box(x1 - 0.2, -2.0, 1.2, x1 + 0.3, -1.0, 3.2, "Metal")
    m.box(x1 + 0.3, -1.85, 2.2, x1 + 0.32, -1.15, 2.9, "Glass")
    return m.build(name)


@special("nightclub", "Club Voltage", 1, 2, ["nightlife", "club", "gang"], interior="nightclub",
         door=lot_door(0.0, -3.4))
def nightclub(name):
    rng = random.Random(22)
    m = Mesh()
    lot(m, 6, "Asphalt")
    x0, x1, y0, y1 = -5.4, 5.4, -3.2, 5.6
    m.box(x0, y0, 0.12, x1, y1, 7.2, "Roof", top="Roof")
    # neon stripes wrapping the box
    for z in (2.0, 4.0, 6.0):
        m.box(x0 - 0.05, y0 - 0.05, z, x1 + 0.05, y1 + 0.05, z + 0.12, "Sign")
    # entrance: canopy, rope posts, doors
    m.box(-1.6, y0 - 0.06, 0.12, 1.6, y0 + 0.0, 3.0, "Trim")
    m.box(-1.2, y0 - 0.1, 0.12, 1.2, y0 - 0.05, 2.7, "Awning")
    m.box(-2.6, y0 - 3.0, 3.3, 2.6, y0, 3.55, "Roof")
    for x in (-2.4, 2.4):
        m.cyl(x, y0 - 2.8, 0.12, 3.3, 0.06, "Metal", seg=6)
    for x in (-2.0, -1.0, 1.0, 2.0):
        m.cyl(x, y0 - 2.2, 0.12, 1.0, 0.05, "Metal", seg=6)
        smooth_blob(m, x, y0 - 2.2, 1.05, 0.08, "Metal", rng, subdiv=1, jitter=0)
    for x in (-2.0, 1.0):
        m.obox((x, y0 - 2.22, 0.85), (1.0, 0, 0), (0, 0.04, 0), (0, 0, 0.06), "Awning")
    m.box(-2.6, y0 - 3.0, 0.12, 2.6, y0, 0.14, "Awning")  # red carpet
    # vertical blade sign
    m.box(x1 - 1.6, y0 - 1.0, 3.0, x1 - 1.2, y0, 7.0, "Roof")
    name_sign(m, "VOLTAGE", (0.0, y0 - 0.02, 4.6), (1, 0, 0), 1.1, plate=None, letters="Lamp", max_w=8)
    name_sign(m, "CLUB", (0.0, y0 - 0.02, 3.65), (1, 0, 0), 0.4, plate=None, letters="Sign")
    # searchlights and roof units
    for x in (-3.5, 3.5):
        m.cyl(x, 3.0, 7.2, 7.8, 0.5, "Metal", seg=10)
        m.obox((x - 0.35, 2.9, 7.8), (0.7, 0, 0), (0, 0.5, 0), (0, 0.4, 1.0), "Lamp")
    roof_clutter(m, rng, x0, 0, x1, y1, 7.2, n=2)
    # alley side door + dumpster (east)
    m.box(x1 - 0.01, 2.0, 0.12, x1 + 0.08, 3.2, 2.4, "Metal")
    m.box(x1 + 0.1, 3.6, 0.12, x1 + 0.6, 5.4, 1.3, "Leaves")
    return m.build(name)


@special("chop_shop", "Eddie's Auto Body", 1, 2, ["garage", "chop_shop", "gang"], door=lot_door(-2.6, -2.0))
def chop_shop(name):
    rng = random.Random(23)
    m = Mesh()
    lot(m, 6, "Asphalt")
    x0, x1, y0, y1 = -5.6, 5.6, -2.0, 5.6
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, 5.2, "Brick", pitch=3.0, win_h=1.0, sill=3.6,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    for bx, up in ((-2.6, 0.55), (2.6, 1.0)):
        m.box(bx - 1.9, y0 - 0.06, 0.12, bx + 1.9, y0 + 0.01, 4.0, "Roof")   # dark bay inside
        top = 0.12 + 3.9 * up
        m.box(bx - 1.9, y0 - 0.1, top, bx + 1.9, y0 - 0.07, 4.0, "Metal")
        for i in range(int((4.0 - top) / 0.4)):
            z = top + 0.2 + i * 0.4
            m.box(bx - 1.9, y0 - 0.12, z, bx + 1.9, y0 - 0.1, z + 0.05, "Trim")
        m.box(bx - 2.1, y0 - 0.2, 4.0, bx + 2.1, y0 + 0.02, 4.3, "Trim")
    flat_roof(m, x0, y0, x1, y1, 5.32, parapet=0.4, rim="Brick")
    name_sign(m, "EDDIE'S AUTO BODY", (0.0, y0, 4.45), (1, 0, 0), 0.5, max_w=9.5)
    # a car on jacks inside the open bay, tyres stacked, an engine hoist
    m.box(-4.0, y0 + 0.4, 0.8, -1.2, y0 + 2.6, 1.6, "Awning")
    for k in range(3):
        m.cyl(4.8, -4.6, 0.12 + k * 0.3, 0.4 + k * 0.3, 0.45, "Tire", seg=10)
        m.cyl(4.0, -5.2, 0.12 + k * 0.3, 0.4 + k * 0.3, 0.45, "Tire", seg=10)
    m.box(-5.4, -5.6, 0.12, -3.0, -4.6, 1.4, "Metal")
    fence(m, 5.8, -1.0, 5.8, 5.8, h=2.4, mat="Metal", post=2.0)
    return m.build(name)


@special("plaza", "Civic Plaza", 1, 2, ["park", "meeting_point"])
def plaza(name):
    rng = random.Random(24)
    m = Mesh()
    lot(m, 6, "Paving")
    for i in range(-5, 6, 2):
        m.box(i - 0.04, -5.9, 0.12, i + 0.04, 5.9, 0.125, "Concrete")
        m.box(-5.9, i - 0.04, 0.12, 5.9, i + 0.04, 0.125, "Concrete")
    # statue on a plinth
    m.box(-1.2, -1.2, 0.12, 1.2, 1.2, 0.6, "Trim")
    m.box(-0.8, -0.8, 0.6, 0.8, 0.8, 2.6, "Concrete")
    name_sign(m, "FOUNDER", (0.0, -0.8, 1.2), (1, 0, 0), 0.22, plate=None, letters="Metal")
    m.box(-0.3, -0.25, 2.6, 0.3, 0.25, 3.6, "Metal")
    m.box(-0.38, -0.3, 3.6, 0.38, 0.3, 4.6, "Metal")
    smooth_blob(m, 0, 0, 4.95, 0.3, "Metal", rng, subdiv=1, jitter=0)
    m.obox((0.3, -0.1, 4.3), (0.9, 0, 0.7), (0, 0.2, 0), (0, 0, 0.2), "Metal")
    # tree squares and benches round the edge
    for (x, y) in ((-4.0, -4.0), (4.0, -4.0), (-4.0, 4.0), (4.0, 4.0)):
        m.box(x - 1.0, y - 1.0, 0.12, x + 1.0, y + 1.0, 0.5, "Concrete")
        m.box(x - 0.9, y - 0.9, 0.5, x + 0.9, y + 0.9, 0.51, "Grass")
        m.cyl(x, y, 0.5, 2.2, 0.15, "Bark", seg=6)
        smooth_blob(m, x, y, 3.4, 1.4, "Leaves", rng, sq=0.9, subdiv=2)
    for (x, y, rot) in ((0, -3.6, 0), (0, 3.6, 0), (-3.6, 0, 1), (3.6, 0, 1)):
        if rot:
            m.box(x - 0.25, y - 0.9, 0.12, x + 0.25, y + 0.9, 0.5, "Door")
        else:
            m.box(x - 0.9, y - 0.25, 0.12, x + 0.9, y + 0.25, 0.5, "Door")
    for (x, y) in ((-5.5, 0.0), (5.5, 0.0)):
        m.cyl(x, y, 0.12, 4.2, 0.08, "Roof", seg=6)
        smooth_blob(m, x, y, 4.4, 0.25, "Lamp", rng, subdiv=1, jitter=0)
    return m.build(name)


@special("warehouse", "Pier 4 Warehouse", 1, 2, ["warehouse", "storage", "hideout", "industry"],
         door=lot_door(3.6, -2.6))
def warehouse(name):
    """Old brick dockside warehouse: painted name, loading dock, crates, a forklift."""
    rng = random.Random(25)
    m = Mesh()
    lot(m, 6, "Asphalt")
    x0, x1, y0, y1 = -5.6, 5.6, -2.6, 5.6
    block_with_windows(m, x0, y0, x1, y1, 0.12, 2, 3.8, "Brick", win_w=1.4, win_h=1.6, sill=1.4, pitch=2.6,
                       mullion=True, lintel="Trim", front_skip=lambda f, c: f == 0)
    gable_roof(m, x0, y0, x1, y1, 7.72, 1.8, mat="Metal", gable="Brick", over=0.3, along_x=True)
    # big sliding door + side door, dock platform with bumpers
    m.box(-4.2, y0 - 0.08, 0.12, -0.2, y0 + 0.01, 4.2, "Door")
    for i in range(7):
        x = -4.0 + i * 0.6
        m.box(x, y0 - 0.12, 0.12, x + 0.08, y0 - 0.08, 4.2, "Trim")
    m.box(-4.4, y0 - 0.25, 4.2, 0.0, y0 + 0.01, 4.45, "Metal")
    door_box(m, 3.6, y0, 0.12, 1.1, 2.3)
    m.box(-5.0, y0 - 1.6, 0.12, 1.0, y0, 1.1, "Concrete")
    for x in (-4.6, -0.4):
        m.box(x - 0.15, y0 - 1.7, 0.4, x + 0.15, y0 - 1.6, 0.9, "Tire")
    name_sign(m, "PIER 4", (-2.2, y0 - 0.02, 5.4), (1, 0, 0), 0.9, plate=None, letters="Trim", max_w=5)
    name_sign(m, "WAREHOUSE", (2.6, y0 - 0.02, 5.6), (1, 0, 0), 0.4, plate=None, letters="Trim", max_w=4)
    # crates, pallets and a forklift in the yard
    for (x, y, s) in ((2.0, -5.0, 1.0), (3.2, -5.0, 1.0), (2.6, -5.0, 0.0)):
        if s:
            m.box(x - 0.55, y - 0.55, 0.12, x + 0.55, y + 0.55, 1.2, "Door")
    m.box(2.05, -5.55, 1.2, 3.15, -4.45, 2.2, "Door")
    m.box(4.0, -5.6, 0.12, 5.4, -4.2, 0.3, "Door")
    m.box(-5.2, -5.4, 0.12, -3.6, -4.2, 1.4, "Sign")
    m.box(-5.0, -5.38, 1.4, -4.0, -4.6, 2.4, "Glass")
    m.box(-3.5, -5.3, 0.12, -3.3, -5.1, 2.6, "Metal")
    m.box(-3.5, -4.5, 0.12, -3.3, -4.3, 2.6, "Metal")
    m.box(-3.3, -5.3, 0.15, -2.4, -5.15, 0.22, "Metal")
    m.box(-3.3, -4.45, 0.15, -2.4, -4.3, 0.22, "Metal")
    for (x, y) in ((-4.8, -5.4), (-4.0, -5.4), (-4.8, -4.2), (-4.0, -4.2)):
        m.box(x - 0.2, y - 0.1, 0.12, x + 0.2, y + 0.1, 0.5, "Tire")
    roof_clutter(m, rng, x0, y0, x1, y1, 7.72, n=0)
    return m.build(name)


# ------------------------------------------------------------------ Tier 3 ---

@special("bunker", "The Bunker", 1, 3, ["hideout", "bunker", "safehouse"], interior="bunker",
         door=lot_door(-2.4, -2.9))
def bunker(name):
    """Half-buried concrete blockhouse in an earth berm, with a ramp down to a garage door."""
    rng = random.Random(31)
    m = Mesh()
    lot(m, 6, "Grass")
    # earth berm: sloped grass faces around a flat-topped mound
    b0, b1, h = 5.9, 3.6, 3.0
    pts0 = [(-b0, -b0 + 2.2), (b0, -b0 + 2.2), (b0, b0), (-b0, b0)]
    pts1 = [(-b1, -b1 + 2.6), (b1, -b1 + 2.6), (b1, b1 - 0.6), (-b1, b1 - 0.6)]
    for i in range(4):
        a0, a1 = pts0[i], pts0[(i + 1) % 4]
        c0, c1 = pts1[i], pts1[(i + 1) % 4]
        m.face([(a0[0], a0[1], 0.12), (a1[0], a1[1], 0.12), (c1[0], c1[1], h), (c0[0], c0[1], h)], "Grass")
    m.face([(x, y, h) for x, y in pts1], "Grass", UP)
    # blockhouse face poking out the front of the berm
    fx0, fx1, fy = -4.6, 4.6, -3.7
    m.box(fx0, fy, 0.12, fx1, -1.0, 3.4, "Concrete")
    m.box(fx0 - 0.3, fy - 0.4, 3.4, fx1 + 0.3, -1.0, 3.9, "Concrete")       # heavy lintel slab
    for x in (fx0 + 0.2, fx1 - 0.6):
        m.box(x, fy - 0.3, 0.12, x + 0.4, fy, 3.4, "Concrete")              # buttresses
    # blast door (personnel) on the left
    m.box(-3.1, fy - 0.1, 0.12, -1.7, fy + 0.0, 2.5, "Metal")
    m.obox((-2.75, fy - 0.16, 1.05), (0.7, 0, 0), (0, 0.06, 0), (0, 0, 0.1), "Roof")   # wheel bar
    m.obox((-2.45, fy - 0.16, 0.75), (0.1, 0, 0), (0, 0.06, 0), (0, 0, 0.7), "Roof")
    for z in (0.5, 2.0):
        m.box(-3.2, fy - 0.14, z, -3.05, fy - 0.08, z + 0.25, "Roof")         # hinges
    # vehicle ramp down to a roll door on the right
    m.box(0.0, -5.9, 0.0, 4.2, fy, 0.08, "Concrete")
    m.face([(0.2, -5.9, 0.1), (4.0, -5.9, 0.1), (4.0, fy, -0.8), (0.2, fy, -0.8)], "Asphalt", (0, -0.2, 1))
    m.box(-0.2, -5.9, -0.9, 0.2, fy, 0.6, "Concrete")
    m.box(4.0, -5.9, -0.9, 4.4, fy, 0.6, "Concrete")
    m.box(0.3, fy - 0.08, -0.8, 3.9, fy + 0.0, 2.6, "Metal")
    for i in range(8):
        m.box(0.3, fy - 0.1, -0.6 + i * 0.4, 3.9, fy - 0.08, -0.55 + i * 0.4, "Roof")
    for x in (0.4, 3.8):  # hazard stripes on the ramp walls
        m.box(x - 0.05, -5.9, 0.6, x + 0.05, fy, 0.75, "MarkingYellow")
    # stencil sign, a periscope vent, antenna, camo net over the mound
    name_sign(m, "THE BUNKER", (-2.4, fy - 0.01, 2.75), (1, 0, 0), 0.28, plate="Concrete", letters="MarkingYellow",
              pad=0.1, plate_depth=0.04)
    m.cyl(2.0, 1.5, h, h + 1.4, 0.3, "Metal", seg=8)
    m.box(1.7, 1.2, h + 1.4, 2.3, 1.8, h + 1.7, "Metal")
    m.cyl(-2.5, 2.0, h, h + 6.0, 0.05, "Metal", seg=4)
    for k in range(4):
        smooth_blob(m, rng.uniform(-3, 3), rng.uniform(-0.5, 2.5), h, rng.uniform(0.8, 1.3), "Leaves", rng,
                    sq=0.35, subdiv=1, jitter=0.2)
    fence(m, -5.8, -5.8, -0.4, -5.8, h=2.0, mat="Metal", post=1.8)
    for x in (-5.4, 5.4):
        m.box(x - 0.2, -5.8, 0.12, x + 0.2, -5.4, 2.6, "Concrete")
        m.box(x - 0.25, -5.85, 2.2, x + 0.25, -5.75, 2.5, "Lamp")
    return m.build(name)


@special("police_hq", "Police Headquarters", 2, 3, ["police", "service", "police_hq"], interior="police",
         door=lot_door(0.0, -8.6))
def police_hq(name):
    rng = random.Random(32)
    m = Mesh()
    lot(m, 12, "Paving")
    # wide podium with a glass lobby and a tower block above
    block_with_windows(m, -11, -8.0, 11, 10, 0.12, 2, 4.2, "Concrete", win_w=2.2, win_h=2.0, pitch=3.0,
                       front_skip=lambda f, c: f == 0 and c in (3, 4))
    m.box(-3.8, -8.06, 0.12, 3.8, -7.98, 3.8, "Glass")
    m.box(-5.0, -11.0, 3.9, 5.0, -8.0, 4.4, "Trim")
    for x in (-4.6, 4.6):
        m.box(x - 0.2, -10.8, 0.12, x + 0.2, -10.4, 3.9, "Trim")
    m.box(-11.2, -8.2, 8.52, 11.2, 10.2, 9.0, "Accent")
    flat_roof(m, -11, -8.0, 11, 10, 9.0, parapet=0.4)
    pts = [(-7.5, -4.0), (7.5, -4.0), (7.5, 6.0), (-7.5, 6.0)]
    ribbon_floors(m, pts, 9.0, 7, 3.4, "Concrete", band=0.45, pilaster="Accent", pil_pitch=2.5, pil_w=0.5)
    top = 9.0 + 7 * 3.4
    poly_cap(m, pts, top, "Roof", rim="Trim", rim_h=0.6)
    name_sign(m, "POLICE HEADQUARTERS", (0.0, -4.0, top - 2.6), (1, 0, 0), 1.0, plate=None, letters="Lamp",
              max_w=14)
    name_sign(m, "POLICE", (0.0, -11.02, 4.45), (1, 0, 0), 0.45, plate=None, letters="Lamp")
    # helipad, antenna mast, sally port with cruisers bay
    m.cyl(-2.0, 1.0, top + 0.6, top + 0.9, 3.8, "Asphalt", seg=20)
    m.cyl(-2.0, 1.0, top + 0.9, top + 0.92, 3.3, "Marking", seg=20)
    m.cyl(-2.0, 1.0, top + 0.92, top + 0.94, 3.0, "Asphalt", seg=20)
    for (a, b, c, d) in ((-3.3, -0.4, -2.8, 2.4), (-1.2, -0.4, -0.7, 2.4), (-2.8, 0.75, -1.2, 1.25)):
        m.box(a, b, top + 0.94, c, d, top + 0.96, "Marking")
    lattice_mast(m, 5.5, 3.0, top + 0.6, top + 12.0, 1.4, 0.4, rungs=5, t=0.1)
    m.box(7.0, -11.8, 0.12, 11.8, -8.0, 0.14, "Asphalt")
    m.box(7.2, -8.06, 0.12, 10.8, -7.98, 3.6, "Metal")
    for x in (2.0, 4.6):
        m.box(x - 0.1, -11.8, 0.12, x + 0.1, -11.6, 6.0, "Metal")
        m.box(x - 0.05, -11.74, 4.6, x + 1.4, -11.68, 6.0, "Accent")  # flags
    trees_row(m, rng, [(-10.0, -10.5), (-7.0, -10.5)], r=1.0)
    return m.build(name)


@special("gas_plant", "Gas Power Plant", 1, 3, ["power", "industry"])
def gas_plant(name):
    m = Mesh()
    lot(m, 6, "Concrete")
    m.box(-5.6, -5.6, 0.12, 0.8, 0.0, 6.5, "Metal", top="Roof")
    block_with_windows(m, -5.6, -5.6, 0.8, 0.0, 3.5, 1, 2.6, "Metal", win_h=1.0, sill=0.8, pitch=2.0)
    m.box(-5.65, -5.65, 5.8, 0.85, 0.05, 6.6, "Accent")
    name_sign(m, "CITY POWER", (-2.4, -5.65, 4.6), (1, 0, 0), 0.5, max_w=5)
    # two gas spheres on legs
    for (x, y) in ((3.4, 2.6), (3.4, -2.2)):
        for (lx, ly) in ((-1.4, -1.4), (1.4, -1.4), (1.4, 1.4), (-1.4, 1.4)):
            m.cyl(x + lx, y + ly, 0.12, 3.0, 0.12, "Metal", seg=6)
        smooth_blob(m, x, y, 4.2, 2.2, "Trim", random.Random(5), subdiv=2, jitter=0.0)
    # exhaust stacks + HRSG blocks
    for x in (-4.4, -1.6):
        m.box(x - 1.0, 0.6, 0.12, x + 1.0, 5.4, 9.0, "Metal")
        m.cyl(x, 4.4, 9.0, 18.0, 0.7, "Metal", seg=10)
        m.cyl(x, 4.4, 16.5, 17.0, 0.75, "Awning", seg=10)
    fence(m, -5.8, -5.8, 5.8, -5.8, h=2.2, mat="Metal", post=2.0, gap=(0.65, 0.8))
    return m.build(name)


@special("recycling_center", "Recycling Center", 1, 3, ["sanitation"])
def recycling_center(name):
    rng = random.Random(33)
    m = Mesh()
    lot(m, 6, "Concrete")
    block_with_windows(m, -5.6, 0.4, 2.4, 5.6, 0.12, 1, 6.0, "Metal", win_h=1.0, sill=4.4, pitch=2.6,
                       all_skip=lambda nm, f, c, cs: nm == "S" and c == 1)
    m.box(-3.0, 0.32, 0.12, 0.0, 0.41, 4.4, "Roof")
    gable_roof(m, -5.6, 0.4, 2.4, 5.6, 6.12, 1.1, mat="Metal", gable="Metal", over=0.25, along_x=True)
    name_sign(m, "RECYCLING", (-1.6, 0.36, 4.7), (1, 0, 0), 0.55, plate="Leaves", letters="Trim", max_w=6.5)
    # conveyor up into the shed, sorted bales and roll-off bins
    m.obox((4.6, -1.0, 0.8), (-2.2, 1.4, 4.2), (0.9, 0.0, 0.0), (0, 0, 0.35), "Metal")
    for i, mat in enumerate(("Leaves", "Accent", "Awning", "Sign")):
        x = -5.2 + i * 2.4
        m.box(x, -5.6, 0.12, x + 2.0, -3.4, 1.6, mat)
        m.box(x - 0.05, -5.65, 1.4, x + 2.05, -3.35, 1.65, "Roof")
    for k in range(6):
        x, y = 3.4 + (k % 2) * 1.2, -0.6 + (k // 2) * 1.2
        m.box(x, y, 0.12 + 0.0, x + 1.0, y + 1.0, 1.0, rng.choice(["Paving", "Leaves", "Accent", "Metal"]))
    return m.build(name)


@special("sports_field", "Municipal Sports Field", 2, 3, ["park", "sports", "meeting_point"])
def sports_field(name):
    m = Mesh()
    lot(m, 12, "Paving")
    m.box(-10.5, -7.5, 0.12, 10.5, 7.5, 0.16, "Grass")
    mk = lambda a, b, c, d: m.box(a, b, 0.16, c, d, 0.17, "Marking")
    mk(-10, -7.1, 10, -6.95); mk(-10, 6.95, 10, 7.1); mk(-10, -7.1, -9.85, 7.1); mk(9.85, -7.1, 10, 7.1)
    mk(-0.08, -7.1, 0.08, 7.1)
    m.cyl(0, 0, 0.16, 0.17, 2.4, "Marking", seg=24)
    m.cyl(0, 0, 0.17, 0.175, 2.25, "Grass", seg=24)
    for s in (-1, 1):
        x_in = s * 7.6
        mk(min(s * 10, x_in), -3.2, max(s * 10, x_in), -3.05)
        mk(min(s * 10, x_in), 3.05, max(s * 10, x_in), 3.2)
        mk(x_in - 0.08, -3.2, x_in + 0.08, 3.2)
        # goals
        gx = s * 10.3
        m.box(gx - 0.08, -1.8, 0.16, gx + 0.08, -1.66, 2.3, "Trim")
        m.box(gx - 0.08, 1.66, 0.16, gx + 0.08, 1.8, 2.3, "Trim")
        m.box(gx - 0.08, -1.8, 2.2, gx + 0.08, 1.8, 2.34, "Trim")
    # bleachers on the north side
    for i in range(5):
        m.box(-8.0, 8.0 + i * 0.7, 0.12, 8.0, 11.6, 0.6 + i * 0.5, "Concrete" if i % 2 else "Accent")
    m.box(-8.2, 11.4, 0.12, 8.2, 11.8, 4.8, "Concrete")
    m.box(-8.4, 7.6, 4.8, 8.4, 11.9, 5.1, "Roof")
    name_sign(m, "MUNICIPAL FIELD", (0.0, 7.62, 5.15), (1, 0, 0), 0.7, plate="Sign", letters="Trim", max_w=9)
    # floodlight masts at the corners
    for (x, y) in ((-11.3, -8.3), (11.3, -8.3), (-11.3, 8.3), (11.3, 8.3)):
        m.cyl(x, y, 0.12, 14.0, 0.18, "Metal", seg=8, r_top=0.12)
        m.box(x - 1.0, y - 0.3, 13.6, x + 1.0, y + 0.3, 15.0, "Metal")
        m.box(x - 0.9, y - 0.32 if y > 0 else y + 0.3, 13.7, x + 0.9, y - 0.3 if y > 0 else y + 0.32, 14.9, "Lamp")
    return m.build(name)


@special("hospital", "General Hospital", 2, 3, ["hospital", "service"], folder="civic")
def hospital(name):
    import build_extra as E
    m = copy_into(Mesh(), E.civic_hospital(name + "_tmp", 133))
    name_sign(m, "GENERAL HOSPITAL", (0.0, -8.0, 5.0), (1, 0, 0), 0.7, plate="Trim", letters="Lamp", max_w=10)
    name_sign(m, "EMERGENCY", (-7.25, -11.62, 3.62), (1, 0, 0), 0.24, plate=None, letters="Lamp", max_w=5)
    return m.build(name)


# ------------------------------------------------------------------ Tier 4 ---

@special("casino", "The Golden Ace Casino", 2, 4, ["casino", "robbable", "nightlife", "landmark"],
         door=lot_door(0.0, -7.6))
def casino(name):
    rng = random.Random(41)
    m = Mesh()
    lot(m, 12, "Paving")
    # low gaming hall with a curved-ish faceted front, hotel tower behind
    hall = [(-11, -7.0), (-6.5, -9.0), (6.5, -9.0), (11, -7.0), (11, 4.0), (-11, 4.0)]
    ribbon_floors(m, hall, 0.12, 2, 4.0, "Sign", glass="Glass", band=0.55, depth=0.25, pilaster="Trim",
                  pil_pitch=2.0, pil_w=0.3)
    m.face([(x, y, 8.12) for x, y in hall], "Roof", UP)
    for o_u in zip(hall, hall[1:] + hall[:1]):
        (ax, ay), (bx, by) = o_u
    # marquee canopy studded with lamps
    m.box(-6.0, -12.0, 4.0, 6.0, -9.0, 4.6, "Trim")
    for i in range(12):
        x = -5.6 + i * 1.02
        m.box(x - 0.15, -12.05, 4.05, x + 0.15, -12.0, 4.55, "Lamp")
    for x in (-5.6, 5.6):
        column(m, x, -11.5, 0.12, 4.0, r=0.3, mat="Sign")
    # hotel tower with gold glass
    pts = octagon(5.5, 1.8)
    pts = [(x, y + 7.0) for x, y in pts]
    ribbon_floors(m, pts, 8.12, 14, 3.2, "Sign", band=0.7, depth=0.15, pilaster="Trim", pil_pitch=1.6, pil_w=0.2)
    top = 8.12 + 14 * 3.2
    poly_cap(m, pts, top, "Roof", rim="Lamp", rim_h=0.8)
    # giant rooftop sign on the hall and a spade on the tower
    m.box(-7.0, -6.4, 8.12, -6.6, -6.0, 13.0, "Metal")
    m.box(6.6, -6.4, 8.12, 7.0, -6.0, 13.0, "Metal")
    name_sign(m, "GOLDEN ACE", (0.0, -6.6, 10.0), (1, 0, 0), 2.0, plate="Sign", letters="Lamp", max_w=13, pad=0.4)
    name_sign(m, "CASINO", (0.0, -9.02, 5.2), (1, 0, 0), 1.2, plate=None, letters="Lamp", max_w=9)
    smooth_blob(m, 0.0, 1.5, top + 2.2, 1.8, "Lamp", rng, subdiv=2, jitter=0.0)
    m.cyl(0.0, 1.5, top, top + 1.0, 0.4, "Metal", seg=8)
    # fountain and palms out front
    m.cyl(-9.0, -10.4, 0.12, 0.6, 1.6, "Trim", seg=16)
    m.cyl(-9.0, -10.4, 0.55, 0.6, 1.4, "Water", seg=16)
    m.cyl(-9.0, -10.4, 0.6, 2.4, 0.1, "Water", seg=6, r_top=0.02)
    for x in (8.0, 10.5):
        for i in range(5):
            m.cyl(x, -10.6, 0.12 + i * 1.2, 1.32 + i * 1.2, 0.2, "Bark", seg=6, r_top=0.18, cap=False)
        for k in range(6):
            a = k * math.tau / 6
            d = Vector((math.cos(a), math.sin(a), 0))
            p = Vector((x, -10.6, 6.1))
            side = Vector((-d.y, d.x, 0)) * 0.4
            m.face([p - side * 0.3, p + d * 1.8 - side + UP * 0.3, p + d * 3.0 - UP * 0.9,
                    p + d * 1.8 + side + UP * 0.3, p + side * 0.3], "Leaves", UP)
    return m.build(name)


@special("stadium", "City Stadium", 3, 4, ["stadium", "sports", "landmark", "meeting_point"])
def stadium(name):
    m = Mesh()
    lot(m, 18, "Paving")
    # oval bowl: rings of stepped seating around a pitch
    a, b = 11.0, 7.5
    m.box(-a + 1, -b + 1, 0.12, a - 1, b - 1, 0.16, "Grass")
    seg = 28
    rings = [(1.0, 0.12, 1.2, "Concrete"), (1.18, 1.2, 4.0, "Accent"), (1.36, 4.0, 7.0, "Concrete"),
             (1.52, 7.0, 10.5, "Accent")]
    prev = None
    for k, (s, z0, z1, mat) in enumerate(rings):
        pts = [(a * s * math.cos(2 * math.pi * i / seg), b * s * math.sin(2 * math.pi * i / seg)) for i in range(seg)]
        if prev:
            for i in range(seg):
                j = (i + 1) % seg
                p0, p1 = prev[i], prev[j]
                q0, q1 = pts[i], pts[j]
                m.face([(p0[0], p0[1], z0), (p1[0], p1[1], z0), (q1[0], q1[1], z1), (q0[0], q0[1], z1)], mat)
        prev = pts
    # outer wall with arches and a roof ring
    s = 1.6
    outer = [(a * s * math.cos(2 * math.pi * i / seg), b * s * math.sin(2 * math.pi * i / seg)) for i in range(seg)]
    for i in range(seg):
        j = (i + 1) % seg
        p0, p1 = outer[i], outer[j]
        m.face([(p0[0], p0[1], 0.12), (p1[0], p1[1], 0.12), (p1[0], p1[1], 12.0), (p0[0], p0[1], 12.0)], "Trim",
               (p0[0] + p1[0], p0[1] + p1[1], 0))
        q0, q1 = prev[i], prev[j]
        m.face([(q0[0], q0[1], 10.5), (q1[0], q1[1], 10.5), (p1[0], p1[1], 12.0), (p0[0], p0[1], 12.0)], "Concrete")
        mid = ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2)
        n = Vector((mid[0], mid[1], 0)).normalized()
        m.obox(Vector((mid[0], mid[1], 2.0)) + n * 0.05 - Vector((-n.y, n.x, 0)) * 0.6, Vector((-n.y, n.x, 0)) * 1.2,
               n * 0.05, UP * 4.0, "Glass")
        # cantilevered roof
        r0 = (prev[i][0] * 0.9, prev[i][1] * 0.9)
        r1 = (prev[j][0] * 0.9, prev[j][1] * 0.9)
        m.face([(p0[0], p0[1], 13.5), (p1[0], p1[1], 13.5), (r1[0], r1[1], 14.5), (r0[0], r0[1], 14.5)], "Roof")
        m.face([(p0[0], p0[1], 13.5), (p1[0], p1[1], 13.5), (p1[0], p1[1], 12.0), (p0[0], p0[1], 12.0)], "Metal",
               (p0[0] + p1[0], p0[1] + p1[1], 0))
    name_sign(m, "CITY STADIUM", (0.0, -b * 1.6 - 0.1, 8.0), (1, 0, 0), 1.6, plate="Sign", letters="Lamp",
              max_w=14)
    for (x, y) in ((-16, -11), (16, -11), (-16, 11), (16, 11)):
        m.cyl(x, y, 0.12, 24.0, 0.3, "Metal", seg=8, r_top=0.2)
        m.box(x - 1.6, y - 0.4, 23.0, x + 1.6, y + 0.4, 25.0, "Metal")
        m.box(x - 1.5, y - 0.42, 23.1, x + 1.5, y + 0.42, 24.9, "Lamp")
    return m.build(name)


@special("city_park", "Central Park", 2, 4, ["park", "landmark", "meeting_point"])
def city_park(name):
    rng = random.Random(43)
    m = Mesh()
    lot(m, 12, "Grass")
    # pond with an island, winding path ring, gazebo, many trees
    m.cyl(3.0, 2.0, 0.08, 0.13, 5.5, "Water", seg=24)
    m.cyl(4.5, 3.0, 0.08, 0.5, 1.2, "Grass", seg=12, r_top=0.9)
    seg = 24
    for i in range(seg):
        a0, a1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
        r0, r1 = 8.0, 9.4
        m.face([(r0 * math.cos(a0), r0 * math.sin(a0), 0.14), (r1 * math.cos(a0), r1 * math.sin(a0), 0.14),
                (r1 * math.cos(a1), r1 * math.sin(a1), 0.14), (r0 * math.cos(a1), r0 * math.sin(a1), 0.14)], "Paving", UP)
    m.box(-0.7, -12.0, 0.12, 0.7, -8.0, 0.14, "Paving")
    # gazebo
    gx, gy = -5.0, -3.0
    m.cyl(gx, gy, 0.12, 0.5, 2.4, "Trim", seg=8)
    for k in range(8):
        a = k * math.tau / 8
        m.cyl(gx + 2.1 * math.cos(a), gy + 2.1 * math.sin(a), 0.5, 3.2, 0.1, "Trim", seg=6)
    m.cyl(gx, gy, 3.2, 3.4, 2.6, "Trim", seg=8)
    m.cyl(gx, gy, 3.4, 4.8, 2.6, "Roof", seg=8, r_top=0.1)
    # trees
    for k in range(16):
        a = rng.uniform(0, math.tau)
        r = rng.uniform(9.8, 11.3)
        x, y = r * math.cos(a), r * math.sin(a)
        if abs(x) < 1.5 and y < 0:
            continue
        s = rng.uniform(0.8, 1.2)
        m.cyl(x, y, 0.12, 2.0 * s, 0.18, "Bark", seg=6, r_top=0.12)
        smooth_blob(m, x, y, 2.0 * s + 1.4 * s, 1.6 * s, "Leaves", rng, sq=0.9, subdiv=1)
    for (x, y) in ((-3.0, 5.0), (-6.0, 3.0), (0.0, -5.0)):
        m.cyl(x, y, 0.12, 2.0, 0.18, "Bark", seg=6, r_top=0.12)
        smooth_blob(m, x, y, 3.4, 1.7, "Leaves", rng, sq=0.9, subdiv=2)
    # entrance arch with the name
    for x in (-2.2, 2.2):
        m.box(x - 0.4, -11.9, 0.12, x + 0.4, -11.1, 4.2, "Brick")
    m.box(-2.6, -11.95, 4.2, 2.6, -11.05, 5.0, "Brick")
    name_sign(m, "CENTRAL PARK", (0.0, -11.96, 4.3), (1, 0, 0), 0.42, plate=None, letters="Trim", max_w=4.4)
    return m.build(name)


@special("solar_farm", "Solar Farm", 2, 4, ["power"])
def solar_farm(name):
    m = Mesh()
    lot(m, 12, "Grass")
    for row in range(6):
        y = -9.5 + row * 3.6
        for col in range(3):
            x0 = -10.5 + col * 7.2
            for x in (x0 + 0.5, x0 + 5.8):
                m.box(x - 0.06, y + 0.8, 0.12, x + 0.06, y + 0.92, 1.6, "Metal")
            m.face([(x0, y, 0.9), (x0 + 6.4, y, 0.9), (x0 + 6.4, y + 2.0, 1.9), (x0, y + 2.0, 1.9)], "Glass", (0, -0.5, 1))
            m.face([(x0, y, 0.85), (x0 + 6.4, y, 0.85), (x0 + 6.4, y + 2.0, 1.85), (x0, y + 2.0, 1.85)], "Metal", (0, 0.5, -1))
    m.box(9.0, -11.6, 0.12, 11.6, -9.0, 2.6, "Concrete", top="Roof")
    name_sign(m, "SOLAR", (10.3, -11.6, 1.5), (1, 0, 0), 0.4, max_w=2.2, pad=0.1)
    fence(m, -11.8, -11.8, 8.6, -11.8, h=2.0, mat="Metal", post=2.4)
    return m.build(name)


@special("wind_turbine", "Wind Turbine", 1, 4, ["power"])
def wind_turbine(name):
    """Tower and nacelle; the rotor is a separate model (wind_turbine_rotor) for spinning."""
    m = Mesh()
    lot(m, 6, "Grass")
    m.cyl(0, 0, 0.12, 0.6, 2.0, "Concrete", seg=12)
    m.cyl(0, 0, 0.6, 30.0, 1.0, "Trim", seg=12, r_top=0.55)
    m.box(-0.8, -1.4, 30.0, 0.8, 2.8, 31.6, "Trim")
    m.box(-3.0, -5.6, 0.12, 0.0, -3.4, 2.6, "Concrete", top="Roof")
    return m.build(name)


@special("wind_turbine_rotor", "Wind Turbine Rotor", 0, 4, ["power"], folder="props")
def wind_turbine_rotor(name):
    """Hub at the origin, spins around Blender -Y (Godot +Z). Mount 1.6 m in front of
    the nacelle, 30.8 m up: Godot local (0, 30.8, 1.6) on wind_turbine."""
    m = Mesh()
    rng = random.Random(9)
    smooth_blob(m, 0, -0.4, 0, 0.7, "Trim", rng, sq=1.0, subdiv=1, jitter=0)
    for k in range(3):
        a = k * math.tau / 3
        d = Vector((math.cos(a), 0, math.sin(a)))
        side = Vector((-d.z, 0, d.x))
        root, tip = d * 0.6, d * 14.0
        m.face([root - side * 0.5, tip - side * 0.15, tip + side * 0.05, root + side * 0.6], "Trim", (0, -1, 0))
        m.face([root - side * 0.5, tip - side * 0.15, tip + side * 0.05, root + side * 0.6], "Trim", (0, 1, 0))
    return m.build(name)


@special("airfield", "Municipal Airfield", 3, 4, ["airfield", "escape", "landmark"])
def airfield(name):
    m = Mesh()
    lot(m, 18, "Grass")
    m.box(-17.5, -4.0, 0.12, 17.5, 4.0, 0.16, "Asphalt")
    for i in range(10):
        x = -15.0 + i * 3.3
        m.box(x, -0.12, 0.16, x + 1.8, 0.12, 0.17, "Marking")
    for s in (-1, 1):
        for k in range(5):
            m.box(s * 16.8 - 0.2, -3.0 + k * 1.5, 0.16, s * 16.8 + 0.2, -2.4 + k * 1.5, 0.17, "Marking")
        for k in range(8):  # edge lights
            m.box(-16 + k * 4.5, s * 4.2 - 0.1, 0.12, -15.8 + k * 4.5, s * 4.2 + 0.1, 0.45, "Lamp")
    # taxiway, hangar with curved roof, control tower
    m.box(-4.0, 4.0, 0.12, 0.0, 9.0, 0.15, "Asphalt")
    hx0, hx1, hy0, hy1 = -10.0, 6.0, 9.0, 17.5
    m.box(hx0, hy0, 0.12, hx1, hy1, 6.0, "Metal")
    seg = 10
    for i in range(seg):
        a0, a1 = math.pi * i / seg, math.pi * (i + 1) / seg
        r = (hy1 - hy0) / 2
        yc = (hy0 + hy1) / 2
        m.face([(hx0, yc - r * math.cos(a0), 6.0 + 2.5 * math.sin(a0)), (hx1, yc - r * math.cos(a0), 6.0 + 2.5 * math.sin(a0)),
                (hx1, yc - r * math.cos(a1), 6.0 + 2.5 * math.sin(a1)), (hx0, yc - r * math.cos(a1), 6.0 + 2.5 * math.sin(a1))],
               "Metal", (0, -math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2)))
    for xx in (hx0, hx1):
        pts = [(xx, (hy0 + hy1) / 2 - (hy1 - hy0) / 2 * math.cos(math.pi * i / seg), 6.0 + 2.5 * math.sin(math.pi * i / seg))
               for i in range(seg + 1)]
        m.face(pts, "Metal", (1 if xx == hx1 else -1, 0, 0))
    m.box(-8.0, hy0 - 0.08, 0.12, 4.0, hy0, 5.6, "Roof")
    name_sign(m, "MAYORSTREET AIRFIELD", (-2.0, hy0 - 0.02, 6.2), (1, 0, 0), 0.7, max_w=13)
    m.box(10.0, 8.0, 0.12, 13.0, 11.0, 12.0, "Concrete")
    pts = octagon(2.6, 0.8)
    pts = [(x + 11.5, y + 9.5) for x, y in pts]
    ribbon_floors(m, pts, 12.0, 1, 3.0, "Trim", band=0.8, depth=0.1)
    poly_cap(m, pts, 15.0, "Roof", rim="Trim")
    m.cyl(11.5, 9.5, 15.0, 17.5, 0.06, "Metal", seg=4)
    # windsock
    m.cyl(14.0, -6.0, 0.12, 5.0, 0.06, "Metal", seg=6)
    m.obox((14.05, -6.2, 4.6), (1.6, 0, -0.2), (0, 0.4, 0), (0, 0, 0.4), "Awning")
    return m.build(name)


@special("radio_tower", "KMAY Radio Tower", 1, 4, ["radio", "landmark"])
def radio_tower(name):
    rng = random.Random(46)
    m = Mesh()
    lot(m, 6, "Grass")
    lattice_mast(m, 0, 1.0, 0.12, 48.0, 3.2, 0.8, rungs=14, t=0.14)
    for z in (16.0, 32.0, 48.0):
        smooth_blob(m, 0, 1.0, z + 0.3, 0.35, "Taillight", rng, subdiv=1, jitter=0)
    m.cyl(0, 1.0, 48.0, 54.0, 0.1, "Metal", seg=6)
    m.box(-5.0, -5.6, 0.12, 0.0, -2.4, 3.4, "Wall", top="Roof")
    door_box(m, -2.5, -5.6, 0.12, 1.0, 2.2)
    name_sign(m, "KMAY 101.5", (-2.5, -5.6, 2.6), (1, 0, 0), 0.32, max_w=4.4, pad=0.1)
    m.cyl(3.4, -3.6, 0.12, 2.2, 0.08, "Metal", seg=6)
    m.cyl(3.4, -3.6, 2.2, 2.5, 1.2, "Trim", seg=12, r_top=0.2)  # satellite dish (simplified)
    return m.build(name)


# ------------------------------------------------------------------ Tier 5 ---

@special("federal_reserve", "Federal Reserve", 2, 5, ["bank", "robbable", "landmark", "vault"], interior="bank",
         door=lot_door(0.0, -8.2))
def federal_reserve(name):
    rng = random.Random(51)
    m = Mesh()
    lot(m, 12, "Paving")
    x0, x1, y0, y1 = -10.5, 10.5, -6.0, 10.5
    m.box(x0 - 0.5, -9.0, 0.12, x1 + 0.5, y1 + 0.5, 1.6, "Trim")
    for i in range(5):
        m.box(-6.0, -11.5 + i * 0.5, 0.12, 6.0, -9.0, 0.12 + 0.3 * (i + 1), "Trim")
    # massive stone block, slit windows
    block_with_windows(m, x0, y0, x1, y1, 1.6, 3, 4.0, "Concrete", win_w=0.9, win_h=2.6, pitch=2.6,
                       front_skip=lambda f, c: f == 0 and c in (3, 4))
    top = 1.6 + 12.0
    for i in range(8):
        x = -7.0 + i * 2.0
        column(m, x, -7.6, 1.6, 12.0, r=0.5, mat="Trim", seg=12)
    m.box(-8.2, -9.0, 12.0, 8.2, y0, 13.6, "Trim")
    text_mesh(m, "FEDERAL RESERVE", (0.0, -9.08, 12.3), (1, 0, 0), 0.8, "Metal", depth=0.03, max_w=13)
    m.face([(-8.4, -9.1, 13.6), (8.4, -9.1, 13.6), (0, -9.1, 16.0)], "Trim", (0, -1, 0))
    m.face([(-8.6, -9.2, 13.55), (0, -9.2, 16.15), (0, y0, 16.15), (-8.6, y0, 13.55)], "Roof", (-1, 0, 1))
    m.face([(8.6, -9.2, 13.55), (0, -9.2, 16.15), (0, y0, 16.15), (8.6, y0, 13.55)], "Roof", (1, 0, 1))
    m.box(-2.0, y0 - 0.1, 1.6, 2.0, y0 + 0.0, 7.0, "Metal")
    m.box(x0 - 0.3, y0 - 0.3, top, x1 + 0.3, y1 + 0.3, top + 0.8, "Trim")
    flat_roof(m, x0, y0, x1, y1, top + 0.8, parapet=0.5)
    # flags and guard booths, bollards
    for x in (-11.0, 11.0):
        m.cyl(x, -11.0, 0.12, 9.0, 0.08, "Metal", seg=6)
        m.box(x + 0.05 if x < 0 else x - 1.6, -11.03, 7.6, x + 1.6 if x < 0 else x - 0.05, -10.97, 8.8, "Accent")
    for i in range(9):
        m.cyl(-8.0 + i * 2.0, -11.8, 0.12, 1.0, 0.2, "Concrete", seg=8)
    m.box(8.0, -11.6, 0.12, 10.0, -10.0, 2.8, "Concrete", top="Roof")
    m.box(8.0, -11.62, 1.2, 10.0, -11.58, 2.2, "Glass")
    return m.build(name)


@special("mansion", "Mansion on the Hill", 2, 5, ["home", "mansion", "luxury"], door=lot_door(0.0, -2.2))
def mansion(name):
    rng = random.Random(52)
    m = Mesh()
    lot(m, 12, "Grass")
    # terraced hill: two stepped grass plinths
    m.box(-11.5, -6.0, 0.12, 11.5, 11.5, 1.6, "Grass", sides="Concrete")
    m.box(-9.0, -3.0, 1.6, 9.0, 10.0, 2.6, "Paving", sides="Concrete")
    for i in range(6):  # grand stair
        m.box(-2.0, -11.0 + i * 0.85, 0.12, 2.0, -6.0, 0.12 + 0.25 * (i + 1), "Trim")
    m.box(-2.0, -6.0, 1.6, 2.0, -3.0, 2.6, "Trim")
    # main house, wings, columned porch
    block_with_windows(m, -5.5, -2.0, 5.5, 6.0, 2.6, 2, 3.6, "Wall", win_w=1.3, win_h=2.2, pitch=2.2, mullion=True,
                       lintel="Trim", front_skip=lambda f, c: f == 0 and c == 2)
    hip_roof(m, -5.5, -2.0, 5.5, 6.0, 9.8, 3.0, mat="RoofTile", over=0.5)
    m.box(-5.7, -2.2, 9.6, 5.7, 6.2, 9.8, "Trim")
    for sx in (-1, 1):
        wx0, wx1 = (-9.0, -5.5) if sx < 0 else (5.5, 9.0)
        block_with_windows(m, wx0, -1.0, wx1, 5.0, 2.6, 1, 3.6, "Wall", win_w=1.3, win_h=2.2, pitch=2.2,
                           mullion=True, lintel="Trim")
        hip_roof(m, wx0, -1.0, wx1, 5.0, 6.2, 1.8, mat="RoofTile", over=0.4)
    for x in (-2.2, -0.8, 0.8, 2.2):
        column(m, x, -3.2, 2.6, 9.4, r=0.3)
    m.box(-2.8, -3.8, 9.4, 2.8, -2.0, 9.9, "Trim")
    m.face([(-2.9, -3.85, 9.9), (2.9, -3.85, 9.9), (0, -3.85, 11.4)], "Trim", (0, -1, 0))
    m.face([(-3.0, -3.9, 9.85), (0, -3.9, 11.5), (0, -2.0, 11.5), (-3.0, -2.0, 9.85)], "RoofTile", (-1, 0, 1))
    m.face([(3.0, -3.9, 9.85), (0, -3.9, 11.5), (0, -2.0, 11.5), (3.0, -2.0, 9.85)], "RoofTile", (1, 0, 1))
    door_box(m, 0.0, -2.0, 2.6, 1.6, 3.0)
    for cx in (-3.5, 3.5):
        m.box(cx - 0.45, 3.5, 9.0, cx + 0.45, 4.3, 13.5, "Brick")
    # pool, palms, gates with the name
    m.box(-8.5, 6.5, 2.55, -1.5, 9.5, 2.62, "Water")
    for (x, y) in ((-10.5, -8.0), (10.5, -8.0), (-10.5, 8.0), (10.5, 8.0)):
        m.cyl(x, y, 1.6, 6.0, 0.18, "Bark", seg=6, r_top=0.12)
        smooth_blob(m, x, y, 6.4, 1.2, "Leaves", rng, sq=0.6, subdiv=1)
    for x in (-3.0, 3.0):
        m.box(x - 0.5, -11.9, 0.12, x + 0.5, -10.9, 3.4, "Trim")
        smooth_blob(m, x, -11.4, 3.7, 0.3, "Lamp", rng, subdiv=1, jitter=0)
    for x0, x1 in ((-11.8, -3.5), (3.5, 11.8)):
        fence(m, x0, -11.6, x1, -11.6, h=2.0, mat="Metal", post=1.2)
    m.box(-2.5, -11.65, 0.12, 2.5, -11.55, 2.6, "Metal")
    name_sign(m, "THE HILL", (0.0, -11.7, 2.75), (1, 0, 0), 0.4, plate="Sign", letters="Trim", max_w=4.2, pad=0.12)
    trees_row(m, rng, [(-10.0, 2.0), (-10.0, -2.0), (10.0, 2.0), (10.0, -2.0)], r=1.2)
    return m.build(name)


@special("landmark_tower", "Mayor's Tower", 2, 5, ["landmark", "office"])
def landmark_tower(name):
    """Supertall: a twisting stack of chamfered floor plates with a glowing crown and spire."""
    m = Mesh()
    lot(m, 12, "Paving")
    m.box(-11, -11, 0.12, 11, 11, 0.4, "Concrete")
    z = 0.4
    # tall lobby
    p = octagon(9.0, 3.0)
    ribbon_floors(m, p, z, 1, 8.0, "Trim", band=0.85, depth=0.3, pilaster="Trim", pil_pitch=2.0, pil_w=0.4)
    z += 8.0
    poly_cap(m, p, z, "Trim")
    floors = 54
    seg_f = 6   # floors per twist step
    for k in range(floors // seg_f):
        f = k / (floors // seg_f)
        s = 8.2 - 3.4 * f
        rot = k * 4.0
        base = octagon(s, s * 0.32)
        ca, sa = math.cos(math.radians(rot)), math.sin(math.radians(rot))
        pts = [(x * ca - y * sa, x * sa + y * ca) for x, y in base]
        ribbon_floors(m, pts, z, seg_f, 3.4, "Metal", band=0.8, depth=0.12, pilaster="Trim", pil_pitch=1.8,
                      pil_w=0.18, pil_d=0.3)
        z += seg_f * 3.4
        m.face([(x, y, z) for x, y in pts], "Roof", UP)
        z += 0.2
    # crown: lit fins and spire
    s = 4.6
    for k in range(8):
        a = k * math.tau / 8
        d = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-d.y, d.x, 0)) * 0.2
        m.obox(Vector((0, 0, z)) + d * (s - 1.6) - side, d * 1.6, side * 2, UP * 9.0, "Lamp")
    m.cyl(0, 0, z, z + 6.0, 3.0, "Glass", seg=8, r_top=1.6)
    m.cyl(0, 0, z + 6.0, z + 26.0, 0.5, "Metal", seg=8, r_top=0.05)
    name_sign(m, "MAYOR'S TOWER", (0.0, -10.4, 0.4), (1, 0, 0), 0.6, plate="Trim", letters="Metal", max_w=8, pad=0.2)
    return m.build(name)


# ----------------------------------------------------------------- driver ---

def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    K.MATERIALS = {}
    for nm, col in K.MAT_COLORS.items():
        mat = bpy.data.materials.new(nm)
        mat.diffuse_color = (*col, 1.0)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (*col, 1.0)
        K.MATERIALS[nm] = mat
    only = set(sys.argv[sys.argv.index("--") + 1:]) if "--" in sys.argv else None
    total = 0
    for sid, spec in SPECS.items():
        if only and sid not in only and spec["folder"] not in only:
            continue
        ob = spec["fn"](sid)
        ob.name = sid
        tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
        total += tris
        K.export(ob, spec["folder"])
        bpy.data.objects.remove(ob, do_unlink=True)
        spec["tris"] = tris
    entries = [{k: v for k, v in s.items() if k != "fn"} for s in SPECS.values()]
    with open(MANIFEST, "w") as f:
        json.dump({"_about": "Special buildings from art/tools/build_specials.py. size is in 12 m tiles "
                             "(0 = prop). door is in Godot local coords of the model (x right, z toward the "
                             "street, the model's front faces +Z), yaw_deg the way you face walking in.",
                   "specials": entries}, f, indent=1)
    gd = os.path.normpath(os.path.join(HERE, "..", "..", "interiors", "special_doors.gd"))
    with open(gd, "w") as f:
        f.write("## Generated by art/tools/build_specials.py: door spot (model-local, +Z = street side)\n"
                "## and interior for every enterable special. Don't edit by hand.\n\n"
                "const DOORS := {\n")
        for s in entries:
            if s.get("interior") and s.get("door"):
                d = s["door"]
                f.write(f'\t"{s["id"]}": {{"interior": "{s["interior"]}", "name": "{s["name"]}", '
                        f'"door": Vector3({d["x"]}, 0.0, {d["z"]})}},\n')
        f.write("}\n")
    print(f"done, {total} tris total, manifest -> {MANIFEST}")


if __name__ == "__main__":
    main()
