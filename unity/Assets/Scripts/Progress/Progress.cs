// Port of the core of scripts/progress.gd (the "Progress" autoload): what the whole game
// shares (the Resident's cash and goodness, unlock flags, the milestone tier, city stats,
// story flags and counters). Saves come later.
using System;
using System.Collections.Generic;

namespace MSP
{
    public class Progress
    {
        public static Progress I { get; private set; } = new Progress();

        public event Action<string, string> Unlocked;         // id, source
        public event Action<int, string, List<string>> TierReached;
        public event Action<string> Notice;                   // good news for the HUD
        public event Action<int, int, string> CashChanged;    // cash, delta, reason
        public event Action<double, double, string> GoodnessChanged;

        public City city;
        public int cash;
        public double goodness;
        public readonly Dictionary<string, string> unlocks = new Dictionary<string, string>();
        public int cityTier;
        public readonly Dictionary<string, double> stats = new Dictionary<string, double>();
        public readonly Dictionary<string, object> flags = new Dictionary<string, object>();
        public readonly Dictionary<string, int> counts = new Dictionary<string, int>();
        public bool playing;

        // ------------------------------------------------------------ wallets ---

        public void AddCash(int n, string reason = "")
        {
            cash += n;
            CashChanged?.Invoke(cash, n, reason);
        }

        public bool SpendCash(int n, string reason = "")
        {
            if (cash < n) return false;
            cash -= n;
            CashChanged?.Invoke(cash, -n, reason);
            return true;
        }

        public void AddGoodness(double delta, string reason = "") => SetGoodness(goodness + delta, reason);

        public void SetGoodness(double v, string reason = "")
        {
            v = Math.Max(-100.0, Math.Min(100.0, v));
            double d = v - goodness;
            goodness = v;
            GoodnessChanged?.Invoke(goodness, d, reason);
        }

        /// <summary>-4 (Kingpin) .. 4 (Hero), one step per 25 points.</summary>
        public int GoodnessTier() => Math.Sign(goodness) * Math.Min((int)(Math.Abs(goodness) / 25.0), 4);

        // ------------------------------------------------------------ unlocks ---

        public bool Unlock(string id, string source = "")
        {
            if (!DoUnlock(id, source)) return false;
            var d = Catalog.GetDef(id);
            if (d != null && d.menu) Notice?.Invoke($"Unlocked: {d.name}. It's in the build menu");
            return true;
        }

        public bool IsUnlocked(string id) => unlocks.ContainsKey(id);

        bool DoUnlock(string id, string source)
        {
            if (unlocks.ContainsKey(id)) return false;
            unlocks[id] = source;
            Unlocked?.Invoke(id, source);
            return true;
        }

        /// <summary>Unlocks every catalog building up to tier t and announces the milestone.</summary>
        public void ReachTier(int t)
        {
            t = Math.Min(t, Catalog.TIERS.Length - 1);
            if (t <= cityTier) return;
            var ids = new List<string>();
            for (int tt = cityTier + 1; tt <= t; tt++)
                foreach (var id in Catalog.IdsForTier(tt))
                    if (DoUnlock(id, "tier:" + tt)) ids.Add(id);
            cityTier = t;
            string tierName = Catalog.TIERS[t].name;
            int n = 0;
            foreach (var id in ids) if (Catalog.GetDef(id).menu) n++;
            Notice?.Invoke($"Milestone: {tierName}! {n} new buildings in the build menu (B)");
            TierReached?.Invoke(t, tierName, ids);
        }

        public void CheckMilestones()
        {
            if (city == null) return;
            double income = stats.TryGetValue("income_per_resident", out var v) ? v : 0.0;
            int t = cityTier;
            while (t + 1 < Catalog.TIERS.Length && Catalog.GoalMet(t + 1, city.population, income)) t++;
            ReachTier(t);
            foreach (var kv in Catalog.PopUnlocks())
                if (city.population >= kv.Value && !unlocks.ContainsKey(kv.Key)) Unlock(kv.Key, "pop:" + kv.Value);
        }

        public void SetStat(string key, double value) => stats[key] = value;

        void CityStats()
        {
            if (city == null) return;
            stats["population"] = city.population;
            stats["jobs"] = city.jobsC + city.jobsI;
        }

        public void SetFlag(string key, object value) => flags[key] = value;
        public object GetFlag(string key, object fallback = null) => flags.TryGetValue(key, out var v) ? v : fallback;

        public int Count(string key, int n = 1)
        {
            counts.TryGetValue(key, out int c);
            counts[key] = c + n;
            return c + n;
        }

        // ---------------------------------------------------------- lifecycle ---

        /// <summary>Called once the city exists. Resets everything to a new game first.</summary>
        public void Begin(City c)
        {
            if (city != null) city.DayPassed -= OnDay;
            city = c;
            city.isUnlocked = IsUnlocked;
            cash = 0;
            goodness = 0.0;
            unlocks.Clear();
            cityTier = 0;
            stats.Clear();
            flags.Clear();
            counts.Clear();
            foreach (var id in Catalog.IdsForTier(0)) unlocks[id] = "start";
            CityStats();
            city.DayPassed += OnDay;
            playing = true;
        }

        /// <summary>After everything is set up: a ready-made city starts at the tier it has earned.</summary>
        public void Started() => CheckMilestones();

        void OnDay()
        {
            CityStats();
            CheckMilestones();
        }
    }
}
