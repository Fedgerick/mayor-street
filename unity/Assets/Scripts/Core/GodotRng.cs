// Godot's RandomNumberGenerator (core/math/random_pcg.h: PCG32), so a city seeded the same way
// as msp's comes out the same, lot for lot.
namespace MSP
{
    public class GodotRng
    {
        const ulong DEFAULT_INC = 1442695040888963407UL;
        public ulong state;
        ulong _inc = DEFAULT_INC;
        ulong _seed;

        public GodotRng(ulong seed = 12047754176567800795UL) { Seed = seed; }

        public ulong Seed
        {
            get => _seed;
            set
            {
                _seed = value;
                state = 0;
                _inc = (DEFAULT_INC << 1) | 1u;
                Next();
                state += value;
                Next();
            }
        }

        uint Next()
        {
            ulong old = state;
            state = unchecked(old * 6364136223846793005UL + _inc);
            uint xorshifted = (uint)(((old >> 18) ^ old) >> 27);
            int rot = (int)(old >> 59);
            return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
        }

        /// <summary>0 .. 2^32-1, as GDScript's randi().</summary>
        public long Randi() => Next();

        /// <summary>0..1, as Godot 4's randf(): two draws, one picks the exponent (by its leading
        /// zeros) and one the significand.</summary>
        public float Randf()
        {
            uint protoExpOffset = Next();
            if (protoExpOffset == 0) return 0f;
            uint significand = Next() | 0x80000001u;
            return (float)((double)(float)significand * System.Math.Pow(2.0, -32 - Clz(protoExpOffset)));
        }

        static int Clz(uint v)
        {
            int n = 0;
            if (v == 0) return 32;
            while ((v & 0x80000000u) == 0) { v <<= 1; n++; }
            return n;
        }

        public float RandfRange(float from, float to) => Randf() * (to - from) + from;

        public long RandiRange(long from, long to)
        {
            if (from == to) return from;
            if (from > to) { long t = from; from = to; to = t; }
            uint bounds = (uint)(to - from) + 1u;
            return from + Bounded(bounds);
        }

        // random_pcg.h rand(bounds): pcg32_boundedrand_r
        uint Bounded(uint bound)
        {
            uint threshold = unchecked((uint)(-(int)bound)) % bound;
            for (;;)
            {
                uint r = Next();
                if (r >= threshold) return r % bound;
            }
        }
    }
}
