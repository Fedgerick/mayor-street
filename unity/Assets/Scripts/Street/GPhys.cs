// Godot-space wrappers over Unity physics, and a CharacterBody3D-style mover.
//
// Street logic works in msp's Godot space; Unity's physics runs in Unity space, so every query
// goes through G.U on the way in and G.FromU on the way out. Unity's CharacterController only
// knows world up, but on msp "up" is away from the planet's centre, so KinematicMover does
// Godot's move_and_slide itself with capsule casts: slide along walls, floor detection against
// an arbitrary up direction, floor snapping, and depenetration.
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public static class Layers
    {
        public const int WORLD = 0;      // msp layer 1: terrain, city collision
        public const int PLAYER = 8;
        public const int CARS = 9;       // msp layer 2: DrivableCar
        public const int TRAFFIC = 10;   // StreetBodies.TRAFFIC_LAYER: AI cars' stand-ins
        public const int PEOPLE = 11;    // StreetBodies.PEOPLE_LAYER
        public static int Mask(params int[] layers)
        {
            int m = 0;
            foreach (int l in layers) m |= 1 << l;
            return m;
        }
    }

    public struct GHit
    {
        public Vector3 point, normal;   // Godot space
        public float distance;
        public Collider collider;
    }

    public static class GPhys
    {
        public static bool Ray(Vector3 from, Vector3 dir, float dist, int mask, out GHit hit)
        {
            hit = default;
            if (!Physics.Raycast(G.U(from), G.U(dir), out var h, dist, mask, QueryTriggerInteraction.Ignore)) return false;
            hit = new GHit { point = G.FromU(h.point), normal = G.FromU(h.normal), distance = h.distance, collider = h.collider };
            return true;
        }

        public static bool SphereCast(Vector3 from, float radius, Vector3 dir, float dist, int mask, out GHit hit, Collider ignore = null)
        {
            hit = default;
            var hits = Physics.SphereCastAll(G.U(from), radius, G.U(dir), dist, mask, QueryTriggerInteraction.Ignore);
            return Nearest(hits, ignore, null, out hit);
        }

        static bool Nearest(RaycastHit[] hits, Collider ignore, HashSet<Collider> ignoreSet, out GHit hit)
        {
            hit = default;
            float best = float.PositiveInfinity;
            bool found = false;
            foreach (var h in hits)
            {
                if (h.collider == ignore || (ignoreSet != null && ignoreSet.Contains(h.collider))) continue;
                // a cast that starts inside a collider reports distance 0 and point zero: skip those
                if (h.distance <= 0f && h.point == Vector3.zero) continue;
                if (h.distance < best)
                {
                    best = h.distance;
                    hit = new GHit { point = G.FromU(h.point), normal = G.FromU(h.normal), distance = h.distance, collider = h.collider };
                    found = true;
                }
            }
            return found;
        }

        public static bool CapsuleCast(Vector3 a, Vector3 b, float radius, Vector3 dir, float dist, int mask, HashSet<Collider> ignore, out GHit hit)
        {
            var hits = Physics.CapsuleCastAll(G.U(a), G.U(b), radius, G.U(dir), dist, mask, QueryTriggerInteraction.Ignore);
            return Nearest(hits, null, ignore, out hit);
        }
    }

    /// <summary>Godot's CharacterBody3D.move_and_slide on a capsule, in Godot space, with an up
    /// direction of the caller's choosing.</summary>
    public class KinematicMover
    {
        public float radius = 0.3f, height = 1.76f;
        public float safeMargin = 0.02f;
        public float floorMaxAngle = 50f * Mathf.Deg2Rad;
        public float floorSnapLength = 0.35f;
        public int mask = Layers.Mask(Layers.WORLD, Layers.CARS, Layers.TRAFFIC, Layers.PEOPLE);
        public readonly HashSet<Collider> ignore = new HashSet<Collider>();

        public Vector3 position;   // feet, Godot space
        public Vector3 velocity;
        public Vector3 up = Vector3.up;
        public bool onFloor, onWall, onCeiling;
        public Vector3 floorNormal, wallNormal;
        public bool disabled;

        readonly Collider[] _overlap = new Collider[16];

        Vector3 A(Vector3 p) => p + up * radius;
        Vector3 B(Vector3 p) => p + up * (height - radius);

        public void MoveAndSlide(float dt)
        {
            bool wasFloor = onFloor;
            onFloor = onWall = onCeiling = false;
            if (disabled) { position += velocity * dt; return; }
            Depenetrate();
            Vector3 motion = velocity * dt;
            float cosFloor = Mathf.Cos(floorMaxAngle);
            for (int it = 0; it < 4 && motion.sqrMagnitude > 1e-10f; it++)
            {
                float len = motion.magnitude;
                Vector3 dir = motion / len;
                if (!GPhys.CapsuleCast(A(position), B(position), radius - safeMargin * 0.5f, dir, len + safeMargin, mask, ignore, out var hit))
                {
                    position += motion;
                    break;
                }
                float travel = Mathf.Max(hit.distance - safeMargin, 0f);
                position += dir * travel;
                Vector3 n = hit.normal;
                float nu = Vector3.Dot(n, up);
                if (nu >= cosFloor) { onFloor = true; floorNormal = n; }
                else if (nu <= -cosFloor) onCeiling = true;
                else { onWall = true; wallNormal = n; }
                Vector3 rest = motion - dir * travel;
                if (onFloor && nu >= cosFloor)
                {
                    // on a walkable slope, keep the horizontal motion and slide up it
                    rest -= n * Vector3.Dot(rest, n);
                }
                else
                {
                    if (onWall)
                    {
                        // walls don't push the body up or down: slide along them horizontally
                        Vector3 nh = (n - up * nu).normalized;
                        n = nh.sqrMagnitude > 0.01f ? nh : n;
                    }
                    rest -= n * Vector3.Dot(rest, n);
                }
                float vn = Vector3.Dot(velocity, n);
                if (vn < 0f) velocity -= n * vn;
                motion = rest;
            }
            // floor check and snap: stay glued to the ground over small bumps and down slopes
            if (!onFloor && Vector3.Dot(velocity, up) <= 0.01f)
            {
                float snap = wasFloor ? floorSnapLength : 0.0f;
                float probe = Mathf.Max(snap, safeMargin * 2f);
                if (GPhys.CapsuleCast(A(position), B(position), radius - safeMargin * 0.5f, -up, probe + safeMargin, mask, ignore, out var g)
                    && Vector3.Dot(g.normal, up) >= cosFloor)
                {
                    onFloor = true;
                    floorNormal = g.normal;
                    float d = Mathf.Max(g.distance - safeMargin, 0f);
                    if (snap > 0f || d < safeMargin * 2f) position -= up * d;
                }
            }
            if (onFloor)
            {
                float vu = Vector3.Dot(velocity, up);
                if (vu < 0f) velocity -= up * vu;
            }
        }

        /// <summary>Push the capsule out of anything it overlaps.</summary>
        public void Depenetrate()
        {
            var uA = G.U(A(position));
            var uB = G.U(B(position));
            int n = Physics.OverlapCapsuleNonAlloc(uA, uB, radius, _overlap, mask, QueryTriggerInteraction.Ignore);
            if (n == 0) return;
            var probe = ProbeCapsule();
            var pos = (uA + uB) * 0.5f;
            var rot = Quaternion.FromToRotation(Vector3.up, (uB - uA).normalized);
            Vector3 push = Vector3.zero;
            for (int i = 0; i < n; i++)
            {
                var c = _overlap[i];
                if (ignore.Contains(c)) continue;
                if (Physics.ComputePenetration(probe, pos, rot,
                        c, c.transform.position, c.transform.rotation, out var dir, out float dist))
                    push += dir * dist;
            }
            if (push != Vector3.zero) position += G.FromU(push);
        }

        const int PROBE_LAYER = 31;
        static CapsuleCollider _probe;
        CapsuleCollider ProbeCapsule()
        {
            if (_probe == null)
            {
                // a shape for ComputePenetration only: parked far away on a layer nothing collides with
                var go = new GameObject("MoverProbe") { hideFlags = HideFlags.HideAndDontSave, layer = PROBE_LAYER };
                go.transform.position = new Vector3(0f, -100000f, 0f);
                for (int l = 0; l < 32; l++) Physics.IgnoreLayerCollision(PROBE_LAYER, l, true);
                _probe = go.AddComponent<CapsuleCollider>();
            }
            _probe.radius = radius;
            _probe.height = height;
            _probe.direction = 1;
            return _probe;
        }

        /// <summary>Godot's body_test_motion: would moving by motion hit something? travel is how far it got.</summary>
        public bool TestMotion(Vector3 from, Vector3 motion, out GHit hit, out Vector3 travel)
        {
            travel = motion;
            float len = motion.magnitude;
            hit = default;
            if (len < 1e-6f) return false;
            Vector3 dir = motion / len;
            if (!GPhys.CapsuleCast(A(from), B(from), radius - safeMargin * 0.5f, dir, len + safeMargin, mask, ignore, out hit)) return false;
            travel = dir * Mathf.Max(hit.distance - safeMargin, 0f);
            return true;
        }
    }
}
