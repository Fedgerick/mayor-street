// Port of vehicles/shaders/vehicle.gdshader: every opaque part of a car in one material. The
// Blender car kit writes the part id into UV.x and a palette index into UV.y; tyres and rims
// carry their wheel centre (UV.y = x, UV2 = (z, y)) and spin and steer in the vertex stage.
//
// glTFast mirrors object space across X and imports v as 1 - v, relative to msp; both are
// undone first, so the code below is msp's in Godot space.
//
// Per renderer (MaterialPropertyBlock or instancing):
//   _InstColor.rgb    paint tint (P_PAINT parts)
//   _InstCustom.x     flags: 1 siren, 2 brake lights, 4 empty (hide driver), 8 headlights in daylight
//   _InstCustom.y     wheel roll angle, radians
//   _InstCustom.z     front wheel steer angle, radians (+ = left)
//   _InstCustom.w     seed 0..1
Shader "MSP/Vehicle"
{
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "MSPCommon.hlsl"

        UNITY_INSTANCING_BUFFER_START(Props)
            UNITY_DEFINE_INSTANCED_PROP(float4, _InstColor)
            UNITY_DEFINE_INSTANCED_PROP(float4, _InstCustom)
        UNITY_INSTANCING_BUFFER_END(Props)

        #define P_PAINT 0
        #define P_SOLID 1
        #define P_GLOSS 2
        #define P_CHROME 3
        #define P_TIRE 4
        #define P_RIM 5
        #define P_HEADLIGHT 6
        #define P_TAILLIGHT 7
        #define P_SIREN_R 8
        #define P_SIREN_B 9
        #define P_SKIN 10
        #define P_CLOTH 11
        #define P_HAIR 12
        #define P_AMBER 13
        #define P_BURNT 14
        #define P_GLASS_OPAQUE 15
        #define P_SIGN 16
        #define P_REVERSE 17
        #define P_BEACON 18

        struct Attributes
        {
            float4 pos : POSITION;
            float3 nrm : NORMAL;
            float2 uv : TEXCOORD0;
            float2 uv2 : TEXCOORD1;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        float3 rot_x(float3 p, float a) { float c = cos(a), s = sin(a); return float3(p.x, p.y * c - p.z * s, p.y * s + p.z * c); }
        float3 rot_y(float3 p, float a) { float c = cos(a), s = sin(a); return float3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c); }

        // Godot-space object position and normal after the wheels spin and steer, and the
        // passengers hide. part and pal come back for the fragment stage.
        void Deform(Attributes i, out float3 og, out float3 ng, out int part, out int pal, out int flags)
        {
            float4 cu = UNITY_ACCESS_INSTANCED_PROP(Props, _InstCustom);
            float2 uv = float2(i.uv.x, 1.0 - i.uv.y);
            float2 uv2 = float2(i.uv2.x, 1.0 - i.uv2.y);
            part = (int)(uv.x + 0.5);
            pal = (int)(uv.y + 0.5);
            flags = (int)(cu.x + 0.5);
            og = GodotPos(i.pos.xyz);
            ng = GodotPos(i.nrm);
            if (part == P_TIRE || part == P_RIM)
            {
                float3 c = float3(uv.y, uv2.y, uv2.x);
                float3 p = rot_x(og - c, -cu.y);
                float3 n = rot_x(ng, -cu.y);
                if (c.z < 0.0)
                {
                    p = rot_y(p, cu.z);
                    n = rot_y(n, cu.z);
                }
                og = p + c;
                ng = n;
                pal = 0;
            }
            if ((flags & 4) != 0 && (part == P_SKIN || part == P_CLOTH || part == P_HAIR)) og = 0;
        }
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
            #pragma multi_compile_instancing
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #pragma multi_compile _ _FORWARD_PLUS
            #include "MSPLit.hlsl"

            static const float3 PALETTE[16] = {
                float3(0.025, 0.025, 0.028), float3(0.09, 0.09, 0.1), float3(0.3, 0.3, 0.32), float3(0.62, 0.62, 0.6),
                float3(0.9, 0.9, 0.88), float3(0.98, 0.72, 0.05), float3(0.06, 0.08, 0.16), float3(0.72, 0.05, 0.04),
                float3(0.1, 0.42, 0.18), float3(0.08, 0.3, 0.68), float3(1.0, 0.55, 0.08), float3(0.42, 0.3, 0.2),
                float3(0.7, 0.71, 0.72), float3(0.55, 0.49, 0.4), float3(0.93, 0.9, 0.78), float3(1.0, 0.5, 0.05) };
            static const float3 SKINS[6] = {
                float3(0.96, 0.78, 0.64), float3(0.88, 0.66, 0.5), float3(0.72, 0.5, 0.34),
                float3(0.55, 0.36, 0.22), float3(0.38, 0.24, 0.15), float3(0.93, 0.72, 0.58) };
            static const float3 HAIRS[6] = {
                float3(0.06, 0.04, 0.03), float3(0.2, 0.12, 0.06), float3(0.45, 0.3, 0.14),
                float3(0.78, 0.62, 0.32), float3(0.6, 0.6, 0.6), float3(0.5, 0.18, 0.06) };
            static const float3 CLOTHES[8] = {
                float3(0.75, 0.15, 0.12), float3(0.15, 0.35, 0.7), float3(0.9, 0.88, 0.82), float3(0.18, 0.18, 0.2),
                float3(0.2, 0.55, 0.3), float3(0.95, 0.7, 0.15), float3(0.5, 0.3, 0.6), float3(0.85, 0.45, 0.25) };

            struct V
            {
                float4 pos : SV_POSITION;
                float3 opos : TEXCOORD0;
                float3 wposU : TEXCOORD1;
                float3 wnrmU : TEXCOORD2;
                nointerpolation int4 pf : TEXCOORD3;   // part, pal, flags
                float4 tint : TEXCOORD4;
                float seed : TEXCOORD5;
                float fog : TEXCOORD6;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_TRANSFER_INSTANCE_ID(i, o);
                float3 og, ng;
                int part, pal, flags;
                Deform(i, og, ng, part, pal, flags);
                o.opos = og;
                o.pf = int4(part, pal, flags, 0);
                o.wposU = TransformObjectToWorld(GodotPos(og));
                o.wnrmU = TransformObjectToWorldNormal(GodotPos(ng));
                o.pos = TransformWorldToHClip(o.wposU);
                o.tint = UNITY_ACCESS_INSTANCED_PROP(Props, _InstColor);
                o.seed = UNITY_ACCESS_INSTANCED_PROP(Props, _InstCustom).w;
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            float person_hash(float seed, float3 opos)
            {
                return hash12(float2(seed * 97.0, floor(opos.z * 1.5) + floor(opos.x * 2.0) * 7.0));
            }

            half4 frag(V i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                int part = i.pf.x, pal = i.pf.y, flags = i.pf.z;
                float3 opos = i.opos;
                float seed = i.seed;
                float3 wpos = GodotPos(i.wposU);
                float3 wnrm = normalize(GodotPos(i.wnrmU));
                float3 alb = 0.5;
                float r = 0.6, m = 0.0;
                float3 emit = 0;
                float lit_k = smoothstep(0.1, 0.5, night_at(wpos));
                float head_on = max(lit_k, (float)((flags & 8) != 0));
                if (part == P_PAINT || part == P_GLOSS)
                {
                    alb = part == P_PAINT ? i.tint.rgb : PALETTE[pal];
                    r = 0.28; m = 0.15;
                    alb *= lerp(0.72, 1.0, smoothstep(0.25, 0.75, opos.y));
                }
                else if (part == P_SOLID) { alb = PALETTE[pal]; r = 0.62; }
                else if (part == P_CHROME) { alb = float3(0.85, 0.86, 0.88); r = 0.12; m = 1.0; }
                else if (part == P_TIRE) { alb = float3(0.045, 0.045, 0.05); r = 0.88; }
                else if (part == P_RIM) { alb = float3(0.72, 0.73, 0.75); r = 0.3; m = 0.85; }
                else if (part == P_HEADLIGHT)
                {
                    alb = float3(0.85, 0.88, 0.9); r = 0.08;
                    emit = float3(1.0, 0.95, 0.84) * (0.12 + head_on * 5.0);
                }
                else if (part == P_TAILLIGHT)
                {
                    alb = float3(0.55, 0.03, 0.03); r = 0.15;
                    float brake = (float)((flags & 2) != 0);
                    emit = float3(1.0, 0.04, 0.02) * (0.3 + lit_k * 3.0 + brake * 5.0);
                }
                else if (part == P_SIREN_R || part == P_SIREN_B)
                {
                    bool red = part == P_SIREN_R;
                    alb = red ? float3(0.6, 0.04, 0.03) : float3(0.04, 0.1, 0.6);
                    r = 0.12;
                    float on = 0.0;
                    if ((flags & 1) != 0)
                    {
                        float t = frac(_Time.y * 1.6 + seed);
                        float ph = red ? t : frac(t + 0.5);
                        on = step(ph, 0.12) + step(0.2, ph) * step(ph, 0.32);
                    }
                    float3 col = red ? float3(1.0, 0.06, 0.03) : float3(0.08, 0.25, 1.0);
                    emit = col * (0.08 + on * 14.0);
                }
                else if (part == P_SKIN) { alb = SKINS[(int)(person_hash(seed, opos) * 5.99)]; r = 0.7; }
                else if (part == P_CLOTH)
                {
                    alb = pal == 0 ? CLOTHES[(int)(hash12(float2(seed * 31.0, 2.0)) * 7.99)] :
                        (pal >= 8 ? CLOTHES[(int)(person_hash(seed, opos) * 7.99)] : PALETTE[pal]);
                    r = 0.85;
                }
                else if (part == P_HAIR) { alb = HAIRS[(int)(hash12(float2(person_hash(seed, opos) * 13.0, 4.0)) * 5.99)]; r = 0.75; }
                else if (part == P_AMBER)
                {
                    alb = float3(0.9, 0.45, 0.05); r = 0.15;
                    emit = float3(1.0, 0.45, 0.05) * (0.1 + lit_k * 0.4);
                }
                else if (part == P_BURNT)
                {
                    float n = fbm(opos.xz * 3.0 + opos.y * 2.0);
                    alb = lerp(float3(0.035, 0.03, 0.028), float3(0.24, 0.11, 0.05), smoothstep(0.45, 0.75, n));
                    alb = lerp(alb, float3(0.16, 0.15, 0.14), (float)(pal == 1) * 0.6 * n);
                    r = 0.95;
                }
                else if (part == P_GLASS_OPAQUE) { alb = float3(0.04, 0.055, 0.07); r = 0.06; m = 0.4; }
                else if (part == P_SIGN) { alb = PALETTE[pal]; r = 0.4; emit = PALETTE[pal] * (0.15 + lit_k * 1.6); }
                else if (part == P_BEACON)
                {
                    alb = float3(0.8, 0.4, 0.04); r = 0.1;
                    float on = 0.0;
                    if ((flags & 1) != 0) on = step(frac(_Time.y * 1.8 + seed), 0.5);
                    emit = float3(1.0, 0.45, 0.03) * (0.1 + lit_k * 0.3 + on * 9.0);
                }
                else if (part == P_REVERSE) { alb = 0.8; r = 0.1; }
                emit += alb * lamp_light(wpos, wnrm);
                return MSPShade(i.wposU, i.wnrmU, i.pos, i.fog, alb, r, m, emit);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            ZWrite On ZTest LEqual ColorMask 0 Cull Back
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            float3 _LightDirection;
            float3 _LightPosition;
            struct V { float4 pos : SV_POSITION; };
            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                float3 og, ng;
                int part, pal, flags;
                Deform(i, og, ng, part, pal, flags);
                float3 wp = TransformObjectToWorld(GodotPos(og));
                float3 wn = TransformObjectToWorldNormal(GodotPos(ng));
                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 ld = normalize(_LightPosition - wp);
                #else
                    float3 ld = _LightDirection;
                #endif
                float4 cs = TransformWorldToHClip(ApplyShadowBias(wp, wn, ld));
                #if UNITY_REVERSED_Z
                    cs.z = min(cs.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    cs.z = max(cs.z, UNITY_NEAR_CLIP_VALUE);
                #endif
                o.pos = cs;
                return o;
            }
            half4 frag(V i) : SV_Target { return 0; }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On ColorMask R Cull Back
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            struct V { float4 pos : SV_POSITION; };
            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                float3 og, ng;
                int part, pal, flags;
                Deform(i, og, ng, part, pal, flags);
                o.pos = TransformObjectToHClip(GodotPos(og));
                return o;
            }
            half frag(V i) : SV_Target { return i.pos.z; }
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }
            ZWrite On Cull Back
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            struct V { float4 pos : SV_POSITION; float3 n : TEXCOORD0; };
            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                float3 og, ng;
                int part, pal, flags;
                Deform(i, og, ng, part, pal, flags);
                o.pos = TransformObjectToHClip(GodotPos(og));
                o.n = TransformObjectToWorldNormal(GodotPos(ng));
                return o;
            }
            half4 frag(V i) : SV_Target { return half4(NormalizeNormalPerPixel(i.n), 0.0); }
            ENDHLSL
        }
    }
}
