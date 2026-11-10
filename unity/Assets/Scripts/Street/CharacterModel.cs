// Port of player/scripts/character_model.gd: a street person, the rigged wardrobe in
// player/assets/character.glb (copied to Resources/Characters by MSPBuild), dressed by seed, and
// animated like msp's AnimationTree: idle / walk / jog / run blended by speed with the feet
// planted, jump and fall in the air, a landing, sitting in cars and on benches, idle variations,
// talking and phone calls on the upper body, and one-shots (get in / out of a car, wave,
// punches, reloads, flinch, stumble, knocked down, getting up, carjack, dying).
//
// Port notes: msp merges the chosen parts into one mesh; here the glb's part renderers are
// switched on and off (same look, a few more draw calls up close). The AnimationTree becomes
// weights on legacy Animation states, worked out each frame by the same blend rules; the upper-
// body filters become layer-1 states with the UPPER bones as mixing transforms.
using System;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class CharacterModel
    {
        public const string RESOURCE = "Characters/character";
        public const float WALK_SPEED = 3.6f, RUN_SPEED = 7.2f;
        static readonly string[] GAITS = { "Walk", "Jog", "Run" };
        static readonly float[] GAIT_AT = { 1.4f, 3.6f, 7.2f };
        static readonly float[] STRIDES = { 1.24f, 2.3f, 3.4f };
        const float MOVE_FROM = 0.08f, MOVE_FULL = 0.7f;
        public const float SEAT_SHIFT = 0.4f;
        static readonly string[] LOOPS = { "Idle", "IdleLook", "IdleArms", "Walk", "Jog", "Run", "Jump", "Fall", "Sit", "SitBench",
            "Talk", "Phone", "AimPistol", "AimShotgun", "Umbrella" };
        static readonly string[] UPPER = { "Chest", "Neck", "Head", "Jaw",
            "UpperArm.L", "LowerArm.L", "Hand.L", "Fingers1.L", "Fingers2.L", "Thumb.L",
            "UpperArm.R", "LowerArm.R", "Hand.R", "Fingers1.R", "Fingers2.R", "Thumb.R" };
        public enum Aim { NONE, PISTOL, SHOTGUN }

        public static readonly Color[] SKIN = { new Color(0.98f, 0.8f, 0.66f), new Color(0.89f, 0.66f, 0.5f), new Color(0.7f, 0.48f, 0.34f), new Color(0.47f, 0.31f, 0.21f), new Color(0.99f, 0.87f, 0.76f) };
        public static readonly Color[] SHIRT = { new Color(0.9f, 0.28f, 0.22f), new Color(0.2f, 0.47f, 0.86f), new Color(0.98f, 0.78f, 0.2f), new Color(0.24f, 0.68f, 0.45f), new Color(0.95f, 0.95f, 0.93f), new Color(0.55f, 0.3f, 0.72f), new Color(0.13f, 0.14f, 0.17f), new Color(0.98f, 0.55f, 0.2f) };
        public static readonly Color[] PANTS = { new Color(0.17f, 0.22f, 0.38f), new Color(0.14f, 0.14f, 0.16f), new Color(0.47f, 0.39f, 0.28f), new Color(0.3f, 0.32f, 0.36f), new Color(0.58f, 0.52f, 0.43f) };
        public static readonly Color[] HAIR = { new Color(0.12f, 0.09f, 0.07f), new Color(0.36f, 0.21f, 0.1f), new Color(0.8f, 0.6f, 0.32f), new Color(0.58f, 0.16f, 0.08f), new Color(0.22f, 0.22f, 0.24f) };
        public static readonly Color[] SHOES = { new Color(0.96f, 0.96f, 0.96f), new Color(0.1f, 0.1f, 0.11f), new Color(0.62f, 0.26f, 0.15f), new Color(0.85f, 0.2f, 0.2f) };
        public static readonly Color[] JACKET = { new Color(0.16f, 0.13f, 0.11f), new Color(0.36f, 0.22f, 0.12f), new Color(0.2f, 0.26f, 0.2f), new Color(0.18f, 0.22f, 0.34f), new Color(0.55f, 0.5f, 0.42f), new Color(0.6f, 0.12f, 0.1f) };
        public static readonly Color[] HAT = { new Color(0.12f, 0.12f, 0.14f), new Color(0.75f, 0.15f, 0.12f), new Color(0.15f, 0.3f, 0.6f), new Color(0.85f, 0.8f, 0.7f), new Color(0.2f, 0.45f, 0.25f) };
        static readonly string[] NO_HAT_HAIR = { "long", "bun", "mohawk", "afro" };
        static readonly Dictionary<string, float> ROUGH = new Dictionary<string, float>
        {
            { "Skin", 0.55f }, { "Hair", 0.85f }, { "Brows", 0.85f }, { "Shoes", 0.45f }, { "Shirt", 0.78f }, { "Jacket", 0.55f },
            { "Pants", 0.85f }, { "Hat", 0.7f }, { "Eyes", 0.15f }, { "EyeWhite", 0.3f }, { "Stubble", 0.95f },
        };
        static readonly string[] PUNCHES = { "Jab", "Punch", "Hook" };
        static readonly string[] ONE_SHOTS_UPPER = { "Jab", "Punch", "Hook", "Hit", "Wave", "ReloadPistol", "ReloadShotgun" };
        static readonly string[] ONE_SHOTS_FULL = { "Land", "SitDown", "StandUp", "EnterCar", "ExitCar", "Carjack", "Stumble", "GetUp" };
        static readonly string[] IDLE_VARIANTS = { "look", "arms", "bench" };
        static readonly string[] UPPER_ACTS = { "talk", "phone", "umbrella" };

        public int seedValue = 7;
        public bool autoIdle = true;
        public GameObject root;            // the instantiated glb
        public Animation anim;
        public readonly Dictionary<string, string> outfit = new Dictionary<string, string>();
        public readonly Dictionary<string, Color> colors = new Dictionary<string, Color>();
        public string activity = "";
        public bool visible = true;

        // the transform the owner gives each frame (Godot space): where the person stands and faces
        public GXform body = GXform.Identity;
        public float yaw;            // visual.rotation.y
        public float sink;           // visual.position.y = -sink

        float _air, _sit, _lean, _aim, _dead, _idlevar, _upperAct, _still, _autoT, _phase;
        bool _sitting, _deadOn, _down, _autoOn;
        string _sitKind = "car";
        Aim _aimKind = Aim.NONE;
        int _combo;
        float _lastPunch = -10f;
        readonly Dictionary<string, float> _pick = new Dictionary<string, float>();   // transition weights (idle_pick, sit_pick, act_pick)
        readonly Dictionary<string, Shot> _shots = new Dictionary<string, Shot>();
        readonly Dictionary<string, Renderer> _parts = new Dictionary<string, Renderer>();
        readonly Dictionary<string, string> _manualOutfit = new Dictionary<string, string>();
        readonly Dictionary<string, Color> _manualColors = new Dictionary<string, Color>();
        static readonly Dictionary<string, Material> _matCache = new Dictionary<string, Material>();
        Transform _hand;
        GameObject _phone;

        class Shot { public float t = -1f, len, fadeIn, fadeOut; public bool upper; }

        public static bool Available() => Resources.Load<GameObject>(RESOURCE) != null;

        public CharacterModel(Transform parent, int seed)
        {
            seedValue = seed;
            var prefab = Resources.Load<GameObject>(RESOURCE);
            root = prefab != null ? UnityEngine.Object.Instantiate(prefab, parent) : new GameObject("Character (missing glb)");
            root.name = "Character";
            anim = root.GetComponentInChildren<Animation>();
            if (anim == null)
            {
                Debug.LogWarning("[MSP] character.glb has no legacy Animation component (set its glTFast import to Legacy animation)");
            }
            else
            {
                anim.playAutomatically = false;
                anim.cullingType = AnimationCullingType.AlwaysAnimate;
                var upperBones = new List<Transform>();
                foreach (var t in root.GetComponentsInChildren<Transform>(true))
                    if (Array.IndexOf(UPPER, t.name) >= 0) upperBones.Add(t);
                foreach (AnimationState st in anim)
                {
                    string n = st.name;
                    st.wrapMode = Array.IndexOf(LOOPS, n) >= 0 ? WrapMode.Loop : WrapMode.ClampForever;
                    st.weight = 0f;
                    st.enabled = false;
                    st.layer = 0;
                    bool upper = Array.IndexOf(ONE_SHOTS_UPPER, n) >= 0 || n == "Talk" || n == "Phone" || n == "Umbrella" || n == "AimPistol" || n == "AimShotgun";
                    if (upper)
                    {
                        st.layer = 1;
                        foreach (var b in upperBones) st.AddMixingTransform(b, false);
                    }
                }
            }
            foreach (var n in ONE_SHOTS_UPPER) _shots[n] = new Shot { len = ClipLength(n), fadeIn = 0.05f, fadeOut = 0.12f, upper = true };
            _shots["Land"] = new Shot { len = ClipLength("Land"), fadeIn = 0.05f, fadeOut = 0.15f };
            _shots["SitDown"] = new Shot { len = ClipLength("SitDown"), fadeIn = 0f, fadeOut = 0.12f };
            _shots["StandUp"] = new Shot { len = ClipLength("StandUp"), fadeIn = 0f, fadeOut = 0.12f };
            _shots["EnterCar"] = new Shot { len = ClipLength("EnterCar"), fadeIn = 0.08f, fadeOut = 0.12f };
            _shots["ExitCar"] = new Shot { len = ClipLength("ExitCar"), fadeIn = 0.08f, fadeOut = 0.12f };
            _shots["Carjack"] = new Shot { len = ClipLength("Carjack"), fadeIn = 0.08f, fadeOut = 0.15f };
            _shots["Stumble"] = new Shot { len = ClipLength("Stumble"), fadeIn = 0.08f, fadeOut = 0.15f };
            _shots["GetUp"] = new Shot { len = ClipLength("GetUp"), fadeIn = 0f, fadeOut = 0.2f };
            foreach (var r in root.GetComponentsInChildren<Renderer>(true))
            {
                _parts[r.gameObject.name] = r;
                r.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.On;
                if (r is SkinnedMeshRenderer smr) smr.updateWhenOffscreen = true;
            }
            foreach (var t in root.GetComponentsInChildren<Transform>(true)) if (t.name == "Hand.R") _hand = t;
            _pick["idle:look"] = 1f;
            _pick["sit:car"] = 1f;
            _pick["act:talk"] = 1f;
            Dress();
        }

        // ----------------------------------------------------------------- wardrobe ---

        public struct Look
        {
            public Dictionary<string, string> styles;
            public Dictionary<string, Color> colors;
        }

        /// <summary>The outfit and colours a seed gives (the same picks as msp, from Godot's RNG).</summary>
        public static Look LookForSeed(int s)
        {
            var rng = new GodotRng((ulong)(long)s);
            Color Pick(Color[] a) => a[(int)(rng.Randi() % a.Length)];
            var cols = new Dictionary<string, Color>
            {
                { "Skin", Pick(SKIN) }, { "Shirt", Pick(SHIRT) }, { "Pants", Pick(PANTS) }, { "Hair", Pick(HAIR) }, { "Shoes", Pick(SHOES) },
            };
            cols["Jacket"] = Pick(JACKET);
            cols["Hat"] = Pick(HAT);
            string top = Weighted(rng, ("tee", 4f), ("longsleeve", 2f), ("hoodie", 2f), ("jacket", 2f), ("tank", 1f));
            string bottom = Weighted(rng, ("jeans", 6f), ("shorts", 2f), ("skirt", 2f));
            string hair = Weighted(rng, ("short", 5f), ("buzz", 2f), ("bald", 1f), ("long", 3f), ("ponytail", 2f), ("bun", 1f), ("mohawk", 0.4f), ("afro", 1f));
            string face = Weighted(rng, ("clean", 8f), ("stubble", 2f), ("mustache", 1f), ("beard", 1.5f), ("glasses", 1.5f), ("shades", 1f));
            if ((bottom == "skirt" || hair == "long" || hair == "ponytail" || hair == "bun") && (face == "stubble" || face == "mustache" || face == "beard"))
                face = "clean";
            string hat = "";
            if (Array.IndexOf(NO_HAT_HAIR, hair) < 0 && rng.Randf() < 0.22f) hat = rng.Randf() < 0.6f ? "cap" : "beanie";
            string shoes = rng.Randf() < 0.25f ? "boots" : "sneakers";
            return new Look
            {
                styles = new Dictionary<string, string> { { "top", top }, { "bottom", bottom }, { "shoes", shoes }, { "hat", hat }, { "hair", hair }, { "face", face } },
                colors = cols,
            };
        }

        static string Weighted(GodotRng rng, params (string k, float w)[] w)
        {
            float total = 0f;
            foreach (var e in w) total += e.w;
            float r = (float)(rng.Randf() * total);
            foreach (var e in w)
            {
                r -= e.w;
                if (r <= 0f) return e.k;
            }
            return w[0].k;
        }

        public void SetOutfit(Dictionary<string, string> styles, Dictionary<string, Color> cols = null)
        {
            if (styles != null) foreach (var kv in styles) _manualOutfit[kv.Key] = kv.Value;
            if (cols != null) foreach (var kv in cols) _manualColors[kv.Key] = kv.Value;
            Dress();
        }

        public List<string> PartNames()
        {
            var p = new List<string> { "Head_skin", "Brows", "Hands", "Top_" + outfit["top"], "Bottom_" + outfit["bottom"], "Shoes_" + outfit["shoes"] };
            if (outfit["hair"] != "bald" && outfit["hair"] != "") p.Add("Hair_" + outfit["hair"]);
            if (outfit["face"] != "clean" && outfit["face"] != "") p.Add("Face_" + outfit["face"]);
            if (outfit["hat"] != "") p.Add("Hat_" + outfit["hat"]);
            return p;
        }

        static Color Darkened(Color c, float a) => new Color(c.r * (1f - a), c.g * (1f - a), c.b * (1f - a), c.a);

        void Dress()
        {
            var look = LookForSeed(seedValue);
            colors.Clear();
            foreach (var kv in look.colors) colors[kv.Key] = kv.Value;
            foreach (var kv in _manualColors) colors[kv.Key] = kv.Value;
            outfit.Clear();
            foreach (var kv in look.styles) outfit[kv.Key] = kv.Value;
            foreach (var kv in _manualOutfit) outfit[kv.Key] = kv.Value;
            colors["Brows"] = _manualColors.TryGetValue("Brows", out var br) ? br : Darkened(colors["Hair"], 0.15f);
            colors["Stubble"] = _manualColors.TryGetValue("Stubble", out var sb) ? sb : Darkened(Color.Lerp(colors["Skin"], colors["Hair"], 0.35f), 0.1f);
            colors["Eyes"] = _manualColors.TryGetValue("Eyes", out var ey) ? ey : new Color(0.03f, 0.03f, 0.04f);
            colors["EyeWhite"] = new Color(0.92f, 0.91f, 0.88f);
            var on = new HashSet<string>(PartNames());
            foreach (var kv in _parts)
            {
                bool show = on.Contains(kv.Key);
                kv.Value.enabled = show;
                if (!show) continue;
                var src = kv.Value.sharedMaterials;
                var mats = new Material[src.Length];
                for (int i = 0; i < src.Length; i++) mats[i] = SlotMaterial(src[i] != null ? Kit.CleanName(src[i].name) : "Skin");
                kv.Value.sharedMaterials = mats;
            }
        }

        Material SlotMaterial(string slot)
        {
            // glTFast may name a material "Skin" or "Skin (Instance)"; CleanName strips the suffixes
            if (!colors.TryGetValue(slot, out var col)) col = new Color(0.5f, 0.5f, 0.5f);
            float rough = ROUGH.TryGetValue(slot, out var r) ? r : 0.7f;
            string key = slot + "|" + ColorUtility.ToHtmlStringRGB(col) + "|" + rough;
            if (_matCache.TryGetValue(key, out var m) && m != null) return m;
            m = Mats.Make(col, 1f - rough);
            m.name = slot;
            _matCache[key] = m;
            return m;
        }

        // ------------------------------------------------------------------ animation ---

        /// <summary>speed: horizontal m/s. onFloor: grounded. vy: vertical velocity. turn: yaw rate (rad/s).</summary>
        public void Animate(float delta, float speed, bool onFloor, float vy, float turn)
        {
            _air = G.MoveToward(_air, onFloor ? 0f : 1f, delta * (onFloor ? 8f : 5f));
            _sit = G.MoveToward(_sit, _sitting ? 1f : 0f, delta * 6f);
            _aim = G.MoveToward(_aim, _aimKind == Aim.NONE ? 0f : 1f, delta * 8f);
            bool still = speed < 0.3f && onFloor && !_sitting && _aimKind == Aim.NONE && !_deadOn && !_down;
            _still = still ? _still + delta : 0f;
            AutoIdle(delta, still);
            bool wantVar = still && Array.IndexOf(IDLE_VARIANTS, activity) >= 0;
            _idlevar = G.MoveToward(_idlevar, wantVar ? 1f : 0f, delta * (wantVar ? 2.5f : 5f));
            bool wantUp = Array.IndexOf(UPPER_ACTS, activity) >= 0 && _aimKind == Aim.NONE && !_deadOn;
            _upperAct = G.MoveToward(_upperAct, wantUp ? 1f : 0f, delta * 4f);
            _dead = G.MoveToward(_dead, _deadOn ? 1f : 0f, delta * 10f);
            string sitKind = _sitKind == "bench" || activity == "bench" ? "bench" : "car";
            Fade("sit:", sitKind, new[] { "car", "bench" }, delta / 0.2f);
            Fade("idle:", activity == "look" || activity == "arms" || activity == "bench" ? activity : CurrentPick("idle:"), IDLE_VARIANTS, delta / 0.4f);
            Fade("act:", wantUp ? activity : CurrentPick("act:"), UPPER_ACTS, delta / 0.3f);
            _lean = Mathf.Lerp(_lean, Mathf.Clamp(-turn * speed * 0.02f, -0.25f, 0.25f), 1f - Mathf.Exp(-8f * delta));

            if (anim != null) Weigh(delta, speed, vy);
            Pose();
        }

        string CurrentPick(string group)
        {
            string best = null;
            float bw = -1f;
            foreach (var kv in _pick)
                if (kv.Key.StartsWith(group) && kv.Value > bw) { bw = kv.Value; best = kv.Key.Substring(group.Length); }
            return best;
        }

        void Fade(string group, string want, string[] all, float step)
        {
            foreach (var k in all)
            {
                _pick.TryGetValue(group + k, out float w);
                _pick[group + k] = G.MoveToward(w, k == want ? 1f : 0f, step);
            }
        }

        float P(string key) => _pick.TryGetValue(key, out var v) ? v : 0f;

        void Weigh(float delta, float speed, float vy)
        {
            var w = new Dictionary<string, float>();
            void Add(string n, float x) { if (x > 0f) { w.TryGetValue(n, out var o); w[n] = o + x; } }
            void Scale(float k) { foreach (var key in new List<string>(w.Keys)) w[key] *= k; }

            // locomotion: a 1D blend space over the gaits, synced, played at the planted-feet pace
            float x = Mathf.Clamp(speed, GAIT_AT[0], GAIT_AT[2]);
            float pace = Mathf.Clamp(speed / StrideAt(speed), 0.35f, 3f);
            _phase = Mathf.Repeat(_phase + delta * pace, 1f);
            float move = G.Smoothstep(MOVE_FROM, MOVE_FULL, speed);
            Add("Idle", 1f - move);
            for (int i = 0; i < 2; i++)
                if (x <= GAIT_AT[i + 1])
                {
                    float k = (x - GAIT_AT[i]) / (GAIT_AT[i + 1] - GAIT_AT[i]);
                    Add(GAITS[i], move * (1f - k));
                    Add(GAITS[i + 1], move * k);
                    break;
                }
            // air
            float am = Mathf.Clamp01(-vy / 3f + 0.3f);
            Scale(1f - _air);
            Add("Jump", _air * (1f - am));
            Add("Fall", _air * am);
            // idle variations
            Scale(1f - _idlevar);
            Add("IdleLook", _idlevar * P("idle:look"));
            Add("IdleArms", _idlevar * P("idle:arms"));
            Add("SitBench", _idlevar * P("idle:bench"));
            // sitting
            Scale(1f - _sit);
            Add("Sit", _sit * P("sit:car"));
            Add("SitBench", _sit * P("sit:bench"));
            // full-body one-shots, in msp's order
            foreach (var n in new[] { "Land", "SitDown", "StandUp", "EnterCar", "ExitCar", "Carjack", "Stumble" }) ShotLayer(n, w, delta);
            // knocked down, then getting up; then death
            if (_down) { Scale(0f); Add("FallBack", 1f); }
            ShotLayer("GetUp", w, delta);
            if (_dead > 0f) { Scale(1f - _dead); Add("Die", _dead); }

            // upper body (layer 1): talk / phone / umbrella, the aim, then the upper one-shots
            var u = new Dictionary<string, float>();
            void AddU(string n, float v) { if (v > 0f) { u.TryGetValue(n, out var o); u[n] = o + v; } }
            void ScaleU(float k) { foreach (var key in new List<string>(u.Keys)) u[key] *= k; }
            float upper = _upperAct * (1f - _dead);
            AddU("Talk", upper * P("act:talk"));
            AddU("Phone", upper * P("act:phone"));
            AddU("Umbrella", upper * P("act:umbrella"));
            float aim = _aim * (1f - _dead);
            if (aim > 0f)
            {
                ScaleU(1f - aim);
                AddU(_aimKind == Aim.SHOTGUN ? "AimShotgun" : "AimPistol", aim);
            }
            foreach (var n in ONE_SHOTS_UPPER)
            {
                var s = _shots[n];
                if (s.t < 0f) continue;
                s.t += delta;
                float e = Envelope(s);
                if (s.t >= s.len) s.t = -1f;
                ScaleU(1f - e);
                AddU(n, e);
            }

            foreach (AnimationState st in anim)
            {
                string n = st.name;
                float weight = st.layer == 1 ? (u.TryGetValue(n, out var uw) ? uw : 0f) : (w.TryGetValue(n, out var ww) ? ww : 0f);
                if (weight <= 0.0001f)
                {
                    if (st.enabled) st.enabled = false;
                    continue;
                }
                if (!st.enabled)
                {
                    st.enabled = true;
                    if (!_shots.ContainsKey(n) && n != "FallBack" && n != "Die" && st.wrapMode != WrapMode.Loop) st.time = 0f;
                }
                st.weight = weight;
                if (Array.IndexOf(GAITS, n) >= 0)
                {
                    st.speed = 0f;
                    st.normalizedTime = _phase;
                }
                else if (_shots.TryGetValue(n, out var shot))
                {
                    st.speed = 0f;
                    st.time = Mathf.Max(shot.t, 0f);
                }
                else st.speed = 1f;
            }
        }

        void ShotLayer(string n, Dictionary<string, float> w, float delta)
        {
            var s = _shots[n];
            if (s.t < 0f) return;
            s.t += delta;
            float e = Envelope(s);
            if (s.t >= s.len) s.t = -1f;
            foreach (var key in new List<string>(w.Keys)) w[key] *= 1f - e;
            w.TryGetValue(n, out var o);
            w[n] = o + e;
        }

        static float Envelope(Shot s)
        {
            float a = s.fadeIn > 0f ? Mathf.Clamp01(s.t / s.fadeIn) : 1f;
            float b = s.fadeOut > 0f ? Mathf.Clamp01((s.len - s.t) / s.fadeOut) : 1f;
            return Mathf.Min(a, b);
        }

        void AutoIdle(float delta, bool still)
        {
            if (!autoIdle) return;
            if (_autoOn)
            {
                _autoT -= delta;
                if (_autoT <= 0f || !still)
                {
                    _autoOn = false;
                    if (activity == "look" || activity == "arms") activity = "";
                    _still = -UnityEngine.Random.Range(2f, 6f);
                }
                return;
            }
            if (still && activity == "" && _still > 7f)
            {
                _autoOn = true;
                _autoT = UnityEngine.Random.Range(4.5f, 9f);
                activity = UnityEngine.Random.value < 0.55f ? "look" : "arms";
            }
        }

        /// <summary>Places the glb: body * visual (yaw, sink) * model (turned to face -Z, leaning).</summary>
        public void Pose()
        {
            if (root == null) return;
            root.SetActive(visible);
            var visual = new GXform(GBasis.Rotation(Vector3.up, yaw), new Vector3(0f, -sink, 0f));
            var model = new GXform(GBasis.Rotation(Vector3.up, Mathf.PI) * GBasis.Rotation(Vector3.forward, _lean), Vector3.zero);
            G.Apply(root.transform, body * visual * model);
        }

        public void SetActivity(string a)
        {
            if (a == activity) return;
            _autoOn = false;
            activity = a;
            ShowPhone(a == "phone");
        }

        void ShowPhone(bool on)
        {
            if (on && _phone == null && _hand != null)
            {
                _phone = GameObject.CreatePrimitive(PrimitiveType.Cube);
                UnityEngine.Object.Destroy(_phone.GetComponent<Collider>());
                _phone.name = "Phone";
                _phone.transform.SetParent(_hand, false);
                _phone.transform.localScale = new Vector3(0.012f, 0.13f, 0.065f);
                _phone.transform.localPosition = G.U(new Vector3(0f, 0.075f, 0.025f));
                _phone.GetComponent<Renderer>().sharedMaterial = Mats.Make(new Color(0.06f, 0.06f, 0.07f), 0.8f, 0.4f);
            }
            if (_phone != null) _phone.SetActive(on);
        }

        /// <summary>Sitting in a car seat (hands on the wheel), or on a bench or chair with kind "bench".</summary>
        public void SetSitting(bool on, string kind = "car")
        {
            _sitting = on;
            if (on) _sitKind = kind;
        }

        public static float StrideAt(float speed)
        {
            if (speed <= GAIT_AT[0]) return STRIDES[0];
            for (int i = 1; i < GAIT_AT.Length; i++)
                if (speed <= GAIT_AT[i])
                    return Mathf.Lerp(STRIDES[i - 1], STRIDES[i], (speed - GAIT_AT[i - 1]) / (GAIT_AT[i] - GAIT_AT[i - 1]));
            return STRIDES[STRIDES.Length - 1];
        }

        public static float SeatK(float t) => G.Smoothstep(0.15f, 0.85f, t);

        void Fire(string k)
        {
            if (_shots.TryGetValue(k, out var s)) s.t = 0f;
        }

        public void SitDown() { _sitting = true; _sitKind = "bench"; _sit = 1f; _pick["sit:bench"] = 1f; _pick["sit:car"] = 0f; Fire("SitDown"); }
        public void StandUp() { _sitting = false; _sit = 0f; Fire("StandUp"); }
        public void PlayLand() => Fire("Land");
        public void PlayEnterCar() => Fire("EnterCar");
        public void PlayExitCar() => Fire("ExitCar");
        public void PlayHit() => Fire("Hit");
        public void PlayWave() => Fire("Wave");
        public void PlayStumble() => Fire("Stumble");
        public void PlayCarjack() => Fire("Carjack");
        public void PlayReload(Aim kind) => Fire(kind == Aim.SHOTGUN ? "ReloadShotgun" : "ReloadPistol");

        public void SetAim(Aim kind)
        {
            _aimKind = kind;
            if (kind != Aim.NONE && Array.IndexOf(UPPER_ACTS, activity) >= 0) SetActivity("");
        }

        /// <summary>Throws the next punch of the jab, cross, hook combo and returns its name.</summary>
        public string PlayPunch(string kind = "")
        {
            float now = Time.time;
            if (kind == "")
            {
                _combo = now - _lastPunch < 0.9f ? (_combo + 1) % PUNCHES.Length : 0;
                kind = PUNCHES[_combo];
            }
            _lastPunch = now;
            Fire(kind);
            return kind;
        }

        public void KnockDown()
        {
            if (_down || _deadOn) return;
            _down = true;
            if (anim != null && anim["FallBack"] != null) anim["FallBack"].time = 0f;
        }

        public void GetUp()
        {
            if (!_down) return;
            _down = false;
            Fire("GetUp");
        }

        public bool IsDown() => _down;

        public void SetDead(bool on)
        {
            if (on && !_deadOn && anim != null && anim["Die"] != null) anim["Die"].time = 0f;
            _deadOn = on;
            _down = false;
            if (on) _dead = 1f;
        }

        public float ClipLength(string n) => anim != null && anim[n] != null ? anim[n].length : 0.5f;

        public void Destroy()
        {
            if (root != null) UnityEngine.Object.Destroy(root);
        }
    }
}
