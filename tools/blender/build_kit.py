"""Procedural stylized art kit for MAYOR / STREET.

Generates buildings (3 zones x 3 growth stages, several variants), road tiles,
street lamps, trees and cars as .glb files the Godot project imports.

Run headless:  python3 tools/blender/build_kit.py  (with the `bpy` pip module)
         or:   blender -b -P tools/blender/build_kit.py

Conventions (Blender space, Z up, exported to glTF Y up):
  * +Y in Blender is north (Godot -Z). Buildings face south (Blender -Y, Godot +Z),
    which is the side the game turns toward the road.
  * One tile is 12 m. Origins sit at the tile centre, ground at z = 0.
  * Material names matter: Godot swaps each one for a shared stylized shader.
"""
import math
import os
import random
import sys

import bpy  # noqa: E402  (bpy must load before bmesh)
import bmesh
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "kit"))

TILE = 12.0
UP = Vector((0, 0, 1))

MAT_COLORS = {
    "Wall": (0.92, 0.88, 0.80), "Accent": (0.75, 0.55, 0.45), "Brick": (0.62, 0.30, 0.22),
    "Concrete": (0.70, 0.70, 0.68), "Trim": (0.95, 0.94, 0.90), "Roof": (0.25, 0.26, 0.28),
    "RoofTile": (0.55, 0.22, 0.16), "Glass": (0.20, 0.35, 0.50), "Door": (0.35, 0.22, 0.14),
    "Metal": (0.60, 0.63, 0.66), "Awning": (0.80, 0.20, 0.20), "Sign": (1.0, 0.8, 0.3),
    "Grass": (0.30, 0.55, 0.22), "Paving": (0.72, 0.70, 0.66), "Asphalt": (0.18, 0.18, 0.20),
    "Sidewalk": (0.68, 0.67, 0.64), "Curb": (0.80, 0.80, 0.78), "Marking": (0.95, 0.95, 0.90),
    "MarkingYellow": (0.95, 0.75, 0.15), "Bark": (0.35, 0.24, 0.16), "Leaves": (0.30, 0.55, 0.20),
    "Lamp": (1.0, 0.9, 0.7), "CarBody": (0.8, 0.1, 0.1), "Tire": (0.08, 0.08, 0.08),
    "Headlight": (1.0, 1.0, 0.9), "Taillight": (0.9, 0.05, 0.05), "Water": (0.2, 0.5, 0.7),
}
MAT_NAMES = list(MAT_COLORS.keys())


class Mesh:
    """Tiny bmesh wrapper: every face is placed with an explicit outward normal."""

    def __init__(self):
        self.bm = bmesh.new()

    def face(self, pts, mat, normal=None, smooth=False):
        pts = [Vector(p) for p in pts]
        if normal is not None:
            n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
            if n.length < 1e-9 and len(pts) > 3:
                n = (pts[2] - pts[0]).cross(pts[3] - pts[0])
            if n.dot(Vector(normal)) < 0:
                pts.reverse()
        verts = [self.bm.verts.new(p) for p in pts]
        f = self.bm.faces.new(verts)
        f.material_index = MAT_NAMES.index(mat)
        f.smooth = smooth
        return f

    def quad(self, o, u, v, mat, normal=None):
        o, u, v = Vector(o), Vector(u), Vector(v)
        self.face([o, o + u, o + u + v, o + v], mat, normal if normal is not None else u.cross(v))

    def obox(self, o, u, v, w, mat, top=None, bottom=False, sides=None):
        """Oriented box from corner o spanned by edge vectors u, v, w (w is 'up')."""
        o, u, v, w = Vector(o), Vector(u), Vector(v), Vector(w)
        c = o + (u + v + w) * 0.5
        side = sides or mat
        faces = [
            (o + w, u, v, top or mat),        # top
            (o, u, w, side), (o + v, u, w, side),
            (o, v, w, side), (o + u, v, w, side),
        ]
        if bottom:
            faces.append((o, u, v, mat))
        for fo, fu, fv, m in faces:
            ctr = fo + (fu + fv) * 0.5
            self.quad(fo, fu, fv, m, ctr - c)

    def box(self, x0, y0, z0, x1, y1, z1, mat, top=None, bottom=False, sides=None):
        self.obox((x0, y0, z0), (x1 - x0, 0, 0), (0, y1 - y0, 0), (0, 0, z1 - z0), mat, top, bottom, sides)

    def cyl(self, cx, cy, z0, z1, r, mat, seg=8, top=None, r_top=None, smooth=True, cap=True):
        r_top = r if r_top is None else r_top
        ring0, ring1 = [], []
        for i in range(seg):
            a = 2 * math.pi * i / seg
            ring0.append(Vector((cx + r * math.cos(a), cy + r * math.sin(a), z0)))
            ring1.append(Vector((cx + r_top * math.cos(a), cy + r_top * math.sin(a), z1)))
        for i in range(seg):
            j = (i + 1) % seg
            mid = (ring0[i] + ring0[j]) * 0.5
            self.face([ring0[i], ring0[j], ring1[j], ring1[i]], mat, mid - Vector((cx, cy, z0)), smooth)
        if cap and r_top > 0.001:
            self.face(ring1, top or mat, (0, 0, 1))

    def blob(self, cx, cy, cz, r, mat, rng, sq=1.0, subdiv=2, jitter=0.12):
        tmp = bmesh.new()
        bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=r)
        for v in tmp.verts:
            k = 1.0 + rng.uniform(-jitter, jitter)
            v.co = Vector((v.co.x * k + cx, v.co.y * k + cy, v.co.z * k * sq + cz))
        for f in tmp.faces:
            pts = [v.co.copy() for v in f.verts]
            ctr = sum(pts, Vector()) / len(pts)
            self.face(pts, mat, ctr - Vector((cx, cy, cz)))
        tmp.free()

    def build(self, name):
        me = bpy.data.meshes.new(name)
        bmesh.ops.remove_doubles(self.bm, verts=self.bm.verts, dist=0.0005)
        self.bm.to_mesh(me)
        self.bm.free()
        used = sorted({p.material_index for p in me.polygons})
        # Compact material slots to the ones actually used.
        remap = {old: new for new, old in enumerate(used)}
        for name_i in used:
            me.materials.append(MATERIALS[MAT_NAMES[name_i]])
        for p in me.polygons:
            p.material_index = remap[p.material_index]
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob


# ---------------------------------------------------------------- facades ---

def facade(m, o, u, width, z0, floors, fh, ww, wh, sill, cols, wall, glass="Glass",
           depth=0.16, frame="Trim", mullion=False, sills=True, skip=None, lintel=None):
    """Wall with recessed windows. o: bottom-left corner seen from outside; u: unit
    vector along the facade. Normal is u x up. skip(floor, col) -> True leaves a plain
    wall panel (used for doors and storefronts)."""
    o, u = Vector(o), Vector(u).normalized()
    n = u.cross(UP)
    pitch = width / cols

    def P(a, h, d=0.0):
        return o + u * a + UP * h - n * d

    for f in range(floors):
        zb = z0 + f * fh
        zs, zt, ze = zb + sill, zb + sill + wh, zb + fh
        m.face([P(0, zb), P(width, zb), P(width, zs), P(0, zs)], wall, n)
        m.face([P(0, zt), P(width, zt), P(width, ze), P(0, ze)], lintel or wall, n)
        prev = 0.0
        for c in range(cols):
            a0 = pitch * (c + 0.5) - ww / 2
            a1 = a0 + ww
            m.face([P(prev, zs), P(a0, zs), P(a0, zt), P(prev, zt)], wall, n)
            prev = a1
            if skip and skip(f, c):
                m.face([P(a0, zs), P(a1, zs), P(a1, zt), P(a0, zt)], wall, n)
                continue
            d = depth
            m.face([P(a0, zs), P(a1, zs), P(a1, zs, d), P(a0, zs, d)], frame, UP)        # sill reveal
            m.face([P(a0, zt), P(a1, zt), P(a1, zt, d), P(a0, zt, d)], frame, -UP)       # head reveal
            m.face([P(a0, zs), P(a0, zt), P(a0, zt, d), P(a0, zs, d)], frame, u)         # left reveal
            m.face([P(a1, zs), P(a1, zt), P(a1, zt, d), P(a1, zs, d)], frame, -u)        # right reveal
            m.face([P(a0, zs, d), P(a1, zs, d), P(a1, zt, d), P(a0, zt, d)], glass, n)
            if mullion:
                mid = (a0 + a1) / 2
                m.obox(P(mid - 0.03, zs, d - 0.02), u * 0.06, n * 0.04, UP * wh, frame)
            if sills:
                m.obox(P(a0 - 0.08, zs - 0.08), u * (ww + 0.16), n * 0.12, UP * 0.08, frame)
        m.face([P(prev, zs), P(width, zs), P(width, zt), P(prev, zt)], wall, n)


def sides_of(x0, y0, x1, y1):
    """(origin, u, width, name) for the four walls of a rectangle, outward winding."""
    return [
        ((x0, y0), (1, 0, 0), x1 - x0, "S"),   # front, faces -Y (south)
        ((x1, y0), (0, 1, 0), y1 - y0, "E"),
        ((x1, y1), (-1, 0, 0), x1 - x0, "N"),
        ((x0, y1), (0, -1, 0), y1 - y0, "W"),
    ]


def block_with_windows(m, x0, y0, x1, y1, z0, floors, fh, wall, win_w=1.3, win_h=1.5,
                       sill=0.9, pitch=2.6, front_skip=None, all_skip=None, mullion=False,
                       glass="Glass", lintel=None, depth=0.16):
    for (ox, oy), u, w, name in sides_of(x0, y0, x1, y1):
        cols = max(1, int(w / pitch))
        sk = front_skip if name == "S" else None
        if all_skip:
            base = sk
            sk = (lambda f, c, b=base, nm=name, cs=cols: (b and b(f, c)) or all_skip(nm, f, c, cs))
        facade(m, (ox, oy, 0.0), u, w, z0, floors, fh, win_w, win_h, sill, cols, wall,
               glass=glass, skip=sk, mullion=mullion, lintel=lintel, depth=depth)


def flat_roof(m, x0, y0, x1, y1, z, parapet=0.6, rim="Trim", roof="Roof", t=0.3):
    m.box(x0, y0, z, x1, y1, z + 0.03, roof, top=roof)  # sits above any cornice top (no z-fighting)
    m.box(x0 - 0.15, y0 - 0.15, z - 0.25, x1 + 0.15, y0 + t, z + parapet, rim)
    m.box(x0 - 0.15, y1 - t, z - 0.25, x1 + 0.15, y1 + 0.15, z + parapet, rim)
    m.box(x0 - 0.15, y0 + t, z - 0.25, x0 + t, y1 - t, z + parapet, rim)
    m.box(x1 - t, y0 + t, z - 0.25, x1 + 0.15, y1 - t, z + parapet, rim)


def roof_clutter(m, rng, x0, y0, x1, y1, z, n=3, tank=False):
    for _ in range(n):
        w, d, h = rng.uniform(1.0, 2.2), rng.uniform(1.0, 2.0), rng.uniform(0.6, 1.4)
        cx = rng.uniform(x0 + 1.2 + w / 2, x1 - 1.2 - w / 2) if x1 - x0 > w + 2.5 else (x0 + x1) / 2
        cy = rng.uniform(y0 + 1.2 + d / 2, y1 - 1.2 - d / 2) if y1 - y0 > d + 2.5 else (y0 + y1) / 2
        m.box(cx - w / 2, cy - d / 2, z, cx + w / 2, cy + d / 2, z + h, "Metal")
        m.cyl(cx, cy, z + h, z + h + 0.25, min(w, d) * 0.3, "Metal", seg=8)
    if tank:
        cx, cy = x1 - 2.2, y1 - 2.2
        for lx in (-0.7, 0.7):
            for ly in (-0.7, 0.7):
                m.box(cx + lx - 0.08, cy + ly - 0.08, z, cx + lx + 0.08, cy + ly + 0.08, z + 1.6, "Metal")
        m.cyl(cx, cy, z + 1.6, z + 3.6, 1.05, "Door", seg=12, top="Door")
        m.cyl(cx, cy, z + 3.6, z + 4.3, 1.1, "Roof", seg=12, r_top=0.05)


def gable_roof(m, x0, y0, x1, y1, z, h, mat="RoofTile", gable="Wall", over=0.45, along_x=True):
    """Ridge along X (gables on the E/W ends) when along_x, else along Y."""
    if along_x:
        ym = (y0 + y1) / 2
        a, b = x0 - over, x1 + over
        m.face([(a, y0 - over, z - 0.2), (b, y0 - over, z - 0.2), (b, ym, z + h), (a, ym, z + h)], mat, (0, -1, 1))
        m.face([(a, y1 + over, z - 0.2), (b, y1 + over, z - 0.2), (b, ym, z + h), (a, ym, z + h)], mat, (0, 1, 1))
        m.face([(a, y0 - over, z - 0.2), (a, y0 - over, z - 0.35), (b, y0 - over, z - 0.35), (b, y0 - over, z - 0.2)], "Trim", (0, -1, 0))
        m.face([(a, y1 + over, z - 0.2), (a, y1 + over, z - 0.35), (b, y1 + over, z - 0.35), (b, y1 + over, z - 0.2)], "Trim", (0, 1, 0))
        m.face([(a, y0 - over, z - 0.35), (b, y0 - over, z - 0.35), (b, ym, z + h - 0.15), (a, ym, z + h - 0.15)], "Trim", (0, 0, -1))
        m.face([(a, y1 + over, z - 0.35), (b, y1 + over, z - 0.35), (b, ym, z + h - 0.15), (a, ym, z + h - 0.15)], "Trim", (0, 0, -1))
        m.face([(x0, y0, z), (x0, y1, z), (x0, ym, z + h - 0.1)], gable, (-1, 0, 0))
        m.face([(x1, y0, z), (x1, y1, z), (x1, ym, z + h - 0.1)], gable, (1, 0, 0))
    else:
        xm = (x0 + x1) / 2
        a, b = y0 - over, y1 + over
        m.face([(x0 - over, a, z - 0.2), (x0 - over, b, z - 0.2), (xm, b, z + h), (xm, a, z + h)], mat, (-1, 0, 1))
        m.face([(x1 + over, a, z - 0.2), (x1 + over, b, z - 0.2), (xm, b, z + h), (xm, a, z + h)], mat, (1, 0, 1))
        m.face([(x0 - over, a, z - 0.35), (x0 - over, b, z - 0.35), (xm, b, z + h - 0.15), (xm, a, z + h - 0.15)], "Trim", (0, 0, -1))
        m.face([(x1 + over, a, z - 0.35), (x1 + over, b, z - 0.35), (xm, b, z + h - 0.15), (xm, a, z + h - 0.15)], "Trim", (0, 0, -1))
        m.face([(x0 - over, a, z - 0.2), (x0 - over, a, z - 0.35), (x0 - over, b, z - 0.35), (x0 - over, b, z - 0.2)], "Trim", (-1, 0, 0))
        m.face([(x1 + over, a, z - 0.2), (x1 + over, a, z - 0.35), (x1 + over, b, z - 0.35), (x1 + over, b, z - 0.2)], "Trim", (1, 0, 0))
        m.face([(x0, y0, z), (x1, y0, z), (xm, y0, z + h - 0.1)], gable, (0, -1, 0))
        m.face([(x0, y1, z), (x1, y1, z), (xm, y1, z + h - 0.1)], gable, (0, 1, 0))


def hip_roof(m, x0, y0, x1, y1, z, h, mat="RoofTile", over=0.45):
    a0, b0, a1, b1 = x0 - over, y0 - over, x1 + over, y1 + over
    inset = min(a1 - a0, b1 - b0) / 2
    r0, r1 = a0 + inset, a1 - inset
    ym = (b0 + b1) / 2
    zr = z + h
    zl = z - 0.2
    m.face([(a0, b0, zl), (a1, b0, zl), (r1, ym, zr), (r0, ym, zr)], mat, (0, -1, 1))
    m.face([(a1, b1, zl), (a0, b1, zl), (r0, ym, zr), (r1, ym, zr)], mat, (0, 1, 1))
    m.face([(a0, b1, zl), (a0, b0, zl), (r0, ym, zr)], mat, (-1, 0, 1))
    m.face([(a1, b0, zl), (a1, b1, zl), (r1, ym, zr)], mat, (1, 0, 1))
    m.face([(a0, b0, zl), (a1, b0, zl), (a1, b1, zl), (a0, b1, zl)], "Trim", (0, 0, -1))


def lot(m, half, mat, curb=True):
    m.box(-half, -half, 0.0, half, half, 0.12, mat)


def fence(m, x0, y0, x1, y1, h=1.0, mat="Trim", gap=None, post=1.5):
    """Picket-ish fence along a polyline segment; gap=(a, b) leaves an opening (fraction)."""
    p0, p1 = Vector((x0, y0, 0.12)), Vector((x1, y1, 0.12))
    d = p1 - p0
    L = d.length
    u = d.normalized()
    side = u.cross(UP) * 0.05
    segs = max(1, int(L / post))
    for i in range(segs):
        t0, t1 = i / segs, (i + 1) / segs
        if gap and gap[0] < (t0 + t1) / 2 < gap[1]:
            continue
        a = p0 + d * t0
        m.obox(a - side, u * (L / segs), side * 2, UP * 0.12, mat)
        m.obox(a - side + UP * (h - 0.35), u * (L / segs), side * 2, UP * 0.1, mat)
        m.obox(a - side * 1.4 - u * 0.06, u * 0.12, side * 2.8, UP * h, mat)


# ------------------------------------------------------------ residential ---

def res_house(name, seed, floors, roof, porch=True, garage=False, hipped=False):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Grass")
    w, d = rng.choice([(7.0, 6.0), (7.5, 6.5), (6.5, 7.0)])
    x0, x1 = -w / 2 - (1.2 if garage else 0), w / 2 - (1.2 if garage else 0)
    y0, y1 = -2.2, -2.2 + d
    fh = 3.0
    z0 = 0.12
    m.box(x0 - 0.15, y0 - 0.15, 0.0, x1 + 0.15, y1 + 0.15, 0.55, "Concrete")
    zb = 0.55
    door_col = 1 if (x1 - x0) / 2.6 >= 2 else 0
    block_with_windows(m, x0, y0, x1, y1, zb, floors, fh, "Wall", win_w=1.2, win_h=1.4, sill=0.9,
                       pitch=2.4, mullion=True,
                       front_skip=lambda f, c: f == 0 and c == door_col)
    cols = max(1, int((x1 - x0) / 2.4))
    pitch = (x1 - x0) / cols
    dx = x0 + pitch * (door_col + 0.5)
    m.box(dx - 0.55, y0 - 0.05, zb, dx + 0.55, y0 + 0.02, zb + 2.2, "Door")
    m.box(dx - 0.7, y0 - 0.08, zb + 2.2, dx + 0.7, y0 + 0.02, zb + 2.4, "Trim")
    # band between floors
    for f in range(1, floors):
        z = zb + f * fh
        m.box(x0 - 0.06, y0 - 0.06, z - 0.1, x1 + 0.06, y1 + 0.06, z + 0.1, "Trim")
    top = zb + floors * fh
    m.box(x0 - 0.08, y0 - 0.08, top - 0.15, x1 + 0.08, y1 + 0.08, top, "Trim")
    if hipped:
        hip_roof(m, x0, y0, x1, y1, top, 2.2 + rng.uniform(0, 0.6))
    else:
        gable_roof(m, x0, y0, x1, y1, top, 2.4 + rng.uniform(0, 0.8), along_x=rng.random() < 0.6)
    # chimney
    cx = x1 - 1.2
    m.box(cx - 0.4, y1 - 2.0, top - 0.5, cx + 0.4, y1 - 1.2, top + 3.2, "Brick")
    m.box(cx - 0.5, y1 - 2.1, top + 3.2, cx + 0.5, y1 - 1.1, top + 3.4, "Concrete")
    if porch:
        m.box(dx - 1.8, y0 - 1.8, 0.0, dx + 1.8, y0, 0.5, "Concrete")
        m.box(dx - 1.9, y0 - 1.9, zb + 2.7, dx + 1.9, y0, zb + 2.85, "Trim")
        for px in (dx - 1.7, dx + 1.7):
            m.box(px - 0.1, y0 - 1.8, 0.5, px + 0.1, y0 - 1.6, zb + 2.7, "Trim")
        m.box(dx - 0.6, -6.0, 0.0, dx + 0.6, y0 - 1.8, 0.16, "Paving")  # path to sidewalk
    if garage:
        gx0, gx1 = x1, x1 + 3.6
        m.box(gx0, y0 + 0.5, 0.0, gx1, y0 + 6.0, 0.15, "Concrete")
        block_with_windows(m, gx0, y0 + 0.5, gx1, y0 + 6.0, 0.15, 1, 2.8, "Wall", pitch=9,
                           all_skip=lambda nm, f, c, cs: nm in ("S", "W"))
        m.box(gx0 + 0.4, y0 + 0.45, 0.15, gx1 - 0.4, y0 + 0.5, 2.4, "Metal")
        m.box(gx0 - 0.1, y0 + 0.4, 2.95, gx1 + 0.1, y0 + 6.1, 3.15, "Roof", sides="Trim")
        m.box(gx0 + 0.3, -6.0, 0.0, gx1 - 0.3, y0 + 0.5, 0.14, "Asphalt")
    # front fence with gate
    fence(m, -5.7, -5.6, 5.7, -5.6, gap=(0.35, 0.65) if not garage else (0.3, 0.9))
    # shrubs
    for sx in (x0 + 0.6, x1 - 0.6):
        m.blob(sx, y0 - 0.8, 0.6, 0.6, "Leaves", rng, sq=0.8)
    return m.build(name)


def res_walkup(name, seed, floors, wall="Brick"):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.0, 5.0, -4.6, 4.6
    fh = 3.1
    zb = 0.12
    # raised ground floor plinth
    m.box(x0 - 0.1, y0 - 0.1, 0.0, x1 + 0.1, y1 + 0.1, 0.8, "Concrete")
    zb = 0.8
    block_with_windows(m, x0, y0, x1, y1, zb, floors, fh, wall, win_w=1.15, win_h=1.6, sill=0.85,
                       pitch=2.0, mullion=True, front_skip=lambda f, c: f == 0 and c == 2)
    top = zb + floors * fh
    # entrance with stoop
    m.box(-0.8, y0 - 0.05, zb, 0.8, y0 + 0.02, zb + 2.4, "Door")
    m.box(-1.2, y0 - 0.6, zb + 2.5, 1.2, y0, zb + 2.7, "Trim")
    for i in range(4):
        m.box(-1.1, y0 - 1.6 + i * 0.35, 0.0, 1.1, y0, 0.2 * (i + 1), "Concrete")
    # floor bands + cornice
    for f in range(1, floors):
        z = zb + f * fh
        m.box(x0 - 0.05, y0 - 0.05, z - 0.08, x1 + 0.05, y1 + 0.05, z + 0.08, "Trim")
    m.box(x0 - 0.35, y0 - 0.35, top, x1 + 0.35, y1 + 0.35, top + 0.45, "Trim")
    flat_roof(m, x0, y0, x1, y1, top + 0.45, parapet=0.5)
    roof_clutter(m, rng, x0, y0, x1, y1, top + 0.45, n=2, tank=rng.random() < 0.6)
    # fire escape on the east side
    if rng.random() < 0.7:
        for f in range(1, floors):
            z = zb + f * fh
            m.box(x1, -2.0, z - 0.05, x1 + 1.0, 2.0, z + 0.05, "Metal")
            m.box(x1 + 0.95, -2.0, z, x1 + 1.0, 2.0, z + 0.9, "Metal")
            m.box(x1, -1.5, z - fh + 0.05, x1 + 0.9, -1.4, z, "Metal")
    # planters
    for sx in (-3.5, 3.5):
        m.box(sx - 0.7, y0 - 1.2, 0.0, sx + 0.7, y0 - 0.3, 0.5, "Concrete")
        m.blob(sx, y0 - 0.75, 0.9, 0.55, "Leaves", rng, sq=0.7)
    return m.build(name)


def res_tower(name, seed, floors, size=1):
    rng = random.Random(seed)
    m = Mesh()
    half = 6 * size
    lot(m, half, "Paving")
    s = 4.8 if size == 1 else 9.5
    x0, x1, y0, y1 = -s, s, -s + 0.4, s
    fh = 3.0
    zb = 0.12
    # lobby
    m.box(x0, y0, zb, x1, y1, zb + 4.0, "Concrete")
    m.box(-2.5, y0 - 0.02, zb, 2.5, y0, zb + 3.2, "Glass")
    m.box(x0 - 0.5, y0 - 2.0, zb + 3.8, x1 + 0.5, y0 + 0.5, zb + 4.2, "Trim")
    z1 = zb + 4.0
    wall = rng.choice(["Wall", "Accent", "Brick"])
    block_with_windows(m, x0, y0, x1, y1, z1, floors, fh, wall, win_w=1.4, win_h=1.7, sill=0.8,
                       pitch=2.2 if size == 1 else 2.4, mullion=False)
    # balconies on the front and back
    cols = int((x1 - x0) / 3.2)
    for f in range(1, floors):
        z = z1 + f * fh
        for c in range(cols):
            if (c + f) % 2 and size == 1:
                continue
            bx = x0 + (x1 - x0) * (c + 0.5) / cols
            for (yy, sgn) in ((y0, -1), (y1, 1)):
                yo = yy + sgn * 1.1
                ya, yb = (yo, yy) if sgn < 0 else (yy, yo)
                m.box(bx - 1.1, ya, z - 0.12, bx + 1.1, yb, z + 0.05, "Concrete")
                m.box(bx - 1.1, yo - 0.04 if sgn > 0 else yo, z, bx + 1.1, yo + 0.04 if sgn < 0 else yo, z + 1.0, "Glass")
    top = z1 + floors * fh
    if size == 2:
        # setback crown
        flat_roof(m, x0, y0, x1, y1, top, parapet=0.4)
        s2 = s * 0.6
        block_with_windows(m, -s2, -s2, s2, s2, top, 3, fh, "Trim", pitch=2.4)
        top2 = top + 3 * fh
        flat_roof(m, -s2, -s2, s2, s2, top2, parapet=0.5)
        roof_clutter(m, rng, -s2, -s2, s2, s2, top2, n=2, tank=True)
        roof_clutter(m, rng, x0, y0, -s2, y1, top, n=2)
    else:
        flat_roof(m, x0, y0, x1, y1, top, parapet=0.6)
        roof_clutter(m, rng, x0, y0, x1, y1, top, n=2, tank=True)
    for sx in (x0 - 0.2, x1 + 0.2):
        m.blob(sx, y0 - 1.5, 0.8, 0.8, "Leaves", rng, sq=0.7)
    return m.build(name)


# ------------------------------------------------------------- commercial ---

def storefront(m, rng, x0, x1, y, z0, h=3.6, awning=True, sign=True):
    w = x1 - x0
    m.box(x0, y - 0.02, z0, x1, y + 0.02, z0 + 0.5, "Trim")
    m.box(x0 + 0.2, y - 0.01, z0 + 0.5, x1 - 0.2, y + 0.03, z0 + h - 0.6, "Glass")
    n = max(2, int(w / 2.2))
    for i in range(n + 1):
        x = x0 + 0.2 + (w - 0.4) * i / n
        m.box(x - 0.06, y - 0.08, z0 + 0.5, x + 0.06, y, z0 + h - 0.6, "Metal")
    dx = x0 + w * rng.choice([0.25, 0.5, 0.75])
    m.box(dx - 0.6, y - 0.06, z0 + 0.12, dx + 0.6, y, z0 + 2.4, "Door")
    m.box(x0, y - 0.1, z0 + h - 0.6, x1, y + 0.02, z0 + h, "Trim")
    if sign:
        m.box(x0 + 0.6, y - 0.35, z0 + h - 0.55, x1 - 0.6, y - 0.1, z0 + h + 0.35, "Sign")
    if awning:
        a, b = z0 + h - 0.7, z0 + h - 1.6
        m.face([(x0 + 0.1, y, a), (x1 - 0.1, y, a), (x1 - 0.1, y - 1.6, b), (x0 + 0.1, y - 1.6, b)], "Awning", (0, -1, 1))
        m.face([(x0 + 0.1, y, a - 0.05), (x1 - 0.1, y, a - 0.05), (x1 - 0.1, y - 1.6, b - 0.05), (x0 + 0.1, y - 1.6, b - 0.05)], "Awning", (0, 0, -1))
        m.face([(x0 + 0.1, y - 1.6, b), (x1 - 0.1, y - 1.6, b), (x1 - 0.1, y - 1.6, b - 0.35), (x0 + 0.1, y - 1.6, b - 0.35)], "Awning", (0, -1, 0))


def com_shop(name, seed, kind):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    if kind == "gas":
        # canopy on pillars plus kiosk
        m.box(-5.5, -5.5, 0.12, 5.5, 2.0, 0.14, "Asphalt")
        for px in (-3.5, 3.5):
            for py in (-3.5, -0.5):
                m.box(px - 0.2, py - 0.2, 0.12, px + 0.2, py + 0.2, 4.5, "Trim")
            m.box(px - 0.5, -2.6, 0.12, px + 0.5, -1.4, 1.6, "Sign")
        m.box(-5.0, -5.0, 4.5, 5.0, 1.0, 5.3, "Trim", top="Roof")
        m.box(-5.05, -5.05, 4.75, 5.05, 1.05, 5.05, "Awning")
        m.box(-4.0, 1.6, 0.12, 4.0, 5.6, 3.6, "Wall", top="Roof")
        storefront(m, rng, -4.0, 4.0, 1.6, 0.12, h=3.4, awning=False, sign=False)
        m.box(-2.5, 1.3, 3.6, 2.5, 1.6, 4.4, "Sign")
        return m.build(name)
    double = kind == "double"
    x0, x1 = (-5.4, 5.4) if double else (-4.6, 4.6)
    y0, y1 = -3.4, 4.8
    h = 4.2 + rng.uniform(0, 0.8)
    wall = rng.choice(["Wall", "Brick", "Accent"])
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, h, wall, pitch=3.0, win_h=1.6, sill=1.6,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    if double:
        storefront(m, rng, x0, -0.1, y0, 0.12, h=3.6)
        storefront(m, rng, 0.1, x1, y0, 0.12, h=3.6)
        m.box(-0.15, y0 - 0.15, 0.12, 0.15, y0 + 0.02, h, "Trim")
    else:
        storefront(m, rng, x0, x1, y0, 0.12, h=3.6)
    # false front parapet
    m.box(x0 - 0.1, y0 - 0.2, h, x1 + 0.1, y0 + 0.3, h + 0.9, "Trim")
    flat_roof(m, x0, y0, x1, y1, h, parapet=0.4)
    roof_clutter(m, rng, x0, y0 + 1, x1, y1, h, n=2)
    for bx in (-4.5, 4.5):
        m.box(bx - 0.4, -5.6, 0.12, bx + 0.4, -5.2, 0.9, "Concrete")
        m.blob(bx, -5.4, 1.3, 0.5, "Leaves", rng, sq=0.8)
    return m.build(name)


def com_midrise(name, seed, floors):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Paving")
    x0, x1, y0, y1 = -5.4, 5.4, -4.8, 5.2
    wall = rng.choice(["Wall", "Brick", "Accent", "Concrete"])
    gh = 4.4
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, gh, wall, pitch=3.0, win_h=2.0, sill=1.4,
                       all_skip=lambda nm, f, c, cs: nm == "S")
    storefront(m, rng, x0, x1, y0, 0.12, h=gh - 0.2)
    fh = 3.3
    block_with_windows(m, x0, y0, x1, y1, gh + 0.12, floors, fh, wall, win_w=1.5, win_h=1.9,
                       sill=0.8, pitch=2.1, mullion=rng.random() < 0.5, lintel="Trim" if rng.random() < 0.4 else None)
    top = gh + 0.12 + floors * fh
    m.box(x0 - 0.1, y0 - 0.1, gh - 0.05, x1 + 0.1, y1 + 0.1, gh + 0.3, "Trim")
    m.box(x0 - 0.45, y0 - 0.45, top, x1 + 0.45, y1 + 0.45, top + 0.6, "Trim")
    flat_roof(m, x0, y0, x1, y1, top + 0.6, parapet=0.5)
    roof_clutter(m, rng, x0, y0, x1, y1, top + 0.6, n=3)
    if rng.random() < 0.6:  # rooftop billboard
        m.box(-3.5, y1 - 1.0, top + 0.6, -3.3, y1 - 0.8, top + 3.0, "Metal")
        m.box(3.3, y1 - 1.0, top + 0.6, 3.5, y1 - 0.8, top + 3.0, "Metal")
        m.box(-4.2, y1 - 1.2, top + 2.5, 4.2, y1 - 0.9, top + 5.0, "Sign")
    return m.build(name)


def com_tower(name, seed, floors, size=1):
    rng = random.Random(seed)
    m = Mesh()
    half = 6 * size
    lot(m, half, "Paving")
    s = 5.0 if size == 1 else 10.0
    x0, x1, y0, y1 = -s, s, -s, s
    base_h = 6.0
    # podium with tall lobby glass
    m.box(x0 - 0.3, y0 - 0.3, 0.12, x1 + 0.3, y1 + 0.3, base_h, "Concrete", top="Roof")
    m.box(x0 + 0.8, y0 - 0.32, 0.12, x1 - 0.8, y0 - 0.28, base_h - 1.0, "Glass")
    m.box(-1.5, y0 - 0.36, 0.12, 1.5, y0 - 0.3, 3.0, "Door")
    m.box(x0 - 0.8, y0 - 2.5, base_h - 0.9, x1 + 0.8, y0 - 0.3, base_h - 0.6, "Metal")
    accent = rng.choice(["Accent", "Concrete", "Trim", "Metal"])
    fh = 3.6
    tiers = [(floors, s - 0.3)]
    if size == 2:
        a = int(floors * 0.55)
        b = int(floors * 0.3)
        tiers = [(a, s - 0.3), (b, s * 0.72), (floors - a - b, s * 0.48)]
    elif floors > 14:
        a = int(floors * 0.75)
        tiers = [(a, s - 0.3), (floors - a, s * 0.7)]
    z = base_h
    for tf, ts in tiers:
        tx0, tx1, ty0, ty1 = -ts, ts, -ts, ts
        # curtain wall: glass box + spandrel bands + fins
        m.box(tx0 + 0.15, ty0 + 0.15, z, tx1 - 0.15, ty1 - 0.15, z + tf * fh, "Glass", top="Roof")
        for f in range(tf):
            zz = z + f * fh
            m.box(tx0, ty0, zz, tx1, ty1, zz + 0.75, accent, top=accent)
        for (ox, oy), u, w, nm in sides_of(tx0, ty0, tx1, ty1):
            u = Vector(u)
            n = u.cross(UP)
            cols = max(2, int(w / 1.6))
            for c in range(1, cols):
                p = Vector((ox, oy, z)) + u * (w * c / cols) + n * 0.0
                m.obox(p - u * 0.06, u * 0.12, n * 0.22, UP * tf * fh, accent)
        z += tf * fh
        m.box(tx0 - 0.2, ty0 - 0.2, z, tx1 + 0.2, ty1 + 0.2, z + 0.6, accent)
        z += 0.6
        flat_roof(m, tx0, ty0, tx1, ty1, z, parapet=0.8, rim=accent)
    ts = tiers[-1][1]
    roof_clutter(m, rng, -ts, -ts, ts, ts, z, n=2)
    if size == 2 or rng.random() < 0.5:
        m.cyl(0, 0, z, z + 2.0, 1.2, "Metal", seg=8)
        m.cyl(0, 0, z + 2.0, z + (16 if size == 2 else 8), 0.25, "Metal", seg=6, r_top=0.05)
        m.blob(0, 0, z + 2.3, 0.35, "Sign", rng, jitter=0)
    for (bx, by) in ((x0 - 0.8, y0 - 3.0), (x1 + 0.8, y0 - 3.0)):
        if size == 2:
            m.box(bx - 1.2, by - 1.2, 0.12, bx + 1.2, by + 1.2, 0.6, "Concrete")
            m.blob(bx, by, 2.0, 1.4, "Leaves", rng, sq=1.1)
    return m.build(name)


# ------------------------------------------------------------- industrial ---

def ind_shed(name, seed, kind):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Asphalt")
    x0, x1, y0, y1 = -4.8, 4.8, -2.4, 5.2
    h = 5.0 + rng.uniform(0, 1.0)
    wall = "Metal" if kind != "brick" else "Brick"
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, h, wall, pitch=3.0, win_h=0.9, sill=h - 1.6,
                       all_skip=lambda nm, f, c, cs: nm == "S" and c == 1)
    m.box(-1.8, y0 - 0.06, 0.12, 1.8, y0, 3.8, "Door" if wall == "Brick" else "Concrete")
    for i in range(10):
        z = 0.4 + i * 0.34
        m.box(-1.8, y0 - 0.09, z, 1.8, y0 - 0.05, z + 0.05, "Metal")
    if kind == "gable":
        gable_roof(m, x0, y0, x1, y1, h, 1.4, mat="Metal", gable=wall, over=0.3, along_x=False)
    else:
        flat_roof(m, x0, y0, x1, y1, h, parapet=0.4, rim="Concrete")
        roof_clutter(m, rng, x0, y0, x1, y1, h, n=2)
    # office annex
    m.box(x1 - 3.4, -5.0, 0.12, x1 - 0.2, y0, 3.2, "Wall", top="Roof")
    m.box(x1 - 3.0, -5.04, 1.0, x1 - 0.6, -5.0, 2.4, "Glass")
    # yard: pallets, barrels, fence
    for i in range(3):
        px, py = x0 + 0.6 + i * 1.3, -5.0
        m.box(px, py, 0.12, px + 1.1, py + 1.1, 0.25 + 0.15 * (i % 2), "Door")
        m.box(px + 0.1, py + 0.1, 0.25 + 0.15 * (i % 2), px + 1.0, py + 1.0, 1.1, "Concrete")
    for i in range(3):
        m.cyl(x0 + 0.8 + i * 0.7, y1 + 0.3, 0.12, 1.0, 0.3, rng.choice(["Awning", "Metal", "Accent"]), seg=8)
    fence(m, -5.8, 5.8, 5.8, 5.8, h=1.8, mat="Metal", post=2.0)
    fence(m, -5.8, -5.8, -5.8, 5.8, h=1.8, mat="Metal", post=2.0)
    return m.build(name)


def ind_warehouse(name, seed, sawtooth):
    rng = random.Random(seed)
    m = Mesh()
    lot(m, 6, "Asphalt")
    x0, x1, y0, y1 = -5.6, 5.6, -3.0, 5.6
    h = 7.5
    wall = rng.choice(["Metal", "Concrete", "Brick"])
    block_with_windows(m, x0, y0, x1, y1, 0.12, 1, h, wall, pitch=2.8, win_h=1.2, sill=h - 2.0,
                       all_skip=lambda nm, f, c, cs: nm == "S" and c in (0, 2))
    # loading docks
    m.box(x0, y0 - 1.6, 0.12, x1, y0, 1.2, "Concrete")
    for dx in (-3.6, 0.0 + 1.5):
        m.box(dx - 1.4, y0 - 0.05, 1.2, dx + 1.4, y0, 4.2, "Metal")
        m.box(dx - 1.6, y0 - 1.2, 4.4, dx + 1.6, y0, 4.6, "Accent")
    if sawtooth:
        n = 4
        step = (y1 - y0) / n
        for i in range(n):
            ya, yb = y0 + i * step, y0 + (i + 1) * step
            m.face([(x0, ya, h), (x1, ya, h), (x1, ya, h + 2.0), (x0, ya, h + 2.0)], "Glass", (0, -1, 0))
            m.face([(x0, ya, h + 2.0), (x1, ya, h + 2.0), (x1, yb, h), (x0, yb, h)], "Roof", (0, 0.3, 1))
            m.face([(x0, ya, h), (x0, ya, h + 2.0), (x0, yb, h)], wall, (-1, 0, 0))
            m.face([(x1, ya, h), (x1, ya, h + 2.0), (x1, yb, h)], wall, (1, 0, 0))
    else:
        flat_roof(m, x0, y0, x1, y1, h, parapet=0.5, rim="Concrete")
        roof_clutter(m, rng, x0, y0, x1, y1, h, n=4)
    m.box(x0 - 0.05, y0 - 0.05, h - 1.6, x1 + 0.05, y0, h - 0.4, "Sign")
    return m.build(name)


def ind_factory(name, seed, size=1):
    rng = random.Random(seed)
    m = Mesh()
    half = 6 * size
    lot(m, half, "Asphalt")
    s = half - 0.8
    x0, x1, y0, y1 = -s, s * 0.35 if size == 2 else s, -s + 0.8, s
    h = 9.0 if size == 1 else 12.0
    wall = rng.choice(["Brick", "Metal", "Concrete"])
    block_with_windows(m, x0, y0, x1, y1, 0.12, 2, h / 2, wall, pitch=2.6, win_h=1.8, sill=1.6,
                       mullion=True)
    flat_roof(m, x0, y0, x1, y1, h, parapet=0.5, rim="Concrete")
    # sawtooth monitors on roof
    for i in range(2 if size == 1 else 4):
        yy = y0 + 1.0 + i * 2.6
        m.box(x0 + 1.0, yy, h, x1 - 1.0, yy + 1.4, h + 1.3, "Roof")
        m.box(x0 + 1.0, yy - 0.02, h + 0.3, x1 - 1.0, yy, h + 1.2, "Glass")
    # smoke stacks
    stacks = [(x1 - 1.6, y1 - 1.6)] if size == 1 else [(x1 - 2, y1 - 2), (x1 - 2, y1 - 6), (x0 + 3, y1 - 2)]
    for (cx, cy) in stacks:
        top = h + (14 if size == 1 else 22) + rng.uniform(-2, 3)
        m.cyl(cx, cy, 0.12, top, 0.9, "Brick", seg=10, r_top=0.65, cap=False)
        for k in range(2):
            z = top - 1.0 - k * 3.0
            m.cyl(cx, cy, z, z + 0.6, 0.85 - k * 0.05 + 0.08, "Awning" if k == 0 else "Trim", seg=10)
        m.cyl(cx, cy, top - 0.2, top, 0.66, "Roof", seg=10)
    if size == 2:
        # tank farm
        for i, (tx, ty) in enumerate(((7.0, -6.0), (7.0, 0.0), (7.0, 6.5))):
            r = 2.4
            m.cyl(tx, ty, 0.12, 8.0 + i, r, "Metal", seg=14, smooth=True)
            m.cyl(tx, ty, 8.0 + i, 9.0 + i, r, "Trim", seg=14, r_top=0.4)
        for z in (5.0, 6.5):
            m.box(x1, -6.2, z, 6.0, -5.8, z + 0.4, "Metal")
            m.box(x1, 0.0, z, 6.0, 0.4, z + 0.4, "Metal")
    else:
        m.cyl(x0 + 2.0, y0 - 2.6 + 0.5, 0.12, 4.5, 1.4, "Metal", seg=12)
        m.cyl(x0 + 2.0, y0 - 2.1, 4.5, 5.2, 1.4, "Trim", seg=12, r_top=0.3)
    m.box(x0 + 3.5, y0 - 0.05, 0.12, x0 + 7.5, y0, 4.5, "Metal")
    fence(m, -half + 0.2, half - 0.2, half - 0.2, half - 0.2, h=2.0, mat="Metal", post=2.4)
    return m.build(name)


# ------------------------------------------------------------------ roads ---

ASPH = 3.75   # half width of asphalt
SWH = 0.17    # sidewalk height


def road_piece(name, conn):
    """conn: set of 'N','E','S','W' (Blender +Y = N, +X = E)."""
    m = Mesh()
    H = TILE / 2
    a = ASPH
    # asphalt: centre + arms
    za = 0.05
    m.face([(-a, -a, za), (a, -a, za), (a, a, za), (-a, a, za)], "Asphalt", UP)
    arms = {"N": (-a, a, a, H), "S": (-a, -H, a, -a), "E": (a, -a, H, a), "W": (-H, -a, -a, a)}
    for d, (x0, y0, x1, y1) in arms.items():
        if d in conn:
            m.face([(x0, y0, za), (x1, y0, za), (x1, y1, za), (x0, y1, za)], "Asphalt", UP)
    # sidewalk corner blocks
    for sx in (-1, 1):
        for sy in (-1, 1):
            xa, xb = sorted((sx * a, sx * H))
            ya, yb = sorted((sy * a, sy * H))
            m.box(xa, ya, 0.0, xb, yb, SWH, "Curb", top="Sidewalk")
    # sidewalk strips on closed sides
    for d, (x0, y0, x1, y1) in arms.items():
        if d not in conn:
            m.box(x0, y0, 0.0, x1, y1, SWH, "Curb", top="Sidewalk")
    # markings
    z = 0.065
    n = len(conn)
    straight_ns = conn == {"N", "S"}
    straight_ew = conn == {"E", "W"}

    def dash_line(p0, p1, dash=1.5, gap=1.5, w=0.12, mat="MarkingYellow"):
        p0, p1 = Vector(p0), Vector(p1)
        d = p1 - p0
        L = d.length
        u = d.normalized()
        side = Vector((-u.y, u.x, 0)) * w / 2
        t = 0.0
        while t < L - 0.01:
            e = min(t + dash, L)
            A, B = p0 + u * t, p0 + u * e
            m.face([A - side, B - side, B + side, A + side], mat, UP)
            t = e + gap

    if straight_ns:
        dash_line((0, -H, z), (0, H, z), dash=2.0, gap=1.0)
    elif straight_ew:
        dash_line((-H, 0, z), (H, 0, z), dash=2.0, gap=1.0)
    elif n == 2:  # corner: two dashes meeting at the centre
        ends = {"N": (0, H, z), "S": (0, -H, z), "E": (H, 0, z), "W": (-H, 0, z)}
        for d in conn:
            dash_line((0, 0, z), ends[d], dash=2.0, gap=1.0)
    elif n == 1:
        ends = {"N": (0, H, z), "S": (0, -H, z), "E": (H, 0, z), "W": (-H, 0, z)}
        d = next(iter(conn))
        dash_line(ends[d], (0, 0, z), dash=2.0, gap=1.0)
    if n >= 3:
        # zebra crossings on each connected arm + stop line
        for d in conn:
            for i in range(7):
                t = -a + 0.35 + i * (2 * a - 0.7) / 6.0
                if d in ("N", "S"):
                    s = 1 if d == "N" else -1
                    y0, y1 = sorted((s * (a + 0.4), s * (H - 0.3)))
                    m.face([(t - 0.25, y0, z), (t + 0.25, y0, z), (t + 0.25, y1, z), (t - 0.25, y1, z)], "Marking", UP)
                else:
                    s = 1 if d == "E" else -1
                    x0, x1 = sorted((s * (a + 0.4), s * (H - 0.3)))
                    m.face([(x0, t - 0.25, z), (x1, t - 0.25, z), (x1, t + 0.25, z), (x0, t + 0.25, z)], "Marking", UP)
        # manhole
        m.cyl(1.6, -1.6, za, za + 0.012, 0.45, "Metal", seg=10, smooth=False)
    if n == 0:
        m.box(-a, -a, 0.0, a, a, SWH, "Curb", top="Sidewalk")
    return m.build(name)


def street_lamp(name):
    m = Mesh()
    m.cyl(0, 0, 0.0, 0.5, 0.18, "Roof", seg=8)
    m.cyl(0, 0, 0.5, 6.4, 0.09, "Roof", seg=8, r_top=0.07)
    # arm reaching toward -X (the game rotates it to face the road)
    m.obox((-0.05, -0.05, 6.3), (-1.6, 0, 0.0), (0, 0.1, 0), (0, 0, 0.1), "Roof")
    m.obox((-1.75, -0.22, 6.12), (0.75, 0, 0), (0, 0.44, 0), (0, 0, 0.25), "Roof")
    m.face([(-1.7, -0.18, 6.11), (-1.05, -0.18, 6.11), (-1.05, 0.18, 6.11), (-1.7, 0.18, 6.11)], "Lamp", (0, 0, -1))
    return m.build(name)


def traffic_light(name):
    m = Mesh()
    m.cyl(0, 0, 0.0, 5.2, 0.1, "Roof", seg=8)
    m.obox((-0.05, -0.05, 5.0), (-3.0, 0, 0), (0, 0.1, 0), (0, 0, 0.12), "Roof")
    m.box(-2.9, -0.2, 4.0, -2.5, 0.2, 5.0, "Roof")
    m.box(-2.92, -0.15, 4.65, -2.88, 0.15, 4.95, "Taillight")
    m.box(-2.92, -0.15, 4.05, -2.88, 0.15, 4.35, "Leaves")
    return m.build(name)


# ------------------------------------------------------------------ trees ---

def tree_round(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    h = rng.uniform(2.6, 3.4)
    m.cyl(0, 0, 0, h + 0.8, 0.22, "Bark", seg=6, r_top=0.12)
    r = rng.uniform(2.0, 2.6)
    m.blob(0, 0, h + r * 0.75, r, "Leaves", rng, subdiv=1)
    for _ in range(3):
        a = rng.uniform(0, 6.28)
        rr = r * rng.uniform(0.55, 0.75)
        m.blob(math.cos(a) * r * 0.6, math.sin(a) * r * 0.6, h + r * rng.uniform(0.4, 1.0), rr, "Leaves", rng)
    return m.build(name)


def tree_pine(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    m.cyl(0, 0, 0, 2.0, 0.25, "Bark", seg=6)
    z = 1.2
    r = 2.4
    for i in range(4):
        m.cyl(0, 0, z, z + 2.8, r, "Leaves", seg=7, r_top=0.15, smooth=False)
        z += 1.8
        r *= 0.75
    return m.build(name)


def palm(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    lean = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), 0)) * 0.12
    p = Vector((0, 0, 0))
    for i in range(6):
        q = p + Vector((0, 0, 1.3)) + lean * (i + 1) * 0.6
        m.cyl(p.x, p.y, p.z, q.z, 0.22 - i * 0.015, "Bark", seg=6, r_top=0.2 - i * 0.015, cap=False)
        p = Vector((q.x, q.y, q.z))
    for k in range(7):
        a = k * 2 * math.pi / 7 + rng.uniform(-0.2, 0.2)
        d = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-d.y, d.x, 0)) * 0.45
        mid = p + d * 1.8 + UP * 0.4
        tip = p + d * 3.4 - UP * 1.0
        for nz in (UP, -UP):
            m.face([p - side * 0.3, mid - side, mid + side, p + side * 0.3], "Leaves", nz)
            m.face([mid - side, tip, mid + side], "Leaves", nz)
    m.blob(p.x, p.y, p.z, 0.4, "Bark", rng)
    return m.build(name)


def bush(name, seed):
    rng = random.Random(seed)
    m = Mesh()
    for _ in range(3):
        m.blob(rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), 0.5, rng.uniform(0.6, 0.9), "Leaves", rng, sq=0.75)
    return m.build(name)


# ------------------------------------------------------------------- cars ---

def car(name, kind):
    """Faces +Y in Blender (north / Godot -Z)."""
    m = Mesh()
    if kind == "sedan":
        L, W, h0, h1, cab = 4.4, 1.8, 0.35, 0.95, (-1.1, 0.9, 1.45)
    elif kind == "hatch":
        L, W, h0, h1, cab = 3.8, 1.7, 0.35, 0.95, (-1.6, 0.8, 1.5)
    elif kind == "van":
        L, W, h0, h1, cab = 4.8, 1.95, 0.4, 1.1, (-2.3, 1.4, 2.1)
    else:  # truck
        L, W, h0, h1, cab = 6.8, 2.3, 0.5, 1.2, (1.6, 3.3, 2.6)
    hl, hw = L / 2, W / 2
    m.box(-hw, -hl, h0, hw, hl, h1, "CarBody", bottom=True)
    ca, cb, ch = cab
    if kind == "truck":
        m.box(-hw, ca, h1, hw, cb, ch, "CarBody")
        m.box(-hw + 0.05, cb - 0.02, h1 + 0.5, hw - 0.05, cb + 0.01, ch - 0.25, "Glass")
        m.box(-hw - 0.05, -hl, h1, hw + 0.05, ca - 0.25, h1 + 1.9, "Trim")
    else:
        # cabin with slanted windscreen and glass sides
        x = hw - 0.12
        m.face([(-x, cb, h1), (x, cb, h1), (x, cb - 0.6, ch), (-x, cb - 0.6, ch)], "Glass", (0, 1, 0.7))
        m.face([(-x, ca, h1), (x, ca, h1), (x, ca + 0.4, ch), (-x, ca + 0.4, ch)], "Glass", (0, -1, 0.7))
        m.face([(-x, ca + 0.4, ch), (x, ca + 0.4, ch), (x, cb - 0.6, ch), (-x, cb - 0.6, ch)], "CarBody", UP)
        for s in (-1, 1):
            m.face([(s * x, ca, h1), (s * x, cb, h1), (s * x, cb - 0.6, ch), (s * x, ca + 0.4, ch)], "Glass", (s, 0, 0))
    # lights
    m.box(-hw + 0.1, hl, h1 - 0.3, -hw + 0.5, hl + 0.03, h1 - 0.1, "Headlight")
    m.box(hw - 0.5, hl, h1 - 0.3, hw - 0.1, hl + 0.03, h1 - 0.1, "Headlight")
    m.box(-hw + 0.1, -hl - 0.03, h1 - 0.3, -hw + 0.5, -hl, h1 - 0.1, "Taillight")
    m.box(hw - 0.5, -hl - 0.03, h1 - 0.3, hw - 0.1, -hl, h1 - 0.1, "Taillight")
    m.box(-hw - 0.02, hl - 0.1, h0, hw + 0.02, hl + 0.06, h0 + 0.18, "Tire")
    m.box(-hw - 0.02, -hl - 0.06, h0, hw + 0.02, -hl + 0.1, h0 + 0.18, "Tire")
    # wheels (as octagonal prisms along X)
    wr = 0.36 if kind != "truck" else 0.48
    for wy in (hl - 0.8, -hl + 0.85) + ((-hl + 2.0,) if kind == "truck" else ()):
        for s in (-1, 1):
            pts0, pts1 = [], []
            for i in range(8):
                a = 2 * math.pi * i / 8
                pts0.append(Vector((s * (hw - 0.22), wy + wr * math.cos(a), wr + wr * math.sin(a))))
                pts1.append(Vector((s * (hw + 0.04), wy + wr * math.cos(a), wr + wr * math.sin(a))))
            for i in range(8):
                j = (i + 1) % 8
                mid = (pts1[i] + pts1[j]) / 2
                m.face([pts0[i], pts0[j], pts1[j], pts1[i]], "Tire", mid - Vector((mid.x, wy, wr)))
            m.face(pts1, "Metal", (s, 0, 0))
    return m.build(name)


# ----------------------------------------------------------------- driver ---

def export(ob, sub):
    path = os.path.join(OUT, sub)
    os.makedirs(path, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.export_scene.gltf(filepath=os.path.join(path, ob.name + ".glb"), use_selection=True,
                              export_format="GLB", export_apply=True, export_yup=True,
                              export_normals=True, export_materials="EXPORT")
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    print(f"  {sub}/{ob.name}.glb  {tris} tris")


def main():
    global MATERIALS
    bpy.ops.wm.read_factory_settings(use_empty=True)
    MATERIALS = {}
    for nm, col in MAT_COLORS.items():
        mat = bpy.data.materials.new(nm)
        mat.diffuse_color = (*col, 1.0)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (*col, 1.0)
        MATERIALS[nm] = mat

    jobs = []
    # Buildings: <zone>_<stage>_<size>_<variant>
    jobs += [("r_1_1_a", "buildings", lambda n: res_house(n, 11, 1, "gable", porch=True)),
             ("r_1_1_b", "buildings", lambda n: res_house(n, 12, 2, "gable", porch=True)),
             ("r_1_1_c", "buildings", lambda n: res_house(n, 13, 2, "hip", porch=False, garage=True, hipped=True)),
             ("r_1_1_d", "buildings", lambda n: res_house(n, 14, 1, "hip", porch=True, garage=True, hipped=True)),
             ("r_2_1_a", "buildings", lambda n: res_walkup(n, 21, 3, "Brick")),
             ("r_2_1_b", "buildings", lambda n: res_walkup(n, 22, 4, "Wall")),
             ("r_2_1_c", "buildings", lambda n: res_walkup(n, 23, 5, "Brick")),
             ("r_2_1_d", "buildings", lambda n: res_walkup(n, 24, 4, "Accent")),
             ("r_3_1_a", "buildings", lambda n: res_tower(n, 31, 8)),
             ("r_3_1_b", "buildings", lambda n: res_tower(n, 32, 11)),
             ("r_3_1_c", "buildings", lambda n: res_tower(n, 33, 14)),
             ("r_3_2_a", "buildings", lambda n: res_tower(n, 34, 18, size=2)),
             ("r_3_2_b", "buildings", lambda n: res_tower(n, 35, 24, size=2)),
             ("c_1_1_a", "buildings", lambda n: com_shop(n, 41, "single")),
             ("c_1_1_b", "buildings", lambda n: com_shop(n, 42, "double")),
             ("c_1_1_c", "buildings", lambda n: com_shop(n, 43, "gas")),
             ("c_1_1_d", "buildings", lambda n: com_shop(n, 44, "single")),
             ("c_2_1_a", "buildings", lambda n: com_midrise(n, 51, 3)),
             ("c_2_1_b", "buildings", lambda n: com_midrise(n, 52, 4)),
             ("c_2_1_c", "buildings", lambda n: com_midrise(n, 53, 6)),
             ("c_3_1_a", "buildings", lambda n: com_tower(n, 61, 12)),
             ("c_3_1_b", "buildings", lambda n: com_tower(n, 62, 18)),
             ("c_3_1_c", "buildings", lambda n: com_tower(n, 63, 22)),
             ("c_3_2_a", "buildings", lambda n: com_tower(n, 64, 30, size=2)),
             ("c_3_2_b", "buildings", lambda n: com_tower(n, 65, 40, size=2)),
             ("i_1_1_a", "buildings", lambda n: ind_shed(n, 71, "flat")),
             ("i_1_1_b", "buildings", lambda n: ind_shed(n, 72, "gable")),
             ("i_1_1_c", "buildings", lambda n: ind_shed(n, 73, "brick")),
             ("i_2_1_a", "buildings", lambda n: ind_warehouse(n, 81, True)),
             ("i_2_1_b", "buildings", lambda n: ind_warehouse(n, 82, False)),
             ("i_2_1_c", "buildings", lambda n: ind_warehouse(n, 83, True)),
             ("i_3_1_a", "buildings", lambda n: ind_factory(n, 91)),
             ("i_3_1_b", "buildings", lambda n: ind_factory(n, 92)),
             ("i_3_2_a", "buildings", lambda n: ind_factory(n, 93, size=2))]
    jobs += [("road_straight", "roads", lambda n: road_piece(n, {"N", "S"})),
             ("road_corner", "roads", lambda n: road_piece(n, {"N", "E"})),
             ("road_t", "roads", lambda n: road_piece(n, {"N", "E", "S"})),
             ("road_cross", "roads", lambda n: road_piece(n, {"N", "E", "S", "W"})),
             ("road_end", "roads", lambda n: road_piece(n, {"N"})),
             ("road_single", "roads", lambda n: road_piece(n, set()))]
    jobs += [("street_lamp", "props", street_lamp), ("traffic_light", "props", traffic_light),
             ("tree_round_a", "props", lambda n: tree_round(n, 1)),
             ("tree_round_b", "props", lambda n: tree_round(n, 2)),
             ("tree_pine", "props", lambda n: tree_pine(n, 3)),
             ("palm", "props", lambda n: palm(n, 4)),
             ("bush", "props", lambda n: bush(n, 5))]
    jobs += [("car_" + k, "cars", (lambda kk: (lambda n: car(n, kk)))(k)) for k in ("sedan", "hatch", "van", "truck")]

    only = set(sys.argv[sys.argv.index("--") + 1:]) if "--" in sys.argv else None
    total = 0
    for name, sub, fn in jobs:
        if only and name not in only and sub not in only:
            continue
        ob = fn(name)
        total += sum(len(p.vertices) - 2 for p in ob.data.polygons)
        export(ob, sub)
        bpy.data.objects.remove(ob, do_unlink=True)
    print(f"done, {total} tris total -> {OUT}")


if __name__ == "__main__":
    main()
