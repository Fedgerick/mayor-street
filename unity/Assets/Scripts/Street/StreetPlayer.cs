// Port of player/scripts/street_player.gd: the on-foot character: camera-relative walk and
// sprint, jump with coyote time and input buffering, curb step-up, fall damage, health, armor and
// regeneration, and a third-person boom (OrbitRig). On msp the body stands on the ball: its basis
// is the local frame under it, and movement runs in that frame (y = away from the centre).
// Godot space throughout; KinematicMover stands in for CharacterBody3D.move_and_slide.
using System;
using UnityEngine;

namespace MSP
{
    public class StreetPlayer : MonoBehaviour
    {
        public event Action InteractRequested;
        public event Action<float, Vector3> Damaged;
        public event Action Died;

        public float walkSpeed = 3.6f, sprintSpeed = 7.2f;
        public float groundAccel = 14f, airAccel = 3f, turnSpeed = 12f;
        public float jumpVelocity = 4f;
        public float stepHeight = 0.32f;
        public int lookSeed = 7;

        public const float MAX_HEALTH = 100f, MAX_ARMOR = 100f, ARMOR_SHARE = 0.66f;
        public const float REGEN_TO = 40f, REGEN_RATE = 1f, REGEN_DELAY = 8f;
        public const float FALL_SAFE = 12f, FALL_DAMAGE = 7f;
        public const float COYOTE = 0.12f, JUMP_BUFFER = 0.14f;

        public bool controlsEnabled, inVehicle, puppet, dead, aiming;
        public float aimYaw;
        public float health = MAX_HEALTH, armor;
        public float healRate = 1f;
        public OrbitRig rig;
        public CharacterModel visual;
        public KinematicMover body;
        public CapsuleCollider shape;

        public Vector3 Position { get => body.position; set => body.position = value; }
        public Vector3 Velocity { get => body.velocity; set => body.velocity = value; }

        float _gravity = 9.8f;
        float _sinceHurt, _sinceFloor, _jumpBuffer, _facing, _turnRate, _airTime, _stepSink;
        int _stepFrames;

        public void Init()
        {
            gameObject.layer = Layers.PLAYER;
            body = new KinematicMover { floorSnapLength = 0.35f, floorMaxAngle = 50f * Mathf.Deg2Rad, safeMargin = 0.02f };
            var rb = gameObject.AddComponent<Rigidbody>();
            rb.isKinematic = true;
            rb.interpolation = RigidbodyInterpolation.None;
            shape = gameObject.AddComponent<CapsuleCollider>();
            shape.radius = 0.3f;
            shape.height = 1.76f;
            shape.center = new Vector3(0f, 0.88f, 0f);
            body.ignore.Add(shape);
            visual = new CharacterModel(transform.parent, lookSeed);
            rig = new OrbitRig { target = () => body.position, height = 1.55f, distance = 3.6f };
            rig.Exclude(shape);
        }

        public void SetControls(bool on)
        {
            controlsEnabled = on;
            rig.inputEnabled = on && !inVehicle && !puppet;
        }

        public void Place(Vector3 pos, float faceYaw)
        {
            body.position = pos;
            body.up = Planet.Up(pos);
            body.velocity = Vector3.zero;
            _facing = faceYaw;
            visual.yaw = faceYaw;
            rig.yaw = faceYaw;
            rig.Snap();
            SyncTransform();
        }

        /// <summary>Visible, no physics, no input: StreetMode moves the character into or out of a car.</summary>
        public void SetPuppet(bool on)
        {
            puppet = on;
            visual.visible = true;
            shape.enabled = !on;
            rig.inputEnabled = controlsEnabled && !on;
            body.velocity = Vector3.zero;
            if (on) visual.Animate(0.016f, 0f, true, 0f, 0f);
        }

        public void Face(float yaw)
        {
            _facing = yaw;
            visual.yaw = yaw;
        }

        public void SetInVehicle(bool on)
        {
            inVehicle = on;
            puppet = false;
            visual.visible = !on;
            shape.enabled = !on;
            rig.inputEnabled = controlsEnabled && !on;
            body.velocity = Vector3.zero;
            visual.Pose();
        }

        public float FacingYaw() => _facing;

        void Update()
        {
            float delta = Mathf.Min(Time.deltaTime, 0.05f);
            if (controlsEnabled && !inVehicle && !puppet && StreetInput.InteractPressed) InteractRequested?.Invoke();
            if (!inVehicle && !puppet) Step(delta);
            else if (puppet) { SyncTransform(); visual.body = new GXform(Planet.Basis(body.position), body.position); visual.Pose(); }
            rig.Update(delta);
        }

        void Step(float delta)
        {
            _sinceHurt += delta;
            if (!dead && health < REGEN_TO * healRate && _sinceHurt > REGEN_DELAY / healRate)
                health = Mathf.Min(health + REGEN_RATE * healRate * delta, REGEN_TO * healRate);
            // Everything below runs in the local frame; on the flat island that is the world.
            var q = Planet.Basis(body.position);
            body.up = q.y;
            var qi = q.Inverse();
            Vector3 lv = qi * body.velocity;
            Vector2 input = controlsEnabled ? StreetInput.MoveVector() : Vector2.zero;
            Vector3 wish = qi * (rig.RightFlat() * input.x + rig.ForwardFlat() * input.y);
            bool sprinting = controlsEnabled && StreetInput.Sprint && !aiming;
            float targetSpeed = (sprinting ? sprintSpeed : walkSpeed * (aiming ? 0.75f : 1f)) * Mathf.Min(input.magnitude, 1f);

            if (body.onFloor)
            {
                _sinceFloor = 0f;
                _stepFrames = 0;
            }
            else if (_stepFrames > 0)
            {
                _stepFrames--;      // crossing the edge of a step: level, no gravity yet
                lv.y = 0f;
            }
            else
            {
                _sinceFloor += delta;
                lv.y -= _gravity * delta * (lv.y < 0f ? 1.6f : 1f);
            }
            body.floorSnapLength = _stepFrames > 0 ? 0f : 0.35f;

            if (controlsEnabled && StreetInput.JumpPressed) _jumpBuffer = JUMP_BUFFER;
            else _jumpBuffer = Mathf.Max(_jumpBuffer - delta, 0f);
            if (_jumpBuffer > 0f && _sinceFloor < COYOTE)
            {
                lv.y = jumpVelocity;
                _jumpBuffer = 0f;
                _sinceFloor = COYOTE;
            }

            var hv = new Vector3(lv.x, 0f, lv.z);
            Vector3 goal = wish.magnitude > 0.01f ? wish.normalized * targetSpeed : Vector3.zero;
            float accel = body.onFloor ? groundAccel : airAccel;
            hv = Vector3.Lerp(hv, goal, 1f - Mathf.Exp(-accel * delta));
            lv.x = hv.x;
            lv.z = hv.z;
            body.velocity = q * lv;

            bool wasFloor = body.onFloor;
            Vector3 before = body.position;
            float falling = -lv.y;
            body.MoveAndSlide(delta);
            if (!wasFloor && body.onFloor && falling > FALL_SAFE && !dead) Hurt((falling - FALL_SAFE) * FALL_DAMAGE, body.position);
            if ((wasFloor || _stepFrames > 0) && goal != Vector3.zero && body.onWall)
                if (TryStep(before, q * goal * delta)) body.velocity = q * goal;  // keep walking: the wall was only the step's face
            lv = qi * body.velocity;

            // Face the direction of travel.
            float prev = _facing;
            if (aiming) _facing = G.LerpAngle(_facing, aimYaw, 1f - Mathf.Exp(-24f * delta));
            else if (hv.magnitude > 0.4f) _facing = G.LerpAngle(_facing, Mathf.Atan2(-hv.x, -hv.z), 1f - Mathf.Exp(-turnSpeed * delta));
            _turnRate = Mathf.Lerp(_turnRate, G.AngleDiff(prev, _facing) / Mathf.Max(delta, 1e-4f), 0.2f);
            visual.yaw = _facing;
            _stepSink = G.MoveToward(_stepSink, 0f, delta * 2.5f);
            visual.sink = _stepSink;
            // A real drop ends in a landing (knees give) unless we land running.
            if (body.onFloor)
            {
                if (_airTime > 0.45f && hv.magnitude < 3f) visual.PlayLand();
                _airTime = 0f;
            }
            else _airTime += delta;
            SyncTransform();
            visual.body = new GXform(Planet.Basis(body.position), body.position);
            visual.Animate(delta, hv.magnitude, body.onFloor, lv.y, _turnRate);
        }

        /// <summary>Climb a curb or stair: probe up, over the edge, and down; if there's flat ground up
        /// there, lift onto it and let the next move carry the player forward.</summary>
        bool TryStep(Vector3 from, Vector3 motion)
        {
            Vector3 up = Planet.Up(from);
            Vector3 dir = (motion - up * Vector3.Dot(motion, up)).normalized;
            float reach = Mathf.Max(motion.magnitude, 0.34f);
            Vector3 p = from;
            if (body.TestMotion(p, up * stepHeight, out _, out _)) return false;
            p += up * stepHeight;
            if (body.TestMotion(p, dir * reach, out _, out _)) return false;
            p += dir * reach;
            if (!body.TestMotion(p, -up * stepHeight, out var hit, out var travel)) return false;
            if (Vector3.Dot(hit.normal, up) < 0.7f) return false;
            float rise = Vector3.Dot(p + travel - from, up);
            if (rise <= 0.02f) return false;
            body.position = from + up * (rise + 0.01f) + dir * motion.magnitude;
            _stepFrames = 12;
            _stepSink = Mathf.Min(_stepSink + rise, stepHeight);
            return true;
        }

        public void SyncTransform()
        {
            transform.position = G.U(body.position);
            transform.rotation = G.U(Planet.Basis(body.position).Quat());
        }

        /// <summary>Take damage; armor soaks most of it first. Returns true if this hit killed.</summary>
        public bool Hurt(float amount, Vector3 from = default)
        {
            if (dead || amount <= 0f) return false;
            float soak = Mathf.Min(armor, amount * ARMOR_SHARE);
            armor -= soak;
            health = Mathf.Max(health - (amount - soak), 0f);
            _sinceHurt = 0f;
            Damaged?.Invoke(amount, from);
            if (health <= 0f)
            {
                dead = true;
                visual.SetDead(true);
                Died?.Invoke();
                return true;
            }
            if (amount >= 8f) visual.PlayHit();
            return false;
        }

        public bool Heal(float amount)
        {
            if (health >= MAX_HEALTH) return false;
            health = Mathf.Min(health + amount, MAX_HEALTH);
            return true;
        }

        public void Revive()
        {
            dead = false;
            health = MAX_HEALTH;
            visual.SetDead(false);
        }
    }
}
