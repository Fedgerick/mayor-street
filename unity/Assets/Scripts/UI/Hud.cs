// Port of scripts/hud.gd and scripts/build_menu.gd: the mayor view UI. Stats bar on top,
// tools and overlays along the bottom, RCI demand, tax, graphics and help on the left, a
// tooltip by the cursor, toasts, and the build menu with every catalog building by group
// (locked ones greyed out with the goal that unlocks them).
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

namespace MSP
{
    public class Hud : MonoBehaviour
    {
        public static readonly string[] TOOLS = { "Inspect", "Road", "Residential", "Commercial", "Industrial", "Bulldoze", "Build" };
        public static readonly Color[] TOOL_COLORS =
        {
            new Color(0.85f, 0.88f, 0.95f), new Color(0.75f, 0.78f, 0.85f), new Color(0.3f, 0.85f, 0.4f),
            new Color(0.3f, 0.6f, 1f), new Color(1f, 0.75f, 0.2f), new Color(1f, 0.35f, 0.3f), new Color(1f, 0.85f, 0.45f),
        };
        static readonly string[] OVERLAYS = { "None", "Zones", "Traffic", "Land value" };
        static readonly string[] SPEEDS = { "II", "1x", "3x", "10x" };

        public event Action<int> ToolSelected;
        public event Action<int> OverlaySelected;
        public event Action<int> SpeedSelected;
        public event Action<int> QualitySelected;
        public event Action<string> BuildingChosen;

        public City city;
        Canvas canvas;
        public RectTransform root;
        Text lblFunds, lblPop, lblJobs, lblTime, lblIncome, lblTier, taxLabel;
        public Text info;
        Text tip, toast;
        Image tipBg, toastBg;
        float _toastT;
        readonly List<RectTransform> bars = new List<RectTransform>();
        readonly List<UIKit.UIButton> toolButtons = new List<UIKit.UIButton>();
        readonly List<UIKit.UIButton> overlayButtons = new List<UIKit.UIButton>();
        readonly List<UIKit.UIButton> speedButtons = new List<UIKit.UIButton>();
        readonly List<UIKit.UIButton> qualityButtons = new List<UIKit.UIButton>();
        static readonly Color TOAST_BAD = new Color(0.6f, 0.15f, 0.12f, 0.92f);
        static readonly Color TOAST_GOOD = new Color(0.12f, 0.38f, 0.24f, 0.94f);

        public void Setup(City c)
        {
            city = c;
            if (EventSystem.current == null)
            {
                var es = new GameObject("EventSystem", typeof(EventSystem), typeof(StandaloneInputModule));
                es.transform.SetParent(transform, false);
            }
            var cgo = new GameObject("HudCanvas", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
            cgo.transform.SetParent(transform, false);
            canvas = cgo.GetComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            var scaler = cgo.GetComponent<CanvasScaler>();
            scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
            scaler.referenceResolution = new Vector2(1920, 1080);
            scaler.matchWidthOrHeight = 1f;
            root = (RectTransform)cgo.transform;
            BuildTop();
            BuildBottom();
            BuildSide();
            BuildMenu();
            tipBg = UIKit.Box("Tip", root, new Color(0.08f, 0.1f, 0.14f, 0.85f), true, 0, new RectOffset(12, 12, 6, 6));
            tipBg.raycastTarget = false;
            UIKit.Anchor(tipBg.rectTransform, Vector2.zero, new Vector2(0, 1), Vector2.zero);
            tip = UIKit.Label("Text", tipBg.transform, "", 17, UIKit.TEXT);
            tipBg.gameObject.SetActive(false);
            toastBg = UIKit.Box("Toast", root, TOAST_BAD, true, 0, new RectOffset(16, 16, 8, 8));
            toastBg.raycastTarget = false;
            UIKit.Anchor(toastBg.rectTransform, new Vector2(0.5f, 1f), new Vector2(0.5f, 1f), new Vector2(0, -90));
            toast = UIKit.Label("Text", toastBg.transform, "", 17, UIKit.TEXT, TextAnchor.MiddleCenter);
            toast.horizontalOverflow = HorizontalWrapMode.Wrap;
            UIKit.MinSize(toast, 588, 0);
            toastBg.gameObject.SetActive(false);
        }

        Text Stat(Transform parent, string title)
        {
            var v = UIKit.Group(title, parent, true, -2);
            UIKit.Label("Title", v, title, 12, UIKit.DIM);
            return UIKit.Label("Value", v, "", 22, UIKit.TEXT);
        }

        void BuildTop()
        {
            var p = UIKit.Box("Top", root, UIKit.PANEL, false, 26);
            UIKit.Anchor(p.rectTransform, new Vector2(0.5f, 1f), new Vector2(0.5f, 1f), new Vector2(0, -12));
            var nv = UIKit.Group("Name", p.transform, true, -2);
            UIKit.Label("City", nv, "NEW HARBOR", 20, UIKit.GOLD);
            lblTier = UIKit.Label("Tier", nv, "", 12, UIKit.DIM);
            lblFunds = Stat(p.transform, "FUNDS");
            lblIncome = Stat(p.transform, "PER DAY");
            lblPop = Stat(p.transform, "POPULATION");
            lblJobs = Stat(p.transform, "JOBS");
            lblTime = Stat(p.transform, "TIME");
            foreach (var t in new[] { lblFunds, lblIncome, lblPop, lblJobs }) UIKit.MinSize(t, 96, 0);
            UIKit.MinSize(lblTime, 150, 0);
            var sp = UIKit.Group("Speed", p.transform, false, 4);
            for (int i = 0; i < SPEEDS.Length; i++)
            {
                int k = i;
                speedButtons.Add(UIKit.Button(SPEEDS[i], sp, SPEEDS[i], 17, UIKit.TEXT, () => SpeedSelected?.Invoke(k), 48, 40));
            }
        }

        void BuildBottom()
        {
            var p = UIKit.Box("Bottom", root, UIKit.PANEL, false, 6);
            UIKit.Anchor(p.rectTransform, new Vector2(0.5f, 0f), new Vector2(0.5f, 0f), new Vector2(0, 32));
            for (int i = 0; i < TOOLS.Length; i++)
            {
                int k = i;
                toolButtons.Add(UIKit.Button(TOOLS[i], p.transform, $"{i + 1}  {TOOLS[i]}", 17, TOOL_COLORS[i], () => ToolSelected?.Invoke(k), 0, 46));
            }
            var sep = UIKit.Panel("Sep", p.transform, new Color(1, 1, 1, 0.15f));
            UIKit.MinSize(sep, 2, 40);
            for (int i = 0; i < OVERLAYS.Length; i++)
            {
                int k = i;
                overlayButtons.Add(UIKit.Button(OVERLAYS[i], p.transform, OVERLAYS[i], 17, UIKit.TEXT, () => OverlaySelected?.Invoke(k), 0, 46));
            }
        }

        void BuildSide()
        {
            var p = UIKit.Box("Side", root, UIKit.PANEL, true, 6);
            UIKit.Anchor(p.rectTransform, new Vector2(0f, 1f), new Vector2(0f, 1f), new Vector2(14, -12));
            UIKit.Label("Demand", p.transform, "DEMAND", 12, UIKit.DIM);
            var hb = UIKit.Group("Bars", p.transform, false, 10);
            for (int i = 0; i < 3; i++)
            {
                var col = UIKit.Group("Col", hb, true, 2);
                col.GetComponent<VerticalLayoutGroup>().childAlignment = TextAnchor.UpperCenter;
                var bg = UIKit.Panel("Bar", col, new Color(0.2f, 0.22f, 0.28f, 0.8f));
                UIKit.MinSize(bg, 26, 70);
                var fill = UIKit.Panel("Fill", bg.transform, TOOL_COLORS[i + 2]);
                fill.rectTransform.anchorMin = Vector2.zero;
                fill.rectTransform.anchorMax = new Vector2(1f, 0.5f);
                fill.rectTransform.offsetMin = fill.rectTransform.offsetMax = Vector2.zero;
                bars.Add(fill.rectTransform);
                UIKit.Label("L", col, new[] { "R", "C", "I" }[i], 17, TOOL_COLORS[i + 2], TextAnchor.MiddleCenter);
            }
            var tx = UIKit.Group("Tax", p.transform, false, 4);
            UIKit.Button("Minus", tx, "-", 17, UIKit.TEXT, () => Tax(-0.01), 32, 30);
            taxLabel = UIKit.Label("TaxLabel", tx, "", 17, UIKit.TEXT, TextAnchor.MiddleCenter);
            UIKit.MinSize(taxLabel, 80, 0);
            UIKit.Button("Plus", tx, "+", 17, UIKit.TEXT, () => Tax(0.01), 32, 30);
            UIKit.Label("Graphics", p.transform, "GRAPHICS", 12, UIKit.DIM);
            var qh = UIKit.Group("Quality", p.transform, false, 4);
            for (int i = 0; i < 3; i++)
            {
                int k = i;
                qualityButtons.Add(UIKit.Button(new[] { "Low", "Med", "High" }[i], qh, new[] { "Low", "Med", "High" }[i], 14, UIKit.TEXT, () => QualitySelected?.Invoke(k), 0, 34));
            }
            info = UIKit.Label("Info", p.transform, "", 14, new Color(0.8f, 0.85f, 0.92f));
            info.horizontalOverflow = HorizontalWrapMode.Wrap;
            UIKit.MinSize(info, 190, 0);
            UIKit.Label("Help", p.transform,
                "WASD pan · Q/E or right-drag rotate\nwheel zoom · middle-drag grab\nSpace pause · , . speed · N skip\nB build menu · O overlays\n[ ] an hour back or on",
                12, new Color(0.55f, 0.6f, 0.7f));
        }

        void Tax(double d) => city.taxRate = Math.Max(0.0, Math.Min(0.2, city.taxRate + d));

        public void SetTool(int i) { for (int k = 0; k < toolButtons.Count; k++) toolButtons[k].Pressed = k == i; }
        public void SetOverlay(int i) { for (int k = 0; k < overlayButtons.Count; k++) overlayButtons[k].Pressed = k == i; }
        public void SetSpeed(int i) { for (int k = 0; k < speedButtons.Count; k++) speedButtons[k].Pressed = k == i; }
        public void SetQuality(int i) { for (int k = 0; k < qualityButtons.Count; k++) qualityButtons[k].Pressed = k == i; }

        /// <summary>A tooltip by the cursor (Unity screen coords); "" hides it.</summary>
        public void ShowTip(Vector2 screen, string text)
        {
            bool on = !string.IsNullOrEmpty(text);
            tipBg.gameObject.SetActive(on);
            if (!on) return;
            tip.text = text;
            RectTransformUtility.ScreenPointToLocalPointInRectangle(root, screen, null, out var local);
            var rt = tipBg.rectTransform;
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.anchoredPosition = local + new Vector2(18, -18);
        }

        /// <summary>Red for problems ("Not enough money"), green for good news.</summary>
        public void ShowToast(string text, bool good = false)
        {
            toast.text = text;
            toastBg.color = good ? TOAST_GOOD : TOAST_BAD;
            toastBg.gameObject.SetActive(true);
            _toastT = good ? 4f : 2.5f;
        }

        public static bool PointerOverUI() => EventSystem.current != null && EventSystem.current.IsPointerOverGameObject();

        void Update()
        {
            UIBlocks.PointerOverUI = PointerOverUI();
            if (_toastT > 0f)
            {
                _toastT -= Time.unscaledDeltaTime;
                if (_toastT <= 0f) toastBg.gameObject.SetActive(false);
            }
            if (city == null) return;
            lblFunds.text = "$" + UIKit.Thousands((long)city.funds);
            double net = city.lastIncome - city.lastExpense;
            lblIncome.text = (net >= 0 ? "+$" : "-$") + UIKit.Thousands((long)Math.Abs(net));
            lblIncome.color = net >= 0 ? new Color(0.5f, 0.95f, 0.55f) : new Color(1f, 0.45f, 0.4f);
            lblPop.text = UIKit.Thousands(city.population);
            lblJobs.text = UIKit.Thousands(city.jobsC + city.jobsI);
            double h = city.TimeOfDay();
            lblTime.text = $"Day {city.GameDay() + 1}  {(int)h:00}:{(int)((h % 1.0) * 60.0):00}";
            for (int i = 0; i < 3; i++)
                bars[i].anchorMax = new Vector2(1f, Mathf.Clamp01(((float)city.demand[i + 1] + 1f) * 0.5f));
            taxLabel.text = $"Tax {(int)Math.Round(city.taxRate * 100.0)}%";
            lblTier.text = Catalog.TIERS[Progress.I.cityTier].name.ToUpperInvariant();
        }

        // ---------------------------------------------------------- build menu ---

        Image _menu;
        RectTransform _grid;
        Text _desc, _goal;
        string _group = "power";
        readonly Dictionary<string, UIKit.UIButton> _tabs = new Dictionary<string, UIKit.UIButton>();

        public bool BuildMenuOpen => _menu != null && _menu.gameObject.activeSelf;

        void BuildMenu()
        {
            _menu = UIKit.Box("BuildMenu", root, UIKit.PANEL, true, 10);
            UIKit.Anchor(_menu.rectTransform, new Vector2(0.5f, 0f), new Vector2(0.5f, 0f), new Vector2(0, 112));
            var top = UIKit.Group("Top", _menu.transform, false, 10);
            UIKit.Label("Title", top, "BUILD", 20, UIKit.GOLD);
            _goal = UIKit.Label("Goal", top, "", 14, new Color(0.7f, 0.76f, 0.85f), TextAnchor.MiddleRight);
            var gle = UIKit.MinSize(_goal, 0, 0);
            gle.flexibleWidth = 1;
            var tabs = UIKit.Group("Tabs", _menu.transform, false, 6);
            foreach (var g in Catalog.GROUPS)
            {
                string gg = g;
                _tabs[g] = UIKit.Button(g, tabs, Catalog.GROUP_NAMES[g], 17, UIKit.TEXT, () => ShowGroup(gg), 0, 38);
            }
            _grid = UIKit.Node("Grid", _menu.transform);
            var grid = _grid.gameObject.AddComponent<GridLayoutGroup>();
            grid.cellSize = new Vector2(214, 80);
            grid.spacing = new Vector2(8, 8);
            grid.constraint = GridLayoutGroup.Constraint.FixedColumnCount;
            grid.constraintCount = 4;
            _desc = UIKit.Label("Desc", _menu.transform, "", 14, new Color(0.75f, 0.8f, 0.88f));
            _desc.horizontalOverflow = HorizontalWrapMode.Wrap;
            UIKit.MinSize(_desc, 880, 40);
            Progress.I.Unlocked += (id, s) => { if (BuildMenuOpen) ShowGroup(_group); };
            Progress.I.TierReached += (t, n, ids) => { if (BuildMenuOpen) ShowGroup(_group); };
            _menu.gameObject.SetActive(false);
        }

        public void ToggleBuildMenu()
        {
            if (BuildMenuOpen) CloseBuildMenu();
            else
            {
                _menu.gameObject.SetActive(true);
                ShowGroup(_group);
            }
        }

        public void CloseBuildMenu() => _menu.gameObject.SetActive(false);

        void ShowGroup(string g)
        {
            _group = g;
            foreach (var kv in _tabs) kv.Value.Pressed = kv.Key == g;
            for (int i = _grid.childCount - 1; i >= 0; i--) Destroy(_grid.GetChild(i).gameObject);
            foreach (var id in Catalog.Ids(g)) Entry(id);
            int t = Progress.I.cityTier;
            string next = Catalog.GoalText(t + 1);
            _goal.text = Catalog.TIERS[t].name + (next != "" ? "   Next milestone: " + next : "");
            _desc.text = "";
        }

        void Entry(string id)
        {
            var d = Catalog.GetDef(id);
            bool built = d.unique && city != null && city.SpecialsOf(id).Count > 0;
            bool unlocked = Progress.I.IsUnlocked(id);
            bool open = unlocked && !built;
            var b = UIKit.Button(id, _grid, null, 15, UIKit.TEXT, () =>
            {
                CloseBuildMenu();
                BuildingChosen?.Invoke(id);
            });
            b.Interactable = open;
            var v = UIKit.Group("Lines", b.image.transform, true, 2);
            UIKit.Fill(v, 12, 10, 8, 6);
            v.GetComponent<VerticalLayoutGroup>().childAlignment = TextAnchor.UpperLeft;
            string detail = built ? "Already built" : (!unlocked ? Catalog.LockText(id) : Price(d));
            var n = UIKit.Label("Name", v, d.name, 15, open ? Color.Lerp(d.accent, Color.white, 0.55f) : new Color(0.56f, 0.59f, 0.66f));
            n.horizontalOverflow = HorizontalWrapMode.Wrap;
            var dl = UIKit.Label("Detail", v, detail, 13, open ? new Color(0.78f, 0.82f, 0.9f) : new Color(0.5f, 0.53f, 0.6f));
            dl.horizontalOverflow = HorizontalWrapMode.Wrap;
            var trig = b.image.gameObject.AddComponent<EventTrigger>();
            var e = new EventTrigger.Entry { eventID = EventTriggerType.PointerEnter };
            e.callback.AddListener(_ => _desc.text = d.desc);
            trig.triggers.Add(e);
        }

        /// <summary>"$1,500 · 1x1" over "earns $8 a day".</summary>
        static string Price(Catalog.Def d)
        {
            string cost = "$" + Catalog.Thousands(d.cost);
            if (d.placement == "line") return cost + " a tile, dragged like a road";
            string size = d.size == 0 ? "on a sidewalk" : $"{d.size}x{d.size}";
            int up = (int)d.upkeep;
            string perDay = up > 0 ? $"\n${up} a day to run" : up < 0 ? $"\nearns ${-up} a day" : "";
            return $"{cost}  ·  {size}{perDay}";
        }
    }
}
