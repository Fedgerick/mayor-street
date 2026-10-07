"""Street dressing kit: the props art/dresser/street_dresser.gd scatters along sidewalks,
storefront modules for blank ground floors, rocks and grass for empty land.

    /opt/bpyenv/bin/python art/tools/build_street.py              # everything
    /opt/bpyenv/bin/python art/tools/build_street.py -- neon_bar  # one name

Writes assets/kit/street/<name>.glb. Same conventions as the rest of the kit: Z up,
the side that faces the street is -Y (Godot +Z), origin on the ground at the centre
(storefronts: origin on the wall plane at the module's bottom centre). Only material
names that scripts/kit.gd maps. Leaves sway in the wind (the dresser gives them
Kit's LeavesWind material), Sign glows at night in the instance's accent colour,
which is how the neon gets its colour.

Every model here is drawn hundreds of times through one MultiMesh, so they are kept
small: trees about 500 triangles, everything else well under 400.
"""
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "tools", "blender")))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import build_kit as K  # noqa: E402
from build_kit import UP, Mesh  # noqa: E402
from build_extra import smooth_blob  # noqa: E402
from build_specials import text_mesh  # noqa: E402
from mathutils import Vector  # noqa: E402

SUB = "street"


# ------------------------------------------------------------------ trees ---

def two_sided(m, pts, mat, normal, gap=0.004):
    """A thin card seen from both sides (the kit shader culls back faces). The back copy
    sits a few mm behind so the mesh welder keeps it separate."""
    n = Vector(normal).normalized()
    m.face(pts, mat, n)
    m.face([Vector(p) - n * gap for p in reversed(pts)], mat, -n)


def tree_street(name, seed, size=1.0, cones=False):
    """Sidewalk tree in an iron grate: slim trunk, light puffy canopy that sways."""
    rng = random.Random(seed)
    m = Mesh()
    g = 0.65
    m.box(-g, -g, 0.0, g, g, 0.035, "Metal")                 # tree grate
    m.box(-0.5, -0.5, 0.035, 0.5, 0.5, 0.05, "Bark")          # soil in the grate
    h = rng.uniform(2.6, 3.1) * size
    m.cyl(0, 0, 0.0, h, 0.13 * size, "Bark", seg=6, r_top=0.09 * size)
    for k in range(2):  # two limbs
        a = rng.uniform(0, math.tau) + k * math.pi
        d = Vector((math.cos(a), math.sin(a), 0))
        p0 = Vector((0, 0, h * 0.75))
        p1 = p0 + d * 0.6 * size + UP * 0.8 * size
        side = Vector((-d.y, d.x, 0)) * 0.06 * size
        m.obox(p0 - side, p1 - p0, side * 2, Vector((0, 0, 0.12)) * size, "Bark")
    R = rng.uniform(1.5, 1.75) * size
    c = Vector((0, 0, h + R * 0.6))
    if cones:  # narrow columnar street tree
        smooth_blob(m, 0, 0, c.z + R * 0.5, R * 0.75, "Leaves", rng, sq=1.9, subdiv=2, jitter=0.05)
    else:
        smooth_blob(m, c.x, c.y, c.z, R, "Leaves", rng, sq=0.8, subdiv=2, jitter=0.07)
        for _ in range(3):
            a = rng.uniform(0, math.tau)
            smooth_blob(m, math.cos(a) * R * 0.6, math.sin(a) * R * 0.6, c.z + rng.uniform(-0.2, 0.5) * R,
                        R * 0.55, "Leaves", rng, sq=0.85, subdiv=1, jitter=0.05)
    return m.build(name)


def bush_low(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    for _ in range(3):
        a = rng.uniform(0, math.tau)
        r = rng.uniform(0.35, 0.55)
        smooth_blob(m, math.cos(a) * 0.35, math.sin(a) * 0.35, r * 0.55, r, "Leaves", rng, sq=0.75, subdiv=0)
    return m.build(name)


def grass_tuft(name, seed, n=7):
    """Crossed blades for parks and empty lots; they sway with the leaves."""
    rng = random.Random(seed)
    m = Mesh()
    for _ in range(n):
        a = rng.uniform(0, math.pi)
        d = Vector((math.cos(a), math.sin(a), 0))
        o = Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 0))
        h = rng.uniform(0.3, 0.55)
        lean = Vector((rng.uniform(-0.12, 0.12), rng.uniform(-0.12, 0.12), 0))
        w = rng.uniform(0.05, 0.08)
        tip = o + lean + UP * h
        pts = [o - d * w, o + d * w, tip]
        two_sided(m, pts, "Leaves", d.cross(UP))
    return m.build(name)


def flowers(name, seed):
    """A clump of leaves with petals in the instance's accent colour."""
    rng = random.Random(seed)
    m = Mesh()
    smooth_blob(m, 0, 0, 0.12, 0.3, "Leaves", rng, sq=0.6, subdiv=0)
    for _ in range(10):
        a = rng.uniform(0, math.tau)
        r = rng.uniform(0.05, 0.27)
        x, y, z = math.cos(a) * r, math.sin(a) * r, rng.uniform(0.2, 0.32)
        s = 0.04
        m.box(x - s, y - s, z, x + s, y + s, z + 0.05, "Awning", top="Awning")
    return m.build(name)


def rock(name, seed, size=1.0):
    rng = random.Random(seed)
    m = Mesh()
    m.blob(0, 0, 0.25 * size, 0.7 * size, "Concrete", rng, sq=0.6, subdiv=1, jitter=0.28)
    if rng.random() < 0.7:
        m.blob(0.55 * size, 0.2 * size, 0.12 * size, 0.38 * size, "Concrete", rng, sq=0.6, subdiv=1, jitter=0.25)
    return m.build(name)


# --------------------------------------------------------- street clutter ---

def trash_overflow(name, seed):
    """A full bin with bags heaped beside it, where garbage isn't being collected."""
    rng = random.Random(seed)
    m = Mesh()
    m.cyl(0, 0, 0.0, 0.95, 0.3, "Metal", seg=8, top="Tire", smooth=True)
    m.cyl(0, 0, 0.95, 1.0, 0.33, "Metal", seg=8, top="Tire")
    smooth_blob(m, 0.05, 0.0, 1.05, 0.28, "Tire", rng, sq=0.7, subdiv=0)  # bag sticking out of the top
    for k in range(4):
        a = rng.uniform(-1.2, 1.2) - math.pi / 2
        r = rng.uniform(0.6, 0.85)
        smooth_blob(m, math.cos(a) * r, math.sin(a) * r, 0.22, rng.uniform(0.25, 0.32), "Tire", rng,
                    sq=0.8, subdiv=0)
    m.box(0.45, -0.7, 0.0, 0.85, -0.35, 0.3, "Door")  # a soggy cardboard box
    return m.build(name)


def trash_bags(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    for k in range(5):
        x, y = rng.uniform(-0.6, 0.6), rng.uniform(-0.35, 0.35)
        smooth_blob(m, x, y, 0.24, rng.uniform(0.24, 0.33), "Tire", rng, sq=0.8, subdiv=0)
    m.box(-0.9, -0.2, 0.0, -0.5, 0.25, 0.32, "Door")
    return m.build(name)


def parking_meter(name):
    m = Mesh()
    m.cyl(0, 0, 0, 1.05, 0.04, "Metal", seg=6)
    m.box(-0.1, -0.08, 1.05, 0.1, 0.08, 1.45, "Metal")
    m.box(-0.07, -0.085, 1.22, 0.07, -0.08, 1.38, "Glass")
    m.cyl(0, 0, 1.45, 1.5, 0.1, "Metal", seg=6)
    return m.build(name)


def street_sign(name):
    """Corner street-name sign: two crossed green blades on a pole."""
    m = Mesh()
    m.cyl(0, 0, 0, 3.0, 0.045, "Metal", seg=6)
    m.box(-0.6, -0.02, 2.75, 0.6, 0.02, 2.97, "Sign")
    m.box(-0.02, -0.6, 2.98, 0.02, 0.6, 3.2, "Sign")
    m.box(-0.25, -0.03, 2.1, 0.25, 0.03, 2.55, "Marking")   # a white "no parking" plate
    return m.build(name)


def cafe_set(name, seed):
    """A café table under an umbrella with two chairs (umbrella in the accent colour)."""
    rng = random.Random(seed)
    m = Mesh()
    m.cyl(0, 0, 0, 0.72, 0.04, "Metal", seg=6, cap=False)
    m.cyl(0, 0, 0.72, 0.75, 0.38, "Trim", seg=10)
    m.cyl(0, 0, 0.75, 2.2, 0.025, "Metal", seg=5, cap=False)
    ring = [Vector((math.cos(a) * 1.25, math.sin(a) * 1.25, 1.95)) for a in
            [i * math.tau / 8 for i in range(8)]]
    tip = Vector((0, 0, 2.35))
    for i in range(8):
        a, b = ring[i], ring[(i + 1) % 8]
        two_sided(m, [a, b, tip], "Awning", (a + b) * 0.5 - Vector((0, 0, 1.5)))
    for s in (-1, 1):
        x = s * 0.62
        m.box(x - 0.2, -0.2, 0.43, x + 0.2, 0.2, 0.47, "Metal")
        for dx in (-0.17, 0.17):
            for dy in (-0.17, 0.17):
                m.box(x + dx - 0.02, dy - 0.02, 0, x + dx + 0.02, dy + 0.02, 0.43, "Metal")
        bx = x + s * 0.18
        m.box(bx - 0.02, -0.2, 0.47, bx + 0.02, 0.2, 0.85, "Metal")
    return m.build(name)


def neon_blade(name, text, seed):
    """Projecting neon blade sign on a bracket; letters in Sign so they glow in the
    instance's accent colour at night. Mounted on the wall: the wall is at y = +0.05."""
    m = Mesh()
    n = len(text)
    lh = 0.42
    H = n * lh * 1.15 + 0.35
    z0 = 3.6
    m.box(-0.03, -0.05, z0 + H * 0.2, 0.03, 0.05, z0 + H * 0.2 + 0.06, "Metal")
    m.box(-0.05, -0.95, z0 - 0.05, 0.05, 0.05, z0, "Metal")
    m.box(-0.05, -0.95, z0 + H, 0.05, 0.05, z0 + H + 0.05, "Metal")
    # The blade sticks out of the wall (-Y), its faces look along +-X.
    m.box(-0.08, -0.9, z0, 0.08, -0.15, z0 + H, "Roof")
    for side in (-1, 1):
        u = Vector((0, side, 0))  # reading direction on this face
        for i, ch in enumerate(text):
            z = z0 + H - 0.2 - (i + 1) * lh * 1.15
            text_mesh(m, ch, Vector((side * 0.085, -0.525, z)), u, lh, "Sign", depth=0.03)
    # a neon tube frame around the blade
    for side in (-1, 1):
        x = side * 0.09
        m.box(x - 0.012, -0.88, z0 + 0.03, x + 0.012, -0.86, z0 + H - 0.03, "Sign")
        m.box(x - 0.012, -0.88, z0 + H - 0.05, x + 0.012, -0.17, z0 + H - 0.03, "Sign")
        m.box(x - 0.012, -0.88, z0 + 0.03, x + 0.012, -0.17, z0 + 0.05, "Sign")
    return m.build(name)


# ------------------------------------------------------------ storefronts ---

def shop_unit(m, rng, x0, x1, z0=0.0, h=4.0, awning="slope", sign=True, cafe=False):
    """One shop on the wall plane y = 0, sticking out toward -Y. A back panel runs 0.6 m
    into the wall so the module covers recessed or uneven ground floors."""
    w = x1 - x0
    m.box(x0, -0.12, z0, x1, 0.6, z0 + h, "Concrete", top="Concrete")   # backing / pilaster block
    m.box(x0, -0.2, z0, x1, -0.12, z0 + 0.45, "Trim")                  # stall riser
    m.box(x0 + 0.25, -0.16, z0 + 0.45, x1 - 0.25, -0.13, z0 + h - 0.85, "Glass")
    panes = max(2, int(w / 2.0))
    for i in range(panes + 1):
        x = x0 + 0.25 + (w - 0.5) * i / panes
        m.box(x - 0.05, -0.22, z0 + 0.45, x + 0.05, -0.12, z0 + h - 0.85, "Metal")
    dx = x0 + w * rng.choice([0.2, 0.5, 0.8])
    dx = min(max(dx, x0 + 0.9), x1 - 0.9)
    m.box(dx - 0.6, -0.24, z0 + 0.02, dx + 0.6, -0.12, z0 + 2.45, "Door")
    m.box(dx - 0.45, -0.25, z0 + 1.0, dx + 0.45, -0.24, z0 + 2.2, "Glass")
    m.box(x0, -0.3, z0 + h - 0.85, x1, -0.12, z0 + h - 0.6, "Trim")      # sign band trim
    if sign:
        m.box(x0 + 0.3, -0.36, z0 + h - 0.6, x1 - 0.3, -0.12, z0 + h - 0.05, "Sign")
    else:
        m.box(x0, -0.3, z0 + h - 0.6, x1, -0.12, z0 + h - 0.05, "Trim")
    m.box(x0, -0.32, z0 + h - 0.05, x1, -0.12, z0 + h + 0.12, "Trim")    # cornice
    if awning == "slope":
        a, b, d = z0 + h - 0.95, z0 + h - 1.75, 1.5
        m.face([(x0 + 0.1, -0.2, a), (x1 - 0.1, -0.2, a), (x1 - 0.1, -0.2 - d, b), (x0 + 0.1, -0.2 - d, b)],
               "Awning", (0, -1, 1))
        m.face([(x0 + 0.1, -0.2, a - 0.04), (x1 - 0.1, -0.2, a - 0.04), (x1 - 0.1, -0.2 - d, b - 0.04),
                (x0 + 0.1, -0.2 - d, b - 0.04)], "Awning", (0, 0, -1))
        m.face([(x0 + 0.1, -0.2 - d, b), (x1 - 0.1, -0.2 - d, b), (x1 - 0.1, -0.2 - d, b - 0.32),
                (x0 + 0.1, -0.2 - d, b - 0.32)], "Awning", (0, -1, 0))
        for x in (x0 + 0.1, x1 - 0.1):  # side cheeks
            s = 1 if x > x0 + 0.2 else -1
            m.face([(x, -0.2, a), (x, -0.2 - d, b), (x, -0.2 - d, b - 0.32)], "Awning", (s, 0, 0))
    elif awning == "box":
        a = z0 + h - 0.95
        m.box(x0 + 0.15, -1.2, a - 0.25, x1 - 0.15, -0.2, a, "Awning", top="Awning", bottom=True)
    if cafe:  # planter boxes framing a café front
        for x in (x0 + 0.3, x1 - 1.1):
            m.box(x, -0.75, z0, x + 0.8, -0.35, z0 + 0.45, "Door", top="Door")
            smooth_blob(m, x + 0.4, -0.55, z0 + 0.55, 0.32, "Leaves", rng, sq=0.6, subdiv=0)


def storefront(name, seed, units, h=4.0):
    """A module of one or more shops (12 m wide, or 6 m for the half), centred on x = 0. units: list of (width, awning, sign, cafe)."""
    rng = random.Random(seed)
    m = Mesh()
    x = -sum(u[0] for u in units) / 2
    for w, aw, sg, cafe in units:
        shop_unit(m, rng, x, x + w, 0.0, h, aw, sg, cafe)
        x += w
    return m.build(name)


# ------------------------------------------------------------------ jobs ---

JOBS = [
    ("tree_street_a", lambda n: tree_street(n, 301)),
    ("tree_street_b", lambda n: tree_street(n, 302, 1.15)),
    ("tree_street_c", lambda n: tree_street(n, 303, 1.0, cones=True)),
    ("bush_low", lambda n: bush_low(n, 304)),
    ("grass_tuft_a", lambda n: grass_tuft(n, 305)),
    ("grass_tuft_b", lambda n: grass_tuft(n, 306, 10)),
    ("flowers", lambda n: flowers(n, 307)),
    ("rock_a", lambda n: rock(n, 308)),
    ("rock_b", lambda n: rock(n, 309, 1.6)),
    ("rock_c", lambda n: rock(n, 310, 0.6)),
    ("trash_overflow", lambda n: trash_overflow(n, 311)),
    ("trash_bags", lambda n: trash_bags(n, 312)),
    ("parking_meter", parking_meter),
    ("street_sign", street_sign),
    ("cafe_set", lambda n: cafe_set(n, 313)),
    ("neon_bar", lambda n: neon_blade(n, "BAR", 314)),
    ("neon_open", lambda n: neon_blade(n, "OPEN", 315)),
    ("neon_hotel", lambda n: neon_blade(n, "HOTEL", 316)),
    ("neon_pizza", lambda n: neon_blade(n, "PIZZA", 317)),
    ("neon_24h", lambda n: neon_blade(n, "24H", 318)),
    ("storefront_a", lambda n: storefront(n, 321, [(12.0, "slope", True, False)])),
    ("storefront_b", lambda n: storefront(n, 322, [(6.0, "slope", True, False), (6.0, "box", True, False)])),
    ("storefront_c", lambda n: storefront(n, 323, [(12.0, None, True, True)])),
    ("storefront_d", lambda n: storefront(n, 324, [(4.0, "box", True, False), (4.0, None, True, False),
                                                    (4.0, "slope", True, False)])),
    ("storefront_half", lambda n: storefront(n, 325, [(6.0, "slope", True, False)])),
]


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
    for name, fn in JOBS:
        if only and name not in only:
            continue
        ob = fn(name)
        total += sum(len(p.vertices) - 2 for p in ob.data.polygons)
        K.export(ob, SUB)
    print(f"done, {total} tris total")


if __name__ == "__main__":
    main()
