// One entry of City.buildings or City.sites (msp keeps them as Dictionaries; the fixed keys are
// fields here and anything other systems add goes in `extra`).
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class Building
    {
        public int id, x, y, size, zone, stage, rot, tint, tint2;
        public long variant;
        public double seed, born;
        public bool connected = true;
        /// <summary>Catalog id for catalog buildings, null for zone buildings.</summary>
        public string kind;
        public string name;
        public string[] tags;
        /// <summary>Sites only: 0..1 done, and the game minutes the job takes.</summary>
        public double built, dur;
        public readonly Dictionary<string, object> extra = new Dictionary<string, object>();

        public bool HasKind => kind != null;
        public bool HasTag(string t) => tags != null && System.Array.IndexOf(tags, t) >= 0;
        public RectInt Rect => new RectInt(x, y, Mathf.Max(size, 1), Mathf.Max(size, 1));

        public T Get<T>(string key, T fallback = default) =>
            extra.TryGetValue(key, out var v) && v is T t ? t : fallback;
    }
}
