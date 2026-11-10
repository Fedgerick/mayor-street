// Port of player/scripts/street_camera.gd: the street-level camera. It follows an OrbitRig,
// glides between rigs (on foot <-> car), and flies the signature zoom: from the mayor view down
// to the character on the sidewalk, and back up, with no cut. Altitude eases in log space so it
// reads as one continuous dive. Drives the one Unity camera (the mayor camera's) while active.
using System;
using UnityEngine;

namespace MSP
{
    public class StreetCamera
    {
        public event Action FlightFinished;
        public enum Mode { IDLE, FOLLOW, FLY, BLEND }

        public float streetFov = 68f;
        public float speedFov = 14f;
        public Mode mode = Mode.IDLE;
        public OrbitRig rig;
        public float fovBoost;      // 0..1, set by StreetMode from speed
        public float lean;          // radians of roll, set by StreetMode in corners

        public Camera cam;
        public GXform xf;           // Godot-space camera transform (-Z forward)
        public float fov = 45f;

        float _t, _dur = 1f;
        GXform _from, _toXf;
        float _fromFov = 45f, _toFov = 45f;
        Vector3 _fromFocus;
        OrbitRig _toRig;
        float _shake, _lean, _nt;
        readonly float _seed = UnityEngine.Random.value * 100f;

        public StreetCamera(Camera c) { cam = c; }

        public void Follow(OrbitRig r) { rig = r; mode = Mode.FOLLOW; }

        /// <summary>Short glide between two rigs (getting in or out of a car).</summary>
        public void BlendTo(OrbitRig r, float duration = 0.6f)
        {
            _from = xf;
            _fromFov = fov;
            _toRig = r;
            _t = 0f;
            _dur = Mathf.Max(duration, 0.01f);
            mode = Mode.BLEND;
        }

        /// <summary>The mayor -> street zoom. from is the mayor camera's transform.</summary>
        public void DiveTo(OrbitRig r, GXform from, float fromFov, float duration = 3.2f)
        {
            xf = from;
            fov = fromFov;
            StartFlight(from, fromFov, duration);
            _toRig = r;
            _toFov = streetFov;
        }

        /// <summary>The street -> mayor zoom. The caller takes the camera back on FlightFinished.</summary>
        public void RiseTo(GXform to, float toFov, float duration = 2.6f)
        {
            StartFlight(xf, fov, duration);
            _toRig = null;
            _toXf = to;
            _toFov = toFov;
        }

        /// <summary>Adds trauma: 0.2 a light knock, 0.5 a punch or a pistol, 1+ a blast.</summary>
        public void Shake(float amount) => _shake = Mathf.Min(Mathf.Max(_shake, amount) + amount * 0.25f, 1.5f);

        void StartFlight(GXform from, float fromFov, float duration)
        {
            _from = from;
            _fromFov = fromFov;
            // Where the start camera looks, on the ground plane (flat map metres on msp).
            var f = Planet.FlatXform(from);
            Vector3 d = -f.basis.z;
            float t = d.y < -0.01f ? -f.origin.y / d.y : 100f;
            _fromFocus = f.origin + d * Mathf.Clamp(t, 1f, 3000f);
            _t = 0f;
            _dur = duration;
            mode = Mode.FLY;
        }

        GXform TargetXf() => _toRig != null ? _toRig.Eye : _toXf;

        public void Update(float delta)
        {
            switch (mode)
            {
                case Mode.FOLLOW:
                    if (rig != null)
                    {
                        xf = rig.Eye;
                        fov = Mathf.Lerp(fov, streetFov + speedFov * fovBoost, 1f - Mathf.Exp(-4f * delta));
                    }
                    break;
                case Mode.BLEND:
                {
                    _t += delta / _dur;
                    float e = Smooth(Mathf.Clamp01(_t));
                    xf = Interpolate(_from, _toRig.Eye, e);
                    fov = Mathf.Lerp(_fromFov, streetFov + speedFov * fovBoost, e);
                    if (_t >= 1f) Follow(_toRig);
                    break;
                }
                case Mode.FLY:
                {
                    _t += delta / _dur;
                    float k = Mathf.Clamp01(_t);
                    xf = FlyXf(k);
                    fov = Mathf.Lerp(_fromFov, _toFov, Smooth(k));
                    if (_t >= 1f)
                    {
                        if (_toRig != null) Follow(_toRig);
                        else mode = Mode.IDLE;
                        FlightFinished?.Invoke();
                    }
                    break;
                }
            }
            _lean = Mathf.Lerp(_lean, mode == Mode.FOLLOW ? lean : 0f, 1f - Mathf.Exp(-3f * delta));
            float roll = _lean, h = 0f, v = 0f;
            if (_shake > 0f)
            {
                _shake = Mathf.Max(_shake - delta * 1.6f, 0f);
                _nt += delta * (18f + 10f * _shake);
                float j = _shake * _shake;
                h = Noise(_nt, 0f) * j * 0.09f;
                v = Noise(0f, _nt) * j * 0.09f;
                roll += Noise(_nt, 50f) * j * 0.03f;
            }
            if (mode == Mode.IDLE || cam == null) return;
            var b = xf.basis;
            if (Mathf.Abs(roll) > 0.0001f) b = b * GBasis.Rotation(Vector3.forward, roll);  // rotate_object_local(FORWARD)
            Vector3 eye = xf.origin + b.x * h + b.y * v;
            cam.transform.position = G.U(eye);
            cam.transform.rotation = G.CameraRot(b);
            cam.fieldOfView = fov;
        }

        float Noise(float x, float y) => Mathf.PerlinNoise(x + _seed, y + _seed) * 2f - 1f;

        static GXform Interpolate(GXform a, GXform b, float t)
        {
            var q = Quaternion.Slerp(a.basis.Quat(), b.basis.Quat(), t);
            return new GXform(GBasis.FromQuat(q), Vector3.Lerp(a.origin, b.origin, t));
        }

        GXform FlyXf(float k)
        {
            var to = Planet.FlatXform(TargetXf());
            var from = Planet.FlatXform(_from);
            Vector3 a = from.origin, b = to.origin;
            if (Planet.on)
            {
                b.x = a.x + Planet.Dx(a.x, b.x);
                to.origin = b;
            }
            bool diving = _toRig != null;
            float eH = Smooth(k);
            float ha = Mathf.Max(a.y, 0.5f), hb = Mathf.Max(b.y, 0.5f);
            float hgt = Mathf.Exp(Mathf.Lerp(Mathf.Log(ha), Mathf.Log(hb), eH));
            float eXZ = diving ? EaseOut(k) : EaseIn(k);
            var p = new Vector3(Mathf.Lerp(a.x, b.x, eXZ), hgt, Mathf.Lerp(a.z, b.z, eXZ));
            Vector3 toFocus = b + (-to.basis.z) * 12f;
            float eLook = diving ? Smooth(Mathf.Clamp01(k * 1.25f)) : Smooth(k);
            Vector3 focus = Vector3.Lerp(_fromFocus, toFocus, eLook);
            Vector3 dir = focus - p;
            var basis = GBasis.LookingAt(dir.magnitude > 0.01f ? dir.normalized : -to.basis.z, Vector3.up);
            float settle = Smooth(Mathf.Clamp01((k - 0.8f) / 0.2f));
            if (settle > 0f) basis = GBasis.FromQuat(Quaternion.Slerp(basis.Quat(), to.basis.Orthonormalized().Quat(), settle));
            p = Vector3.Lerp(p, b, settle);
            return Planet.XfRigid(new GXform(basis, p));
        }

        static float Smooth(float x) => x * x * x * (x * (x * 6f - 15f) + 10f);
        static float EaseOut(float x) => 1f - Mathf.Pow(1f - x, 2.4f);
        static float EaseIn(float x) => x * x;
    }
}
