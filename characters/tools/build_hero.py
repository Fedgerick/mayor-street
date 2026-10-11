"""Build the high-detail player character: characters/assets/hero.glb.

Run headless (needs the `bpy` pip module, Blender 4.2, like player/tools/build_character.py):
    python3 characters/tools/build_hero.py

It reuses the street people's builder (player/tools/build_character.py): the same rig, the
same part names and the same weighting, so the parts drop onto any CharacterModel's
skeleton. What changes, for the one person the camera follows:

  * finer metaballs and about 2.5x the triangles (a full outfit is ~25k instead of ~10k),
  * a sculpted face: eye sockets and lids, lashes, cheekbones, a nose bridge and wings,
    two lips with a mouth line, a defined jaw and chin,
  * eyes with a cornea bulge (the shader paints iris, pupil and a catchlight),
  * clothes trims: collars, ribbed cuffs and hems, a waistband with belt loops, jeans
    seams, hoodie drawstrings, jacket zip, shoe soles and laces,
  * extra material slots for HeroLook (characters/scripts/hero_look.gd): Iris, Mouth,
    Lashes, Frame, Lens, Sole, Laces, Trim.

Every part also comes as <name>_mid, decimated back to the street part's triangle budget,
for close-up crowd people and police (HeroLook.mid): the new face, eyes and materials at
the street cost. No animations and no LOD1 copies: CharacterModel keeps animating with its
own clips and keeps its 1.5k-triangle crowd mesh for distance.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "player", "tools"))

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import build_character as bc  # noqa: E402
from build_character import Blob, arm_points, leg_points, lerp, LEG_X  # noqa: E402

OUT = os.environ.get("HERO_OUT") or os.path.join(ROOT, "characters", "assets", "hero.glb")
DETAIL = 0.62     # metaball resolution scale (smaller is finer)
TRI_SCALE = 2.5   # triangle budget against the street parts


TRIMS = []   # pieces the current builder made that skip decimation (rings, rods, beads)


def trim(ob):
    TRIMS.append(ob)
    return ob


def torus(loc, major, minor, mat, rot=(0, 0, 0), seg=28, mseg=6, sc=(1, 1, 1)):
    bpy.ops.mesh.primitive_torus_add(major_segments=seg, minor_segments=mseg, major_radius=major,
                                     minor_radius=minor, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.scale = sc
    ob.data.materials.append(mat)
    return trim(ob)


def rod(a, b, r, mat, verts=6):
    return trim(bc.rod(a, b, r, mat, verts))


def bead(loc, r, sc, mat, seg=10, rings=6):
    return trim(bc.sphere(loc, r, sc, mat, seg, rings))


def tube_ring(center, radius, minor, mat, sc=(1.0, 0.8), tilt=0.0, seg=32):
    """A horizontal ring (collar, cuff, hem, waistband) around +Z, squashed front to back."""
    return torus(center, radius, minor, mat, rot=(tilt, 0, 0), seg=seg, sc=(sc[0], sc[1], 1.0))


def arm_ring(sx, t, radius, minor, mat):
    """A ring around the arm at t along it (0 shoulder, 1 elbow, 2 wrist)."""
    sh, el, wr = arm_points(sx)
    p = lerp(sh, el, t) if t <= 1.0 else lerp(el, wr, t - 1.0)
    d = (el - sh).normalized() if t <= 1.0 else (wr - el).normalized()
    ob = torus(p, radius, minor, mat, seg=24)
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d)
    return ob


def leg_ring(sx, z, radius, minor, mat):
    hip, knee, ankle = leg_points(sx)
    return torus((LEG_X * sx, 0.0, z), radius, minor, mat, seg=24)


# ------------------------------------------------------------------- the face ---

def head(m):
    h = Blob(0.0042)
    h.capsule((0, 0.01, 1.395), (0, 0.0, 1.56), 0.057)                   # neck
    h.capsule((0, 0.02, 1.43), (0, -0.025, 1.47), 0.03)                  # throat
    h.ball((0, 0.008, 1.668), 0.152, (0.92, 1.0, 1.08))                  # skull
    h.ball((0, -0.028, 1.6), 0.108, (0.97, 0.95, 0.86))                  # jaw and cheeks
    h.ball((0, -0.098, 1.547), 0.037, (1.2, 0.9, 0.82))                  # chin
    for sx in (-1, 1):
        h.capsule((0.085 * sx, -0.035, 1.555), (0.03 * sx, -0.092, 1.535), 0.026)   # jawline
        h.ball((0.074 * sx, -0.1, 1.644), 0.024, (1.25, 0.8, 0.7))      # cheekbones
        h.ball((0.058 * sx, -0.098, 1.603), 0.036)                       # cheeks
        h.capsule((0.03 * sx, -0.128, 1.72), (0.08 * sx, -0.115, 1.722), 0.011)    # brow ridge
        h.ball((0.145 * sx, 0.008, 1.662), 0.034, (0.38, 0.85, 1.3))     # ears
        h.ball((0.152 * sx, 0.004, 1.632), 0.016, (0.6, 0.9, 1.0))       # ear lobes
        h.ball((0.053 * sx, -0.138, 1.69), 0.023, (1.12, 0.66, 0.3))     # upper lids
        h.ball((0.054 * sx, -0.139, 1.652), 0.014, (1.25, 0.6, 0.32))    # lower lids
        h.ball((0.013 * sx, -0.16, 1.626), 0.0095, (1.0, 1.0, 0.85))     # nostrils
        h.ball((0.019 * sx, -0.15, 1.628), 0.012, (0.9, 1.0, 1.0))       # nose wings
    h.capsule((0, -0.142, 1.69), (0, -0.152, 1.65), 0.009)              # nose bridge
    h.capsule((0, -0.152, 1.65), (0, -0.168, 1.632), 0.0135)
    h.ball((0, -0.17, 1.628), 0.0155)                                    # nose tip
    h.capsule((-0.022, -0.143, 1.6), (0.022, -0.143, 1.6), 0.0078)       # upper lip
    h.capsule((-0.017, -0.139, 1.581), (0.017, -0.139, 1.581), 0.0088)   # lower lip
    out = [h.mesh(m["Skin"])]
    for sx in (-1, 1):
        out.append(bead((0.053 * sx, -0.138, 1.673), 0.027, (1.0, 0.64, 0.88), m["EyeWhite"], 28, 16))
        out.append(bead((0.053 * sx, -0.151, 1.673), 0.0146, (1.0, 0.36, 1.0), m["Iris"], 24, 12))
        # Lashes: a thin dark arc along each upper lid's edge.
        la = Blob(0.0018)
        pts = []
        for i in range(7):
            a = (i - 3) / 3.0
            pts.append((0.053 * sx + a * 0.022 * sx, -0.1545 + a * a * 0.011, 1.6905 - a * a * 0.006 + max(a * sx, 0) * 0.002))
        for a_, b_ in zip(pts, pts[1:]):
            la.capsule(a_, b_, 0.0026)
        out.append(la.mesh(m["Lashes"]))
    mo = bead((0, -0.1495, 1.5905), 0.026, (1.0, 0.2, 0.075), m["Mouth"], 20, 6)   # mouth line
    out.append(mo)
    return out


def brows(m):
    b = Blob(0.0026)
    for sx in (-1, 1):
        b.capsule((0.025 * sx, -0.151, 1.722), (0.05 * sx, -0.149, 1.733), 0.0068)
        b.capsule((0.05 * sx, -0.149, 1.733), (0.084 * sx, -0.134, 1.724), 0.0062)
        b.capsule((0.084 * sx, -0.134, 1.724), (0.094 * sx, -0.122, 1.716), 0.0045)
    return [b.mesh(m["Brows"])]


def glasses_frame(m, lens):
    out = []
    mat = m["Frame"]
    for sx in (-1, 1):
        out.append(trim(bc.ring((0.054 * sx, -0.168, 1.674), 0.024, 0.0026, mat)))
        out.append(rod((0.078 * sx, -0.164, 1.68), (0.142 * sx, -0.01, 1.685), 0.0022, mat, 6))
        if lens:
            bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.023, depth=0.002,
                                                location=(0.054 * sx, -0.168, 1.674),
                                                rotation=(math.pi / 2, 0, 0))
            lo = bpy.context.active_object
            lo.data.materials.append(m["Lens"])
            out.append(trim(lo))
    out.append(rod((-0.03, -0.171, 1.68), (0.03, -0.171, 1.68), 0.0024, mat, 6))
    return out


def face_glasses(m):
    return glasses_frame(m, False)


def face_shades(m):
    return glasses_frame(m, True)


# --------------------------------------------------------------- clothes trims ---

def top_tee(m):
    out = bc.top_tee(m)
    for sx in (1, -1):
        out.append(arm_ring(sx, 0.46, 0.071, 0.008, m["Shirt"]))
    out.append(tube_ring((0, 0.012, 0.965), 0.15, 0.009, m["Shirt"], sc=(1.12, 0.8)))
    return out


def top_longsleeve(m):
    out = bc.top_longsleeve(m)
    for sx in (1, -1):
        out.append(arm_ring(sx, 1.86, 0.054, 0.012, m["Trim"]))
    out.append(tube_ring((0, 0.012, 0.965), 0.15, 0.01, m["Shirt"], sc=(1.12, 0.8)))
    return out


def top_hoodie(m):
    out = bc.top_hoodie(m)
    for sx in (1, -1):
        out.append(arm_ring(sx, 1.82, 0.06, 0.014, m["Trim"]))
        st = Vector((0.03 * sx, -0.105, 1.43))
        out.append(rod(st, st + Vector((0.004 * sx, -0.022, -0.17)), 0.0045, m["Laces"], 6))  # drawstrings
        out.append(bead(st + Vector((0.004 * sx, -0.022, -0.175)), 0.008, (1, 1, 1.6), m["Laces"], 8, 6))
    out.append(tube_ring((0, 0.012, 0.935), 0.163, 0.018, m["Trim"], sc=(1.1, 0.82)))
    return out


def top_jacket(m):
    out = bc.top_jacket(m)
    for sx in (1, -1):
        out.append(arm_ring(sx, 1.85, 0.064, 0.012, m["Jacket"]))
        for i in range(3):   # buttons on the right half, holes on the left
            z = 1.27 - i * 0.12
            if sx > 0:
                out.append(bead((0.035, -0.152 + i * 0.006, z), 0.009, (1, 0.45, 1), m["Frame"], 10, 6))
    return out


def top_tank(m):
    out = bc.top_tank(m)
    out.append(tube_ring((0, 0.012, 0.965), 0.135, 0.009, m["Shirt"], sc=(1.12, 0.8)))
    return out


def jeans_extras(m, short=False):
    out = [tube_ring((0, 0.005, 1.0), 0.158, 0.014, m["Pants"], sc=(1.13, 0.82))]   # waistband
    for a in (-60, -20, 20, 60, 160, 200):   # belt loops
        r = math.radians(a)
        x, y = math.sin(r) * 0.178, -math.cos(r) * 0.13
        out.append(rod((x, y, 0.985), (x, y, 1.02), 0.006, m["Pants"], 4))
    out.append(bead((0, -0.133, 0.998), 0.009, (1, 0.5, 1), m["Frame"], 10, 6))   # button
    return out


def bottom_jeans(m):
    out = bc.bottom_jeans(m) + jeans_extras(m)
    for sx in (1, -1):
        out.append(leg_ring(sx, 0.13, 0.072, 0.012, m["Pants"]))   # rolled hem
    return out


def bottom_shorts(m):
    out = bc.bottom_shorts(m) + jeans_extras(m)
    for sx in (1, -1):
        hip, knee, _ = leg_points(sx)
        z = lerp(hip, knee, 0.62).z
        out.append(leg_ring(sx, z, 0.084, 0.011, m["Pants"]))
    return out


def bottom_skirt(m):
    out = bc.bottom_skirt(m)
    out.append(tube_ring((0, 0.005, 1.0), 0.158, 0.013, m["Pants"], sc=(1.13, 0.82)))
    return out


def soles_and_laces(m, boot):
    out = []
    for sx in (1, -1):
        x = LEG_X * sx
        s = Blob(0.004)
        s.capsule((x, 0.04, 0.016), (x, -0.135, 0.016), 0.019)
        s.ball((x, -0.045, 0.016), 0.03, (2.0, 3.6, 0.6))
        out.append(s.mesh(m["Sole"]))
        top = 0.21 if boot else 0.115
        for i in range(4 if boot else 3):   # laces across the tongue
            t = i / (3.0 if boot else 2.0)
            z = lerp(0.075, top - 0.012, t)
            yy = lerp(-0.088, -0.05, t)
            out.append(rod((x - 0.026, yy, z), (x + 0.026, yy, z + 0.006), 0.0045, m["Laces"], 5))
    return out


def shoes_sneakers(m):
    return bc.shoes_sneakers(m) + soles_and_laces(m, False)


def shoes_boots(m):
    return bc.shoes_boots(m) + soles_and_laces(m, True)


def hat_cap(m):
    return bc.hat_cap(m)


def hat_beanie(m):
    return bc.hat_beanie(m)


OVERRIDES = {
    "Head_skin": (head, 6500), "Brows": (brows, 320), "Hands": (None, 2800),
    "Face_glasses": (face_glasses, 1200), "Face_shades": (face_shades, 1300),
    "Top_tee": (top_tee, None), "Top_longsleeve": (top_longsleeve, None),
    "Top_hoodie": (top_hoodie, None), "Top_jacket": (top_jacket, None), "Top_tank": (top_tank, None),
    "Bottom_jeans": (bottom_jeans, None), "Bottom_shorts": (bottom_shorts, None),
    "Bottom_skirt": (bottom_skirt, None), "Shoes_sneakers": (shoes_sneakers, 1900),
    "Shoes_boots": (shoes_boots, 2100), "Hat_cap": (hat_cap, None), "Hat_beanie": (hat_beanie, None),
}


# Crowd copies that need more than the street part's budget to keep the new face and trims.
MID_TARGETS = {"Head_skin": 2600, "Brows": 120, "Hands": 1100, "Face_glasses": 300,
               "Face_shades": 470, "Shoes_sneakers": 800, "Shoes_boots": 900}


def build_parts(rig, m, proxy):
    parts = []
    total = 0
    for name, builder, target, mode in bc.WARDROBE:
        street_target = target
        ob_builder, ob_target = OVERRIDES.get(name, (None, None))
        builder = ob_builder or builder
        target = ob_target or int(target * TRI_SCALE)
        bc.RES_SCALE[0] = DETAIL
        TRIMS.clear()
        pieces = builder(m)
        bc.RES_SCALE[0] = 1.0
        base = [p for p in pieces if p not in TRIMS]
        ob = None
        if base:
            ob = bc.finish(bc.join(base, name), max(target - sum(bc.tris(t) for t in TRIMS), target // 2))
        if TRIMS:
            for t in TRIMS:
                bc.select_only([t], t)
                bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
                bpy.ops.object.shade_smooth()
            ob = bc.join(([ob] if ob else []) + list(TRIMS), name)
        bc.weight_part(ob, mode, proxy)
        # The crowd's copy: the same sculpt at the street part's triangle budget.
        mid = ob.copy()
        mid.data = ob.data.copy()
        mid.name = mid.data.name = name + "_mid"
        bpy.context.scene.collection.objects.link(mid)
        bc.decimate(mid, MID_TARGETS.get(name, street_target))
        for o in (ob, mid):
            bc.bind(o, rig)
            parts.append(o)
        total += bc.tris(ob)
        print(f"  {name:16s} {bc.tris(ob):6d} tris   mid {bc.tris(mid):5d}", flush=True)
    return parts


def main():
    bc.reset()
    names = {
        "Skin": (0.87, 0.64, 0.48), "Shirt": (0.2, 0.45, 0.85), "Jacket": (0.25, 0.2, 0.16),
        "Pants": (0.16, 0.2, 0.32), "Shoes": (0.95, 0.95, 0.95), "Hair": (0.15, 0.1, 0.07),
        "Brows": (0.12, 0.08, 0.06), "Eyes": (0.03, 0.03, 0.04), "EyeWhite": (0.93, 0.92, 0.9),
        "Hat": (0.7, 0.15, 0.12), "Stubble": (0.45, 0.32, 0.25),
        "Iris": (0.3, 0.18, 0.08), "Mouth": (0.45, 0.2, 0.18), "Lashes": (0.05, 0.04, 0.03),
        "Frame": (0.03, 0.03, 0.04), "Lens": (0.02, 0.02, 0.03), "Sole": (0.92, 0.9, 0.86),
        "Laces": (0.95, 0.95, 0.95), "Trim": (0.2, 0.45, 0.85),
    }
    m = {k: bc.material(k, v) for k, v in names.items()}
    rig = bc.build_armature()
    proxy = bc.Proxy(rig, m)
    print("hero wardrobe:", flush=True)
    parts = build_parts(rig, m, proxy)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bc.select_only(parts + [rig], rig)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_animations=False, export_yup=True, export_apply=False,
                              export_skins=True, export_all_influences=False,
                              export_materials="EXPORT")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
