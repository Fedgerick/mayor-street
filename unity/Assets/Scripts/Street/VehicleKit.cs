// Port of vehicles/vehicle_kit.gd: the round-3 car kit. VehicleBaker (editor) bakes each
// vehicles/assets/*.glb into Resources/VehicleMeshes/<name> with two submeshes, body (0) and
// glass (1); specs.json is copied to Resources/Vehicles/specs. Cars face -Z (Godot space) with
// the origin on the ground under the car.
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public static class VehicleKit
    {
        public static readonly string[] MODELS =
        {
            "car_sedan", "car_hatch", "car_taxi", "car_sports", "car_pickup", "car_van",
            "car_bus", "car_police", "car_ambulance", "car_firetruck", "car_garbage", "car_truck", "car_tow",
        };
        public static readonly float[] LOD_DISTANCES = { 28f, 80f };
        public const int SIREN = 1, BRAKE = 2, EMPTY = 4, HEADLIGHTS = 8;

        static readonly Dictionary<string, Mesh> _meshes = new Dictionary<string, Mesh>();
        static Dictionary<string, object> _specs;
        static Material _body, _glass;

        public static Material[] Materials()
        {
            if (_body == null)
            {
                var bs = Resources.Load<Shader>("Shaders/MSPVehicle");
                var gs = Resources.Load<Shader>("Shaders/MSPVehicleGlass");
                _body = new Material(bs != null ? bs : Shader.Find("Universal Render Pipeline/Lit")) { name = "VehBody", enableInstancing = true };
                _glass = new Material(gs != null ? gs : Shader.Find("Universal Render Pipeline/Lit")) { name = "VehGlass", enableInstancing = true };
            }
            return new[] { _body, _glass };
        }

        static Mesh Load(string nm)
        {
            if (_meshes.TryGetValue(nm, out var m)) return m;
            m = Resources.Load<Mesh>("VehicleMeshes/" + nm);
            _meshes[nm] = m;
            return m;
        }

        public static Mesh Mesh(string model, int lod = 0) => Load(lod <= 0 ? model : $"{model}_lod{Mathf.Min(lod, 2)}");

        public static Mesh Damaged(string model, int stage) => stage <= 0 ? Mesh(model) : Load($"{model}_dmg{Mathf.Min(stage, 3)}");

        public static int LodFor(float distance) => distance < LOD_DISTANCES[0] ? 0 : (distance < LOD_DISTANCES[1] ? 1 : 2);

        public static Dictionary<string, object> Spec(string model)
        {
            if (_specs == null)
            {
                var ta = Resources.Load<TextAsset>("Vehicles/specs");
                _specs = (ta != null ? Json.Parse(ta.text) : null) as Dictionary<string, object> ?? new Dictionary<string, object>();
            }
            return _specs.TryGetValue(model, out var v) ? v as Dictionary<string, object> : null;
        }

        /// <summary>Instance custom data (flags, wheel angle, steer, seed), as msp's VehicleKit.custom().</summary>
        public static Vector4 Custom(bool siren = false, bool brake = false, bool empty = false, bool lights = false,
            float wheelAngle = 0f, float steer = 0f, float seed = 0f)
        {
            int fl = (siren ? SIREN : 0) | (brake ? BRAKE : 0) | (empty ? EMPTY : 0) | (lights ? HEADLIGHTS : 0);
            return new Vector4(fl, G.Fposmod(wheelAngle, G.TAU), steer, seed);
        }
    }
}
