"""Interior scenes for enterable buildings: geometry, collision and markers.

    python3 art/tools/build_interiors.py            # all
    python3 art/tools/build_interiors.py -- bank    # one

Each interior exports to interiors/models/<id>.glb containing:
  * "<id>"          the visible room (its own I_* materials, imported as StandardMaterial3D)
  * "<id>-colonly"  plain boxes Godot turns into a StaticBody3D on import (walls, floors, furniture)
  * "M_<name>"      empty markers: M_spawn (where you appear, facing in), M_exit (door back to
                    the street), plus points of interest such as M_vault, M_stash, M_cell
  * "L_<rrggbb>_<range>_<energy x10>"  where interiors/interior.gd puts an OmniLight3D

Floor at z = 0 (stairs may go below), entrance on the south wall (-Y, Godot +Z).
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
from mathutils import Vector  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, "..", "..", "interiors", "models"))

# name: (base colour sRGB, roughness, metallic, emission strength)
IMATS = {
    "I_Plaster": ((0.86, 0.83, 0.77), 0.9, 0.0, 0), "I_PlasterCool": ((0.74, 0.78, 0.8), 0.9, 0.0, 0),
    "I_Wood": ((0.52, 0.34, 0.2), 0.6, 0.0, 0), "I_WoodDark": ((0.28, 0.17, 0.1), 0.55, 0.0, 0),
    "I_Floorboards": ((0.6, 0.43, 0.27), 0.7, 0.0, 0), "I_Tile": ((0.85, 0.85, 0.82), 0.4, 0.0, 0),
    "I_Marble": ((0.93, 0.91, 0.87), 0.18, 0.0, 0), "I_MarbleDark": ((0.2, 0.22, 0.24), 0.15, 0.0, 0),
    "I_Carpet": ((0.55, 0.12, 0.14), 0.95, 0.0, 0), "I_CarpetBlue": ((0.16, 0.22, 0.38), 0.95, 0.0, 0),
    "I_Concrete": ((0.55, 0.55, 0.53), 0.9, 0.0, 0), "I_ConcreteDark": ((0.33, 0.33, 0.32), 0.9, 0.0, 0),
    "I_Steel": ((0.62, 0.64, 0.66), 0.35, 0.9, 0), "I_SteelDark": ((0.25, 0.26, 0.28), 0.4, 0.8, 0),
    "I_Brass": ((0.85, 0.66, 0.3), 0.3, 1.0, 0), "I_Gold": ((1.0, 0.78, 0.3), 0.25, 1.0, 0),
    "I_Glass": ((0.55, 0.7, 0.75), 0.05, 0.0, 0), "I_Fabric": ((0.3, 0.42, 0.5), 0.95, 0.0, 0),
    "I_Leather": ((0.35, 0.18, 0.12), 0.5, 0.0, 0), "I_Black": ((0.05, 0.05, 0.06), 0.5, 0.0, 0),
    "I_White": ((0.95, 0.95, 0.93), 0.6, 0.0, 0), "I_Red": ((0.75, 0.1, 0.1), 0.5, 0.0, 0),
    "I_Green": ((0.15, 0.4, 0.22), 0.8, 0.0, 0), "I_Olive": ((0.33, 0.36, 0.2), 0.85, 0.0, 0),
    "I_Cash": ((0.45, 0.65, 0.4), 0.8, 0.0, 0), "I_Plant": ((0.25, 0.55, 0.22), 0.8, 0.0, 0),
    "I_Yellow": ((0.95, 0.75, 0.1), 0.6, 0.0, 0), "I_Paper": ((0.95, 0.93, 0.86), 0.9, 0.0, 0),
    # glowing surfaces
    "I_LampWarm": ((1.0, 0.85, 0.6), 0.5, 0.0, 6.0), "I_LampCool": ((0.85, 0.92, 1.0), 0.5, 0.0, 5.0),
    "I_Window": ((0.75, 0.86, 1.0), 0.3, 0.0, 2.2), "I_Screen": ((0.35, 0.6, 0.95), 0.3, 0.0, 3.0),
    "I_NeonPink": ((1.0, 0.2, 0.7), 0.4, 0.0, 9.0), "I_NeonCyan": ((0.1, 0.9, 1.0), 0.4, 0.0, 9.0),
    "I_NeonPurple": ((0.55, 0.2, 1.0), 0.4, 0.0, 9.0), "I_NeonGreen": ((0.3, 1.0, 0.4), 0.4, 0.0, 6.0),
    "I_Fridge": ((0.85, 0.95, 1.0), 0.2, 0.0, 2.5), "I_RedLight": ((1.0, 0.1, 0.05), 0.4, 0.0, 6.0),
}
H = 3.6       # default ceiling height
T = 0.2       # wall thickness


def srgb_to_lin(c):
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def setup_materials():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    K.MATERIALS = {}
    for nm, col in K.MAT_COLORS.items():
        mat = bpy.data.materials.new(nm)
        mat.diffuse_color = (*col, 1.0)
        K.MATERIALS[nm] = mat
    for nm, (col, rough, metal, emit) in IMATS.items():
        mat = bpy.data.materials.new(nm)
        mat.use_nodes = True
        b = mat.node_tree.nodes["Principled BSDF"]
        lin = srgb_to_lin(col)
        b.inputs["Base Color"].default_value = (*lin, 1)
        b.inputs["Roughness"].default_value = rough
        b.inputs["Metallic"].default_value = metal
        if emit:
            b.inputs["Emission Color"].default_value = (*lin, 1)
            b.inputs["Emission Strength"].default_value = emit
        if nm == "I_Glass":
            b.inputs["Alpha"].default_value = 0.25
            mat.blend_method = "BLEND" if hasattr(mat, "blend_method") else None
        K.MATERIALS[nm] = mat
        if nm not in K.MAT_NAMES:
            K.MAT_NAMES.append(nm)


class Room:
    """A visible mesh, a collision mesh and markers, built together."""

    def __init__(self, name):
        self.name = name
        self.v = Mesh()
        self.c = Mesh()
        self.markers = []   # (name, (x, y, z), yaw_deg)

    # solid furniture / walls: drawn and collidable
    def solid(self, x0, y0, z0, x1, y1, z1, mat, top=None, collide=True):
        self.v.box(x0, y0, z0, x1, y1, z1, mat, top=top, bottom=True)
        if collide:
            self.c.box(x0, y0, z0, x1, y1, z1, "Concrete", bottom=True)

    def deco(self, x0, y0, z0, x1, y1, z1, mat, top=None):
        self.v.box(x0, y0, z0, x1, y1, z1, mat, top=top)

    def cyl(self, x, y, z0, z1, r, mat, seg=12, collide=False, **kw):
        self.v.cyl(x, y, z0, z1, r, mat, seg=seg, **kw)
        if collide:
            self.c.box(x - r, y - r, z0, x + r, y + r, z1, "Concrete", bottom=True)

    def mark(self, name, x, y, z=0.0, yaw=0.0):
        self.markers.append(("M_" + name, (x, y, z), yaw))

    def light(self, x, y, z, color="ffd9a0", rng=8.0, energy=1.5):
        self.markers.append((f"L_{color}_{int(rng)}_{int(energy * 10)}", (x, y, z), 0.0))

    def shell(self, x0, y0, x1, y1, h=H, wall="I_Plaster", floor="I_Floorboards", ceil="I_White", z=0.0,
              doors=None, skirting="I_WoodDark"):
        """Floor, ceiling and four walls. doors: list of (side, centre, width, height)."""
        doors = doors or []
        self.solid(x0 - T, y0 - T, z - 0.3, x1 + T, y1 + T, z, floor)
        self.solid(x0 - T, y0 - T, z + h, x1 + T, y1 + T, z + h + 0.25, ceil)
        sides = {"S": (x0, x1, y0 - T, y0, True), "N": (x0, x1, y1, y1 + T, True),
                 "W": (y0, y1, x0 - T, x0, False), "E": (y0, y1, x1, x1 + T, False)}
        for side, (a0, a1, b0, b1, along_x) in sides.items():
            gaps = sorted([(c - w / 2, c + w / 2, dh) for s, c, w, dh in doors if s == side])
            cur = a0 - (T if along_x else T)
            segs = []
            for g0, g1, dh in gaps:
                segs.append((cur, g0, 0, h))
                segs.append((g0, g1, dh, h))     # lintel over the door
                cur = g1
            segs.append((cur, a1 + T, 0, h))
            for s0, s1, za, zb in segs:
                if s1 - s0 < 0.01 or zb - za < 0.01:
                    continue
                if along_x:
                    self.solid(s0, b0, z + za, s1, b1, z + zb, wall)
                    if za == 0:
                        yy = b1 if side == "S" else b0
                        self.deco(s0, min(yy, yy + (0.03 if side == "S" else -0.03)), z,
                                  s1, max(yy, yy + (0.03 if side == "S" else -0.03)), z + 0.12, skirting)
                else:
                    self.solid(b0, s0, z + za, b1, s1, z + zb, wall)
                    if za == 0:
                        xx = b1 if side == "W" else b0
                        self.deco(min(xx, xx + (0.03 if side == "W" else -0.03)), s0, z,
                                  max(xx, xx + (0.03 if side == "W" else -0.03)), s1, z + 0.12, skirting)

    def door_leaf(self, side, x, y, w=1.1, h=2.2, mat="I_WoodDark", frame="I_White"):
        """A closed-looking door panel standing in a door gap (the exit or a fake door)."""
        if side in "SN":
            self.deco(x - w / 2 - 0.1, y - 0.12, 0, x + w / 2 + 0.1, y + 0.12, h + 0.1, frame)
            self.deco(x - w / 2, y - 0.14, 0, x + w / 2, y + 0.14, h, mat)
            self.deco(x + w / 2 - 0.2, y - 0.2, 1.0, x + w / 2 - 0.1, y + 0.2, 1.08, "I_Brass")
        else:
            self.deco(x - 0.12, y - w / 2 - 0.1, 0, x + 0.12, y + w / 2 + 0.1, h + 0.1, frame)
            self.deco(x - 0.14, y - w / 2, 0, x + 0.14, y + w / 2, h, mat)

    def window(self, side, x, y, z0, w, h):
        """Glowing daylight pane set into a wall (rooms have no outside view)."""
        if side in "SN":
            s = -1 if side == "S" else 1
            self.deco(x - w / 2 - 0.1, y - 0.05 * s, z0 - 0.1, x + w / 2 + 0.1, y - 0.08 * s, z0 + h + 0.1, "I_White")
            self.deco(x - w / 2, y - 0.08 * s, z0, x + w / 2, y - 0.1 * s, z0 + h, "I_Window")
        else:
            s = -1 if side == "W" else 1
            self.deco(x - 0.05 * s, y - w / 2 - 0.1, z0 - 0.1, x - 0.08 * s, y + w / 2 + 0.1, z0 + h + 0.1, "I_White")
            self.deco(x - 0.08 * s, y - w / 2, z0, x - 0.1 * s, y + w / 2, z0 + h, "I_Window")

    def ceiling_lamp(self, x, y, h=H, mat="I_LampWarm", color="ffd9a0", rng=7.0, energy=1.4, size=0.6):
        self.deco(x - size / 2, y - size / 2, h - 0.08, x + size / 2, y + size / 2, h, mat)
        self.light(x, y, h - 0.5, color, rng, energy)

    def export(self):
        os.makedirs(OUT, exist_ok=True)
        vis = self.v.build(self.name)
        col = self.c.build(self.name + "-colonly")
        objs = [vis, col]
        for nm, loc, yaw in self.markers:
            e = bpy.data.objects.new(nm, None)
            e.location = loc
            e.rotation_euler = (0, 0, math.radians(yaw))
            bpy.context.scene.collection.objects.link(e)
            objs.append(e)
        bpy.ops.object.select_all(action="DESELECT")
        for o in objs:
            o.select_set(True)
        bpy.context.view_layer.objects.active = vis
        path = os.path.join(OUT, self.name + ".glb")
        bpy.ops.export_scene.gltf(filepath=path, use_selection=True, export_format="GLB", export_apply=True,
                                  export_yup=True, export_normals=True, export_materials="EXPORT")
        tris = sum(len(p.vertices) - 2 for p in vis.data.polygons)
        print(f"  interiors/{self.name}.glb  {tris} tris, {len(self.markers)} markers")
        for o in objs:
            bpy.data.objects.remove(o, do_unlink=True)


# -------------------------------------------------------------- furniture ---

def sofa(r, x, y, w=2.2, facing="N", mat="I_Fabric"):
    if facing == "N":
        r.solid(x - w / 2, y - 0.45, 0, x + w / 2, y + 0.45, 0.45, mat)
        r.solid(x - w / 2, y - 0.45, 0.45, x + w / 2, y - 0.2, 0.95, mat)
        for s in (-1, 1):
            r.solid(x + s * w / 2 - (0.2 if s > 0 else 0), y - 0.45, 0.45, x + s * w / 2 + (0 if s > 0 else 0.2),
                    y + 0.45, 0.7, mat)
    else:  # facing S
        r.solid(x - w / 2, y - 0.45, 0, x + w / 2, y + 0.45, 0.45, mat)
        r.solid(x - w / 2, y + 0.2, 0.45, x + w / 2, y + 0.45, 0.95, mat)


def table(r, x, y, w, d, h=0.75, top="I_Wood", leg="I_WoodDark"):
    r.solid(x - w / 2, y - d / 2, h - 0.05, x + w / 2, y + d / 2, h, top)
    for sx in (-1, 1):
        for sy in (-1, 1):
            r.deco(x + sx * (w / 2 - 0.08) - 0.04, y + sy * (d / 2 - 0.08) - 0.04, 0,
                   x + sx * (w / 2 - 0.08) + 0.04, y + sy * (d / 2 - 0.08) + 0.04, h - 0.05, leg)
    r.c.box(x - w / 2, y - d / 2, 0, x + w / 2, y + d / 2, h, "Concrete")


def chair(r, x, y, facing="N", mat="I_WoodDark"):
    r.deco(x - 0.22, y - 0.22, 0.42, x + 0.22, y + 0.22, 0.47, mat)
    by = y - 0.22 if facing == "N" else y + 0.18
    r.deco(x - 0.22, by, 0.47, x + 0.22, by + 0.04, 0.95, mat)
    for sx in (-1, 1):
        for sy in (-1, 1):
            r.deco(x + sx * 0.18 - 0.02, y + sy * 0.18 - 0.02, 0, x + sx * 0.18 + 0.02, y + sy * 0.18 + 0.02, 0.42, mat)


def shelf_unit(r, x0, y0, x1, y1, h=2.0, levels=4, mat="I_Wood", goods=None, rng=None):
    r.solid(x0, y0, 0, x1, y1, 0.08, mat)
    r.deco(x0, y0, 0, x0 + 0.05, y1, h, mat) if (x1 - x0) > (y1 - y0) else None
    for k in range(levels + 1):
        z = 0.1 + k * (h - 0.1) / levels
        r.deco(x0, y0, z - 0.03, x1, y1, z, mat)
        if goods and k < levels:
            along_x = (x1 - x0) > (y1 - y0)
            L = (x1 - x0) if along_x else (y1 - y0)
            n = int(L / 0.32)
            for i in range(n):
                if rng.random() < 0.15:
                    continue
                gh = rng.uniform(0.18, 0.32)
                m = rng.choice(goods)
                if along_x:
                    a = x0 + 0.05 + i * 0.32
                    r.deco(a, y0 + 0.05, z, a + 0.26, y1 - 0.05, z + gh, m)
                else:
                    a = y0 + 0.05 + i * 0.32
                    r.deco(x0 + 0.05, a, z, x1 - 0.05, a + 0.26, z + gh, m)
    r.c.box(x0, y0, 0, x1, y1, h, "Concrete")
    for (px, py) in ((x0, y0), (x1 - 0.05, y0), (x0, y1 - 0.05), (x1 - 0.05, y1 - 0.05)):
        r.deco(px, py, 0, px + 0.05, py + 0.05, h, mat)


def plant(r, x, y, rng, s=1.0):
    r.cyl(x, y, 0, 0.45 * s, 0.25 * s, "I_ConcreteDark", seg=10, collide=True)
    from build_extra import smooth_blob
    smooth_blob(r.v, x, y, 0.9 * s, 0.42 * s, "I_Plant", rng, sq=1.1, subdiv=1)


def crate(r, x, y, s=1.0, z=0.0, mat="I_Wood"):
    r.solid(x - 0.5 * s, y - 0.5 * s, z, x + 0.5 * s, y + 0.5 * s, z + 0.8 * s, mat)
    r.deco(x - 0.52 * s, y - 0.52 * s, z + 0.35 * s, x + 0.52 * s, y + 0.52 * s, z + 0.45 * s, "I_WoodDark")


def counter(r, x0, y0, x1, y1, h=1.05, body="I_WoodDark", top="I_Marble"):
    r.solid(x0, y0, 0, x1, y1, h - 0.05, body)
    r.solid(x0 - 0.05, y0 - 0.05, h - 0.05, x1 + 0.05, y1 + 0.05, h, top)


# --------------------------------------------------------------- interiors ---

def home():
    """The Resident's apartment: living room, kitchenette, bed, wardrobe, garage door."""
    rng = random.Random(1)
    r = Room("home")
    x0, x1, y0, y1 = -5.0, 5.0, -4.0, 4.0
    r.shell(x0, y0, x1, y1, h=3.0, wall="I_Plaster", floor="I_Floorboards",
            doors=[("S", -3.6, 1.1, 2.2), ("E", 2.0, 2.6, 2.5)])
    r.door_leaf("S", -3.6, y0 - T / 2)
    # garage roll door on the east wall
    r.deco(x1 + 0.02, 0.7, 0, x1 + 0.1, 3.3, 2.5, "I_SteelDark")
    for i in range(8):
        r.deco(x1 - 0.0, 0.7, 0.2 + i * 0.3, x1 + 0.02, 3.3, 0.24 + i * 0.3, "I_Steel")
    r.window("N", -2.5, y1, 1.0, 2.0, 1.4)
    r.window("N", 2.5, y1, 1.0, 2.0, 1.4)
    r.window("W", x0, 0.5, 1.0, 1.8, 1.4)
    # living: rug, sofa, coffee table, tv
    r.deco(-3.4, -1.6, 0.0, 0.2, 1.2, 0.02, "I_CarpetBlue")
    sofa(r, -1.6, -1.5, 2.4, "N")
    table(r, -1.6, -0.1, 1.2, 0.6, h=0.4)
    r.solid(-3.0, 2.9, 0, -0.2, 3.5, 0.5, "I_WoodDark")
    r.deco(-2.6, 3.42, 0.8, -0.6, 3.48, 2.0, "I_Black")
    r.deco(-2.5, 3.40, 0.9, -0.7, 3.42, 1.9, "I_Screen")
    plant(r, -4.4, 3.3, rng)
    # kitchenette along the north-east
    counter(r, 0.8, 3.2, 4.8, 3.9, h=0.92, body="I_White", top="I_MarbleDark")
    r.deco(1.0, 3.85, 1.5, 4.6, 3.95, 2.2, "I_White")
    r.solid(4.0, 2.2, 0, 4.9, 3.2, 1.9, "I_Steel")          # fridge
    r.deco(2.0, 3.25, 0.93, 2.6, 3.7, 0.95, "I_Steel")       # hob
    table(r, 2.4, 1.4, 1.2, 0.8)
    chair(r, 2.0, 0.8, "N")
    chair(r, 2.8, 2.0, "S")
    # bed corner (south-east) + wardrobe
    r.solid(1.4, -3.9, 0, 3.6, -1.6, 0.5, "I_WoodDark")
    r.deco(1.45, -3.85, 0.5, 3.55, -1.65, 0.62, "I_White")
    r.deco(1.5, -2.6, 0.62, 3.5, -1.7, 0.66, "I_Red")
    r.solid(1.4, -3.95, 0.5, 3.6, -3.8, 1.3, "I_WoodDark")
    r.deco(1.7, -3.6, 0.62, 2.4, -3.1, 0.75, "I_White")
    r.deco(2.6, -3.6, 0.62, 3.3, -3.1, 0.75, "I_White")
    r.solid(3.9, -3.9, 0, 4.9, -3.3, 0.6, "I_Wood")
    r.deco(4.2, -3.7, 0.6, 4.5, -3.4, 1.0, "I_LampWarm")
    r.light(4.35, -3.55, 1.2, "ffc080", 4, 0.6)
    r.solid(4.3, -2.9, 0, 4.95, -0.4, 2.3, "I_Wood")         # wardrobe
    r.deco(4.28, -1.7, 1.0, 4.3, -1.6, 1.3, "I_Brass")
    r.ceiling_lamp(-1.6, 0.0, h=3.0)
    r.ceiling_lamp(2.6, 2.0, h=3.0, rng=6.0, energy=1.0)
    r.ceiling_lamp(2.6, -2.4, h=3.0, rng=6.0, energy=1.0)
    r.mark("spawn", -3.6, -3.0, 0, 0)
    r.mark("exit", -3.6, y0 - 0.1, 0, 180)
    r.mark("save", 2.5, -1.3, 0, 180)
    r.mark("wardrobe", 3.8, -1.6, 0, -90)
    r.mark("garage", x1 - 0.6, 2.0, 0, -90)
    r.export()


def bank():
    """Lobby with columns and teller line, manager's office, and a vault behind a round door."""
    rng = random.Random(2)
    r = Room("bank")
    x0, x1, y0, y1 = -8.0, 8.0, -6.0, 4.0
    r.shell(x0, y0, x1, y1, h=5.2, wall="I_Plaster", floor="I_Marble", ceil="I_White",
            doors=[("S", 0.0, 2.4, 3.2), ("N", 4.5, 1.6, 2.6)], skirting="I_MarbleDark")
    r.door_leaf("S", 0.0, y0 - T / 2, w=2.4, h=3.2, mat="I_Brass", frame="I_MarbleDark")
    for x in (-6.0, -2.4, 2.4, 6.0):
        r.cyl(x, -2.0, 0, 5.2, 0.4, "I_Marble", seg=14, collide=True)
        r.solid(x - 0.55, -2.55, 0, x + 0.55, -1.45, 0.3, "I_MarbleDark")
        r.solid(x - 0.55, -2.55, 4.9, x + 0.55, -1.45, 5.2, "I_MarbleDark")
    r.deco(-2.0, -5.5, 0.0, 2.0, -0.6, 0.015, "I_Carpet")
    # rope queue
    for x in (-1.6, -0.5, 0.5, 1.6):
        r.cyl(x, -3.2, 0, 0.95, 0.04, "I_Brass", seg=6)
    r.deco(-1.6, -3.22, 0.85, 1.6, -3.18, 0.9, "I_Red")
    # teller counter with glass across the room, gap at the east for the office door
    counter(r, -7.8, 0.4, 3.0, 1.2, h=1.15)
    for i in range(5):
        x = -7.0 + i * 2.2
        r.deco(x - 0.05, 0.75, 1.15, x + 0.05, 0.85, 2.4, "I_Brass")
        r.deco(x + 0.15, 0.78, 1.25, x + 2.05, 0.82, 2.35, "I_Glass")
        r.deco(x + 0.9, 1.0, 1.15, x + 1.4, 1.2, 1.5, "I_Screen")
        chair(r, x + 1.1, 2.0, "S", mat="I_Leather")
    r.solid(3.0, 0.4, 0, 3.2, 1.2, 2.4, "I_WoodDark")   # half wall end
    # manager desk (west of the vault corridor)
    table(r, -5.5, 2.8, 2.0, 0.9, top="I_WoodDark")
    chair(r, -5.5, 3.4, "S", mat="I_Leather")
    r.deco(-5.9, 2.6, 0.75, -5.3, 2.7, 1.1, "I_Screen")
    # walls of the inner vault corridor
    r.solid(3.6, 1.2, 0, 3.8, y1, 5.2, "I_Plaster")
    plant(r, -7.4, -5.4, rng, 1.3)
    plant(r, 7.4, -5.4, rng, 1.3)
    r.window("W", x0, -3.0, 1.4, 1.6, 2.8)
    r.window("E", x1, -3.0, 1.4, 1.6, 2.8)
    for x in (-4.0, 0.0, 4.0):
        r.cyl(x, -3.8, 4.4, 5.2, 0.03, "I_Brass", seg=4)
        r.cyl(x, -3.8, 4.0, 4.4, 0.5, "I_LampWarm", seg=12, r_top=0.15)
        r.light(x, -3.8, 3.6, "ffe0b0", 9, 2.2)
    r.light(-2.0, 2.4, 3.6, "ffe8c8", 7, 1.2)
    # vault room behind the north wall: thick walls, round door standing open
    vx0, vx1, vy0, vy1 = 2.0, 7.0, 4.0 + T, 9.0
    r.shell(vx0, vy0, vx1, vy1, h=3.2, wall="I_ConcreteDark", floor="I_Concrete", ceil="I_ConcreteDark",
            doors=[("S", 4.5, 1.6, 2.6)], skirting="I_SteelDark")
    # round vault door, swung open against the wall, with spokes
    dx, dy = 2.5, 3.2
    seg = 16
    for i in range(seg):
        a0, a1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
        p0 = Vector((dx, dy + 1.25 * math.cos(a0), 1.35 + 1.25 * math.sin(a0)))
        p1 = Vector((dx, dy + 1.25 * math.cos(a1), 1.35 + 1.25 * math.sin(a1)))
        c = Vector((dx, dy, 1.35))
        r.v.face([c, p0, p1], "I_Steel", (1, 0, 0))
        r.v.face([c + Vector((-0.45, 0, 0)), p1 + Vector((-0.45, 0, 0)), p0 + Vector((-0.45, 0, 0))], "I_Steel", (-1, 0, 0))
        r.v.face([p0, p1, p1 + Vector((-0.45, 0, 0)), p0 + Vector((-0.45, 0, 0))], "I_SteelDark",
                 ((p0 + p1) / 2 - c))
    for k in range(3):
        a = k * math.pi / 3
        d = Vector((0, math.cos(a), math.sin(a)))
        r.v.obox(Vector((dx + 0.02, dy, 1.35)) - d * 0.7 - Vector((0, 0, 0.04)), d * 1.4, Vector((0.12, 0, 0)),
                 Vector((0, 0, 0.08)), "I_Brass")
    r.c.box(dx - 0.45, dy - 1.25, 0, dx, dy + 1.25, 2.6, "Concrete")
    # inside the vault: deposit box wall, gold, cash carts
    for row in range(5):
        for col in range(8):
            y = vy0 + 0.6 + col * 0.52
            r.deco(vx0 + 0.02, y, 0.4 + row * 0.5, vx0 + 0.08, y + 0.48, 0.85 + row * 0.5, "I_Steel")
            r.deco(vx0 + 0.08, y + 0.2, 0.6 + row * 0.5, vx0 + 0.1, y + 0.28, 0.65 + row * 0.5, "I_Brass")
    r.c.box(vx0, vy0, 0, vx0 + 0.1, vy1, 3.0, "Concrete")
    for k in range(3):
        y = 6.2 + k * 0.9
        r.solid(5.4, y, 0, 6.8, y + 0.7, 0.8, "I_SteelDark")
        for i in range(10):
            bx = 5.5 + (i % 5) * 0.26
            by = y + 0.08 + (i // 5) * 0.3
            r.deco(bx, by, 0.8, bx + 0.22, by + 0.22 * 0.0 + 0.12, 0.88, "I_Gold")
            if i < 5:
                r.deco(bx, by + 0.15, 0.88, bx + 0.22, by + 0.27, 0.96, "I_Gold")
    for (x, y) in ((3.4, 7.8), (4.3, 8.3)):
        r.solid(x - 0.4, y - 0.3, 0, x + 0.4, y + 0.3, 0.9, "I_Steel")
        for z in range(3):
            r.deco(x - 0.35, y - 0.25, 0.9 + z * 0.12, x + 0.35, y + 0.25, 1.0 + z * 0.12, "I_Cash")
    r.ceiling_lamp(4.5, 6.6, h=3.2, mat="I_LampCool", color="d8e8ff", rng=6, energy=1.4, size=1.2)
    r.deco(4.0, vy0 + 0.02, 2.75, 5.0, vy0 + 0.06, 2.95, "I_RedLight")
    r.mark("spawn", 0.0, -5.0, 0, 0)
    r.mark("exit", 0.0, y0 - 0.1, 0, 180)
    r.mark("counter", -2.0, -0.2, 0, 0)
    r.mark("manager", -5.5, 2.0, 0, 0)
    r.mark("vault_door", 4.5, 4.2, 0, 0)
    r.mark("vault", 4.5, 7.0, 0, 0)
    r.mark("alarm", 7.6, 0.0, 2.4, -90)
    r.deco(7.75, -0.3, 2.2, 7.95, 0.3, 2.6, "I_RedLight")
    r.export()


def bunker():
    """Blast door at street level, stairs down to a stash room and a garage bay."""
    rng = random.Random(3)
    r = Room("bunker")
    # entry landing at z 0
    r.shell(-2.0, -3.0, 2.0, 0.0, h=2.8, wall="I_Concrete", floor="I_ConcreteDark", ceil="I_ConcreteDark",
            doors=[("S", 0.0, 1.2, 2.2), ("N", 0.0, 1.8, 2.8)], skirting="I_SteelDark")
    r.door_leaf("S", 0.0, -3.0 - T / 2, w=1.2, h=2.2, mat="I_SteelDark", frame="I_Steel")
    # stairs down 3 m going north
    steps = 12
    for i in range(steps):
        z = -0.25 * (i + 1)
        y = 0.0 + i * 0.3
        r.solid(-0.9, y, z - 0.25, 0.9, y + 0.3, z, "I_ConcreteDark")
    r.solid(-1.1, 0.0, -3.3, -0.9, 3.6, 2.8, "I_Concrete")
    r.solid(0.9, 0.0, -3.3, 1.1, 3.6, 2.8, "I_Concrete")
    r.solid(-1.1, 0.0, 2.8, 1.1, 3.6, 3.05, "I_ConcreteDark")
    for x in (-0.85, 0.85):
        r.deco(x - 0.03, 0.0, -0.1, x + 0.03, 3.6, 0.0, "I_Yellow")
    # main hall at z -3
    z = -3.0
    x0, x1, y0, y1 = -7.0, 7.0, 3.6, 13.0
    r.shell(x0, y0, x1, y1, h=3.4, z=z, wall="I_Concrete", floor="I_ConcreteDark", ceil="I_ConcreteDark",
            doors=[("S", 0.0, 1.8, 2.8), ("E", 10.0, 3.2, 3.0)], skirting="I_Yellow")
    # strip lights and caged bulbs
    for x in (-4.5, 0.0, 4.5):
        for y in (6.0, 10.5):
            r.deco(x - 0.9, y - 0.08, z + 3.25, x + 0.9, y + 0.08, z + 3.4, "I_LampCool")
            r.light(x, y, z + 2.8, "e6f0ff", 7, 1.2)
    r.light(0.0, 1.5, 0.6, "ffd090", 5, 0.8)
    r.deco(-0.2, 1.4, 2.6, 0.2, 1.8, 2.8, "I_LampWarm")
    # stash wall: weapon rack (silhouettes), crates, cash table, map table, bunks
    r.solid(x0 + 0.02, 5.0, z, x0 + 0.4, 10.0, z + 2.6, "I_WoodDark")
    for i in range(9):
        y = 5.4 + i * 0.5
        r.deco(x0 + 0.42, y, z + 0.9, x0 + 0.5, y + 0.08, z + 2.2, "I_Black")
        r.deco(x0 + 0.42, y - 0.05, z + 1.5, x0 + 0.5, y + 0.16, z + 1.65, "I_Black")
    for (cx, cy, s) in ((-5.6, 11.8, 1.0), (-4.5, 12.2, 0.9), (-5.6, 11.8 + 0.0, 0.8)):
        crate(r, cx, cy, s, z=z if s != 0.8 else z + 0.8, mat="I_Olive")
    table(r, -2.5, 8.0, 2.4, 1.2, h=0.85, top="I_Green", leg="I_SteelDark")
    for i in range(14):
        bx = -3.5 + (i % 7) * 0.28
        by = 7.7 + (i // 7) * 0.35
        r.deco(bx, by, z + 0.85, bx + 0.24, by + 0.15, z + 0.85 + 0.06 * (1 + i % 3), "I_Cash")
    r.deco(-2.0, 8.0, z + 0.85, -1.6, 8.4, z + 1.2, "I_SteelDark")
    r.deco(-2.7, 7.8, z + 2.0, -2.3, 8.2, z + 2.2, "I_LampWarm")
    r.light(-2.5, 8.0, z + 1.8, "ffcc80", 4, 0.9)
    # map table with city map + monitors on the north wall
    table(r, 2.5, 10.8, 2.6, 1.6, h=0.9, top="I_SteelDark", leg="I_SteelDark")
    r.deco(1.4, 10.1, z + 0.9, 3.6, 11.5, z + 0.92, "I_Paper")
    for k in range(3):
        r.deco(0.8 + k * 1.3, y1 - 0.06, z + 1.4, 1.9 + k * 1.3, y1 - 0.02, z + 2.1, "I_Screen")
    for (bx, by) in ((4.2, 4.2), (6.0, 4.2)):
        r.solid(bx - 0.5, by, z, bx + 0.5, by + 2.0, z + 0.45, "I_SteelDark")
        r.deco(bx - 0.45, by + 0.05, z + 0.45, bx + 0.45, by + 1.95, z + 0.6, "I_Olive")
        r.deco(bx - 0.5, by, z + 1.5, bx + 0.5, by + 2.0, z + 1.6, "I_SteelDark")
        r.deco(bx - 0.45, by + 0.05, z + 1.6, bx + 0.45, by + 1.95, z + 1.75, "I_Olive")
    # garage bay through the east opening
    gx0, gx1, gy0, gy1 = x1 + T, 15.0, 6.5, 13.0
    r.shell(gx0, gy0, gx1, gy1, h=3.4, z=z, wall="I_ConcreteDark", floor="I_ConcreteDark", ceil="I_ConcreteDark",
            doors=[("W", 10.0, 3.2, 3.0), ("E", 9.75, 3.6, 3.0)], skirting="I_Yellow")
    r.deco(gx1 + 0.02, 7.95, z, gx1 + 0.1, 11.55, z + 3.0, "I_SteelDark")
    for i in range(9):
        r.deco(gx1, 7.95, z + 0.2 + i * 0.32, gx1 + 0.02, 11.55, z + 0.24 + i * 0.32, "I_Yellow" if i % 2 else "I_Black")
    for y in (8.6, 11.0):
        r.deco(gx0 + 0.6, y - 0.05, z + 0.0, gx1 - 0.6, y + 0.05, z + 0.01, "I_Yellow")
    r.solid(gx0 + 0.3, gy0 + 0.1, z, gx0 + 2.0, gy0 + 0.7, z + 1.0, "I_Red")   # tool chest
    r.light(12.0, 10.0, z + 2.8, "e6f0ff", 7, 1.0)
    r.deco(11.0, 9.9, z + 3.25, 13.0, 10.1, z + 3.4, "I_LampCool")
    r.mark("spawn", 0.0, -2.0, 0, 0)
    r.mark("exit", 0.0, -3.1, 0, 180)
    r.mark("stash", -6.0, 7.5, z, -90)
    r.mark("cash_table", -2.5, 7.0, z, 0)
    r.mark("map", 2.5, 9.6, z, 0)
    r.mark("bed", 5.1, 5.0, z, 0)
    r.mark("garage", 12.0, 9.75, z, -90)
    r.mark("garage_exit", gx1 - 0.3, 9.75, z, -90)
    r.export()


def shop(variant):
    """One shop layout dressed three ways: gas station mart, pawn shop, diner."""
    rng = random.Random(4)
    r = Room("shop_" + variant)
    x0, x1, y0, y1 = -5.0, 5.0, -4.0, 4.0
    floor = {"gas": "I_Tile", "pawn": "I_Floorboards", "diner": "I_Tile"}[variant]
    wall = {"gas": "I_PlasterCool", "pawn": "I_Plaster", "diner": "I_White"}[variant]
    r.shell(x0, y0, x1, y1, h=3.2, wall=wall, floor=floor,
            doors=[("S", -2.5, 1.4, 2.3), ("N", 3.6, 1.0, 2.2)], skirting="I_ConcreteDark")
    r.door_leaf("S", -2.5, y0 - T / 2, w=1.4, h=2.3, mat="I_Glass", frame="I_Steel")
    r.window("S", 1.5, y0, 0.6, 4.4, 1.8)
    # back room behind the north door: the safe
    r.shell(2.6, y1 + T, 5.0, 6.6, h=3.2, wall="I_ConcreteDark", floor="I_ConcreteDark",
            doors=[("S", 3.6, 1.0, 2.2)])
    r.solid(3.9, 5.7, 0, 4.9, 6.55, 1.1, "I_SteelDark")
    r.deco(3.95, 5.66, 0.4, 4.4, 5.7, 0.8, "I_Steel")
    shelf_unit(r, 2.7, 5.5, 3.4, 6.55, h=2.0, levels=3, mat="I_SteelDark",
               goods=["I_Olive", "I_Paper", "I_Wood"], rng=rng)
    r.ceiling_lamp(3.8, 5.6, h=3.2, mat="I_LampCool", color="e0ecff", rng=4, energy=0.7, size=0.4)
    # counter by the door, register, cigarettes / lottery behind
    counter(r, -4.9, -0.8, -1.8, -0.1, h=1.0, body="I_Red" if variant == "diner" else "I_WoodDark",
            top="I_MarbleDark" if variant != "pawn" else "I_Glass")
    r.deco(-3.4, -0.6, 1.0, -2.8, -0.2, 1.3, "I_SteelDark")
    r.deco(-3.35, -0.62, 1.15, -2.85, -0.6, 1.28, "I_Screen")
    r.mark("register", -3.1, -0.45, 1.0, 180)
    if variant == "gas":
        shelf_unit(r, -4.9, 0.3, -1.9, 0.6, h=2.2, levels=5, mat="I_Steel",
                   goods=["I_Red", "I_Yellow", "I_White", "I_Cash"], rng=rng)
        for x in (-0.6, 1.6):  # aisles
            shelf_unit(r, x, -2.4, x + 0.8, 2.0, h=1.6, levels=3, mat="I_White",
                       goods=["I_Red", "I_Yellow", "I_CarpetBlue", "I_Green", "I_White"], rng=rng)
        for i in range(4):  # fridges on the east wall
            y = -3.2 + i * 1.6
            r.solid(4.2, y, 0, 4.95, y + 1.5, 2.3, "I_Steel")
            r.deco(4.17, y + 0.08, 0.15, 4.2, y + 1.42, 2.15, "I_Fridge")
        r.solid(-1.4, -3.7, 0, -0.4, -3.0, 1.6, "I_Red")  # slushie machine
        r.deco(-1.3, -3.72, 1.0, -0.5, -3.7, 1.5, "I_NeonCyan")
        lamps = [(-3.0, 1.5), (0.0, 0.0), (2.6, 0.0), (2.6, -2.8), (0.0, -2.8)]
        lamp_mat, lamp_col = "I_LampCool", "eef4ff"
    elif variant == "pawn":
        for (x, y) in ((-0.5, -1.5), (1.5, -1.5), (-0.5, 1.2), (1.5, 1.2)):
            r.solid(x - 0.7, y - 0.4, 0, x + 0.7, y + 0.4, 0.9, "I_WoodDark")
            r.deco(x - 0.68, y - 0.38, 0.9, x + 0.68, y + 0.38, 1.0, "I_Glass")
            for k in range(4):
                r.deco(x - 0.5 + k * 0.3, y - 0.1, 0.9, x - 0.35 + k * 0.3, y + 0.1, 0.95, rng.choice(["I_Gold", "I_Steel", "I_Brass"]))
        shelf_unit(r, 4.3, -3.8, 4.95, 3.8, h=2.4, levels=4, mat="I_WoodDark",
                   goods=["I_Black", "I_Steel", "I_Brass", "I_Red", "I_Wood"], rng=rng)
        for i in range(4):  # guitars on the west wall
            r.deco(x0 + 0.02, -3.0 + i * 0.8, 1.4, x0 + 0.1, -2.75 + i * 0.8, 2.6, "I_Wood")
            r.deco(x0 + 0.02, -3.1 + i * 0.8, 1.2, x0 + 0.12, -2.65 + i * 0.8, 1.7, rng.choice(["I_Red", "I_Black", "I_Yellow"]))
        r.deco(-4.9, 0.4, 1.0, -1.9, 0.5, 2.4, "I_Steel")   # wire grille over the counter
        r.deco(-2.0, y0 + 0.02, 2.6, 0.0, y0 + 0.06, 2.9, "I_NeonGreen")
        lamps = [(-3.0, 1.5), (0.5, -0.2), (3.0, 1.5), (3.0, -2.5)]
        lamp_mat, lamp_col = "I_LampWarm", "ffcf90"
    else:  # diner
        counter(r, -1.0, 1.4, 4.8, 2.0, h=1.05, body="I_Red", top="I_Steel")
        for i in range(6):
            x = -0.5 + i * 0.9
            r.cyl(x, 1.0, 0, 0.7, 0.06, "I_Steel", seg=6)
            r.cyl(x, 1.0, 0.7, 0.78, 0.22, "I_Red", seg=10, collide=True)
        r.deco(-1.0, y1 - 0.4, 0.0, 4.8, y1 - 0.02, 1.0, "I_Steel")
        r.deco(-1.0, y1 - 0.4, 1.4, 4.8, y1 - 0.02, 1.5, "I_Steel")
        r.deco(0.0, y1 - 0.05, 1.8, 2.5, y1 - 0.02, 2.3, "I_Screen")    # menu board
        for (bx, by) in ((-4.0, -3.0), (-0.5, -3.0), (2.5, -3.0)):
            r.solid(bx - 0.9, by - 0.6, 0, bx + 0.9, by - 0.15, 0.45, "I_Red")
            r.solid(bx - 0.9, by - 0.6, 0.45, bx + 0.9, by - 0.45, 1.1, "I_Red")
            table(r, bx, by + 0.35, 1.6, 0.7, h=0.75, top="I_White", leg="I_Steel")
            r.solid(bx - 0.9, by + 0.85, 0, bx + 0.9, by + 1.3, 0.45, "I_Red")
            r.solid(bx - 0.9, by + 1.15, 0.45, bx + 0.9, by + 1.3, 1.1, "I_Red")
        r.deco(-4.8, y0 + 0.02, 2.5, 4.8, y0 + 0.06, 2.6, "I_NeonCyan")
        lamps = [(-3.0, 0.5), (0.0, -2.6), (3.0, -2.6), (2.0, 1.7)]
        lamp_mat, lamp_col = "I_LampWarm", "ffe0b0"
    for (x, y) in lamps:
        r.ceiling_lamp(x, y, h=3.2, mat=lamp_mat, color=lamp_col, rng=6, energy=1.1, size=0.9)
    r.mark("spawn", -2.5, -3.0, 0, 0)
    r.mark("exit", -2.5, y0 - 0.1, 0, 180)
    r.mark("counter", -3.1, -1.3, 0, 0)
    r.mark("clerk", -3.1, 0.2, 0, 180)
    r.mark("safe", 4.3, 5.2, 0, 0)
    r.export()


def nightclub():
    rng = random.Random(5)
    r = Room("nightclub")
    x0, x1, y0, y1 = -9.0, 9.0, -6.0, 8.0
    r.shell(x0, y0, x1, y1, h=5.0, wall="I_Black", floor="I_MarbleDark", ceil="I_Black",
            doors=[("S", 0.0, 1.8, 2.6), ("N", 7.0, 1.0, 2.2)], skirting="I_NeonPurple")
    r.door_leaf("S", 0.0, y0 - T / 2, w=1.8, h=2.6, mat="I_Leather", frame="I_Black")
    # dance floor: glowing tiles in a checker of three colours
    cols = ["I_NeonPink", "I_NeonCyan", "I_NeonPurple", "I_Black"]
    for i in range(7):
        for j in range(5):
            x, y = -3.5 + i * 1.0, -1.0 + j * 1.0
            r.deco(x + 0.03, y + 0.03, 0.0, x + 0.97, y + 0.97, 0.03, cols[(i * 3 + j * 2 + i * j) % 4])
    r.light(0.0, 1.5, 3.6, "ff40c0", 8, 2.0)
    r.light(-3.0, 1.5, 3.6, "30e0ff", 7, 1.6)
    r.light(3.0, 1.5, 3.6, "8040ff", 7, 1.6)
    # mirror ball and truss
    from build_extra import smooth_blob
    smooth_blob(r.v, 0.0, 1.5, 4.0, 0.45, "I_Steel", rng, subdiv=2, jitter=0.0)
    r.cyl(0.0, 1.5, 4.4, 5.0, 0.02, "I_Steel", seg=4)
    r.deco(-4.0, -1.2, 4.5, 4.0, -1.0, 4.7, "I_SteelDark")
    r.deco(-4.0, 3.9, 4.5, 4.0, 4.1, 4.7, "I_SteelDark")
    for x in (-3.0, -1.0, 1.0, 3.0):
        r.cyl(x, -1.1, 4.1, 4.5, 0.15, "I_Black", seg=8)
        r.cyl(x, 4.0, 4.1, 4.5, 0.15, "I_Black", seg=8)
    # DJ booth on a riser to the north
    r.solid(-2.5, 5.0, 0, 2.5, y1, 0.6, "I_Black")
    r.solid(-1.6, 5.2, 0.6, 1.6, 5.8, 1.6, "I_SteelDark")
    r.deco(-1.6, 5.18, 0.8, 1.6, 5.2, 1.0, "I_NeonCyan")
    r.deco(-1.2, 5.3, 1.6, -0.4, 5.7, 1.65, "I_Black")
    r.deco(0.4, 5.3, 1.6, 1.2, 5.7, 1.65, "I_Black")
    for x in (-2.3, 2.3):
        r.solid(x - 0.5, 6.2, 0.6, x + 0.5, 7.0, 2.6, "I_Black")
        r.deco(x - 0.35, 6.16, 1.5, x + 0.35, 6.2, 2.2, "I_SteelDark")
    r.deco(-3.0, y1 - 0.06, 1.0, 3.0, y1 - 0.02, 4.0, "I_Screen")
    # bar along the west wall with backlit bottles
    counter(r, x0 + 1.5, -4.5, x0 + 2.3, 3.5, h=1.1, body="I_Black", top="I_MarbleDark")
    r.deco(x0 + 1.48, -4.5, 0.15, x0 + 1.5, 3.5, 0.25, "I_NeonPink")
    r.deco(x0 + 0.02, -4.2, 1.0, x0 + 0.06, 3.2, 2.6, "I_NeonPurple")
    for k in range(3):
        z = 1.2 + k * 0.5
        r.deco(x0 + 0.06, -4.2, z - 0.04, x0 + 0.4, 3.2, z, "I_Glass")
        for i in range(24):
            y = -4.0 + i * 0.3
            r.cyl(x0 + 0.22, y, z, z + 0.3, 0.06, rng.choice(["I_Green", "I_Brass", "I_Glass", "I_Red"]), seg=6)
    for i in range(6):
        r.cyl(x0 + 3.0, -3.5 + i * 1.3, 0, 0.75, 0.2, "I_Steel", seg=8, collide=True)
    r.light(x0 + 1.5, -0.5, 3.0, "ff60d0", 7, 1.2)
    # booths on the east side
    for k in range(3):
        y = -4.5 + k * 3.0
        r.solid(x1 - 1.0, y, 0, x1 - 0.02, y + 2.2, 1.3, "I_Leather")
        r.solid(x1 - 2.5, y, 0, x1 - 1.0, y + 0.3, 1.1, "I_Leather")
        r.solid(x1 - 2.5, y + 1.9, 0, x1 - 1.0, y + 2.2, 1.1, "I_Leather")
        r.cyl(x1 - 1.9, y + 1.1, 0, 0.7, 0.45, "I_MarbleDark", seg=12, collide=True)
        r.deco(x1 - 0.05, y + 0.3, 2.0, x1 - 0.02, y + 1.9, 2.1, "I_NeonCyan")
        r.light(x1 - 1.5, y + 1.1, 2.6, "60c0ff", 4, 0.6)
    # VIP rope and the back office through the north-east door
    ox0, ox1, oy0, oy1 = 5.0, 9.0, y1 + T, 12.0
    r.shell(ox0, oy0, ox1, oy1, h=3.0, wall="I_WoodDark", floor="I_Carpet", ceil="I_Black",
            doors=[("S", 7.0, 1.0, 2.2)], skirting="I_Brass")
    table(r, 7.0, 10.6, 2.0, 0.9, top="I_WoodDark")
    chair(r, 7.0, 11.3, "S", mat="I_Leather")
    r.solid(5.1, 11.2, 0, 6.0, 11.95, 1.2, "I_SteelDark")   # safe
    r.deco(5.2, 11.18, 0.4, 5.8, 11.2, 0.9, "I_Steel")
    sofa(r, 6.0, 8.9, 1.6, "N", mat="I_Leather")
    r.ceiling_lamp(7.0, 10.2, h=3.0, rng=5, energy=0.9, size=0.5)
    r.light(0.0, -4.5, 3.2, "a060ff", 7, 0.8)
    r.mark("spawn", 0.0, -5.0, 0, 0)
    r.mark("exit", 0.0, y0 - 0.1, 0, 180)
    r.mark("bar", x0 + 3.0, 0.0, 0, -90)
    r.mark("dance", 0.0, 1.5, 0, 0)
    r.mark("dj", 0.0, 6.2, 0.6, 180)
    r.mark("office", 7.0, 9.6, 0, 0)
    r.mark("safe", 5.5, 10.7, 0, 0)
    r.export()


def police():
    rng = random.Random(6)
    r = Room("police")
    x0, x1, y0, y1 = -7.0, 7.0, -6.0, 6.0
    r.shell(x0, y0, x1, y1, h=3.4, wall="I_PlasterCool", floor="I_Tile", ceil="I_White",
            doors=[("S", -3.0, 1.6, 2.4)], skirting="I_CarpetBlue")
    r.door_leaf("S", -3.0, y0 - T / 2, w=1.6, h=2.4, mat="I_Glass", frame="I_SteelDark")
    r.window("S", 3.0, y0, 1.0, 4.0, 1.4)
    r.deco(-7.0, -6.0, 0, 7.0, 6.0, 0.012, "I_Tile")
    # waiting area benches, front desk with a raised counter and a flag
    for y in (-4.6, -3.4):
        r.solid(-6.6, y, 0, -4.4, y + 0.45, 0.45, "I_SteelDark")
    counter(r, -4.0, -2.6, 1.0, -1.8, h=1.2, body="I_WoodDark", top="I_MarbleDark")
    r.deco(-3.2, -1.95, 1.2, -2.6, -1.85, 1.6, "I_Screen")
    r.deco(-0.6, -1.95, 1.2, 0.0, -1.85, 1.6, "I_Screen")
    r.deco(-4.0, -2.62, 0.3, 1.0, -2.6, 0.9, "I_CarpetBlue")
    r.cyl(-6.5, 5.4, 0, 2.4, 0.03, "I_Brass", seg=6)
    r.deco(-6.48, 4.6, 1.6, -6.46, 5.38, 2.3, "I_CarpetBlue")
    # bullpen desks
    for (x, y) in ((-4.5, 1.5), (-1.5, 1.5), (-4.5, 4.2), (-1.5, 4.2)):
        table(r, x, y, 1.8, 0.9, top="I_SteelDark", leg="I_SteelDark")
        r.deco(x - 0.3, y + 0.2, 0.75, x + 0.3, y + 0.3, 1.2, "I_Screen")
        r.deco(x + 0.4, y - 0.2, 0.75, x + 0.8, y + 0.1, 0.85, "I_Paper")
        chair(r, x, y - 0.8, "N", mat="I_Black")
    for k in range(5):
        r.solid(x0 + 0.02, -1.0 + k * 0.6, 0, x0 + 0.6, -0.45 + k * 0.6, 1.4, "I_Steel")  # filing cabinets
    r.deco(-6.0, y1 - 0.05, 1.2, -2.0, y1 - 0.02, 2.4, "I_Paper")  # notice board
    # cells along the east: back wall, dividers, bars
    cx0 = 2.4
    for k in range(4):
        y = -1.4 + k * 2.4
        r.solid(cx0, y - 0.1, 0, x1, y + 0.1, 3.4, "I_ConcreteDark")
    for k in range(3):
        ya, yb = -1.3 + k * 2.4, -1.3 + (k + 1) * 2.4 - 0.2
        r.deco(cx0 + 0.6 + 2.9, ya + 0.1, 0, x1 - 0.1, ya + 0.9, 0.5, "I_SteelDark")   # bunk
        r.solid(cx0 + 3.5, ya + 0.1, 0, x1 - 0.1, ya + 0.9, 0.5, "I_SteelDark")
        r.deco(cx0 + 3.6, ya + 0.15, 0.5, x1 - 0.15, ya + 0.85, 0.58, "I_White")
        r.cyl(cx0 + 1.2, yb - 0.35, 0, 0.45, 0.22, "I_Steel", seg=8, collide=True)        # toilet
        for i in range(10):
            yy = ya + 0.05 + i * (yb - ya - 0.1) / 9
            r.deco(cx0 - 0.03, yy - 0.025, 0, cx0 + 0.03, yy + 0.025, 3.0, "I_Steel")
        r.c.box(cx0 - 0.05, ya, 0, cx0 + 0.05, yb, 3.4, "Concrete")
        r.deco(cx0 - 0.06, ya, 1.0, cx0 + 0.06, yb, 1.06, "I_Steel")
        r.deco(cx0 - 0.06, ya, 2.95, cx0 + 0.06, yb, 3.05, "I_Steel")
        r.light(cx0 + 2.4, (ya + yb) / 2, 3.0, "e0ecff", 4, 0.5)
        r.deco(cx0 + 2.2, (ya + yb) / 2 - 0.2, 3.3, cx0 + 2.6, (ya + yb) / 2 + 0.2, 3.4, "I_LampCool")
        r.mark(f"cell_{k + 1}", cx0 + 2.0, (ya + yb) / 2, 0, -90)
    r.deco(cx0 + 0.0, -1.5, 3.2, cx0 + 0.1, 5.8, 3.4, "I_SteelDark")
    # evidence locker in the south-east corner
    r.solid(3.0, -5.9, 0, 6.9, -5.2, 2.4, "I_SteelDark")
    for i in range(6):
        r.deco(3.1 + i * 0.63, -5.22, 0.2, 3.6 + i * 0.63, -5.18, 2.2, "I_Steel")
    for (x, y) in ((-4.5, -4.0), (-1.5, 2.8), (-4.5, 2.8), (0.8, -4.0), (4.5, -3.5)):
        r.ceiling_lamp(x, y, h=3.4, mat="I_LampCool", color="eaf2ff", rng=6, energy=1.1, size=1.2)
    r.mark("spawn", -3.0, -5.0, 0, 0)
    r.mark("exit", -3.0, y0 - 0.1, 0, 180)
    r.mark("desk", -1.5, -3.2, 0, 0)
    r.mark("evidence", 5.0, -4.6, 0, 180)
    r.mark("busted", 1.6, 2.2, 0, -90)
    r.export()

def shop_clothes():
    """Clothing shop: racks and tables of clothes, mannequins, fitting rooms, a big mirror."""
    rng = random.Random(8)
    r = Room("shop_clothes")
    x0, x1, y0, y1 = -5.0, 5.0, -4.0, 4.0
    r.shell(x0, y0, x1, y1, h=3.4, wall="I_White", floor="I_Floorboards",
            doors=[("S", -1.8, 1.4, 2.3), ("N", 3.6, 1.0, 2.2)], skirting="I_WoodDark")
    r.door_leaf("S", -1.8, y0 - T / 2, w=1.4, h=2.3, mat="I_Glass", frame="I_Steel")
    r.window("S", -4.0, y0, 0.5, 1.6, 2.4)
    r.window("S", 2.4, y0, 0.5, 4.2, 2.4)
    colours = ["I_Red", "I_CarpetBlue", "I_Yellow", "I_Green", "I_Black", "I_White", "I_Fabric", "I_Olive",
               "I_NeonPink", "I_Leather"]
    # hanging rails: a chrome bar with a row of garments
    def rail(x, y, length, along_x=True):
        if along_x:
            for e in (x - length / 2, x + length / 2):
                r.cyl(e, y, 0, 1.55, 0.03, "I_Steel", seg=6)
            r.deco(x - length / 2, y - 0.02, 1.5, x + length / 2, y + 0.02, 1.55, "I_Steel")
            n = int(length / 0.12)
            for i in range(n):
                gx = x - length / 2 + 0.08 + i * 0.12
                ln = rng.uniform(0.6, 1.0)
                r.deco(gx - 0.03, y - 0.25, 1.5 - ln, gx + 0.03, y + 0.25, 1.48, rng.choice(colours[:8]))
            r.c.box(x - length / 2, y - 0.3, 0, x + length / 2, y + 0.3, 1.6, "Concrete")
        else:
            for e in (y - length / 2, y + length / 2):
                r.cyl(x, e, 0, 1.55, 0.03, "I_Steel", seg=6)
            r.deco(x - 0.02, y - length / 2, 1.5, x + 0.02, y + length / 2, 1.55, "I_Steel")
            n = int(length / 0.12)
            for i in range(n):
                gy = y - length / 2 + 0.08 + i * 0.12
                ln = rng.uniform(0.6, 1.0)
                r.deco(x - 0.25, gy - 0.03, 1.5 - ln, x + 0.25, gy + 0.03, 1.48, rng.choice(colours[:8]))
            r.c.box(x - 0.3, y - length / 2, 0, x + 0.3, y + length / 2, 1.6, "Concrete")
    rail(-3.2, 1.2, 2.4)
    rail(-3.2, -1.6, 2.4)
    rail(4.4, -0.6, 4.0, along_x=False)
    # display tables with folded stacks
    for (tx, ty) in ((0.2, -1.6), (0.2, 1.0)):
        table(r, tx, ty, 1.6, 0.9, h=0.8, top="I_Wood", leg="I_WoodDark")
        for i in range(6):
            sx = tx - 0.6 + (i % 3) * 0.6
            sy = ty - 0.2 + (i // 3) * 0.4
            for k in range(rng.randint(2, 4)):
                r.deco(sx - 0.22, sy - 0.15, 0.8 + k * 0.06, sx + 0.22, sy + 0.15, 0.85 + k * 0.06, rng.choice(colours))
    # mannequins
    for (mx, my) in ((-4.2, -3.2), (1.6, -3.3), (3.4, -3.3)):
        r.cyl(mx, my, 0, 0.05, 0.25, "I_SteelDark", seg=10, collide=True)
        r.cyl(mx, my, 0.05, 0.9, 0.04, "I_Steel", seg=6)
        r.deco(mx - 0.22, my - 0.13, 0.9, mx + 0.22, my + 0.13, 1.55, rng.choice(colours))
        r.deco(mx - 0.18, my - 0.11, 0.5, mx + 0.18, my + 0.11, 0.95, rng.choice(colours))
        from build_extra import smooth_blob
        smooth_blob(r.v, mx, my, 1.72, 0.13, "I_White", rng, subdiv=1, jitter=0.0)
    # fitting rooms along the north wall (two curtained booths)
    for i, cx in enumerate((-3.9, -2.4)):
        r.solid(cx - 0.75, y1 - 1.5, 0, cx - 0.7, y1, 2.3, "I_White")
        r.deco(cx - 0.7, y1 - 1.5, 0.15, cx + 0.7, y1 - 1.45, 2.2, "I_Carpet" if i == 0 else "I_CarpetBlue")
        r.deco(cx - 0.6, y1 - 0.06, 0.4, cx + 0.6, y1 - 0.02, 2.0, "I_Glass")   # mirror inside
    r.solid(-1.65, y1 - 1.5, 0, -1.6, y1, 2.3, "I_White")
    # big mirror and a bench
    r.deco(-0.4, y1 - 0.06, 0.3, 1.4, y1 - 0.02, 2.4, "I_Glass")
    r.deco(-0.5, y1 - 0.08, 0.2, 1.5, y1 - 0.06, 2.5, "I_Brass")
    r.solid(-0.2, y1 - 1.2, 0, 1.2, y1 - 0.8, 0.45, "I_Leather")
    # counter by the door
    counter(r, 1.6, -0.6, 3.6, 0.0, h=1.0, body="I_White", top="I_Wood")
    r.deco(2.4, -0.4, 1.0, 2.9, -0.1, 1.3, "I_SteelDark")
    r.deco(2.45, -0.42, 1.12, 2.85, -0.4, 1.26, "I_Screen")
    r.mark("register", 2.65, -0.25, 1.0, 180)
    # back room with the safe
    r.shell(2.6, y1 + T, 5.0, 6.6, h=3.4, wall="I_ConcreteDark", floor="I_ConcreteDark", doors=[("S", 3.6, 1.0, 2.2)])
    r.solid(3.9, 5.7, 0, 4.9, 6.55, 1.1, "I_SteelDark")
    crate(r, 3.2, 5.9, 0.7, mat="I_Paper")
    r.ceiling_lamp(3.8, 5.6, h=3.4, mat="I_LampCool", color="e0ecff", rng=4, energy=0.7, size=0.4)
    plant(r, 4.4, -3.4, rng, 1.0)
    r.deco(-4.8, y0 + 0.02, 2.75, 4.8, y0 + 0.06, 2.85, "I_NeonPink")
    for (x, y) in ((-3.0, 0.0), (0.2, -0.3), (3.0, 1.6), (3.0, -2.4), (-3.0, 2.8)):
        r.ceiling_lamp(x, y, h=3.4, mat="I_LampWarm", color="fff0d8", rng=6, energy=1.1, size=0.5)
    r.mark("spawn", -1.8, -3.0, 0, 0)
    r.mark("exit", -1.8, y0 - 0.1, 0, 180)
    r.mark("counter", 2.6, -1.1, 0, 0)
    r.mark("clerk", 2.6, 0.5, 0, 180)
    r.mark("racks", -3.2, -0.2, 0, 0)
    r.mark("fitting_room", -3.9, y1 - 0.8, 0, 180)
    r.mark("mirror", 0.5, y1 - 1.6, 0, 0)
    r.mark("safe", 4.3, 5.2, 0, 0)
    r.export()


def casino():
    """Gaming floor (slots, card tables, roulette, bar, cashier cage) and, behind the cage,
    the counting room with the cash, the money counters and the security monitors."""
    rng = random.Random(9)
    r = Room("casino")
    x0, x1, y0, y1 = -12.0, 12.0, -8.0, 7.0
    r.shell(x0, y0, x1, y1, h=5.0, wall="I_WoodDark", floor="I_Carpet", ceil="I_Black",
            doors=[("S", 0.0, 2.6, 3.0), ("N", 7.5, 1.2, 2.4)], skirting="I_Brass")
    r.door_leaf("S", 0.0, y0 - T / 2, w=2.6, h=3.0, mat="I_Glass", frame="I_Brass")
    r.deco(-2.5, y0, 0.0, 2.5, -4.5, 0.015, "I_MarbleDark")  # entry runner
    # slot machine banks, back to back
    for bx in (-9.5, -6.5):
        for i in range(6):
            y = -5.6 + i * 1.0
            for side in (-1, 1):
                x = bx + side * 0.45
                r.solid(x - 0.3, y - 0.4, 0, x + 0.3, y + 0.4, 1.0, "I_SteelDark")
                r.deco(x - 0.32, y - 0.38, 1.0, x + 0.32, y + 0.38, 1.75, "I_Black")
                r.deco(x + side * 0.33 - 0.01, y - 0.3, 1.15, x + side * 0.33 + 0.01, y + 0.3, 1.6, "I_Screen")
                r.deco(x - 0.3, y - 0.36, 1.75, x + 0.3, y + 0.36, 1.95,
                       rng.choice(["I_NeonPink", "I_NeonCyan", "I_NeonPurple", "I_NeonGreen"]))
                chair(r, x + side * 0.75, y, "N", mat="I_Leather")
        r.light(bx, -3.0, 3.0, "ff70d0", 7, 1.2)
    # card tables
    for (tx, ty) in ((-1.5, -3.5), (2.5, -3.5), (-1.5, 0.5), (2.5, 0.5)):
        r.cyl(tx, ty, 0, 0.72, 0.3, "I_WoodDark", seg=10)
        r.cyl(tx, ty, 0.72, 0.8, 1.2, "I_Green", seg=16, collide=True)
        r.cyl(tx, ty, 0.8, 0.82, 1.25, "I_Leather", seg=16, r_top=1.2, cap=False)
        for k in range(5):
            a = math.pi * (0.15 + 0.7 * k / 4)
            chair(r, tx + math.cos(a) * 1.6, ty - math.sin(a) * 1.6, "N", mat="I_Leather")
        for k in range(4):  # chip stacks
            r.cyl(tx - 0.5 + k * 0.3, ty + 0.5, 0.82, 0.9 + k * 0.03, 0.06, rng.choice(["I_Red", "I_CarpetBlue", "I_Gold"]), seg=8)
        r.ceiling_lamp(tx, ty, h=5.0, mat="I_LampWarm", color="ffd9a0", rng=6, energy=1.5, size=0.8)
    # roulette
    rx, ry = 7.0, -3.5
    r.solid(rx - 1.8, ry - 0.8, 0, rx + 1.8, ry + 0.8, 0.8, "I_WoodDark")
    r.deco(rx - 1.75, ry - 0.75, 0.8, rx + 0.6, ry + 0.75, 0.82, "I_Green")
    r.cyl(rx + 1.1, ry, 0.8, 0.95, 0.55, "I_Wood", seg=16)
    r.cyl(rx + 1.1, ry, 0.95, 0.98, 0.42, "I_Red", seg=16)
    r.cyl(rx + 1.1, ry, 0.98, 1.1, 0.06, "I_Gold", seg=8)
    r.ceiling_lamp(rx, ry, h=5.0, mat="I_LampWarm", color="ffd9a0", rng=6, energy=1.5, size=0.8)
    # bar along the east wall
    counter(r, 10.0, -2.0, 11.0, 4.0, h=1.1, body="I_WoodDark", top="I_MarbleDark")
    shelf_unit(r, 11.4, -1.8, 11.95, 3.8, h=2.4, levels=4, mat="I_WoodDark",
               goods=["I_Glass", "I_Gold", "I_Green", "I_Brass"], rng=rng)
    for i in range(5):
        r.cyl(9.4, -1.4 + i * 1.2, 0, 0.75, 0.05, "I_Brass", seg=6)
        r.cyl(9.4, -1.4 + i * 1.2, 0.75, 0.82, 0.22, "I_Leather", seg=10, collide=True)
    r.deco(10.0, 4.0, 1.1, 11.0, -2.0, 1.12, "I_NeonPurple")
    # cashier cage on the north wall; the counting room door is behind it, reached through
    # the staff gap between the cage and the bar
    cx0, cx1 = 2.0, 9.0
    counter(r, cx0, 4.4, cx1, 5.0, h=1.1, body="I_WoodDark", top="I_Marble")
    for i in range(8):
        x = cx0 + 0.1 + i * (cx1 - cx0 - 0.2) / 7
        r.deco(x - 0.02, 4.68, 1.1, x + 0.02, 4.72, 3.0, "I_Brass")
    r.deco(cx0, 4.66, 2.95, cx1, 4.74, 3.05, "I_Brass")
    r.c.box(cx0, 4.4, 1.1, cx1, 5.0, 3.0, "Concrete")
    r.solid(cx0 - 0.2, 4.4, 0, cx0, y1, 3.0, "I_WoodDark")
    r.deco(4.5, 4.36, 2.0, 6.5, 4.4, 2.4, "I_NeonGreen")
    # counting room behind the north wall
    ky0, ky1 = y1 + T, 13.0
    r.shell(4.0, ky0, 12.0, ky1, h=3.2, wall="I_ConcreteDark", floor="I_Concrete", ceil="I_ConcreteDark",
            doors=[("S", 7.5, 1.2, 2.4)], skirting="I_SteelDark")
    r.door_leaf("W", 4.0 - T / 2, 10.0, w=1.0, mat="I_SteelDark", frame="I_Steel")
    for (tx, ty) in ((6.0, 9.2), (9.5, 9.2)):
        r.solid(tx - 1.2, ty - 0.6, 0, tx + 1.2, ty + 0.6, 0.85, "I_Steel")
        for k in range(10):
            bx = tx - 1.0 + (k % 5) * 0.4
            by = ty - 0.4 + (k // 5) * 0.4
            for z in range(rng.randint(1, 4)):
                r.deco(bx, by, 0.85 + z * 0.08, bx + 0.32, by + 0.16, 0.92 + z * 0.08, "I_Cash")
        r.deco(tx - 0.2, ty + 0.2, 0.85, tx + 0.3, ty + 0.55, 1.15, "I_SteelDark")   # money counter
        r.ceiling_lamp(tx, ty, h=3.2, mat="I_LampCool", color="e0ecff", rng=5, energy=1.2, size=0.9)
    for i in range(3):   # cash carts
        x = 5.0 + i * 1.0
        r.solid(x - 0.4, 11.7, 0, x + 0.4, 12.8, 1.0, "I_SteelDark")
        r.deco(x - 0.35, 11.75, 1.0, x + 0.35, 12.75, 1.2, "I_Cash")
    r.solid(10.6, 11.8, 0, 11.9, 12.9, 1.8, "I_SteelDark")       # safe
    r.deco(10.6, 11.78, 0.7, 11.2, 11.8, 1.3, "I_Steel")
    for i in range(4):   # security monitors
        r.deco(11.9, 9.0 + i * 0.6, 1.4, 11.95, 9.5 + i * 0.6, 1.85, "I_Screen")
    r.deco(11.5, 8.9, 0.0, 11.95, 11.4, 0.9, "I_SteelDark")
    r.deco(4.5, ky1 - 0.06, 2.6, 5.5, ky1 - 0.02, 2.8, "I_RedLight")
    # glitzy ceiling
    for x in range(-10, 11, 4):
        r.deco(x - 0.1, y0, 4.85, x + 0.1, y1, 4.95, "I_Brass")
    r.deco(-11.9, -7.9, 3.8, -11.85, 6.9, 3.9, "I_NeonPink")
    r.light(-2.0, 5.0, 3.5, "ffd090", 9, 1.5)
    r.light(5.0, -6.0, 3.5, "ffd090", 9, 1.5)
    r.mark("spawn", 0.0, -6.8, 0, 0)
    r.mark("exit", 0.0, y0 - 0.1, 0, 180)
    r.mark("slots", -8.0, -1.0, 0, 0)
    r.mark("tables", 0.5, -1.5, 0, 0)
    r.mark("roulette", 7.0, -2.2, 0, 180)
    r.mark("bar", 9.0, 1.0, 0, -90)
    r.mark("cage", 5.5, 3.6, 0, 0)
    r.mark("counting_room", 7.8, 10.6, 0, 0)
    r.mark("cash", 6.0, 10.1, 0, 180)
    r.mark("safe", 11.0, 11.2, 0, 0)
    r.mark("security", 11.0, 10.0, 0, -90)
    r.export()


def federal_reserve():
    """Marble hall with a guard desk and security gates, a long ramp down to the vault floor:
    a round vault door standing open onto cages of gold."""
    rng = random.Random(10)
    r = Room("federal_reserve")
    x0, x1, y0, y1 = -9.0, 9.0, -7.0, 3.0
    r.shell(x0, y0, x1, y1, h=7.0, wall="I_Marble", floor="I_Marble", ceil="I_White",
            doors=[("S", 0.0, 2.8, 3.6), ("N", 0.0, 3.0, 3.0)], skirting="I_MarbleDark")
    r.door_leaf("S", 0.0, y0 - T / 2, w=2.8, h=3.6, mat="I_Brass", frame="I_MarbleDark")
    for x in (-7.0, -3.5, 3.5, 7.0):
        r.cyl(x, -4.0, 0, 7.0, 0.5, "I_Marble", seg=16, collide=True)
        r.solid(x - 0.65, -4.65, 0, x + 0.65, -3.35, 0.35, "I_MarbleDark")
    r.deco(-1.6, y0, 0.0, 1.6, y1, 0.015, "I_CarpetBlue")
    # an eagle-ish seal on the back wall: gold disc
    r.v.cyl(0, y1 - 0.02, 4.2, 4.2, 1.2, "I_Gold", seg=20)
    for i in range(20):
        a0, a1 = math.tau * i / 20, math.tau * (i + 1) / 20
        c = Vector((0, y1 - 0.05, 5.2))
        p0 = c + Vector((math.cos(a0) * 1.2, 0, math.sin(a0) * 1.2))
        p1 = c + Vector((math.cos(a1) * 1.2, 0, math.sin(a1) * 1.2))
        r.v.face([c, p1, p0], "I_Gold", (0, -1, 0))
    # guard desk and turnstile gates
    counter(r, -5.5, -1.6, -2.0, -0.8, h=1.1, body="I_MarbleDark", top="I_Marble")
    r.deco(-4.2, -1.3, 1.1, -3.6, -1.0, 1.45, "I_Screen")
    for x in (-1.6, -0.5, 0.6, 1.7):
        r.solid(x - 0.08, -0.4, 0, x + 0.08, 0.6, 1.0, "I_Steel")
    r.deco(-1.6, -0.35, 0.95, 1.7, -0.3, 1.0, "I_RedLight")
    for x in (-8.0, 8.0):
        plant(r, x, -6.2, rng, 1.4)
    for x in (-5.0, 0.0, 5.0):
        r.cyl(x, -2.0, 6.2, 7.0, 0.03, "I_Brass", seg=4)
        r.cyl(x, -2.0, 5.6, 6.2, 0.7, "I_LampWarm", seg=14, r_top=0.2)
        r.light(x, -2.0, 5.0, "ffe0b0", 11, 2.4)
    # ramp corridor down to the vault level (z = -4)
    cx0, cx1 = -1.5, 1.5
    ry0, ry1 = y1 + T, 13.0
    zv = -4.0
    r.solid(cx0 - T, ry0, zv, cx0, ry1, 3.0, "I_Concrete")
    r.solid(cx1, ry0, zv, cx1 + T, ry1, 3.0, "I_Concrete")
    r.solid(cx0 - T, ry0, 3.0, cx1 + T, ry1, 3.3, "I_ConcreteDark")
    steps = 16
    for i in range(steps):
        y = ry0 + i * (ry1 - ry0) / steps
        z = -(i + 1) * (-zv) / steps
        r.solid(cx0, y, z - 0.25, cx1, y + (ry1 - ry0) / steps, z, "I_ConcreteDark")
    for i in range(3):
        r.ceiling_lamp(0.0, ry0 + 2 + i * 3.5, h=3.0, mat="I_LampCool", color="e0ecff", rng=5, energy=1.0, size=0.6)
    # vault level
    vx0, vx1, vy0, vy1 = -7.0, 7.0, ry1, 24.0
    r.shell(vx0, vy0, vx1, vy1, h=4.0, z=zv, wall="I_SteelDark", floor="I_Concrete", ceil="I_ConcreteDark",
            doors=[("S", 0.0, 3.0, 3.0)], skirting="I_Steel")
    # the round vault door, swung open to the west
    dx, dy, dz = -2.2, vy0 + 1.2, zv + 1.6
    seg = 20
    for i in range(seg):
        a0, a1 = math.tau * i / seg, math.tau * (i + 1) / seg
        p0 = Vector((dx, dy + 1.5 * math.cos(a0), dz + 1.5 * math.sin(a0)))
        p1 = Vector((dx, dy + 1.5 * math.cos(a1), dz + 1.5 * math.sin(a1)))
        c = Vector((dx, dy, dz))
        r.v.face([c, p0, p1], "I_Steel", (1, 0, 0))
        r.v.face([c + Vector((-0.6, 0, 0)), p1 + Vector((-0.6, 0, 0)), p0 + Vector((-0.6, 0, 0))], "I_Steel", (-1, 0, 0))
        r.v.face([p0, p1, p1 + Vector((-0.6, 0, 0)), p0 + Vector((-0.6, 0, 0))], "I_SteelDark", ((p0 + p1) / 2 - c))
    for k in range(4):
        a = k * math.pi / 4
        d = Vector((0, math.cos(a), math.sin(a)))
        r.v.obox(Vector((dx + 0.02, dy, dz)) - d * 1.0 - Vector((0, 0, 0.05)), d * 2.0, Vector((0.14, 0, 0)),
                 Vector((0, 0, 0.1)), "I_Brass")
    r.c.box(dx - 0.6, dy - 1.5, zv, dx, dy + 1.5, zv + 3.2, "Concrete")
    # gold cages: rows of shelves stacked with bars behind mesh
    for row, y in enumerate((17.0, 20.0)):
        for side in (-1, 1):
            xa, xb = (1.2, 6.6) if side > 0 else (-6.6, -1.2)
            r.solid(xa, y - 0.5, zv, xb, y + 0.5, zv + 0.1, "I_SteelDark")
            for lvl in range(3):
                z = zv + 0.1 + lvl * 0.7
                r.deco(xa, y - 0.5, z + 0.6, xb, y + 0.5, z + 0.64, "I_Steel")
                n = int((xb - xa) / 0.3)
                for i in range(n):
                    bx = xa + 0.05 + i * 0.3
                    for j in range(2):
                        r.deco(bx, y - 0.4 + j * 0.42, z, bx + 0.25, y - 0.05 + j * 0.42, z + 0.1, "I_Gold")
                        if rng.random() < 0.7:
                            r.deco(bx + 0.02, y - 0.38 + j * 0.42, z + 0.1, bx + 0.23, y - 0.07 + j * 0.42, z + 0.18, "I_Gold")
            r.c.box(xa, y - 0.5, zv, xb, y + 0.5, zv + 2.2, "Concrete")
            # cage mesh in front
            for i in range(int((xb - xa) / 0.4) + 1):
                x = xa + i * 0.4
                r.deco(x - 0.015, y - 0.62, zv, x + 0.015, y - 0.58, zv + 2.4, "I_Steel")
    # pallet of cash and a cart in the middle
    for (px, py) in ((-0.8, 22.5), (0.8, 22.5)):
        r.solid(px - 0.6, py - 0.5, zv, px + 0.6, py + 0.5, zv + 0.15, "I_Wood")
        r.solid(px - 0.55, py - 0.45, zv + 0.15, px + 0.55, py + 0.45, zv + 1.0, "I_Cash")
    for (x, y) in ((-4.0, 23.0), (4.0, 23.0), (0.0, 18.5)):
        r.ceiling_lamp(x, y, h=zv + 4.0, mat="I_LampCool", color="d8e8ff", rng=8, energy=1.6, size=1.4)
    r.deco(-0.5, vy1 - 0.06, zv + 3.2, 0.5, vy1 - 0.02, zv + 3.5, "I_RedLight")
    r.mark("spawn", 0.0, -5.8, 0, 0)
    r.mark("exit", 0.0, y0 - 0.1, 0, 180)
    r.mark("desk", -3.8, -2.2, 0, 0)
    r.mark("gate", 0.0, -0.9, 0, 0)
    r.mark("vault_door", 0.0, vy0 + 1.0, zv, 0)
    r.mark("vault", 0.0, 20.5, zv, 0)
    r.mark("gold", 4.0, 18.5, zv, 0)
    r.mark("alarm", 8.8, -1.0, 2.4, -90)
    r.deco(8.75, -1.3, 2.2, 8.95, -0.7, 2.6, "I_RedLight")
    r.export()


JOBS = {"home": home, "bank": bank, "bunker": bunker, "shop_gas": lambda: shop("gas"),
        "shop_pawn": lambda: shop("pawn"), "shop_diner": lambda: shop("diner"),
        "nightclub": nightclub, "police": police, "shop_clothes": shop_clothes, "casino": casino,
        "federal_reserve": federal_reserve}


def main():
    only = set(sys.argv[sys.argv.index("--") + 1:]) if "--" in sys.argv else None
    for nm, fn in JOBS.items():
        if only and nm not in only:
            continue
        setup_materials()
        fn()


if __name__ == "__main__":
    main()
