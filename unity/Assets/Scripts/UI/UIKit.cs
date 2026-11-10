// Small helpers for building msp's HUD in code with uGUI (msp builds its Control tree in
// code too): rounded panels, labels, buttons that can stay pressed, and box layouts.
using System;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

namespace MSP
{
    public static class UIKit
    {
        public static readonly Color BUTTON = new Color(0.16f, 0.19f, 0.25f, 0.92f);
        public static readonly Color HOVER = new Color(0.24f, 0.28f, 0.36f, 0.95f);
        public static readonly Color PRESSED = new Color(0.3f, 0.55f, 0.95f, 1f);
        public static readonly Color PANEL = new Color(0.07f, 0.09f, 0.13f, 0.82f);
        public static readonly Color TEXT = new Color(0.93f, 0.95f, 0.98f);
        public static readonly Color DIM = new Color(0.6f, 0.66f, 0.76f);
        public static readonly Color GOLD = new Color(1f, 0.85f, 0.45f);

        static Font _font;
        static Sprite _round;

        public static Font Font => _font ??= Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");

        /// <summary>A white rounded rectangle, 9-sliced, for every panel and button.</summary>
        public static Sprite Round
        {
            get
            {
                if (_round != null) return _round;
                const int S = 32, R = 10;
                var tex = new Texture2D(S, S, TextureFormat.RGBA32, false) { name = "UIRound", wrapMode = TextureWrapMode.Clamp };
                var px = new Color32[S * S];
                for (int y = 0; y < S; y++)
                    for (int x = 0; x < S; x++)
                    {
                        float cx = Mathf.Clamp(x + 0.5f, R, S - R), cy = Mathf.Clamp(y + 0.5f, R, S - R);
                        float d = Mathf.Sqrt((x + 0.5f - cx) * (x + 0.5f - cx) + (y + 0.5f - cy) * (y + 0.5f - cy));
                        byte a = (byte)(Mathf.Clamp01(R - d + 0.5f) * 255f);
                        px[y * S + x] = new Color32(255, 255, 255, a);
                    }
                tex.SetPixels32(px);
                tex.Apply();
                _round = Sprite.Create(tex, new Rect(0, 0, S, S), new Vector2(0.5f, 0.5f), 100f, 0, SpriteMeshType.FullRect, new Vector4(R + 1, R + 1, R + 1, R + 1));
                return _round;
            }
        }

        public static RectTransform Node(string name, Transform parent)
        {
            var go = new GameObject(name, typeof(RectTransform));
            var rt = (RectTransform)go.transform;
            rt.SetParent(parent, false);
            return rt;
        }

        public static void Anchor(RectTransform rt, Vector2 anchor, Vector2 pivot, Vector2 pos)
        {
            rt.anchorMin = rt.anchorMax = anchor;
            rt.pivot = pivot;
            rt.anchoredPosition = pos;
        }

        public static void Fill(RectTransform rt, float l = 0, float r = 0, float t = 0, float b = 0)
        {
            rt.anchorMin = Vector2.zero;
            rt.anchorMax = Vector2.one;
            rt.offsetMin = new Vector2(l, b);
            rt.offsetMax = new Vector2(-r, -t);
        }

        public static Image Panel(string name, Transform parent, Color c)
        {
            var rt = Node(name, parent);
            var img = rt.gameObject.AddComponent<Image>();
            img.sprite = Round;
            img.type = Image.Type.Sliced;
            img.color = c;
            return img;
        }

        /// <summary>A panel that sizes itself round its children, laid out in a row or column.</summary>
        public static Image Box(string name, Transform parent, Color c, bool vertical, float spacing, RectOffset pad = null)
        {
            var img = Panel(name, parent, c);
            HorizontalOrVerticalLayoutGroup g = vertical
                ? img.gameObject.AddComponent<VerticalLayoutGroup>()
                : img.gameObject.AddComponent<HorizontalLayoutGroup>();
            Layout(g, spacing, pad ?? new RectOffset(14, 14, 10, 10));
            var fit = img.gameObject.AddComponent<ContentSizeFitter>();
            fit.horizontalFit = ContentSizeFitter.FitMode.PreferredSize;
            fit.verticalFit = ContentSizeFitter.FitMode.PreferredSize;
            return img;
        }

        /// <summary>An invisible row or column inside a box.</summary>
        public static RectTransform Group(string name, Transform parent, bool vertical, float spacing)
        {
            var rt = Node(name, parent);
            HorizontalOrVerticalLayoutGroup g = vertical
                ? rt.gameObject.AddComponent<VerticalLayoutGroup>()
                : rt.gameObject.AddComponent<HorizontalLayoutGroup>();
            Layout(g, spacing, new RectOffset(0, 0, 0, 0));
            return rt;
        }

        static void Layout(HorizontalOrVerticalLayoutGroup g, float spacing, RectOffset pad)
        {
            g.spacing = spacing;
            g.padding = pad;
            g.childControlWidth = true;
            g.childControlHeight = true;
            g.childForceExpandWidth = false;
            g.childForceExpandHeight = false;
            g.childAlignment = TextAnchor.MiddleLeft;
        }

        public static Text Label(string name, Transform parent, string text, int size, Color color, TextAnchor align = TextAnchor.MiddleLeft)
        {
            var rt = Node(name, parent);
            var t = rt.gameObject.AddComponent<Text>();
            t.font = Font;
            t.text = text;
            t.fontSize = size;
            t.color = color;
            t.alignment = align;
            t.horizontalOverflow = HorizontalWrapMode.Overflow;
            t.verticalOverflow = VerticalWrapMode.Overflow;
            t.raycastTarget = false;
            return t;
        }

        public static LayoutElement MinSize(Component c, float w, float h)
        {
            var le = c.GetComponent<LayoutElement>() ?? c.gameObject.AddComponent<LayoutElement>();
            if (w > 0) { le.minWidth = w; le.preferredWidth = w; }
            if (h > 0) { le.minHeight = h; le.preferredHeight = h; }
            return le;
        }

        /// <summary>A button that can stay pressed (msp's toggle_mode buttons).</summary>
        public class UIButton
        {
            public Button button;
            public Image image;
            public Text text;
            bool _pressed;

            public bool Pressed
            {
                get => _pressed;
                set
                {
                    _pressed = value;
                    var cb = button.colors;
                    cb.normalColor = value ? PRESSED : BUTTON;
                    cb.highlightedColor = value ? PRESSED : HOVER;
                    cb.selectedColor = cb.normalColor;
                    button.colors = cb;
                }
            }

            public bool Interactable { get => button.interactable; set => button.interactable = value; }
        }

        public static UIButton Button(string name, Transform parent, string label, int size, Color textColor, Action onClick, float minW = 0, float minH = 40)
        {
            var img = Panel(name, parent, Color.white);
            var b = img.gameObject.AddComponent<Button>();
            b.targetGraphic = img;
            b.navigation = new Navigation { mode = Navigation.Mode.None };
            var cb = b.colors;
            cb.normalColor = BUTTON;
            cb.highlightedColor = HOVER;
            cb.pressedColor = PRESSED;
            cb.selectedColor = BUTTON;
            cb.disabledColor = new Color(0.11f, 0.12f, 0.15f, 0.7f);
            cb.colorMultiplier = 1f;
            cb.fadeDuration = 0.05f;
            b.colors = cb;
            var ub = new UIButton { button = b, image = img };
            if (label != null)
            {
                var hl = img.gameObject.AddComponent<HorizontalLayoutGroup>();
                hl.padding = new RectOffset(12, 12, 6, 6);
                hl.childAlignment = TextAnchor.MiddleCenter;
                hl.childControlWidth = hl.childControlHeight = true;
                hl.childForceExpandWidth = hl.childForceExpandHeight = false;
                ub.text = Label("Text", img.transform, label, size, textColor, TextAnchor.MiddleCenter);
            }
            MinSize(img, minW, minH);
            b.onClick.AddListener(() =>
            {
                // a clicked button would otherwise keep the keyboard (Space presses it again)
                EventSystem.current?.SetSelectedGameObject(null);
                onClick?.Invoke();
            });
            return ub;
        }

        public static string Thousands(long n) => Catalog.Thousands(n);
    }
}
