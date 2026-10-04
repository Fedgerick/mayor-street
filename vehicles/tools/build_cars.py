"""Blender-scripted car kit for MayorStreet (round 3).

Builds every vehicle the city needs from code: rounded subdivided bodies with wheel
arches, real wheels (tyre, rim, spokes), see-through glass with a driver inside,
headlights, tail lights, sirens and light bars, three damage stages and three LODs.

Run headless (pip `bpy` 4.2):
    python3 vehicles/tools/build_cars.py [-- name ...] [--out DIR]

Output, per model `<name>` (see MODELS):
    <name>.glb        LOD0, about 6,000 triangles, glass is its own transparent surface
    <name>_lod1.glb   LOD1, about 1,500 triangles, one surface (glass opaque)
    <name>_lod2.glb   LOD2, about 300 triangles, one surface
    <name>_dmg1.glb   LOD0 dented
    <name>_dmg2.glb   LOD0 smashed: deeper dents, cracked glass, broken lights
    <name>_dmg3.glb   LOD0 burnt-out wreck: charred, no glass, no tyres, no driver
    specs.json        sizes, axles, wheel radius, seat and siren data for the game code

Conventions match the city kit: Blender +Y is the car's front (Godot -Z), origin on the
ground under the middle of the car, metres.

Every mesh uses at most two materials, `VehBody` and `VehGlass`; the look of each part
is carried in the UVs and read by vehicles/shaders/vehicle.gdshader:
    UV.x  part id (PAINT, GLOSS, TIRE, HEADLIGHT, ... see PART below)
    UV.y  palette index, or for wheels the wheel centre's x
    UV2   for wheels: the wheel centre (Godot z, Godot y), so the shader can spin and
          steer them per instance.
"""
import json
import math
import os
import random
import sys

import bpy  # noqa: E402  (bpy must load before bmesh)
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets"))

# ------------------------------------------------------------- parts -------
PART = {
    "PAINT": 0,      # instance tint (MultiMesh colour)
    "SOLID": 1,      # palette colour, satin plastic
    "GLOSS": 2,      # palette colour, glossy paint (liveries)
    "CHROME": 3,
    "TIRE": 4,       # UV.y = wheel centre x
    "RIM": 5,        # UV.y = wheel centre x
    "HEADLIGHT": 6,
    "TAILLIGHT": 7,  # brightens with the brake flag
    "SIREN_R": 8,
    "SIREN_B": 9,
    "SKIN": 10,      # driver / passengers, colour from the instance seed
    "CLOTH": 11,
    "HAIR": 12,
    "AMBER": 13,
    "BURNT": 14,
    "GLASS_OPAQUE": 15,
    "SIGN": 16,      # palette colour, glows at night
    "REVERSE": 17,
    "GLASS": 100,    # goes to the VehGlass surface; UV.x there = 0 clean, 1 cracked
}
# Palette indices (mirrored in the shader).
BLACK, DARK, GREY, LIGHT, WHITE, TAXI, NAVY, RED, GREEN, BLUE, ORANGE, TAN, SILVER, BEIGE, CREAM, AMBERC = range(16)


class M:
    """Material keys: (part, palette/wheel index)."""
    _keys = []

    @classmethod
    def idx(cls, part, pal=0):
        k = (PART[part], pal)
        if k not in cls._keys:
            cls._keys.append(k)
        return cls._keys.index(k)

    @classmethod
    def key(cls, i):
        return cls._keys[i]


def mi(part, pal=0):
    return M.idx(part, pal)


# --------------------------------------------------------- bmesh helpers ---

def merge(bm, src, mat=None, xf=None):
    """Copy bmesh `src` into `bm` (optionally transformed); faces keep src material
    unless `mat` is given."""
    vmap = {}
    for v in src.verts:
        co = v.co.copy()
        if xf is not None:
            co = xf @ co
        vmap[v] = bm.verts.new(co)
    out = []
    for f in src.faces:
        try:
            nf = bm.faces.new([vmap[v] for v in f.verts])
        except ValueError:
            continue
        nf.material_index = f.material_index if mat is None else mat
        nf.smooth = f.smooth
        out.append(nf)
    return out


def frame_from_normal(n):
    """Matrix whose Z axis points along n (X stays as horizontal as it can)."""
    n = Vector(n).normalized()
    up = Vector((0, 0, 1)) if abs(n.z) < 0.95 else Vector((0, 1, 0))
    x = up.cross(n).normalized()
    y = n.cross(x).normalized()
    return Matrix((x, y, n)).transposed().to_4x4()


def rbox(size, mat, bevel=0.0, seg=2, smooth=True):
    """Rounded box centred on the origin."""
    t = bmesh.new()
    bmesh.ops.create_cube(t, size=1.0)
    for v in t.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
    if bevel > 0:
        b = min(bevel, min(size) * 0.49)
        bmesh.ops.bevel(t, geom=list(t.edges), offset=b, segments=seg, profile=0.5, affect="EDGES")
    for f in t.faces:
        f.material_index = mat
        f.smooth = smooth
    return t


def cyl(r, length, mat, seg=12, cap_mat=None, r2=None, smooth=True):
    """Cylinder along X centred on the origin."""
    t = bmesh.new()
    r2 = r if r2 is None else r2
    a, b = [], []
    for i in range(seg):
        ang = 2 * math.pi * i / seg
        a.append(t.verts.new((-length / 2, r * math.cos(ang), r * math.sin(ang))))
        b.append(t.verts.new((length / 2, r2 * math.cos(ang), r2 * math.sin(ang))))
    for i in range(seg):
        j = (i + 1) % seg
        f = t.faces.new((a[i], a[j], b[j], b[i]))
        f.material_index = mat
        f.smooth = smooth
    for ring in (a, b):
        f = t.faces.new(ring)
        f.material_index = mat if cap_mat is None else cap_mat
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return t


def sphere(r, mat, seg=10, rings=6, scale=(1, 1, 1)):
    t = bmesh.new()
    bmesh.ops.create_uvsphere(t, u_segments=seg, v_segments=rings, radius=r)
    for v in t.verts:
        v.co = Vector((v.co.x * scale[0], v.co.y * scale[1], v.co.z * scale[2]))
    for f in t.faces:
        f.material_index = mat
        f.smooth = True
    return t


def lathe(profile, seg, mats):
    """Revolve [(x, r), ...] around the X axis. mats: one material per profile segment."""
    t = bmesh.new()
    rings = []
    for x, r in profile:
        ring = []
        for i in range(seg):
            a = 2 * math.pi * i / seg
            ring.append(t.verts.new((x, r * math.cos(a), r * math.sin(a))))
        rings.append(ring)
    for k in range(len(rings) - 1):
        for i in range(seg):
            j = (i + 1) % seg
            vs = (rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i])
            if len({v.co.to_tuple(5) for v in vs}) < 3:
                continue
            try:
                f = t.faces.new(vs)
            except ValueError:
                continue
            f.material_index = mats[k]
            f.smooth = True
    return t


def torus(R, r, mat, seg=14, sides=5):
    t = bmesh.new()
    rings = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        c = Vector((R * math.cos(a), R * math.sin(a), 0))
        d = Vector((math.cos(a), math.sin(a), 0))
        ring = []
        for k in range(sides):
            b = 2 * math.pi * k / sides
            ring.append(t.verts.new(c + d * (r * math.cos(b)) + Vector((0, 0, r * math.sin(b)))))
        rings.append(ring)
    for i in range(seg):
        for k in range(sides):
            f = t.faces.new((rings[i][k], rings[(i + 1) % seg][k], rings[(i + 1) % seg][(k + 1) % sides], rings[i][(k + 1) % sides]))
            f.material_index = mat
            f.smooth = True
    return t


def tris_of(bm):
    return sum(len(f.verts) - 2 for f in bm.faces)


# -------------------------------------------------------------- body cage ---
# A loft of cross-section rings along Y. Each station: (y, half width, bottom z, belt z,
# crown). The greenhouse (cabin) sits on the top faces between stations g0..g1.

RING = 12  # a b c d e f g f' e' d' c' b'


def ring_points(s, prof):
    y, w, zc, zb, crown = s
    side = prof.get("side", 0.0)   # how slab-sided (0 round .. 1 boxy)
    sh = prof.get("shoulder", 0.16)
    pts = [
        (0.0, zc),
        (w - 0.10 * (1 - side * 0.6), zc),
        (w - 0.01, zc + 0.16),
        (w, zc + (zb - zc) * 0.55),
        (w - 0.04 * (1 - side), zb),
        (w - sh, zb + crown * 0.55),
        (0.0, zb + crown),
    ]
    full = pts + [(-x, z) for x, z in reversed(pts[1:-1])]
    return [Vector((x, y, z)) for x, z in full]


def seg_of(j):
    """Ring segment j (between ring points j and j+1) -> (segment 0..5, side +1/-1)."""
    return (j, 1) if j < 6 else (11 - j, -1)


def build_cage(spec, lod):
    st = spec["stations"]
    gh = spec.get("greenhouse")
    paint = spec.get("paint_fn") or (lambda k, s, side: mi("PAINT"))
    trim = mi("SOLID", BLACK)
    glass = mi("GLASS") if lod == 0 else mi("GLASS_OPAQUE")
    bm = bmesh.new()
    V = [[bm.verts.new(p) for p in ring_points(s, spec)] for s in st]
    n = len(st)
    g0, g1 = (gh["g0"], gh["g1"]) if gh else (n, n)
    for k in range(n - 1):
        for j in range(RING):
            s, side = seg_of(j)
            if gh and g0 <= k < g1 and s == 5:
                continue  # roof goes here
            f = bm.faces.new((V[k][j], V[k][(j + 1) % RING], V[k + 1][(j + 1) % RING], V[k + 1][j]))
            f.material_index = paint(k, s, side)
            f.smooth = True
    # Caps.
    for k in (0, n - 1):
        f = bm.faces.new(V[k])
        f.material_index = paint(k if k == 0 else n - 2, 2, 1)
        f.smooth = True
    side_faces, front_faces, rear_faces = [], [], []
    if gh:
        yr, yf = gh["y_rear"], gh["y_front"]
        zr = gh["z_roof"]
        rw = gh.get("roof_w", 0.82)
        y0, y1 = st[g0][0], st[g1][0]
        T = {}
        for k in range(g0, g1 + 1):
            yk = st[k][0]
            ty = yr + (yk - y0) / (y1 - y0) * (yf - yr)
            if "mid_y" in gh and k in gh["mid_y"]:
                ty = gh["mid_y"][k]
            fx = V[k][5].co.x
            T[k] = (bm.verts.new((fx * rw, ty, zr - gh.get("roof_edge", 0.05))),
                    bm.verts.new((0.0, ty, zr)),
                    bm.verts.new((-fx * rw, ty, zr - gh.get("roof_edge", 0.05))))
        for k in range(g0, g1):
            for a, b in ((0, 1), (1, 2)):
                f = bm.faces.new((T[k][a], T[k][b], T[k + 1][b], T[k + 1][a]))
                f.material_index = gh.get("roof_mat", None) or paint(k, 6, 1)
                f.smooth = True
            for vi, ti in ((5, 0), (7, 2)):
                f = bm.faces.new((V[k][vi], V[k + 1][vi], T[k + 1][ti], T[k][ti]))
                g = gh.get("side_glass", [True] * (g1 - g0))[k - g0]
                f.material_index = glass if g else paint(k, 7, 1 if vi == 5 else -1)
                f.smooth = True
                if g:
                    side_faces.append(f)
        for k, lst in ((g1, front_faces), (g0, rear_faces)):
            for vi, vj, ti, tj in ((5, 6, 0, 1), (6, 7, 1, 2)):
                f = bm.faces.new((V[k][vi], V[k][vj], T[k][tj], T[k][ti]))
                isg = gh.get("rear_glass", True) if k == g0 else True
                f.material_index = glass if isg else paint(k, 7, 1)
                f.smooth = True
                if isg:
                    lst.append(f)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Window frames: inset the glass so a black frame (and pillars) runs round each pane.
    cr = bm.edges.layers.float.get("crease_edge") or bm.edges.layers.float.new("crease_edge")
    glass_set, frames = [], []
    if gh:
        fw = spec.get("frame", 0.04)
        for grp in (front_faces, rear_faces):
            if grp:
                r = bmesh.ops.inset_region(bm, faces=grp, thickness=fw, depth=-0.01, use_even_offset=True)
                frames += r["faces"]
                glass_set += grp
        if side_faces:
            r = bmesh.ops.inset_individual(bm, faces=side_faces, thickness=fw * 0.85, depth=-0.01, use_even_offset=True)
            frames += r["faces"]
            glass_set += side_faces
        for f in frames:
            f.material_index = trim
            for e in f.edges:
                e[cr] = max(e[cr], 0.8)
        for f in glass_set:
            for e in f.edges:
                e[cr] = 1.0
    # Boxy vehicles keep their roof edges and pillars sharper.
    if gh and spec.get("boxy"):
        for k in range(g0, g1):
            for a in (0, 2):
                e = bm.edges.get((T[k][a], T[k + 1][a]))
                if e:
                    e[cr] = spec["boxy"]
        for k in (g0, g1):
            for a, b in ((0, 1), (1, 2)):
                e = bm.edges.get((T[k][a], T[k][b]))
                if e:
                    e[cr] = spec["boxy"] * 0.8
    # Keep the shoulder line and the sill crisp.
    for k in range(n - 1):
        for j in (4, 8, 1, 11):
            e = bm.edges.get((V[k][j], V[k + 1][j]))
            if e:
                e[cr] = spec.get("crease_belt", 0.55) if j in (4, 8) else 0.75
    return bm


def object_from_bm(bm, name):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    for _ in M._keys:
        pass
    return ob


def apply_mods(ob):
    bpy.context.view_layer.objects.active = ob
    for md in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=md.name)


def ensure_slots(ob):
    """Give an object one material slot per material key (booleans need slots)."""
    me = ob.data
    while len(me.materials) < len(M._keys):
        i = len(me.materials)
        nm = "K%d" % i
        mat = bpy.data.materials.get(nm) or bpy.data.materials.new(nm)
        me.materials.append(mat)


def subdivide_body(bm, levels):
    ob = object_from_bm(bm, "body")
    bm.free()
    ensure_slots(ob)
    if levels > 0:
        md = ob.modifiers.new("ss", "SUBSURF")
        md.levels = levels
        md.render_levels = levels
        md.uv_smooth = "NONE"
        md.use_creases = True
        apply_mods(ob)
    return ob


BODY_BUDGET = (2900, 820, 180)


def decimate(ob, budget):
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    if tris <= budget:
        return
    md = ob.modifiers.new("dec", "DECIMATE")
    md.decimate_type = "COLLAPSE"
    md.ratio = budget / tris
    md.use_symmetry = True
    md.symmetry_axis = "X"
    md.use_collapse_triangulate = False
    apply_mods(ob)


def fit(ob, spec):
    """Scale the subdivided body to the target length, width and height."""
    me = ob.data
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    L, W, H = spec["L"], spec["W"], spec["H"]
    y0, y1 = min(ys), max(ys)
    x1 = max(abs(min(xs)), max(xs))
    z0, z1 = min(zs), max(zs)
    zc = spec["stations"][len(spec["stations"]) // 2][2]
    yc = spec.get("y_center", 0.0)
    for v in me.vertices:
        x, y, z = v.co
        v.co = Vector((x / x1 * W / 2,
                       yc - L / 2 + (y - y0) / (y1 - y0) * L,
                       zc + (z - z0) / (z1 - z0) * (H - zc)))


def boolean(ob, cutter_bm, op="DIFFERENCE"):
    cut = object_from_bm(cutter_bm, "cutter")
    cutter_bm.free()
    ensure_slots(cut)
    md = ob.modifiers.new("b", "BOOLEAN")
    md.operation = op
    md.object = cut
    md.solver = "EXACT"
    md.material_mode = "TRANSFER"
    apply_mods(ob)
    bpy.data.objects.remove(cut, do_unlink=True)


def arch_cutters(spec, lod):
    """One pocket per wheel: from just inside the tyre out past the body side, so the
    hood and floor between the wheels stay whole."""
    seg = 20 if lod == 0 else (12 if lod == 1 else 8)
    out = bmesh.new()
    well = mi("SOLID", BLACK)
    ww = spec.get("wheel_w", 0.24)
    for wy, r, dual in spec["axles"]:
        w = ww * (1.7 if dual else 1.0)
        x0 = spec["track"] - w / 2 - 0.08
        x1 = spec["W"] / 2 + 0.3
        for s in (-1, 1):
            c = cyl(r + 0.05, x1 - x0, well, seg=seg, smooth=True)
            merge(out, c, xf=Matrix.Translation((s * (x0 + x1) / 2, wy, r + 0.01)))
            c.free()
    return out


# -------------------------------------------------------------- wheels -----

def wheel(r, width, wheel_id, lod, dual=False, burnt=False):
    """A wheel facing +X (outer face), centred on the origin."""
    tire = mi("TIRE", wheel_id) if not burnt else mi("BURNT")
    rim = mi("RIM", wheel_id) if not burnt else mi("BURNT")
    hw = width / 2
    ri = r * 0.64  # rim radius
    if lod == 2:
        t = cyl(r, width, tire, seg=6, cap_mat=rim, smooth=False)
        return t
    seg = 14 if lod == 0 else 8
    out = bmesh.new()
    if not burnt:
        prof = [(-hw, ri * 0.98), (-hw - 0.01, r * 0.88), (-hw * 0.7, r),
                (hw * 0.7, r), (hw + 0.01, r * 0.88), (hw, ri * 0.98)]
        if lod == 1:
            prof = [prof[0], prof[2], prof[3], prof[5]]
        t = lathe(prof, seg, [tire] * (len(prof) - 1))
        merge(out, t)
        t.free()
    # Rim: dish with a lip, then a hub; spokes in front.
    rp = [(hw - 0.005, ri), (hw - 0.05, ri * 0.86), (hw - 0.07, ri * 0.3), (hw - 0.02, 0.0)]
    if lod == 1:
        rp = [rp[0], rp[1], rp[3]]
    t = lathe(rp, seg, [rim] * (len(rp) - 1))
    merge(out, t)
    t.free()
    # Inner face so the wheel is closed from behind.
    t = lathe([(-hw, ri * 0.98), (-hw + 0.02, 0.0)], seg, [mi("SOLID", BLACK)])
    merge(out, t)
    t.free()
    if lod == 0:
        n = 5 if r < 0.45 else 8
        for i in range(n):
            a = 2 * math.pi * i / n
            sp = rbox((0.03, ri * 0.62, ri * 0.16), rim, bevel=0.0)
            xf = Matrix.Translation((hw - 0.05, 0, 0)) @ Matrix.Rotation(a, 4, "X") @ Matrix.Translation((0, ri * 0.55, 0))
            merge(out, sp, xf=xf)
            sp.free()
        hub = cyl(ri * 0.22, 0.04, mi("CHROME") if not burnt else mi("BURNT"), seg=8)
        merge(out, hub, xf=Matrix.Translation((hw - 0.02, 0, 0)))
        hub.free()
    return out


def add_wheels(bm, spec, lod, burnt=False):
    centers = []
    wid = 0
    for wy, r, dual in spec["axles"]:
        for s in (-1, 1):
            tx = spec["track"]
            ww = spec.get("wheel_w", 0.24)
            if dual:
                ww *= 1.7
            w = wheel(r, ww, wid, lod, dual, burnt)
            xf = Matrix.Translation((s * (tx + (0.05 if lod == 2 else 0.0)), wy, r))
            if s < 0:
                xf = xf @ Matrix.Rotation(math.pi, 4, "Z")
            if burnt:
                xf = Matrix.Translation((0, 0, -r * 0.18)) @ xf
            merge(bm, w, xf=xf)
            w.free()
            centers.append((s * tx, wy, r))
            wid += 1
    return centers


# ----------------------------------------------------------- placements ----

class Surface:
    def __init__(self, bm):
        self.tree = BVHTree.FromBMesh(bm)

    def free(self):
        self.tree = None

    def hit(self, origin, direction):
        loc, nrm, _i, _d = self.tree.ray_cast(Vector(origin), Vector(direction).normalized())
        return loc, nrm

    def put(self, bm, part_bm, origin, direction, sink=0.0, spin=0.0):
        loc, nrm = self.hit(origin, direction)
        if loc is None:
            part_bm.free()
            return None
        xf = Matrix.Translation(loc - nrm * sink) @ frame_from_normal(nrm) @ Matrix.Rotation(spin, 4, "Z")
        merge(bm, part_bm, xf=xf)
        part_bm.free()
        return loc, nrm


def lens(w, h, d, mat, bevel=0.03):
    return rbox((w, h, d), mat, bevel=bevel, seg=1)


def add_lights(bm, surf, spec, lod, ext, broken=0):
    W = spec["W"]
    yf, yb = ext[1] + 1.0, ext[0] - 1.0
    hz = spec.get("head_z", 0.72)
    tz = spec.get("tail_z", 0.8)
    hx = W / 2 - spec.get("head_in", 0.32)
    tx = W / 2 - spec.get("tail_in", 0.28)
    hs = spec.get("head_size", (0.36, 0.15))
    ts = spec.get("tail_size", (0.32, 0.16))
    head = mi("HEADLIGHT")
    dead = mi("SOLID", DARK)
    bv = 0.03 if lod == 0 else 0.0
    for s in (-1, 1):
        broke = (broken >= 1 and s < 0) or broken >= 2
        surf.put(bm, lens(hs[0], 0.06, hs[1], dead if broke else head, bv), (s * hx, yf, hz), (0, -1, 0), sink=0.015)
        surf.put(bm, lens(ts[0], 0.06, ts[1], mi("TAILLIGHT") if not (broken >= 2 and s > 0) else dead, bv),
                 (s * tx, yb, tz), (0, 1, 0), sink=0.015)
        if lod == 0:
            surf.put(bm, lens(0.12, 0.05, 0.07, mi("AMBER")), (s * (hx + hs[0] * 0.5 - 0.02), yf, hz - hs[1] * 0.8), (0, -1, 0), sink=0.01)
            surf.put(bm, lens(0.1, 0.05, 0.06, mi("REVERSE")), (s * (tx - ts[0] * 0.5 - 0.08), yb, tz), (0, 1, 0), sink=0.01)
    if lod == 0 and spec.get("plates", True):
        pz = spec.get("plate_z", 0.5)
        surf.put(bm, rbox((0.52, 0.03, 0.13), mi("SOLID", CREAM), 0.01, 1), (0, yb, spec.get("plate_z_rear", pz + 0.12)), (0, 1, 0), sink=0.008)
        surf.put(bm, rbox((0.52, 0.03, 0.13), mi("SOLID", CREAM), 0.01, 1), (0, yf, pz), (0, -1, 0), sink=0.008)


def add_bumpers(bm, spec, lod, ext, mat=None):
    W = spec["W"]
    bz = spec.get("bumper_z", 0.42)
    mat = mi("SOLID", DARK) if mat is None else mat
    seg = 2 if lod == 0 else 1
    for y in (ext[1] - 0.06, ext[0] + 0.06):
        b = rbox((W * 0.96, 0.22, 0.2), mat, bevel=0.07 if lod == 0 else 0.0, seg=seg)
        merge(bm, b, xf=Matrix.Translation((0, y, bz)))
        b.free()


def add_grille(bm, surf, spec, ext, mat=None):
    gz = spec.get("grille_z", 0.62)
    g = rbox(spec.get("grille", (0.7, 0.05, 0.16)), mat if mat is not None else mi("SOLID", BLACK), 0.02, 1)
    surf.put(bm, g, (0, ext[1] + 1.0, gz), (0, -1, 0), sink=0.01)


def add_mirrors(bm, spec, lod):
    if lod > 0:
        return
    my, mz = spec["mirror"]
    for s in (-1, 1):
        x = s * (spec["W"] / 2 + 0.06)
        arm = rbox((0.12, 0.05, 0.04), mi("SOLID", BLACK))
        merge(bm, arm, xf=Matrix.Translation((x - s * 0.06, my, mz)))
        arm.free()
        hd = rbox((0.08, 0.13, 0.12), mi("PAINT") if not spec.get("mirror_mat") else spec["mirror_mat"], bevel=0.035, seg=2)
        merge(bm, hd, xf=Matrix.Translation((x + s * 0.02, my - 0.03, mz)))
        hd.free()
        gl = rbox((0.012, 0.09, 0.08), mi("CHROME"), bevel=0.0)
        merge(bm, gl, xf=Matrix.Translation((x + s * 0.02, my - 0.1, mz)))
        gl.free()


def add_handles(bm, surf, spec, lod):
    if lod > 0:
        return
    for y in spec.get("handles", []):
        for s in (-1, 1):
            surf.put(bm, rbox((0.16, 0.035, 0.035), mi("CHROME"), 0.012, 1),
                     (s * (spec["W"] + 1), y, spec["handle_z"]), (-s, 0, 0), sink=0.005)


# ------------------------------------------------------------- interior ----

def person(seat, mat_cloth, lod, scale=1.0, arms_to=None, hair=True):
    """Seated upper body: torso, neck, head, hair, arms. seat = hip point."""
    out = bmesh.new()
    x, y, z = seat
    sc = scale
    tor = rbox((0.36 * sc, 0.22 * sc, 0.5 * sc), mat_cloth, bevel=0.08 * sc, seg=1 if lod else 2)
    merge(out, tor, xf=Matrix.Translation((x, y, z + 0.28 * sc)))
    tor.free()
    head = sphere(0.105 * sc, mi("SKIN"), seg=10 if lod == 0 else 6, rings=6 if lod == 0 else 4, scale=(0.9, 1.0, 1.12))
    merge(out, head, xf=Matrix.Translation((x, y + 0.02 * sc, z + 0.68 * sc)))
    head.free()
    if lod == 0:
        neck = rbox((0.08, 0.08, 0.1), mi("SKIN"))
        merge(out, neck, xf=Matrix.Translation((x, y, z + 0.55 * sc)))
        neck.free()
        if hair:
            hr = sphere(0.112 * sc, mi("HAIR"), seg=10, rings=5, scale=(0.92, 1.02, 0.85))
            # keep only the top/back half
            bmesh.ops.delete(hr, geom=[v for v in hr.verts if v.co.z < -0.02 and v.co.y > -0.03], context="VERTS")
            merge(out, hr, xf=Matrix.Translation((x, y - 0.005, z + 0.715 * sc)))
            hr.free()
        if arms_to is not None:
            for s in (-1, 1):
                sh = Vector((x + s * 0.17 * sc, y, z + 0.46 * sc))
                hand = Vector((arms_to[0] + s * 0.16, arms_to[1], arms_to[2]))
                d = hand - sh
                arm = cyl(0.045 * sc, d.length, mat_cloth, seg=6, r2=0.04 * sc)
                rot = Vector((1, 0, 0)).rotation_difference(d.normalized()).to_matrix().to_4x4()
                merge(out, arm, xf=Matrix.Translation((sh + hand) / 2) @ rot)
                arm.free()
                hs = sphere(0.04, mi("SKIN"), seg=6, rings=4)
                merge(out, hs, xf=Matrix.Translation(hand))
                hs.free()
    return out


def seat(w, depth, back_h, mat, lod):
    out = bmesh.new()
    b = rbox((w, depth, 0.14), mat, bevel=0.05 if lod == 0 else 0, seg=1)
    merge(out, b, xf=Matrix.Translation((0, 0, 0.07)))
    b.free()
    bk = rbox((w, 0.14, back_h), mat, bevel=0.05 if lod == 0 else 0, seg=1)
    merge(out, bk, xf=Matrix.Translation((0, -depth / 2 + 0.02, back_h / 2 + 0.08)) @ Matrix.Rotation(-0.2, 4, "X"))
    bk.free()
    if lod == 0:
        hr = rbox((min(w, 0.26), 0.1, 0.16), mat, bevel=0.04, seg=1)
        merge(out, hr, xf=Matrix.Translation((0, -depth / 2 - 0.06, back_h + 0.16)))
        hr.free()
    return out


def add_cabin(bm, spec, lod, driver=True, passengers=None):
    """Inward-facing tub (door cards, floor), headliner, dashboard, seats, wheel, driver."""
    c = spec["cabin"]
    y0, y1 = c["y"]          # rear wall .. dashboard
    wi = c["w"]              # inner half width
    zf, zb, zr = c["floor"], c["belt"], c["roof"]
    trim = mi("SOLID", c.get("trim", DARK))
    # Tub: four walls up to the belt and the floor, normals pointing inward.
    t = bmesh.new()
    p = [t.verts.new(v) for v in ((-wi, y0, zf), (wi, y0, zf), (wi, y1, zf), (-wi, y1, zf),
                                    (-wi, y0, zb), (wi, y0, zb), (wi, y1, zb), (-wi, y1, zb))]
    for q in ((0, 1, 2, 3), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)):
        f = t.faces.new([p[i] for i in q])
        f.material_index = trim
    # Normals inward: flip the outward ones.
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    bmesh.ops.reverse_faces(t, faces=t.faces)
    merge(bm, t)
    t.free()
    if c.get("headliner", True):
        hl = bmesh.new()
        hy0, hy1 = c.get("roof_y", (y0, y1))
        q = [hl.verts.new(v) for v in ((-wi * 0.92, hy0, zr), (wi * 0.92, hy0, zr), (wi * 0.92, hy1, zr), (-wi * 0.92, hy1, zr))]
        f = hl.faces.new(q)
        f.material_index = mi("SOLID", c.get("liner", LIGHT))
        f.normal_update()
        if f.normal.z > 0:
            f.normal_flip()
        merge(bm, hl)
        hl.free()
    # Dashboard.
    dash = rbox((wi * 2, 0.3, 0.16), mi("SOLID", BLACK), bevel=0.05 if lod == 0 else 0, seg=1)
    merge(bm, dash, xf=Matrix.Translation((0, y1 - 0.15, zb - 0.02)))
    dash.free()
    dx = -spec.get("driver_x", 0.36)
    sy = c["seat_y"]
    sz = zf + 0.12
    seat_mat = mi("SOLID", c.get("seat", DARK))
    for x in (dx, -dx):
        s = seat(0.46, 0.46, 0.55, seat_mat, lod)
        merge(bm, s, xf=Matrix.Translation((x, sy, sz)))
        s.free()
    for ry in c.get("rear_rows", []):
        s = seat(wi * 1.8, 0.44, 0.52, seat_mat, lod)
        merge(bm, s, xf=Matrix.Translation((0, ry, sz)))
        s.free()
    wheel_at = Vector((dx, y1 - 0.38, zb + 0.06))
    if lod == 0:
        sw = torus(0.17, 0.022, mi("SOLID", BLACK), seg=12, sides=4)
        merge(bm, sw, xf=Matrix.Translation(wheel_at) @ Matrix.Rotation(math.radians(65), 4, "X"))
        sw.free()
    if driver:
        hip = (dx, sy - 0.02, sz + 0.14)
        p = person(hip, mi("CLOTH", c.get("uniform", 0)), lod, scale=c.get("driver_scale", 1.0),
                   arms_to=(wheel_at.x, wheel_at.y - 0.02, wheel_at.z + 0.06))
        merge(bm, p)
        p.free()
    for i, px in enumerate(passengers or []):
        p = person((px[0], px[1], sz + 0.14), mi("CLOTH", 8 + i % 8), 1, scale=0.95)
        merge(bm, p)
        p.free()


# --------------------------------------------------------------- extras ----

def light_bar(bm, at, width, lod, depth=0.26):
    x, y, z = at
    base = rbox((width, depth, 0.07), mi("SOLID", BLACK), bevel=0.02, seg=1)
    merge(bm, base, xf=Matrix.Translation((x, y, z + 0.035)))
    base.free()
    n = 2 if lod else 3
    seg_w = (width - 0.06) / 2 / n
    for s, part in ((-1, "SIREN_R"), (1, "SIREN_B")):
        for i in range(n):
            cx = x + s * (0.03 + seg_w * (i + 0.5))
            l = rbox((seg_w - 0.02, depth - 0.04, 0.1), mi(part), bevel=0.03 if lod == 0 else 0, seg=1)
            merge(bm, l, xf=Matrix.Translation((cx, y, z + 0.12)))
            l.free()
    if lod == 0:
        c = rbox((0.08, depth - 0.06, 0.08), mi("CHROME"), bevel=0.02, seg=1)
        merge(bm, c, xf=Matrix.Translation((x, y, z + 0.11)))
        c.free()


def box_module(bm, x0, x1, y0, y1, z0, z1, mat, lod, bevel=0.1):
    b = rbox((x1 - x0, y1 - y0, z1 - z0), mat, bevel=bevel if lod < 2 else 0.0, seg=2 if lod == 0 else 1)
    merge(bm, b, xf=Matrix.Translation(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)))
    b.free()


def stripe(bm, x, y0, y1, z0, z1, mat, side):
    """A flat livery panel on a flat side (x = side face)."""
    b = rbox((0.012, y1 - y0, z1 - z0), mat)
    merge(bm, b, xf=Matrix.Translation((side * (x + 0.006), (y0 + y1) / 2, (z0 + z1) / 2)))
    b.free()


# --------------------------------------------------------------- models ----

def sedan_stations(L=4.5, W=1.82, zc=0.3, zb=0.92, nose=0.76, tail=0.86, crown=0.06, cab=(-1.2, 1.0), b=-0.05):
    h = L / 2
    return [
        (-h, W / 2 - 0.16, zc + 0.12, tail - 0.04, 0.02),
        (-h + 0.12, W / 2 - 0.04, zc + 0.04, tail, 0.04),
        (-h + 0.6, W / 2, zc, zb, crown),
        (cab[0], W / 2, zc, zb, crown),
        (b - 0.08, W / 2, zc, zb, crown),
        (b + 0.08, W / 2, zc, zb, crown),
        (cab[1], W / 2, zc, zb - 0.02, crown),
        (h - 0.55, W / 2 - 0.02, zc, nose + 0.04, crown),
        (h - 0.12, W / 2 - 0.08, zc + 0.04, nose - 0.02, 0.03),
        (h, W / 2 - 0.2, zc + 0.12, nose - 0.08, 0.01),
    ]


def make_specs():
    S = {}

    # ---- sedan (keeps the old kit's axles: front 1.4, rear -1.35, r 0.36, track 0.81)
    def sedan_like(name, paint_fn=None, extras=None, tint=True, roof_mat=None):
        st = sedan_stations()
        sp = {
            "L": 4.5, "W": 1.82, "H": 1.46, "stations": st, "side": 0.1,
            "greenhouse": {"g0": 3, "g1": 6, "y_rear": -0.82, "y_front": 0.4, "z_roof": 1.5, "roof_w": 0.8,
                           "mid_y": {4: -0.2, 5: -0.06}, "side_glass": [True, False, True], "roof_mat": roof_mat},
            "axles": [(1.4, 0.36, False), (-1.35, 0.36, False)], "track": 0.81, "wheel_w": 0.24,
            "cabin": {"y": (-1.0, 0.5), "w": 0.74, "floor": 0.42, "belt": 0.9, "roof": 1.38, "seat_y": -0.12,
                      "rear_rows": [-0.85], "roof_y": (-0.75, 0.1)},
            "mirror": (0.42, 0.98), "handles": (-0.05, -0.75), "handle_z": 0.86,
            "head_z": 0.68, "tail_z": 0.8, "plate_z": 0.42, "bumper_z": 0.4, "grille_z": 0.56,
            "paint_fn": paint_fn, "extras": extras, "tinted": tint,
        }
        S[name] = sp
        return sp

    sedan_like("car_sedan")

    # ---- taxi: yellow sedan, checker band, roof sign
    def taxi_paint(k, s, side):
        if s in (3,) and 2 <= k <= 6:
            return mi("GLOSS", BLACK)
        return mi("GLOSS", TAXI)

    def taxi_extras(bm, sp, lod, surf):
        sign = rbox((0.62, 0.24, 0.22), mi("SIGN", TAXI), bevel=0.05 if lod == 0 else 0, seg=1)
        merge(bm, sign, xf=Matrix.Translation((0, -0.3, sp["H"] + 0.1)))
        sign.free()
        if lod == 0:
            for i in range(10):
                for row in range(2):
                    pass
    sedan_like("car_taxi", paint_fn=taxi_paint, extras=taxi_extras, tint=False)

    # ---- police: black and white, light bar, push bar
    def police_paint(k, s, side):
        if 3 <= k <= 5 and s in (2, 3, 4):
            return mi("GLOSS", WHITE)
        if s in (6, 7):
            return mi("GLOSS", WHITE)
        return mi("GLOSS", BLACK)

    def police_extras(bm, sp, lod, surf):
        light_bar(bm, (0, -0.28, sp["H"] - 0.005), 1.2, lod)
        if lod == 0:
            pb = rbox((0.9, 0.08, 0.32), mi("SOLID", BLACK), 0.03, 1)
            merge(bm, pb, xf=Matrix.Translation((0, sp["L"] / 2 + 0.06, 0.55)))
            pb.free()
            for s in (-1, 1):
                a = rbox((0.06, 0.06, 0.4), mi("SOLID", BLACK), 0.02, 1)
                merge(bm, a, xf=Matrix.Translation((s * 0.3, sp["L"] / 2 + 0.07, 0.58)))
                a.free()
    sp = sedan_like("car_police", paint_fn=police_paint, extras=police_extras, tint=False, roof_mat=mi("GLOSS", WHITE))
    sp["cabin"]["uniform"] = 6
    sp["siren"] = {"pos": (0, sp["H"] + 0.12, 0.28), "width": 1.2}

    # ---- hatchback (old axles: 1.1, -1.05)
    st = [
        (-1.9, 0.7, 0.42, 0.9, 0.02),
        (-1.82, 0.82, 0.32, 0.94, 0.04),
        (-1.4, 0.85, 0.3, 0.94, 0.05),
        (-0.4, 0.85, 0.3, 0.94, 0.05),
        (-0.28, 0.85, 0.3, 0.94, 0.05),
        (0.55, 0.85, 0.3, 0.92, 0.05),
        (1.4, 0.83, 0.3, 0.8, 0.06),
        (1.78, 0.77, 0.34, 0.72, 0.03),
        (1.9, 0.66, 0.42, 0.64, 0.01),
    ]
    S["car_hatch"] = {
        "L": 3.85, "W": 1.72, "H": 1.5, "stations": st, "side": 0.15,
        "greenhouse": {"g0": 1, "g1": 5, "y_rear": -1.7, "y_front": 0.0, "z_roof": 1.54, "roof_w": 0.82,
                       "mid_y": {2: -1.32, 3: -0.4, 4: -0.28}, "side_glass": [True, True, False, True]},
        "axles": [(1.1, 0.36, False), (-1.05, 0.36, False)], "track": 0.76, "wheel_w": 0.22,
        "cabin": {"y": (-1.55, 0.45), "w": 0.7, "floor": 0.42, "belt": 0.92, "roof": 1.44, "seat_y": -0.05,
                  "rear_rows": [-0.85], "roof_y": (-1.4, 0.05)},
        "mirror": (0.45, 1.0), "handles": (0.05, -0.75), "handle_z": 0.88,
        "head_z": 0.7, "tail_z": 0.95, "tail_in": 0.18, "tail_size": (0.18, 0.3), "plate_z": 0.42, "plate_z_rear": 0.6,
        "bumper_z": 0.42, "grille_z": 0.55, "tinted": True,
    }

    # ---- sports car: low, wide, long nose
    st = [
        (-2.2, 0.8, 0.38, 0.86, 0.02),
        (-2.08, 0.94, 0.28, 0.9, 0.05),
        (-1.4, 0.97, 0.24, 0.9, 0.06),
        (-0.85, 0.95, 0.24, 0.86, 0.06),
        (-0.25, 0.93, 0.24, 0.84, 0.06),
        (0.6, 0.94, 0.24, 0.8, 0.06),
        (1.5, 0.95, 0.24, 0.77, 0.05),
        (2.05, 0.86, 0.26, 0.62, 0.03),
        (2.2, 0.7, 0.3, 0.52, 0.01),
    ]
    S["car_sports"] = {
        "L": 4.45, "W": 1.96, "H": 1.24, "stations": st, "side": 0.0, "shoulder": 0.22, "crease_belt": 0.3,
        "greenhouse": {"g0": 2, "g1": 5, "y_rear": -1.15, "y_front": 0.0, "z_roof": 1.24, "roof_w": 0.74,
                       "mid_y": {3: -0.8, 4: -0.4}, "side_glass": [False, True, True], "roof_edge": 0.06},
        "axles": [(1.42, 0.36, False), (-1.38, 0.37, False)], "track": 0.86, "wheel_w": 0.28,
        "cabin": {"y": (-1.15, 0.55), "w": 0.76, "floor": 0.22, "belt": 0.84, "roof": 1.16, "seat_y": -0.5,
                  "rear_rows": [], "roof_y": (-0.95, -0.2), "driver_scale": 0.86, "seat": RED},
        "mirror": (0.35, 0.9), "handles": (-0.3,), "handle_z": 0.8,
        "head_z": 0.56, "head_size": (0.42, 0.1), "tail_z": 0.74, "tail_size": (0.42, 0.1), "plate_z": 0.36,
        "bumper_z": 0.34, "grille_z": 0.42, "grille": (0.9, 0.05, 0.12), "tinted": True,
    }

    # ---- pickup: cab plus bed (bed is cut out of the body)
    st = [
        (-2.7, 0.88, 0.5, 1.12, 0.02),
        (-2.62, 0.97, 0.45, 1.16, 0.03),
        (-0.65, 0.98, 0.45, 1.16, 0.03),
        (-0.5, 0.98, 0.45, 1.16, 0.04),
        (0.15, 0.98, 0.45, 1.16, 0.04),
        (0.3, 0.98, 0.45, 1.16, 0.04),
        (1.0, 0.98, 0.45, 1.14, 0.05),
        (2.4, 0.97, 0.45, 1.1, 0.06),
        (2.68, 0.92, 0.48, 1.02, 0.03),
        (2.75, 0.84, 0.55, 0.94, 0.01),
    ]
    S["car_pickup"] = {
        "L": 5.5, "W": 2.0, "H": 1.92, "stations": st, "side": 0.6, "boxy": 0.5, "shoulder": 0.1,
        "greenhouse": {"g0": 3, "g1": 6, "y_rear": -0.48, "y_front": 0.55, "z_roof": 1.95, "roof_w": 0.86,
                       "mid_y": {4: 0.12, 5: 0.27}, "side_glass": [True, False, True], "rear_glass": True},
        "axles": [(1.85, 0.42, False), (-1.75, 0.42, False)], "track": 0.86, "wheel_w": 0.28,
        "cabin": {"y": (-0.45, 1.0), "w": 0.82, "floor": 0.62, "belt": 1.14, "roof": 1.84, "seat_y": 0.25,
                  "rear_rows": [], "roof_y": (-0.4, 0.5)},
        "bed": (-2.6, -0.6),
        "mirror": (1.0, 1.25), "handles": (0.4,), "handle_z": 1.08,
        "head_z": 0.92, "head_size": (0.32, 0.2), "tail_z": 0.95, "tail_in": 0.1, "tail_size": (0.14, 0.32),
        "plate_z": 0.6, "plate_z_rear": 0.55, "bumper_z": 0.55, "grille_z": 0.86, "grille": (1.0, 0.05, 0.32),
        "bumper_mat": mi("CHROME"), "tinted": True,
    }

    # ---- van (old axles 1.6, -1.55)
    st = [
        (-2.45, 0.92, 0.42, 1.08, 0.02),
        (-2.38, 0.98, 0.36, 1.1, 0.03),
        (-1.0, 0.98, 0.36, 1.1, 0.03),
        (0.9, 0.98, 0.36, 1.1, 0.03),
        (1.4, 0.98, 0.36, 1.06, 0.04),
        (2.2, 0.95, 0.36, 0.9, 0.06),
        (2.42, 0.88, 0.4, 0.82, 0.03),
        (2.45, 0.8, 0.46, 0.76, 0.01),
    ]
    S["car_van"] = {
        "L": 4.9, "W": 1.98, "H": 2.08, "stations": st, "side": 0.7, "boxy": 0.7, "shoulder": 0.08,
        "greenhouse": {"g0": 1, "g1": 4, "y_rear": -2.4, "y_front": 0.75, "z_roof": 2.1, "roof_w": 0.94,
                       "mid_y": {2: -1.0, 3: 0.7}, "side_glass": [False, False, True], "rear_glass": True},
        "axles": [(1.6, 0.36, False), (-1.55, 0.36, False)], "track": 0.86, "wheel_w": 0.24,
        "cabin": {"y": (-2.3, 1.3), "w": 0.86, "floor": 0.45, "belt": 1.06, "roof": 2.0, "seat_y": 0.55,
                  "rear_rows": [], "roof_y": (-2.2, 0.7)},
        "mirror": (1.3, 1.25), "handles": (0.8,), "handle_z": 1.0,
        "head_z": 0.8, "head_size": (0.3, 0.16), "tail_z": 0.95, "tail_in": 0.13, "tail_size": (0.2, 0.42),
        "plate_z": 0.5, "bumper_z": 0.42, "grille_z": 0.66, "grille": (0.9, 0.05, 0.2), "tinted": True,
    }

    # ---- ambulance: van cab with a box module
    def amb_extras(bm, sp, lod, surf):
        box_module(bm, -1.08, 1.08, -2.75, 0.55, 0.5, 2.62, mi("GLOSS", WHITE), lod, bevel=0.12)
        if lod < 2:
            for s in (-1, 1):
                stripe(bm, 1.08, -2.6, 0.45, 1.0, 1.2, mi("GLOSS", RED), s)
            for s in (-1, 1):
                for yy in (-2.5, 0.42):
                    l = rbox((0.14, 0.14, 0.12), mi("SIREN_R" if (s > 0) == (yy > 0) else "SIREN_B"), 0.03, 1)
                    merge(bm, l, xf=Matrix.Translation((s * 0.95, yy, 2.65)))
                    l.free()
        light_bar(bm, (0, 0.72, 2.0), 1.3, lod)
    st = [
        (-2.85, 0.92, 0.42, 1.08, 0.02),
        (-2.78, 0.98, 0.36, 1.1, 0.03),
        (0.4, 0.98, 0.36, 1.1, 0.03),
        (0.6, 0.98, 0.36, 1.1, 0.03),
        (1.6, 0.98, 0.36, 1.06, 0.04),
        (2.35, 0.95, 0.36, 0.9, 0.06),
        (2.58, 0.88, 0.4, 0.82, 0.03),
        (2.62, 0.8, 0.46, 0.76, 0.01),
    ]
    S["car_ambulance"] = {
        "L": 5.5, "W": 2.0, "H": 2.0, "y_center": -0.12, "stations": st, "side": 0.7, "boxy": 0.7, "shoulder": 0.08,
        "greenhouse": {"g0": 3, "g1": 4, "y_rear": 0.6, "y_front": 1.0, "z_roof": 2.0, "roof_w": 0.94,
                       "side_glass": [True], "rear_glass": False},
        "axles": [(1.75, 0.38, False), (-1.9, 0.38, True)], "track": 0.84, "wheel_w": 0.24,
        "cabin": {"y": (0.55, 1.5), "w": 0.86, "floor": 0.45, "belt": 1.06, "roof": 1.92, "seat_y": 0.9,
                  "rear_rows": [], "roof_y": (0.6, 0.95), "uniform": 9, "headliner": False},
        "mirror": (1.45, 1.25), "handles": (1.1,), "handle_z": 1.0,
        "head_z": 0.8, "head_size": (0.3, 0.16), "tail_z": 1.0, "tail_in": 0.08, "tail_size": (0.14, 0.3),
        "plate_z": 0.5, "bumper_z": 0.42, "grille_z": 0.66, "grille": (0.9, 0.05, 0.2),
        "paint_fn": lambda k, s, side: mi("GLOSS", WHITE), "extras": amb_extras, "tinted": False,
        "siren": {"pos": (0, 2.1, -0.72), "width": 1.3},
    }

    # ---- box truck (old car_truck: axles 2.6, -2.55, -1.4, r 0.48)
    def truck_extras(bm, sp, lod, surf):
        box_module(bm, -1.2, 1.2, -3.42, 1.32, 1.0, 3.3, mi("SOLID", CREAM), lod, bevel=0.06)
        if lod < 2:
            box_module(bm, -1.05, 1.05, -3.25, 1.2, 0.6, 1.0, mi("SOLID", BLACK), lod, bevel=0.02)
            for s in (-1, 1):
                stripe(bm, 1.2, -3.3, 1.2, 1.15, 1.35, mi("PAINT"), s)
    st = [
        (1.3, 1.05, 0.62, 1.66, 0.02),
        (1.36, 1.12, 0.58, 1.7, 0.03),
        (2.2, 1.12, 0.58, 1.7, 0.03),
        (2.9, 1.12, 0.58, 1.6, 0.04),
        (3.3, 1.08, 0.6, 1.4, 0.04),
        (3.42, 1.0, 0.66, 1.28, 0.01),
    ]
    S["car_truck"] = {
        "L": 2.12, "W": 2.24, "H": 2.75, "y_center": 2.36, "stations": st, "side": 0.8, "boxy": 0.7, "shoulder": 0.08,
        "greenhouse": {"g0": 1, "g1": 3, "y_rear": 1.4, "y_front": 2.55, "z_roof": 2.75, "roof_w": 0.95,
                       "mid_y": {2: 2.1}, "side_glass": [False, True], "rear_glass": False},
        "axles": [(2.6, 0.48, False), (-2.55, 0.48, True), (-1.4, 0.48, True)], "track": 0.96, "wheel_w": 0.3,
        "cabin": {"y": (1.42, 3.0), "w": 1.0, "floor": 1.0, "belt": 1.66, "roof": 2.66, "seat_y": 2.05,
                  "rear_rows": [], "roof_y": (1.45, 2.5)},
        "mirror": (2.85, 1.85), "handles": (), "handle_z": 1.3,
        "head_z": 0.95, "head_size": (0.32, 0.18), "tail_z": 0.8, "tail_in": 0.15, "tail_size": (0.16, 0.24),
        "plate_z": 0.7, "bumper_z": 0.62, "grille_z": 1.05, "grille": (1.2, 0.05, 0.4), "body_len": 6.84,
        "extras": truck_extras, "tinted": True,
    }

    # ---- garbage truck
    def garb_extras(bm, sp, lod, surf):
        box_module(bm, -1.25, 1.25, -3.6, 1.15, 1.05, 3.25, mi("GLOSS", GREEN), lod, bevel=0.25)
        box_module(bm, -1.2, 1.2, -4.1, -3.4, 0.75, 3.0, mi("SOLID", GREY), lod, bevel=0.1)
        if lod < 2:
            box_module(bm, -1.1, 1.1, -3.5, 1.1, 0.62, 1.05, mi("SOLID", DARK), lod, bevel=0.02)
            for s in (-1, 1):
                stripe(bm, 1.25, -3.3, 0.9, 1.6, 1.75, mi("GLOSS", WHITE), s)
                for yy in (-4.0,):
                    l = rbox((0.14, 0.1, 0.14), mi("AMBER"), 0.03, 1)
                    merge(bm, l, xf=Matrix.Translation((s * 1.0, yy, 3.05)))
                    l.free()
    st = [
        (1.2, 1.1, 0.62, 1.7, 0.02),
        (1.26, 1.18, 0.58, 1.74, 0.03),
        (2.3, 1.18, 0.58, 1.74, 0.03),
        (3.2, 1.18, 0.58, 1.64, 0.04),
        (3.75, 1.14, 0.6, 1.42, 0.04),
        (3.9, 1.06, 0.66, 1.28, 0.01),
    ]
    S["car_garbage"] = {
        "L": 2.7, "W": 2.36, "H": 2.85, "y_center": 2.55, "stations": st, "side": 0.8, "boxy": 0.7, "shoulder": 0.08,
        "greenhouse": {"g0": 1, "g1": 3, "y_rear": 1.3, "y_front": 2.9, "z_roof": 2.85, "roof_w": 0.95,
                       "mid_y": {2: 2.35}, "side_glass": [True, True], "rear_glass": False},
        "axles": [(2.85, 0.5, False), (-1.75, 0.5, True), (-2.95, 0.5, True)], "track": 1.0, "wheel_w": 0.3,
        "cabin": {"y": (1.32, 3.4), "w": 1.05, "floor": 1.0, "belt": 1.66, "roof": 2.75, "seat_y": 2.25,
                  "rear_rows": [1.6], "roof_y": (1.35, 2.8), "uniform": 10},
        "mirror": (3.25, 1.85), "handles": (), "handle_z": 1.3,
        "head_z": 0.95, "head_size": (0.32, 0.18), "tail_z": 0.95, "tail_in": 0.15, "tail_size": (0.16, 0.24),
        "plate_z": 0.7, "bumper_z": 0.62, "grille_z": 1.05, "grille": (1.2, 0.05, 0.4), "body_len": 8.0,
        "paint_fn": lambda k, s, side: mi("GLOSS", WHITE), "extras": garb_extras, "tinted": False,
    }

    # ---- fire truck: crew cab, locker body, ladder, light bar
    def fire_extras(bm, sp, lod, surf):
        box_module(bm, -1.25, 1.25, -4.5, 1.25, 0.65, 2.5, mi("GLOSS", RED), lod, bevel=0.06)
        if lod < 2:
            for s in (-1, 1):
                for i in range(4):
                    y0 = -4.25 + i * 1.33
                    stripe(bm, 1.25, y0, y0 + 1.15, 0.85, 2.3, mi("CHROME"), s)
                stripe(bm, 1.25, -4.45, 1.2, 0.68, 0.8, mi("GLOSS", WHITE), s)
            # Ladder.
            for s in (-1, 1):
                box_module(bm, s * 0.45 - 0.05, s * 0.45 + 0.05, -4.7, 2.9, 2.62, 2.74, mi("SOLID", SILVER), lod, bevel=0.0)
            if lod == 0:
                for i in range(16):
                    y = -4.5 + i * 0.46
                    r = cyl(0.025, 0.9, mi("SOLID", SILVER), seg=5)
                    merge(bm, r, xf=Matrix.Translation((0, y, 2.68)))
                    r.free()
            for y in (-3.8, 1.0):
                box_module(bm, -0.6, 0.6, y - 0.1, y + 0.1, 2.5, 2.64, mi("SOLID", DARK), lod, bevel=0.0)
        light_bar(bm, (0, 3.1, sp["H"]), 1.6, lod)
    st = [
        (1.25, 1.1, 0.62, 1.66, 0.02),
        (1.3, 1.2, 0.58, 1.7, 0.03),
        (2.3, 1.2, 0.58, 1.7, 0.03),
        (2.45, 1.2, 0.58, 1.7, 0.03),
        (3.6, 1.2, 0.58, 1.62, 0.04),
        (4.3, 1.16, 0.6, 1.42, 0.04),
        (4.45, 1.08, 0.66, 1.28, 0.01),
    ]
    S["car_firetruck"] = {
        "L": 3.25, "W": 2.44, "H": 2.85, "y_center": 2.88, "stations": st, "side": 0.8, "boxy": 0.7, "shoulder": 0.08,
        "greenhouse": {"g0": 1, "g1": 4, "y_rear": 1.32, "y_front": 3.4, "z_roof": 2.85, "roof_w": 0.95,
                       "mid_y": {2: 2.28, 3: 2.47}, "side_glass": [True, False, True], "rear_glass": False},
        "axles": [(3.35, 0.5, False), (-2.45, 0.5, True), (-3.65, 0.5, True)], "track": 1.04, "wheel_w": 0.3,
        "cabin": {"y": (1.35, 3.95), "w": 1.1, "floor": 1.0, "belt": 1.66, "roof": 2.75, "seat_y": 2.9,
                  "rear_rows": [1.75], "roof_y": (1.4, 3.3), "uniform": 11},
        "passengers": [(0.4, 1.75), (-0.4, 1.75)],
        "mirror": (3.8, 1.85), "handles": (), "handle_z": 1.3,
        "head_z": 0.95, "head_size": (0.32, 0.18), "tail_z": 0.95, "tail_in": 0.15, "tail_size": (0.16, 0.24),
        "plate_z": 0.7, "bumper_z": 0.62, "grille_z": 1.05, "grille": (1.3, 0.05, 0.4), "body_len": 9.2,
        "paint_fn": lambda k, s, side: mi("GLOSS", RED) if s < 6 else mi("GLOSS", WHITE),
        "extras": fire_extras, "tinted": False, "bumper_mat": mi("CHROME"),
        "siren": {"pos": (0, 2.95, -3.1), "width": 1.6},
    }

    # ---- city bus
    def bus_extras(bm, sp, lod, surf):
        box_module(bm, -0.7, 0.7, -3.5, -1.2, sp["H"] - 0.05, sp["H"] + 0.3, mi("SOLID", LIGHT), lod, bevel=0.08)
        if lod < 2:
            surf.put(bm, rbox((1.5, 0.05, 0.24), mi("SIGN", ORANGE), 0.02, 1), (0, 10, 2.78), (0, -1, 0), sink=0.01)
            # Front door (passenger side, +X).
            surf.put(bm, rbox((1.1, 0.04, 1.9), mi("SOLID", BLACK), 0.02, 1), (5, 4.6, 1.45), (-1, 0, 0), sink=0.01)
    win = [-5.2, -3.85, -2.5, -1.15, 0.2, 1.55, 2.9, 4.2, 5.2]
    st = [(-5.75, 1.15, 0.45, 1.66, 0.02), (-5.68, 1.26, 0.38, 1.72, 0.03)]
    st += [(y, 1.27, 0.36, 1.72 if y < 5.0 else 1.5, 0.03) for y in win]
    st += [(5.62, 1.24, 0.38, 1.42, 0.03), (5.75, 1.16, 0.45, 1.3, 0.01)]
    rows = [y for y in (-4.6, -3.7, -2.8, -1.9, -1.0, -0.1, 0.8, 1.7, 2.6)]
    S["car_bus"] = {
        "L": 11.5, "W": 2.55, "H": 3.05, "budget": 1.35, "stations": st, "side": 0.9, "boxy": 0.95, "shoulder": 0.07,
        "greenhouse": {"g0": 2, "g1": 10, "y_rear": -5.3, "y_front": 5.45, "z_roof": 3.05, "roof_w": 0.97,
                       "mid_y": {**{k + 2: y for k, y in enumerate(win)}, 2: -5.1, 10: 4.9}, "side_glass": [True] * 8, "rear_glass": True,
                       "roof_edge": 0.05},
        "frame": 0.06,
        "axles": [(3.85, 0.5, False), (-2.9, 0.5, True)], "track": 1.05, "wheel_w": 0.3,
        "cabin": {"y": (-5.3, 5.4), "w": 1.18, "floor": 0.55, "belt": 1.5, "roof": 2.92, "seat_y": 4.8,
                  "rear_rows": [], "roof_y": (-5.2, 5.3), "seat": BLUE, "uniform": 9},
        "bus_rows": rows,
        "passengers": [(0.65, rows[1]), (-0.6, rows[3]), (0.6, rows[4]), (-0.65, rows[6]), (0.62, rows[8])],
        "mirror": (5.5, 2.3), "handles": (), "handle_z": 1.2,
        "head_z": 0.75, "head_size": (0.34, 0.16), "tail_z": 0.9, "tail_in": 0.12, "tail_size": (0.16, 0.36),
        "plate_z": 0.55, "bumper_z": 0.5, "grille_z": 0.8, "grille": (1.4, 0.05, 0.12),
        "paint_fn": lambda k, s, side: mi("GLOSS", BLUE) if s <= 2 else mi("GLOSS", WHITE),
        "tinted": False,
    }
    return S


# --------------------------------------------------------------- build -----

def build(name, sp, lod, damage=0):
    burnt = damage >= 3
    cage = build_cage(sp, lod)
    levels = 2 if lod == 0 else (1 if lod == 1 else 0)
    ob = subdivide_body(cage, levels)
    fit(ob, sp)
    if lod < 2:
        boolean(ob, arch_cutters(sp, lod))
        if "bed" in sp:
            y0, y1 = sp["bed"]
            c = rbox((sp["W"] - 0.2, y1 - y0, 2.0), mi("SOLID", DARK))
            boolean(ob, _moved(c, (0, (y0 + y1) / 2, 0.82 + 1.0)))
    decimate(ob, BODY_BUDGET[lod] * sp.get("budget", 1.0))
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bpy.data.objects.remove(ob, do_unlink=True)
    surf = Surface(bm)
    if sp.get("extras"):
        sp["extras"](bm, sp, lod, surf)
    surf.free()
    # Lights and trim are placed on the finished outside (body plus modules).
    surf = Surface(bm)
    ys = [v.co.y for v in bm.verts]
    ext = (min(ys), max(ys))
    if lod < 2:
        add_bumpers(bm, sp, lod, ext, sp.get("bumper_mat"))
        add_grille(bm, surf, sp, ext)
        add_lights(bm, surf, sp, lod, ext, broken=damage if damage < 3 else 0)
        add_mirrors(bm, sp, lod)
        add_handles(bm, surf, sp, lod)
    else:
        add_lights(bm, surf, sp, 2, ext)
    if "bus_rows" in sp and lod == 0:
        for y in sp["bus_rows"]:
            for s in (-1, 1):
                st = seat(0.85, 0.42, 0.6, mi("SOLID", BLUE), 1)
                merge(bm, st, xf=Matrix.Translation((s * 0.68, y, sp["cabin"]["floor"] + 0.12)))
                st.free()
    if lod == 0 and not burnt:
        add_cabin(bm, sp, lod, driver=True, passengers=sp.get("passengers"))
    elif lod == 0 and burnt:
        add_cabin(bm, sp, lod, driver=False)
    elif lod == 1:
        # Just a head behind the glass-coloured windows is invisible; skip the cabin.
        pass
    surf.free()
    centers = add_wheels(bm, sp, lod, burnt)
    if damage:
        dent(bm, sp, damage, seed=hash(name) & 0xffff)
    if burnt:
        for f in bm.faces:
            part, pal = M.key(f.material_index)
            if part == PART["GLASS"]:
                f.tag = True
            elif part not in (PART["BURNT"],):
                f.material_index = mi("BURNT", 1 if part in (PART["SKIN"], PART["CLOTH"], PART["HAIR"], PART["SOLID"]) else 0)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.tag], context="FACES")
    if damage == 2:
        pass  # cracked glass is flagged in to_uvs
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0002)
    return bm, centers


def _moved(b, t):
    for v in b.verts:
        v.co += Vector(t)
    return b


def dent(bm, sp, level, seed=1):
    """Push the body in around a few impact points (wheels are left alone)."""
    rng = random.Random(seed + level)
    ys = [v.co.y for v in bm.verts]
    L, W, H = max(ys) - min(ys), sp["W"], sp["H"]
    yc = (max(ys) + min(ys)) / 2
    hits = [((-W / 2, yc + L / 2 - 0.3, 0.7), 0.6, 0.17),
            ((W / 2, yc - L / 2 + 0.6, 0.65), 0.55, 0.13),
            ((-W / 2, yc - 0.4, 0.75), 0.45, 0.1)]
    if level >= 2:
        hits += [((0, yc + L / 2 + 0.1, 0.65), 0.95, 0.28),
                 ((W / 2, yc + 0.1, 0.8), 0.7, 0.14),
                 ((-W / 4, yc - 0.2, H + 0.1), 0.6, 0.12),
                 ((-W / 2, yc - L / 2 + 0.1, 0.7), 0.6, 0.15)]
    hits = [(Vector(p), r, d) for p, r, d in hits]
    for v in bm.verts:
        if any(M.key(f.material_index)[0] in (PART["TIRE"], PART["RIM"]) for f in v.link_faces):
            continue
        for p, r, d in hits:
            dist = (v.co - p).length
            if dist < r:
                k = (1 - dist / r) ** 2
                inward = Vector((p.x, p.y - yc, p.z - H * 0.5))
                inward.y *= 0.6
                if inward.length < 1e-4:
                    continue
                n = inward.normalized()
                wob = 0.7 + 0.6 * math.sin(v.co.x * 23.0 + v.co.y * 17.0 + v.co.z * 29.0 + rng.random() * 6.0)
                v.co -= n * d * k * wob


# ------------------------------------------------------------- export -------

def to_uvs(bm, centers, lod, cracked):
    uv = bm.loops.layers.uv.get("UVMap") or bm.loops.layers.uv.new("UVMap")
    uv2 = bm.loops.layers.uv.get("UV2") or bm.loops.layers.uv.new("UV2")
    has_glass = False
    for f in bm.faces:
        part, pal = M.key(f.material_index)
        u2 = (0.0, 0.0)
        if part == PART["GLASS"]:
            u = (1.0 if cracked else 0.0, 0.0)
            f.material_index = 1
            has_glass = True
        else:
            if part in (PART["TIRE"], PART["RIM"]):
                cx, cy, cz = centers[pal]
                u = (float(part), cx)
                u2 = (-cy, cz)     # Godot z, Godot y
            else:
                u = (float(part), float(pal))
            f.material_index = 0
        for lp in f.loops:
            # glTF flips V; write 1 - v so Godot reads back the value we meant.
            lp[uv].uv = (u[0], 1.0 - u[1])
            lp[uv2].uv = (u2[0], 1.0 - u2[1])
    return has_glass


def export_bm(bm, name, out_dir, centers, lod, cracked=False):
    has_glass = to_uvs(bm, centers, lod, cracked)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(BODY_MAT)
    me.materials.append(GLASS_MAT)
    for p in me.polygons:
        p.use_smooth = True
    try:
        me.set_sharp_from_angle(angle=math.radians(38))
    except AttributeError:
        pass
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    os.makedirs(out_dir, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out_dir, name + ".glb"), use_selection=True,
                              export_format="GLB", export_apply=True, export_yup=True,
                              export_normals=True, export_texcoords=True, export_materials="EXPORT",
                              export_tangents=False)
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    bpy.data.objects.remove(ob, do_unlink=True)
    return tris


def spec_json(name, sp, centers):
    """What the game code needs to know about a model, in Godot space (front = -Z)."""
    L = sp.get("body_len", sp["L"])
    cab = sp["cabin"]
    d = {
        "length": round(L, 3), "width": sp["W"],
        "height": round(sp["H"] + (0.3 if name == "car_bus" else 0.0) + (0.2 if "siren" in sp else 0.0), 3),
        "wheel_radius": sp["axles"][0][1], "track": sp["track"],
        # Axles as Godot z (front is negative).
        "axles": [{"z": round(-a[0], 3), "radius": a[1], "dual": a[2], "steer": i == 0}
                  for i, a in enumerate(sp["axles"])],
        "seat": [-sp.get("driver_x", 0.36), cab["floor"] + 0.26, round(-cab["seat_y"], 3)],
        "tinted": sp.get("tinted", True),
        "siren": "siren" in sp,
        "lods": [name, name + "_lod1", name + "_lod2"],
        "damage": [name + "_dmg1", name + "_dmg2", name + "_dmg3"],
    }
    return d


BODY_MAT = None
GLASS_MAT = None


def main():
    global BODY_MAT, GLASS_MAT
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out_dir = OUT
    if "--out" in argv:
        i = argv.index("--out")
        out_dir = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    only = set(argv) if argv else None
    bpy.ops.wm.read_factory_settings(use_empty=True)
    BODY_MAT = bpy.data.materials.new("VehBody")
    GLASS_MAT = bpy.data.materials.new("VehGlass")
    GLASS_MAT.diffuse_color = (0.2, 0.3, 0.35, 0.4)
    specs = make_specs()
    meta_path = os.path.join(out_dir, "specs.json")
    meta = {}
    if os.path.exists(meta_path):
        with open(meta_path) as fh:
            meta = json.load(fh)
    for name, sp in specs.items():
        if only and name not in only:
            continue
        line = []
        centers = None
        for lod in (0, 1, 2):
            bm, centers_l = build(name, sp, lod)
            if lod == 0:
                centers = centers_l
            suffix = "" if lod == 0 else "_lod%d" % lod
            line.append(export_bm(bm, name + suffix, out_dir, centers_l, lod))
        for dmg in (1, 2, 3):
            bm, c = build(name, sp, 0, damage=dmg)
            line.append(export_bm(bm, "%s_dmg%d" % (name, dmg), out_dir, c, 0, cracked=dmg >= 2))
        meta[name] = spec_json(name, sp, centers)
        meta[name]["tris"] = line[:3]
        print("  %-14s lod0 %5d  lod1 %5d  lod2 %4d  dmg %s" % (name, line[0], line[1], line[2], line[3:]))
    with open(meta_path, "w") as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)
    print("done ->", out_dir)


if __name__ == "__main__":
    main()
