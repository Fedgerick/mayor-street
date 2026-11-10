// Port of services/services_view.gd: draws what services add to the map: the coverage overlays,
// power lines, and garbage bags on the sidewalks. Catalog buildings are drawn by CityView.
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

namespace MSP
{
    public class ServicesView : MonoBehaviour
    {
        public const float OVERLAY_Y = 0.45f;
        public const float UPDATE_EVERY = 0.5f;  // seconds between services.Update() calls while the city changes
        public const float POLE_H = 8.5f;

        public CityServices services;
        public City city;
        public CityServices.Overlay overlay = CityServices.Overlay.NONE;

        GameObject _overlayGo;
        Texture2D _overlayTex;
        Color32[] _px;
        Mesh _poleMesh, _wireMesh, _bagMesh;
        Material _poleMat, _wireMat, _bagDark, _bagGreen;
        readonly List<Matrix4x4> _poles = new List<Matrix4x4>(), _wires = new List<Matrix4x4>();
        readonly List<Matrix4x4> _bagsDark = new List<Matrix4x4>(), _bagsGreen = new List<Matrix4x4>();
        float _t;
        bool _overlayDirty = true, _linesDirty = true;

        public void Setup(CityServices s)
        {
            services = s;
            city = s.city;
            MakeOverlay();
            _poleMesh = PoleMesh();
            var wb = new ConstructionSites.Boxes();
            wb.Box(Vector3.zero, Vector3.one, Color.white);
            _wireMesh = wb.Mesh();
            _bagMesh = MeshUtil.Sphere(0.45f, 8, 4);
            _poleMat = Lit(new Color(0.36f, 0.3f, 0.24f));
            _wireMat = Lit(new Color(0.08f, 0.08f, 0.08f));
            _bagDark = Lit(new Color(0.1f, 0.11f, 0.1f));
            _bagGreen = Lit(new Color(0.18f, 0.32f, 0.16f));
            s.CoverageChanged += () => { _overlayDirty = true; _linesDirty = true; };
            s.StatsChanged += () => { _overlayDirty = true; RefreshBags(); };
            RefreshLines();
            RefreshBags();
        }

        static Material Lit(Color c)
        {
            var m = Mats.Make(c, 0.15f);
            m.SetFloat("_Cull", 0f);  // box faces are wound for Godot; draw both sides
            return m;
        }

        public void SetOverlay(CityServices.Overlay mode)
        {
            overlay = mode;
            _overlayGo.SetActive(mode != CityServices.Overlay.NONE);
            _overlayDirty = true;
        }

        void Update()
        {
            if (services == null) return;
            _t += Time.deltaTime;
            if (_t >= UPDATE_EVERY)
            {
                _t = 0f;
                services.Update();
            }
            if (_linesDirty) RefreshLines();
            if (_overlayDirty && _overlayGo.activeSelf) RefreshOverlay();
            Draw(_poleMesh, _poleMat, _poles, true);
            Draw(_wireMesh, _wireMat, _wires, false);
            Draw(_bagMesh, _bagDark, _bagsDark, true);
            Draw(_bagMesh, _bagGreen, _bagsGreen, true);
        }

        void Draw(Mesh mesh, Material mat, List<Matrix4x4> xfs, bool shadow)
        {
            if (xfs.Count == 0) return;
            var rp = new RenderParams(mat)
            {
                shadowCastingMode = shadow ? ShadowCastingMode.On : ShadowCastingMode.Off,
                receiveShadows = true,
                layer = gameObject.layer,
                worldBounds = new Bounds(Vector3.zero, Vector3.one * (Planet.R * 2.5f + 200f)),
            };
            for (int i = 0; i < xfs.Count; i += 1023)
                Graphics.RenderMeshInstanced(rp, mesh, 0, xfs, Mathf.Min(1023, xfs.Count - i), i);
        }

        // ------------------------------------------------------------------ overlay ---

        void MakeOverlay()
        {
            _overlayTex = new Texture2D(City.W, City.H, TextureFormat.RGBA32, false)
            {
                filterMode = FilterMode.Bilinear,
                wrapModeU = Planet.on ? TextureWrapMode.Repeat : TextureWrapMode.Clamp,
                wrapModeV = TextureWrapMode.Clamp,
            };
            _px = new Color32[City.W * City.H];
            var mat = new Material(Resources.Load<Shader>("Shaders/MSPOverlay"));
            mat.SetTexture("_MainTex", _overlayTex);
            Mesh plane;
            if (Planet.on) plane = Planet.BeltMesh(OVERLAY_Y);
            else
            {
                // a flat sheet over the map, u east, v south (Godot space, written through G.U)
                float w = City.W * City.TILE, h = City.H * City.TILE;
                plane = new Mesh();
                plane.vertices = new[] { G.U(new Vector3(0, OVERLAY_Y, 0)), G.U(new Vector3(w, OVERLAY_Y, 0)), G.U(new Vector3(0, OVERLAY_Y, h)), G.U(new Vector3(w, OVERLAY_Y, h)) };
                plane.uv = new[] { new Vector2(0, 0), new Vector2(1, 0), new Vector2(0, 1), new Vector2(1, 1) };
                plane.triangles = new[] { 0, 1, 2, 1, 3, 2 };
                plane.RecalculateNormals();
                plane.RecalculateBounds();
            }
            _overlayGo = MeshUtil.Show(transform, "ServiceOverlay", plane, mat);
            var mr = _overlayGo.GetComponent<MeshRenderer>();
            mr.shadowCastingMode = ShadowCastingMode.Off;
            mr.receiveShadows = false;
            _overlayGo.SetActive(false);
        }

        /// <summary>Colour for a value 0..1. "Good" maps run red (none) to green (full); "bad" maps the other way.</summary>
        public static Color OverlayColor(CityServices.Overlay mode, float v)
        {
            bool bad = mode == CityServices.Overlay.GARBAGE || mode == CityServices.Overlay.CRIME;
            if (bad)
            {
                if (v < 0.04f) return new Color(0, 0, 0, 0);
                var b = G.Lerp(new Color(0.95f, 0.85f, 0.1f), new Color(0.9f, 0.12f, 0.08f), Mathf.Clamp01(v));
                b.a = 0.35f + 0.35f * v;
                return b;
            }
            if (mode == CityServices.Overlay.POWER)
            {
                if (v <= 0f) return new Color(0, 0, 0, 0);
                return v >= 1f ? new Color(0.95f, 0.85f, 0.15f, 0.6f) : new Color(0.9f, 0.15f, 0.1f, 0.6f);
            }
            var c = G.Lerp(new Color(0.9f, 0.2f, 0.12f), new Color(0.95f, 0.85f, 0.15f), Mathf.Clamp01(v * 2f));
            c = G.Lerp(c, new Color(0.2f, 0.85f, 0.3f), Mathf.Clamp01(v * 2f - 1f));
            c.a = 0.5f;
            return c;
        }

        void RefreshOverlay()
        {
            _overlayDirty = false;
            var vals = services.OverlayValues(overlay);
            if (vals == null) return;
            int n = City.W * City.H;
            bool builtOnly = overlay == CityServices.Overlay.HAPPINESS || overlay == CityServices.Overlay.GARBAGE
                || overlay == CityServices.Overlay.CRIME;
            byte[] nearBuilt = null;
            if (builtOnly)
            {
                nearBuilt = new byte[n];
                for (int i = 0; i < n; i++)
                {
                    if (city.bld[i] < 0) continue;
                    int x = i % City.W, y = i / City.W;
                    for (int dy = -1; dy <= 1; dy++)
                        for (int dx = -1; dx <= 1; dx++)
                            if (city.Inside(x + dx, y + dy)) nearBuilt[city.Idx(x + dx, y + dy)] = 1;
                }
            }
            for (int i = 0; i < n; i++)
            {
                var c = new Color(0, 0, 0, 0);
                if (city.land[i] == 1 && (!builtOnly || nearBuilt[i] == 1)) c = OverlayColor(overlay, vals[i]);
                _px[i] = c;
            }
            _overlayTex.SetPixels32(_px);
            _overlayTex.Apply(false);
        }

        // -------------------------------------------------------------- power lines ---

        void RefreshLines()
        {
            _linesDirty = false;
            _poles.Clear();
            _wires.Clear();
            var pl = services.powerLine;
            var dirs = new[] { new Vector2Int(1, 0), new Vector2Int(0, 1), new Vector2Int(-1, 0), new Vector2Int(0, -1) };
            for (int i = 0; i < City.W * City.H; i++)
            {
                if (pl[i] == 0) continue;
                int x = i % City.W, y = i / City.W;
                Vector3 p = city.CellCenter(x, y);
                bool horiz = (x > 0 || Planet.on) && pl[city.Idx(x - 1, y)] == 1;
                horiz = horiz || ((x < City.W - 1 || Planet.on) && pl[city.Idx(x + 1, y)] == 1);
                var b = GBasis.Rotation(Vector3.up, horiz ? 0f : Mathf.PI * 0.5f);
                _poles.Add(G.M(Planet.Xf(new GXform(b, p))));
                // A wire to the east and south neighbour (or the road the line meets), at both arm ends.
                foreach (var d in dirs)
                {
                    int nx = x + d.x, ny = y + d.y;
                    if (!city.Inside(nx, ny)) continue;
                    int j = city.Idx(nx, ny);
                    bool toLine = pl[j] == 1 && (d.x > 0 || d.y > 0);
                    bool toGrid = pl[j] == 0 && (city.road[j] == 1 || city.bld[j] >= 0);
                    if (!(toLine || toGrid)) continue;
                    Vector3 q = city.CellCenter(nx, ny);
                    if (Planet.on) q.x = p.x + Planet.Dx(p.x, q.x);
                    if (toGrid) q = Vector3.Lerp(p, q, 0.5f);
                    Vector3 dir = q - p;
                    Vector3 side = new Vector3(-dir.z, 0, dir.x).normalized * 1.1f;
                    foreach (float s in new[] { -1f, 1f })
                    {
                        Vector3 a = p + side * s + new Vector3(0, POLE_H - 0.2f, 0);
                        Vector3 e = q + side * s + new Vector3(0, POLE_H - (toLine ? 0.2f : 3f), 0);
                        Vector3 mid = (a + e) * 0.5f - new Vector3(0, 0.35f, 0);
                        float len = Vector3.Distance(a, e);
                        // Godot's looking_at points -Z at the target; the wire is a unit box, so its sign doesn't matter
                        var lb = GBasis.LookingAt((e - a).normalized, Vector3.up) * GBasis.Scaled(new Vector3(0.05f, 0.05f, len));
                        _wires.Add(G.M(Planet.Xf(new GXform(lb, mid))));
                    }
                }
            }
        }

        static Mesh PoleMesh()
        {
            var bx = new ConstructionSites.Boxes();
            bx.Box(new Vector3(0, POLE_H * 0.5f, 0), new Vector3(0.3f, POLE_H, 0.3f), Color.white);
            bx.Box(new Vector3(0, POLE_H - 0.4f, 0), new Vector3(0.18f, 0.18f, 2.6f), Color.white);
            return bx.Mesh();
        }

        // ------------------------------------------------------------------ garbage ---

        void RefreshBags()
        {
            _bagsDark.Clear();
            _bagsGreen.Clear();
            int k = 0;
            foreach (var p in services.GarbagePiles())
            {
                float h = G.Fposmod(Mathf.Sin(k * 12.9898f) * 43758.5453f, 1f);
                var b = GBasis.Rotation(Vector3.up, h * G.TAU) * GBasis.Scaled(new Vector3(1f, 0.7f / 0.9f, 1f) * (0.8f + h * 0.5f));
                var m = G.M(Planet.Xf(new GXform(b, p + new Vector3(0, 0.3f, 0))));
                float hc = G.Fposmod(Mathf.Sin(k * 78.233f) * 43758.5453f, 1f);
                (hc < 0.6f ? _bagsDark : _bagsGreen).Add(m);
                k++;
            }
        }
    }
}
