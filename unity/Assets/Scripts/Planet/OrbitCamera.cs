// Milestone-0 mayor camera: orbits a focus point on the ball. Right-drag or Q/E turns,
// middle-drag or R/F tilts, wheel zooms, WASD / left-drag pans. The full port of
// scripts/mayor_camera.gd replaces it in milestone 1.
using UnityEngine;

namespace MSP
{
    public class OrbitCamera : MonoBehaviour
    {
        public Vector3 focus;      // flat map metres (Godot space)
        public float distance = 230f;
        public float yaw;          // radians, 0 looks north
        public float tilt = -0.5f; // radians below the horizon of the focus
        public Camera cam;

        Vector3 _lastMouse;

        void Awake()
        {
            cam = gameObject.AddComponent<Camera>();
            cam.nearClipPlane = 0.3f;
            cam.farClipPlane = 6000f;
            cam.fieldOfView = 50f;
            cam.clearFlags = CameraClearFlags.SolidColor;
            cam.backgroundColor = new Color(0.02f, 0.03f, 0.06f);
            gameObject.AddComponent<AudioListener>();
        }

        public void SetView(Vector3 f, float dist, float yawRad, float tiltRad)
        {
            focus = f;
            distance = dist;
            yaw = yawRad;
            tilt = tiltRad == 0f ? -0.6f : tiltRad;
            Apply();
        }

        void Update()
        {
            float dt = Time.unscaledDeltaTime;
            Vector3 m = Input.mousePosition;
            Vector3 dm = m - _lastMouse;
            _lastMouse = m;
            if (Input.GetMouseButton(1)) yaw -= dm.x * 0.005f;
            if (Input.GetMouseButton(2)) tilt = Mathf.Clamp(tilt - dm.y * 0.005f, -1.5f, -0.05f);
            if (Input.GetKey(KeyCode.Q)) yaw += dt;
            if (Input.GetKey(KeyCode.E)) yaw -= dt;
            if (Input.GetKey(KeyCode.R)) tilt = Mathf.Clamp(tilt - dt, -1.5f, -0.05f);
            if (Input.GetKey(KeyCode.F)) tilt = Mathf.Clamp(tilt + dt, -1.5f, -0.05f);
            float wheel = Input.mouseScrollDelta.y;
            if (wheel != 0f) distance = Mathf.Clamp(distance * Mathf.Pow(0.88f, wheel), 20f, 2400f);
            Vector2 pan = Vector2.zero;
            if (Input.GetKey(KeyCode.W)) pan.y -= 1f;
            if (Input.GetKey(KeyCode.S)) pan.y += 1f;
            if (Input.GetKey(KeyCode.A)) pan.x -= 1f;
            if (Input.GetKey(KeyCode.D)) pan.x += 1f;
            pan *= distance * 0.8f * dt;
            if (Input.GetMouseButton(0)) pan += new Vector2(-dm.x, dm.y) * distance * 0.0015f;
            if (pan != Vector2.zero)
            {
                // pan in the camera's heading: x right, y toward the camera (south when yaw is 0)
                float c = Mathf.Cos(yaw), s = Mathf.Sin(yaw);
                focus.x = Planet.WrapX(focus.x + pan.x * c + pan.y * s);
                focus.z = Mathf.Clamp(focus.z - pan.x * s + pan.y * c, -300f, Planet.H * Planet.TILE + 200f);
            }
            Apply();
        }

        void Apply()
        {
            // offset from the focus in its local frame (x east, y up, z south), Godot space
            float ct = Mathf.Cos(-tilt);
            Vector3 off = new Vector3(Mathf.Sin(yaw) * ct, Mathf.Sin(-tilt), Mathf.Cos(yaw) * ct) * distance;
            var f = Planet.Frame(focus);
            Vector3 target = Planet.Warp(focus);
            Vector3 eye = target + f * off;
            var b = GBasis.LookingAt(target - eye, f.y);
            transform.position = G.U(eye);
            transform.rotation = G.CameraRot(b);
        }
    }
}
