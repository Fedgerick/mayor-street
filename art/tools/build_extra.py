"""Extra pieces for the MAYOR / STREET kit, built on tools/blender/build_kit.py.

Adds building variants under the kit's <zone>_<stage>_<size>_<variant> names
(so kit.gd picks them up with no code change), civic buildings for city
services, more street props and softer stylized trees.

    python3 art/tools/build_extra.py              # everything
    python3 art/tools/build_extra.py -- civic     # one folder or one name

Uses only material names that scripts/kit.gd already maps, except "Water"
(fountain, pool), which falls back to the glTF colour until kit.gd maps it.
Run build_kit.py first: it owns everything this script does not list.
"""
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "tools", "blender")))

import bpy  # noqa: E402
import build_kit as K  # noqa: E402
from build_kit import (UP, Mesh, block_with_windows, facade, fence, flat_roof, gable_roof,  # noqa: E402
                       hip_roof, lot, roof_clutter, storefront)
from mathutils import Vector  # noqa: E402


# --------------------------------------------------------------- helpers ---

def smooth_blob(m, cx, cy, cz, r, mat, rng, sq=1.0, subdiv=2, jitter=0.08):
    """Puffy, smooth-shaded canopy lump (the soft stylized foliage look)."""
    import bmesh
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=subdiv + 1, radius=r)
    for v in tmp.verts:
        k = 1.0 + rng.uniform(-jitter, jitter)
        v.co = Vector((v.co.x * k + cx, v.co.y * k + cy, v.co.z * k * sq + cz))
    for f in tmp.faces:
        pts = [v.co.copy() for v in f.verts]
        ctr = sum(pts, Vector()) / len(pts)
        m.face(pts, mat, ctr - Vector((cx, cy, cz)), smooth=True)
    tmp.free()


def poly_edges(pts):
    """(origin, unit u, length) for each edge of a CCW footprint (outward = u x up)."""
    out = []
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        a, b = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
        out.append((a, (b - a).normalized(), (b - a).length))
    return out


def octagon(s, c):
    """Square of half-size s with corners chamfered by c, CCW from front-left."""
    return [(-s + c, -s), (s - c, -s), (s, -s + c), (s, s - c), (s - c, s), (-s + c, s), (-s, s - c), (-s, -s + c)]


def poly_cap(m, pts, z, mat, rim=None, rim_h=0.5, rim_t=0.25):
    m.face([(x, y, z) for x, y in pts], mat, UP)
    if rim:
        for o, u, L in poly_edges(pts):
            n = u.cross(UP)
            m.obox(o + Vector((0, 0, z - 0.2)) - u * 0.0 + n * 0.12, u * L, -n * rim_t, UP * (rim_h + 0.2), rim)


def ribbon_floors(m, pts, z0, floors, fh, wall, glass="Glass", band=0.62, depth=0.22,
                  pilaster=None, pil_pitch=3.0, pil_w=0.35, pil_d=0.3):
    """Cheap tower skin: per floor a spandrel and a recessed glass ribbon, plus optional
    full-height pilasters. A few quads per floor per side, so tall towers stay light."""
    for o, u, L in poly_edges(pts):
        n = u.cross(UP)

        def P(a, h, d=0.0):
            return o + u * a + UP * h - n * d
        for f in range(floors):
            zb = z0 + f * fh
            zg, zt = zb + fh * (1 - band), zb + fh
            m.face([P(0, zb), P(L, zb), P(L, zg), P(0, zg)], wall, n)
            m.face([P(0, zg), P(L, zg), P(L, zg, depth), P(0, zg, depth)], wall, UP)
            m.face([P(0, zt), P(L, zt), P(L, zt, depth), P(0, zt, depth)], wall, -UP)
            m.face([P(0, zg), P(0, zt), P(0, zt, depth), P(0, zg, depth)], wall, u)
            m.face([P(L, zg), P(L, zt), P(L, zt, depth), P(L, zg, depth)], wall, -u)
            m.face([P(0, zg, depth), P(L, zg, depth), P(L, zt, depth), P(0, zt, depth)], glass, n)
        if pilaster:
            cols = max(1, int(L / pil_pitch))
            for c in range(1, cols):
                a = L * c / cols
                m.obox(P(a - pil_w / 2, z0), u * pil_w, n * pil_d, UP * floors * fh, pilaster)


def ladder_box(m, x0, y0, z0, x1, y1, z1, mat):
    m.box(x0, y0, z0, x1, y1, z1, mat)


def trees_row(m, rng, pts, r=1.2, z=0.12):
    for (x, y) in pts:
        m.cyl(x, y, z, z + 1.6, 0.14, "Bark", seg=6, r_top=0.1)
        smooth_blob(m, x, y, z + 1.6 + r * 0.8, r, "Leaves", rng, sq=0.9, subdiv=1)


# ------------------------------------------------------- residential +5 ---

def res_modern(name, seed):
    """Flat-roofed modern house: two stacked offset boxes, big glass, carport."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Grass")
    m.box(-4.6, -2.4, 0.0, 2.2, 3.8, 0.4, "Concrete")
    block_with_windows(m, -4.4, -2.2, 2.0, 3.6, 0.4, 1, 3.0, "Wall", win_w=2.4, win_h=2.2, sill=0.3,
                       pitch=3.2, front_skip=lambda f, c: c == 1)
    m.box(-0.5, -2.25, 0.4, 0.6, -2.18, 2.6, "Door")
    # cantilevered upper box clad in timber (Door is accent-tinted wood)
    ux0, ux1, uy0, uy1 = -2.6, 3.8, -1.6, 4.2
    m.box(ux0, uy0, 3.4, ux1, uy1, 3.6, "Trim")
    block_with_windows(m, ux0, uy0, ux1, uy1, 3.6, 1, 2.9, "Door", win_w=2.6, win_h=1.6, sill=0.7,
                       pitch=3.1, depth=0.25)
    flat_roof(m, ux0, uy0, ux1, uy1, 6.5, parapet=0.25, rim="Trim")
    flat_roof(m, -4.4, -2.2, ux0, 3.6, 3.4, parapet=0.2, rim="Trim")
    # carport
    for py in (-1.0, 3.0):
        m.box(4.9, py, 0.12, 5.05, py + 0.15, 3.1, "Metal")
    m.box(2.2, -1.4, 3.1, 5.4, 3.6, 3.3, "Roof", sides="Trim")
    m.box(2.6, -6.0, 0.0, 5.2, 3.4, 0.15, "Paving")
    # timber deck + hedges + young trees
    m.box(-4.6, 3.8, 0.0, 0.0, 5.4, 0.3, "Door")
    m.box(-5.7, -5.4, 0.12, 1.8, -4.7, 1.0, "Leaves")
    trees_row(m, rng, [(-4.8, 4.9), (-1.2, -4.2)], r=1.1)
    m.box(-1.0, -6.0, 0.0, 0.0, -2.4, 0.15, "Paving")
    return m.build(name)


def res_duplex(name, seed):
    """Two narrow gabled townhouses sharing a party wall, mirrored colours via trim."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Grass")
    for k, (x0, x1) in enumerate(((-5.0, -0.05), (0.05, 5.0))):
        y0, y1 = -2.0, 5.0
        m.box(x0, y0, 0.0, x1, y1, 0.6, "Concrete")
        wall = "Wall" if k == 0 else "Accent"
        block_with_windows(m, x0, y0, x1, y1, 0.6, 2, 2.9, wall, win_w=1.1, win_h=1.5, pitch=2.4,
                           mullion=True, front_skip=lambda f, c, kk=k: f == 0 and c == (0 if kk == 0 else 1))
        dx = x0 + 1.2 if k == 0 else x1 - 1.2
        m.box(dx - 0.5, y0 - 0.06, 0.6, dx + 0.5, y0 + 0.02, 2.75, "Door")
        m.box(dx - 0.8, y0 - 1.0, 2.9, dx + 0.8, y0, 3.05, "Trim")
        for s in (-1, 1):
            m.box(dx + s * 0.7 - 0.06, y0 - 0.95, 0.6, dx + s * 0.7 + 0.06, y0 - 0.85, 2.9, "Trim")
        m.box(dx - 0.9, y0 - 1.2, 0.0, dx + 0.9, y0, 0.45, "Concrete")
        m.box(dx - 0.5, -6.0, 0.0, dx + 0.5, y0 - 1.2, 0.15, "Paving")
        # bay window on the upper floor
        bx = (x0 + x1) / 2 + (0.6 if k == 0 else -0.6)
        m.box(bx - 1.1, y0 - 0.7, 3.4, bx + 1.1, y0, 5.6, "Trim")
        m.box(bx - 0.9, y0 - 0.72, 3.9, bx + 0.9, y0 - 0.68, 5.2, "Glass")
        gable_roof(m, x0, y0, x1, y1, 6.4, 2.6 + 0.2 * k, along_x=False, over=0.3)
        m.box(x1 - 1.4 if k == 0 else x0 + 0.6, y1 - 2.0, 6.0, (x1 - 0.6) if k == 0 else x0 + 1.4, y1 - 1.2,
              9.4, "Brick")
    m.box(-0.12, -2.4, 0.6, 0.12, 5.2, 7.2, "Trim")  # party wall fin
    for sx in (-3.6, 3.6):
        smooth_blob(m, sx, -3.4, 0.55, 0.65, "Leaves", rng, sq=0.75, subdiv=1)
    fence(m, -5.7, -5.6, 5.7, -5.6, h=0.8, gap=(0.2, 0.8))
    return m.build(name)


def res_brownstones(name, seed):
    """Row of three narrow brownstones with stoops, bays and heavy cornices."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    walls = ["Brick", "Accent", "Brick"]
    floors = [4, 4, 4]
    for k in range(3):
        x0 = -5.6 + k * 3.75
        x1 = x0 + 3.65
        y0, y1 = -3.6, 5.4
        fl = floors[k] + (1 if rng.random() < 0.3 else 0)
        m.box(x0, y0, 0.0, x1, y1, 1.4, "Concrete")
        block_with_windows(m, x0, y0, x1, y1, 1.4, fl, 3.0, walls[k], win_w=0.95, win_h=1.75, sill=0.7,
                           pitch=1.2, front_skip=lambda f, c: f == 0 and c == 0, lintel="Trim")
        m.box(x0 + 0.25, y0 - 0.06, 1.4, x0 + 1.15, y0 + 0.02, 3.8, "Door")
        m.box(x0 + 0.1, y0 - 0.3, 3.8, x0 + 1.3, y0, 4.1, "Trim")
        for i in range(5):  # stoop
            m.box(x0 + 0.15, y0 - 2.2 + i * 0.44, 0.0, x0 + 1.25, y0, 0.28 * (i + 1), "Concrete")
        for s in (0.1, 1.3):
            m.box(x0 + s - 0.05, y0 - 2.2, 0.28, x0 + s + 0.05, y0, 1.6, "Metal")
        top = 1.4 + fl * 3.0
        m.box(x0 - 0.02, y0 - 0.6, top - 0.1, x1 + 0.02, y1 + 0.1, top + 0.25, "Trim")
        m.box(x0 - 0.02, y0 - 0.45, top + 0.25, x1 + 0.02, y1 + 0.1, top + 0.7, "Trim")
        for bx in range(4):
            xx = x0 + 0.3 + bx * 1.0
            m.box(xx, y0 - 0.6, top - 0.5, xx + 0.18, y0, top - 0.1, "Trim")  # brackets
        flat_roof(m, x0, y0, x1, y1, top + 0.7, parapet=0.2, rim="Trim")
        m.box(x1 - 1.2, y1 - 1.5, top + 0.7, x1 - 0.5, y1 - 0.8, top + 2.0, "Brick")
    for sx in (-5.6 + 3.75 * k + 2.6 for k in range(3)):
        m.cyl(sx, -5.2, 0.12, 1.4, 0.12, "Bark", seg=6)
        smooth_blob(m, sx, -5.2, 2.4, 1.0, "Leaves", rng, subdiv=1)
    return m.build(name)


def res_stepped(name, seed):
    """Stepped brick apartment block with terraces, roof garden and a water tower."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    fh = 3.0
    tiers = [(-5.2, -4.6, 5.2, 5.2, 6), (-5.2, -2.4, 5.2, 5.2, 3), (-5.2, 0.0, 3.0, 5.2, 3)]
    z = 0.12
    m.box(-5.2, -4.6, 0.12, 5.2, 5.2, 4.2, "Concrete")
    storefront(m, rng, -5.2, 5.2, -4.6, 0.12, h=4.0, awning=True, sign=False)
    z = 4.2
    for i, (x0, y0, x1, y1, fl) in enumerate(tiers):
        block_with_windows(m, x0, y0, x1, y1, z, fl, fh, "Brick", win_w=1.2, win_h=1.6, pitch=2.0,
                           mullion=True, lintel="Trim")
        z2 = z + fl * fh
        m.box(x0 - 0.2, y0 - 0.2, z2, x1 + 0.2, y1 + 0.2, z2 + 0.35, "Trim")
        nxt = tiers[i + 1] if i + 1 < len(tiers) else None
        if nxt:
            # terrace: deck, glass rail, planters on the exposed strip
            m.box(x0, y0, z2 + 0.35, x1, nxt[1], z2 + 0.4, "Door")
            m.box(x0, y0 - 0.1, z2 + 0.35, x1, y0 + 0.02, z2 + 1.3, "Glass")
            for px in range(3):
                xx = x0 + 1.5 + px * (x1 - x0 - 3) / 2
                m.box(xx - 0.5, y0 + 0.3, z2 + 0.4, xx + 0.5, y0 + 0.9, z2 + 0.9, "Concrete")
                smooth_blob(m, xx, y0 + 0.6, z2 + 1.2, 0.5, "Leaves", rng, sq=0.8, subdiv=1)
            z = z2 + 0.35
        else:
            flat_roof(m, x0, y0, x1, y1, z2 + 0.35, parapet=0.6, rim="Trim")
            m.box(x0 + 0.6, y0 + 0.6, z2 + 0.35, x1 - 3.0, y1 - 0.6, z2 + 0.5, "Grass")
            for k in range(3):
                smooth_blob(m, x0 + 1.3 + k * 1.6, y1 - 1.3, z2 + 1.0, 0.6, "Leaves", rng, sq=0.8, subdiv=1)
            roof_clutter(m, rng, x1 - 2.8, y0, x1, y1, z2 + 0.35, n=0, tank=True)
    return m.build(name)


def res_twin_towers(name, seed):
    """Size-2 residential: two slim towers on a shared podium with a pool deck."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 12, "Paving")
    m.box(-11, -10.5, 0.12, 11, 10.5, 5.0, "Concrete", top="Paving")
    storefront(m, rng, -11, -2.0, -10.5, 0.12, h=4.4)
    storefront(m, rng, 2.0, 11, -10.5, 0.12, h=4.4)
    m.box(-2.0, -10.6, 0.12, 2.0, -10.4, 3.6, "Glass")
    m.box(-11.3, -10.8, 4.8, 11.3, 10.8, 5.3, "Trim")
    # pool deck between the towers
    m.box(-3.0, -6.0, 5.0, 3.0, 4.0, 5.08, "Water")
    m.box(-3.4, -6.4, 5.0, 3.4, -6.0, 5.3, "Trim")
    m.box(-3.4, 4.0, 5.0, 3.4, 4.4, 5.3, "Trim")
    for py in (-4.5, -1.0, 2.5):
        for s in (-1, 1):
            m.box(s * 4.2 - 0.4, py, 5.3, s * 4.2 + 0.4, py + 1.8, 5.6, "Trim")
    for (cx, fl, wall) in ((-7.0, 22, "Wall"), (7.0, 28, "Accent")):
        pts = octagon(3.8, 1.1)
        pts = [(x + cx, y) for x, y in pts]
        ribbon_floors(m, pts, 5.3, fl, 3.0, wall, band=0.55, pilaster="Trim", pil_pitch=2.6)
        top = 5.3 + fl * 3.0
        poly_cap(m, pts, top, "Roof", rim="Trim", rim_h=0.9)
        # balconies every other floor on the front faces
        for f in range(1, fl, 2):
            z = 5.3 + f * 3.0
            m.box(cx - 2.6, -4.6, z - 0.1, cx + 2.6, -3.8, z + 0.05, "Concrete")
            m.box(cx - 2.6, -4.62, z + 0.05, cx + 2.6, -4.58, z + 1.0, "Glass")
        m.box(cx - 1.6, -1.6, top, cx + 1.6, 1.6, top + 2.6, "Trim", top="Roof")
    for sx in (-10.0, 10.0):
        smooth_blob(m, sx, -11.2, 1.0, 0.8, "Leaves", rng, sq=0.7, subdiv=1)
    return m.build(name)


# --------------------------------------------------------- commercial +4 ---

def com_diner(name, seed):
    """Chrome diner with wraparound windows, a tall pole sign and patio umbrellas."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -4.6, 3.4, -2.4, 3.8
    m.box(x0, y0, 0.12, x1, y1, 0.9, "Metal")
    m.box(x0, y0, 0.9, x1, y1, 1.0, "Sign")
    for (o, u, L, n) in (((x0, y0), (1, 0, 0), x1 - x0, "S"), ((x1, y0), (0, 1, 0), y1 - y0, "E"),
                         ((x0, y1), (0, -1, 0), y1 - y0, "W")):
        if n == "W":
            o = (x0, y1)
        uu = Vector(u)
        nn = uu.cross(UP)
        base = Vector((o[0], o[1], 1.0))
        m.face([base, base + uu * L, base + uu * L + UP * 1.6, base + UP * 1.6], "Glass", nn)
    m.face([(x0, y1, 0.9), (x1, y1, 0.9), (x1, y1, 2.6), (x0, y1, 2.6)], "Metal", (0, 1, 0))
    m.box(x0 - 0.1, y0 - 0.1, 2.6, x1 + 0.1, y1 + 0.1, 3.2, "Sign")
    # barrel roof
    seg = 8
    for i in range(seg):
        a0, a1 = math.pi * i / seg, math.pi * (i + 1) / seg
        r = (y1 - y0) / 2 + 0.3
        yc = (y0 + y1) / 2
        p0 = (yc - r * math.cos(a0), 3.2 + 0.9 * math.sin(a0))
        p1 = (yc - r * math.cos(a1), 3.2 + 0.9 * math.sin(a1))
        m.face([(x0 - 0.3, p0[0], p0[1]), (x1 + 0.3, p0[0], p0[1]), (x1 + 0.3, p1[0], p1[1]),
                (x0 - 0.3, p1[0], p1[1])], "Metal", (0, p0[0] + p1[0] - 2 * yc, 1))
    for xx in (x0, x1):
        pts = [(xx, (y0 + y1) / 2 - ((y1 - y0) / 2 + 0.3) * math.cos(math.pi * i / seg),
                3.2 + 0.9 * math.sin(math.pi * i / seg)) for i in range(seg + 1)]
        m.face(pts, "Trim", (1 if xx == x1 else -1, 0, 0))
    m.box(-1.0, y0 - 0.5, 0.12, 0.4, y0, 2.5, "Metal")
    m.box(-0.9, y0 - 0.52, 0.2, 0.3, y0 - 0.48, 2.3, "Glass")
    # pole sign
    m.cyl(4.6, -4.4, 0.12, 7.0, 0.16, "Metal", seg=8)
    m.box(3.4, -4.6, 7.0, 5.8, -4.2, 9.2, "Sign")
    m.box(3.3, -4.65, 6.9, 5.9, -4.15, 7.05, "Trim")
    m.box(3.3, -4.65, 9.15, 5.9, -4.15, 9.3, "Trim")
    # patio with umbrellas and tables
    for k, (tx, ty) in enumerate(((-3.6, -4.6), (-1.6, -4.8), (1.4, -4.6))):
        m.cyl(tx, ty, 0.12, 0.85, 0.05, "Metal", seg=6)
        m.cyl(tx, ty, 0.85, 0.9, 0.45, "Trim", seg=10)
        m.cyl(tx, ty, 0.9, 2.3, 0.04, "Metal", seg=6)
        m.cyl(tx, ty, 2.0, 2.45, 1.2, "Awning", seg=10, r_top=0.05)
    m.box(x0 - 0.8, -5.8, 0.12, x0 - 0.6, -3.2, 1.0, "Leaves")
    # back: dumpster
    m.box(1.0, 4.4, 0.12, 3.0, 5.6, 1.3, "Accent")
    return m.build(name)


def com_loft(name, seed):
    """Brick warehouse-turned-offices: tall arched-feel windows, rooftop sign frame."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.4, 5.4, -4.6, 5.4
    m.box(x0, y0, 0.12, x1, y1, 0.9, "Concrete")
    storefront(m, rng, x0, x1, y0, 0.9, h=3.8, awning=rng.random() < 0.5)
    block_with_windows(m, x0, y0, x1, y1, 0.9, 1, 4.0, "Brick", pitch=2.6, win_h=2.4, sill=0.8,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    fl = 4
    block_with_windows(m, x0, y0, x1, y1, 4.9, fl, 3.6, "Brick", win_w=1.6, win_h=2.5, sill=0.6,
                       pitch=2.4, mullion=True, lintel="Trim")
    top = 4.9 + fl * 3.6
    # pilasters + corbelled cornice
    for xx in (x0 - 0.05, -1.8, 1.8, x1 - 0.45):
        m.box(xx, y0 - 0.25, 0.9, xx + 0.5, y0 + 0.02, top, "Brick")
    for i in range(14):
        xx = x0 + 0.2 + i * (x1 - x0 - 0.4) / 13
        m.box(xx - 0.12, y0 - 0.45, top - 0.4, xx + 0.12, y0, top, "Trim")
    m.box(x0 - 0.4, y0 - 0.6, top, x1 + 0.4, y1 + 0.4, top + 0.5, "Trim")
    flat_roof(m, x0, y0, x1, y1, top + 0.5, parapet=0.4, rim="Brick")
    # rooftop sign frame (lattice)
    for xx in (-4.0, -1.3, 1.3, 4.0):
        m.box(xx - 0.08, 0.0, top + 0.5, xx + 0.08, 0.16, top + 3.6, "Metal")
    m.box(-4.4, -0.05, top + 2.0, 4.4, 0.2, top + 4.0, "Sign")
    roof_clutter(m, rng, x0, 1.0, x1, y1, top + 0.5, n=2, tank=True)
    return m.build(name)


def com_glass_tower(name, seed, floors):
    """Chamfered glass office tower with a lit crown (size 1)."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    m.box(-5.6, -5.6, 0.12, 5.6, 5.6, 0.3, "Concrete")
    pts = octagon(5.0, 1.6)
    # lobby: recessed glass with columns
    inner = octagon(4.4, 1.4)
    for o, u, L in poly_edges(inner):
        n = u.cross(UP)
        m.face([o + UP * 0.3, o + u * L + UP * 0.3, o + u * L + UP * 6.0, o + UP * 6.0], "Glass", n)
    for (x, y) in pts:
        m.cyl(x * 0.93, y * 0.93, 0.3, 6.0, 0.25, "Trim", seg=8)
    poly_cap(m, pts, 6.0, "Trim")
    m.face([(x, y, 6.0) for x, y in reversed(pts)], "Trim", -UP)
    ribbon_floors(m, pts, 6.0, floors, 3.6, "Metal", band=0.78, depth=0.12, pilaster="Trim", pil_pitch=1.8,
                  pil_w=0.18, pil_d=0.35)
    top = 6.0 + floors * 3.6
    # crown: stepped chamfered rings
    z = top
    for k, (s, c, h) in enumerate(((5.0, 1.6, 0.8), (4.2, 1.3, 3.0), (3.0, 0.9, 2.0))):
        p = octagon(s, c)
        ribbon_floors(m, p, z, 1, h, "Trim", glass="Sign" if k == 1 else "Glass", band=0.6, depth=0.1)
        z += h
        poly_cap(m, p, z, "Roof")
    m.cyl(0, 0, z, z + 7.0, 0.2, "Metal", seg=6, r_top=0.05)
    m.box(-1.4, -4.9, 0.3, 1.4, -4.4, 3.0, "Door")
    for sx in (-5.2, 5.2):
        m.box(sx - 0.5, -6.0, 0.12, sx + 0.5, -5.0, 0.7, "Concrete")
        smooth_blob(m, sx, -5.5, 1.2, 0.6, "Leaves", rng, sq=0.8, subdiv=1)
    return m.build(name)


def com_deco_tower(name, seed):
    """Size-2 art deco skyscraper: setbacks, pilasters and a spire. The skyline anchor."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 12, "Paving")
    m.box(-11.2, -11.2, 0.12, 11.2, 11.2, 0.3, "Concrete")
    tiers = [(10.0, 0.0, 10, "Concrete"), (8.0, 1.5, 12, "Concrete"), (6.0, 1.2, 10, "Accent"),
             (4.0, 0.8, 6, "Accent")]
    z = 0.3
    # ground floor: big storefront base
    for (o, u, L) in poly_edges([(-10, -10), (10, -10), (10, 10), (-10, 10)]):
        n = u.cross(UP)
        m.face([o + UP * z, o + u * L + UP * z, o + u * L + UP * 6.0, o + UP * 6.0], "Glass", n)
    for i in range(9):
        x = -10 + i * 2.5
        for (px, py) in ((x, -10), (x, 10), (-10, x), (10, x)):
            m.box(px - 0.3, py - 0.3, z, px + 0.3, py + 0.3, 6.0, "Trim")
    m.box(-10.4, -10.4, 6.0, 10.4, 10.4, 6.8, "Trim")
    m.box(-3.0, -11.6, 4.6, 3.0, -10.0, 5.0, "Metal")  # entrance canopy
    z = 6.8
    for k, (s, c, fl, wall) in enumerate(tiers):
        pts = octagon(s, c) if c > 0 else [(-s, -s), (s, -s), (s, s), (-s, s)]
        ribbon_floors(m, pts, z, fl, 3.6, wall, band=0.5, depth=0.2, pilaster="Trim", pil_pitch=2.2,
                      pil_w=0.4, pil_d=0.35)
        z += fl * 3.6
        m.face([(x, y, z) for x, y in pts], "Roof", UP)
        for o, u, L in poly_edges(pts):
            n = u.cross(UP)
            m.obox(o + n * 0.25 - UP * 0.0 + Vector((0, 0, z)), u * L, -n * 0.5, UP * 1.0, "Trim")
            # deco chevrons on the setback corners
        z += 1.0
    # spire: stacked lit drums + needle
    for (r, h, mat) in ((3.0, 2.5, "Trim"), (2.2, 3.0, "Sign"), (1.4, 3.0, "Trim"), (0.8, 2.0, "Sign")):
        m.cyl(0, 0, z, z + h, r, mat, seg=12)
        z += h
    m.cyl(0, 0, z, z + 14.0, 0.45, "Metal", seg=8, r_top=0.03)
    for (bx, by) in ((-11.0, -11.6), (11.0, -11.6)):
        m.box(bx - 0.8, by - 0.6, 0.12, bx + 0.8, by + 0.6, 0.7, "Concrete")
        smooth_blob(m, bx, by, 1.4, 0.8, "Leaves", rng, subdiv=1)
    return m.build(name)


# --------------------------------------------------------- industrial +4 ---

def container(m, x, y, z, rot90, mat):
    L, W, H = 6.1, 2.44, 2.6
    if rot90:
        m.box(x - W / 2, y - L / 2, z, x + W / 2, y + L / 2, z + H, mat)
    else:
        m.box(x - L / 2, y - W / 2, z, x + L / 2, y + W / 2, z + H, mat)


def ind_container_yard(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Asphalt")
    mats = ["Awning", "Accent", "Metal", "Sign", "Brick"]
    for row, y in enumerate((-1.5, 1.2, 3.9)):
        for col, x in enumerate((-2.4, 3.8)):
            stack = rng.randint(1, 3)
            for s in range(stack):
                container(m, x, y, 0.12 + s * 2.62, False, rng.choice(mats))
    # gantry crane straddling the stacks
    for gx in (-5.6, 5.6):
        for gy in (-3.4, 5.6):
            m.box(gx - 0.25, gy - 0.25, 0.12, gx + 0.25, gy + 0.25, 10.0, "Sign")
        m.box(gx - 0.3, -3.6, 10.0, gx + 0.3, 5.8, 10.8, "Sign")
    m.box(-5.9, 0.6, 10.8, 5.9, 1.6, 11.6, "Sign")
    m.box(-0.8, 0.4, 9.2, 0.8, 1.8, 10.8, "Trim")
    m.cyl(0, 1.1, 6.5, 9.2, 0.04, "Metal", seg=4)
    # gatehouse
    m.box(-5.6, -5.6, 0.12, -3.4, -3.8, 2.6, "Wall", top="Roof")
    m.box(-5.0, -5.62, 1.0, -3.8, -5.58, 2.1, "Glass")
    m.box(-3.2, -5.2, 1.0, 2.0, -5.0, 1.15, "Awning")
    fence(m, 5.8, -5.8, 5.8, 5.8, h=2.0, mat="Metal", post=2.0)
    fence(m, -5.8, 5.8, 5.8, 5.8, h=2.0, mat="Metal", post=2.0)
    return m.build(name)


def ind_silos(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Concrete")
    for i, (x, y) in enumerate(((-3.0, 1.6), (0.0, 1.6), (3.0, 1.6), (-1.5, 4.3), (1.5, 4.3))):
        h = 12.0 + (i % 2) * 2.0
        m.cyl(x, y, 0.12, h, 1.45, "Concrete", seg=16)
        m.cyl(x, y, h, h + 1.2, 1.5, "Metal", seg=16, r_top=0.25)
        for b in range(3):
            m.cyl(x, y, 3.0 + b * 3.4, 3.25 + b * 3.4, 1.5, "Trim", seg=16)
    # head house and conveyor
    m.box(-4.8, -1.0, 0.12, -1.6, 0.4, 16.5, "Metal", top="Roof")
    m.box(-4.8, -1.02, 14.0, -1.6, -0.98, 15.5, "Glass")
    m.obox((-1.6, -0.6, 15.0), (6.0, 0, 0), (0, 0.8, 0), (0, 0, 1.0), "Metal")
    # loading shed + truck bay
    m.box(-5.6, -5.4, 0.12, 1.0, -2.0, 4.5, "Metal", top="Roof")
    m.box(-4.2, -5.42, 0.12, -0.6, -5.38, 3.6, "Door")
    m.box(1.5, -5.6, 0.12, 5.6, -1.4, 0.16, "Asphalt")
    for xx in (2.0, 3.6, 5.2):
        m.box(xx - 0.06, -5.6, 0.16, xx + 0.06, -2.0, 0.17, "MarkingYellow")
    return m.build(name)


def ind_power_plant(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Asphalt")
    # hyperboloid cooling tower
    cx, cy = 2.2, 2.2
    prof = [(0.12, 3.6), (4.0, 3.0), (8.0, 2.5), (11.0, 2.4), (13.0, 2.55), (14.5, 2.75)]
    for (z0, r0), (z1, r1) in zip(prof, prof[1:]):
        m.cyl(cx, cy, z0, z1, r0, "Concrete", seg=20, r_top=r1, cap=False)
    m.cyl(cx, cy, 14.5, 14.8, 2.75, "Trim", seg=20, r_top=2.75, cap=False)
    m.cyl(cx, cy, 14.0, 14.05, 2.6, "Roof", seg=20, r_top=2.6)
    # turbine hall
    m.box(-5.6, -5.6, 0.12, 0.6, -0.4, 7.0, "Metal", top="Roof")
    block_with_windows(m, -5.6, -5.6, 0.6, -0.4, 4.0, 1, 3.0, "Metal", win_h=1.2, sill=0.9, pitch=2.0)
    m.box(-5.65, -5.65, 6.2, 0.65, -0.35, 7.3, "Accent")
    # stack
    m.cyl(-4.2, 3.6, 0.12, 22.0, 0.9, "Concrete", seg=12, r_top=0.7, cap=False)
    for z, mat in ((19.0, "Awning"), (20.5, "Trim"), (21.4, "Awning")):
        m.cyl(-4.2, 3.6, z, z + 0.6, 0.85, mat, seg=12)
    # transformers
    for i in range(3):
        x = -4.6 + i * 1.6
        m.box(x, 0.6, 0.12, x + 1.1, 1.6, 1.8, "Metal")
        for k in range(3):
            m.cyl(x + 0.25 + k * 0.3, 1.1, 1.8, 2.6, 0.06, "Trim", seg=6)
    fence(m, -5.8, -5.8, 5.8, -5.8, h=2.2, mat="Metal", post=2.0, gap=(0.55, 0.75))
    return m.build(name)


def ind_refinery(name, seed):
    """Size-2 industrial: tank farm, distillation columns and a pipe rack."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 12, "Asphalt")
    for i, (x, y, r, h) in enumerate(((-7, 6, 3.4, 7), (0, 6.5, 3.4, 7), (7, 6, 3.0, 9), (-7, -1, 2.4, 6))):
        m.cyl(x, y, 0.12, h, r, "Trim" if i % 2 else "Metal", seg=18)
        m.cyl(x, y, h, h + 0.8, r, "Metal", seg=18, r_top=r * 0.3)
        m.cyl(x, y, 0.12, 0.5, r + 0.6, "Concrete", seg=18)  # bund
    for (x, y, h) in ((2.0, -4.0, 22.0), (5.0, -4.0, 16.0), (8.0, -3.0, 19.0)):
        m.cyl(x, y, 0.12, h, 0.9, "Metal", seg=12)
        for z in range(4, int(h), 5):
            m.cyl(x, y, z, z + 0.25, 1.25, "Awning", seg=12)
        m.cyl(x, y, h, h + 1.5, 0.9, "Metal", seg=12, r_top=0.2)
    # pipe rack
    for x in range(-9, 11, 3):
        m.box(x - 0.15, -8.0, 0.12, x + 0.15, -7.7, 5.0, "Sign")
        m.box(x - 0.15, -9.6, 0.12, x + 0.15, -9.3, 5.0, "Sign")
    for k, z in enumerate((3.4, 4.2, 5.0)):
        for y in (-9.4, -8.9, -8.2):
            m.obox((-9.5, y, z), (20.0, 0, 0), (0, 0.3, 0), (0, 0, 0.3), "Metal" if k != 1 else "Accent")
    m.box(-10.8, -4.0, 0.12, -4.0, 1.5, 5.0, "Wall", top="Roof")
    block_with_windows(m, -10.8, -4.0, -4.0, 1.5, 1.5, 1, 3.0, "Wall", pitch=2.2)
    m.cyl(-2.0, 1.0, 0.12, 26.0, 0.5, "Metal", seg=8, r_top=0.35)  # flare stack
    m.cyl(-2.0, 1.0, 26.0, 27.0, 0.6, "Sign", seg=8)
    fence(m, -11.8, -11.8, 11.8, -11.8, h=2.2, mat="Metal", post=2.4, gap=(0.1, 0.25))
    return m.build(name)


# ------------------------------------------------------------------ civic ---

def civic_fire_station(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Concrete")
    x0, x1, y0, y1 = -5.4, 5.4, -2.6, 5.4
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, 5.0, "Brick", pitch=3.0, win_h=1.4, sill=2.0,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    block_with_windows(m, x0, y0, x1, y1, 5.12, 1, 3.4, "Brick", win_w=1.4, win_h=1.6, pitch=2.2,
                       mullion=True, lintel="Trim")
    # two apparatus bays with roll-up doors
    for bx in (-2.7, 2.7):
        m.box(bx - 2.1, y0 - 0.08, 0.12, bx + 2.1, y0 + 0.01, 4.4, "Awning")
        for i in range(9):
            z = 0.5 + i * 0.45
            m.box(bx - 2.1, y0 - 0.11, z, bx + 2.1, y0 - 0.07, z + 0.06, "Trim")
        m.box(bx - 1.6, y0 - 0.12, 2.6, bx + 1.6, y0 - 0.08, 3.4, "Glass")
        m.box(bx - 2.3, y0 - 0.2, 4.4, bx + 2.3, y0 + 0.02, 4.7, "Trim")
    m.box(-0.25, y0 - 0.2, 0.12, 0.25, y0 + 0.02, 5.1, "Trim")
    m.box(x0, y0 - 0.3, 5.0, x1, y0 + 0.01, 5.25, "Trim")
    top = 8.52
    m.box(x0 - 0.3, y0 - 0.3, top, x1 + 0.3, y1 + 0.3, top + 0.5, "Trim")
    flat_roof(m, x0, y0, x1, y1, top + 0.5, parapet=0.3)
    m.box(-3.5, y0 - 0.4, 5.6, 3.5, y0 - 0.15, 6.6, "Sign")
    # hose tower
    m.box(x1 - 2.6, y1 - 2.6, top, x1 - 0.2, y1 - 0.2, top + 6.0, "Brick")
    block_with_windows(m, x1 - 2.6, y1 - 2.6, x1 - 0.2, y1 - 0.2, top + 3.0, 1, 2.5, "Brick", win_w=0.8,
                       win_h=1.4, pitch=2.0)
    hip_roof(m, x1 - 2.6, y1 - 2.6, x1 - 0.2, y1 - 0.2, top + 6.0, 1.6, mat="Roof", over=0.25)
    # apron with markings
    m.box(-5.6, -6.0, 0.12, 5.6, y0, 0.14, "Asphalt")
    for bx in (-2.7, 2.7):
        for s in (-1, 1):
            m.box(bx + s * 2.0 - 0.08, -6.0, 0.14, bx + s * 2.0 + 0.08, y0, 0.15, "MarkingYellow")
    m.cyl(-5.2, -5.4, 0.12, 9.0, 0.06, "Metal", seg=6)  # flag pole
    m.box(-5.15, -5.43, 7.8, -3.9, -5.37, 8.8, "Awning")
    return m.build(name)


def civic_police(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.2, 5.2, -3.4, 5.2
    m.box(x0, y0, 0.12, x1, y1, 0.9, "Concrete")
    block_with_windows(m, x0, y0, x1, y1, 0.9, 3, 3.3, "Concrete", win_w=1.6, win_h=1.6, pitch=2.3,
                       front_skip=lambda f, c: f == 0 and c in (1, 2))
    top = 0.9 + 3 * 3.3
    # entrance portico with columns
    m.box(-2.6, y0 - 2.4, 0.12, 2.6, y0, 0.9, "Concrete")
    for xx in (-2.2, -0.75, 0.75, 2.2):
        m.cyl(xx, y0 - 1.9, 0.9, 4.6, 0.22, "Trim", seg=10)
    m.box(-2.7, y0 - 2.5, 4.6, 2.7, y0, 5.2, "Trim")
    m.box(-1.0, y0 - 0.06, 0.9, 1.0, y0 + 0.02, 3.4, "Glass")
    m.box(-2.4, y0 - 2.55, 4.7, 2.4, y0 - 2.5, 5.1, "Sign")
    # blue band
    m.box(x0 - 0.05, y0 - 0.05, top - 0.9, x1 + 0.05, y1 + 0.05, top - 0.4, "Accent")
    flat_roof(m, x0, y0, x1, y1, top, parapet=0.5)
    m.cyl(3.6, 3.4, top, top + 6.0, 0.08, "Metal", seg=6)  # radio mast
    m.box(3.3, 3.2, top + 4.5, 3.9, 3.6, top + 5.3, "Metal")
    m.cyl(-4.6, -5.4, 0.12, 8.0, 0.06, "Metal", seg=6)
    m.box(-4.55, -5.43, 6.8, -3.3, -5.37, 7.8, "Accent")
    for xx in (-4.0, 4.0):
        m.box(xx - 0.15, -6.0, 0.12, xx + 0.15, -5.7, 0.9, "Concrete")
    return m.build(name)


def civic_hospital(name, seed):
    """Size 2: tower over a wide podium, helipad, ambulance canopy, red cross signs."""
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 12, "Paving")
    m.box(-11, -9.5, 0.12, 11, 10.5, 0.12, "Paving")
    block_with_windows(m, -11, -8.0, 11, 10.5, 0.12, 2, 4.0, "Wall", win_w=2.2, win_h=1.8, pitch=3.0,
                       front_skip=lambda f, c: f == 0 and c in (3, 4))
    m.box(-3.5, -8.05, 0.12, 3.5, -7.98, 3.6, "Glass")
    m.box(-11.2, -8.2, 8.12, 11.2, 10.7, 8.6, "Trim")
    flat_roof(m, -11, -8.0, 11, 10.5, 8.6, parapet=0.4)
    pts = [(-7.0, -4.0), (7.0, -4.0), (7.0, 6.0), (-7.0, 6.0)]
    ribbon_floors(m, pts, 8.6, 8, 3.4, "Wall", band=0.5, pilaster="Trim", pil_pitch=3.5)
    top = 8.6 + 8 * 3.4
    poly_cap(m, pts, top, "Roof", rim="Trim", rim_h=0.6)
    # helipad
    m.cyl(0, 1.0, top + 0.6, top + 0.9, 4.2, "Asphalt", seg=24)
    m.cyl(0, 1.0, top + 0.9, top + 0.92, 3.6, "Marking", seg=24)
    m.cyl(0, 1.0, top + 0.92, top + 0.94, 3.3, "Asphalt", seg=24)
    for (x0, y0, x1, y1) in ((-1.4, -0.6, -0.9, 2.6), (0.9, -0.6, 1.4, 2.6), (-0.9, 0.75, 0.9, 1.25)):
        m.box(x0, y0, top + 0.94, x1, y1, top + 0.96, "Marking")
    for (x, y, nrm) in ((0, -4.05, "S"), (7.05, 1.0, "E")):
        if nrm == "S":
            m.box(-1.5, -4.4, top - 3.5, 1.5, -4.0, top - 0.5, "Trim")
            m.box(-0.35, -4.45, top - 3.2, 0.35, -4.4, top - 0.8, "Sign")
            m.box(-1.2, -4.45, top - 2.35, 1.2, -4.4, top - 1.65, "Sign")
        else:
            m.box(7.0, -0.5, top - 3.5, 7.4, 2.5, top - 0.5, "Trim")
            m.box(7.4, 0.65, top - 3.2, 7.45, 1.35, top - 0.8, "Sign")
            m.box(7.4, -0.2, top - 2.35, 7.45, 2.2, top - 1.65, "Sign")
    # ambulance canopy + drop-off loop
    m.box(-10.5, -11.6, 0.12, -4.0, -8.0, 0.14, "Asphalt")
    for xx in (-10.0, -4.5):
        m.box(xx - 0.2, -11.2, 0.12, xx + 0.2, -10.8, 3.6, "Trim")
    m.box(-10.6, -11.6, 3.6, -3.9, -8.0, 4.0, "Trim", top="Roof")
    m.box(-10.0, -11.65, 3.62, -4.5, -11.6, 3.95, "Awning")
    trees_row(m, rng, [(5.0, -10.5), (8.0, -10.5), (11.0, -10.5)], r=1.0)
    return m.build(name)


def civic_school(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Grass")
    x0, x1, y0, y1 = -5.4, 2.0, -1.6, 5.4
    block_with_windows(m, x0, y0, x1, y1, 0.12, 2, 3.6, "Brick", win_w=2.0, win_h=1.9, pitch=2.5,
                       mullion=True, lintel="Trim", front_skip=lambda f, c: f == 0 and c == 1)
    m.box(-2.9, y0 - 0.06, 0.12, -1.3, y0 + 0.02, 2.6, "Door")
    m.box(-3.3, y0 - 1.4, 2.8, -0.9, y0, 3.05, "Trim")
    top = 0.12 + 7.2
    m.box(x0 - 0.2, y0 - 0.2, top, x1 + 0.2, y1 + 0.2, top + 0.4, "Trim")
    hip_roof(m, x0, y0, x1, y1, top + 0.4, 2.0, mat="Roof", over=0.4)
    # clock gable on the front
    m.box(-2.9, y0 - 0.3, top + 0.4, -1.3, y0 + 0.2, top + 2.6, "Brick")
    m.obox((-2.6, y0 - 0.35, top + 1.0), (1.0, 0, 0), (0, 0.06, 0), (0, 0, 1.0), "Trim")
    m.box(-2.12, y0 - 0.4, top + 1.45, -2.08, y0 - 0.35, top + 1.85, "Roof")
    gable_roof(m, -2.9, y0 - 0.3, -1.3, y0 + 0.2, top + 2.6, 0.9, mat="Roof", over=0.15, along_x=False,
               gable="Brick")
    # playground court
    m.box(2.6, -5.6, 0.12, 5.7, 5.6, 0.14, "Asphalt")
    for (a, b, c, d) in ((2.8, -5.4, 5.5, -5.3), (2.8, 5.3, 5.5, 5.4), (2.8, -0.05, 5.5, 0.05),
                         (2.8, -5.4, 2.9, 5.4), (5.4, -5.4, 5.5, 5.4)):
        m.box(a, b, 0.14, c, d, 0.15, "Marking")
    m.cyl(4.15, 0.0, 0.14, 0.15, 1.0, "Marking", seg=16)
    m.cyl(4.15, 0.0, 0.15, 0.155, 0.9, "Asphalt", seg=16)
    for yy in (-5.0, 5.0):  # hoops
        m.cyl(4.15, yy, 0.14, 3.0, 0.06, "Metal", seg=6)
        m.box(3.6, yy - 0.05, 2.7, 4.7, yy + 0.05, 3.5, "Trim")
    # swing set
    for xx in (-5.0, -2.2):
        m.box(xx - 0.06, -4.2, 0.12, xx + 0.06, -4.08, 2.4, "Accent")
    m.box(-5.06, -4.2, 2.4, -2.14, -4.08, 2.52, "Accent")
    for xx in (-4.3, -2.9):
        m.box(xx - 0.25, -4.25, 0.6, xx + 0.25, -4.03, 0.66, "Awning")
    m.cyl(-5.4, -5.4, 0.12, 9.0, 0.06, "Metal", seg=6)
    m.box(-5.35, -5.43, 7.8, -4.1, -5.37, 8.8, "Awning")
    fence(m, -5.8, -5.8, 5.8, -5.8, h=1.2, mat="Metal", post=2.0, gap=(0.15, 0.3))
    return m.build(name)


def civic_park(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Grass")
    # cross paths and a central fountain
    m.box(-0.9, -6.0, 0.12, 0.9, 6.0, 0.15, "Paving")
    m.box(-6.0, -0.9, 0.12, 6.0, 0.9, 0.15, "Paving")
    m.cyl(0, 0, 0.12, 0.16, 3.0, "Paving", seg=20)
    m.cyl(0, 0, 0.16, 0.7, 2.2, "Concrete", seg=20)
    m.cyl(0, 0, 0.55, 0.6, 1.95, "Water", seg=20)
    m.cyl(0, 0, 0.6, 1.6, 0.35, "Concrete", seg=10)
    m.cyl(0, 0, 1.6, 1.8, 0.9, "Concrete", seg=14)
    m.cyl(0, 0, 1.75, 1.8, 0.75, "Water", seg=14)
    m.cyl(0, 0, 1.8, 2.6, 0.12, "Water", seg=8, r_top=0.02)
    # trees in the four quadrants, flower beds, benches
    for qx in (-1, 1):
        for qy in (-1, 1):
            x, y = qx * 3.6, qy * 3.6
            m.cyl(x, y, 0.12, 2.2, 0.2, "Bark", seg=6, r_top=0.13)
            r = rng.uniform(1.5, 1.9)
            smooth_blob(m, x, y, 2.2 + r * 0.8, r, "Leaves", rng, sq=0.9, subdiv=2)
            smooth_blob(m, x + qx * 0.8, y - qy * 0.6, 2.0 + r * 0.6, r * 0.65, "Leaves", rng, subdiv=1)
            bx, by = qx * 1.6, qy * 2.6
            m.box(bx - 0.25, by - 0.75, 0.12, bx + 0.25, by + 0.75, 0.55, "Door")
            m.box(bx + qx * 0.2 - 0.06, by - 0.75, 0.55, bx + qx * 0.2 + 0.06, by + 0.75, 1.0, "Door")
            fx, fy = qx * 5.2, qy * 1.8
            m.box(fx - 0.6, fy - 0.6, 0.12, fx + 0.6, fy + 0.6, 0.35, "Concrete")
            smooth_blob(m, fx, fy, 0.5, 0.5, "Awning", rng, sq=0.6, subdiv=1, jitter=0.15)
    for (x, y) in ((-5.4, 5.4), (5.4, -5.4)):
        m.cyl(x, y, 0.12, 4.0, 0.07, "Roof", seg=6)
        m.cyl(x, y, 4.0, 4.5, 0.25, "Lamp", seg=8)
    return m.build(name)


def civic_parking(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Asphalt")
    for row, y0 in enumerate((-4.8, 0.6)):
        for i in range(5):
            x = -5.0 + i * 2.5
            m.box(x - 0.05, y0, 0.12, x + 0.05, y0 + 4.6, 0.13, "Marking")
    m.box(-5.6, -0.5, 0.12, 5.6, 0.5, 0.35, "Concrete")
    for x in (-4.0, 0.0, 4.0):
        smooth_blob(m, x, 0.0, 0.8, 0.6, "Leaves", rng, sq=0.7, subdiv=1)
    m.box(4.2, -5.8, 0.12, 5.6, -4.8, 2.6, "Wall", top="Roof")
    m.box(4.25, -5.82, 1.0, 5.55, -5.78, 2.1, "Glass")
    for (x, y) in ((-5.6, -5.6), (-5.6, 5.6), (5.6, 5.6)):
        m.cyl(x, y, 0.12, 6.0, 0.08, "Roof", seg=6)
        m.box(x - 0.4 if x > 0 else x, y - 0.2, 5.8, x if x > 0 else x + 0.4, y + 0.2, 6.0, "Lamp")
    m.cyl(-4.0, -5.4, 0.12, 4.5, 0.08, "Metal", seg=6)
    m.box(-4.6, -5.45, 3.5, -3.4, -5.35, 4.7, "Sign")
    return m.build(name)


# ------------------------------------------------------------------ props ---

def p_bench(name):
    m = Mesh()
    for x in (-0.75, 0.75):
        m.box(x - 0.05, -0.25, 0.0, x + 0.05, 0.25, 0.45, "Metal")
        m.box(x - 0.05, 0.18, 0.45, x + 0.05, 0.25, 0.9, "Metal")
    for k in range(3):
        y = -0.22 + k * 0.15
        m.box(-0.9, y, 0.45, 0.9, y + 0.12, 0.5, "Door")
    for k in range(2):
        z = 0.6 + k * 0.17
        m.box(-0.9, 0.2, z, 0.9, 0.26, z + 0.12, "Door")
    return m.build(name)


def p_hydrant(name):
    m = Mesh()
    m.cyl(0, 0, 0.0, 0.08, 0.17, "Awning", seg=10)
    m.cyl(0, 0, 0.08, 0.6, 0.12, "Awning", seg=10)
    m.cyl(0, 0, 0.6, 0.75, 0.13, "Awning", seg=10, r_top=0.06)
    m.cyl(0, 0, 0.75, 0.8, 0.04, "Awning", seg=6)
    for a in (0, math.pi):
        d = Vector((math.cos(a), math.sin(a), 0))
        m.obox(d * 0.1 + Vector((-0.05, -0.05, 0.4)), d * 0.1, Vector((-d.y, d.x, 0)) * 0.1, UP * 0.1, "Trim")
    return m.build(name)


def p_trash_bin(name):
    m = Mesh()
    m.cyl(0, 0, 0.0, 0.85, 0.28, "Metal", seg=10, r_top=0.3)
    m.cyl(0, 0, 0.85, 0.95, 0.32, "Roof", seg=10, r_top=0.25)
    m.cyl(0, 0, 0.3, 0.38, 0.29, "Accent", seg=10)
    return m.build(name)


def p_mailbox(name):
    m = Mesh()
    for x in (-0.18, 0.18):
        m.box(x - 0.03, -0.18, 0.0, x + 0.03, 0.18, 0.3, "Roof")
    m.box(-0.25, -0.22, 0.3, 0.25, 0.22, 1.05, "Accent")
    m.obox((-0.25, 0.22, 1.05), (0.5, 0, 0), (0, -0.44, 0), (0, 0, 0.15), "Accent")
    m.box(-0.15, -0.23, 0.85, 0.15, -0.21, 0.92, "Roof")
    return m.build(name)


def p_bus_stop(name):
    """Shelter facing -Y (the road side), 3.6 m wide."""
    m = Mesh()
    m.box(-1.8, -0.1, 0.0, 1.8, 1.3, 0.05, "Paving")
    for x in (-1.75, 1.75):
        m.box(x - 0.05, 1.0, 0.05, x + 0.05, 1.1, 2.5, "Metal")
        m.box(x - 0.03, 0.0, 0.3, x + 0.03, 1.05, 2.3, "Glass")
    m.box(-1.75, 1.05, 0.3, 1.75, 1.1, 2.3, "Glass")
    m.box(-1.9, -0.1, 2.5, 1.9, 1.3, 2.62, "Roof", sides="Trim")
    m.box(-1.2, 0.75, 0.45, 1.2, 1.0, 0.52, "Door")
    m.box(1.0, 1.1, 0.6, 1.7, 1.15, 2.1, "Sign")  # ad panel
    m.cyl(-2.3, 0.0, 0.0, 2.8, 0.04, "Metal", seg=6)
    m.box(-2.55, -0.03, 2.3, -2.05, 0.03, 2.8, "Sign")
    return m.build(name)


def p_planter(name):
    rng = random.Random(7)
    m = Mesh()
    m.box(-0.6, -0.6, 0.0, 0.6, 0.6, 0.55, "Concrete")
    m.box(-0.5, -0.5, 0.55, 0.5, 0.5, 0.56, "Bark")
    smooth_blob(m, 0, 0, 0.9, 0.5, "Leaves", rng, sq=0.8, subdiv=1)
    return m.build(name)


def p_billboard(name):
    """Two-legged roadside billboard, panel facing -Y."""
    m = Mesh()
    for x in (-2.0, 2.0):
        m.box(x - 0.15, -0.15, 0.0, x + 0.15, 0.15, 5.5, "Metal")
    m.box(-3.2, -0.2, 5.0, 3.2, 0.2, 8.4, "Trim")
    m.box(-3.0, -0.24, 5.2, 3.0, -0.2, 8.2, "Sign")
    m.box(-3.2, -1.2, 4.9, 3.2, -0.2, 5.0, "Metal")
    for x in (-2.0, 0.0, 2.0):
        m.box(x - 0.05, -1.1, 8.4, x + 0.05, -0.2, 8.5, "Metal")
        m.box(x - 0.15, -1.2, 8.3, x + 0.15, -0.9, 8.45, "Lamp")
    return m.build(name)


def p_bollard(name):
    m = Mesh()
    m.cyl(0, 0, 0.0, 0.85, 0.1, "Roof", seg=8)
    m.cyl(0, 0, 0.85, 0.95, 0.1, "Roof", seg=8, r_top=0.03)
    m.cyl(0, 0, 0.65, 0.72, 0.105, "Marking", seg=8)
    return m.build(name)


def p_news_box(name):
    m = Mesh()
    m.box(-0.25, -0.22, 0.0, 0.25, 0.22, 0.45, "Roof")
    m.box(-0.28, -0.25, 0.45, 0.28, 0.25, 1.1, "Accent")
    m.box(-0.2, -0.26, 0.7, 0.2, -0.25, 1.0, "Glass")
    return m.build(name)


def p_power_pole(name):
    m = Mesh()
    m.cyl(0, 0, 0.0, 9.0, 0.14, "Bark", seg=8, r_top=0.11)
    m.box(-1.3, -0.07, 8.0, 1.3, 0.07, 8.18, "Bark")
    for x in (-1.1, -0.4, 0.4, 1.1):
        m.cyl(x, 0, 8.18, 8.4, 0.05, "Trim", seg=6)
    m.cyl(0.0, 0.3, 6.6, 7.4, 0.25, "Metal", seg=8)
    return m.build(name)


def p_tree_puffy(name, seed, size=1.0):
    """Soft, rounded stylized tree: tapered trunk, two limbs, clustered smooth canopy."""
    rng = random.Random(seed)
    m = Mesh()
    h = rng.uniform(2.4, 3.0) * size
    m.cyl(0, 0, 0, h, 0.24 * size, "Bark", seg=7, r_top=0.15 * size)
    tips = []
    for k in range(2):
        a = rng.uniform(0, math.tau) + k * math.pi
        d = Vector((math.cos(a), math.sin(a), 0))
        p0 = Vector((0, 0, h * 0.8))
        p1 = p0 + d * 1.0 * size + UP * 1.1 * size
        side = Vector((-d.y, d.x, 0)) * 0.09 * size
        m.obox(p0 - side, p1 - p0, side * 2, Vector((0, 0, 0.18)) * size, "Bark")
        tips.append(p1)
    R = rng.uniform(1.9, 2.2) * size
    c = Vector((0, 0, h + R * 0.7))
    smooth_blob(m, c.x, c.y, c.z, R, "Leaves", rng, sq=0.85, subdiv=2, jitter=0.06)
    for p in tips:
        smooth_blob(m, p.x * 1.2, p.y * 1.2, p.z + R * 0.35, R * 0.62, "Leaves", rng, sq=0.85, subdiv=1)
    for _ in range(2):
        a = rng.uniform(0, math.tau)
        smooth_blob(m, math.cos(a) * R * 0.5, math.sin(a) * R * 0.5, c.z + R * 0.45, R * 0.55, "Leaves",
                    rng, sq=0.85, subdiv=1)
    return m.build(name)


def p_tree_cypress(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    m.cyl(0, 0, 0, 1.0, 0.16, "Bark", seg=6)
    smooth_blob(m, 0, 0, 3.6, 1.05, "Leaves", rng, sq=3.0, subdiv=2, jitter=0.05)
    return m.build(name)


def p_hedge(name):
    """3 m hedge segment along X, for lot edges and medians."""
    rng = random.Random(9)
    m = Mesh()
    m.box(-1.5, -0.45, 0.0, 1.5, 0.45, 0.9, "Leaves")
    for k in range(4):
        smooth_blob(m, -1.1 + k * 0.73, 0, 0.95, 0.42, "Leaves", rng, sq=0.5, subdiv=1)
    return m.build(name)


# ----------------------------------------------------------------- driver ---

JOBS = [
    ("r_1_1_e", "buildings", lambda n: res_modern(n, 101)),
    ("r_1_1_f", "buildings", lambda n: res_duplex(n, 102)),
    ("r_2_1_e", "buildings", lambda n: res_brownstones(n, 103)),
    ("r_3_1_d", "buildings", lambda n: res_stepped(n, 104)),
    ("r_3_2_c", "buildings", lambda n: res_twin_towers(n, 105)),
    ("c_1_1_e", "buildings", lambda n: com_diner(n, 111)),
    ("c_2_1_d", "buildings", lambda n: com_loft(n, 112)),
    ("c_3_1_d", "buildings", lambda n: com_glass_tower(n, 113, 20)),
    ("c_3_2_c", "buildings", lambda n: com_deco_tower(n, 114)),
    ("i_1_1_d", "buildings", lambda n: ind_container_yard(n, 121)),
    ("i_2_1_d", "buildings", lambda n: ind_silos(n, 122)),
    ("i_3_1_c", "buildings", lambda n: ind_power_plant(n, 123)),
    ("i_3_2_b", "buildings", lambda n: ind_refinery(n, 124)),
    ("fire_station", "civic", lambda n: civic_fire_station(n, 131)),
    ("police_station", "civic", lambda n: civic_police(n, 132)),
    ("hospital", "civic", lambda n: civic_hospital(n, 133)),
    ("school", "civic", lambda n: civic_school(n, 134)),
    ("park", "civic", lambda n: civic_park(n, 135)),
    ("parking_lot", "civic", lambda n: civic_parking(n, 136)),
    ("bench", "props", p_bench), ("hydrant", "props", p_hydrant), ("trash_bin", "props", p_trash_bin),
    ("mailbox", "props", p_mailbox), ("bus_stop", "props", p_bus_stop), ("planter", "props", p_planter),
    ("billboard", "props", p_billboard), ("bollard", "props", p_bollard), ("news_box", "props", p_news_box),
    ("power_pole", "props", p_power_pole), ("hedge", "props", p_hedge),
    ("tree_puffy_a", "props", lambda n: p_tree_puffy(n, 201)),
    ("tree_puffy_b", "props", lambda n: p_tree_puffy(n, 202, 1.2)),
    ("tree_puffy_c", "props", lambda n: p_tree_puffy(n, 203, 0.8)),
    ("tree_cypress", "props", lambda n: p_tree_cypress(n, 204)),
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
    for name, sub, fn in JOBS:
        if only and name not in only and sub not in only:
            continue
        ob = fn(name)
        total += sum(len(p.vertices) - 2 for p in ob.data.polygons)
        K.export(ob, sub)
        bpy.data.objects.remove(ob, do_unlink=True)
    print(f"done, {total} tris total -> {K.OUT}")


if __name__ == "__main__":
    main()
