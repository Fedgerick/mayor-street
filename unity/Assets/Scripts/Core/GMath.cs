// Godot-style maths for the port.
//
// msp's game logic is written in Godot's right-handed space (x east, y up, z south on the
// flat map; cameras and bodies look down -Z). The port keeps all of that logic in the same
// space, with these Godot-like types, so the GDScript translates line for line. Only at the
// edge, where a value is written to a Unity Transform, it is mirrored across X (G.U(...)):
// Unity is left-handed, and a mirror is exactly what glTFast applies to the imported .glb
// models, so meshes, positions and rotations all stay consistent.
using UnityEngine;

namespace MSP
{
    /// <summary>3x3 rotation/scale in Godot's convention: columns are the local x, y, z axes.</summary>
    public struct GBasis
    {
        public Vector3 x, y, z;

        public GBasis(Vector3 x, Vector3 y, Vector3 z) { this.x = x; this.y = y; this.z = z; }

        public static readonly GBasis Identity = new GBasis(Vector3.right, Vector3.up, Vector3.forward);

        public static GBasis Rotation(Vector3 axis, float angle)
        {
            var q = Quaternion.AngleAxis(angle * Mathf.Rad2Deg, axis.normalized);
            // Unity's AngleAxis in a right-handed reading equals Godot's for the same numbers:
            // both build the standard rotation matrix from axis and angle.
            return FromQuat(q);
        }

        public static GBasis FromQuat(Quaternion q)
        {
            return new GBasis(q * Vector3.right, q * Vector3.up, q * Vector3.forward);
        }

        public static GBasis Scaled(Vector3 s) => new GBasis(new Vector3(s.x, 0, 0), new Vector3(0, s.y, 0), new Vector3(0, 0, s.z));

        /// <summary>Godot Basis.from_euler with the default YXZ order.</summary>
        public static GBasis FromEuler(Vector3 e)
        {
            return Rotation(Vector3.up, e.y) * Rotation(Vector3.right, e.x) * Rotation(Vector3.forward, e.z);
        }

        public Vector3 Mul(Vector3 v) => x * v.x + y * v.y + z * v.z;

        public static Vector3 operator *(GBasis b, Vector3 v) => b.Mul(v);
        public static GBasis operator *(GBasis a, GBasis b) => new GBasis(a.Mul(b.x), a.Mul(b.y), a.Mul(b.z));

        public GBasis Transposed()
        {
            return new GBasis(new Vector3(x.x, y.x, z.x), new Vector3(x.y, y.y, z.y), new Vector3(x.z, y.z, z.z));
        }

        public float Determinant() => Vector3.Dot(x, Vector3.Cross(y, z));

        public GBasis Inverse()
        {
            float det = Determinant();
            if (Mathf.Abs(det) < 1e-12f) return Identity;
            // rows of the inverse are cross products of the columns
            Vector3 r0 = Vector3.Cross(y, z) / det;
            Vector3 r1 = Vector3.Cross(z, x) / det;
            Vector3 r2 = Vector3.Cross(x, y) / det;
            return new GBasis(r0, r1, r2).Transposed();
        }

        public Vector3 Scale => new Vector3(x.magnitude, y.magnitude, z.magnitude);

        public GBasis Orthonormalized()
        {
            Vector3 nx = x.normalized;
            Vector3 ny = (y - nx * Vector3.Dot(nx, y)).normalized;
            Vector3 nz = (z - nx * Vector3.Dot(nx, z) - ny * Vector3.Dot(ny, z)).normalized;
            return new GBasis(nx, ny, nz);
        }

        /// <summary>Rotation part as a quaternion (Godot space).</summary>
        public Quaternion Quat()
        {
            var o = Orthonormalized();
            if (o.Determinant() < 0) o.z = -o.z;
            return Quaternion.LookRotation(o.z, o.y);
        }

        /// <summary>Godot's Basis.looking_at: -Z points at target direction.</summary>
        public static GBasis LookingAt(Vector3 target, Vector3 up)
        {
            Vector3 vz = (-target).normalized;
            Vector3 vx = Vector3.Cross(up, vz);
            if (vx.sqrMagnitude < 1e-10f) vx = Vector3.Cross(Vector3.forward, vz);
            vx.Normalize();
            Vector3 vy = Vector3.Cross(vz, vx);
            return new GBasis(vx, vy, vz);
        }
    }

    /// <summary>Godot Transform3D.</summary>
    public struct GXform
    {
        public GBasis basis;
        public Vector3 origin;

        public GXform(GBasis b, Vector3 o) { basis = b; origin = o; }

        public static readonly GXform Identity = new GXform(GBasis.Identity, Vector3.zero);

        public static GXform At(Vector3 o) => new GXform(GBasis.Identity, o);

        public Vector3 Mul(Vector3 v) => basis * v + origin;
        public static Vector3 operator *(GXform t, Vector3 v) => t.Mul(v);
        public static GXform operator *(GXform a, GXform b) => new GXform(a.basis * b.basis, a.Mul(b.origin));

        public GXform Inverse()
        {
            var bi = basis.Inverse();
            return new GXform(bi, bi * -origin);
        }

        public GXform Translated(Vector3 v) => new GXform(basis, origin + v);
        public GXform RotatedLocal(Vector3 axis, float a) => new GXform(basis * GBasis.Rotation(axis, a), origin);
        public GXform ScaledLocal(Vector3 s) => new GXform(basis * GBasis.Scaled(s), origin);

        public GXform LookingAt(Vector3 target, Vector3 up) => new GXform(GBasis.LookingAt(target - origin, up), origin);
    }

    /// <summary>The Godot-space to Unity-space edge (mirror across X) and small GDScript helpers.</summary>
    public static class G
    {
        public const float TAU = Mathf.PI * 2f;

        /// <summary>Godot-space point or direction -> Unity space.</summary>
        public static Vector3 U(Vector3 v) => new Vector3(-v.x, v.y, v.z);

        /// <summary>Unity-space point or direction -> Godot space (the mirror is its own inverse).</summary>
        public static Vector3 FromU(Vector3 v) => new Vector3(-v.x, v.y, v.z);

        /// <summary>A Godot-space rotation -> the same rotation seen in Unity space.</summary>
        public static Quaternion U(Quaternion q) => new Quaternion(q.x, -q.y, -q.z, q.w);

        public static Quaternion FromU(Quaternion q) => new Quaternion(q.x, -q.y, -q.z, q.w);

        /// <summary>Write a Godot-space transform (rotation, scale, origin) to a Unity Transform.
        /// Scale must be along the basis axes (no shear), as msp's transforms always are.</summary>
        public static void Apply(Transform t, GXform x)
        {
            t.position = U(x.origin);
            ApplyBasis(t, x.basis);
        }

        public static void ApplyLocal(Transform t, GXform x)
        {
            t.localPosition = U(x.origin);
            var s = x.basis.Scale;
            var b = x.basis;
            if (b.Determinant() < 0) { s.x = -s.x; b.x = -b.x; }
            t.localRotation = U(b.Quat());
            t.localScale = s;
        }

        public static void ApplyBasis(Transform t, GBasis b)
        {
            var s = b.Scale;
            if (b.Determinant() < 0) { s.x = -s.x; b.x = -b.x; }
            t.rotation = U(b.Quat());
            t.localScale = s;
        }

        /// <summary>A Godot-space transform as a Unity matrix (for Graphics.RenderMeshInstanced).</summary>
        public static Matrix4x4 M(GXform x)
        {
            // conjugate by the mirror: M * T * M, done on the columns directly
            var m = new Matrix4x4();
            Vector3 cx = U(x.basis.x) * -1f; // M * (basis * M e_x) = M * basis * (-e_x)
            Vector3 cy = U(x.basis.y);
            Vector3 cz = U(x.basis.z);
            Vector3 o = U(x.origin);
            m.SetColumn(0, new Vector4(cx.x, cx.y, cx.z, 0));
            m.SetColumn(1, new Vector4(cy.x, cy.y, cy.z, 0));
            m.SetColumn(2, new Vector4(cz.x, cz.y, cz.z, 0));
            m.SetColumn(3, new Vector4(o.x, o.y, o.z, 1));
            return m;
        }

        /// <summary>Read a Unity Transform back as a Godot-space transform.</summary>
        public static GXform Read(Transform t)
        {
            var m = t.localToWorldMatrix;
            Vector3 cx = -FromU(m.GetColumn(0));
            Vector3 cy = FromU(m.GetColumn(1));
            Vector3 cz = FromU(m.GetColumn(2));
            return new GXform(new GBasis(cx, cy, cz), FromU(m.GetColumn(3)));
        }

        /// <summary>A Unity camera looks down its +Z, a Godot camera down -Z: the rotation that puts
        /// a Unity camera where a Godot camera with basis b would look.</summary>
        public static Quaternion CameraRot(GBasis b)
        {
            return Quaternion.LookRotation(U(-b.z), U(b.y));
        }

        public static float Fposmod(float a, float b)
        {
            float r = a % b;
            if (r < 0) r += b;
            return r;
        }

        public static int Posmod(int a, int b)
        {
            int r = a % b;
            if (r < 0) r += b;
            return r;
        }

        public static float MoveToward(float from, float to, float delta)
        {
            return Mathf.Abs(to - from) <= delta ? to : from + Mathf.Sign(to - from) * delta;
        }

        public static float Lerp(float a, float b, float t) => a + (b - a) * t; // unclamped, like GDScript lerp

        public static float LerpAngle(float a, float b, float t)
        {
            float d = Fposmod(b - a + Mathf.PI, TAU) - Mathf.PI;
            return a + d * t;
        }

        public static float AngleDiff(float a, float b) => Fposmod(b - a + Mathf.PI, TAU) - Mathf.PI;

        public static Vector3 Slerp(Vector3 a, Vector3 b, float t) => Vector3.Slerp(a, b, t);

        public static Color Lerp(Color a, Color b, float t) => a + (b - a) * t;

        public static float Smoothstep(float e0, float e1, float x)
        {
            if (Mathf.Approximately(e0, e1)) return x < e0 ? 0f : 1f;
            float t = Mathf.Clamp01((x - e0) / (e1 - e0));
            return t * t * (3f - 2f * t);
        }

        public static float Remap(float v, float i0, float i1, float o0, float o1) => o0 + (o1 - o0) * ((v - i0) / (i1 - i0));
    }
}
