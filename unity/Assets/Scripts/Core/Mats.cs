using UnityEngine;

namespace MSP
{
    /// <summary>URP materials made in code (the port builds its look at runtime, as msp does).</summary>
    public static class Mats
    {
        // Template materials saved by MSPBuild.Setup in Resources/Mats, so their shaders ship in
        // the build (Shader.Find alone can miss shaders no asset references).
        static Material _lit, _unlit;

        public static Material LitTemplate => _lit ??= Resources.Load<Material>("Mats/Lit") ?? new Material(Shader.Find("Universal Render Pipeline/Lit"));
        public static Material UnlitTemplate => _unlit ??= Resources.Load<Material>("Mats/Unlit") ?? new Material(Shader.Find("Universal Render Pipeline/Unlit"));

        public static Material Make(Color c, float smooth = 0.1f, float metal = 0f)
        {
            var m = new Material(LitTemplate);
            m.SetColor("_BaseColor", c);
            m.SetFloat("_Smoothness", smooth);
            m.SetFloat("_Metallic", metal);
            m.enableInstancing = true;
            return m;
        }

        public static Material MakeUnlit(Color c)
        {
            var m = new Material(UnlitTemplate);
            m.SetColor("_BaseColor", c);
            return m;
        }
    }
}
