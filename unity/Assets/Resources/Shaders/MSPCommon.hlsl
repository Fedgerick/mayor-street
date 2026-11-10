// Port of shaders/common.gdshaderinc: shared globals and helpers for the city shaders.
// World positions passed to these helpers are in msp's Godot space (Unity world mirrored
// across X: GodotPos()).
#ifndef MSP_COMMON_INCLUDED
#define MSP_COMMON_INCLUDED

float night;           // 0 = full day, 1 = full night
float window_lit;      // fraction of windows lit right now
float3 sun_dir;        // toward the light, Unity space (DayNight.ApplyLight)
float overlay_mode;    // 0 none, 1 zones, 2 traffic, 3 land value
float tile_size;
float gfx_quality;     // 0 low, 1 medium, 2 high
float weather_wet;     // 0 dry .. 1 soaked
float planet_radius;   // 0 = flat world; else the ball's radius
float planet_v0;       // flat z of the equator
float orbit_view;      // 1 seen from orbit
float4 preview_color;
float grid_alpha;      // tile grid lines while a build tool is active
float2 map_size;       // city_map size in cells; 0 until CityView sets the maps
Texture2D city_map;    // R road, G zone, B traffic, A land value (point sampled)
Texture2D lamp_map;    // RG lamp head offset in tile, B has lamp
Texture2D preview_map; // R = tool preview

static const float3 LAMP_COLOR = float3(1.0, 0.72, 0.42);

float3 GodotPos(float3 u) { return float3(-u.x, u.y, u.z); }

float night_at(float3 wp)
{
    if (orbit_view <= 0.0) return night;
    float sun_up = dot(normalize(wp), GodotPos(sun_dir));
    return lerp(night, 1.0 - smoothstep(-0.12, 0.1, sun_up), orbit_view);
}

float window_lit_at(float3 wp)
{
    if (orbit_view <= 0.0) return window_lit;
    return lerp(window_lit, 0.3 * night_at(wp), orbit_view);
}

float hash12(float2 p) { float3 p3 = frac(p.xyx * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return frac((p3.x + p3.y) * p3.z); }
float hash13(float3 p3) { p3 = frac(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return frac((p3.x + p3.y) * p3.z); }

float vnoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash12(i), hash12(i + float2(1, 0)), u.x), lerp(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p)
{
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p *= 2.03; a *= 0.5; }
    return s;
}

float3 map_pos(float3 wp)
{
    if (planet_radius <= 0.0) return wp;
    float r = length(wp);
    float lat = asin(clamp(wp.y / r, -1.0, 1.0));
    float lon = atan2(wp.x, wp.z);
    if (lon < 0.0) lon += 6.28318530718;
    return float3(lon * planet_radius, r - planet_radius, planet_v0 - lat * planet_radius);
}

float3 map_warp(float3 mp)
{
    if (planet_radius <= 0.0) return mp;
    float lat = (planet_v0 - mp.z) / planet_radius;
    float lon = mp.x / planet_radius;
    return float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)) * (planet_radius + mp.y);
}

float3 up_at(float3 wp) { return planet_radius <= 0.0 ? float3(0, 1, 0) : normalize(wp); }

int2 cell_of(float3 wp) { return int2(floor(map_pos(wp).xz / max(tile_size, 0.001))); }

bool cell_ok(int2 c) { return map_size.x > 0.0 && c.x >= 0 && c.y >= 0 && c.x < (int)map_size.x && c.y < (int)map_size.y; }

int2 wrap_cell(int2 c)
{
    if (planet_radius > 0.0 && map_size.x > 0.0) c.x = (int)(c.x - map_size.x * floor(c.x / map_size.x));
    return c;
}

float4 city_at(int2 c)
{
    c = wrap_cell(c);
    if (!cell_ok(c)) return 0;
    return city_map.Load(int3(c, 0));
}

int zone_of(float4 cm) { return (int)(cm.g * 255.0 + 0.5) / 64; }
bool built_of(float4 cm) { return ((int)(cm.g * 255.0 + 0.5) % 64) >= 32; }
bool dark_of(float4 cm) { return ((int)(cm.g * 255.0 + 0.5) % 32) >= 16; }

float3 zone_rgb(int z)
{
    if (z == 1) return float3(0.25, 0.85, 0.35);
    if (z == 2) return float3(0.25, 0.55, 1.0);
    if (z == 3) return float3(1.0, 0.75, 0.15);
    return 0;
}

float3 heat(float t)
{
    t = saturate(t);
    return lerp(lerp(float3(0.15, 0.85, 0.3), float3(1.0, 0.85, 0.1), smoothstep(0.0, 0.5, t)), float3(1.0, 0.15, 0.1), smoothstep(0.5, 1.0, t));
}

// Street lamp light reaching a (Godot-space) world point: the lamps of the 3x3 tiles around it.
float3 lamp_light(float3 wp, float3 n)
{
    if (night < 0.02 || map_size.x <= 0.0) return 0;
    int2 c = cell_of(wp);
    float acc = 0.0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 cc = c + int2(dx, dy);
            int2 wc = wrap_cell(cc);
            if (!cell_ok(wc)) continue;
            float4 l = lamp_map.Load(int3(wc, 0));
            if (l.b < 0.5) continue;
            float3 lp = map_warp(float3((cc.x + l.r) * tile_size, 6.0, (cc.y + l.g) * tile_size));
            float3 d = lp - wp;
            float dist = length(d);
            float ndl = max(dot(n, d / dist), 0.0) * 0.7 + 0.3;
            float fall = 1.0 - smoothstep(0.0, 13.0, dist);
            acc += fall * fall * ndl;
        }
    return LAMP_COLOR * acc * night * 1.6;
}

float3 preview_tint(float3 wp)
{
    if (map_size.x <= 0.0) return 0;
    int2 c = wrap_cell(cell_of(wp));
    if (!cell_ok(c)) return 0;
    float p = preview_map.Load(int3(c, 0)).r;
    if (p < 0.01) return 0;
    float2 f = frac(map_pos(wp).xz / tile_size);
    float edge = max(smoothstep(0.42, 0.48, abs(f.x - 0.5)), smoothstep(0.42, 0.48, abs(f.y - 0.5)));
    return preview_color.rgb * (0.35 + edge * 0.65) * p;
}

#endif
