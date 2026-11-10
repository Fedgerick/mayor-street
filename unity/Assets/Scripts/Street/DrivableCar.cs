// Port of player/scripts/drivable_car.gd: an enterable, drivable car using the car kit's meshes.
// msp's car is a Godot VehicleBody3D (Bullet's raycast vehicle); Unity has no such body, so
// WheelSim below does what VehicleBody3D does each physics tick: a ray per wheel, a spring and
// damper scaled by the car's mass, a sideways bilateral impulse and a forward (engine, brake)
// impulse, both held inside a friction circle. The tuning on top of it (power curve, drag,
// speed-sensitive steering, downforce, tip damping, the visual body spring) is msp's, line for
// line. Arcade feel: grippy, forgiving, self-righting.
//
// Godot space throughout; the Rigidbody is read and written through the mirror (G.U). Its
// angular velocity and torques are axial vectors, so they mirror as (x, -y, -z).
// Kit cars face -Z; the body drives along +Z, so the mesh is turned 180 degrees inside it.
using System;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class DrivableCar : MonoBehaviour
    {
        public event Action<StreetPlayer> DriverChanged;
        public event Action<float> Damaged;
        public event Action<DrivableCar> Exploded;
        public event Action<float> Crashed;     // a hard knock, 0..1, for camera shake and sound

        public const float SAG = 0.15f;
        public const float MAX_HEALTH = 1000f;
        public const float SMOKE_AT = 400f;
        public const float BURN_SECONDS = 4.5f;
        public const float CRASH_DV = 9f;
        public const float CRASH_DAMAGE = 16f;
        public const float HEFT = 1.4f;
        public const float SETTLE_TIME = 0.3f;
        public const float MAX_KICK_UP = 3f;
        public const float MAX_SPIN = 5f;
        public const float TIP_DAMP = 3.5f;
        public const float RIGHTING = 9000f;
        public const float KNEE = 0.38f;
        public const float ROLLING = 0.12f;
        public const float ENGINE_BRAKE = 0.7f;
        public const float BRAKE_G = 0.95f;
        public const float BRAKE_G_HEAVY = 0.62f;
        public const float GRIP = 1.25f;
        public const float STEER_PAST_GRIP = 1.3f;
        public const float SEAT_DROP = 0.52f;
        public const float MAX_ROLL = 0.09f, MAX_PITCH = 0.06f;
        public static readonly string[] EMERGENCY = { "car_police", "car_ambulance", "car_firetruck" };

        // model: wheel radius, front axle z, rear axle z, half track, mass, max engine force, top speed m/s
        static readonly Dictionary<string, float[]> MODELS = new Dictionary<string, float[]>
        {
            { "car_sedan", new[] { 0.36f, 1.4f, -1.35f, 0.81f, 1250f, 5200f, 38f } },
            { "car_hatch", new[] { 0.36f, 1.1f, -1.05f, 0.76f, 1050f, 4300f, 34f } },
            { "car_taxi", new[] { 0.36f, 1.4f, -1.35f, 0.81f, 1300f, 5300f, 37f } },
            { "car_sports", new[] { 0.36f, 0f, 0f, 0f, 1150f, 7800f, 48f } },
            { "car_police", new[] { 0.36f, 0f, 0f, 0f, 1500f, 7000f, 44f } },
            { "car_pickup", new[] { 0.42f, 0f, 0f, 0f, 1900f, 6800f, 33f } },
            { "car_van", new[] { 0.36f, 1.6f, -1.55f, 0.88f, 1700f, 6000f, 31f } },
            { "car_ambulance", new[] { 0.42f, 0f, 0f, 0f, 2600f, 8500f, 33f } },
            { "car_truck", new[] { 0.48f, 2.6f, -2.55f, 1.06f, 3200f, 10500f, 26f } },
            { "car_bus", new[] { 0.5f, 0f, 0f, 0f, 9000f, 21000f, 22f } },
            { "car_firetruck", new[] { 0.5f, 0f, 0f, 0f, 9000f, 23000f, 26f } },
            { "car_garbage", new[] { 0.5f, 0f, 0f, 0f, 8500f, 19000f, 22f } },
        };

        public struct Feel { public float roll, pitch, spring, steer, grip; public Feel(float r, float p, float s, float st, float g) { roll = r; pitch = p; spring = s; steer = st; grip = g; } }
        static readonly Dictionary<string, Feel> FEEL = new Dictionary<string, Feel>
        {
            { "default", new Feel(0.010f, 0.006f, 55f, 3.2f, 1.0f) },
            { "car_sports", new Feel(0.006f, 0.004f, 90f, 3.8f, 1.12f) },
            { "car_police", new Feel(0.008f, 0.005f, 70f, 3.5f, 1.06f) },
            { "car_hatch", new Feel(0.011f, 0.007f, 55f, 3.4f, 1.0f) },
            { "car_pickup", new Feel(0.014f, 0.008f, 42f, 2.8f, 0.95f) },
            { "car_van", new Feel(0.015f, 0.008f, 40f, 2.7f, 0.93f) },
            { "car_ambulance", new Feel(0.016f, 0.009f, 38f, 2.5f, 0.92f) },
            { "car_truck", new Feel(0.018f, 0.009f, 34f, 2.2f, 0.9f) },
            { "car_bus", new Feel(0.02f, 0.01f, 28f, 1.8f, 0.88f) },
            { "car_firetruck", new Feel(0.019f, 0.01f, 30f, 1.9f, 0.9f) },
            { "car_garbage", new Feel(0.02f, 0.01f, 28f, 1.8f, 0.88f) },
        };

        class Wheel
        {
            public Vector3 pos;              // hardpoint, body space
            public float radius, rest = 0.22f, travel = 0.22f, stiffness, maxForce;
            public float dampC = 0.8f, dampR = 1.1f, slip, rollInfluence = 0.06f;
            public bool steer, traction = true;
            public float engineForce, brake;
            // per tick
            public bool contact;
            public Vector3 point, normal;
            public float length, relVel, invDot = 1f, force, sideImp, fwdImp, skid;
            public Vector3 fwd, side;
        }

        public string model = "car_sedan";
        public Color tint = new Color(0.85f, 0.12f, 0.1f);
        public float maxSteer = 0.6f;
        public float steerSpeed = 3.2f;
        public float brakeForce = 40f;
        public float handling = 1f;
        public float weatherGrip = 1f;

        public StreetPlayer driver;
        public OrbitRig rig;
        public float throttle, steerInput, steering;
        public bool headlightsOn;
        public bool parked, playerOwned;
        public bool driving = true;                  // msp's set_physics_process: input and tuning run
        public float health = MAX_HEALTH;
        public bool burning, wrecked;
        public int damageStage;

        public Rigidbody rb;
        public readonly List<Collider> colliders = new List<Collider>();
        public Vector3 AabbSize => _aabb.size;

        readonly List<Wheel> _wheels = new List<Wheel>();
        float _engine = 4500f, _topSpeed = 35f, _drag, _steer, _wheelbase = 2.7f;
        float _landT, _landCap, _brakeNewtons, _upsideDown, _burn, _settle;
        Bounds _aabb;
        Vector3 _lastVel, _accel;
        Feel _feel;
        Vector2 _roll, _pitch, _heave;
        float _wheelAngle;
        bool _kitShader, _braking;
        float _radius = 0.36f, _seed;
        Vector3 _seat;
        int _dmgMesh;
        Transform _tilt;
        MeshFilter _mf;
        MeshRenderer _mr;
        MaterialPropertyBlock _mpb;
        Light _headlights;
        Color _paint;

        static readonly int ID_COLOR = Shader.PropertyToID("_InstColor");
        static readonly int ID_CUSTOM = Shader.PropertyToID("_InstCustom");
        static int GroundMask => Layers.Mask(Layers.WORLD, Layers.TRAFFIC);

        // ------------------------------------------------------------------ Godot-space body ---

        public Vector3 Position => G.FromU(rb.position);
        public GBasis Basis => GBasis.FromQuat(G.FromU(rb.rotation));
        public GXform Xform => new GXform(Basis, Position);
        public Vector3 LinearVelocity { get => G.FromU(rb.linearVelocity); set => rb.linearVelocity = G.U(value); }
        public Vector3 AngularVelocity { get => Ax(rb.angularVelocity); set => rb.angularVelocity = Ax(value); }
        static Vector3 Ax(Vector3 w) => new Vector3(w.x, -w.y, -w.z);   // axial vectors through the mirror
        /// <summary>The interpolated (drawn) position, for cameras.</summary>
        public Vector3 DrawnPosition => G.FromU(transform.position);

        void ApplyTorque(Vector3 t) => rb.AddTorque(Ax(t), ForceMode.Force);
        void ApplyCentralForce(Vector3 f) => rb.AddForce(G.U(f), ForceMode.Force);
        void ApplyImpulseAt(Vector3 imp, Vector3 at) => rb.AddForceAtPosition(G.U(imp), G.U(at), ForceMode.Impulse);
        Vector3 PointVelocity(Vector3 p) => G.FromU(rb.GetPointVelocity(G.U(p)));
        Vector3 CenterOfMass => G.FromU(rb.worldCenterOfMass);

        // ------------------------------------------------------------------ setup ---

        public static DrivableCar Spawn(Transform parent, string model, Color tint, GXform at)
        {
            var go = new GameObject("Car_" + model);
            go.transform.SetParent(parent, false);
            go.SetActive(false);
            var c = go.AddComponent<DrivableCar>();
            c.model = model;
            c.tint = tint;
            G.Apply(go.transform, at);
            go.SetActive(true);
            return c;
        }

        void Awake()
        {
            gameObject.layer = Layers.CARS;
            rb = gameObject.AddComponent<Rigidbody>();
        }

        void Start()
        {
            float[] spec = MODELS.TryGetValue(model, out var sp) ? sp : MODELS["car_sedan"];
            _radius = spec[0];
            _feel = FEEL.TryGetValue(model, out var fe) ? fe : FEEL["default"];
            rb.mass = spec[4] * HEFT;
            _engine = spec[5] * HEFT;
            _topSpeed = spec[6];
            steerSpeed = _feel.steer;
            rb.useGravity = false;
            rb.linearDamping = 0f;
            rb.angularDamping = 1.5f;
            rb.interpolation = RigidbodyInterpolation.Interpolate;
            rb.collisionDetectionMode = CollisionDetectionMode.ContinuousDynamic;
            _drag = Mathf.Max(_engine * KNEE - ROLLING * rb.mass, 0f) / (_topSpeed * _topSpeed);
            _seed = UnityEngine.Random.value;
            _paint = tint;
            BuildVisual();
            BuildBody(spec);
            rb.automaticCenterOfMass = false;
            rb.centerOfMass = G.U(new Vector3(0f, 0.3f, 0.05f));   // low, so it doesn't tip over on a kerb
            // Settle: a car spawned over an AI car's stand-in ignores the stand-ins for a moment.
            rb.excludeLayers = 1 << Layers.TRAFFIC;
            _settle = SETTLE_TIME;
            rig = new OrbitRig
            {
                target = () => DrawnPosition,
                height = _aabb.size.y + 0.9f,
                distance = 5f + _aabb.size.z * 0.45f,
                sideOffset = 0f,
                recenterSpeed = 3f,
                minPitch = -50f * Mathf.Deg2Rad,
                maxPitch = 15f * Mathf.Deg2Rad,
                pitch = -12f * Mathf.Deg2Rad,
            };
            rig.Exclude(colliders);
            rig.yaw = HeadingYaw();
            rig.Snap();
            _lastVel = Vector3.zero;
        }

        public static Dictionary<string, object> KitSpec(string m) => VehicleKit.Spec(m);

        public bool IsEmergency() => Array.IndexOf(EMERGENCY, model) >= 0;

        void BuildVisual()
        {
            Mesh mesh = VehicleKit.Mesh(model);
            _kitShader = mesh != null;
            if (mesh == null)
            {
                // Fallback so the car still works without the kit.
                var tmp = GameObject.CreatePrimitive(PrimitiveType.Cube);
                mesh = tmp.GetComponent<MeshFilter>().sharedMesh;
                Destroy(tmp);
                _aabb = new Bounds(new Vector3(0f, 0.6f, 0f), new Vector3(1.8f, 1.2f, 4.3f));
            }
            else
            {
                var b = mesh.bounds;
                _aabb = new Bounds(G.FromU(b.center), b.size);
            }
            var ks = KitSpec(model);
            if (_kitShader && ks != null && ks.ContainsKey("seat"))
            {
                var seat = ks["seat"] as List<object>;
                _seat = new Vector3(-Json.F(seat[0]), Json.F(seat[1]), -Json.F(seat[2]));
                _radius = Json.F(Json.Get(ks, "wheel_radius"), _radius);
            }
            else _seat = new Vector3(0.38f, 0.25f + SEAT_DROP, model != "car_truck" ? 0.15f : 2.2f);

            var tilt = new GameObject("Tilt");
            tilt.transform.SetParent(transform, false);
            tilt.transform.localPosition = new Vector3(0f, 0.45f, 0f);
            tilt.layer = Layers.CARS;
            _tilt = tilt.transform;
            var bodyGo = new GameObject("Body");
            bodyGo.layer = Layers.CARS;
            bodyGo.transform.SetParent(_tilt, false);
            G.ApplyLocal(bodyGo.transform, new GXform(GBasis.Rotation(Vector3.up, Mathf.PI), new Vector3(0f, -0.45f, 0f)));
            _mf = bodyGo.AddComponent<MeshFilter>();
            _mf.sharedMesh = mesh;
            _mr = bodyGo.AddComponent<MeshRenderer>();
            if (_kitShader) _mr.sharedMaterials = VehicleKit.Materials();
            else
            {
                bodyGo.transform.localPosition = new Vector3(0f, 0.15f, 0f);
                bodyGo.transform.localScale = _aabb.size;
                _mr.sharedMaterial = Mats.Make(tint);
            }
            _mpb = new MaterialPropertyBlock();
            WriteInstance();

            float hl = _aabb.size.z * 0.5f;
            var lgo = new GameObject("Headlights");
            lgo.transform.SetParent(transform, false);
            lgo.transform.localPosition = G.U(new Vector3(0f, 0.8f, hl + 0.1f));
            var dir = new Vector3(0f, -Mathf.Sin(8f * Mathf.Deg2Rad), Mathf.Cos(8f * Mathf.Deg2Rad));
            lgo.transform.localRotation = Quaternion.LookRotation(G.U(dir), Vector3.up);
            _headlights = lgo.AddComponent<Light>();
            _headlights.type = LightType.Spot;
            _headlights.range = 38f;
            _headlights.spotAngle = 76f;
            _headlights.innerSpotAngle = 40f;
            _headlights.intensity = 6f;
            _headlights.color = new Color(1f, 0.95f, 0.85f);
            _headlights.shadows = LightShadows.None;
            _headlights.enabled = false;
        }

        void BuildBody(float[] spec)
        {
            float r = spec[0];
            float lowerH = Mathf.Min(_aabb.size.y, model != "car_truck" ? 1.05f : 1.3f);
            var box = AddBox(new Vector3(_aabb.size.x - 0.04f, lowerH - r * 0.9f, _aabb.size.z - 0.05f), 0f);
            box.center = new Vector3(0f, r * 0.9f + box.size.y * 0.5f, 0f);
            if (_aabb.size.y > lowerH + 0.1f)
            {
                var cab = AddBox(new Vector3(_aabb.size.x - 0.3f, _aabb.size.y - lowerH, _aabb.size.z * 0.5f), 0f);
                float cz = model != "car_truck" ? 0f : spec[1] - 0.4f;
                cab.center = G.U(new Vector3(0f, lowerH + cab.size.y * 0.5f, cz));
            }
            float front = spec[1] != 0f ? spec[1] : _aabb.size.z * 0.31f;
            float rear = spec[2] != 0f ? spec[2] : -_aabb.size.z * 0.3f;
            float track = spec[3] != 0f ? spec[3] : _aabb.size.x * 0.42f;
            var axles = new List<(float z, bool steer)> { (front, true), (rear, false) };
            if (rb.mass > 3000f) axles.Add((Mathf.Lerp(front, rear, 0.72f), false));
            var ks = KitSpec(model);
            if (_kitShader && ks != null && ks.ContainsKey("axles"))
            {
                axles.Clear();
                foreach (var a in (List<object>)ks["axles"])
                {
                    var ad = (Dictionary<string, object>)a;
                    axles.Add((-Json.F(ad["z"]), Json.B(ad["steer"])));
                }
                track = Json.F(Json.Get(ks, "track"), track);
            }
            foreach (var ax in axles)
                for (int s = -1; s <= 1; s += 2)
                    _wheels.Add(new Wheel
                    {
                        pos = new Vector3(s * track, r + 0.22f - SAG, ax.z),
                        radius = r,
                        stiffness = rb.mass < 3000f ? 42f : 52f,
                        maxForce = rb.mass * 14f,
                        slip = GRIP * _feel.grip,
                        steer = ax.steer,
                    });
            _wheelbase = Mathf.Max(Mathf.Abs(axles[0].z - axles[1].z), 1.5f);
            float bg = Mathf.Lerp(BRAKE_G, BRAKE_G_HEAVY, Mathf.Clamp01((rb.mass - 3000f) / 9000f));
            _brakeNewtons = bg * 9.8f * rb.mass / _wheels.Count;
            brakeForce = _brakeNewtons / 60f;
        }

        BoxCollider AddBox(Vector3 size, float z)
        {
            var bc = gameObject.AddComponent<BoxCollider>();
            bc.size = size;
            colliders.Add(bc);
            return bc;
        }

        // ------------------------------------------------------------------ queries ---

        public Vector3 Forward() => Basis.z;
        /// <summary>Signed forward speed, m/s.</summary>
        public float Speed() => Vector3.Dot(LinearVelocity, Forward());

        /// <summary>In the local frame (on msp, the frame standing on the ball under the car).</summary>
        public float HeadingYaw()
        {
            var f = Planet.ToLocal(Position, Forward());
            return Mathf.Atan2(-f.x, -f.z);
        }

        public void SetDriver(StreetPlayer d)
        {
            driver = d;
            rig.inputEnabled = d != null;
            headlightsOn = d != null;
            _headlights.enabled = headlightsOn;
            if (d == null)
            {
                throttle = 0f;
                steerInput = 0f;
            }
            else
            {
                rig.yaw = HeadingYaw();
                rig.Snap();
            }
            DriverChanged?.Invoke(d);
        }

        /// <summary>Where the driver's feet go when seated (left seat), world space.</summary>
        public Vector3 SeatPoint()
        {
            var b = Basis;
            return Position + b.x * _seat.x + b.z * _seat.z + b.y * (_seat.y - SEAT_DROP);
        }

        /// <summary>Beside the driver's door (left side), on the ground.</summary>
        public Vector3 ExitPoint()
        {
            var b = Basis;
            return Position + b.x * (_aabb.size.x * 0.5f + 0.7f) + b.z * (_seat.z + 0.15f) + Up() * 0.2f;
        }

        public bool InContact()
        {
            foreach (var w in _wheels) if (w.contact) return true;
            return false;
        }

        // ------------------------------------------------------------------ damage ---

        public void TakeHit(float amount, Vector3 fromPos = default, Vector3 dir = default)
        {
            if (wrecked || amount <= 0f) return;
            health = Mathf.Max(health - amount, 0f);
            Damaged?.Invoke(amount);
            if (health < MAX_HEALTH * 0.75f) SetDamage(health >= SMOKE_AT ? 1 : 2);
            if (health <= 0f && !burning)
            {
                burning = true;
                _burn = 0f;
            }
        }

        public void Explode()
        {
            if (wrecked) return;
            wrecked = true;
            burning = false;
            health = 0f;
            if (!SetDamage(3)) _paint = new Color(0.06f, 0.055f, 0.05f);
            _headlights.enabled = false;
            foreach (var w in _wheels)
            {
                w.engineForce = 0f;
                w.brake = brakeForce;
            }
            rb.AddForce(G.U(Up() * rb.mass * 4.5f), ForceMode.Impulse);
            rb.AddTorque(Ax(new Vector3(UnityEngine.Random.Range(-1f, 1f), 0f, UnityEngine.Random.Range(-1f, 1f)) * rb.mass * 1.2f), ForceMode.Impulse);
            Exploded?.Invoke(this);
        }

        /// <summary>Swap to the car kit's dented / smashed / burnt mesh. False when there isn't one.</summary>
        bool SetDamage(int stage)
        {
            if (stage > damageStage)
            {
                damageStage = stage;
                var m = _kitShader ? VehicleKit.Damaged(model, stage) : null;
                if (m != null)
                {
                    _mf.sharedMesh = m;
                    _dmgMesh = stage;
                }
            }
            return _dmgMesh == stage;
        }

        // ------------------------------------------------------------------ physics ---

        Vector3 Up() => Planet.Up(Position);

        void FixedUpdate()
        {
            float delta = Time.fixedDeltaTime;
            if (_settle > 0f)
            {
                _settle -= delta;
                if (_settle <= 0f) rb.excludeLayers = 0;
            }
            // Point gravity on msp: toward the ball's centre.
            rb.AddForce(G.U(Planet.Gravity(Position)), ForceMode.Acceleration);
            if (driving) PhysicsProcess(delta);
            WheelSim(delta);
        }

        void SteadyBody(float delta)
        {
            if (wrecked) return;
            var v = LinearVelocity;
            var upv = Up();
            float vy = Vector3.Dot(v, upv);
            float vyCap = Mathf.Max(Vector3.Dot(_lastVel, upv), 0f) + MAX_KICK_UP;
            float fall = -Vector3.Dot(_lastVel, upv);
            if (fall > 2f)
            {
                // Coming down hard: the ground gives back a quarter of the landing speed at most.
                _landCap = 0.5f + fall * 0.25f;
                _landT = 0.25f;
            }
            if (_landT > 0f)
            {
                _landT -= delta;
                vyCap = Mathf.Min(vyCap, _landCap);
            }
            if (vy > vyCap)
            {
                v -= upv * (vy - vyCap);
                LinearVelocity = v;
            }
            if (InContact())
            {
                var b = Basis;
                var local = b.Inverse() * AngularVelocity;
                var damp = new Vector3(local.x, 0f, local.z) * TIP_DAMP * rb.mass * 1.2f;
                ApplyTorque(-(b * damp));
                var up = b.y;
                float lean = Mathf.Acos(Mathf.Clamp(Vector3.Dot(up, upv), -1f, 1f));
                if (lean > 0.44f && lean < 1.9f)
                {
                    var axis = Vector3.Cross(up, upv);
                    if (axis.magnitude > 0.001f) ApplyTorque(axis.normalized * (lean - 0.44f) * RIGHTING * (rb.mass / 1000f));
                }
            }
            if (rb.angularVelocity.magnitude > MAX_SPIN) rb.angularVelocity = rb.angularVelocity.normalized * MAX_SPIN;
        }

        void PhysicsProcess(float delta)
        {
            brakeForce = _brakeNewtons * delta;
            SteadyBody(delta);
            var lv = LinearVelocity;
            float dv = (lv - _lastVel).magnitude;
            if (delta > 0f)
            {
                var a = Basis.Inverse() * ((lv - _lastVel) / delta);
                _accel = Vector3.Lerp(_accel, Vector3.ClampMagnitude(a, 40f), 1f - Mathf.Exp(-10f * delta));
            }
            _lastVel = lv;
            if (dv > CRASH_DV * 0.6f && delta > 0f)
            {
                Crashed?.Invoke(Mathf.Clamp((dv - CRASH_DV * 0.6f) / 14f, 0.15f, 1f));
                _heave.y -= Mathf.Min(dv * 0.08f, 0.6f);
                _pitch.y += UnityEngine.Random.Range(-1f, 1f) * Mathf.Min(dv * 0.04f, 0.4f);
            }
            if (dv > CRASH_DV && delta > 0f) TakeHit((dv - CRASH_DV) * CRASH_DAMAGE);
            BodyMotion(delta);
            if (burning)
            {
                _burn += delta;
                if (_burn >= BURN_SECONDS) Explode();
            }
            if (wrecked) return;
            float v = Speed();
            bool hb = false;
            if (driver != null)
            {
                throttle = Mathf.Clamp01(StreetInput.Throttle) - Mathf.Clamp01(StreetInput.Brake);
                steerInput = StreetInput.Steer;
                hb = StreetInput.Handbrake;
                if (_resetQueued) ResetUpright();
            }
            _resetQueued = false;
            // Speed-sensitive steering: full lock when slow; at speed no more than the tyres can use.
            float gripG = GRIP * handling * _feel.grip * weatherGrip * 9.8f + 0.004f * v * v;
            float lockAngle = Mathf.Min(maxSteer * Mathf.Clamp(handling, 0.5f, 1.5f), Mathf.Atan(_wheelbase * gripG * STEER_PAST_GRIP / Mathf.Max(v * v, 1f)));
            _steer = G.MoveToward(_steer, steerInput * lockAngle, steerSpeed * delta);
            steering = _steer + RoadBend();

            bool braking = false;
            float ef = 0f, bf = 0f;
            if (throttle > 0.05f)
            {
                if (v < -1f) { bf = brakeForce * throttle; braking = true; }
                else ef = _engine * handling * throttle * Mathf.Min(1f, KNEE * _topSpeed / Mathf.Max(v, 0.1f));
            }
            else if (throttle < -0.05f)
            {
                if (v > 1f) { bf = brakeForce * -throttle; braking = true; }
                else ef = _engine * 0.6f * throttle * Mathf.Clamp01(1f + v / (_topSpeed * 0.35f));
            }
            else if (driver == null || Mathf.Abs(v) < 0.5f) bf = brakeForce * 0.3f;   // parked, or held on a slope
            float grip = GRIP * handling * _feel.grip * weatherGrip;
            foreach (var w in _wheels)
            {
                bool rear = w.pos.z < 0f;
                w.brake = hb && rear ? brakeForce * 1.5f : bf;
                w.slip = hb && rear ? grip * 0.55f : grip;
                w.engineForce = hb && rear ? 0f : ef / _wheels.Count;
            }
            Resist(Mathf.Abs(throttle) < 0.05f && driver != null);
            _braking = braking || hb || (driver != null && throttle < -0.05f && v > 0.5f);

            ApplyCentralForce(-Up() * rb.mass * 0.004f * v * v);   // downforce
            if (Vector3.Dot(Basis.y, Up()) < 0.3f)
            {
                _upsideDown += delta;
                if (_upsideDown > 2.5f && driver != null) ResetUpright();
            }
            else _upsideDown = 0f;
            rig.heading = HeadingYaw();
        }

        bool _resetQueued;

        void Resist(bool coasting)
        {
            var vel = LinearVelocity;
            float sp = vel.magnitude;
            if (sp < 0.05f) return;
            float f = _drag * sp * sp;
            if (InContact()) f += (ROLLING + (coasting ? ENGINE_BRAKE : 0f)) * rb.mass * Mathf.Min(sp, 1f);
            ApplyCentralForce(-vel / sp * f);
        }

        /// <summary>msp: the steering it takes to follow the map's own straight lines (an east-west
        /// street is a circle of latitude, which bends toward the pole).</summary>
        float RoadBend()
        {
            if (!Planet.on) return 0f;
            float lat = Planet.LatOf(Planet.Flat(Position));
            float east = Planet.ToLocal(Position, Forward()).x;
            return Mathf.Atan(_wheelbase * east * Mathf.Tan(lat) / Planet.R);
        }

        /// <summary>What VehicleBody3D does each tick: rays, springs, then tyre impulses.</summary>
        void WheelSim(float dt)
        {
            var xf = Xform;
            var up = xf.basis.y;
            float mass = rb.mass;
            var com = CenterOfMass;
            foreach (var w in _wheels)
            {
                Vector3 hard = xf * w.pos;
                Vector3 dir = -up;
                float rayLen = w.rest + w.radius;
                w.contact = false;
                if (RayGround(hard, dir, rayLen, out var hit))
                {
                    w.contact = true;
                    w.point = G.FromU(hit.point);
                    w.normal = G.FromU(hit.normal);
                    w.length = Mathf.Clamp(hit.distance - w.radius, w.rest - w.travel, w.rest + w.travel);
                    float denom = Vector3.Dot(w.normal, dir);
                    if (denom >= -0.1f) { w.relVel = 0f; w.invDot = 10f; }
                    else
                    {
                        w.invDot = -1f / denom;
                        w.relVel = Vector3.Dot(w.normal, PointVelocity(w.point)) * w.invDot;
                    }
                    float f = w.stiffness * (w.rest - w.length) * w.invDot;
                    f -= (w.relVel < 0f ? w.dampC : w.dampR) * w.relVel;
                    w.force = Mathf.Min(Mathf.Max(f * mass, 0f), w.maxForce);
                    ApplyImpulseAt(w.normal * w.force * dt, w.point);
                }
                else
                {
                    w.length = w.rest;
                    w.relVel = 0f;
                    w.force = 0f;
                }
            }
            // Friction: sideways bilateral impulse, forward engine or rolling/brake impulse.
            bool sliding = false;
            foreach (var w in _wheels)
            {
                w.sideImp = w.fwdImp = 0f;
                w.skid = 1f;
                if (!w.contact) continue;
                var wb = xf.basis * (w.steer ? GBasis.Rotation(Vector3.up, steering) : GBasis.Identity);
                var side = wb.x - w.normal * Vector3.Dot(wb.x, w.normal);
                side = side.sqrMagnitude > 1e-6f ? side.normalized : wb.x;
                var fwd = Vector3.Cross(side, w.normal).normalized;   // +Z for an unsteered wheel on flat ground
                w.side = side;
                w.fwd = fwd;
                w.sideImp = Bilateral(w.point, side, com, 0.2f);
                float rolling;
                if (w.engineForce != 0f) rolling = w.engineForce * dt;
                else
                {
                    float maxImp = w.brake;
                    rolling = maxImp > 0f ? Mathf.Clamp(Bilateral(w.point, fwd, com, 1f), -maxImp, maxImp) : 0f;
                }
                w.fwdImp = rolling;
                float maximp = w.force * dt * w.slip;
                float x = w.fwdImp * 0.5f, y = w.sideImp;
                float sq = x * x + y * y;
                if (sq > maximp * maximp)
                {
                    sliding = true;
                    w.skid *= maximp / Mathf.Sqrt(sq);
                }
            }
            if (sliding)
                foreach (var w in _wheels)
                    if (w.sideImp != 0f && w.skid < 1f)
                    {
                        w.fwdImp *= w.skid;
                        w.sideImp *= w.skid;
                    }
            foreach (var w in _wheels)
            {
                if (!w.contact) continue;
                if (w.fwdImp != 0f) ApplyImpulseAt(w.fwd * w.fwdImp, w.point);
                if (w.sideImp != 0f)
                {
                    var rel = w.point - com;
                    rel -= up * (Vector3.Dot(up, rel) * (1f - w.rollInfluence));
                    ApplyImpulseAt(w.side * w.sideImp, com + rel);
                }
            }
        }

        /// <summary>Bullet's resolveSingleBilateral against static ground: the impulse along axis
        /// that removes `damping` of the contact point's velocity along it.</summary>
        float Bilateral(Vector3 point, Vector3 axis, Vector3 com, float damping)
        {
            // effective mass at the point along the axis (computed in Unity space; the term is
            // the same either side of the mirror)
            Vector3 rU = G.U(point - com), aU = G.U(axis);
            Vector3 c = Vector3.Cross(rU, aU);
            Quaternion q = rb.rotation * rb.inertiaTensorRotation;
            Vector3 cl = Quaternion.Inverse(q) * c;
            Vector3 it = rb.inertiaTensor;
            Vector3 ic = new Vector3(it.x > 0 ? cl.x / it.x : 0f, it.y > 0 ? cl.y / it.y : 0f, it.z > 0 ? cl.z / it.z : 0f);
            float jac = 1f / rb.mass + Vector3.Dot(cl, ic);
            float relVel = Vector3.Dot(axis, PointVelocity(point));
            return -damping * relVel / jac;
        }

        bool RayGround(Vector3 from, Vector3 dir, float len, out RaycastHit best)
        {
            best = default;
            var hits = Physics.RaycastAll(G.U(from), G.U(dir), len, GroundMask, QueryTriggerInteraction.Ignore);
            float bd = float.PositiveInfinity;
            foreach (var h in hits)
            {
                if (colliders.Contains(h.collider)) continue;
                if (h.distance < bd) { bd = h.distance; best = h; }
            }
            return bd < float.PositiveInfinity;
        }

        void BodyMotion(float delta)
        {
            bool onGround = InContact();
            float k = _feel.spring;
            float damp = 2f * Mathf.Sqrt(k) * 0.55f;
            float rollGoal = onGround ? Mathf.Clamp(_accel.x * _feel.roll, -MAX_ROLL, MAX_ROLL) : 0f;
            float pitchGoal = onGround ? Mathf.Clamp(-_accel.z * _feel.pitch, -MAX_PITCH, MAX_PITCH) : 0f;
            float heaveGoal = Mathf.Clamp(-_accel.y * 0.004f, -0.05f, 0.05f);
            Spring(ref _roll, rollGoal, k, damp, delta);
            Spring(ref _pitch, pitchGoal, k, damp, delta);
            Spring(ref _heave, heaveGoal, k, damp, delta);
            _roll.x = Mathf.Clamp(_roll.x, -MAX_ROLL * 1.4f, MAX_ROLL * 1.4f);
            _pitch.x = Mathf.Clamp(_pitch.x, -MAX_PITCH * 1.4f, MAX_PITCH * 1.4f);
            _heave.x = Mathf.Clamp(_heave.x, -0.12f, 0.08f);
            if (_kitShader && !wrecked) _wheelAngle += Speed() * delta / _radius;
        }

        static void Spring(ref Vector2 st, float goal, float k, float damp, float delta)
        {
            st.y += ((goal - st.x) * k - st.y * damp) * delta;
            st.x += st.y * delta;
        }

        void Update()
        {
            float delta = Mathf.Min(Time.deltaTime, 0.05f);
            if (driver != null && driving && StreetInput.ResetPressed) _resetQueued = true;
            // The body's lean on its visual spring (Tilt: rotation (pitch, 0, roll), Godot Euler YXZ).
            G.ApplyLocal(_tilt, new GXform(GBasis.Rotation(Vector3.right, _pitch.x) * GBasis.Rotation(Vector3.forward, _roll.x),
                new Vector3(0f, 0.45f + _heave.x, 0f)));
            WriteInstance();
            rig.Update(delta);
        }

        /// <summary>VehicleKit.custom() flags: brake 2, empty 4, headlights 8.</summary>
        public int LampFlags() => (_braking ? 2 : 0) | (driver == null ? 4 : 0) | (headlightsOn ? 8 : 0);

        void WriteInstance()
        {
            if (_mr == null) return;
            _mpb.SetVector(ID_COLOR, (Vector4)_paint);
            _mpb.SetVector(ID_CUSTOM, _kitShader && !wrecked
                ? new Vector4(LampFlags(), G.Fposmod(_wheelAngle, G.TAU), steering, 0.37f)
                : new Vector4(4f, 0f, 0f, 0.37f));
            _mr.SetPropertyBlock(_mpb);
        }

        public Vector2 BodyTilt() => new Vector2(_roll.x, _pitch.x);

        public void ResetUpright()
        {
            var up = Up();
            var fw = Forward();
            fw = fw - up * Vector3.Dot(fw, up);
            fw = fw.magnitude < 0.1f ? Planet.Basis(Position).x : fw.normalized;
            Vector3 pos;
            if (Planet.on)
            {
                var pf = Planet.Flat(Position);
                pf.y = Mathf.Max(pf.y, 0f) + 1f;
                pos = Planet.Place(pf);
            }
            else
            {
                var p = Position;
                pos = new Vector3(p.x, Mathf.Max(p.y, 0f) + 1f, p.z);
            }
            var b = new GBasis(Vector3.Cross(up, fw), up, fw);
            rb.position = G.U(pos);
            rb.rotation = G.U(b.Quat());
            transform.SetPositionAndRotation(rb.position, rb.rotation);
            rb.linearVelocity = Vector3.zero;
            rb.angularVelocity = Vector3.zero;
            _lastVel = Vector3.zero;
            _accel = Vector3.zero;
            _upsideDown = 0f;
        }
    }
}
