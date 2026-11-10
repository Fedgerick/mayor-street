// Port of vehicles/shaders/vehicle_glass.gdshader: car windows, tinted, see-through in the
// middle and mirror-like at grazing angles. UV.x = 1 on cracked glass (damage stages).
Shader "MSP/VehicleGlass"
{
    SubShader
    {
        Tags { "RenderType" = "Transparent" "RenderPipeline" = "UniversalPipeline" "Queue" = "Transparent+1" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "MSPCommon.hlsl"
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite On
            Cull Back
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct A { float4 pos : POSITION; float3 nrm : NORMAL; float2 uv : TEXCOORD0; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct V
            {
                float4 pos : SV_POSITION;
                float3 opos : TEXCOORD0;
                float3 wposU : TEXCOORD1;
                float3 nrmU : TEXCOORD2;
                float cracked : TEXCOORD3;
                float fog : TEXCOORD4;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            V vert(A i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_TRANSFER_INSTANCE_ID(i, o);
                o.opos = GodotPos(i.pos.xyz);
                o.cracked = i.uv.x;
                o.wposU = TransformObjectToWorld(i.pos.xyz);
                o.nrmU = TransformObjectToWorldNormal(i.nrm);
                o.pos = TransformWorldToHClip(o.wposU);
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            float crack_lines(float2 p)
            {
                float2 c0 = floor(p);
                float2 f = frac(p);
                float d1 = 8.0, d2 = 8.0;
                for (int y = -1; y <= 1; y++)
                    for (int x = -1; x <= 1; x++)
                    {
                        float2 o = float2(x, y);
                        float2 c = o + float2(hash12(c0 + o), hash12(c0 + o + 17.0)) - f;
                        float d = dot(c, c);
                        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
                    }
                return 1.0 - smoothstep(0.0, 0.06, sqrt(d2) - sqrt(d1));
            }

            half4 frag(V i) : SV_Target
            {
                float3 n = normalize(i.nrmU);
                float3 view = GetWorldSpaceNormalizeViewDir(i.wposU);
                float f = pow(1.0 - saturate(dot(n, view)), 3.0);
                float3 alb = float3(0.05, 0.07, 0.085);
                float a = lerp(0.34, 0.92, f);
                if (i.cracked > 0.5)
                {
                    float2 p = float2(i.opos.x + i.opos.z, i.opos.y) * 7.0;
                    float c = crack_lines(p) * 0.8 + crack_lines(p * 2.3) * 0.4;
                    alb = lerp(alb, float3(0.75, 0.8, 0.82), saturate(c));
                    a = max(a, clamp(c, 0.0, 0.85) + 0.15);
                }
                InputData input = (InputData)0;
                input.positionWS = i.wposU;
                input.normalWS = n;
                input.viewDirectionWS = view;
                input.shadowCoord = TransformWorldToShadowCoord(i.wposU);
                input.fogCoord = i.fog;
                input.bakedGI = SampleSH(n);
                input.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(i.pos);
                input.shadowMask = half4(1, 1, 1, 1);
                SurfaceData s = (SurfaceData)0;
                s.albedo = alb;
                s.metallic = 0.0;
                s.smoothness = 0.96;
                s.occlusion = 1.0;
                s.alpha = a;
                s.normalTS = float3(0, 0, 1);
                half4 c = UniversalFragmentPBR(input, s);
                c.rgb = MixFog(c.rgb, i.fog);
                c.a = a;
                return c;
            }
            ENDHLSL
        }
    }
}
