// Port of scripts/catalog.gd: every building the Mayor can buy plus the milestone tiers that
// unlock them. The data is generated into CatalogData.cs by tools/gen_catalog.py.
using System.Collections.Generic;
using System.Linq;
using UnityEngine;

namespace MSP
{
    public static partial class Catalog
    {
        public static readonly string[] GROUPS = { "power", "parks", "garbage", "safety", "business", "street", "landmarks" };
        public static readonly Dictionary<string, string> GROUP_NAMES = new Dictionary<string, string>
        {
            { "power", "Power" }, { "parks", "Parks" }, { "garbage", "Garbage" }, { "safety", "Safety" },
            { "business", "Business" }, { "street", "Street" }, { "landmarks", "Landmarks" },
        };

        /// <summary>A door spot in the model's own space (x right, z toward the street).</summary>
        public class Door
        {
            public float x, z, yawDeg;
            public Door(float x, float z, float yawDeg) { this.x = x; this.z = z; this.yawDeg = yawDeg; }
        }

        public class Def
        {
            public string id, name, group, placement, interior, unlockHint, desc, standIn, kitModel;
            public int size, cost, tier, unlockPop;
            public float upkeep, height;
            public string[] tags;
            public bool unique, needsRoad, menu;
            public Color accent, color;
            public Door door;
            public bool HasTag(string t) => System.Array.IndexOf(tags, t) >= 0;
            /// <summary>"" when the model isn't baked into the kit.</summary>
            public string Model => kitModel != "" && Kit.Has(kitModel) ? kitModel : "";
        }

        /// <summary>A milestone tier. pop/income of 0: no such goal. any: either goal is enough.</summary>
        public class Tier
        {
            public string name;
            public int pop, income;
            public bool any;
        }

        static Dictionary<string, Def> _byId;

        static Dictionary<string, Def> ById
        {
            get
            {
                if (_byId == null)
                {
                    _byId = new Dictionary<string, Def>();
                    foreach (var d in DEFS) _byId[d.id] = d;
                }
                return _byId;
            }
        }

        /// <summary>The entry for an id, or null for an unknown one.</summary>
        public static Def GetDef(string id) => id != null && ById.TryGetValue(id, out var d) ? d : null;

        public static bool Has(string id) => id != null && ById.ContainsKey(id);

        /// <summary>Ids in build menu order; one group only when given. Spawned-only buildings are
        /// left out unless all is true.</summary>
        public static List<string> Ids(string group = "", bool all = false) =>
            DEFS.Where(d => (group == "" || d.group == group) && (all || d.menu)).Select(d => d.id).ToList();

        public static List<string> WithTag(string tag) => DEFS.Where(d => d.HasTag(tag)).Select(d => d.id).ToList();

        /// <summary>Ids unlocked by population alone, with the people each needs.</summary>
        public static Dictionary<string, int> PopUnlocks() =>
            DEFS.Where(d => d.unlockPop > 0).ToDictionary(d => d.id, d => d.unlockPop);

        public static List<string> IdsForTier(int t) => DEFS.Where(d => d.tier == t).Select(d => d.id).ToList();

        public static bool GoalMet(int t, int pop, double income)
        {
            if (t <= 0) return true;
            if (t >= TIERS.Length) return false;
            var g = TIERS[t];
            var met = new List<bool>();
            if (g.pop > 0) met.Add(pop >= g.pop);
            if (g.income > 0) met.Add(income >= g.income);
            if (g.any) return met.Contains(true);
            return !met.Contains(false);
        }

        /// <summary>"Reach 5,000 people", for a tier's goal.</summary>
        public static string GoalText(int t)
        {
            if (t <= 0 || t >= TIERS.Length) return "";
            var g = TIERS[t];
            var parts = new List<string>();
            if (g.pop > 0) parts.Add(Thousands(g.pop) + " people");
            if (g.income > 0) parts.Add("$" + Thousands(g.income) + " income per resident");
            return "Reach " + string.Join(g.any ? " or " : " and ", parts);
        }

        /// <summary>What a locked build menu entry shows.</summary>
        public static string LockText(string id)
        {
            var d = GetDef(id);
            if (d == null) return "";
            if (d.tier < 0) return d.unlockHint != "" ? d.unlockHint : "Unlocked by a quest";
            return GoalText(d.tier) + (d.unlockHint != "" ? " " + d.unlockHint : "");
        }

        public static string Thousands(long n)
        {
            string s = System.Math.Abs(n).ToString();
            string o = "";
            while (s.Length > 3)
            {
                o = "," + s.Substring(s.Length - 3) + o;
                s = s.Substring(0, s.Length - 3);
            }
            return (n < 0 ? "-" : "") + s + o;
        }
    }
}
