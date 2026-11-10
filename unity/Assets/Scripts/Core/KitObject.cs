using UnityEngine;

namespace MSP
{
    /// <summary>One kit mesh as a GameObject (for things that move or are few; CityView draws the
    /// city with instancing). The tints are msp's instance COLOR and CUSTOM (alpha = seed).</summary>
    public static class KitObject
    {
        static MaterialPropertyBlock _mpb;

        public static GameObject Make(Transform parent, string kitName, GXform xf, Color tint, Color custom)
        {
            var mesh = Kit.Mesh(kitName);
            if (mesh == null) return null;
            var go = new GameObject(kitName, typeof(MeshFilter), typeof(MeshRenderer));
            go.transform.SetParent(parent, false);
            go.GetComponent<MeshFilter>().sharedMesh = mesh;
            var mr = go.GetComponent<MeshRenderer>();
            mr.sharedMaterials = Kit.MaterialsFor(kitName);
            SetTints(mr, tint, custom);
            G.Apply(go.transform, xf);
            return go;
        }

        public static void SetTints(Renderer r, Color tint, Color custom, float buildTop = 1000f, float buildDone = 1000f)
        {
            _mpb ??= new MaterialPropertyBlock();
            r.GetPropertyBlock(_mpb);
            _mpb.SetVector("_InstColor", tint);
            _mpb.SetVector("_InstCustom", custom);
            _mpb.SetFloat("_BuildTop", buildTop);
            _mpb.SetFloat("_BuildDone", buildDone);
            r.SetPropertyBlock(_mpb);
        }
    }
}
