// The boot object in Assets/Scenes/Main.unity: builds the whole game in code, as msp's
// scripts/main.gd does.
//
// Milestone 0 (pipeline check): the planet (belt, ice cap, sea), a few msp kit buildings on
// the belt, the sun and an orbit camera. Options (after the exe name):
//   --view=x,z,dist,yawdeg,tiltdeg   camera framing over flat map metres
//   --hour=10.5                      clock (sun position)
//   --screenshot=path.png            render, save, quit
using System.Collections;
using UnityEngine;

namespace MSP
{
    public class Main : MonoBehaviour
    {
        public const int PLANET_COLS = 192;
        public const int PLANET_ROWS = 36;

        OrbitCamera cam;
        Light sun;
        float hour = 10.5f;

        void Awake()
        {
            Application.targetFrameRate = 60;
            Planet.Configure(PLANET_COLS, PLANET_ROWS);
            Physics.gravity = Vector3.zero; // planet bodies apply their own pull toward the centre
        }

        void Start()
        {
            hour = Args.GetF("hour", 10.5f);
            BuildWorld();
            var camGo = new GameObject("MayorCamera");
            camGo.transform.SetParent(transform);
            cam = camGo.AddComponent<OrbitCamera>();
            float[] v = { 1182f, 204f, 230f, -35f, -30f };
            if (Args.Has("view"))
            {
                string[] parts = Args.Get("view").Split(',');
                for (int i = 0; i < parts.Length && i < v.Length; i++)
                    float.TryParse(parts[i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v[i]);
            }
            cam.SetView(new Vector3(v[0], 0f, v[1]), v[2], v[3] * Mathf.Deg2Rad, v[4] * Mathf.Deg2Rad);
            if (Args.Has("screenshot"))
                StartCoroutine(Screenshot(Args.Get("screenshot")));
        }

        void Update()
        {
            UpdateSun();
        }

        void BuildWorld()
        {
            var world = new GameObject("World").transform;
            world.SetParent(transform);
            var belt = new GameObject("Belt", typeof(MeshFilter), typeof(MeshRenderer));
            belt.transform.SetParent(world);
            belt.GetComponent<MeshFilter>().sharedMesh = Planet.BeltMesh(0f, 1);
            belt.GetComponent<MeshRenderer>().sharedMaterial = Mats.Make(new Color(0.36f, 0.5f, 0.24f));
            AddSphere(world, "Sea", Planet.R - 0.6f, new Color(0.12f, 0.36f, 0.5f), 0.85f);
            AddCap(world, "IceCap", Planet.R + 0.2f, Planet.LatOf(new Vector3(0, 0, 0)), Mathf.PI * 0.5f, new Color(0.9f, 0.94f, 0.97f));
            PlaceSampleBuildings(world);

            sun = new GameObject("Sun").AddComponent<Light>();
            sun.transform.SetParent(transform);
            sun.type = LightType.Directional;
            sun.shadows = LightShadows.Soft;
            sun.intensity = 1.2f;
            RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.55f, 0.65f, 0.8f);
            RenderSettings.ambientEquatorColor = new Color(0.45f, 0.48f, 0.5f);
            RenderSettings.ambientGroundColor = new Color(0.25f, 0.24f, 0.22f);
        }

        /// <summary>A row of msp's kit buildings along a street near the starter town, to check
        /// the .glb import, orientation and placement on the ball.</summary>
        void PlaceSampleBuildings(Transform parent)
        {
            string[] names = { "r_1_1_a", "r_2_1_b", "c_3_1_a", "c_2_1_c", "i_2_1_a", "r_3_2_a", "c_3_2_b", "r_1_1_c" };
            float x0 = 1152f, z = 204f;
            for (int i = 0; i < names.Length; i++)
            {
                var prefab = Resources.Load<GameObject>("Kit/buildings/" + names[i]);
                if (prefab == null) { Debug.LogWarning("[MSP] missing kit model " + names[i]); continue; }
                var go = Instantiate(prefab, parent);
                go.name = names[i];
                int w = names[i][2] - '0';
                var flat = new GXform(GBasis.Identity, new Vector3(x0 + i * 24f + w * 6f, 0f, z));
                G.Apply(go.transform, Planet.Xf(flat));
                if (Args.Has("debug"))
                {
                    var b = new Bounds(go.transform.position, Vector3.zero);
                    int nr = 0;
                    foreach (var r in go.GetComponentsInChildren<Renderer>()) { b.Encapsulate(r.bounds); nr++; }
                    var mr = go.GetComponentInChildren<Renderer>();
                    string sh = mr != null && mr.sharedMaterial != null ? mr.sharedMaterial.shader.name + " supported=" + mr.sharedMaterial.shader.isSupported : "none";
                    Debug.Log($"[MSP] {names[i]} pos={go.transform.position} |pos|={go.transform.position.magnitude:F1} R={Planet.R:F1} scale={go.transform.lossyScale} renderers={nr} bounds={b.center} size={b.size} shader={sh}");
                }
            }
            // a road strip in front of them
            for (int i = 0; i < 16; i++)
            {
                var road = Resources.Load<GameObject>("Kit/roads/road_straight");
                if (road == null) break;
                var go = Instantiate(road, parent);
                var flat = new GXform(GBasis.Rotation(Vector3.up, Mathf.PI * 0.5f), new Vector3(x0 + 6f + i * 12f, 0f, z + 12f));
                G.Apply(go.transform, Planet.Xf(flat));
            }
        }

        static void AddSphere(Transform parent, string name, float radius, Color c, float smooth)
        {
            var go = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            go.name = name;
            Destroy(go.GetComponent<Collider>());
            go.transform.SetParent(parent);
            go.transform.localScale = Vector3.one * radius * 2f;
            go.GetComponent<MeshRenderer>().sharedMaterial = Mats.Make(c, smooth);
            // the default sphere is coarse; good enough for the milestone-0 sea seen from orbit
        }

        /// <summary>The sphere between two latitudes (radians), as a mesh in Unity space.</summary>
        static void AddCap(Transform parent, string name, float radius, float lat0, float lat1, Color c)
        {
            int rings = 24, segs = 192;
            var verts = new Vector3[(rings + 1) * (segs + 1)];
            var norms = new Vector3[verts.Length];
            int k = 0;
            for (int j = 0; j <= rings; j++)
            {
                float lat = Mathf.Lerp(lat0, lat1, (float)j / rings);
                for (int i = 0; i <= segs; i++)
                {
                    Vector3 d = Planet.DirAt(lat, G.TAU * i / segs);
                    verts[k] = G.U(d * radius);
                    norms[k] = G.U(d);
                    k++;
                }
            }
            var idx = new int[rings * segs * 6];
            k = 0;
            for (int j = 0; j < rings; j++)
                for (int i = 0; i < segs; i++)
                {
                    int a = j * (segs + 1) + i, b = a + segs + 1;
                    // rows run north here (the belt's run south), so this order faces out
                    idx[k++] = a; idx[k++] = b; idx[k++] = a + 1;
                    idx[k++] = a + 1; idx[k++] = b; idx[k++] = b + 1;
                }
            var m = new Mesh { indexFormat = UnityEngine.Rendering.IndexFormat.UInt32, vertices = verts, normals = norms, triangles = idx };
            m.RecalculateBounds();
            var go = new GameObject(name, typeof(MeshFilter), typeof(MeshRenderer));
            go.transform.SetParent(parent);
            go.GetComponent<MeshFilter>().sharedMesh = m;
            go.GetComponent<MeshRenderer>().sharedMaterial = Mats.Make(c, 0.3f);
        }

        /// <summary>Sun over the camera's spot at the clock's hour (msp turns the sky to the local
        /// up so street level at noon looks like the flat game).</summary>
        void UpdateSun()
        {
            if (sun == null || cam == null) return;
            Vector3 focus = cam.focus;
            var f = Planet.Frame(focus);
            float a = (hour - 6f) / 12f * Mathf.PI; // 0 at sunrise, PI at sunset
            Vector3 toSun = (f.x * -Mathf.Cos(a) + f.y * Mathf.Sin(a) + f.z * -0.35f).normalized;
            sun.transform.rotation = Quaternion.LookRotation(G.U(-toSun));
            sun.intensity = Mathf.Clamp01(Mathf.Sin(a) * 2f) * 1.2f;
        }

        IEnumerator Screenshot(string path)
        {
            for (int i = 0; i < 40; i++) yield return null;
            yield return new WaitForEndOfFrame();
            ScreenCapture.CaptureScreenshot(path);
            Debug.Log("[MSP] screenshot " + path);
            for (int i = 0; i < 5; i++) yield return null;
            Application.Quit();
        }
    }
}
