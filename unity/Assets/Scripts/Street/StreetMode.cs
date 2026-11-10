// Port of player/scripts/street_mode.gd (the on-foot core): street level in one node: the
// character, the street camera, collision built from the City, and the hand-over with the mayor
// view. The mayor view hands over with EnterStreet() and takes the camera back after
// ExitStreet() (StreetExited). Parked cars to steal and drive (E gets in and out). Combat,
// wanted levels, pickups and seating come later.
using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class StreetMode : MonoBehaviour
    {
        public event Action StreetEntered;
        public event Action StreetExited;
        public event Action<DrivableCar> VehicleChanged;

        public static readonly string[] CAR_MODELS = { "car_sedan", "car_hatch", "car_van", "car_sedan", "car_truck" };
        public static readonly Color[] CAR_COLORS =
        {
            new Color(0.85f, 0.12f, 0.1f), new Color(0.95f, 0.95f, 0.95f), new Color(0.12f, 0.12f, 0.14f), new Color(0.15f, 0.3f, 0.7f),
            new Color(0.7f, 0.72f, 0.75f), new Color(0.95f, 0.75f, 0.1f), new Color(0.1f, 0.45f, 0.3f), new Color(0.55f, 0.1f, 0.15f),
        };
        public const float PARK_OUT = 2.85f;
        public int parkedCarsPerDrop = 4;
        public float enterRadius = 3.2f;

        public float diveSeconds = 3.2f;
        public float riseSeconds = 2.6f;
        public const float UNDER_DEPTH = 1.5f;
        public const float SPAWN_POLE_CLEAR = 0.45f;

        public City city;
        public StreetPlayer player;
        public StreetCamera camera;
        public CityCollision collision;
        public bool active, busy, down, switching;
        public int rescues;
        public DrivableCar car;
        public readonly List<DrivableCar> vehicles = new List<DrivableCar>();
        Transform _carsRoot;
        readonly System.Random _rng = new System.Random();
        UnityEngine.UI.Text _speedo;

        float _rescueT;
        UnityEngine.UI.Text _hint;
        string _note;
        float _noteT;

        public void Setup(City c, Camera cam, Transform hudRoot)
        {
            city = c;
            Time.fixedDeltaTime = 1f / 60f;   // msp's physics tick
            _carsRoot = new GameObject("Cars").transform;
            _carsRoot.SetParent(transform, false);
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
            player.InteractRequested += OnInteract;
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
                _speedo = UIKit.Label("Speedo", hudRoot, "", 44, UIKit.TEXT, TextAnchor.LowerRight);
                UIKit.Anchor(_speedo.rectTransform, new Vector2(1f, 0f), new Vector2(1f, 0f), new Vector2(-40, 40));
                _speedo.rectTransform.sizeDelta = new Vector2(320, 70);
                var o2 = _speedo.gameObject.AddComponent<UnityEngine.UI.Outline>();
                o2.effectColor = new Color(0.05f, 0.06f, 0.1f, 0.85f);
                _speedo.gameObject.SetActive(false);
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
            if (parkedCarsPerDrop > 0) SpawnParkedCarsNear(spot, parkedCarsPerDrop);
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
        public Vector3 FocusPoint() => car != null ? car.Position : player.Position;
        public float ViewYaw() => car != null ? car.rig.yaw : player.rig.yaw;

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
            if (active && car != null && !switching && !down && StreetInput.InteractPressed && Mathf.Abs(car.Speed()) < 6f)
                StartCoroutine(LeaveCar());
            string hint = "", speedo = "";
            if (active)
            {
                _rescueT -= delta;
                if (_rescueT <= 0f)
                {
                    _rescueT = 0.25f;
                    RescueIfUnder();
                }
                if (car != null)
                {
                    float sp = Mathf.Abs(car.Speed());
                    speedo = $"{Mathf.RoundToInt(sp * 3.6f)} km/h";
                    hint = sp < 6f && !switching ? "E  get out" : "";
                    // Wider and leaning into corners at speed.
                    camera.fovBoost = Mathf.Pow(Mathf.Clamp01(sp / 38f), 1.4f);
                    camera.lean = Mathf.Clamp(-Vector3.Dot(car.AngularVelocity, Planet.Up(car.Position)) * sp * 0.0035f, -0.07f, 0.07f);
                }
                else
                {
                    var lv = Planet.ToLocal(player.Position, player.Velocity);
                    float run = new Vector2(lv.x, lv.z).magnitude;
                    camera.fovBoost = Mathf.Clamp01((run - 4f) / 4f) * 0.3f;   // a touch wider when sprinting
                    camera.lean = 0f;
                    bool near = false;
                    foreach (var v in vehicles)
                        if (v != null && Vector3.Distance(v.Position, player.Position) < enterRadius) { near = true; break; }
                    hint = near && !switching ? "E  get in" : "";
                }
            }
            if (_hint != null)
            {
                _noteT -= delta;
                string text = _noteT > 0f ? _note : hint;
                _hint.text = text;
                _hint.gameObject.SetActive(active && text != "");
                _speedo.text = speedo;
                _speedo.gameObject.SetActive(active && speedo != "");
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
            if (switching || !Planet.on || player == null) return;
            if (car != null)
            {
                if (DepthBelowGround(car.Position) > UNDER_DEPTH)
                {
                    var at = RoadPointNear(Planet.Flat(car.Position));
                    var fw = car.Forward();
                    var up = Planet.Up(at);
                    fw -= up * Vector3.Dot(fw, up);
                    if (fw.magnitude < 0.1f) fw = Planet.Basis(at).z;
                    fw.Normalize();
                    car.rb.position = G.U(at);
                    car.rb.rotation = G.U(new GBasis(Vector3.Cross(up, fw), up, fw).Quat());
                    car.LinearVelocity = Vector3.zero;
                    car.AngularVelocity = Vector3.zero;
                    car.ResetUpright();   // lifts it 1 m
                    rescues++;
                    Note("Back on the road");
                }
            }
            else if (!player.inVehicle && DepthBelowGround(player.Position) > UNDER_DEPTH)
            {
                player.Place(SidewalkSpawn(RoadPointNear(Planet.Flat(player.Position))), player.rig.yaw);
                player.Velocity = Vector3.zero;
                rescues++;
                Note("Back on the street");
            }
            // Cars nobody is in that fell through are only in the way: let them go.
            for (int i = vehicles.Count - 1; i >= 0; i--)
            {
                var v = vehicles[i];
                if (v == null) { vehicles.RemoveAt(i); continue; }
                if (v != car && v.driver == null && DepthBelowGround(v.Position) > 20f)
                {
                    vehicles.RemoveAt(i);
                    Destroy(v.gameObject);
                }
            }
        }

        // ------------------------------------------------------------------ cars ---

        void OnInteract()
        {
            if (!active || switching || down || player.dead) return;
            var best = FreeCarNear();
            if (best != null) StartCoroutine(EnterCar(best));
        }

        DrivableCar FreeCarNear()
        {
            DrivableCar best = null;
            float bestD = enterRadius;
            foreach (var v in vehicles)
            {
                if (v == null || v.driver != null || v.wrecked) continue;
                float d = Vector3.Distance(v.Position, player.Position);
                if (d < bestD) { best = v; bestD = d; }
            }
            return best;
        }

        /// <summary>Step to the driver's door, duck into the seat, then take the wheel.</summary>
        IEnumerator EnterCar(DrivableCar c)
        {
            if (switching) yield break;
            switching = true;
            car = c;
            if (Vector3.Dot(c.Basis.y, Planet.Up(c.Position)) < 0.5f) c.ResetUpright();   // on its side or roof
            if (c.parked && !c.playerOwned) Note("Stole a car");
            c.playerOwned = true;
            c.Crashed -= OnCarCrashed;
            c.Crashed += OnCarCrashed;
            c.SetDriver(player);     // ours now; input is ignored until we're seated
            c.driving = false;
            VehicleChanged?.Invoke(c);
            player.SetPuppet(true);
            player.rig.Exclude(c.colliders);   // don't let the car squash the camera
            Vector3 door = OnGround(c.ExitPoint() - Planet.Up(c.Position) * 0.2f);
            float yaw = c.HeadingYaw();
            Vector3 start = player.Position;
            int steps = Mathf.Max((int)(Vector3.Distance(start, door) / 3f * 60f), 4);
            var tick = new WaitForFixedUpdate();
            for (int i = 0; i < steps; i++)
            {
                float k = (i + 1f) / steps;
                player.Position = Vector3.Lerp(start, door, k);
                player.Face(G.LerpAngle(player.FacingYaw(), yaw, k));
                player.visual.Animate(1f / 60f, 2.5f, true, 0f, 0f);
                yield return tick;
                if (car != c) { EnterCutShort(c); yield break; }
            }
            player.visual.SetSitting(true);
            player.visual.PlayEnterCar();
            float dur = player.visual.ClipLength("EnterCar");
            float t = 0f;
            while (t < dur)
            {
                t += Time.fixedDeltaTime;
                float k = Mathf.Clamp01(t / dur);
                player.Position = Vector3.Lerp(door, c.SeatPoint(), k * k * (3f - 2f * k));
                player.Face(c.HeadingYaw());
                yield return tick;
                if (car != c) { EnterCutShort(c); yield break; }
            }
            camera.BlendTo(c.rig, 0.8f);
            player.rig.Include(c.colliders);
            player.SetInVehicle(true);
            c.driving = true;
            switching = false;
        }

        /// <summary>Tests: straight into the nearest car, no walk to the door.</summary>
        public bool TakeNearestCar()
        {
            DrivableCar best = null;
            float bestD = 60f;
            foreach (var v in vehicles)
                if (v != null && v.driver == null && Vector3.Distance(v.Position, player.Position) < bestD) { best = v; bestD = Vector3.Distance(v.Position, player.Position); }
            if (best == null || switching) return false;
            car = best;
            best.playerOwned = true;
            best.Crashed -= OnCarCrashed;
            best.Crashed += OnCarCrashed;
            best.SetDriver(player);
            player.SetInVehicle(true);
            camera.BlendTo(best.rig, 0.3f);
            VehicleChanged?.Invoke(best);
            return true;
        }

        void EnterCutShort(DrivableCar c)
        {
            player.rig.Include(c.colliders);
            c.driving = true;
            switching = false;
        }

        IEnumerator LeaveCar()
        {
            if (switching || car == null) yield break;
            switching = true;
            var c = car;
            car = null;
            Vector3 p = c.ExitPoint();
            // If the door side is blocked, try the other side, then the roof.
            bool doorSide = true;
            Vector3 up = Planet.Up(c.Position);
            var cands = new[] { p, p - c.Basis.x * (c.AabbSize.x + 1.4f), c.Position + up * (c.AabbSize.y + 1f) };
            foreach (var cand0 in cands)
            {
                var cand = OnGround(cand0);
                Vector3 a = cand + up * 0.3f, b = cand + up * 1.4f;
                bool blocked = false;
                foreach (var col in Physics.OverlapCapsule(G.U(a), G.U(b), 0.3f, Layers.Mask(Layers.WORLD, Layers.CARS, Layers.TRAFFIC), QueryTriggerInteraction.Ignore))
                    if (!c.colliders.Contains(col)) { blocked = true; break; }
                if (!blocked) { p = cand; break; }
                doorSide = false;
            }
            c.SetDriver(null);
            player.SetInVehicle(false);
            player.SetPuppet(true);
            player.rig.Exclude(c.colliders);
            player.rig.yaw = c.rig.yaw;
            player.rig.pitch = Mathf.Clamp(c.rig.pitch, player.rig.minPitch, player.rig.maxPitch);
            camera.BlendTo(player.rig, 0.9f);
            VehicleChanged?.Invoke(null);
            player.Face(c.HeadingYaw());
            var tick = new WaitForFixedUpdate();
            player.visual.SetSitting(false);
            if (doorSide)
            {
                player.visual.PlayExitCar();
                Vector3 seat = c.SeatPoint();
                float dur = player.visual.ClipLength("ExitCar");
                float t = 0f;
                while (t < dur)
                {
                    t += Time.fixedDeltaTime;
                    float k = Mathf.Clamp01(t / dur);
                    player.Position = Vector3.Lerp(seat, p - up * 0.2f, k * k * (3f - 2f * k));
                    player.Face(c.HeadingYaw());
                    yield return tick;
                }
            }
            player.Place(p, c.HeadingYaw());
            player.SetPuppet(false);
            player.rig.Include(c.colliders);
            player.SetControls(active || busy);
            switching = false;
        }

        void OnCarCrashed(float strength)
        {
            camera.Shake(0.25f + strength * 0.9f);
        }

        public DrivableCar SpawnCar(string model, Vector3 pos, float yaw, Color color)
        {
            var at = new GXform(Planet.Basis(pos) * GBasis.Rotation(Vector3.up, yaw), pos);   // yaw in the local frame
            var c = DrivableCar.Spawn(_carsRoot, model, color, at);
            vehicles.Add(c);
            return c;
        }

        /// <summary>Park a few cars at the kerb of nearby straight roads so there's always a ride.</summary>
        public void SpawnParkedCarsNear(Vector3 p, int count)
        {
            if (city == null) return;
            int existing = 0;
            foreach (var v in vehicles) if (v != null && Vector3.Distance(v.Position, p) < 40f) existing++;
            int need = count - existing;
            if (need <= 0) return;
            var origin = city.WorldToCell(p);
            var spots = new List<Vector2Int>();
            for (int r = 0; r < 5; r++)
                for (int y = origin.y - r; y <= origin.y + r; y++)
                    for (int x = origin.x - r; x <= origin.x + r; x++)
                    {
                        if (Mathf.Max(Mathf.Abs(x - origin.x), Mathf.Abs(y - origin.y)) != r || !city.IsRoad(x, y)) continue;
                        int m = city.RoadMask(x, y);
                        if (m == (2 | 8) || m == (1 | 4)) spots.Add(new Vector2Int(x, y));
                    }
            foreach (var cell in spots)
            {
                if (need <= 0) break;
                int m = city.RoadMask(cell.x, cell.y);
                var c = city.CellCenter(cell.x, cell.y);
                float side = _rng.NextDouble() < 0.5 ? 1f : -1f;
                float along = (float)(_rng.NextDouble() * 5.0 - 2.5);
                Vector3 pos;
                float yaw;
                if (m == (2 | 8))   // road runs along X: park at a kerb, drive on the right
                {
                    pos = c + new Vector3(along, 0.15f, side * PARK_OUT);
                    yaw = side > 0f ? Mathf.PI * 0.5f : -Mathf.PI * 0.5f;
                }
                else
                {
                    pos = c + new Vector3(side * PARK_OUT, 0.15f, along);
                    yaw = side < 0f ? 0f : Mathf.PI;
                }
                pos.y += (float)city.TerrainHeight(pos.x, pos.z);
                pos = Planet.Place(pos);
                bool clear = true;
                foreach (var v in vehicles) if (v != null && Vector3.Distance(v.Position, pos) < 6f) clear = false;
                if (!clear) continue;
                var parked = SpawnCar(CAR_MODELS[_rng.Next(CAR_MODELS.Length)], pos, yaw, CAR_COLORS[_rng.Next(CAR_COLORS.Length)]);
                parked.parked = true;   // someone else's: taking it is theft
                need--;
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
