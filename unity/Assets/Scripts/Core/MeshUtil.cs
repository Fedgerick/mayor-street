// Small mesh helpers. Rule for meshes built in Godot space and written through G.U():
// keep Godot's triangle order, i.e. triangles wound clockwise seen from their front side in
// Godot space (checked on the laptop build: the mirror does not flip what reaches the screen).
using UnityEngine;

namespace MSP
{
    public static class MeshUtil
    {
        /// <summary>A UV sphere of the given radius centred on the origin (Unity space, outward faces).</summary>
        public static Mesh Sphere(float radius, int segs, int rings)
        {
            var verts = new Vector3[(rings + 1) * (segs + 1)];
            var norms = new Vector3[verts.Length];
            var uvs = new Vector2[verts.Length];
            int k = 0;
            for (int j = 0; j <= rings; j++)
            {
                float lat = -Mathf.PI * 0.5f + Mathf.PI * j / rings; // south to north
                for (int i = 0; i <= segs; i++)
                {
                    Vector3 d = Planet.DirAt(lat, G.TAU * i / segs);
                    verts[k] = G.U(d * radius);
                    norms[k] = G.U(d);
                    uvs[k] = new Vector2((float)i / segs, (float)j / rings);
                    k++;
                }
            }
            var idx = new int[rings * segs * 6];
            k = 0;
            for (int j = 0; j < rings; j++)
                for (int i = 0; i < segs; i++)
                {
                    int a = j * (segs + 1) + i, b = a + segs + 1; // b is one ring north
                    idx[k++] = a; idx[k++] = b; idx[k++] = a + 1;
                    idx[k++] = a + 1; idx[k++] = b; idx[k++] = b + 1;
                }
            var m = new Mesh { indexFormat = UnityEngine.Rendering.IndexFormat.UInt32, vertices = verts, normals = norms, uv = uvs, triangles = idx };
            m.RecalculateBounds();
            return m;
        }

        public static GameObject Show(Transform parent, string name, Mesh mesh, Material mat)
        {
            var go = new GameObject(name, typeof(MeshFilter), typeof(MeshRenderer));
            go.transform.SetParent(parent, false);
            go.GetComponent<MeshFilter>().sharedMesh = mesh;
            go.GetComponent<MeshRenderer>().sharedMaterial = mat;
            return go;
        }
    }
}
