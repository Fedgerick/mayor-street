// Port of player/scripts/street_input.gd: the street-level controls, keyboard + mouse and a
// standard gamepad (through Unity's default "Horizontal"/"Vertical" axes and joystick buttons).
using UnityEngine;

namespace MSP
{
    public static class StreetInput
    {
        static bool Any(params KeyCode[] keys)
        {
            foreach (var k in keys) if (Input.GetKey(k)) return true;
            return false;
        }

        static bool AnyDown(params KeyCode[] keys)
        {
            foreach (var k in keys) if (Input.GetKeyDown(k)) return true;
            return false;
        }

        static float Axis(string name)
        {
            try { return Input.GetAxisRaw(name); } catch { return 0f; }
        }

        /// <summary>x = right, y = forward. Length is at most 1.</summary>
        public static Vector2 MoveVector()
        {
            float x = (Any(KeyCode.D, KeyCode.RightArrow) ? 1f : 0f) - (Any(KeyCode.A, KeyCode.LeftArrow) ? 1f : 0f);
            float y = (Any(KeyCode.W, KeyCode.UpArrow) ? 1f : 0f) - (Any(KeyCode.S, KeyCode.DownArrow) ? 1f : 0f);
            var v = new Vector2(x, y);
            if (v == Vector2.zero)
            {
                var j = new Vector2(Axis("Horizontal"), Axis("Vertical"));
                if (j.magnitude > 0.2f) v = j;
            }
            return Vector2.ClampMagnitude(v, 1f);
        }

        public static bool Sprint => Any(KeyCode.LeftShift, KeyCode.RightShift, KeyCode.JoystickButton8);
        public static bool JumpPressed => AnyDown(KeyCode.Space, KeyCode.JoystickButton0);
        public static bool Handbrake => Any(KeyCode.Space, KeyCode.JoystickButton0);
        public static bool InteractPressed => AnyDown(KeyCode.E, KeyCode.F, KeyCode.JoystickButton3);
        public static bool ToggleViewPressed => AnyDown(KeyCode.Tab, KeyCode.JoystickButton6);
        public static bool ResetPressed => AnyDown(KeyCode.R, KeyCode.JoystickButton2);
        public static bool HornHeld => Any(KeyCode.H, KeyCode.JoystickButton4);
        public static bool LightsPressed => AnyDown(KeyCode.L);
        public static float Throttle => Any(KeyCode.W, KeyCode.UpArrow) ? 1f : Mathf.Max(Axis("Vertical"), 0f);
        public static float Brake => Any(KeyCode.S, KeyCode.DownArrow) ? 1f : Mathf.Max(-Axis("Vertical"), 0f);

        /// <summary>Mouse motion this frame in pixels, y down, as Godot's InputEventMouseMotion.relative.
        /// The Input Manager's "Mouse X/Y" axes are the delta x 0.1 and keep working with the
        /// cursor locked (mousePosition doesn't).</summary>
        public static Vector2 MouseDelta => new Vector2(Axis("Mouse X") * 10f, -Axis("Mouse Y") * 10f);

        public static Vector2 LookStick() => Vector2.zero;  // a right stick needs axes in the Input Manager; not mapped
    }
}
