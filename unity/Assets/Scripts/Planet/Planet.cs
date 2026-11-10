// Port of planet/planet.gd. All values are in Godot space (see GMath.cs).
//
// The ball the city lives on. Everything else keeps thinking in flat map metres:
// x runs east (wrapping all the way round), z runs south across the buildable belt,
// y is height above sea level. Planet turns those into points and frames on the sphere
// and back again.
using UnityEngine;

namespace MSP
{
    public static class Planet
    {
        public const float TILE = 12f;

        public static bool on = false;
        public static int W = 192;
        public static int H = 36;
        public static float R = 192 * TILE / G.TAU;
        public static float V0 = 36 * TILE * 0.5f;

        public static void Configure(int cols, int rows)
        {
            on = true;
            W = cols;
            H = rows;
            R = W * TILE / G.TAU;
            V0 = H * TILE * 0.5f;
            Shader.SetGlobalFloat("planet_radius", R);
            Shader.SetGlobalFloat("planet_v0", V0);
        }

        public static float Circumference() => W * TILE;

        // ----------------------------------------------- identity on the flat island ---

        public static Vector3 Place(Vector3 p) => on ? Warp(p) : p;
        public static Vector3 Flat(Vector3 w) => on ? Unwarp(w) : w;
        public static GXform Xf(GXform t) => on ? WarpXform(t) : t;
        public static GXform XfRigid(GXform t) => on ? new GXform(Frame(t.origin) * t.basis, Warp(t.origin)) : t;
        public static Vector3 Up(Vector3 w) => on ? UpAt(w) : Vector3.up;
        public static GBasis Basis(Vector3 w) => on ? FrameWorld(w) : GBasis.Identity;
        public static Vector3 Dir(Vector3 w, Vector3 d) => on ? FrameWorld(w) * d : d;
        public static Vector3 ToLocal(Vector3 w, Vector3 d) => on ? FrameWorld(w).Inverse() * d : d;

        // --------------------------------------------------------------- the ball ---

        public static float LatOf(Vector3 p) => (V0 - p.z) / R;
        public static float LonOf(Vector3 p) => p.x / R;

        public static Vector3 DirAt(float lat, float lon)
        {
            float c = Mathf.Cos(lat);
            return new Vector3(c * Mathf.Sin(lon), Mathf.Sin(lat), c * Mathf.Cos(lon));
        }

        public static Vector3 Warp(Vector3 p) => DirAt(LatOf(p), LonOf(p)) * (R + p.y);

        public static Vector3 Unwarp(Vector3 w)
        {
            float r = w.magnitude;
            if (r < 0.001f) return Vector3.zero;
            float lat = Mathf.Asin(Mathf.Clamp(w.y / r, -1f, 1f));
            float lon = G.Fposmod(Mathf.Atan2(w.x, w.z), G.TAU);
            return new Vector3(lon * R, r - R, V0 - lat * R);
        }

        public static GBasis Frame(Vector3 p) => FrameAt(LatOf(p), LonOf(p));

        public static GBasis FrameAt(float lat, float lon)
        {
            Vector3 up = DirAt(lat, lon);
            Vector3 east = new Vector3(Mathf.Cos(lon), 0f, -Mathf.Sin(lon));
            Vector3 south = Vector3.Cross(east, up);
            return new GBasis(east, up, south);
        }

        public static GBasis FrameWorld(Vector3 w)
        {
            float r = w.magnitude;
            if (r < 0.001f) return GBasis.Identity;
            float lat = Mathf.Asin(Mathf.Clamp(w.y / r, -1f, 1f));
            float lon = Mathf.Atan2(w.x, w.z);
            return FrameAt(lat, lon);
        }

        public static Vector3 UpAt(Vector3 w) => w.magnitude > 0.001f ? w.normalized : Vector3.up;

        public static GXform WarpXform(GXform xf)
        {
            float lat = LatOf(xf.origin);
            var f = FrameAt(lat, LonOf(xf.origin));
            f.x *= Mathf.Cos(lat);
            return new GXform(f * xf.basis, Warp(xf.origin));
        }

        public static float WrapX(float x) => G.Fposmod(x, W * TILE);

        public static float Dx(float a, float b)
        {
            float c = W * TILE;
            return G.Fposmod(b - a + c * 0.5f, c) - c * 0.5f;
        }

        /// <summary>Where a ray meets the ball at height h; false if it misses.</summary>
        public static bool RayHit(Vector3 from, Vector3 dir, out Vector3 hit, float h = 0f)
        {
            hit = Vector3.zero;
            float r = R + h;
            float b = Vector3.Dot(from, dir);
            float c = from.sqrMagnitude - r * r;
            float disc = b * b - c;
            if (disc < 0f) return false;
            float t = -b - Mathf.Sqrt(disc);
            if (t < 0f)
            {
                t = -b + Mathf.Sqrt(disc);
                if (t < 0f) return false;
            }
            hit = from + dir * t;
            return true;
        }

        public static bool AboveHorizon(Vector3 eye, Vector3 w, float top)
        {
            float he = Mathf.Max(eye.magnitude - R, 0.5f);
            float reach = Mathf.Acos(Mathf.Clamp(R / (R + he), -1f, 1f)) + Mathf.Acos(Mathf.Clamp(R / (R + Mathf.Max(top, 0.5f)), -1f, 1f));
            return Vector3.Angle(eye.normalized, w.normalized) * Mathf.Deg2Rad < reach;
        }

        /// <summary>A sheet over the whole belt at height h, one quad per tile, UVs 0..1 across the
        /// map (u east, v south). Vertices are written in Unity space, ready to draw.</summary>
        public static Mesh BeltMesh(float h, int perTile = 1)
        {
            int cols = W * perTile;
            int rows = H * perTile;
            float step = TILE / perTile;
            var verts = new Vector3[(cols + 1) * (rows + 1)];
            var norms = new Vector3[verts.Length];
            var uvs = new Vector2[verts.Length];
            int k = 0;
            for (int j = 0; j <= rows; j++)
                for (int i = 0; i <= cols; i++)
                {
                    Vector3 w = Warp(new Vector3(i * step, h, j * step));
                    verts[k] = G.U(w);
                    norms[k] = G.U(w.normalized);
                    uvs[k] = new Vector2((float)i / cols, (float)j / rows);
                    k++;
                }
            var idx = new int[cols * rows * 6];
            k = 0;
            for (int j = 0; j < rows; j++)
                for (int i = 0; i < cols; i++)
                {
                    int a = j * (cols + 1) + i;
                    int b = a + cols + 1;
                    // Godot winds a, a+1, b; the mirror flips handedness, so reverse each triangle
                    idx[k++] = a; idx[k++] = b; idx[k++] = a + 1;
                    idx[k++] = a + 1; idx[k++] = b; idx[k++] = b + 1;
                }
            var m = new Mesh { indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
            m.vertices = verts;
            m.normals = norms;
            m.uv = uvs;
            m.triangles = idx;
            m.RecalculateBounds();
            return m;
        }

        public static GXform FlatXform(GXform t) => on ? new GXform(FrameWorld(t.origin).Inverse() * t.basis, Unwarp(t.origin)) : t;

        public static float Fdx(float a, float b) => on ? Dx(a, b) : b - a;

        public static float Fdist(Vector3 a, Vector3 b) => new Vector2(Fdx(a.x, b.x), b.z - a.z).magnitude;

        /// <summary>Gravity at a Godot-space world point: 9.8 toward the centre on the ball.</summary>
        public static Vector3 Gravity(Vector3 w) => on ? -UpAt(w) * 9.8f : Vector3.down * 9.8f;
    }
}
