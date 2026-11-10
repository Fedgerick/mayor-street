// Port of shaders/standin.gdshader: distant buildings as plain boxes (CityView stand-ins): the
// wall colour, a grid of windows that light up at night like the kit's, and a darker roof.
// uv = wall metres (roof: y < 0), uv2.x = the building's seed, colour = wall tint.
Shader "MSP/Standin"
{
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "MSPCommon.hlsl"
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #include "MSPLit.hlsl"

            struct A { float4 pos : POSITION; float3 nrm : NORMAL; float4 col : COLOR; float2 uv : TEXCOORD0; float2 uv2 : TEXCOORD1; };
            struct V
            {
                float4 pos : SV_POSITION;
                float3 wposU : TEXCOORD0;
                float3 nrmU : TEXCOORD1;
                float3 wcol : TEXCOORD2;
                float2 uv : TEXCOORD3;
                nointerpolation float seed : TEXCOORD4;
                float fog : TEXCOORD5;
            };

            V vert(A i)
            {
                V o;
                o.wposU = TransformObjectToWorld(i.pos.xyz);
                o.pos = TransformWorldToHClip(o.wposU);
                o.nrmU = TransformObjectToWorldNormal(i.nrm);
                o.wcol = i.col.rgb;
                o.uv = i.uv;
                o.seed = i.uv2.x;
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            half4 frag(V i) : SV_Target
            {
                float3 wpos = GodotPos(i.wposU);
                bool roof = i.uv.y < 0.0;
                float3 alb = i.wcol * 0.78;
                float glass = 0.0, lit = 0.0;
                if (roof) alb = i.wcol * 0.42;
                else
                {
                    float2 cell = float2(i.uv.x / 2.6, (i.uv.y - 4.0) / 3.0);
                    float2 f = frac(cell);
                    glass = step(0.0, cell.y) * step(0.18, f.x) * step(f.x, 0.82) * step(0.22, f.y) * step(f.y, 0.8);
                    float rid = floor(cell.y) * 37.0 + floor(cell.x) + i.seed * 1000.0;
                    lit = glass * step(hash12(float2(rid, 9.1)), window_lit_at(wpos));
                    alb = lerp(alb, float3(0.16, 0.2, 0.25), glass * 0.8);
                }
                float3 emit = lit * night_at(wpos) * float3(1.0, 0.78, 0.5) * 1.6;
                return MSPShade(i.wposU, i.nrmU, i.pos, i.fog, alb, lerp(0.85, 0.2, glass), 0.0, emit);
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On ColorMask R Cull Back
            HLSLPROGRAM
            #pragma vertex MSPDepthVert
            #pragma fragment MSPDepthFrag
            #include "MSPLit.hlsl"
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }
            ZWrite On Cull Back
            HLSLPROGRAM
            #pragma vertex MSPDepthVert
            #pragma fragment MSPDepthNormalsFrag
            #include "MSPLit.hlsl"
            ENDHLSL
        }
    }
}
