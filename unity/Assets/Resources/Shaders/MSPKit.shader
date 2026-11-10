// Port of shaders/kit.gdshader: one shader for every kit mesh (buildings, roads, props, cars).
// Kit.cs merges a model's materials into one submesh whose vertices carry a material number
// (uv3.x) that picks a row from the global tables _MatA/_MatB/_MatC, so a building is one
// draw call; cars keep one material per submesh (the _U* properties, _Merged = 0).
//
// Object-space data from glTFast is mirrored across X relative to msp (Godot); the vertex
// stage mirrors it back, so the fragment code below is msp's, line for line, in Godot space.
Shader "MSP/Kit"
{
    Properties
    {
        _Merged ("Merged", Float) = 1
        _UBase ("Base colour", Color) = (0.9, 0.9, 0.9, 1)
        _UTintSrc ("Tint source", Float) = 0
        _UTintAmount ("Tint amount", Float) = 1
        _UPattern ("Pattern", Float) = 0
        _UKind ("Kind", Float) = 0
        _URough ("Roughness", Float) = 0.85
        _UMetal ("Metallic", Float) = 0
        _UWind ("Wind", Float) = 0
        _UGround ("Ground level", Float) = 0
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "MSPCommon.hlsl"

        CBUFFER_START(UnityPerMaterial)
        float _Merged;
        float4 _UBase;
        float _UTintSrc, _UTintAmount, _UPattern, _UKind, _URough, _UMetal, _UWind, _UGround;
        CBUFFER_END

        float4 _MatA[32];  // base colour, tint amount
        float4 _MatB[32];  // roughness, metallic, specular, tint source
        float4 _MatC[32];  // pattern, kind, wind, ground level

        UNITY_INSTANCING_BUFFER_START(Props)
            UNITY_DEFINE_INSTANCED_PROP(float4, _InstColor)   // msp instance COLOR (wall tint)
            UNITY_DEFINE_INSTANCED_PROP(float4, _InstCustom)  // msp INSTANCE_CUSTOM (accent tint, a = seed)
            UNITY_DEFINE_INSTANCED_PROP(float, _BuildTop)     // construction: nothing above this yet
            UNITY_DEFINE_INSTANCED_PROP(float, _BuildDone)    // construction: bare frame above this
        UNITY_INSTANCING_BUFFER_END(Props)

        struct Attributes
        {
            float4 pos : POSITION;
            float3 nrm : NORMAL;
            float4 col : COLOR;
            float2 uv : TEXCOORD0;
            float2 uv2 : TEXCOORD1;
            float2 mid : TEXCOORD3;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        void MatRows(float mid, out float4 a, out float4 b, out float4 c)
        {
            if (_Merged > 0.5)
            {
                int i = (int)(mid + 0.5);
                a = _MatA[i]; b = _MatB[i]; c = _MatC[i];
            }
            else
            {
                a = float4(_UBase.rgb, _UTintAmount);
                b = float4(_URough, _UMetal, 0.5, _UTintSrc);
                c = float4(_UPattern, _UKind, _UWind, _UGround);
            }
        }

        // Godot-space object position after wind sway (msp's vertex()).
        float3 SwayedObjectPos(float3 og, float wind, float3 originG)
        {
            if (wind > 0.5)
            {
                float h = max(og.y - 1.2, 0.0);
                float t = _Time.y * 1.4 + originG.x * 0.05 + originG.z * 0.07;
                og.x += sin(t) * 0.035 * h;
                og.z += cos(t * 0.83) * 0.03 * h;
            }
            return og;
        }

        float3 ObjectOriginG() { return GodotPos(TransformObjectToWorld(float3(0, 0, 0))); }
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
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION
            #pragma multi_compile _ _FORWARD_PLUS
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Varyings
            {
                float4 pos : SV_POSITION;
                float3 opos : TEXCOORD0;   // Godot object space
                float3 onrm : TEXCOORD1;
                float3 wposU : TEXCOORD2;  // Unity world
                float3 wnrmU : TEXCOORD3;
                float4 uvs : TEXCOORD4;    // uv, uv2
                float3 oview : TEXCOORD5;  // camera -> vertex, Godot object space (glass)
                nointerpolation float4 ma : TEXCOORD6;
                nointerpolation float4 mb : TEXCOORD7;
                nointerpolation float4 mc : TEXCOORD8;
                float fog : TEXCOORD9;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings vert(Attributes i)
            {
                Varyings o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_TRANSFER_INSTANCE_ID(i, o);
                MatRows(i.mid.x, o.ma, o.mb, o.mc);
                float3 originG = ObjectOriginG();
                float3 og = GodotPos(i.pos.xyz);
                o.opos = og;
                o.onrm = GodotPos(i.nrm);
                og = SwayedObjectPos(og, o.mc.z, originG);
                float3 ou = GodotPos(og);
                o.wposU = TransformObjectToWorld(ou);
                o.wnrmU = TransformObjectToWorldNormal(i.nrm);
                o.pos = TransformWorldToHClip(o.wposU);
                o.uvs = float4(i.uv, i.uv2);
                o.oview = 0;
                if ((int)(o.mc.y + 0.5) == 1)
                    o.oview = GodotPos(i.pos.xyz - TransformWorldToObject(_WorldSpaceCameraPos));
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            float aa_fade(float2 uv) { float2 w = fwidth(uv); return saturate(1.0 - max(w.x, w.y) * 1.6); }
            float grid_line(float2 uv, float2 width)
            {
                float2 f = frac(uv);
                float2 d = min(f, 1.0 - f);
                float2 l = 1.0 - smoothstep(width * 0.5, width * 0.5 + fwidth(uv) * 1.2, d);
                return max(l.x, l.y);
            }
            float in_box(float2 p, float2 a, float2 b) { return step(a.x, p.x) * step(p.x, b.x) * step(a.y, p.y) * step(p.y, b.y); }

            static const float3 ROOM_WALLS[8] = {
                float3(0.78, 0.72, 0.6), float3(0.82, 0.82, 0.8), float3(0.52, 0.62, 0.74), float3(0.56, 0.66, 0.5),
                float3(0.86, 0.6, 0.5), float3(0.6, 0.58, 0.6), float3(0.86, 0.76, 0.46), float3(0.75, 0.78, 0.8) };
            static const float3 ROOM_FLOORS[5] = {
                float3(0.42, 0.26, 0.14), float3(0.22, 0.13, 0.07), float3(0.32, 0.32, 0.35), float3(0.2, 0.24, 0.38), float3(0.68, 0.66, 0.62) };
            static const float3 FURNITURE[6] = {
                float3(0.55, 0.2, 0.16), float3(0.2, 0.32, 0.5), float3(0.3, 0.3, 0.32), float3(0.62, 0.5, 0.36), float3(0.18, 0.4, 0.3), float3(0.75, 0.72, 0.68) };
            static const float3 RAIL_GLASS = float3(0.46, 0.53, 0.55);

            float2 bay_size(float2 size) { return size / max(float2(1, 1), floor(size / float2(3.8, 3.4) + 0.5)); }

            float3 room(float2 pane, float2 size, float3 d, float rid, bool shop, float detail, out float depth_k)
            {
                float3 p = float3(pane, 0.0);
                float3 bmin = 0;
                float3 bmax;
                float deep = 3.2 + 2.4 * hash12(float2(rid, 3.1));
                if (size.y < 4.5)
                {
                    float w = max(size.x + 1.4, 2.8);
                    bmin = float3(-(w - size.x) * 0.5, shop ? -0.15 : -0.9, 0.0);
                    bmax = float3(bmin.x + w, size.y + (shop ? 0.7 : 0.45), deep + (shop ? 3.0 : 0.0));
                }
                else
                {
                    float2 c = bay_size(size);
                    p.xy = pane - floor(pane / c) * c;
                    bmax = float3(c, deep + 2.0);
                }
                float h1 = hash12(float2(rid, 1.7));
                float h2 = hash12(float2(rid, 5.3));
                float3 wall = ROOM_WALLS[(int)(h1 * 7.99)];
                float3 flr = ROOM_FLOORS[(int)(h2 * 4.99)] * 0.85;
                float3 avg = wall * 0.7 + flr * 0.15 + 0.13;
                depth_k = 0.5;
                if (detail <= 0.0) return avg;
                d = float3(abs(d.x) < 1e-4 ? 1e-4 : d.x, abs(d.y) < 1e-4 ? 1e-4 : d.y, max(d.z, 1e-4));
                float3 tp = (lerp(bmin, bmax, step(0, d)) - p) / d;
                float t = min(tp.x, min(tp.y, tp.z));
                float3 hit = p + d * t;
                float3 col;
                if (t == tp.z)
                {
                    col = wall * 0.9;
                    if (shop)
                    {
                        float sy = hit.y - bmin.y;
                        float2 cell = float2(floor(hit.x / 0.4), floor(sy / 0.45));
                        float goods = step(0.3, sy) * step(sy, 2.1) * step(0.18, frac(sy / 0.45));
                        col = lerp(col, FURNITURE[(int)(hash12(cell + rid * 13.0) * 5.99)] * 1.15, goods * 0.9);
                    }
                    float fx0 = lerp(bmin.x, bmax.x, 0.1 + 0.3 * h2);
                    float fx1 = fx0 + (bmax.x - bmin.x) * (0.3 + 0.3 * h1);
                    float fh = shop ? 1.3 : 0.55 + 0.5 * h2;
                    col = lerp(col, FURNITURE[(int)(h2 * 5.99)], in_box(hit.xy, float2(fx0, bmin.y), float2(fx1, bmin.y + fh)) * 0.85);
                    float2 pc = float2(lerp(bmin.x, bmax.x, 0.3 + 0.4 * h1), bmin.y + 1.6);
                    col = lerp(col, FURNITURE[(int)(h1 * 5.99)] * 1.2, in_box(hit.xy, pc - float2(0.35, 0.25), pc + float2(0.35, 0.25)) * step(0.4, h2) * 0.8);
                }
                else if (t == tp.y)
                {
                    col = d.y < 0.0 ? flr : float3(0.86, 0.85, 0.82);
                }
                else
                {
                    col = wall * 0.78;
                    col = lerp(col, FURNITURE[(int)(h1 * 5.99)] * 0.8, step(0.6, h1) * step(hit.y, bmin.y + 1.9) * step(hit.z, bmax.z * 0.45) * 0.85);
                }
                depth_k = saturate(hit.z / bmax.z);
                return lerp(avg, col, detail);
            }

            bool is_rail(float2 size) { return size.y < 1.06 || size.x < 0.2; }

            float pane_id(float2 pane, float3 p_obj, float3 t, float3 b, float seed)
            {
                float3 corner = p_obj - t * pane.x - b * pane.y;
                return hash13(floor(corner * 2.0 + 0.371) + floor(frac(seed) * 4096.0));
            }

            float3 window_glass(float2 uv, float2 uv2, float3 n, float3 p_obj, float3 view, float seed, float wl, float nt,
                                out float3 emit_out, out float tall_k, out float clear_k)
            {
                // Godot keeps glTF's v (down from the top) and msp reads 1 - v; glTFast already
                // imports v as 1 - v (Unity's v runs up), so msp's 1 - v is plain uv.y here.
                // (Flipping again made size.y negative: every pane hit is_rail(), flat and unlit.)
                float2 pane = uv;
                float2 size = uv2;
                tall_k = 0.0;
                clear_k = 0.0;
                if (is_rail(size)) { emit_out = 0; return RAIL_GLASS; }
                float3 t = abs(n.y) > 0.99 ? float3(1, 0, 0) : normalize(cross(-n, float3(0, 1, 0)));
                float3 b = normalize(cross(n, t));
                float3 v = normalize(view);
                float3 d = float3(dot(v, t), dot(v, b), dot(v, -n));
                float rid = pane_id(pane, p_obj, t, b, seed);
                bool tall = size.y >= 4.5;
                if (tall) rid = hash12(floor(pane / bay_size(size)) + rid * 31.0);
                bool shop = !tall && size.x > 2.6 && (p_obj.y - pane.y) < 1.5;
                float2 fw = fwidth(pane);
                float detail = saturate(1.6 - max(fw.x, fw.y) * 9.0);
                float depth_k;
                float3 col = room(pane, size, d, rid, shop, detail, depth_k);
                float lit = step(hash12(float2(rid, 9.1)), wl);
                if (shop) lit = max(lit, step(0.3, nt) * step(0.24, wl));
                float cool = step(0.8, hash12(float2(rid, 4.4)));
                float3 lamp = lerp(float3(1.0, 0.7, 0.42), float3(0.72, 0.84, 1.0), cool) * (0.75 + 0.5 * hash12(float2(rid, 6.6)));
                float kind_h = hash12(float2(rid, 2.2));
                float cover = 0.0;
                float3 cloth = 0;
                float px = max(fw.x, fw.y);
                if (!shop)
                {
                    if (kind_h < 0.3)
                    {
                        float lvl = size.y * (0.25 + 0.6 * hash12(float2(rid, 8.8)));
                        cover = step(size.y - lvl, pane.y);
                        float slats = saturate(1.0 - px / 0.07 * 2.5);
                        cloth = float3(0.86, 0.83, 0.76) * (1.0 - 0.14 * slats * (0.5 + 0.5 * sin(pane.y / 0.07 * 6.2832)));
                    }
                    else if (kind_h < 0.5 && !tall)
                    {
                        float cw = size.x * (0.18 + 0.12 * hash12(float2(rid, 7.7)));
                        cover = 1.0 - step(cw, pane.x) * step(pane.x, size.x - cw);
                        float folds = saturate(1.0 - px / 0.35 * 2.5);
                        cloth = FURNITURE[(int)(hash12(float2(rid, 5.5)) * 5.99)] * (1.0 - 0.15 * folds * (0.5 + 0.5 * sin(pane.x * 18.0)));
                    }
                }
                float day = 1.0 - nt;
                float3 inside = col * day * (0.13 * lerp(1.0, 0.4, depth_k) + (shop ? 0.15 : 0.0));
                inside += col * lamp * lit * nt * lerp(1.0, 0.6, depth_k) * (shop ? 1.5 : 1.0);
                float3 front = cloth * (0.3 * day + lamp * lit * nt * 0.6);
                emit_out = lerp(inside, front, cover);
                tall_k = tall ? 1.0 : 0.0;
                clear_k = 1.0 - cover;
                return lerp(float3(0.02, 0.02, 0.02), cloth * 0.3, cover);
            }

            float3 window_flat(float2 uv, float2 uv2, float3 n, float3 p_obj, float seed, float wl, float nt, out float3 emit_out)
            {
                float2 pane = uv; // msp's (u, 1 - v): glTFast already flipped v (see window_glass)
                if (is_rail(uv2)) { emit_out = 0; return RAIL_GLASS; }
                float3 t = abs(n.y) > 0.99 ? float3(1, 0, 0) : normalize(cross(-n, float3(0, 1, 0)));
                float3 b = normalize(cross(n, t));
                float rid = pane_id(pane, p_obj, t, b, seed);
                float lit = step(hash12(float2(rid, 9.1)), wl);
                float3 lamp = float3(1.0, 0.72, 0.45) * (0.75 + 0.5 * hash12(float2(rid, 6.6)));
                float ceiling = 0.6 + 0.4 * smoothstep(0.2, 1.0, pane.y / max(uv2.y, 0.5));
                emit_out = lamp * lit * nt * ceiling + float3(0.03, 0.04, 0.05) * (1.0 - nt);
                return float3(0.03, 0.03, 0.03);
            }

            half4 frag(Varyings i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                float4 icolor = UNITY_ACCESS_INSTANCED_PROP(Props, _InstColor);
                float4 icustom = UNITY_ACCESS_INSTANCED_PROP(Props, _InstCustom);
                float buildTop = UNITY_ACCESS_INSTANCED_PROP(Props, _BuildTop);
                float buildDone = UNITY_ACCESS_INSTANCED_PROP(Props, _BuildDone);
                // unset instance props read 0: treat as "finished" (msp's default is 1000)
                if (buildTop <= 0.0) buildTop = 1000.0;
                if (buildDone == 0.0) buildDone = 1000.0;  // 0: unset (a site passes a real cut, which can be below 0)
                if (all(icolor == 0)) icolor = float4(1, 1, 1, 1);

                float3 opos = i.opos;
                float3 wpos = GodotPos(i.wposU);
                float3 wnrm = GodotPos(normalize(i.wnrmU));
                float3 origin = ObjectOriginG();
                float3 mpos = map_pos(wpos);
                float3 base_color = i.ma.rgb;
                float tint_amount = i.ma.w;
                float rough = i.mb.x, metal = i.mb.y;
                int tint_src = (int)(i.mb.w + 0.5);
                int pattern = (int)(i.mc.x + 0.5);
                int kind = (int)(i.mc.y + 0.5);
                bool ground_level = i.mc.w > 0.5;
                if (opos.y > buildTop) discard;
                float nt = night_at(wpos);
                float wl = window_lit_at(wpos);

                float3 n = normalize(i.onrm);
                float3 tint = tint_src == 1 ? icolor.rgb : (tint_src == 2 ? icustom.rgb : float3(1, 1, 1));
                float3 alb = base_color * lerp(float3(1, 1, 1), tint, tint_amount);
                float r = rough, m = metal;
                float seed = icustom.a;
                float2 wuv = abs(n.x) > abs(n.z) ? float2(opos.z, opos.y) : float2(opos.x, opos.y);
                float3 emit = 0;
                bool wall = abs(n.y) < 0.5 && !ground_level && kind == 0;

                if (pattern == 1 || pattern == 11)
                {
                    alb *= 0.93 + 0.12 * fbm(wuv * 0.35 + opos.xz * 0.2 + seed * 40.0);
                    if (pattern == 11)
                    {
                        alb *= 0.88 + 0.22 * fbm(opos.xz * 0.25 + seed * 9.0);
                        alb *= lerp(1.0, 0.92 + 0.16 * vnoise(opos.xz * 3.0), aa_fade(opos.xz * 3.0));
                        alb *= 0.5 + 0.62 * frac(seed * 5.31);
                        alb *= lerp(float3(1.07, 1.0, 0.9), float3(0.94, 0.98, 1.05), frac(seed * 3.77));
                    }
                }
                else if (pattern == 2)
                {
                    float2 uv = wuv / float2(0.55, 0.24);
                    float row = floor(uv.y);
                    uv.x += fmod(row, 2.0) * 0.5;
                    float2 cell = floor(uv);
                    float fade = aa_fade(uv);
                    float mortar = grid_line(uv, float2(0.08, 0.14)) * fade;
                    float bh = hash12(cell + seed * 13.0);
                    alb *= lerp(1.0, 0.82 + 0.3 * bh, fade);
                    alb *= 0.92 + 0.14 * fbm(wuv * 0.3 + seed * 7.0);
                    alb = lerp(alb, float3(0.62, 0.6, 0.56), mortar * 0.6);
                }
                else if (pattern == 3)
                {
                    float2 uv = wuv / float2(3.0, 1.55);
                    float fade = aa_fade(uv * 4.0);
                    alb *= 1.0 - grid_line(uv, float2(0.012, 0.025)) * 0.3 * fade;
                    alb *= 0.94 + 0.1 * hash12(floor(uv) + seed * 7.0) * fade;
                    alb *= 0.95 + 0.08 * fbm(wuv * 0.5);
                }
                else if (pattern == 4)
                {
                    float c = wuv.x / 0.22;
                    float fade = aa_fade(float2(c, c));
                    alb *= 1.0 + sin(c * 6.2832) * 0.09 * fade;
                    r = lerp(r, r * 0.7, (0.5 + 0.5 * sin(c * 6.2832)) * fade);
                    float rust = smoothstep(0.55, 0.8, fbm(wuv * 0.4 + seed * 17.0));
                    alb = lerp(alb, float3(0.42, 0.24, 0.14), rust * 0.45);
                }
                else if (pattern == 5)
                {
                    float2 uv = float2(wuv.x + opos.x + opos.z, opos.y) / float2(0.45, 0.3);
                    uv.x += fmod(floor(uv.y), 2.0) * 0.5;
                    float fade = aa_fade(uv);
                    alb *= 1.0 - grid_line(uv, float2(0.04, 0.2)) * 0.35 * fade;
                    alb *= lerp(1.0, 0.85 + 0.25 * hash12(floor(uv) + seed), fade);
                    alb *= 0.9 + 0.15 * fbm(opos.xz * 0.4 + seed * 5.0);
                }
                else if (pattern == 6 || pattern == 10)
                {
                    float2 uv = (pattern == 10 ? mpos.xz : opos.xz) / (pattern == 10 ? 1.5 : 1.0);
                    float fade = aa_fade(uv);
                    alb *= 1.0 - grid_line(uv, float2(0.04, 0.04)) * 0.22 * fade;
                    alb *= lerp(1.0, 0.93 + 0.12 * hash12(floor(uv)), fade);
                    alb *= 0.9 + 0.14 * fbm(mpos.xz * 0.25);
                    alb *= 1.0 - smoothstep(0.62, 0.72, fbm(mpos.xz * 0.9 + 4.0)) * 0.12 * aa_fade(mpos.xz * 0.9);
                }
                else if (pattern == 7)
                {
                    float g = fbm(mpos.xz * 0.06);
                    alb = lerp(float3(0.1, 0.25, 0.045), float3(0.2, 0.36, 0.07), g);
                    float stripe = step(0.5, frac(opos.x / 1.4));
                    alb *= lerp(1.0, 0.88 + 0.2 * stripe, aa_fade(opos.xz / 1.4));
                    alb *= lerp(1.0, 0.9 + 0.2 * vnoise(mpos.xz * 2.0), aa_fade(mpos.xz * 2.0));
                    alb = lerp(alb, float3(0.32, 0.3, 0.12), smoothstep(0.66, 0.8, fbm(mpos.xz * 0.15 + 9.0)) * 0.4);
                }
                else if (pattern == 8)
                {
                    alb *= 0.86 + 0.22 * fbm(mpos.xz * 0.4);
                    alb *= lerp(1.0, 0.92 + 0.12 * vnoise(mpos.xz * 9.0), aa_fade(mpos.xz * 9.0));
                    float patchk = smoothstep(0.62, 0.66, fbm(mpos.xz * 0.12 + 3.0));
                    alb *= 1.0 - patchk * 0.16;
                    float worn = smoothstep(0.58, 0.7, fbm(mpos.xz * 0.04 + 7.0));
                    float crack = 1.0 - smoothstep(0.0, 0.012, abs(fbm(mpos.xz * 0.7 + 11.0) - 0.5));
                    alb *= 1.0 - crack * worn * 0.2 * aa_fade(mpos.xz * 5.6);
                    r = lerp(r, 0.6, patchk * 0.5);
                }
                else if (pattern == 9)
                {
                    float s = step(0.5, frac((opos.x + opos.z) / 0.9));
                    alb = lerp(float3(0.95, 0.94, 0.9), alb, s);
                }

                if (wall)
                {
                    float basek = smoothstep(0.0, 2.4 + vnoise(float2(wuv.x * 0.8 + seed * 9.0, seed)) * 1.2, opos.y);
                    alb *= lerp(0.6, 1.0, basek);
                    float streak = vnoise(float2(wuv.x * 2.2 + seed * 31.0, opos.y * 0.12));
                    alb *= 1.0 - smoothstep(0.5, 0.95, streak) * 0.14 * aa_fade(float2(wuv.x * 2.2, wuv.x * 2.2));
                    alb *= 0.94 + 0.1 * fbm(wuv * 0.12 + seed * 3.0);
                    alb *= 1.0 + clamp(opos.y / 120.0, 0.0, 0.1);
                }

                if (kind == 1)
                {
                    float3 e;
                    float tall_k = 0.0, clear_k = 0.0;
                    if (gfx_quality < 0.5) alb = window_flat(i.uvs.xy, i.uvs.zw, n, opos, seed, wl, nt, e);
                    else alb = window_glass(i.uvs.xy, i.uvs.zw, n, opos, i.oview, seed, wl, nt, e, tall_k, clear_k);
                    emit += e;
                    r = 0.06;
                    m = tall_k * 0.55;
                    m = max(m, 0.5 * clear_k);
                    alb = lerp(alb, float3(0.16, 0.26, 0.3), tall_k * 0.5);
                }
                else if (kind == 7) { alb = float3(0.05, 0.07, 0.09); r = 0.04; m = 0.3; }
                else if (kind == 2) emit += alb * (0.25 + 1.2 * smoothstep(0.1, 0.6, nt));
                else if (kind == 3) emit += float3(1.0, 0.8, 0.55) * smoothstep(0.1, 0.5, nt) * 5.0;
                else if (kind == 5) emit += float3(1.0, 0.95, 0.82) * (0.15 + smoothstep(0.1, 0.5, nt) * 4.0);
                else if (kind == 6) emit += float3(1.0, 0.05, 0.03) * (0.35 + smoothstep(0.1, 0.5, nt) * 2.2);

                if (opos.y > buildDone && !ground_level && kind != 4)
                {
                    float storey = frac(opos.y / 3.4);
                    float slab = step(storey, 0.12);
                    if (kind == 1) alb = lerp(float3(0.03, 0.03, 0.03), float3(0.5, 0.49, 0.47), slab);
                    else alb = float3(0.55, 0.54, 0.51) * (0.86 + 0.16 * fbm(wuv * 0.5 + seed * 5.0)) * (1.0 - 0.18 * slab);
                    emit = 0;
                    r = 0.92;
                    m = 0.0;
                    kind = 0;
                }
                if (kind >= 1 && kind <= 3 && dark_of(city_at(cell_of(origin))))
                    emit *= 1.0 - smoothstep(0.1, 0.5, nt);

                int2 cell = ground_level ? cell_of(wpos)
                    : int2(floor((map_pos(origin).xz + (mpos.xz - map_pos(origin).xz) * 0.98) / max(tile_size, 0.001)));
                if (overlay_mode > 0.5)
                {
                    float4 cm = city_at(cell);
                    float lum = dot(alb, float3(0.3, 0.59, 0.11));
                    float3 grey = lum * 0.6 + 0.25;
                    if (overlay_mode < 1.5) { int z = zone_of(cm); alb = z > 0 ? lerp(grey, zone_rgb(z), 0.6) : grey; }
                    else if (overlay_mode < 2.5) alb = (pattern == 8 && cm.r > 0.5) ? heat(cm.b * 2.0) * 0.8 : grey;
                    else alb = cm.r > 0.5 ? grey : lerp(grey, heat(1.0 - cm.a), 0.65);
                    emit *= 0.3;
                }

                float wet_k = 0.0;
                if (weather_wet > 0.001 && kind == 0)
                {
                    float up = smoothstep(0.5, 0.9, dot(wnrm, up_at(wpos))) * (pattern == 7 ? 0.25 : 1.0);
                    wet_k = weather_wet * lerp(0.3, 1.0, up);
                    alb *= 1.0 - wet_k * (pattern == 0 || pattern == 4 ? 0.2 : 0.36);
                    r = lerp(r, 0.14, weather_wet * up);
                    if (pattern == 8 || pattern == 6 || pattern == 10)
                    {
                        float puddle = smoothstep(0.56, 0.62, fbm(mpos.xz * 0.11 + 21.0)) * smoothstep(0.35, 0.9, weather_wet) * up;
                        alb *= 1.0 - puddle * 0.4;
                        r = lerp(r, 0.03, puddle);
                        wet_k = max(wet_k, puddle);
                    }
                }

                if (kind != 3) emit += alb * lamp_light(wpos, wnrm) * (1.0 + wet_k * 1.5);
                emit += preview_tint(wpos) * (ground_level ? 1.0 : 0.5);

                // URP lighting
                InputData input = (InputData)0;
                input.positionWS = i.wposU;
                input.normalWS = normalize(i.wnrmU);
                input.viewDirectionWS = GetWorldSpaceNormalizeViewDir(i.wposU);
                input.shadowCoord = TransformWorldToShadowCoord(i.wposU);
                input.fogCoord = i.fog;
                input.bakedGI = SampleSH(input.normalWS);
                input.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(i.pos);
                input.shadowMask = half4(1, 1, 1, 1);
                SurfaceData s = (SurfaceData)0;
                s.albedo = alb;
                s.metallic = m;
                s.smoothness = 1.0 - r;
                s.occlusion = 1.0;
                s.emission = emit;
                s.alpha = 1.0;
                s.normalTS = float3(0, 0, 1);
                half4 color = UniversalFragmentPBR(input, s);
                if (kind == 4)
                {
                    // foliage backlight (msp BACKLIGHT = alb * 0.45): light coming through the leaves
                    Light ml = GetMainLight(input.shadowCoord);
                    color.rgb += alb * 0.45 * ml.color * ml.shadowAttenuation * saturate(-dot(input.normalWS, ml.direction));
                }
                color.rgb = MixFog(color.rgb, i.fog);
                return color;
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
            struct V { float4 pos : SV_POSITION; float oy : TEXCOORD0; UNITY_VERTEX_INPUT_INSTANCE_ID };
            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_TRANSFER_INSTANCE_ID(i, o);
                float4 a, b, c;
                MatRows(i.mid.x, a, b, c);
                float3 og = SwayedObjectPos(GodotPos(i.pos.xyz), c.z, ObjectOriginG());
                o.oy = og.y;
                float3 wp = TransformObjectToWorld(GodotPos(og));
                float3 wn = TransformObjectToWorldNormal(i.nrm);
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
            half4 frag(V i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                float top = UNITY_ACCESS_INSTANCED_PROP(Props, _BuildTop);
                if (top > 0.0 && i.oy > top) discard;
                return 0;
            }
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
            struct V { float4 pos : SV_POSITION; float oy : TEXCOORD0; UNITY_VERTEX_INPUT_INSTANCE_ID };
            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_TRANSFER_INSTANCE_ID(i, o);
                float4 a, b, c;
                MatRows(i.mid.x, a, b, c);
                float3 og = SwayedObjectPos(GodotPos(i.pos.xyz), c.z, ObjectOriginG());
                o.oy = og.y;
                o.pos = TransformObjectToHClip(GodotPos(og));
                return o;
            }
            half frag(V i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                float top = UNITY_ACCESS_INSTANCED_PROP(Props, _BuildTop);
                if (top > 0.0 && i.oy > top) discard;
                return i.pos.z;
            }
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
            struct V { float4 pos : SV_POSITION; float3 n : TEXCOORD0; float oy : TEXCOORD1; UNITY_VERTEX_INPUT_INSTANCE_ID };
            V vert(Attributes i)
            {
                V o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_TRANSFER_INSTANCE_ID(i, o);
                float4 a, b, c;
                MatRows(i.mid.x, a, b, c);
                float3 og = SwayedObjectPos(GodotPos(i.pos.xyz), c.z, ObjectOriginG());
                o.oy = og.y;
                o.pos = TransformObjectToHClip(GodotPos(og));
                o.n = TransformObjectToWorldNormal(i.nrm);
                return o;
            }
            half4 frag(V i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                float top = UNITY_ACCESS_INSTANCED_PROP(Props, _BuildTop);
                if (top > 0.0 && i.oy > top) discard;
                return half4(NormalizeNormalPerPixel(i.n), 0.0);
            }
            ENDHLSL
        }
    }
}
