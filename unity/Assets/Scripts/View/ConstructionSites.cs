// Port of scripts/construction_sites.gd: draws the buildings City has under construction
// (City.sites): a fenced dirt lot, then the building rising storey by storey as a bare frame
// with the finished facade following it up, scaffolding round it, and a tower crane on tall
// ones. When the job is done City adds the real building and CityView draws it.
//
// The building is its own kit mesh drawn with the kit shader's construction cut (_BuildTop,
// _BuildDone). Scaffold, crane and fence meshes are made here from boxes (in Godot space,
// local to the lot) and cached by shape.
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class ConstructionSites : MonoBehaviour
    {
        public const float SETUP = 0.08f;
        public const float TOPPED = 0.80f;
        public const float CLAD = 0.92f;
        public const float CRANE_OVER = 22f;

        static readonly Color STEEL = new Color(0.52f, 0.54f, 0.56f);
        static readonly Color WOOD = new Color(0.62f, 0.47f, 0.28f);
        static readonly Color NET = new Color(0.1f, 0.42f, 0.3f);
        static readonly Color CRANE = new Color(0.95f, 0.7f, 0.08f);
        static readonly Color DIRT = new Color(0.4f, 0.32f, 0.22f);
        static readonly Color CONCRETE = new Color(0.6f, 0.59f, 0.56f);

        City city;
        CityView view;

        class Profile
        {
            public float h;
            public float[] levels;  // x0, x1, z0, z1 per metre (Godot mesh space)
        }

        class Site
        {
            public GameObject root, body, bld, cap, scaffold, mast, head, fence;
            public float h, seed;
            public double built = -1;
            public Profile prof;
        }

        readonly Dictionary<int, Site> _sites = new Dictionary<int, Site>();
        readonly Dictionary<string, Mesh> _scaffolds = new Dictionary<string, Mesh>();
        readonly Dictionary<int, Mesh> _fences = new Dictionary<int, Mesh>();
        readonly Dictionary<float, Mesh> _masts = new Dictionary<float, Mesh>();
        readonly Dictionary<float, Mesh> _heads = new Dictionary<float, Mesh>();
        readonly Dictionary<string, Profile> _profiles = new Dictionary<string, Profile>();
        Material _siteMat, _capMat;
        Mesh _cube;
        MaterialPropertyBlock _mpb;
        float _visT;

        public void Setup(City c, CityView v)
        {
            city = c;
            view = v;
            _siteMat = new Material(Resources.Load<Shader>("Shaders/MSPSite")) { name = "Site" };
            _capMat = Mats.Make(CONCRETE, 0.1f);
            _mpb = new MaterialPropertyBlock();
            city.SiteStarted += Add;
            city.SiteEnded += (id, done) => Remove(id);
            foreach (int id in city.sites.Keys()) Add(id);
        }

        public int Count => _sites.Count;

        void Update()
        {
            if (_sites.Count == 0) return;
            _visT -= Time.deltaTime;
            bool check = _visT <= 0f;
            if (check) _visT = 0.25f;
            float now = Time.time;
            foreach (var kv in _sites)
            {
                var s = kv.Value;
                if (check && city.sites.TryGetValue(kv.Key, out var b))
                    s.root.SetActive(view == null || view.CellVisible(b.x, b.y));
                if (s.root.activeSelf) Pose(kv.Key, s, now);
            }
        }

        // -------------------------------------------------------------- a site ---

        GameObject Child(Transform parent, string name, Mesh mesh, Material mat, bool shadows = true)
        {
            var go = MeshUtil.Show(parent, name, mesh, mat);
            if (!shadows) go.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            return go;
        }

        void Add(int id)
        {
            if (_sites.ContainsKey(id) || !city.sites.TryGetValue(id, out var b)) return;
            string nm = view != null ? view.BuildingMesh(b) : "";
            var mesh = nm != "" ? Kit.Mesh(nm) : null;
            var xf = new GXform(GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f), city.BuildingCenter(b));
            var root = new GameObject("Site_" + id);
            root.transform.SetParent(transform, false);
            G.Apply(root.transform, Planet.Xf(xf));
            var s = new Site { root = root, seed = (float)b.seed };
            float half = b.size * City.TILE * 0.5f;

            s.fence = Child(root.transform, "Fence", FenceMesh(b.size), _siteMat);

            // Nobody walks or drives through the job: the hoarding is solid.
            s.body = new GameObject("SiteBody_" + id);
            s.body.transform.SetParent(transform, false);
            G.Apply(s.body.transform, Planet.XfRigid(xf));
            var box = s.body.AddComponent<BoxCollider>();
            box.size = new Vector3(half * 2f - 0.7f, 3f, half * 2f - 0.7f);
            box.center = new Vector3(0f, 1.5f, 0f);

            if (mesh != null)
            {
                var prof = GetProfile(nm, mesh);
                s.prof = prof;
                s.h = prof.h;
                s.bld = Child(root.transform, "Building", mesh, Kit.Merged);
                s.bld.GetComponent<MeshRenderer>().sharedMaterials = Kit.MaterialsFor(nm);
                KitObject.SetTints(s.bld.GetComponent<MeshRenderer>(), CityView.WallTint(b), CityView.Accent(b));

                _cube ??= Cube();
                s.cap = Child(root.transform, "Deck", _cube, _capMat, false);
                s.scaffold = Child(root.transform, "Scaffold", ScaffoldMesh(nm, prof), _siteMat, false);

                if (prof.h > CRANE_OVER)
                {
                    s.mast = Child(root.transform, "Mast", MastMesh(prof.h + 16f), _siteMat);
                    var c = Centre(prof, prof.h * 0.5f);
                    s.mast.transform.localPosition = G.U(new Vector3(c.x, 0f, c.y));
                    s.head = Child(s.mast.transform, "Head", HeadMesh(10f + 9f * b.size), _siteMat, false);
                }
            }
            _sites[id] = s;
            Pose(id, s, 0f);
        }

        void Remove(int id)
        {
            if (!_sites.TryGetValue(id, out var s)) return;
            Destroy(s.root);
            Destroy(s.body);
            _sites.Remove(id);
        }

        /// <summary>Where the job stands at `built`: heights in metres above the lot for a building h tall.</summary>
        public static (float top, float done, float scaffold, float crane, float fence) Stage(float built, float h)
        {
            float band = Mathf.Clamp(h * 0.3f, 3.5f, 12f);
            float rise = Mathf.Clamp01((built - SETUP) / (TOPPED - SETUP));
            float top = built < SETUP ? -1f : Mathf.Lerp(0.4f, h + 0.2f, rise);
            float done = top - band;
            if (built >= TOPPED) done = Mathf.Lerp(h - band, h + 1f, Mathf.Clamp01((built - TOPPED) / (CLAD - TOPPED)));
            float strike = Mathf.Clamp01((built - CLAD) / (0.99f - CLAD));
            float scaffold = built < SETUP ? -1f : Mathf.Lerp(top + 1.6f, -1f, strike);
            float crane = Mathf.Lerp(Mathf.Max(top + 9f, 12f), -1f, strike);
            if (built < SETUP * 0.6f) crane = Mathf.Lerp(-1f, 12f, built / (SETUP * 0.6f));
            return (top, done, scaffold, crane, Mathf.Lerp(0f, 2.4f, Mathf.Clamp01(built / (SETUP * 0.5f))));
        }

        void SetClip(GameObject go, float clip)
        {
            var r = go.GetComponent<MeshRenderer>();
            r.GetPropertyBlock(_mpb);
            _mpb.SetFloat("_ClipTop", clip);
            r.SetPropertyBlock(_mpb);
        }

        void Pose(int id, Site s, float now)
        {
            if (!city.sites.TryGetValue(id, out var b)) return;
            double built = b.built;
            if (s.head != null && s.head.activeInHierarchy)
            {
                // the jib swings whether or not the job moved on
                float a = s.seed * G.TAU + Mathf.Sin(now * 0.13f + s.seed * 40f) * 1.3f;
                s.head.transform.localRotation = G.U(GBasis.Rotation(Vector3.up, a).Quat());
            }
            if (System.Math.Abs(built - s.built) < 1e-6) return;
            s.built = built;
            var st = Stage((float)built, s.h);
            SetClip(s.fence, st.fence);
            if (s.bld == null) return;
            s.bld.SetActive(st.top > 0f);
            // the kit shader reads 0 as "no cut", so keep a real cut just off zero
            KitObject.SetTints(s.bld.GetComponent<MeshRenderer>(), CityView.WallTint(b), CityView.Accent(b),
                NonZero(st.top), NonZero(st.done));
            s.scaffold.SetActive(st.scaffold > 0f);
            SetClip(s.scaffold, st.scaffold);
            // the working deck: a slab closing the open top of the frame
            bool capOn = st.top > 0f && built < TOPPED;
            s.cap.SetActive(capOn);
            if (capOn)
            {
                var r = Section(s.prof, st.top);
                s.cap.transform.localPosition = G.U(new Vector3((r[0] + r[1]) * 0.5f, st.top - 0.15f, (r[2] + r[3]) * 0.5f));
                s.cap.transform.localScale = new Vector3(Mathf.Max(r[1] - r[0] - 0.1f, 0.5f), 0.3f, Mathf.Max(r[3] - r[2] - 0.1f, 0.5f));
            }
            if (s.mast != null)
            {
                s.mast.SetActive(st.crane > 3f);
                SetClip(s.mast, st.crane);
                s.head.transform.localPosition = new Vector3(0f, st.crane, 0f);
            }
        }

        static float NonZero(float v) => Mathf.Abs(v) < 1e-4f ? -1e-4f : v;

        // -------------------------------------------------------- mesh profile ---

        /// <summary>For each metre of height, the box round everything at or above it.</summary>
        Profile GetProfile(string nm, Mesh mesh)
        {
            if (_profiles.TryGetValue(nm, out var p)) return p;
            var verts = mesh.isReadable ? mesh.vertices : new Vector3[0];
            float h = 0f;
            foreach (var v in verts) h = Mathf.Max(h, v.y);
            int n = Mathf.CeilToInt(h) + 1;
            var lv = new float[n * 4];
            for (int k = 0; k < n; k++)
            {
                lv[k * 4] = float.PositiveInfinity; lv[k * 4 + 1] = float.NegativeInfinity;
                lv[k * 4 + 2] = float.PositiveInfinity; lv[k * 4 + 3] = float.NegativeInfinity;
            }
            foreach (var u in verts)
            {
                var v = G.FromU(u);
                int k = Mathf.Clamp((int)v.y, 0, n - 1);
                lv[k * 4] = Mathf.Min(lv[k * 4], v.x);
                lv[k * 4 + 1] = Mathf.Max(lv[k * 4 + 1], v.x);
                lv[k * 4 + 2] = Mathf.Min(lv[k * 4 + 2], v.z);
                lv[k * 4 + 3] = Mathf.Max(lv[k * 4 + 3], v.z);
            }
            for (int k = n - 2; k >= 0; k--)
            {
                lv[k * 4] = Mathf.Min(lv[k * 4], lv[k * 4 + 4]);
                lv[k * 4 + 1] = Mathf.Max(lv[k * 4 + 1], lv[k * 4 + 5]);
                lv[k * 4 + 2] = Mathf.Min(lv[k * 4 + 2], lv[k * 4 + 6]);
                lv[k * 4 + 3] = Mathf.Max(lv[k * 4 + 3], lv[k * 4 + 7]);
            }
            for (int k = 1; k < n; k++)
                if (float.IsPositiveInfinity(lv[k * 4]))
                    for (int j = 0; j < 4; j++) lv[k * 4 + j] = lv[k * 4 - 4 + j];
            if (float.IsPositiveInfinity(lv[0])) lv = new[] { -1f, 1f, -1f, 1f };
            p = new Profile { h = h, levels = lv };
            _profiles[nm] = p;
            return p;
        }

        static float[] Section(Profile prof, float y)
        {
            var lv = prof.levels;
            int k = Mathf.Clamp(Mathf.CeilToInt(y), 0, lv.Length / 4 - 1);
            return new[] { lv[k * 4], lv[k * 4 + 1], lv[k * 4 + 2], lv[k * 4 + 3] };
        }

        static Vector2 Centre(Profile prof, float y)
        {
            var r = Section(prof, y);
            return new Vector2((r[0] + r[1]) * 0.5f, (r[2] + r[3]) * 0.5f);
        }

        // -------------------------------------------------------------- meshes ---

        /// <summary>Collects boxes and beams (Godot space) into one vertex-coloured mesh.</summary>
        internal class Boxes
        {
            readonly List<Vector3> v = new List<Vector3>();
            readonly List<Vector3> n = new List<Vector3>();
            readonly List<Color> c = new List<Color>();
            readonly List<Vector2> uv = new List<Vector2>();

            static readonly Vector3[][] F =
            {
                new[] { new Vector3(1, 0, 0), new Vector3(0, 1, 0), new Vector3(0, 0, 1) }, new[] { new Vector3(-1, 0, 0), new Vector3(0, 0, 1), new Vector3(0, 1, 0) },
                new[] { new Vector3(0, 1, 0), new Vector3(0, 0, 1), new Vector3(1, 0, 0) }, new[] { new Vector3(0, -1, 0), new Vector3(1, 0, 0), new Vector3(0, 0, 1) },
                new[] { new Vector3(0, 0, 1), new Vector3(1, 0, 0), new Vector3(0, 1, 0) }, new[] { new Vector3(0, 0, -1), new Vector3(0, 1, 0), new Vector3(1, 0, 0) },
            };

            public void Box(Vector3 centre, Vector3 size, Color col, bool net = false) =>
                Add(new GXform(GBasis.Scaled(size), centre), col, net);

            public void Beam(Vector3 a, Vector3 b, float thick, Color col)
            {
                var d = b - a;
                float l = d.magnitude;
                if (l < 0.001f) return;
                var z = d / l;
                var x = Vector3.Cross(z, Mathf.Abs(z.y) < 0.95f ? Vector3.up : Vector3.right).normalized;
                var y = Vector3.Cross(z, x);
                Add(new GXform(new GBasis(x * thick, y * thick, z * l), (a + b) * 0.5f), col, false);
            }

            void Add(GXform xf, Color col, bool net)
            {
                var nb = xf.basis.Inverse().Transposed();
                foreach (var f in F)
                {
                    var o = f[0] * 0.5f;
                    var a = f[1] * 0.5f;
                    var b = f[2] * 0.5f;
                    var nn = (nb * f[0]).normalized;
                    foreach (var p in new[] { o - a - b, o + a - b, o + a + b, o - a - b, o + a + b, o - a + b })
                    {
                        v.Add(xf * p);
                        n.Add(nn);
                        c.Add(col);
                        uv.Add(new Vector2(net ? 1f : 0f, 0f));
                    }
                }
            }

            public Mesh Mesh()
            {
                var m = new Mesh { name = "SiteBoxes", indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
                var vu = new Vector3[v.Count];
                var nu = new Vector3[n.Count];
                var idx = new int[v.Count];
                for (int i = 0; i < v.Count; i++) { vu[i] = G.U(v[i]); nu[i] = G.U(n[i]); idx[i] = i; }
                m.vertices = vu;
                m.normals = nu;
                m.SetColors(c);
                m.SetUVs(0, uv);
                m.triangles = idx;  // drawn two-sided (MSPSite), so winding doesn't matter
                m.RecalculateBounds();
                return m;
            }
        }

        static float H01(float a, float b) => G.Fposmod(Mathf.Sin(a * 12.9898f + b * 78.233f) * 43758.5453f, 1f);

        static Vector3 Abs(Vector3 v) => new Vector3(Mathf.Abs(v.x), Mathf.Abs(v.y), Mathf.Abs(v.z));

        Mesh ScaffoldMesh(string nm, Profile prof)
        {
            if (_scaffolds.TryGetValue(nm, out var cached)) return cached;
            var bx = new Boxes();
            var r = Section(prof, 2f);
            float top = prof.h + 1.6f;
            int levels = (int)(top / 2f);
            var sides = new (Vector3 u, float a, float b, Vector3 w, float off)[]
            {
                (new Vector3(1, 0, 0), r[0], r[1], new Vector3(0, 0, 1), r[3]), (new Vector3(1, 0, 0), r[0], r[1], new Vector3(0, 0, -1), -r[2]),
                (new Vector3(0, 0, 1), r[2], r[3], new Vector3(1, 0, 0), r[1]), (new Vector3(0, 0, 1), r[2], r[3], new Vector3(-1, 0, 0), -r[0]),
            };
            for (int si = 0; si < sides.Length; si++)
            {
                var sd = sides[si];
                var u = sd.u;
                var w = sd.w;
                float a = sd.a - 1.1f, b = sd.b + 1.1f;
                var inner = w * (sd.off + 0.3f);
                var outer = w * (sd.off + 1.1f);
                int bays = Mathf.Max(Mathf.CeilToInt((b - a) / 2.5f), 1);
                float step = (b - a) / bays;
                for (int k = 0; k <= bays; k++)
                {
                    var at = u * (a + step * k);
                    bx.Box(at + inner + new Vector3(0, top * 0.5f, 0), new Vector3(0.07f, top, 0.07f), STEEL);
                    bx.Box(at + outer + new Vector3(0, top * 0.5f, 0), new Vector3(0.07f, top, 0.07f), STEEL);
                }
                var mid = u * ((a + b) * 0.5f);
                var along = u * (b - a);
                for (int l = 1; l <= levels; l++)
                {
                    float y = l * 2f;
                    bx.Box(mid + (inner + outer) * 0.5f + new Vector3(0, y, 0), along + Abs(w) * 0.75f + new Vector3(0, 0.05f, 0), WOOD);
                    bx.Box(mid + outer + new Vector3(0, y + 1f, 0), along + Abs(w) * 0.05f + new Vector3(0, 0.05f, 0), STEEL);
                    for (int k = 0; k < bays; k++)
                    {
                        var p0 = u * (a + step * k) + outer;
                        var p1 = u * (a + step * (k + 1)) + outer;
                        float hsh = H01(si * 7f + k, l * 3f + prof.h);
                        if ((k + l) % 3 == 0) bx.Beam(p0 + new Vector3(0, y - 2f, 0), p1 + new Vector3(0, y, 0), 0.05f, STEEL);
                        if (hsh < 0.4f && l > 1)
                            bx.Box((p0 + p1) * 0.5f + w * 0.06f + new Vector3(0, y - 1f, 0), u * step + new Vector3(0, 2f, 0) + Abs(w) * 0.01f, NET, true);
                    }
                }
            }
            var m = bx.Mesh();
            _scaffolds[nm] = m;
            return m;
        }

        Mesh FenceMesh(int size)
        {
            if (_fences.TryGetValue(size, out var cached)) return cached;
            var bx = new Boxes();
            float half = size * City.TILE * 0.5f - 0.35f;
            bx.Box(new Vector3(0, 0.1f, 0), new Vector3(half * 2f, 0.2f, half * 2f), DIRT);
            float g = half - 2.2f;
            int nx = Mathf.Max((int)(g * 2f / 3.2f), 1);
            for (int iz = 0; iz <= nx; iz++)
                for (int ix = 0; ix <= nx; ix++)
                {
                    var p = new Vector3(-g + g * 2f * ix / nx, 0.3f, -g + g * 2f * iz / nx);
                    bx.Box(p, new Vector3(0.9f, 0.35f, 0.9f), CONCRETE);
                    foreach (var q in new[] { new Vector3(0.25f, 0, 0.25f), new Vector3(-0.25f, 0, 0.25f), new Vector3(0.25f, 0, -0.25f), new Vector3(-0.25f, 0, -0.25f) })
                        bx.Box(p + q + new Vector3(0, 0.6f, 0), new Vector3(0.04f, 0.9f, 0.04f), new Color(0.45f, 0.25f, 0.16f));
                }
            int panels = Mathf.Max((int)(half * 2f / 2f), 1);
            float pw = half * 2f / panels;
            for (int side = 0; side < 4; side++)
            {
                var u = side < 2 ? new Vector3(1, 0, 0) : new Vector3(0, 0, 1);
                var w = side < 2 ? new Vector3(0, 0, side == 0 ? 1 : -1) : new Vector3(side == 2 ? 1 : -1, 0, 0);
                for (int k = 0; k < panels; k++)
                {
                    float c = -half + pw * (k + 0.5f);
                    if (side == 0 && Mathf.Abs(c) < 2.2f) continue; // the gate
                    var col = (k + side) % 2 == 0 ? new Color(0.2f, 0.36f, 0.62f) : new Color(0.86f, 0.86f, 0.84f);
                    bx.Box(u * c + w * half + new Vector3(0, 1.1f, 0), u * (pw - 0.04f) + new Vector3(0, 2f, 0) + Abs(w) * 0.06f, col);
                }
                for (int k = 0; k <= panels; k++)
                    bx.Box(u * (-half + pw * k) + w * half + new Vector3(0, 1.15f, 0), new Vector3(0.1f, 2.3f, 0.1f), STEEL);
            }
            bx.Box(new Vector3(half - 1.6f, 0.6f, half - 1.4f), new Vector3(1.6f, 0.8f, 1f), WOOD);
            bx.Box(new Vector3(-half + 1.5f, 0.5f, half - 1.3f), new Vector3(1.2f, 0.6f, 1.2f), new Color(0.7f, 0.3f, 0.2f));
            var m = bx.Mesh();
            _fences[size] = m;
            return m;
        }

        Mesh MastMesh(float height)
        {
            float h = Mathf.Ceil(height / 4f) * 4f;
            if (_masts.TryGetValue(h, out var cached)) return cached;
            var bx = new Boxes();
            const float W = 0.85f;
            Vector3[] corners = { new Vector3(W, 0, W), new Vector3(-W, 0, W), new Vector3(-W, 0, -W), new Vector3(W, 0, -W) };
            foreach (var c in corners) bx.Box(c + new Vector3(0, h * 0.5f, 0), new Vector3(0.14f, h, 0.14f), CRANE);
            for (int l = 0; l < (int)(h / 2f); l++)
            {
                float y = l * 2f;
                for (int k = 0; k < 4; k++)
                {
                    var a = corners[k];
                    var b = corners[(k + 1) % 4];
                    bx.Beam(a + new Vector3(0, y + 2f, 0), b + new Vector3(0, y + 2f, 0), 0.07f, CRANE);
                    if ((l + k) % 2 == 0) bx.Beam(a + new Vector3(0, y, 0), b + new Vector3(0, y + 2f, 0), 0.06f, CRANE);
                    else bx.Beam(b + new Vector3(0, y, 0), a + new Vector3(0, y + 2f, 0), 0.06f, CRANE);
                }
            }
            var m = bx.Mesh();
            _masts[h] = m;
            return m;
        }

        /// <summary>The top of a tower crane, turning about its origin: jib along +X, counterweight on -X.</summary>
        Mesh HeadMesh(float jib)
        {
            if (_heads.TryGetValue(jib, out var cached)) return cached;
            var bx = new Boxes();
            bx.Box(new Vector3(0, 0.5f, 0), new Vector3(2.2f, 1f, 2.2f), STEEL);
            bx.Box(new Vector3(0.4f, 1.9f, 1.5f), new Vector3(1.6f, 1.8f, 1.3f), new Color(0.9f, 0.9f, 0.88f));
            bx.Box(new Vector3(1.22f, 2.1f, 1.5f), new Vector3(0.04f, 1f, 1.1f), new Color(0.1f, 0.14f, 0.18f));
            var peak = new Vector3(0, 7.5f, 0);
            foreach (var c in new[] { new Vector3(0.6f, 1, 0.6f), new Vector3(-0.6f, 1, 0.6f), new Vector3(-0.6f, 1, -0.6f), new Vector3(0.6f, 1, -0.6f) })
                bx.Beam(c, peak, 0.12f, CRANE);
            float jy = 1.6f;
            bx.Beam(new Vector3(0, jy, 0.5f), new Vector3(jib, jy, 0.5f), 0.1f, CRANE);
            bx.Beam(new Vector3(0, jy, -0.5f), new Vector3(jib, jy, -0.5f), 0.1f, CRANE);
            bx.Beam(new Vector3(0, jy + 1f, 0), new Vector3(jib, jy + 1f, 0), 0.1f, CRANE);
            int n = (int)(jib / 2f);
            for (int k = 0; k < n; k++)
            {
                float x0 = jib * k / n, x1 = jib * (k + 1) / n;
                bx.Beam(new Vector3(x0, jy, 0.5f), new Vector3(x1, jy + 1f, 0), 0.05f, CRANE);
                bx.Beam(new Vector3(x0, jy, -0.5f), new Vector3(x1, jy + 1f, 0), 0.05f, CRANE);
                bx.Beam(new Vector3(x1, jy, 0.5f), new Vector3(x1, jy, -0.5f), 0.05f, CRANE);
            }
            bx.Box(new Vector3(-4f, jy, 0), new Vector3(8f, 0.25f, 1.2f), CRANE);
            bx.Box(new Vector3(-6.8f, jy + 0.1f, 0), new Vector3(2f, 1.7f, 1.5f), CONCRETE);
            bx.Beam(peak, new Vector3(jib * 0.75f, jy + 1f, 0), 0.04f, STEEL);
            bx.Beam(peak, new Vector3(-7.5f, jy + 0.2f, 0), 0.04f, STEEL);
            float tx = jib * 0.62f;
            bx.Box(new Vector3(tx, jy - 0.15f, 0), new Vector3(1f, 0.25f, 1.1f), STEEL);
            bx.Box(new Vector3(tx, jy - 4.3f, 0), new Vector3(0.05f, 8f, 0.05f), new Color(0.12f, 0.12f, 0.12f));
            bx.Box(new Vector3(tx, jy - 8.5f, 0), new Vector3(0.4f, 0.5f, 0.4f), CRANE);
            bx.Box(new Vector3(tx, jy - 9.4f, 0), new Vector3(2.4f, 0.5f, 1.2f), WOOD);
            var m = bx.Mesh();
            _heads[jib] = m;
            return m;
        }

        static Mesh Cube()
        {
            var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
            var m = go.GetComponent<MeshFilter>().sharedMesh;
            Destroy(go);
            return m;
        }
    }
}
