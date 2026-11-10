// Port of player/scripts/orbit_rig.gd: a third-person camera boom that follows a target. It
// doesn't own a camera: StreetCamera reads `Eye` so one camera can glide between rigs (mayor
// view -> character -> car) without cuts. yaw and pitch are in the local frame under the boom:
// on msp that frame stands on the ball, so yaw 0 always looks north. Godot space throughout.
using System;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class OrbitRig
    {
        public float height = 1.6f;
        public float distance = 3.8f;
        public float sideOffset = 0.35f;            // over-the-shoulder
        public float minPitch = -70f * Mathf.Deg2Rad;
        public float maxPitch = 35f * Mathf.Deg2Rad;
        public float mouseSensitivity = 0.0025f;
        public float stickSpeed = 2.6f;
        public float followSharpness = 18f;
        public float recenterSpeed;                  // >0: swing behind the target's heading when idle (cars)
        public float recenterDelay = 1.2f;
        public int collisionMask = Layers.Mask(Layers.WORLD, Layers.CARS);
        public float springRadius = 0.22f, springMargin = 0.15f;

        public Func<Vector3> target;                 // the target's position, Godot space
        public float yaw;
        public float pitch = -12f * Mathf.Deg2Rad;
        public bool inputEnabled;
        public float heading;                        // set by the owner each frame, used by recentering
        public readonly HashSet<Collider> excluded = new HashSet<Collider>();

        public Vector3 position;                     // the boom's pivot, Godot space
        public GBasis basis = GBasis.Identity;
        public GXform Eye;                           // where the camera goes

        float _idle;
        float _boomLength;

        public OrbitRig() { _boomLength = distance; }

        public void Exclude(Collider c) { if (c != null) excluded.Add(c); }
        public void Exclude(IEnumerable<Collider> cs) { foreach (var c in cs) Exclude(c); }
        public void Include(IEnumerable<Collider> cs) { foreach (var c in cs) excluded.Remove(c); }

        public void Snap()
        {
            if (target != null)
            {
                var t = target();
                position = t + Planet.Up(t) * height;
            }
            _boomLength = distance;
            Apply();
        }

        /// <summary>Point the boom the way a given camera faces, for a seamless hand-off.</summary>
        public void LookFrom(GXform t)
        {
            var f = Planet.ToLocal(t.origin, -t.basis.z);
            yaw = Mathf.Atan2(-f.x, -f.z);
        }

        public void Update(float delta)
        {
            if (inputEnabled)
            {
                if (Cursor.lockState == CursorLockMode.Locked)
                {
                    var r = StreetInput.MouseDelta;
                    if (r != Vector2.zero)
                    {
                        yaw -= r.x * mouseSensitivity;
                        pitch = Mathf.Clamp(pitch - r.y * mouseSensitivity, minPitch, maxPitch);
                        _idle = 0f;
                    }
                }
                var st = StreetInput.LookStick();
                if (st != Vector2.zero)
                {
                    yaw -= st.x * stickSpeed * delta;
                    pitch = Mathf.Clamp(pitch - st.y * stickSpeed * 0.7f * delta, minPitch, maxPitch);
                    _idle = 0f;
                }
            }
            _idle += delta;
            if (recenterSpeed > 0f && _idle > recenterDelay)
            {
                yaw = G.LerpAngle(yaw, heading, 1f - Mathf.Exp(-recenterSpeed * delta));
                pitch = Mathf.Lerp(pitch, -12f * Mathf.Deg2Rad, 1f - Mathf.Exp(-recenterSpeed * 0.5f * delta));
            }
            if (target != null)
            {
                var t = target();
                var goal = t + Planet.Up(t) * height;
                position = Vector3.Lerp(position, goal, 1f - Mathf.Exp(-followSharpness * delta));
            }
            _boomLength = Mathf.Lerp(_boomLength, distance, 1f - Mathf.Exp(-4f * delta));
            Apply();
        }

        void Apply()
        {
            // Basis.from_euler(Vector3(pitch, yaw, 0)): Godot's default YXZ order, Ry * Rx
            basis = Planet.Basis(position) * GBasis.Rotation(Vector3.up, yaw) * GBasis.Rotation(Vector3.right, pitch);
            // the SpringArm3D sits side_offset to the right and extends along the boom's +Z
            Vector3 springPos = position + basis.x * sideOffset;
            Vector3 dir = basis.z;
            float len = SpringWithExclusions(springPos, dir, _boomLength);
            Eye = new GXform(basis, springPos + dir * len);
        }

        float SpringWithExclusions(Vector3 from, Vector3 dir, float len)
        {
            var hits = Physics.SphereCastAll(G.U(from), springRadius, G.U(dir), len, collisionMask, QueryTriggerInteraction.Ignore);
            float best = len;
            foreach (var h in hits)
            {
                if (excluded.Contains(h.collider) || (h.distance <= 0f && h.point == Vector3.zero)) continue;
                best = Mathf.Min(best, Mathf.Max(h.distance - springMargin, 0f));
            }
            return best;
        }

        /// <summary>Along the ground, in world space (tangent to the ball on msp).</summary>
        public Vector3 ForwardFlat() => Planet.Dir(position, new Vector3(-Mathf.Sin(yaw), 0f, -Mathf.Cos(yaw)));
        public Vector3 RightFlat() => Planet.Dir(position, new Vector3(Mathf.Cos(yaw), 0f, -Mathf.Sin(yaw)));
    }
}
