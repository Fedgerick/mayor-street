// Port of player/scripts/street_mode.gd (the on-foot core): street level in one node: the
// character, the street camera, collision built from the City, and the hand-over with the mayor
// view. The mayor view hands over with EnterStreet() and takes the camera back after
// ExitStreet() (StreetExited). Cars, combat, wanted levels, pickups and seating come later.
using System;
using UnityEngine;

namespace MSP
{
    public class StreetMode : MonoBehaviour
    {
        public event Action StreetEntered;
        public event Action StreetExited;

        public float diveSeconds = 3.2f;
        public float riseSeconds = 2.6f;
        public const float UNDER_DEPTH = 1.5f;
        public const float SPAWN_POLE_CLEAR = 0.45f;

        public City city;
        public StreetPlayer player;
        public StreetCamera camera;
        public CityCollision collision;
        public bool active, busy, down;
        public int rescues;

        float _rescueT;
        UnityEngine.UI.Text _hint;
        string _note;
        float _noteT;

        public void Setup(City c, Camera cam, Transform hudRoot)
        {
            city = c;
            var colGo = new GameObject("Collision");
            colGo.transform.SetParent(transform, false);
            collision = colGo.AddComponent<CityCollision>();
            collision.Setup(c);
            var pgo = new GameObject("Player");
            pgo.transform.SetParent(transform, false);
            player = pgo.AddComponent<StreetPlayer>();
            player.Init();
            player.enabled = false;
            player.visual.visible = false;
            player.visual.Pose();
            camera = new StreetCamera(cam);
            if (hudRoot == null)
            {
                // its own canvas: the mayor HUD hides at street level
                var cgo = new GameObject("StreetHud", typeof(Canvas), typeof(UnityEngine.UI.CanvasScaler));
                cgo.transform.SetParent(transform, false);
                var canvas = cgo.GetComponent<Canvas>();
                canvas.renderMode = RenderMode.ScreenSpaceOverlay;
                canvas.sortingOrder = 5;
                var scaler = cgo.GetComponent<UnityEngine.UI.CanvasScaler>();
                scaler.uiScaleMode = UnityEngine.UI.CanvasScaler.ScaleMode.ScaleWithScreenSize;
                scaler.referenceResolution = new Vector2(1920, 1080);
                scaler.matchWidthOrHeight = 1f;
                hudRoot = cgo.transform;
            }
            {
                _hint = UIKit.Label("StreetHint", hudRoot, "", 20, UIKit.TEXT, TextAnchor.LowerCenter);
                UIKit.Anchor(_hint.rectTransform, new Vector2(0.5f, 0f), new Vector2(0.5f, 0f), new Vector2(0, 40));
                var outline = _hint.gameObject.AddComponent<UnityEngine.UI.Outline>();
                outline.effectColor = new Color(0, 0, 0, 0.8f);
                _hint.gameObject.SetActive(false);
            }
        }

        // ------------------------------------------------------------------ mode switch ---

        /// <summary>from: the mayor camera's Godot-space transform. groundPoint: world point it looks at.</summary>
        public void EnterStreet(GXform from, float fromFov, Vector3 groundPoint)
        {
            if (busy || active) return;
            busy = true;
            Vector3 spot = SidewalkSpawn(groundPoint);
            player.enabled = true;
            player.visual.visible = true;
            player.SetInVehicle(false);
            player.visual.SetSitting(false);
            player.SetControls(false);
            // Face the way the mayor camera looks, so the dive swings in from the same side.
            var f = Planet.ToLocal(spot, -from.basis.z);
            float yaw = Mathf.Atan2(-f.x, -f.z);
            player.Place(spot, yaw);
            player.rig.pitch = -14f * Mathf.Deg2Rad;
            player.rig.Snap();
            camera.cam.nearClipPlane = 0.08f;
            camera.DiveTo(player.rig, from, fromFov, diveSeconds);
            camera.FlightFinished += OnDived;
        }

        void OnDived()
        {
            camera.FlightFinished -= OnDived;
            busy = false;
            active = true;
            player.SetControls(true);
            Cursor.lockState = CursorLockMode.Locked;
            Cursor.visible = false;
            StreetEntered?.Invoke();
        }

        public bool CanExit() => active && !busy && !down;

        public void ExitStreet(GXform to, float toFov = 45f)
        {
            if (busy || !active || !CanExit()) return;
            busy = true;
            active = false;
            player.SetControls(false);
            Cursor.lockState = CursorLockMode.None;
            Cursor.visible = true;
            camera.RiseTo(to, toFov, riseSeconds);
            camera.FlightFinished += OnRisen;
        }

        void OnRisen()
        {
            camera.FlightFinished -= OnRisen;
            busy = false;
            player.enabled = false;
            player.visual.visible = false;
            player.visual.Pose();
            camera.cam.nearClipPlane = 0.5f;
            StreetExited?.Invoke();
        }

        /// <summary>Where the mayor camera should centre when returning (Godot world space).</summary>
        public Vector3 FocusPoint() => player.Position;
        public float ViewYaw() => player.rig.yaw;

        void Update()
        {
            float delta = Mathf.Min(Time.deltaTime, 0.05f);
            if (active && Input.GetKeyDown(KeyCode.Escape))
            {
                bool lockNow = Cursor.lockState != CursorLockMode.Locked;
                Cursor.lockState = lockNow ? CursorLockMode.Locked : CursorLockMode.None;
                Cursor.visible = !lockNow;
            }
            if (active && Input.GetMouseButtonDown(0) && Cursor.lockState != CursorLockMode.Locked)
            {
                Cursor.lockState = CursorLockMode.Locked;
                Cursor.visible = false;
            }
            if (active)
            {
                var lv = Planet.ToLocal(player.Position, player.Velocity);
                float run = new Vector2(lv.x, lv.z).magnitude;
                camera.fovBoost = Mathf.Clamp01((run - 4f) / 4f) * 0.3f;   // a touch wider when sprinting
                camera.lean = 0f;
                _rescueT -= delta;
                if (_rescueT <= 0f)
                {
                    _rescueT = 0.25f;
                    RescueIfUnder();
                }
            }
            if (_hint != null)
            {
                _noteT -= delta;
                string text = _noteT > 0f ? _note : "";
                _hint.text = text;
                _hint.gameObject.SetActive(active && text != "");
            }
        }

        void LateUpdate()
        {
            if (active || busy) camera.Update(Mathf.Min(Time.deltaTime, 0.05f));
        }

        public void Note(string text)
        {
            _note = text;
            _noteT = 2.5f;
        }

        // ------------------------------------------------------------------ the ground ---

        /// <summary>How far a world point is under the ground (negative above it). msp only.</summary>
        public float DepthBelowGround(Vector3 p)
        {
            if (!Planet.on || city == null) return float.NegativeInfinity;
            var f = Planet.Flat(p);
            return Planet.R + (float)city.TerrainHeight(f.x, f.z) - p.magnitude;
        }

        /// <summary>p lifted onto the ground if it is under it.</summary>
        public Vector3 OnGround(Vector3 p)
        {
            if (!Planet.on) return new Vector3(p.x, Mathf.Max(p.y, 0f), p.z);
            float d = DepthBelowGround(p);
            return d > -0.05f ? p + Planet.Up(p) * (d + 0.05f) : p;
        }

        void RescueIfUnder()
        {
            if (!Planet.on || player == null || player.inVehicle) return;
            if (DepthBelowGround(player.Position) > UNDER_DEPTH)
            {
                player.Place(SidewalkSpawn(RoadPointNear(Planet.Flat(player.Position))), player.rig.yaw);
                player.Velocity = Vector3.zero;
                rescues++;
                Note("Back on the street");
            }
        }

        /// <summary>World point on the surface at the nearest road cell's centre (or straight above
        /// flat when there's no road near).</summary>
        public Vector3 RoadPointNear(Vector3 flat)
        {
            var o = city.FlatToCell(flat);
            for (int r = 0; r < 8; r++)
            {
                var best = new Vector2Int(-1, -1);
                float bestD = float.PositiveInfinity;
                for (int y = o.y - r; y <= o.y + r; y++)
                    for (int x = o.x - r; x <= o.x + r; x++)
                    {
                        if (Mathf.Max(Mathf.Abs(x - o.x), Mathf.Abs(y - o.y)) != r || !city.IsRoad(x, y)) continue;
                        float d = Planet.Fdist(city.CellCenter(x, y), flat);
                        if (d < bestD) { bestD = d; best = new Vector2Int(G.Posmod(x, City.W), y); }
                    }
                if (best.x >= 0)
                {
                    var c = city.CellCenter(best.x, best.y);
                    c.y = (float)city.TerrainHeight(c.x, c.z);
                    return Planet.Place(c);
                }
            }
            return Planet.Place(new Vector3(flat.x, (float)city.TerrainHeight(flat.x, flat.z), flat.z));
        }

        /// <summary>Nearest sidewalk to a ground point, or the point itself if there are no roads.</summary>
        public Vector3 SidewalkSpawn(Vector3 p)
        {
            if (city == null) return p + Planet.Up(p) * 0.3f;
            var o = city.WorldToCell(p);
            var pf = Planet.Flat(p);
            for (int r = 0; r < 12; r++)
            {
                Vector3 best = Vector3.zero;
                float bestD = float.PositiveInfinity;
                for (int y = o.y - r; y <= o.y + r; y++)
                    for (int x = o.x - r; x <= o.x + r; x++)
                    {
                        if (Mathf.Max(Mathf.Abs(x - o.x), Mathf.Abs(y - o.y)) != r || !city.IsRoad(x, y)) continue;
                        var c = city.CellCenter(x, y);
                        int m = city.RoadMask(x, y);
                        var cands = new[]
                        {
                            new Vector3(4.9f, 0, 4.9f), new Vector3(-4.9f, 0, 4.9f), new Vector3(4.9f, 0, -4.9f), new Vector3(-4.9f, 0, -4.9f),
                            (m & 4) == 0 ? new Vector3(0, 0, 4.9f) : new Vector3(4.9f, 0, 0),
                            (m & 1) == 0 ? new Vector3(0, 0, -4.9f) : new Vector3(-4.9f, 0, 0),
                        };
                        foreach (var cand in cands)
                        {
                            Vector3 w = c + cand;
                            if (Planet.on) w.x = pf.x + Planet.Dx(pf.x, w.x);
                            if (collision != null && collision.PoleNear(Planet.Place(w), SPAWN_POLE_CLEAR)) continue;
                            float d = (w - pf).sqrMagnitude;
                            if (d < bestD) { bestD = d; best = w; }
                        }
                    }
                if (bestD < float.PositiveInfinity) return Planet.Place(best + Vector3.up * 0.3f);
            }
            return p + Planet.Up(p) * 0.3f;
        }
    }
}
