// Port of services/services_panel.gd: a small HUD panel with the service overlay buttons and the
// city's service numbers, bottom right above the tool bar.
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

namespace MSP
{
    public class ServicesPanel : MonoBehaviour
    {
        public event Action<CityServices.Overlay> OverlaySelected;

        CityServices services;
        readonly List<UIKit.UIButton> buttons = new List<UIKit.UIButton>();
        readonly Dictionary<string, Text> lines = new Dictionary<string, Text>();
        static long R(double v) => (long)Math.Round(v, MidpointRounding.AwayFromZero);
        static readonly Color WARN = new Color(1f, 0.55f, 0.5f);

        public void Setup(RectTransform root, CityServices s)
        {
            services = s;
            var p = UIKit.Box("Services", root, UIKit.PANEL, true, 3, new RectOffset(10, 10, 8, 8));
            UIKit.Anchor(p.rectTransform, new Vector2(1f, 0f), new Vector2(1f, 0f), new Vector2(-14, 100));
            UIKit.Label("Title", p.transform, "CITY SERVICES", 12, UIKit.DIM);
            foreach (var key in new[] { "power", "garbage", "crime", "happiness", "approval" })
                lines[key] = UIKit.Label(key, p.transform, "", 15, UIKit.TEXT);
            var names = CityServices.OVERLAY_NAMES;
            RectTransform row = null;
            for (int i = 1; i < names.Length; i++)
            {
                if ((i - 1) % 4 == 0) row = UIKit.Group("Row", p.transform, false, 4);
                int k = i;
                buttons.Add(UIKit.Button(names[i], row, names[i], 13, UIKit.TEXT, () => OnButton(k), 0, 30));
            }
            s.StatsChanged += Refresh;
            s.CoverageChanged += Refresh;
            Refresh();
        }

        void OnButton(int mode)
        {
            bool on = !buttons[mode - 1].Pressed;
            var m = on ? (CityServices.Overlay)mode : CityServices.Overlay.NONE;
            SetOverlay(m);
            OverlaySelected?.Invoke(m);
        }

        /// <summary>Shows which overlay is on (when it's switched from elsewhere, like a hotkey).</summary>
        public void SetOverlay(CityServices.Overlay mode)
        {
            for (int k = 0; k < buttons.Count; k++) buttons[k].Pressed = k + 1 == (int)mode;
        }

        void Refresh()
        {
            if (services == null || lines.Count == 0) return;
            var s = services.Stats();
            lines["power"].text = $"Power  {R(s["power_pct"])}%   {R(s["demand_mw"])} / {R(s["supply_mw"])} MW";
            lines["garbage"].text = $"Garbage collected  {R(s["garbage_pct"])}%";
            lines["crime"].text = $"Crime  {R(s["crime"])}";
            lines["happiness"].text = $"Happiness  {R(s["happiness"])}";
            lines["approval"].text = $"Approval  {R(s["approval"])}%";
            lines["power"].color = s["power_pct"] < 95.0 ? WARN : UIKit.TEXT;
            lines["garbage"].color = s["garbage_pct"] < 80.0 ? WARN : UIKit.TEXT;
        }
    }
}
