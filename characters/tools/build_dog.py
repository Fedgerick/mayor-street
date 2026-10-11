"""Build the street dogs: characters/assets/dog.glb.

Run headless (the `bpy` pip module, Blender 4.2):
    python3 characters/tools/build_dog.py

A sculpted dog (metaballs, like the people) to replace citylife's 130-triangle box dog,
0.62 m to the ear tips, facing -Z in Godot, paws at y = 0. It keeps the box dog's
layout so citylife's trot animation works unchanged: separate shells for the body (with
neck and collar), head, four legs and tail, each pivoting where citylife/dog.gdshader
expects (legs swing about y = 0.3 at z = -0.24 front / 0.22 back; the tail wags with
height above 0.44). Objects are named <part>_lod0 / <part>_lod1; HeroDog
(characters/dogs/hero_dog.gd) turns them into one mesh per LOD with the part number in
UV.x and the material (coat, nose, eye, collar, tongue) in UV.y.

LOD0 is about 2,300 triangles, LOD1 about 500.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "player", "tools"))

import bpy  # noqa: E402

import build_character as bc  # noqa: E402

OUT = os.environ.get("DOG_OUT") or os.path.join(ROOT, "characters", "assets", "dog.glb")


def G(x, y, z):
    """Godot coordinates (y up, front -Z) to Blender's (z up, front +Y after export)."""
    return (x, -z, y)


class B(bc.Blob):
    def gball(self, p, r, sc=(1, 1, 1)):
        # sc is in Godot axes too: (x, y, z) -> Blender (x, z, y)
        return self.ball(G(*p), r, (sc[0], sc[2], sc[1]))

    def gcap(self, a, b, r):
        return self.capsule(G(*a), G(*b), r)


def body(m):
    b = B(0.009)
    b.gcap((0, 0.43, -0.2), (0, 0.42, 0.19), 0.1)          # ribcage to rump
    b.gball((0, 0.41, -0.19), 0.115, (1.0, 1.05, 1.0))     # deep chest
    b.gball((0, 0.43, 0.18), 0.1, (1.05, 1.0, 1.0))        # haunches
    b.gball((0, 0.37, 0.0), 0.075, (1.0, 0.8, 1.6))        # belly tuck
    b.gcap((0, 0.46, -0.24), (0, 0.56, -0.34), 0.065)      # neck
    for sx in (-1, 1):
        b.gball((0.07 * sx, 0.39, -0.22), 0.055)            # shoulders
        b.gball((0.075 * sx, 0.41, 0.2), 0.07)              # hips
    out = [b.mesh(m["Coat"])]
    bpy.ops.mesh.primitive_torus_add(major_segments=20, minor_segments=5, major_radius=0.064,
                                     minor_radius=0.012, location=G(0, 0.53, -0.315),
                                     rotation=(math.radians(-55), 0, 0))
    col = bpy.context.active_object
    col.data.materials.append(m["Collar"])
    out.append(col)
    tag = bc.sphere(G(0, 0.47, -0.36), 0.014, (1, 0.35, 1), m["Collar"], 10, 6)   # tag
    out.append(tag)
    return out


def head(m):
    h = B(0.006)
    h.gball((0, 0.6, -0.4), 0.075, (0.95, 0.95, 1.05))     # skull
    h.gcap((0, 0.58, -0.44), (0, 0.555, -0.545), 0.042)    # muzzle
    h.gball((0, 0.545, -0.47), 0.045, (1.0, 0.8, 1.2))     # jaw
    for sx in (-1, 1):
        h.gball((0.035 * sx, 0.575, -0.5), 0.03)            # cheeks
        h.gball((0.033 * sx, 0.632, -0.44), 0.022)          # brows
    out = [h.mesh(m["Coat"])]
    for sx in (-1, 1):
        e = B(0.006)   # floppy ears, their own shells so they stay flat
        e.gcap((0.055 * sx, 0.665, -0.385), (0.082 * sx, 0.6, -0.375), 0.022)
        e.gcap((0.082 * sx, 0.6, -0.375), (0.088 * sx, 0.55, -0.38), 0.018)
        ob = e.mesh(m["Coat"])
        bc.select_only([ob], ob)
        bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY")
        ob.scale = (0.45, 1.0, 1.0)
        out.append(ob)
        out.append(bc.sphere(G(0.036 * sx, 0.618, -0.468), 0.0115, (1, 1, 1), m["Eye"], 12, 8))
    out.append(bc.sphere(G(0, 0.567, -0.585), 0.019, (1.25, 0.9, 0.85), m["Nose"], 14, 8))
    out.append(bc.sphere(G(0, 0.528, -0.53), 0.02, (1.0, 0.25, 1.3), m["Tongue"], 10, 6))
    return out


def leg(m, sx, front):
    x = 0.068 * sx
    z = -0.22 if front else 0.2
    b = B(0.006)
    if front:
        b.gcap((x, 0.4, z), (x, 0.2, z - 0.005), 0.038)
        b.gcap((x, 0.2, z - 0.005), (x, 0.045, z - 0.012), 0.026)
    else:
        b.gcap((x, 0.42, z), (x, 0.24, z + 0.05), 0.05)          # thigh
        b.gcap((x, 0.24, z + 0.05), (x, 0.12, z + 0.035), 0.03)  # hock
        b.gcap((x, 0.12, z + 0.035), (x, 0.045, z + 0.01), 0.026)
    b.gball((x, 0.028, z - 0.03), 0.032, (1.0, 0.65, 1.35))     # paw
    return [b.mesh(m["Coat"])]


def tail(m):
    t = B(0.005)
    pts = [(0, 0.45, 0.27), (0, 0.5, 0.33), (0, 0.56, 0.37), (0, 0.61, 0.39)]
    rs = [0.026, 0.022, 0.018, 0.012]
    for i in range(3):
        t.gcap(pts[i], pts[i + 1], rs[i])
    return [t.mesh(m["Coat"])]


PARTS = [
    ("body", body, 800),
    ("head", head, 650),
    ("leg_fl", lambda m: leg(m, -1, True), 180),
    ("leg_fr", lambda m: leg(m, 1, True), 180),
    ("leg_bl", lambda m: leg(m, -1, False), 210),
    ("leg_br", lambda m: leg(m, 1, False), 210),
    ("tail", tail, 100),
]


def main():
    bc.reset()
    m = {k: bc.material(k, c) for k, c in {
        "Coat": (0.55, 0.36, 0.2), "Nose": (0.05, 0.04, 0.04), "Eye": (0.06, 0.04, 0.03),
        "Collar": (0.75, 0.15, 0.12), "Tongue": (0.85, 0.4, 0.42)}.items()}
    obs = []
    for name, builder, target in PARTS:
        for lod, scale in ((0, 1.0), (1, 0.22)):
            bc.RES_SCALE[0] = 1.0 if lod == 0 else 2.2
            ob = bc.finish(bc.join(builder(m), f"{name}_lod{lod}"), max(int(target * scale), 16))
            bc.RES_SCALE[0] = 1.0
            obs.append(ob)
            print(f"  {name}_lod{lod:<3d} {bc.tris(ob):5d} tris", flush=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bc.select_only(obs, obs[0])
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True, export_materials="EXPORT")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
