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

        MayorCamera cam;
        DayNight dayNight;
        PlanetSky planetSky;
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
            dayNight = new GameObject("DayNight").AddComponent<DayNight>();
            dayNight.transform.SetParent(transform);
            planetSky = new GameObject("PlanetSky").AddComponent<PlanetSky>();
            planetSky.transform.SetParent(transform);
            planetSky.Setup(dayNight);
            var camGo = new GameObject("MayorCamera");
            camGo.transform.SetParent(transform);
            cam = camGo.AddComponent<MayorCamera>();
            cam.bounds = new Rect(0, -300, Planet.W * Planet.TILE, Planet.H * Planet.TILE + 500);
            cam.Moved += dayNight.SetViewDistance;
            dayNight.ApplyQuality(Args.GetI("quality", 1), cam.cam);
            float[] v = { 1182f, 204f, 230f, -35f, 0f };
            if (Args.Has("view"))
            {
                string[] parts = Args.Get("view").Split(',');
                for (int i = 0; i < parts.Length && i < v.Length; i++)
                    float.TryParse(parts[i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v[i]);
            }
            cam.SetView(new Vector3(v[0], 0f, v[1]), v[2], v[3] * Mathf.Deg2Rad, v[4] * Mathf.Deg2Rad);
            if (Args.Has("screenshot")) cam.inputEnabled = false;
            if (Args.Has("screenshot"))
                StartCoroutine(Screenshot(Args.Get("screenshot")));
        }

        void Update()
        {
            // [ and ] step the clock an hour (milestone-0 testing until the City clock is ported)
            if (Input.GetKeyDown(KeyCode.LeftBracket)) hour = G.Fposmod(hour - 1f, 24f);
            if (Input.GetKeyDown(KeyCode.RightBracket)) hour = G.Fposmod(hour + 1f, 24f);
        }

        void LateUpdate()
        {
            // as main.gd _follow_planet_sky: the sky follows the mayor focus round the ball
            Vector3 where = Planet.Warp(cam.focus);
            dayNight.UpdateTime(PlanetSky.LocalHour(hour, where), 0);
            planetSky.Follow(where, cam.Eye, hour);
        }

        void BuildWorld()
        {
            var world = new GameObject("World").transform;
            world.SetParent(transform);
            var belt = new GameObject("Belt", typeof(MeshFilter), typeof(MeshRenderer));
            belt.transform.SetParent(world);
            belt.GetComponent<MeshFilter>().sharedMesh = Planet.BeltMesh(0f, 1);
            belt.GetComponent<MeshRenderer>().sharedMaterial = Mats.Make(new Color(0.36f, 0.5f, 0.24f));
            MeshUtil.Show(world, "Sea", MeshUtil.Sphere(Planet.R - 0.6f, 192, 96), Mats.Make(new Color(0.12f, 0.36f, 0.5f), 0.85f));
            AddCap(world, "IceCap", Planet.R + 0.2f, Planet.LatOf(new Vector3(0, 0, 0)), Mathf.PI * 0.5f, new Color(0.9f, 0.94f, 0.97f));
            PlaceSampleBuildings(world);

        }

        /// <summary>A row of msp's kit buildings along a street near the starter town, drawn with the
        /// ported kit shader, to check the look before CityView is ported.</summary>
        void PlaceSampleBuildings(Transform parent)
        {
            Kit.Install();
            string[] names = { "r_1_1_a", "r_2_1_b", "c_3_1_a", "c_2_1_c", "i_2_1_a", "r_3_2_a", "c_3_2_b", "r_1_1_c" };
            float x0 = 1152f, z = 204f;
            var rng = new System.Random(7);
            for (int i = 0; i < names.Length; i++)
            {
                int zone = names[i][0] == 'r' ? 1 : names[i][0] == 'c' ? 2 : 3;
                int w = names[i][4] - '0';
                var flat = new GXform(GBasis.Identity, new Vector3(x0 + i * 24f + w * 6f, 0f, z - (w - 1) * 6f));
                var wall = Kit.WALLS[zone][rng.Next(Kit.WALLS[zone].Length)];
                var acc = Kit.ACCENTS[rng.Next(Kit.ACCENTS.Length)];
                var go = KitObject.Make(parent, names[i], Planet.Xf(flat), wall, new Color(acc.r, acc.g, acc.b, (float)rng.NextDouble()));
                if (go == null) Debug.LogWarning("[MSP] missing kit mesh " + names[i]);
            }
            // a road strip in front of them
            for (int i = 0; i < 20; i++)
            {
                var flat = new GXform(GBasis.Rotation(Vector3.up, Mathf.PI * 0.5f), new Vector3(x0 + i * 12f, 0f, z + 12f));
                KitObject.Make(parent, "road_straight", Planet.Xf(flat), Color.white, Color.white);
            }
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
