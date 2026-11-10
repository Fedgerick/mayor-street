// GDScript's hash() for the values msp hashes (Variant::recursive_hash: murmur3 with Godot's
// seed, then fmix32), so scattered trees, bushes and palms land where msp puts them.
namespace MSP
{
    public static class GodotHash
    {
        const uint SEED = 0x7F07C65;

        static uint Rotl(uint x, int r) => (x << r) | (x >> (32 - r));

        static uint One(uint k, uint h)
        {
            unchecked
            {
                k *= 0xcc9e2d51; k = Rotl(k, 15); k *= 0x1b873593;
                h ^= k; h = Rotl(h, 13); return h * 5 + 0xe6546b64;
            }
        }

        static uint Fmix(uint h)
        {
            unchecked
            {
                h ^= h >> 16; h *= 0x85ebca6b; h ^= h >> 13; h *= 0xc2b2ae35; h ^= h >> 16; return h;
            }
        }

        /// <summary>hash(Vector3i(x, y, z))</summary>
        public static uint Vector3i(int x, int y, int z) => Fmix(One((uint)z, One((uint)y, One((uint)x, SEED))));
    }
}
