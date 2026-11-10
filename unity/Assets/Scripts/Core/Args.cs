using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    /// <summary>Command-line options, msp style: --name=value (or --name for "1").</summary>
    public static class Args
    {
        static Dictionary<string, string> _map;

        public static Dictionary<string, string> Map
        {
            get
            {
                if (_map != null) return _map;
                _map = new Dictionary<string, string>();
                foreach (string a in System.Environment.GetCommandLineArgs())
                {
                    if (!a.StartsWith("--")) continue;
                    string s = a.Substring(2);
                    int eq = s.IndexOf('=');
                    if (eq < 0) _map[s] = "1";
                    else _map[s.Substring(0, eq)] = s.Substring(eq + 1);
                }
                return _map;
            }
        }

        public static bool Has(string k) => Map.ContainsKey(k);
        public static string Get(string k, string def = "") => Map.TryGetValue(k, out var v) ? v : def;
        public static float GetF(string k, float def) => Map.TryGetValue(k, out var v) && float.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var f) ? f : def;
        public static int GetI(string k, int def) => Map.TryGetValue(k, out var v) && int.TryParse(v, out var i) ? i : def;
    }
}
