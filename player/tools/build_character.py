"""Build the street character: a stylized, rigged, animated person, exported as glTF.

Run headless (needs the `bpy` pip module, Blender 4.2):
    python3 player/tools/build_character.py
Writes player/assets/character.glb.

The body is sculpted from metaballs (soft, chunky shapes in the spirit of the city kit),
skinned to a 16-bone armature with automatic weights, and given keyframed actions:
Idle, Walk, Run, Jump, Fall, Sit, EnterCar, ExitCar. Materials are named slots
(Skin, Shirt, Pants, Shoes, Hair, Eyes) so the game can recolour each person.

Conventions: the character faces -Y in Blender (glTF/Godot -Z), Z up, feet at Z = 0.
Poses are written as rotations in a world-aligned frame per bone and composed down the
hierarchy (child = parent @ delta), which keeps the animation code readable.
"""
import math
import os
import sys

import bpy  # noqa: E402  (bpy must load before mathutils users)
from mathutils import Matrix, Quaternion, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "character.glb"))
VIS = 0.574  # visible radius of a stiffness-2 metaball per unit of influence radius
FPS = 30

# ------------------------------------------------------------------ landmarks ---
# A-pose. x: character's left is +X.
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

BONES = {
    # name: (head, tail, parent, connected)
    "Hips": (Vector((0, 0, 0.9)), Vector((0, 0, 1.06)), None, False),
    "Spine": (Vector((0, 0, 1.06)), Vector((0, 0, 1.22)), "Hips", True),
    "Chest": (Vector((0, 0, 1.22)), Vector((0, 0, 1.43)), "Spine", True),
    "Neck": (Vector((0, 0, 1.43)), Vector((0, 0, 1.53)), "Chest", True),
    "Head": (Vector((0, 0, 1.53)), Vector((0, 0, 1.86)), "Neck", True),
}
for s, sx in (("L", 1), ("R", -1)):
    sh = Vector((SHOULDER.x * sx, SHOULDER.y, SHOULDER.z))
    d = Vector((ARM_DIR.x * sx, 0, ARM_DIR.z))
    el = sh + d * UPPER_ARM
    wr = el + d * FOREARM
    BONES["UpperArm." + s] = (sh, el, "Chest", False)
    BONES["LowerArm." + s] = (el, wr, "UpperArm." + s, True)
    BONES["Hand." + s] = (wr, wr + d * HAND, "LowerArm." + s, True)
    hip = Vector((LEG_X * sx, 0, HIP_Z))
    knee = Vector((LEG_X * sx, -0.01, KNEE_Z))
    ankle = Vector((LEG_X * sx, 0.0, ANKLE_Z))
    BONES["UpperLeg." + s] = (hip, knee, "Hips", False)
    BONES["LowerLeg." + s] = (knee, ankle, "UpperLeg." + s, True)
    BONES["Foot." + s] = (ankle, Vector((LEG_X * sx, -0.15, 0.03)), "LowerLeg." + s, True)

ORDER = ["Hips", "Spine", "Chest", "Neck", "Head",
         "UpperArm.L", "LowerArm.L", "Hand.L", "UpperArm.R", "LowerArm.R", "Hand.R",
         "UpperLeg.L", "LowerLeg.L", "Foot.L", "UpperLeg.R", "LowerLeg.R", "Foot.R"]


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


class Blob:
    """One metaball object = one separate mesh island with one material."""

    def __init__(self, name, res=0.018):
        self.mb = bpy.data.metaballs.new(name)
        self.mb.resolution = res
        self.mb.render_resolution = res
        self.ob = bpy.data.objects.new(name, self.mb)
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
        e.size_x = (b - a).length / 2
        e.rotation = Vector((1, 0, 0)).rotation_difference((b - a).normalized())
        return e


def to_mesh(blob, mat):
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(blob.ob.evaluated_get(dg))
    ob = bpy.data.objects.new(blob.ob.name + "_mesh", me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(mat)
    bpy.data.objects.remove(blob.ob)
    return ob


def lerp(a, b, t):
    return a + (b - a) * t


# ---------------------------------------------------------------------- body ---

def build_body(mats):
    parts = []
    # Torso: chest and belly blend into one soft jacket/shirt shape.
    t = Blob("Torso")
    t.ball((0, 0.0, 1.3), 0.17, (1.25, 0.82, 1.0))
    t.ball((0, 0.0, 1.14), 0.155, (1.12, 0.8, 1.0))
    t.ball((0, 0.0, 1.02), 0.15, (1.15, 0.82, 0.8))
    t.capsule((-0.17, 0, 1.38), (0.17, 0, 1.38), 0.085)  # shoulders
    parts.append(to_mesh(t, mats["Shirt"]))
    # Hips/pelvis in trouser colour.
    p = Blob("Pelvis")
    p.ball((0, 0.0, 0.94), 0.15, (1.12, 0.8, 0.75))
    parts.append(to_mesh(p, mats["Pants"]))
    # Neck and head.
    h = Blob("Head")
    h.capsule((0, 0, 1.4), (0, 0, 1.56), 0.06)
    h.ball((0, -0.005, 1.66), 0.155, (0.95, 1.0, 1.08))
    h.ball((0, -0.03, 1.6), 0.115, (1.0, 1.0, 0.9))       # jaw/cheeks
    h.ball((0, -0.16, 1.64), 0.03)                          # nose
    for sx in (-1, 1):
        h.ball((0.15 * sx, 0.0, 1.65), 0.035, (0.6, 1.0, 1.2))  # ears
    parts.append(to_mesh(h, mats["Skin"]))
    hair = Blob("Hair")
    hair.ball((0, 0.02, 1.72), 0.158, (1.0, 1.02, 0.78))
    hair.ball((0, 0.05, 1.67), 0.15, (0.98, 0.95, 0.9))
    hair.ball((0, -0.09, 1.76), 0.1, (1.25, 0.8, 0.5))      # fringe
    parts.append(to_mesh(hair, mats["Hair"]))
    for sx, s in ((1, "L"), (-1, "R")):
        sh, el, _, _ = BONES["UpperArm." + s]
        _, wr, _, _ = BONES["LowerArm." + s]
        _, hand_tip, _, _ = BONES["Hand." + s]
        sleeve = Blob("Sleeve" + s)
        sleeve.ball(sh, 0.085)
        sleeve.capsule(sh, lerp(sh, el, 0.75), 0.07)
        parts.append(to_mesh(sleeve, mats["Shirt"]))
        arm = Blob("Arm" + s)
        arm.capsule(lerp(sh, el, 0.55), el, 0.052)
        arm.capsule(el, wr, 0.048)
        arm.ball(lerp(wr, hand_tip, 0.45), 0.06, (0.8, 0.55, 1.1))  # mitten hand
        arm.ball(lerp(wr, hand_tip, 0.2) + Vector((0, -0.04, 0)), 0.025)  # thumb
        parts.append(to_mesh(arm, mats["Skin"]))
        hip, knee, _, _ = BONES["UpperLeg." + s]
        _, ankle, _, _ = BONES["LowerLeg." + s]
        leg = Blob("Leg" + s)
        leg.capsule(hip + Vector((0, 0, 0.02)), knee, 0.09)
        leg.capsule(knee, ankle + Vector((0, 0, 0.03)), 0.075)
        parts.append(to_mesh(leg, mats["Pants"]))
        shoe = Blob("Shoe" + s)
        shoe.capsule(Vector((LEG_X * sx, 0.04, 0.055)), Vector((LEG_X * sx, -0.12, 0.05)), 0.055)
        shoe.ball(Vector((LEG_X * sx, 0.0, 0.1)), 0.06)
        parts.append(to_mesh(shoe, mats["Shoes"]))
    # Eyes: small flattened spheres on the face.
    for sx in (-1, 1):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=10, ring_count=6, radius=0.024,
                                             location=(0.058 * sx, -0.158, 1.68))
        e = bpy.context.active_object
        e.scale = (1.0, 0.6, 1.3)
        e.data.materials.append(mats["Eyes"])
        parts.append(e)
    for ob in parts:
        bpy.context.view_layer.objects.active = ob
    bpy.ops.object.select_all(action="DESELECT")
    for ob in parts:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.join()
    body = bpy.context.active_object
    body.name = "Body"
    # Lighter mesh for the laptop: merge close verts and decimate.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=0.002)
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    dec = body.modifiers.new("Decimate", "DECIMATE")
    dec.ratio = 0.25
    bpy.ops.object.modifier_apply(modifier="Decimate")
    bpy.ops.object.shade_smooth()
    return body


def build_armature():
    arm = bpy.data.armatures.new("Rig")
    ob = bpy.data.objects.new("Rig", arm)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode="EDIT")
    for name in ORDER:
        head, tail, parent, conn = BONES[name]
        b = arm.edit_bones.new(name)
        b.head, b.tail = head, tail
        b.roll = 0.0
        if parent:
            b.parent = arm.edit_bones[parent]
            b.use_connect = conn
    bpy.ops.object.mode_set(mode="OBJECT")
    for pb in ob.pose.bones:
        pb.rotation_mode = "QUATERNION"
    return ob


def skin(body, rig):
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    # Eyes, hair and the head blob follow the head bone rigidly, whatever heat said.
    vg = body.vertex_groups
    head = vg["Head"]
    for v in body.data.vertices:
        if v.co.z > 1.56:
            for g in list(v.groups):
                vg[g.group].remove([v.index])
            head.add([v.index], 1.0, "REPLACE")
    # Keep at most 4 influences, normalised (glTF and Godot expect this).
    bpy.context.view_layer.objects.active = body
    body.select_set(True)
    bpy.ops.object.mode_set(mode="WEIGHT_PAINT")
    bpy.ops.object.vertex_group_limit_total(group_select_mode="ALL", limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    bpy.ops.object.mode_set(mode="OBJECT")


# ---------------------------------------------------------------- animation ---

def q(axis, deg):
    return Quaternion(Vector(axis), math.radians(deg))


def X(d):
    return q((1, 0, 0), d)


def Y(d):
    return q((0, 1, 0), d)


def Z(d):
    return q((0, 0, 1), d)


# Signs, with the character facing -Y:
#   down-pointing limb, X(-a): swings forward.      up-pointing (spine), X(+a): leans forward.
#   left arm, Y(+a): lowers toward the body (rest is an A-pose); right arm, Y(-a).
#   Z(+a): turn to the character's left.

ARM_DOWN = 34.0  # from the A-pose to a relaxed hang


def base_pose():
    return {n: Quaternion() for n in ORDER}


def apply_pose(rig, pose, hip_offset=Vector()):
    """pose: bone -> delta rotation in a world-aligned frame, relative to the parent."""
    abs_rot = {}
    abs_mat = {}
    rest = {b.name: b.matrix_local.copy() for b in rig.data.bones}
    for name in ORDER:
        parent = BONES[name][2]
        delta = pose.get(name, Quaternion())
        if parent is None:
            r = delta
            head = rest[name].to_translation() + hip_offset
        else:
            r = abs_rot[parent] @ delta
            # Head follows the posed parent.
            off = rest[parent].inverted() @ rest[name].to_translation()
            head = abs_mat[parent] @ off
        abs_rot[name] = r
        m = r.to_matrix().to_4x4() @ rest[name].to_3x3().to_4x4()
        m.translation = head
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
    return p, Vector()


def sit_pose(p):
    for side, sg in (("L", 1), ("R", -1)):
        p["UpperLeg." + side] = X(-82) @ Y(4 * sg)
        p["LowerLeg." + side] = X(78)
        p["Foot." + side] = X(-8)
        # Hands on the wheel.
        p["UpperArm." + side] = Y((ARM_DOWN + 4) * sg) @ X(-50)
        p["LowerArm." + side] = X(-48)
    p["Spine"] = X(-8)
    p["Chest"] = X(-3)
    p["Head"] = X(8)
    return p


def sit(t):
    p = sit_pose(base_pose())
    p["Head"] = X(8) @ Z(4 * math.sin(t * math.tau))
    return p, Vector((0, 0.05, -0.4))


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


def build_actions(rig):
    make_action(rig, "Idle", 60, idle)
    make_action(rig, "Walk", 30, lambda t: gait(t, 0.0))
    make_action(rig, "Run", 20, lambda t: gait(t, 1.0))
    make_action(rig, "Jump", 30, jump)
    make_action(rig, "Fall", 30, fall)
    make_action(rig, "Sit", 60, sit)
    make_action(rig, "EnterCar", 21, enter_car, loop=False)
    make_action(rig, "ExitCar", 21, exit_car, loop=False)


# --------------------------------------------------------------------- main ---

def main():
    reset()
    mats = {
        "Skin": material("Skin", (0.87, 0.64, 0.48), 0.6),
        "Shirt": material("Shirt", (0.2, 0.45, 0.85), 0.75),
        "Pants": material("Pants", (0.16, 0.2, 0.32), 0.85),
        "Shoes": material("Shoes", (0.95, 0.95, 0.95), 0.5),
        "Hair": material("Hair", (0.15, 0.1, 0.07), 0.9),
        "Eyes": material("Eyes", (0.03, 0.03, 0.04), 0.25),
    }
    body = build_body(mats)
    rig = build_armature()
    skin(body, rig)
    build_actions(rig)
    tris = sum(len(p.vertices) - 2 for p in body.data.polygons)
    print(f"character: {len(body.data.vertices)} verts, {tris} tris, {len(rig.data.bones)} bones")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_animations=True, export_animation_mode="NLA_TRACKS",
                              export_yup=True, export_apply=False, export_skins=True,
                              export_all_influences=False, export_force_sampling=True,
                              export_materials="EXPORT")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
