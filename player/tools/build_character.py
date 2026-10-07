"""Build the street people: one rig, a wardrobe of parts, and the animation set, as glTF.

Run headless (needs the `bpy` pip module, Blender 4.2):
    python3 player/tools/build_character.py
Writes player/assets/character.glb.

Everything is sculpted from metaballs (soft, chunky shapes in the spirit of the city kit),
then decimated to a triangle budget. The file holds one armature and many mesh parts,
each skinned to it, which CharacterModel (player/scripts/character_model.gd) merges into
one mesh per outfit:

    Head_skin       face with eyes, lids, nose, ears and a mouth on a jaw bone
    Brows, Hands    hands have four fingers and a thumb on finger bones
    Hair_<style>    short, buzz, long, ponytail, bun, mohawk, afro   (bald: none)
    Face_<style>    stubble, mustache, beard, glasses, shades          (clean: none)
    Top_<style>     tee, longsleeve, hoodie, jacket, tank   (arms included)
    Bottom_<style>  jeans, shorts, skirt                    (legs included)
    Shoes_<style>   sneakers, boots
    Hat_<style>     cap, beanie

Every part also comes as <name>_lod1, about a seventh of the triangles, for the crowd.
A full outfit is about 10k triangles at LOD0 and 1.5k at LOD1.

Materials are named slots the game recolours: Skin, Shirt, Jacket, Pants, Shoes, Hair,
Brows, Eyes, EyeWhite, Hat, Stubble.

Animations: Idle, IdleLook, IdleArms, Walk, Run, Jump, Fall, Sit, SitBench, EnterCar,
ExitCar, Talk, Phone, Wave, Punch, Jab, Hook, AimPistol, AimShotgun, ReloadPistol,
ReloadShotgun, Hit, Stumble, FallBack, GetUp, Die, Carjack.

Conventions: the character faces -Y in Blender (glTF/Godot -Z), Z up, feet at Z = 0.
Poses are written as rotations in a world-aligned frame per bone and composed down the
hierarchy (child = parent @ delta), which keeps the animation code readable. A pose can
also aim a limb straight at a direction with Dir(...).
"""
import math
import os

import bpy  # noqa: E402  (bpy must load before mathutils users)
from mathutils import Quaternion, Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("CHARACTER_OUT") or os.path.normpath(os.path.join(HERE, "..", "assets", "character.glb"))
VIS = 0.574  # visible radius of a stiffness-2 metaball per unit of influence radius
FPS = 30
LOD1 = 0.15  # LOD1 keeps about this share of the triangles

# ------------------------------------------------------------------ landmarks ---
# A-pose. x: character's left is +X. Front is -Y.
HIP_Z = 0.93
LEG_X = 0.115
KNEE_Z = 0.51
ANKLE_Z = 0.1
SHOULDER = Vector((0.205, 0.0, 1.405))
ARM_A = math.radians(42.0)  # arm angle from vertical at rest
ARM_DIR = Vector((math.sin(ARM_A), 0.0, -math.cos(ARM_A)))
UPPER_ARM = 0.29
FOREARM = 0.26
HAND = 0.11
FRONT = Vector((0, -1, 0))
KNUCKLE = 0.088  # wrist to knuckles along the hand


def arm_axes(sx):
    """Hand direction d (wrist to fingertips) and palm normal n (toward the body)."""
    d = Vector((ARM_DIR.x * sx, 0, ARM_DIR.z))
    n = Vector((-math.cos(ARM_A) * sx, 0, -math.sin(ARM_A)))
    return d, n


def arm_points(sx):
    d, _ = arm_axes(sx)
    sh = Vector((SHOULDER.x * sx, SHOULDER.y, SHOULDER.z))
    el = sh + d * UPPER_ARM
    wr = el + d * FOREARM
    return sh, el, wr


def thumb_line(sx):
    d, n = arm_axes(sx)
    wr = arm_points(sx)[2]
    a = wr + d * 0.022 + FRONT * 0.026 + n * 0.01
    u = (d * 0.7 + FRONT * 0.6 + n * 0.35).normalized()
    return a, u


def leg_points(sx):
    hip = Vector((LEG_X * sx, 0, HIP_Z))
    knee = Vector((LEG_X * sx, -0.01, KNEE_Z))
    ankle = Vector((LEG_X * sx, 0.0, ANKLE_Z))
    return hip, knee, ankle


BONES = {
    # name: (head, tail, parent, connected)
    "Hips": (Vector((0, 0, 0.9)), Vector((0, 0, 1.06)), None, False),
    "Spine": (Vector((0, 0, 1.06)), Vector((0, 0, 1.22)), "Hips", True),
    "Chest": (Vector((0, 0, 1.22)), Vector((0, 0, 1.43)), "Spine", True),
    "Neck": (Vector((0, 0, 1.43)), Vector((0, 0, 1.53)), "Chest", True),
    "Head": (Vector((0, 0, 1.53)), Vector((0, 0, 1.86)), "Neck", True),
    "Jaw": (Vector((0, -0.015, 1.625)), Vector((0, -0.11, 1.555)), "Head", False),
}
for s, sx in (("L", 1), ("R", -1)):
    d, n = arm_axes(sx)
    sh, el, wr = arm_points(sx)
    BONES["UpperArm." + s] = (sh, el, "Chest", False)
    BONES["LowerArm." + s] = (el, wr, "UpperArm." + s, True)
    BONES["Hand." + s] = (wr, wr + d * HAND, "LowerArm." + s, True)
    kn = wr + d * KNUCKLE
    BONES["Fingers1." + s] = (kn, kn + d * 0.04, "Hand." + s, False)
    BONES["Fingers2." + s] = (kn + d * 0.04, kn + d * 0.078, "Fingers1." + s, True)
    ta, tu = thumb_line(sx)
    BONES["Thumb." + s] = (ta, ta + tu * 0.035, "Hand." + s, False)
    hip, knee, ankle = leg_points(sx)
    BONES["UpperLeg." + s] = (hip, knee, "Hips", False)
    BONES["LowerLeg." + s] = (knee, ankle, "UpperLeg." + s, True)
    BONES["Foot." + s] = (ankle, Vector((LEG_X * sx, -0.15, 0.03)), "LowerLeg." + s, True)

ORDER = ["Hips", "Spine", "Chest", "Neck", "Head", "Jaw",
         "UpperArm.L", "LowerArm.L", "Hand.L", "Fingers1.L", "Fingers2.L", "Thumb.L",
         "UpperArm.R", "LowerArm.R", "Hand.R", "Fingers1.R", "Fingers2.R", "Thumb.R",
         "UpperLeg.L", "LowerLeg.L", "Foot.L", "UpperLeg.R", "LowerLeg.R", "Foot.R"]
DETAIL_BONES = {"Jaw", "Fingers1.L", "Fingers2.L", "Thumb.L", "Fingers1.R", "Fingers2.R", "Thumb.R"}


# --------------------------------------------------------------------- helpers ---

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS


def material(name, color, rough=0.7):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    return m


_blob_n = [0]
RES_SCALE = [1.0]   # coarser metaballs when a part is rebuilt for its LOD


class Blob:
    """One metaball object = one separate mesh island with one material.
    Metaball objects whose names share a stem melt together, so each gets a unique stem."""

    def __init__(self, res=0.012):
        _blob_n[0] += 1
        stem = "".join(chr(97 + int(c)) for c in str(_blob_n[0]))  # letters only
        self.mb = bpy.data.metaballs.new("mb" + stem)
        self.mb.resolution = res * RES_SCALE[0]
        self.mb.render_resolution = res * RES_SCALE[0]
        self.ob = bpy.data.objects.new("mb" + stem, self.mb)
        bpy.context.scene.collection.objects.link(self.ob)

    def ball(self, p, r, sc=(1, 1, 1)):
        e = self.mb.elements.new(type="ELLIPSOID")
        e.co = p
        e.radius = r / VIS
        e.size_x, e.size_y, e.size_z = sc
        return e

    def capsule(self, a, b, r):
        a, b = Vector(a), Vector(b)
        e = self.mb.elements.new(type="CAPSULE")
        e.co = (a + b) / 2
        e.radius = r / VIS
        e.size_x = max((b - a).length / 2, 1e-4)
        e.rotation = Vector((1, 0, 0)).rotation_difference((b - a).normalized())
        return e

    def mesh(self, mat):
        dg = bpy.context.evaluated_depsgraph_get()
        me = bpy.data.meshes.new_from_object(self.ob.evaluated_get(dg))
        ob = bpy.data.objects.new("piece", me)
        bpy.context.scene.collection.objects.link(ob)
        me.materials.append(mat)
        bpy.data.objects.remove(self.ob)
        return ob


def sphere(loc, r, sc, mat, seg=12, rings=7):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=seg, ring_count=rings, radius=r, location=loc)
    ob = bpy.context.active_object
    ob.scale = sc
    ob.data.materials.append(mat)
    return ob


def ring(loc, major, minor, mat, rot=(math.pi / 2, 0, 0)):
    bpy.ops.mesh.primitive_torus_add(major_segments=14, minor_segments=4, major_radius=major,
                                     minor_radius=minor, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.data.materials.append(mat)
    return ob


def rod(a, b, r, mat, verts=5):
    a, b = Vector(a), Vector(b)
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=(b - a).length,
                                        location=(a + b) / 2)
    ob = bpy.context.active_object
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference((b - a).normalized())
    ob.data.materials.append(mat)
    return ob


def tris(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def select_only(obs, active):
    bpy.ops.object.select_all(action="DESELECT")
    for o in obs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active


def join(obs, name):
    select_only(obs, obs[0])
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if len(obs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.active_object
    ob.name = name
    ob.data.name = name
    return ob


def decimate(ob, target):
    select_only([ob], ob)
    for _ in range(3):   # the collapse sometimes stops short; go again
        n = tris(ob)
        if n <= target * 1.1:
            break
        dec = ob.modifiers.new("Decimate", "DECIMATE")
        dec.ratio = target / n
        dec.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier="Decimate")


def finish(ob, target):
    select_only([ob], ob)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=0.0015)
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    decimate(ob, target)
    bpy.ops.object.shade_smooth()
    return ob


def lerp(a, b, t):
    return a + (b - a) * t


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (a + ab * t - p).length


# --------------------------------------------------------------------- wardrobe ---
# Each builder returns a list of mesh pieces (any materials); build_wardrobe() joins,
# decimates, weights and makes the LOD.

def torso(b, k=0.0, shoulders=True, narrow=1.0):
    b.ball((0, 0.0, 1.31), 0.165 + k, (1.24 * narrow, 0.8, 0.95))     # chest
    b.ball((0, -0.03, 1.285), 0.11 + k, (1.3 * narrow, 0.75, 0.8))     # front of the chest
    b.ball((0, 0.012, 1.15), 0.15 + k, (1.06, 0.78, 1.0))              # waist
    b.ball((0, 0.0, 1.02), 0.148 + k, (1.13, 0.8, 0.75))               # hem
    if shoulders:
        b.capsule((-0.17, 0.005, 1.385), (0.17, 0.005, 1.385), 0.08 + k)


def bare_forearm(b, sx, start=0.0):
    sh, el, wr = arm_points(sx)
    if start < 1.0:
        b.capsule(lerp(sh, el, start), el, 0.05)
    b.capsule(el, wr, 0.044)
    b.ball(lerp(el, wr, 0.28), 0.05)


def sleeve(b, sx, upto, r0=0.07, r1=0.06, cuff=0.06):
    """Shoulder cap and a sleeve down the arm; upto <= 1 ends on the upper arm,
    above 1 continues down the forearm (2 = the wrist)."""
    sh, el, wr = arm_points(sx)
    b.ball(sh, r0 + 0.016)
    if upto <= 1.0:
        end = lerp(sh, el, upto)
        b.capsule(sh, end, r0)
        b.ball(end, r0 + 0.004)
    else:
        b.capsule(sh, el, r0)
        end = lerp(el, wr, upto - 1.0)
        b.capsule(el, end, r1)
        b.ball(end, cuff)


def top_tee(m):
    sh_ = Blob()
    torso(sh_)
    sk = Blob()
    for sx in (1, -1):
        sleeve(sh_, sx, 0.48, r0=0.072)
        bare_forearm(sk, sx, 0.35)
    return [sh_.mesh(m["Shirt"]), sk.mesh(m["Skin"])]


def top_longsleeve(m):
    sh_ = Blob()
    torso(sh_)
    sk = Blob()
    for sx in (1, -1):
        sleeve(sh_, sx, 1.9, r0=0.069, r1=0.057, cuff=0.058)
        _, el, wr = arm_points(sx)
        sk.capsule(lerp(el, wr, 0.8), wr, 0.042)
    return [sh_.mesh(m["Shirt"]), sk.mesh(m["Skin"])]


def top_hoodie(m):
    h = Blob()
    torso(h, 0.016)
    h.ball((0, 0.0, 0.95), 0.152, (1.12, 0.82, 0.35))                   # waistband
    h.ball((0, -0.12, 1.06), 0.085, (1.35, 0.4, 0.62))                  # front pocket
    for i in range(9):                                                  # hood, bunched behind the neck
        a = math.radians(-112 + i * 28)
        h.ball((math.sin(a) * 0.1, math.cos(a) * 0.1 + 0.025, 1.455), 0.05, (1, 1, 0.85))
    h.ball((0, 0.13, 1.42), 0.07, (1.35, 0.7, 0.9))
    sk = Blob()
    for sx in (1, -1):
        sleeve(h, sx, 1.86, r0=0.077, r1=0.064, cuff=0.062)
        _, el, wr = arm_points(sx)
        sk.capsule(lerp(el, wr, 0.8), wr, 0.042)
    return [h.mesh(m["Shirt"]), sk.mesh(m["Skin"])]


def top_jacket(m):
    inner = Blob()
    torso(inner)
    out = [inner.mesh(m["Shirt"])]
    for sx in (1, -1):
        j = Blob()   # each half is its own shell, so the front stays open
        j.ball((0.07 * sx, 0.006, 1.31), 0.163, (1.08, 0.84, 0.97))
        j.ball((0.07 * sx, 0.012, 1.15), 0.152, (0.98, 0.82, 1.0))
        j.ball((0.07 * sx, 0.004, 1.0), 0.15, (1.02, 0.84, 0.85))
        j.capsule((0.0, 0.006, 1.388), (0.175 * sx, 0.006, 1.388), 0.088)
        j.capsule((0.0, 0.075, 1.455), (0.085 * sx, 0.035, 1.45), 0.032)          # collar
        j.ball((0.075 * sx, -0.112, 1.355), 0.05, (0.7, 0.32, 1.25))            # lapel
        sleeve(j, sx, 1.88, r0=0.078, r1=0.066, cuff=0.064)
        out.append(j.mesh(m["Jacket"]))
    sk = Blob()
    for sx in (1, -1):
        _, el, wr = arm_points(sx)
        sk.capsule(lerp(el, wr, 0.8), wr, 0.042)
    out.append(sk.mesh(m["Skin"]))
    return out


def top_tank(m):
    t = Blob()
    torso(t, shoulders=False, narrow=0.9)
    for sx in (1, -1):
        t.capsule((0.1 * sx, -0.075, 1.36), (0.115 * sx, 0.0, 1.455), 0.022)
        t.capsule((0.115 * sx, 0.0, 1.455), (0.1 * sx, 0.075, 1.36), 0.022)
    sk = Blob()
    sk.ball((0, 0.0, 1.355), 0.14, (1.2, 0.72, 0.62))                   # upper chest and back
    sk.capsule((-0.16, 0.005, 1.385), (0.16, 0.005, 1.385), 0.07)
    for sx in (1, -1):
        sh, el, _ = arm_points(sx)
        sk.ball(sh, 0.078)
        bare_forearm(sk, sx, 0.0)
    return [t.mesh(m["Shirt"]), sk.mesh(m["Skin"])]


def pelvis(b, k=0.0):
    b.ball((0, 0.0, 0.95), 0.15 + k, (1.12, 0.8, 0.72))
    for sx in (1, -1):
        b.ball((0.06 * sx, 0.035, 0.885), 0.09 + k)


def bare_leg(b, sx, start=0.0):
    hip, knee, ankle = leg_points(sx)
    b.capsule(lerp(hip, knee, start), knee, 0.072)
    b.capsule(knee, ankle + Vector((0, 0, 0.03)), 0.058)
    b.ball(lerp(knee, ankle, 0.3) + Vector((0, 0.012, 0)), 0.064)


def bottom_jeans(m):
    p = Blob()
    pelvis(p)
    for sx in (1, -1):
        hip, knee, ankle = leg_points(sx)
        p.capsule(hip + Vector((0, 0, 0.02)), knee, 0.086)
        p.ball(lerp(hip, knee, 0.25), 0.094)
        p.capsule(knee, ankle + Vector((0, 0, 0.05)), 0.071)
        p.ball(ankle + Vector((0, 0, 0.06)), 0.073, (1, 1, 0.55))
    return [p.mesh(m["Pants"])]


def bottom_shorts(m):
    p = Blob()
    pelvis(p)
    sk = Blob()
    for sx in (1, -1):
        hip, knee, _ = leg_points(sx)
        end = lerp(hip, knee, 0.62)
        p.capsule(hip + Vector((0, 0, 0.02)), end, 0.082)
        p.ball(end, 0.084, (1, 1, 0.55))
        bare_leg(sk, sx, 0.5)
    return [p.mesh(m["Pants"]), sk.mesh(m["Skin"])]


def bottom_skirt(m):
    p = Blob()
    pelvis(p)
    p.ball((0, 0.0, 0.86), 0.163, (1.15, 0.85, 0.7))
    p.ball((0, 0.005, 0.77), 0.172, (1.18, 0.9, 0.5))
    p.ball((0, 0.005, 0.69), 0.182, (1.2, 0.92, 0.32))
    sk = Blob()
    for sx in (1, -1):
        bare_leg(sk, sx, 0.0)
    return [p.mesh(m["Pants"]), sk.mesh(m["Skin"])]


def shoe(b, sx, boot=False):
    x = LEG_X * sx
    b.capsule((x, 0.035, 0.056), (x, -0.112, 0.05), 0.054)
    b.ball((x, 0.0, 0.1), 0.058)
    b.ball((x, -0.04, 0.024), 0.03, (2.15, 3.4, 0.82))                  # sole
    if boot:
        b.capsule((x, 0.0, 0.08), (x, 0.004, 0.2), 0.066)
        b.ball((x, 0.004, 0.205), 0.069, (1, 1, 0.45))


def shoes_sneakers(m):
    b = Blob()
    for sx in (1, -1):
        shoe(b, sx)
    return [b.mesh(m["Shoes"])]


def shoes_boots(m):
    b = Blob()
    for sx in (1, -1):
        shoe(b, sx, boot=True)
    return [b.mesh(m["Shoes"])]


def head(m):
    h = Blob(0.0065)
    h.capsule((0, 0.008, 1.395), (0, 0.0, 1.56), 0.058)                 # neck
    h.ball((0, 0.0, 1.665), 0.152, (0.93, 1.0, 1.08))                   # skull
    h.ball((0, -0.03, 1.6), 0.11, (0.98, 0.95, 0.88))                   # jaw and cheeks
    h.ball((0, -0.095, 1.548), 0.04, (1.15, 0.9, 0.8))                  # chin
    h.capsule((-0.07, -0.116, 1.716), (0.07, -0.116, 1.716), 0.013)    # brow ridge
    h.capsule((0, -0.14, 1.69), (0, -0.166, 1.632), 0.014)              # nose
    h.ball((0, -0.166, 1.628), 0.017)
    h.capsule((-0.023, -0.142, 1.597), (0.023, -0.142, 1.597), 0.01)    # upper lip
    for sx in (-1, 1):
        h.ball((0.016 * sx, -0.157, 1.622), 0.012)                      # nostrils
        h.ball((0.062 * sx, -0.094, 1.602), 0.04)                       # cheeks
        h.ball((0.146 * sx, 0.005, 1.66), 0.036, (0.42, 0.85, 1.25))    # ears
        h.ball((0.053 * sx, -0.127, 1.693), 0.022, (1.1, 0.7, 0.42))    # upper lids
    out = [h.mesh(m["Skin"])]
    for sx in (-1, 1):
        out.append(sphere((0.053 * sx, -0.14, 1.673), 0.027, (1.0, 0.62, 0.9), m["EyeWhite"]))
        out.append(sphere((0.053 * sx, -0.1575, 1.672), 0.0148, (1.0, 0.4, 1.15), m["Eyes"], 10, 6))
    out.append(sphere((0, -0.155, 1.585), 0.027, (1.0, 0.3, 0.2), m["Eyes"], 12, 5))      # mouth
    return out


def brows(m):
    b = Blob(0.0035)
    for sx in (-1, 1):
        b.capsule((0.02 * sx, -0.149, 1.722), (0.05 * sx, -0.147, 1.731), 0.0075)
        b.capsule((0.05 * sx, -0.147, 1.731), (0.083 * sx, -0.133, 1.722), 0.0068)
    return [b.mesh(m["Brows"])]


# (offset toward the front, length, radius, knuckle distance) per finger, index first.
FINGERS = [(0.029, 0.072, 0.0098, KNUCKLE), (0.0095, 0.08, 0.0102, KNUCKLE + 0.003),
           (-0.0095, 0.075, 0.0097, KNUCKLE), (-0.027, 0.06, 0.0087, KNUCKLE - 0.006)]


def hand_shape(b, sx, mitten=False):
    d, n = arm_axes(sx)
    wr = arm_points(sx)[2]
    if mitten:
        b.capsule(wr + d * 0.02, wr + d * 0.13, 0.03)
    else:
        b.capsule(wr + d * 0.012 + FRONT * 0.012, wr + d * 0.07 + FRONT * 0.012, 0.025)
        b.capsule(wr + d * 0.012 - FRONT * 0.014, wr + d * 0.07 - FRONT * 0.014, 0.024)
        for off, ln, r, kd in FINGERS:
            k = wr + d * kd + FRONT * off
            b.capsule(k, k + d * ln, r)
    ta, tu = thumb_line(sx)
    b.capsule(ta - tu * 0.012, ta + tu * 0.058, 0.0115 if not mitten else 0.014)


def hands(m):
    out = []
    for sx in (1, -1):
        b = Blob(0.0042)
        hand_shape(b, sx)
        out.append(b.mesh(m["Skin"]))
    return out


def hands_mitten(m):
    out = []
    for sx in (1, -1):
        b = Blob(0.02)
        hand_shape(b, sx, mitten=True)
        out.append(b.mesh(m["Skin"]))
    return out


def hair_cap(b, k=0.0, top=1.0):
    b.ball((0, 0.03, 1.725), 0.165 + k, (1.0, 1.04, 0.82 * top))
    b.ball((0, 0.06, 1.66), 0.15 + k, (0.98, 0.93, 0.95))
    for sx in (-1, 1):
        b.ball((0.112 * sx, 0.012, 1.712), 0.06 + k, (0.7, 1.15, 1.0))


def hair_short(m):
    b = Blob(0.008)
    hair_cap(b)
    for p in [(0, -0.095, 1.8), (-0.06, -0.085, 1.79), (0.062, -0.08, 1.795), (0.03, -0.035, 1.852),
              (-0.042, 0.0, 1.855), (0.075, 0.03, 1.83), (-0.085, 0.04, 1.82), (0.0, 0.08, 1.83)]:
        b.ball(p, 0.045)
    b.ball((0.02, -0.118, 1.772), 0.048, (1.45, 0.62, 0.55))             # fringe
    return [b.mesh(m["Hair"])]


def hair_buzz(m):
    b = Blob(0.008)
    b.ball((0, 0.025, 1.705), 0.158, (0.96, 1.02, 0.82))
    b.ball((0, 0.045, 1.655), 0.15, (0.97, 0.95, 0.96))
    return [b.mesh(m["Hair"])]


def hair_long(m):
    b = Blob(0.008)
    hair_cap(b, 0.004)
    for x in (-0.085, 0.0, 0.085):
        b.capsule((x, 0.075, 1.69), (x * 1.12, 0.09, 1.46), 0.066)
    for sx in (-1, 1):
        b.capsule((0.128 * sx, -0.005, 1.71), (0.138 * sx, 0.02, 1.48), 0.045)
    b.ball((-0.04, -0.112, 1.775), 0.05, (1.35, 0.6, 0.52))               # side-swept fringe
    return [b.mesh(m["Hair"])]


def hair_ponytail(m):
    b = Blob(0.008)
    hair_cap(b, -0.004, 0.95)
    b.ball((0, 0.155, 1.715), 0.032)                                     # tie
    b.capsule((0, 0.18, 1.715), (0, 0.215, 1.6), 0.042)
    b.ball((0, 0.22, 1.555), 0.036)
    return [b.mesh(m["Hair"])]


def hair_bun(m):
    b = Blob(0.008)
    hair_cap(b, -0.004, 0.95)
    b.ball((0, 0.07, 1.865), 0.064)
    return [b.mesh(m["Hair"])]


def hair_mohawk(m):
    b = Blob(0.008)
    b.ball((0, 0.025, 1.7), 0.155, (0.95, 1.01, 0.8))                    # shaved sides
    b.ball((0, 0.045, 1.655), 0.148, (0.96, 0.94, 0.95))
    c = Blob(0.008)
    for i in range(8):
        a = math.radians(-58 + i * 18)
        c.ball((0, math.sin(a) * 0.17 + 0.03, 1.69 + math.cos(a) * 0.19), 0.036, (0.55, 1.0, 1.35))
    return [b.mesh(m["Hair"]), c.mesh(m["Hair"])]


def hair_afro(m):
    b = Blob(0.01)
    b.ball((0, 0.07, 1.8), 0.2, (1.05, 1.0, 0.95))
    for i in range(10):
        a = i * 2.39996
        z = 1.72 + (i % 4) * 0.045
        b.ball((math.cos(a) * 0.17, 0.08 + math.sin(a) * 0.15, z + 0.06), 0.065)
    return [b.mesh(m["Hair"])]


def face_mustache(m):
    b = Blob(0.0035)
    b.capsule((-0.026, -0.156, 1.601), (0.026, -0.156, 1.601), 0.0105)
    for sx in (-1, 1):
        b.ball((0.033 * sx, -0.149, 1.59), 0.009)
    return [b.mesh(m["Hair"])]


def face_beard(m):
    b = Blob(0.006)
    b.ball((0, -0.045, 1.57), 0.112, (1.0, 0.98, 0.72))
    b.ball((0, -0.105, 1.535), 0.045, (1.2, 1.0, 1.0))
    return [b.mesh(m["Hair"])] + face_mustache(m)


def face_stubble(m):
    b = Blob(0.006)
    b.ball((0, -0.044, 1.572), 0.108, (1.0, 0.97, 0.7))
    b.ball((0, -0.1, 1.538), 0.042, (1.2, 1.0, 1.0))
    return [b.mesh(m["Stubble"])]


def glasses_frame(m, lens):
    out = []
    for sx in (-1, 1):
        out.append(ring((0.054 * sx, -0.165, 1.674), 0.024, 0.0028, m["Eyes"]))
        out.append(rod((0.078 * sx, -0.162, 1.68), (0.142 * sx, -0.01, 1.685), 0.0024, m["Eyes"], 4))
        if lens:
            bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.023, depth=0.003,
                                                location=(0.054 * sx, -0.165, 1.674),
                                                rotation=(math.pi / 2, 0, 0))
            lo = bpy.context.active_object
            lo.data.materials.append(m["Eyes"])
            out.append(lo)
    out.append(rod((-0.03, -0.168, 1.68), (0.03, -0.168, 1.68), 0.0025, m["Eyes"], 4))
    return out


def face_glasses(m):
    return glasses_frame(m, False)


def face_shades(m):
    return glasses_frame(m, True)


def hat_cap(m):
    b = Blob(0.008)
    b.ball((0, 0.025, 1.752), 0.172, (1.0, 1.04, 0.72))
    b.ball((0, -0.172, 1.742), 0.09, (1.0, 0.95, 0.15))                   # brim
    b.ball((0, 0.025, 1.876), 0.012)
    return [b.mesh(m["Hat"])]


def hat_beanie(m):
    b = Blob(0.008)
    b.ball((0, 0.035, 1.735), 0.172, (1.0, 1.04, 1.0))
    b.ball((0, 0.035, 1.72), 0.172, (1.01, 1.05, 0.3))                    # folded cuff
    b.ball((0, 0.03, 1.9), 0.035)                                         # bobble
    return [b.mesh(m["Hat"])]


# (name, builder, LOD0 triangles, weighting)
WARDROBE = [
    ("Head_skin", head, 1900, "head"),
    ("Brows", brows, 80, "head"),
    ("Hands", hands, 1100, "hands"),
    ("Hair_short", hair_short, 900, "hair"),
    ("Hair_buzz", hair_buzz, 500, "hair"),
    ("Hair_long", hair_long, 1300, "hair"),
    ("Hair_ponytail", hair_ponytail, 1000, "hair"),
    ("Hair_bun", hair_bun, 900, "hair"),
    ("Hair_mohawk", hair_mohawk, 800, "hair"),
    ("Hair_afro", hair_afro, 1300, "hair"),
    ("Face_stubble", face_stubble, 350, "head"),
    ("Face_mustache", face_mustache, 150, "head"),
    ("Face_beard", face_beard, 600, "head"),
    ("Face_glasses", face_glasses, 400, "hair"),
    ("Face_shades", face_shades, 450, "hair"),
    ("Top_tee", top_tee, 2300, "body"),
    ("Top_longsleeve", top_longsleeve, 2300, "body"),
    ("Top_hoodie", top_hoodie, 2700, "body"),
    ("Top_jacket", top_jacket, 2900, "body"),
    ("Top_tank", top_tank, 2200, "body"),
    ("Bottom_jeans", bottom_jeans, 1500, "body"),
    ("Bottom_shorts", bottom_shorts, 1500, "body"),
    ("Bottom_skirt", bottom_skirt, 1500, "skirt"),
    ("Shoes_sneakers", shoes_sneakers, 600, "body"),
    ("Shoes_boots", shoes_boots, 700, "body"),
    ("Hat_cap", hat_cap, 500, "hair"),
    ("Hat_beanie", hat_beanie, 500, "hair"),
]


# ------------------------------------------------------------------- skinning ---

def build_armature():
    arm = bpy.data.armatures.new("Rig")
    ob = bpy.data.objects.new("Rig", arm)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode="EDIT")
    for name in ORDER:
        head_, tail, parent, conn = BONES[name]
        b = arm.edit_bones.new(name)
        b.head, b.tail = head_, tail
        b.roll = 0.0
        if parent:
            b.parent = arm.edit_bones[parent]
            b.use_connect = conn
    bpy.ops.object.mode_set(mode="OBJECT")
    for pb in ob.pose.bones:
        pb.rotation_mode = "QUATERNION"
    return ob


class Proxy:
    """A plain body, weighted by Blender's bone heat, whose weights every garment copies
    from the nearest point, so clothes and skin bend the same way."""

    def __init__(self, rig, m):
        b = Blob(0.016)
        torso(b)
        pelvis(b)
        b.capsule((0, 0.008, 1.395), (0, 0.0, 1.56), 0.058)
        b.ball((0, 0.0, 1.665), 0.152, (0.93, 1.0, 1.08))
        pieces = [b.mesh(m["Skin"])]
        for sx in (1, -1):
            a = Blob(0.016)
            sh, el, wr = arm_points(sx)
            a.ball(sh, 0.08)
            a.capsule(sh, el, 0.06)
            a.capsule(el, wr, 0.05)
            hand_shape(a, sx, mitten=True)
            pieces.append(a.mesh(m["Skin"]))
            lg = Blob(0.016)
            hip, knee, ankle = leg_points(sx)
            lg.capsule(hip + Vector((0, 0, 0.02)), knee, 0.088)
            lg.capsule(knee, ankle, 0.07)
            shoe(lg, sx)
            pieces.append(lg.mesh(m["Skin"]))
        ob = join(pieces, "Proxy")
        finish(ob, 6000)
        for name in DETAIL_BONES:
            rig.data.bones[name].use_deform = False
        select_only([ob, rig], rig)
        bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        for name in DETAIL_BONES:
            rig.data.bones[name].use_deform = True
        names = {g.index: g.name for g in ob.vertex_groups}
        self.weights = [{names[g.group]: g.weight for g in v.groups if g.weight > 0.001}
                        for v in ob.data.vertices]
        self.verts = [v.co.copy() for v in ob.data.vertices]
        self.polys = [list(p.vertices) for p in ob.data.polygons]
        self.bvh = BVHTree.FromPolygons(self.verts, self.polys)
        bpy.data.objects.remove(ob)

    def at(self, co):
        _, _, idx, _ = self.bvh.find_nearest(co)
        acc = {}
        for vi in self.polys[idx]:
            w = 1.0 / ((self.verts[vi] - co).length + 0.004)
            for g, x in self.weights[vi].items():
                acc[g] = acc.get(g, 0.0) + x * w
        return acc


def head_weights(co, jaw_scale=1.0):
    z = co.z
    if z < 1.4:
        w = {"Chest": 1.0}
    elif z < 1.47:
        k = (z - 1.4) / 0.07
        w = {"Chest": 1 - k, "Neck": k}
    elif z < 1.55:
        k = smooth((z - 1.47) / 0.08)
        w = {"Neck": 1 - k, "Head": k}
    else:
        w = {"Head": 1.0}
    # The chin and lower lip ride the jaw.
    if w.get("Head", 0) > 0 and co.y < -0.02:
        j = smooth((1.588 - z) / 0.022) * smooth((-0.02 - co.y) / 0.05) * jaw_scale
        h = w["Head"]
        w["Head"] = h * (1 - j)
        w["Jaw"] = h * j
    return w


def hair_weights(co):
    # Rigid on the head; long hair below the neck follows the chest.
    z = co.z
    if z > 1.52:
        return {"Head": 1.0}
    k = smooth((z - 1.42) / 0.1)
    return {"Head": k, "Chest": 1 - k}


def hand_weights(co):
    sx = 1 if co.x > 0 else -1
    s = "L" if sx > 0 else "R"
    d, _ = arm_axes(sx)
    wr = arm_points(sx)[2]
    t = (co - wr).dot(d)
    ta, tu = thumb_line(sx)
    dt = seg_dist(co, ta, ta + tu * 0.058) - 0.0115
    df = min(seg_dist(co, wr + d * kd + FRONT * off, wr + d * (kd + ln)) - r
             for off, ln, r, kd in FINGERS)
    if dt < df and dt < 0.006:
        k = smooth(((co - ta).dot(tu) + 0.004) / 0.018)
        return {"Hand." + s: 1 - k, "Thumb." + s: k}
    if t < 0.02:
        k = smooth((t + 0.012) / 0.03)
        return {"LowerArm." + s: 1 - k, "Hand." + s: k}
    tk = t - KNUCKLE
    k1 = smooth((tk + 0.008) / 0.016)
    k2 = smooth((tk - 0.034) / 0.014)
    return {"Hand." + s: 1 - k1, "Fingers1." + s: k1 * (1 - k2), "Fingers2." + s: k1 * k2}


def set_weights(ob, fn):
    ob.vertex_groups.clear()
    groups = {n: ob.vertex_groups.new(name=n) for n in ORDER}
    for v in ob.data.vertices:
        w = fn(v)
        top = sorted(((x, g) for g, x in w.items() if x > 0.0), reverse=True)[:4]
        total = sum(x for x, _ in top) or 1.0
        for x, g in top:
            groups[g].add([v.index], x / total, "REPLACE")


def weight_part(ob, mode, proxy):
    if mode == "head":
        set_weights(ob, lambda v: head_weights(v.co))
    elif mode == "hair":
        set_weights(ob, lambda v: hair_weights(v.co))
    elif mode == "hands":
        set_weights(ob, lambda v: hand_weights(v.co))
    else:
        skirt_mat = ob.data.materials.find("Pants") if mode == "skirt" else None
        vmat = {}
        for p in ob.data.polygons:
            for vi in p.vertices:
                vmat[vi] = p.material_index

        def fn(v):
            w = proxy.at(v.co)
            if skirt_mat is not None and vmat.get(v.index) == skirt_mat and v.co.z < 0.9:
                # The skirt mostly hangs from the hips instead of following each thigh.
                k = 0.7 * smooth((0.9 - v.co.z) / 0.12)
                total = sum(w.values()) or 1.0
                w = {g: x / total * (1 - k) for g, x in w.items()}
                w["Hips"] = w.get("Hips", 0.0) + k
            return w
        set_weights(ob, fn)


def bind(ob, rig):
    ob.parent = rig
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = rig


def build_wardrobe(rig, m, proxy):
    parts = []
    for name, builder, target, mode in WARDROBE:
        ob = finish(join(builder(m), name), target)
        weight_part(ob, mode, proxy)
        if name == "Hands":
            low = finish(join(hands_mitten(m), name + "_lod1"), max(int(target * LOD1), 60))
            weight_part(low, mode, proxy)
        else:
            low = ob.copy()
            low.data = ob.data.copy()
            low.name = low.data.name = name + "_lod1"
            bpy.context.scene.collection.objects.link(low)
            want = max(int(tris(ob) * LOD1), 24)
            decimate(low, want)
            if tris(low) > want * 1.5:
                # The collapse got stuck (overlapping shells): rebuild coarser instead.
                bpy.data.objects.remove(low)
                RES_SCALE[0] = 2.5
                low = finish(join(builder(m), name + "_lod1"), want)
                RES_SCALE[0] = 1.0
                weight_part(low, mode, proxy)
        for o in (ob, low):
            bind(o, rig)
            parts.append(o)
        print(f"  {name:16s} {tris(ob):5d} tris   lod1 {tris(low):4d}", flush=True)
    return parts


# ---------------------------------------------------------------- animation ---

def q(axis, deg):
    return Quaternion(Vector(axis), math.radians(deg))


def X(d):
    return q((1, 0, 0), d)


def Y(d):
    return q((0, 1, 0), d)


def Z(d):
    return q((0, 0, 1), d)


class Dir:
    """Aim a bone straight along a direction given in its frame bone's space (Chest for
    arms, Hips for legs), with an optional twist about that direction in degrees."""

    def __init__(self, v, twist=0.0, frame=None):
        self.v = Vector(v).normalized()
        self.twist = twist
        self.frame = frame


def dir_lerp(a, b, k):
    return Dir(lerp(a.v, b.v, k), lerp(a.twist, b.twist, k), a.frame)


# Signs, with the character facing -Y:
#   down-pointing limb, X(-a): swings forward.      up-pointing (spine), X(+a): leans forward.
#   left arm, Y(+a): lowers toward the body (rest is an A-pose); right arm, Y(-a).
#   Z(+a): turn to the character's left.         Jaw, X(+a): opens the mouth.
#   Fingers, Y(+a) on the left / Y(-a) on the right: curl toward the palm.

ARM_DOWN = 34.0  # from the A-pose to a relaxed hang
RELAXED = (16, 20, 8)   # finger curl: knuckles, middle joints, thumb
FIST = (88, 100, 40)
GRIP = (70, 80, 30)
OPEN = (2, 4, 0)


def hand(p, side, curl):
    sg = 1 if side == "L" else -1
    f1, f2, th = curl
    d, _ = arm_axes(sg)
    p["Fingers1." + side] = Y(f1 * sg)
    p["Fingers2." + side] = Y(f2 * sg)
    p["Thumb." + side] = Quaternion(d, math.radians(th * sg))
    return p


def lerp_curl(a, b, k):
    return tuple(lerp(x, y, k) for x, y in zip(a, b))


def base_pose():
    p = {n: Quaternion() for n in ORDER}
    hand(p, "L", RELAXED)
    hand(p, "R", RELAXED)
    return p


def rest_dir(name):
    head_, tail, _, _ = BONES[name]
    return (tail - head_).normalized()


def apply_pose(rig, pose, hip_offset=Vector()):
    """pose: bone -> delta rotation in a world-aligned frame, relative to the parent,
    or a Dir that aims the bone."""
    abs_rot = {}
    abs_mat = {}
    rest = {b.name: b.matrix_local.copy() for b in rig.data.bones}
    for name in ORDER:
        parent = BONES[name][2]
        delta = pose.get(name, Quaternion())
        if isinstance(delta, Dir):
            frame = delta.frame or ("Chest" if "Arm" in name or "Hand" in name else "Hips")
            r = (abs_rot[frame] @ Quaternion(delta.v, math.radians(delta.twist)) @
                 rest_dir(name).rotation_difference(delta.v))
        elif parent is None:
            r = delta
        else:
            r = abs_rot[parent] @ delta
        if parent is None:
            head_ = rest[name].to_translation() + hip_offset
        else:
            # Head follows the posed parent.
            off = rest[parent].inverted() @ rest[name].to_translation()
            head_ = abs_mat[parent] @ off
        abs_rot[name] = r
        m = r.to_matrix().to_4x4() @ rest[name].to_3x3().to_4x4()
        m.translation = head_
        abs_mat[name] = m
        rig.pose.bones[name].matrix = m
        bpy.context.view_layer.update()


def key_pose(rig, frame, pose, hip_offset=Vector()):
    apply_pose(rig, pose, hip_offset)
    for name in ORDER:
        pb = rig.pose.bones[name]
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        if name == "Hips":
            pb.keyframe_insert("location", frame=frame)


def relaxed(p, sway=0.0):
    p["UpperArm.L"] = Y(ARM_DOWN) @ X(sway)
    p["UpperArm.R"] = Y(-ARM_DOWN) @ X(-sway)
    p["LowerArm.L"] = X(-12)
    p["LowerArm.R"] = X(-12)
    return p


def make_action(rig, name, frames, fn, loop=True):
    act = bpy.data.actions.new(name)
    rig.animation_data_create()
    rig.animation_data.action = act
    for pb in rig.pose.bones:
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
    n = frames if loop else frames - 1
    for f in range(0, frames + 1 if loop else frames, 1):
        t = (f % frames) / frames if loop else f / max(n, 1)
        pose, off = fn(t)
        key_pose(rig, f, pose, off)
    act.use_fake_user = True
    # Linear-ish keys are fine at 30 fps sampling; make loops seamless.
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    track = rig.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, 0, act)
    rig.animation_data.action = None
    return act


def idle(t):
    w = math.sin(t * math.tau)
    p = relaxed(base_pose(), sway=2.0 * w)
    p["Spine"] = X(1.0 + 1.2 * w)
    p["Chest"] = X(-0.5 * w)
    p["Head"] = Z(3.0 * math.sin(t * math.tau + 1.0)) @ X(-1.0 * w)
    p["UpperArm.L"] = Y(ARM_DOWN - 1.5 * w) @ X(2)
    p["UpperArm.R"] = Y(-ARM_DOWN + 1.5 * w) @ X(2)
    p["UpperLeg.L"] = Y(-1.5)
    p["UpperLeg.R"] = Y(2.5) @ X(-3)
    p["LowerLeg.R"] = X(6)
    p["Foot.R"] = X(-3)
    return p, Vector((0.01 * w, 0, -0.006 + 0.004 * w))


def idle_look(t):
    """Glance left, back, then right, shifting weight between the feet."""
    p, off = idle(t * 2 % 1.0)
    look = math.sin(t * math.tau)
    hold = smooth(abs(look) * 1.6) * (1 if look > 0 else -1)
    p["Head"] = Z(32 * hold) @ X(-2 + 4 * abs(hold))
    p["Neck"] = Z(10 * hold)
    p["Chest"] = Z(6 * hold)
    shift = math.sin(t * math.tau + 0.6)
    p["Hips"] = Y(2.5 * shift)
    p["UpperLeg.L"] = Y(-1.5 - 2 * shift)
    p["UpperLeg.R"] = Y(2.5 - 2 * shift) @ X(-3)
    return p, Vector((0.022 * shift, 0, -0.006))


def idle_arms(t):
    """Arms folded across the chest, weight on one leg."""
    w = math.sin(t * math.tau)
    p, off = idle(t)
    p["UpperArm.L"] = Dir((0.3, -0.55, -0.78))
    p["LowerArm.L"] = Dir((-0.95, -0.22, 0.2 + 0.02 * w))
    p["UpperArm.R"] = Dir((-0.3, -0.64, -0.71))
    p["LowerArm.R"] = Dir((0.95, -0.32, 0.25 + 0.02 * w))
    p["Hand.L"] = Z(20) @ Y(-20)
    p["Hand.R"] = Z(-20) @ Y(20)
    hand(p, "L", (40, 50, 20))
    hand(p, "R", (40, 50, 20))
    p["Hips"] = Y(-4)
    p["Spine"] = Y(3) @ X(-1 + w)
    p["Head"] = Z(-5) @ X(2 * w)
    return p, off + Vector((-0.03, 0, -0.005))


def gait(t, run):
    """Walk (run=0) or run (run=1). One cycle = two steps; left foot forward at t=0."""
    ph = t * math.tau
    s, c = math.sin(ph), math.cos(ph)
    p = base_pose()
    thigh = lerp(28, 48, run)
    knee_swing = lerp(55, 105, run)
    for side, sg in (("L", 1.0), ("R", -1.0)):
        # sg flips the phase for the right leg.
        ss, cc = s * sg, c * sg
        p["UpperLeg." + side] = X(-thigh * cc + lerp(0, -10, run))
        # Knee folds while the leg swings forward (sin > 0 for the swinging leg).
        bend = knee_swing * max(0.0, ss) + lerp(6, 18, run) * max(0.0, -ss) + 4
        p["LowerLeg." + side] = X(bend)
        p["Foot." + side] = X(lerp(-10, -25, run) * max(0.0, ss) + 12 * max(0.0, cc) * (1 - run * 0.5))
        arm = lerp(26, 50, run)
        p["UpperArm." + side] = (Y(ARM_DOWN if sg > 0 else -ARM_DOWN) @ X(arm * cc) @
                                 Y(lerp(0, 8, run) * (1 if sg > 0 else -1)))
        p["LowerArm." + side] = X(-lerp(20, 85, run) - lerp(10, 20, run) * max(0.0, -cc))
        hand(p, side, (lerp(16, 55, run), lerp(20, 70, run), lerp(8, 25, run)))
    p["Hips"] = Z(lerp(7, 10, run) * c) @ Y(-3 * s)
    p["Spine"] = X(lerp(4, 12, run)) @ Z(-lerp(5, 8, run) * c)
    p["Chest"] = X(lerp(1, 5, run)) @ Z(-lerp(4, 7, run) * c)
    p["Head"] = X(-lerp(4, 12, run)) @ Z(lerp(4, 8, run) * c)
    bob = abs(c)
    drop = lerp(0.035, 0.08, run)
    off = Vector((0.012 * s, 0, -drop * (1 - bob) - lerp(0.0, 0.05, run)))
    return p, off


def jump(t):
    p = relaxed(base_pose())
    w = math.sin(t * math.tau) * 2
    p["UpperLeg.L"] = X(-55 + w)
    p["LowerLeg.L"] = X(80)
    p["UpperLeg.R"] = X(10 - w)
    p["LowerLeg.R"] = X(45)
    p["Foot.L"] = X(-15)
    p["UpperArm.L"] = Y(ARM_DOWN - 35) @ X(-60 + w)
    p["UpperArm.R"] = Y(-ARM_DOWN + 35) @ X(-45 - w)
    p["LowerArm.L"] = X(-40)
    p["LowerArm.R"] = X(-50)
    p["Spine"] = X(6)
    p["Head"] = X(-8)
    hand(p, "L", OPEN)
    hand(p, "R", OPEN)
    return p, Vector((0, 0, 0.05))


def fall(t):
    p = relaxed(base_pose())
    w = math.sin(t * math.tau) * 6
    p["UpperLeg.L"] = X(-25 + w)
    p["LowerLeg.L"] = X(35)
    p["UpperLeg.R"] = X(5 - w)
    p["LowerLeg.R"] = X(25)
    p["UpperArm.L"] = Y(ARM_DOWN - 50 + w) @ X(-20)
    p["UpperArm.R"] = Y(-ARM_DOWN + 50 - w) @ X(-20)
    p["LowerArm.L"] = X(-25)
    p["LowerArm.R"] = X(-25)
    p["Spine"] = X(-4)
    hand(p, "L", OPEN)
    hand(p, "R", OPEN)
    return p, Vector()


def sit_pose(p):
    for side, sg in (("L", 1), ("R", -1)):
        p["UpperLeg." + side] = X(-82) @ Y(4 * sg)
        p["LowerLeg." + side] = X(78)
        p["Foot." + side] = X(-8)
        # Hands on the wheel.
        p["UpperArm." + side] = Y((ARM_DOWN + 4) * sg) @ X(-50)
        p["LowerArm." + side] = X(-48)
        hand(p, side, GRIP)
    p["Spine"] = X(-8)
    p["Chest"] = X(-3)
    p["Head"] = X(8)
    return p


def sit(t):
    p = sit_pose(base_pose())
    p["Head"] = X(8) @ Z(4 * math.sin(t * math.tau))
    return p, Vector((0, 0.05, -0.4))


def sit_bench(t):
    """Sitting on a bench or chair (seat about 0.45 m), hands resting on the thighs."""
    w = math.sin(t * math.tau)
    p = base_pose()
    for side, sg in (("L", 1), ("R", -1)):
        p["UpperLeg." + side] = Dir((0.1 * sg, -1, 0.04))
        p["LowerLeg." + side] = Dir((0.04 * sg, -0.12, -1))
        p["Foot." + side] = Dir((0.0, -0.92, -0.4))
        p["UpperArm." + side] = Dir((0.14 * sg, -0.34, -0.93))
        p["LowerArm." + side] = Dir((-0.05 * sg, -0.92, -0.38))
        hand(p, side, (22, 28, 10))
    p["Spine"] = X(5 + 1.2 * w)
    p["Chest"] = X(2 - 0.6 * w)
    p["Head"] = X(-4) @ Z(6 * math.sin(t * math.tau * 0.5 + 1.0))
    return p, Vector((0, 0.06, -0.43 + 0.003 * w))


def enter_car(t):
    """Step up, duck and swing into the seat (character's left side faces the car)."""
    a = relaxed(base_pose())
    b = sit_pose(base_pose())
    k = t * t * (3 - 2 * t)
    p = {}
    for n in ORDER:
        p[n] = a[n].slerp(b[n], k)
    duck = math.sin(t * math.pi)
    p["Spine"] = p["Spine"] @ X(30 * duck)
    p["Head"] = p["Head"] @ X(10 * duck)
    p["Hips"] = Z(-60 * duck)
    off = Vector((0, 0.05 * k, -0.4 * k - 0.05 * duck))
    return p, off


def exit_car(t):
    p, off = enter_car(1.0 - t)
    return p, off


def talk(t):
    """Chatting: hands gesture in turn, head nods, the jaw moves."""
    p, off = idle(t)
    a = math.sin(t * math.tau * 2)
    b = math.sin(t * math.tau * 3 + 1.3)
    p["UpperArm.R"] = Dir((-0.22, -0.3 - 0.1 * a, -0.93))
    p["LowerArm.R"] = Dir((0.12 - 0.15 * a, -0.92, 0.05 + 0.25 * max(a, 0)), twist=-30)
    p["UpperArm.L"] = Dir((0.22, -0.2 - 0.08 * b, -0.96))
    p["LowerArm.L"] = Dir((0.15 + 0.1 * b, -0.8, -0.2 + 0.2 * max(b, 0)), twist=30)
    hand(p, "L", (10, 14, 4))
    hand(p, "R", (8 + 10 * max(-a, 0), 12, 4))
    p["Head"] = X(3 * math.sin(t * math.tau * 4)) @ Z(5 * math.sin(t * math.tau))
    p["Jaw"] = X(3 + 6 * max(0.0, math.sin(t * math.tau * 9)) + 3 * max(0.0, math.sin(t * math.tau * 13)))
    return p, off


def phone(t):
    """Phone to the right ear, the other hand on the hip, chatting."""
    p, off = idle(t)
    w = math.sin(t * math.tau)
    p["UpperArm.R"] = Dir((-0.42, -0.9, 0.06))
    p["LowerArm.R"] = Dir((0.55, 0.62, 0.55))
    p["Hand.R"] = X(-10)
    hand(p, "R", (60, 50, 35))
    p["UpperArm.L"] = Dir((0.6, 0.15, -0.78))
    p["LowerArm.L"] = Dir((-0.55, -0.35, -0.72))
    hand(p, "L", (50, 40, 20))
    p["Head"] = Z(-6) @ Y(-6) @ X(3 * w)
    p["Jaw"] = X(2 + 5 * max(0.0, math.sin(t * math.tau * 7)) + 2 * max(0.0, math.sin(t * math.tau * 11)))
    return p, off


def umbrella(t):
    """Holding an umbrella up: right fist in front of the shoulder, handle upright."""
    p, off = idle(t)
    w = math.sin(t * math.tau)
    p["UpperArm.R"] = Dir((-0.15, -0.4, -0.9))
    p["LowerArm.R"] = Dir((0.15, -0.6, 0.78 + 0.02 * w))
    p["Hand.R"] = X(-8) @ Z(10)
    hand(p, "R", FIST)
    p["Chest"] = Y(2)
    return p, off


def wave(t):
    """A friendly wave with the right hand."""
    p, off = idle(t)
    up = smooth(t / 0.2) * (1 - smooth((t - 0.82) / 0.18))
    sway = math.sin(t * math.tau * 3) * up
    rest_u = Dir((-0.15, -0.05, -1))
    rest_l = Dir((-0.05, -0.2, -1))
    p["UpperArm.R"] = dir_lerp(rest_u, Dir((-0.8, -0.25, 0.45)), up)
    p["LowerArm.R"] = dir_lerp(rest_l, Dir((-0.05 - 0.45 * sway, -0.25, 1.0)), up)
    p["Hand.R"] = X(-10 * up)
    hand(p, "R", (lerp(16, 0, up), lerp(20, 4, up), lerp(8, 0, up)))
    p["Head"] = Z(-8 * up) @ Y(-5 * up)
    p["Chest"] = Y(4 * up)
    return p, off


def punch(t):
    """Right cross: wind up, snap out, recover."""
    p = relaxed(base_pose())
    if t < 0.3:
        k = smooth(t / 0.3)
        out = 0.0
    elif t < 0.5:
        k = 1.0
        out = smooth((t - 0.3) / 0.2)
    else:
        k = 1.0 - smooth((t - 0.5) / 0.5)
        out = k
    guard = max(k, out)
    p["UpperArm.L"] = X(-55 * guard) @ Y(ARM_DOWN)
    p["LowerArm.L"] = X(-12 - 100 * guard)
    p["UpperArm.R"] = X(-45 * guard - 45 * out) @ Y(-ARM_DOWN + 25 * guard - 20 * out)
    p["LowerArm.R"] = X(-12 - 110 * guard * (1 - out) - 8 * out)
    p["Chest"] = Z(-18 * k * (1 - out) + 22 * out)
    p["Spine"] = X(6 * guard) @ Z(8 * out)
    p["UpperLeg.L"] = X(-18 * guard)
    p["LowerLeg.L"] = X(14 * guard)
    p["UpperLeg.R"] = X(10 * guard)
    hand(p, "L", lerp_curl(RELAXED, FIST, guard))
    hand(p, "R", lerp_curl(RELAXED, FIST, guard))
    return p, Vector((0, 0, -0.04 * guard))


def jab(t):
    """Quick left jab from the guard."""
    p = relaxed(base_pose())
    if t < 0.25:
        k, out = smooth(t / 0.25), 0.0
    elif t < 0.45:
        k, out = 1.0, smooth((t - 0.25) / 0.2)
    else:
        k = 1.0 - smooth((t - 0.45) / 0.55)
        out = k
    guard = max(k, out)
    p["UpperArm.R"] = X(-55 * guard) @ Y(-ARM_DOWN)
    p["LowerArm.R"] = X(-12 - 105 * guard)
    p["UpperArm.L"] = X(-45 * guard - 42 * out) @ Y(ARM_DOWN - 25 * guard + 22 * out)
    p["LowerArm.L"] = X(-12 - 110 * guard * (1 - out) - 6 * out)
    p["Chest"] = Z(10 * k * (1 - out) - 16 * out)
    p["Spine"] = X(5 * guard) @ Z(-6 * out)
    p["UpperLeg.L"] = X(-20 * guard)
    p["LowerLeg.L"] = X(16 * guard)
    p["UpperLeg.R"] = X(8 * guard)
    hand(p, "L", lerp_curl(RELAXED, FIST, guard))
    hand(p, "R", lerp_curl(RELAXED, FIST, guard))
    return p, Vector((0, 0, -0.04 * guard))


def hook(t):
    """Right hook: the elbow comes up and the fist swings across."""
    p = relaxed(base_pose())
    if t < 0.3:
        k, swing = smooth(t / 0.3), 0.0
    elif t < 0.55:
        k, swing = 1.0, smooth((t - 0.3) / 0.25)
    else:
        k = 1.0 - smooth((t - 0.55) / 0.45)
        swing = k
    guard = max(k, swing)
    rest_u, rest_l = Dir((-0.12, -0.05, -1)), Dir((-0.05, -0.2, -1))
    g_u, g_l = Dir((-0.3, -0.35, -0.88)), Dir((0.12, -0.45, 0.88))
    h_u, h_l = Dir((-0.85, -0.5, -0.12)), Dir((0.92, -0.38, 0.05))
    p["UpperArm.R"] = dir_lerp(dir_lerp(rest_u, g_u, k), h_u, swing)
    p["LowerArm.R"] = dir_lerp(dir_lerp(rest_l, g_l, k), h_l, swing)
    p["UpperArm.L"] = X(-55 * guard) @ Y(ARM_DOWN)
    p["LowerArm.L"] = X(-12 - 100 * guard)
    p["Chest"] = Z(-20 * k * (1 - swing) + 30 * swing)
    p["Spine"] = X(5 * guard) @ Z(10 * swing)
    p["Hips"] = Z(8 * swing)
    p["UpperLeg.L"] = X(-14 * guard)
    p["LowerLeg.L"] = X(14 * guard)
    hand(p, "L", lerp_curl(RELAXED, FIST, guard))
    hand(p, "R", lerp_curl(RELAXED, FIST, guard))
    return p, Vector((0, 0, -0.045 * guard))


def aim_pistol(t):
    w = math.sin(t * math.tau) * 0.8
    p = relaxed(base_pose())
    p["UpperArm.R"] = X(-84 + w) @ Y(-ARM_DOWN - 8)
    p["LowerArm.R"] = X(-4)
    p["Hand.R"] = X(4)
    p["UpperArm.L"] = X(-72 + w) @ Y(ARM_DOWN + 22)
    p["LowerArm.L"] = X(10) @ Z(-12)
    p["Chest"] = Z(6)
    p["Head"] = Z(-4)
    hand(p, "R", GRIP)
    hand(p, "L", (50, 60, 20))
    return p, Vector()


def aim_shotgun(t):
    w = math.sin(t * math.tau) * 0.8
    p = relaxed(base_pose())
    p["UpperArm.R"] = X(-40 + w) @ Y(-ARM_DOWN + 2)
    p["LowerArm.R"] = X(-70)
    p["UpperArm.L"] = X(-75 + w) @ Y(ARM_DOWN + 14)
    p["LowerArm.L"] = X(-15) @ Y(20)
    p["Chest"] = Z(14)
    p["Spine"] = Z(6)
    p["Head"] = Z(-14)
    hand(p, "R", GRIP)
    hand(p, "L", GRIP)
    return p, Vector()


def reload_pistol(t):
    """Gun drops to the chest, the free hand fetches a magazine from the belt and slaps it in."""
    p = relaxed(base_pose())
    k = smooth(t / 0.15) * (1 - smooth((t - 0.85) / 0.15))
    rest_u, rest_l = Dir((-0.15, -0.05, -1)), Dir((-0.05, -0.2, -1))
    p["UpperArm.R"] = dir_lerp(rest_u, Dir((-0.16, -0.45, -0.88)), k)
    p["LowerArm.R"] = dir_lerp(rest_l, Dir((0.3, -0.94, 0.18)), k)
    p["Hand.R"] = Z(-20 * k)
    hand(p, "R", lerp_curl(RELAXED, GRIP, k))
    belt = smooth((t - 0.12) / 0.18) * (1 - smooth((t - 0.38) / 0.16))
    up = smooth((t - 0.42) / 0.16) * (1 - smooth((t - 0.8) / 0.15))
    lu = dir_lerp(dir_lerp(Dir((0.15, -0.05, -1)), Dir((0.32, 0.15, -0.94)), belt), Dir((0.12, -0.45, -0.88)), up)
    ll = dir_lerp(dir_lerp(Dir((0.05, -0.2, -1)), Dir((-0.1, -0.35, -0.93)), belt), Dir((-0.42, -0.9, 0.05)), up)
    p["UpperArm.L"] = lu
    p["LowerArm.L"] = ll
    hand(p, "L", lerp_curl(RELAXED, GRIP, max(belt, up)))
    p["Head"] = X(16 * k) @ Z(-6 * belt)
    p["Chest"] = X(4 * k)
    return p, Vector()


def reload_shotgun(t):
    """Shotgun at the hip, two shells pushed in, then a pump."""
    p = relaxed(base_pose())
    k = smooth(t / 0.12) * (1 - smooth((t - 0.88) / 0.12))
    rest_u, rest_l = Dir((-0.15, -0.05, -1)), Dir((-0.05, -0.2, -1))
    p["UpperArm.R"] = dir_lerp(rest_u, Dir((-0.22, -0.12, -0.97)), k)
    p["LowerArm.R"] = dir_lerp(rest_l, Dir((0.12, -0.98, 0.1)), k)
    hand(p, "R", lerp_curl(RELAXED, GRIP, k))
    shells = max(0.0, math.sin(min(t / 0.62, 1.0) * math.pi * 2)) * smooth(t / 0.15)
    pump = math.sin(min(max((t - 0.65) / 0.22, 0.0), 1.0) * math.pi)
    p["UpperArm.L"] = dir_lerp(Dir((0.15, -0.05, -1)), Dir((0.05, -0.35 - 0.12 * shells + 0.18 * pump, -0.93)), k)
    p["LowerArm.L"] = dir_lerp(Dir((0.05, -0.2, -1)), Dir((-0.3, -0.92 + 0.2 * pump, 0.05 + 0.15 * shells)), k)
    hand(p, "L", lerp_curl(RELAXED, GRIP, k))
    p["Head"] = X(14 * k)
    p["Chest"] = Z(10 * k) @ X(4 * k)
    return p, Vector()


def hit(t):
    k = math.sin(min(t / 0.9, 1.0) * math.pi)
    p = relaxed(base_pose())
    p["Spine"] = X(-14 * k)
    p["Chest"] = X(-10 * k)
    p["Head"] = X(-22 * k)
    p["UpperArm.L"] = X(-20 * k) @ Y(ARM_DOWN - 25 * k)
    p["UpperArm.R"] = X(-20 * k) @ Y(-ARM_DOWN + 25 * k)
    p["UpperLeg.R"] = X(-15 * k)
    p["LowerLeg.R"] = X(20 * k)
    hand(p, "L", OPEN)
    hand(p, "R", OPEN)
    p["Jaw"] = X(8 * k)
    return p, Vector((0, 0.04 * k, -0.03 * k))


def stumble(t):
    """Trip forward, arms out, and catch the balance."""
    k = math.sin(min(t, 1.0) * math.pi)
    lunge = math.sin(min(t / 0.7, 1.0) * math.pi)
    p = relaxed(base_pose())
    p["Spine"] = X(22 * k)
    p["Chest"] = X(10 * k)
    p["Head"] = X(-18 * k)
    p["UpperArm.L"] = X(-55 * k) @ Y(ARM_DOWN - 40 * k)
    p["UpperArm.R"] = X(-45 * k) @ Y(-ARM_DOWN + 45 * k)
    p["LowerArm.L"] = X(-25 * k)
    p["LowerArm.R"] = X(-25 * k)
    p["UpperLeg.R"] = X(-55 * lunge)
    p["LowerLeg.R"] = X(50 * lunge)
    p["UpperLeg.L"] = X(18 * lunge)
    p["LowerLeg.L"] = X(25 * lunge)
    hand(p, "L", OPEN)
    hand(p, "R", OPEN)
    return p, Vector((0, -0.12 * lunge, -0.12 * lunge))


def lying_pose():
    p = relaxed(base_pose())
    p["Hips"] = X(-88)
    p["Spine"] = X(-4)
    p["Head"] = X(-10) @ Z(18)
    p["UpperLeg.L"] = X(65)
    p["UpperLeg.R"] = X(85)
    p["LowerLeg.L"] = X(15)
    p["LowerLeg.R"] = X(5)
    p["UpperArm.L"] = Y(ARM_DOWN - 70)
    p["UpperArm.R"] = X(20) @ Y(-ARM_DOWN + 55)
    p["LowerArm.L"] = X(-30)
    p["LowerArm.R"] = X(-50)
    hand(p, "L", (30, 40, 10))
    hand(p, "R", (30, 40, 10))
    return p, Vector((0, 0.35, -0.78))


def blend(a, b, k):
    pa, oa = a
    pb, ob = b
    return {n: pa[n].slerp(pb[n], k) for n in ORDER}, oa.lerp(ob, k)


def fall_back(t):
    """Knocked off the feet onto the back (a car, a shotgun blast); stays down."""
    k = smooth(t / 0.7)
    flail = math.sin(min(t / 0.55, 1.0) * math.pi)
    start = (relaxed(base_pose()), Vector())
    p, off = blend(start, lying_pose(), k)
    p["UpperArm.L"] = p["UpperArm.L"] @ X(-60 * flail)
    p["UpperArm.R"] = p["UpperArm.R"] @ X(-70 * flail)
    p["UpperLeg.L"] = p["UpperLeg.L"] @ X(-40 * flail)
    p["Head"] = p["Head"] @ X(25 * flail)
    p["Jaw"] = X(10 * flail)
    hand(p, "L", OPEN)
    hand(p, "R", OPEN)
    bump = math.sin(min(max((t - 0.7) / 0.3, 0.0), 1.0) * math.pi) * 0.03   # a small bounce
    return p, off + Vector((0, 0, bump))


def get_up(t):
    """From lying on the back: sit up, roll onto the knees, stand."""
    lie = lying_pose()
    sitp = relaxed(base_pose())
    sitp["Hips"] = X(-25)
    sitp["Spine"] = X(25)
    sitp["Chest"] = X(10)
    sitp["UpperLeg.L"] = X(-30)
    sitp["UpperLeg.R"] = X(-60)
    sitp["LowerLeg.L"] = X(40)
    sitp["LowerLeg.R"] = X(110)
    sitp["UpperArm.L"] = X(35) @ Y(ARM_DOWN - 12)
    sitp["UpperArm.R"] = X(35) @ Y(-ARM_DOWN + 12)
    hand(sitp, "L", OPEN)
    hand(sitp, "R", OPEN)
    sit_ = (sitp, Vector((0, 0.18, -0.7)))
    crouch = relaxed(base_pose())
    crouch["Hips"] = X(25)
    crouch["Spine"] = X(15)
    crouch["UpperLeg.L"] = X(-95)
    crouch["UpperLeg.R"] = X(-30)
    crouch["LowerLeg.L"] = X(115)
    crouch["LowerLeg.R"] = X(120)
    crouch["Foot.L"] = X(-20)
    crouch["UpperArm.L"] = X(-25) @ Y(ARM_DOWN)
    crouch["LowerArm.L"] = X(-60)
    crouch_ = (crouch, Vector((0, 0.0, -0.45)))
    stand = (relaxed(base_pose()), Vector())
    if t < 0.35:
        return blend(lie, sit_, smooth(t / 0.35))
    if t < 0.7:
        return blend(sit_, crouch_, smooth((t - 0.35) / 0.35))
    return blend(crouch_, stand, smooth((t - 0.7) / 0.3))


def die(t):
    """Stagger, fold at the knees and fall onto the back."""
    k = smooth(t / 0.85)
    knees = math.sin(min(t / 0.6, 1.0) * math.pi * 0.5) * (1 - smooth((t - 0.6) / 0.3))
    p = relaxed(base_pose())
    p["Hips"] = X(-88 * k)
    p["Spine"] = X(10 * knees - 4 * k)
    p["Head"] = X(30 * knees - 10 * k) @ Z(18 * k)
    p["UpperLeg.L"] = X(-60 * knees + 75 * k - 10)
    p["UpperLeg.R"] = X(-40 * knees + 85 * k)
    p["LowerLeg.L"] = X(90 * knees + 15 * k)
    p["LowerLeg.R"] = X(70 * knees + 5 * k)
    p["UpperArm.L"] = X(-30 * knees) @ Y(ARM_DOWN - 70 * k)
    p["UpperArm.R"] = X(-40 * knees + 20 * k) @ Y(-ARM_DOWN + 55 * k)
    p["LowerArm.L"] = X(-30 * k)
    p["LowerArm.R"] = X(-50 * k)
    hand(p, "L", lerp_curl(RELAXED, (30, 40, 10), k))
    hand(p, "R", lerp_curl(RELAXED, (30, 40, 10), k))
    p["Jaw"] = X(6 * k)
    off = Vector((0, 0.35 * k, -0.35 * knees * (1 - k) - 0.78 * k))
    return p, off


def carjack(t):
    """Reach for the door and haul the driver out."""
    reach = smooth(t / 0.35)
    pull = smooth((t - 0.35) / 0.4)
    back = 1.0 - smooth((t - 0.8) / 0.2)
    p = relaxed(base_pose())
    for side, sg in (("L", 1), ("R", -1)):
        p["UpperArm." + side] = X(-80 * reach + 45 * pull * back) @ Y((ARM_DOWN - 15 * reach) * sg)
        p["LowerArm." + side] = X(-10 - 70 * pull * back)
        hand(p, side, lerp_curl(OPEN, GRIP, pull * back))
    p["Spine"] = X(20 * reach * (1 - pull) - 15 * pull * back)
    p["Chest"] = Z(-25 * pull * back)
    p["UpperLeg.L"] = X(-25 * reach)
    p["LowerLeg.L"] = X(20 * reach)
    p["UpperLeg.R"] = X(15 * pull * back)
    return p, Vector((0, 0.08 * pull * back, -0.05 * reach))


CLIPS = [
    # (name, frames, pose function, loops)
    ("Idle", 60, idle, True),
    ("IdleLook", 150, idle_look, True),
    ("IdleArms", 90, idle_arms, True),
    ("Walk", 30, lambda t: gait(t, 0.0), True),
    ("Run", 20, lambda t: gait(t, 1.0), True),
    ("Jump", 30, jump, True),
    ("Fall", 30, fall, True),
    ("Sit", 60, sit, True),
    ("SitBench", 90, sit_bench, True),
    ("EnterCar", 21, enter_car, False),
    ("ExitCar", 21, exit_car, False),
    ("Talk", 120, talk, True),
    ("Phone", 90, phone, True),
    ("Umbrella", 60, umbrella, True),
    ("Wave", 45, wave, False),
    ("Punch", 13, punch, False),
    ("Jab", 11, jab, False),
    ("Hook", 15, hook, False),
    ("AimPistol", 40, aim_pistol, True),
    ("AimShotgun", 40, aim_shotgun, True),
    ("ReloadPistol", 36, reload_pistol, False),
    ("ReloadShotgun", 48, reload_shotgun, False),
    ("Hit", 11, hit, False),
    ("Stumble", 24, stumble, False),
    ("FallBack", 24, fall_back, False),
    ("GetUp", 45, get_up, False),
    ("Die", 31, die, False),
    ("Carjack", 27, carjack, False),
]


def build_actions(rig):
    for name, frames, fn, loop in CLIPS:
        make_action(rig, name, frames, fn, loop)


# --------------------------------------------------------------------- main ---

def main():
    reset()
    m = {
        "Skin": material("Skin", (0.87, 0.64, 0.48), 0.6),
        "Shirt": material("Shirt", (0.2, 0.45, 0.85), 0.75),
        "Jacket": material("Jacket", (0.25, 0.2, 0.16), 0.6),
        "Pants": material("Pants", (0.16, 0.2, 0.32), 0.85),
        "Shoes": material("Shoes", (0.95, 0.95, 0.95), 0.5),
        "Hair": material("Hair", (0.15, 0.1, 0.07), 0.9),
        "Brows": material("Brows", (0.12, 0.08, 0.06), 0.9),
        "Eyes": material("Eyes", (0.03, 0.03, 0.04), 0.25),
        "EyeWhite": material("EyeWhite", (0.93, 0.92, 0.9), 0.3),
        "Hat": material("Hat", (0.7, 0.15, 0.12), 0.7),
        "Stubble": material("Stubble", (0.45, 0.32, 0.25), 0.95),
    }
    rig = build_armature()
    proxy = Proxy(rig, m)
    print("wardrobe:", flush=True)
    parts = build_wardrobe(rig, m, proxy)
    build_actions(rig)
    print(f"{len(parts)} meshes, {len(rig.data.bones)} bones, {len(CLIPS)} clips")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    select_only(parts + [rig], rig)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_animations=True, export_animation_mode="NLA_TRACKS",
                              export_yup=True, export_apply=False, export_skins=True,
                              export_all_influences=False, export_force_sampling=True,
                              export_materials="EXPORT")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
