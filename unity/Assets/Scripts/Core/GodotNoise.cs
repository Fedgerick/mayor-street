// Godot's FastNoiseLite resource with its defaults (simplex smooth, FBM, 5 octaves, lacunarity
// 2, gain 0.5, frequency 0.01, seed 0), on top of the same upstream library Godot ships.
namespace MSP
{
    public class GodotNoise
    {
        readonly FastNoiseLite _n = new FastNoiseLite();
        int _seed, _octaves = 5;
        float _freq = 0.01f;

        public GodotNoise()
        {
            _n.SetNoiseType(FastNoiseLite.NoiseType.OpenSimplex2S);
            _n.SetFractalType(FastNoiseLite.FractalType.FBm);
            _n.SetFractalOctaves(5);
            _n.SetFractalLacunarity(2f);
            _n.SetFractalGain(0.5f);
            _n.SetFractalWeightedStrength(0f);
            _n.SetFractalPingPongStrength(2f);
            _n.SetFrequency(0.01f);
            _n.SetSeed(0);
        }

        public int Seed { get => _seed; set { _seed = value; _n.SetSeed(value); } }
        public float Frequency { get => _freq; set { _freq = value; _n.SetFrequency(value); } }
        public int Octaves { get => _octaves; set { _octaves = value; _n.SetFractalOctaves(value); } }

        public float Get2D(float x, float y) => _n.GetNoise(x, y);
        public float Get3D(float x, float y, float z) => _n.GetNoise(x, y, z);
    }
}
