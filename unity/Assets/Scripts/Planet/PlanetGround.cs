// Port of planet/planet_ground.gd: the planet's ground (one sphere terrain mesh, fine across
// the belt and coarse toward the poles, ice cap tinted in by vertex colour) with its
// collision, and the sea sphere whose shader reads the sea floor near the south shore.
using System;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public static class PlanetGround
    {
        /// <summary>height, landness and ice take flat map metres (x, z). Returns the terrain's collider.</summary>
        public static MeshCollider Build(Transform parent, int rowsH, Func<double, double, double> height,
            Func<double, double, double> landness, Func<double, double, double> ice)
        {
            var rows = Rows(rowsH);
            int cols = Planet.W * 2;
            float step = Planet.Circumference() / cols;
            int nr = rows.Count, nc = cols + 1;
            var verts = new Vector3[nr * nc];
            var norms = new Vector3[nr * nc];
            var colors = new Color[nr * nc];
            var hs = new float[nr * nc];
            for (int j = 0; j < nr; j++)
                for (int i = 0; i < nc; i++)
                    hs[j * nc + i] = (float)height(i * step, rows[j]) - 0.03f;
            for (int j = 0; j < nr; j++)
                for (int i = 0; i < nc; i++)
                {
                    int k = j * nc + i;
                    float x = i * step, z = rows[j];
                    var p = new Vector3(x, hs[k], z);
                    verts[k] = G.U(Planet.Warp(p));
                    float hl = hs[j * nc + Math.Max(i - 1, 0)];
                    float hr = hs[j * nc + Math.Min(i + 1, nc - 1)];
                    float hu = hs[Math.Max(j - 1, 0) * nc + i];
                    float hd = hs[Math.Min(j + 1, nr - 1) * nc + i];
                    float dz = Mathf.Max(rows[Math.Min(j + 1, nr - 1)] - rows[Math.Max(j - 1, 0)], 0.1f);
                    var ln = new Vector3((hl - hr) / (2f * step), 1f, (hu - hd) / dz).normalized;
                    norms[k] = G.U(Planet.Frame(p) * ln);
                    colors[k] = new Color(Mathf.Clamp01((float)landness(x, z)), (float)ice(x, z), 0f, 1f);
                }
            var idx = new int[(nr - 1) * (nc - 1) * 6];
            int t = 0;
            for (int j = 0; j < nr - 1; j++)
                for (int i = 0; i < nc - 1; i++)
                {
                    int a = j * nc + i, b = a + 1, c = a + nc, d = c + 1;
                    idx[t++] = a; idx[t++] = b; idx[t++] = c;   // Godot's order (see MeshUtil)
                    idx[t++] = b; idx[t++] = d; idx[t++] = c;
                }
            var mesh = new Mesh { name = "Terrain", indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
            mesh.vertices = verts;
            mesh.normals = norms;
            mesh.colors = colors;
            mesh.triangles = idx;
            mesh.RecalculateBounds();
            var mat = new Material(Resources.Load<Shader>("Shaders/MSPTerrain")) { name = "Terrain" };
            var go = MeshUtil.Show(parent, "Terrain", mesh, mat);
            go.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            var col = go.AddComponent<MeshCollider>();
            col.sharedMesh = mesh;
            BuildSea(parent, rowsH, height, nc, step);
            return col;
        }

        /// <summary>Rows of the terrain mesh in flat z: coarse from the north pole to the belt, every
        /// half tile across the belt and its shores, coarse again to the south pole.</summary>
        static List<float> Rows(int rowsH)
        {
            float north = Planet.V0 - Planet.R * Mathf.PI * 0.5f;
            float south = Planet.V0 + Planet.R * Mathf.PI * 0.5f;
            float fine0 = -60f;
            float fine1 = rowsH * Planet.TILE + 60f;
            var rows = new List<float>();
            float z = north;
            while (z < fine0) { rows.Add(z); z += 24f; }
            z = fine0;
            while (z < fine1) { rows.Add(z); z += Planet.TILE * 0.5f; }
            z = fine1;
            while (z < south) { rows.Add(z); z += 24f; }
            rows.Add(south);
            return rows;
        }

        static void BuildSea(Transform parent, int rowsH, Func<double, double, double> height, int nc, float step)
        {
            float z0 = rowsH * Planet.TILE - 120f;
            float z1 = rowsH * Planet.TILE + 300f;
            const int ih = 128;
            var img = new Texture2D(nc, ih, TextureFormat.RFloat, false, true)
            {
                name = "SeaFloor", wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Bilinear,
            };
            var px = new float[nc * ih];
            for (int j = 0; j < ih; j++)
            {
                float z = Mathf.Lerp(z0, z1, (float)j / (ih - 1));
                for (int i = 0; i < nc; i++) px[j * nc + i] = (float)(-height(i * step, z) / 16.0);
            }
            img.SetPixelData(px, 0);
            img.Apply(false, true);
            var mat = new Material(Resources.Load<Shader>("Shaders/MSPWater")) { name = "Sea" };
            mat.SetTexture("_HeightTex", img);
            mat.SetVector("_HeightRect", new Vector4(0f, z0, Planet.Circumference(), z1 - z0));
            mat.SetTexture("_WaveA", WaveNormals(0.03f, 3, 6f));
            mat.SetTexture("_WaveB", WaveNormals(0.05f, 9, 4f));
            var go = MeshUtil.Show(parent, "Sea", MeshUtil.Sphere(Planet.R - 0.7f, 256, 128), mat);
            go.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        }

        /// <summary>Godot's NoiseTexture2D (256², seamless, as a normal map) for the sea's waves:
        /// tangent-space normals in rgb, as msp's wave_a / wave_b.</summary>
        static Texture2D WaveNormals(float freq, int seed, float bump)
        {
            const int S = 256;
            var n = new GodotNoise { Seed = seed, Frequency = freq };
            // Seamless: sample the noise on a torus (4D is not in FastNoiseLite, so blend the
            // four shifted copies as Godot's seamless option does).
            var h = new float[S * S];
            for (int y = 0; y < S; y++)
                for (int x = 0; x < S; x++)
                {
                    float fx = (float)x / S, fy = (float)y / S;
                    float a = n.Get2D(x, y), b = n.Get2D(x - S, y), c = n.Get2D(x, y - S), d = n.Get2D(x - S, y - S);
                    h[y * S + x] = Mathf.Lerp(Mathf.Lerp(a, b, fx), Mathf.Lerp(c, d, fx), fy) * 0.5f + 0.5f;
                }
            var tex = new Texture2D(S, S, TextureFormat.RGBA32, true, true) { name = "Waves", wrapMode = TextureWrapMode.Repeat, filterMode = FilterMode.Trilinear };
            var px = new Color32[S * S];
            for (int y = 0; y < S; y++)
                for (int x = 0; x < S; x++)
                {
                    float l = h[y * S + (x + S - 1) % S], r = h[y * S + (x + 1) % S];
                    float u = h[((y + S - 1) % S) * S + x], dn = h[((y + 1) % S) * S + x];
                    var nv = new Vector3((l - r) * bump, (u - dn) * bump, 1f).normalized;
                    px[y * S + x] = new Color32((byte)((nv.x * 0.5f + 0.5f) * 255f), (byte)((nv.y * 0.5f + 0.5f) * 255f), (byte)((nv.z * 0.5f + 0.5f) * 255f), 255);
                }
            tex.SetPixels32(px);
            tex.Apply(true, true);
            return tex;
        }
    }
}
