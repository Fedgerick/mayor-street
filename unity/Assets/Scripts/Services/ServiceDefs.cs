// Port of services/service_defs.gd: the numbers services compute with, keyed by catalog id
// (name, size, cost, upkeep, tier and tags live in Catalog).
using System.Collections.Generic;

namespace MSP
{
    public static class ServiceDefs
    {
        public class Def
        {
            public string service;
            public float mw, radius, strength = 1f, tons;
        }

        public static readonly Dictionary<string, Def> DEFS = new Dictionary<string, Def>
        {
            { "coal_plant", new Def { service = "power", mw = 80f } },
            { "gas_plant", new Def { service = "power", mw = 160f } },
            { "solar_farm", new Def { service = "power", mw = 60f } },
            { "wind_turbine", new Def { service = "power", mw = 10f } },
            { "small_park", new Def { service = "park", radius = 4f, strength = 0.6f } },
            { "plaza", new Def { service = "park", radius = 5f, strength = 0.7f } },
            { "sports_field", new Def { service = "park", radius = 7f, strength = 0.8f } },
            { "city_park", new Def { service = "park", radius = 11f, strength = 1f } },
            { "stadium", new Def { service = "park", radius = 8f, strength = 0.5f } },
            { "garbage_depot", new Def { service = "garbage", radius = 16f, tons = 60f } },
            { "recycling_center", new Def { service = "garbage", radius = 20f, tons = 100f } },
            { "landfill", new Def { service = "garbage", radius = 12f, tons = 45f } },
            { "police_station", new Def { service = "police", radius = 13f, strength = 1f } },
            { "police_hq", new Def { service = "police", radius = 22f, strength = 1.4f } },
            { "fire_station", new Def { service = "fire", radius = 14f, strength = 1f } },
        };

        /// <summary>Power demand in MW per resident / job, by zone.</summary>
        public static readonly double[] MW_PER_CAP = { 0.0, 0.004, 0.006, 0.01 };
        /// <summary>Garbage in tons per day per resident / job, by zone.</summary>
        public static readonly double[] TONS_PER_CAP = { 0.0, 0.002, 0.003, 0.005 };
        public const double SPECIAL_MW = 0.4;
        public const double SPECIAL_TONS = 0.2;
        public const double POWER_LINE_UPKEEP = 0.05;

        public static bool Has(string kind) => kind != null && DEFS.ContainsKey(kind);
        public static Def Get(string kind) => kind != null && DEFS.TryGetValue(kind, out var d) ? d : null;
        public static string ServiceOf(string kind) => Get(kind)?.service ?? "";
    }
}
