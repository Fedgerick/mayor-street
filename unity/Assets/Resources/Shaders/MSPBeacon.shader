// Port of shaders/beacon.gdshader: red aircraft warning lights on the tallest towers, dim by
// day and pulsing at night, growing with distance so each stays a visible point. Instanced.
Shader "MSP/Beacon"
{
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }
        Pass
        {
            Name "Unlit"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "MSPCommon.hlsl"

            struct A { float4 pos : POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct V { float4 pos : SV_POSITION; float phase : TEXCOORD0; };

            V vert(A i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                float3 oU = TransformObjectToWorld(float3(0, 0, 0));
                float3 og = GodotPos(oU);
                o.phase = frac(sin(dot(og.xz, float2(12.9898, 78.233))) * 43758.5453);
                float d = length(oU - GetCameraPositionWS());
                float3 wp = oU + (TransformObjectToWorld(i.pos.xyz) - oU) * clamp(d * 0.006, 1.0, 6.0);
                o.pos = TransformWorldToHClip(wp);
                return o;
            }

            half4 frag(V i) : SV_Target
            {
                float t = frac(_Time.y * 0.5 + i.phase);
                float pulse = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.45, 0.7, t));
                float k = smoothstep(0.2, 0.6, night);
                return half4(float3(1.0, 0.07, 0.03) * lerp(0.35, 0.6 + 7.0 * pulse, k), 1.0);
            }
            ENDHLSL
        }
    }
}
