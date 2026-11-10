// Port of scripts/mayor_camera.gd. Mayor view: orbit, tilt, zoom toward the cursor, pan with
// keys or by dragging. focus, panning and GroundPoint() are in flat map metres (Godot space);
// on the planet the camera is stood up on the ball over the focus and can pull back far
// enough to see the globe.
using System;
using UnityEngine;

namespace MSP
{
    public class MayorCamera : MonoBehaviour
    {
        public const float MIN_DIST = 25f;
        public const float MAX_DIST = 900f;
        public const float PLANET_MAX_DIST = 2600f;

        public event Action<float> Moved;

        public Camera cam;
        public Vector3 focus = new Vector3(480, 0, 480);
        public float yaw = -35f * Mathf.Deg2Rad;
        public float tilt;
        public float dist = 320f;
        public Rect bounds = new Rect(0, 0, 960, 960);
        public float autoOrbit;  // radians per second, used on the title screen
        public bool inputEnabled = true;

        Vector3 _focusGoal;
        float _yawGoal, _tiltGoal, _distGoal;
        bool _rotating, _panning;
        Vector3 _panAnchor;
        Vector3 _lastMouse;

        /// <summary>The camera's eye in Godot space.</summary>
        public Vector3 Eye => G.FromU(transform.position);
        /// <summary>The camera as a Godot-space transform (-Z forward), as Apply() last placed it.</summary>
        public GXform GodotXf = GXform.Identity;

        void Awake()
        {
            // no ?? on UnityEngine.Object: a missing component can be a fake null in the editor
            cam = gameObject.GetComponent<Camera>();
            if (cam == null) cam = gameObject.AddComponent<Camera>();
            // Camera.main (CityView's culling and full-detail chunks) finds only the MainCamera tag
            gameObject.tag = "MainCamera";
            cam.fieldOfView = 45f;
            cam.nearClipPlane = 0.5f;
            cam.farClipPlane = 6000f;
            cam.clearFlags = CameraClearFlags.Skybox;
            if (GetComponent<AudioListener>() == null) gameObject.AddComponent<AudioListener>();
            _focusGoal = focus;
            _yawGoal = yaw;
            _tiltGoal = tilt;
            _distGoal = dist;
        }

        public void SetView(Vector3 f, float d, float y, float t = 0f)
        {
            focus = _focusGoal = f;
            dist = _distGoal = d;
            yaw = _yawGoal = y;
            tilt = _tiltGoal = t;
            Apply();
        }

        /// <summary>Ease over to a new framing; Update does the move.</summary>
        public void GlideTo(Vector3 f, float d, float y)
        {
            _focusGoal = f;
            _distGoal = d;
            _yawGoal = yaw + G.AngleDiff(yaw, y);
        }

        /// <summary>Low and cinematic up close, more top-down when zoomed out.</summary>
        public float PitchFor(float d)
        {
            float k = Mathf.Clamp01(Mathf.InverseLerp(MIN_DIST, 600f, d));
            float p = Mathf.Deg2Rad * Mathf.Lerp(22f, 58f, Mathf.Sqrt(k)) + tilt;
            if (Planet.on) p = Mathf.Lerp(p, 84f * Mathf.Deg2Rad, G.Smoothstep(700f, 1800f, d));
            return p;
        }

        public float MaxDist() => Planet.on ? PLANET_MAX_DIST : MAX_DIST;

        static Vector3 Toward(Vector3 from, Vector3 to)
        {
            Vector3 d = to - from;
            if (Planet.on) d.x = Planet.Dx(from.x, to.x);
            return d;
        }

        /// <summary>Flat map point under a screen position (Unity screen coords), or false.</summary>
        public bool GroundPoint(Vector2 screen, out Vector3 flat)
        {
            flat = Vector3.zero;
            Ray r = cam.ScreenPointToRay(screen);
            Vector3 o = G.FromU(r.origin), d = G.FromU(r.direction);
            if (Planet.on)
            {
                if (!Planet.RayHit(o, d, out Vector3 hit)) return false;
                flat = Vector3.Scale(Planet.Unwarp(hit), new Vector3(1, 0, 1));
                return true;
            }
            if (Mathf.Abs(d.y) < 1e-4f) return false;
            float t = -o.y / d.y;
            if (t < 0f) return false;
            flat = o + d * t;
            return true;
        }

        public bool IsDragging() => _rotating || _panning;

        void HandleMouse()
        {
            Vector3 m = Input.mousePosition;
            Vector3 rel = m - _lastMouse;
            _lastMouse = m;
            rel.y = -rel.y; // Godot's mouse y runs down the screen
            float wheel = Input.mouseScrollDelta.y;
            if (wheel != 0f && !UIBlocks.PointerOverUI)
            {
                bool zoomIn = wheel > 0f;
                float k = zoomIn ? 0.85f : 1f / 0.85f;
                float newDist = Mathf.Clamp(_distGoal * k, MIN_DIST, MaxDist());
                if (zoomIn && GroundPoint(m, out Vector3 gp))
                {
                    float frac = 1f - newDist / _distGoal;
                    _focusGoal += Toward(_focusGoal, gp) * frac;
                }
                _distGoal = newDist;
            }
            if (Input.GetMouseButtonDown(1)) _rotating = true;
            if (Input.GetMouseButtonUp(1)) _rotating = false;
            if (Input.GetMouseButtonDown(2))
            {
                _panning = true;
                _panAnchor = GroundPoint(m, out Vector3 gp) ? gp : focus;
            }
            if (Input.GetMouseButtonUp(2)) _panning = false;
            if (_rotating)
            {
                _yawGoal -= rel.x * 0.006f;
                _tiltGoal = Mathf.Clamp(_tiltGoal + rel.y * 0.004f, -0.35f, 0.5f);
            }
            else if (_panning && rel != Vector3.zero && GroundPoint(m, out Vector3 gp2))
            {
                Vector3 step = Toward(gp2, _panAnchor);
                _focusGoal += step;
                focus += step;
                Apply();
            }
        }

        void Update()
        {
            float delta = Time.unscaledDeltaTime;
            if (inputEnabled)
            {
                HandleMouse();
                Vector2 move = Vector2.zero;
                bool ctrl = Input.GetKey(KeyCode.LeftControl) || Input.GetKey(KeyCode.RightControl);
                if (!ctrl)
                {
                    if (Input.GetKey(KeyCode.W) || Input.GetKey(KeyCode.UpArrow)) move.y -= 1;
                    if (Input.GetKey(KeyCode.S) || Input.GetKey(KeyCode.DownArrow)) move.y += 1;
                    if (Input.GetKey(KeyCode.A) || Input.GetKey(KeyCode.LeftArrow)) move.x -= 1;
                    if (Input.GetKey(KeyCode.D) || Input.GetKey(KeyCode.RightArrow)) move.x += 1;
                    if (Input.GetKey(KeyCode.Q)) _yawGoal += delta * 1.5f;
                    if (Input.GetKey(KeyCode.E)) _yawGoal -= delta * 1.5f;
                }
                if (Input.GetKey(KeyCode.PageUp)) _distGoal = Mathf.Max(_distGoal * (1f - delta * 1.5f), MIN_DIST);
                if (Input.GetKey(KeyCode.PageDown)) _distGoal = Mathf.Min(_distGoal * (1f + delta * 1.5f), MaxDist());
                if (move != Vector2.zero)
                {
                    bool shift = Input.GetKey(KeyCode.LeftShift) || Input.GetKey(KeyCode.RightShift);
                    float speed = _distGoal * 1.1f * (shift ? 2.5f : 1f);
                    Vector3 fwd = new Vector3(-Mathf.Sin(_yawGoal), 0, -Mathf.Cos(_yawGoal));
                    Vector3 right = new Vector3(Mathf.Cos(_yawGoal), 0, -Mathf.Sin(_yawGoal));
                    _focusGoal += (right * move.x - fwd * move.y) * speed * delta;
                }
            }
            _yawGoal += autoOrbit * delta;
            if (!Planet.on) _focusGoal.x = Mathf.Clamp(_focusGoal.x, bounds.xMin, bounds.xMax);
            _focusGoal.z = Mathf.Clamp(_focusGoal.z, bounds.yMin, bounds.yMax);
            float k = 1f - Mathf.Exp(-delta * 10f);
            if (Planet.on)
            {
                // the short way round the seam, then keep focus in 0..circumference
                Vector3 step = Toward(focus, _focusGoal) * k;
                focus += step;
                float wrapped = Planet.WrapX(focus.x);
                _focusGoal.x += wrapped - focus.x;
                focus.x = wrapped;
            }
            else focus = Vector3.Lerp(focus, _focusGoal, k);
            yaw = Mathf.Lerp(yaw, _yawGoal, k);
            tilt = Mathf.Lerp(tilt, _tiltGoal, k);
            dist = Mathf.Lerp(dist, _distGoal, 1f - Mathf.Exp(-delta * 8f));
            Apply();
        }

        public void Apply()
        {
            float p = Mathf.Clamp(PitchFor(dist), 8f * Mathf.Deg2Rad, 85f * Mathf.Deg2Rad);
            Vector3 offset = new Vector3(Mathf.Sin(yaw) * Mathf.Cos(p), Mathf.Sin(p), Mathf.Cos(yaw) * Mathf.Cos(p)) * dist;
            Vector3 eye, target, up;
            if (Planet.on)
            {
                var q = Planet.Frame(focus);
                target = Planet.Warp(focus);
                eye = target + q * offset;
                up = q.y;
            }
            else
            {
                target = focus;
                eye = focus + offset;
                up = Vector3.up;
            }
            GodotXf = new GXform(GBasis.LookingAt(target - eye, up), eye);
            transform.position = G.U(eye);
            transform.rotation = G.CameraRot(GodotXf.basis);
            Moved?.Invoke(dist);
        }
    }

    /// <summary>Whether the pointer is over a HUD panel (set by the HUD), so the world ignores the click.</summary>
    public static class UIBlocks
    {
        public static bool PointerOverUI;
    }
}
