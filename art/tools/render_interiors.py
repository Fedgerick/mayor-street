"""Cutaway previews of the interiors (interiors/models/*.glb), so rooms can be judged
without Godot. The ceiling and the top of the walls are sliced off, L_ markers become
point lights the way interiors/interior.gd turns them into OmniLights.

    /opt/bpyenv/bin/python art/tools/render_interiors.py            # every room + sheet
    /opt/bpyenv/bin/python art/tools/render_interiors.py -- bank    # one room

Images land in art/previews/interiors_<id>.jpg and art/previews/interiors_sheet.jpg.
"""
import math
import os
import sys

import bpy
import bmesh  # after bpy: the pip module only provides it once bpy is loaded
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render_previews as R  # noqa: E402

MODELS = os.path.join(R.GAME, "interiors", "models")
ROOMS = ["home", "bank", "bunker", "shop_gas", "shop_pawn", "shop_diner", "nightclub", "police",
         "shop_clothes", "casino", "federal_reserve"]
CUT = {"bunker": -0.3, "federal_reserve": -0.3}   # rooms a floor down: slice above them
DEFAULT_CUT = 2.3


def cutaway(ob, z):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, z), plane_no=(0, 0, 1), clear_outer=True)
    bm.to_mesh(ob.data)
    bm.free()


def room(rid, res=(1400, 1000)):
    R.reset()
    R.setup_render(res, samples=64)
    sc = bpy.context.scene
    sc.view_settings.exposure = float(os.environ.get("PREVIEW_EXPOSURE", "0.0"))
    w = bpy.data.worlds.new("World")
    sc.world = w
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.06, 0.065, 0.075, 1)
    w.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    bpy.ops.import_scene.gltf(filepath=os.path.join(MODELS, rid + ".glb"))
    vis = None
    for ob in list(sc.objects):
        if ob.name.endswith("-colonly"):
            bpy.data.objects.remove(ob, do_unlink=True)
        elif ob.type == "MESH":
            vis = ob
    cutaway(vis, CUT.get(rid, DEFAULT_CUT))
    for ob in list(sc.objects):
        if ob.type == "EMPTY" and ob.name.startswith("L_"):
            p = ob.name.split("_")
            col = tuple(int(p[1][i:i + 2], 16) / 255 for i in (0, 2, 4))
            li = bpy.data.lights.new(ob.name, "POINT")
            li.color = col
            li.energy = float(p[3]) / 10 * float(p[2]) * 25
            li.shadow_soft_size = 0.3
            lo = bpy.data.objects.new(ob.name + "_light", li)
            lo.location = ob.matrix_world.translation
            sc.collection.objects.link(lo)
    # soft fill from above, standing in for the game's ambient light
    fill = bpy.data.lights.new("Fill", "AREA")
    fill.energy = 900
    fill.size = 20
    fo = bpy.data.objects.new("Fill", fill)
    fo.location = vis.matrix_world @ Vector((0, 0, 0)) + Vector((0, 0, 14))
    sc.collection.objects.link(fo)
    R.frame(vis, res, yaw=-30.0, pitch=52.0, lens=40, pad=0.85)
    out = "interiors_" + rid
    sc.render.filepath = os.path.join(R.OUT, out + ".jpg")
    bpy.ops.render.render(write_still=True)
    print("wrote", out)
    return os.path.join(R.OUT, out + ".jpg")


def sheet(paths, cols=4, cell=(700, 500)):
    from PIL import Image, ImageDraw
    rows = (len(paths) + cols - 1) // cols
    out = Image.new("RGB", (cols * cell[0], rows * cell[1]), (20, 22, 26))
    for i, (rid, p) in enumerate(paths):
        im = Image.open(p).convert("RGB").resize(cell)
        d = ImageDraw.Draw(im)
        d.rectangle((0, cell[1] - 30, cell[0], cell[1]), fill=(20, 22, 26))
        d.text((10, cell[1] - 24), rid, fill=(235, 235, 235))
        out.paste(im, ((i % cols) * cell[0], (i // cols) * cell[1]))
    out.save(os.path.join(R.OUT, "interiors_sheet.jpg"), quality=85)
    print("wrote interiors_sheet")


if __name__ == "__main__":
    want = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ROOMS
    done = [(r, room(r)) for r in want]
    if len(done) > 1:
        sheet(done)
