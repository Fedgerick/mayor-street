// An id -> value map that iterates in insertion order and keeps that order across removals,
// as Godot's Dictionary does. City relies on it so its simulation runs the same as msp's.
using System.Collections;
using System.Collections.Generic;

namespace MSP
{
    public class OrderedMap<TKey, TValue> : IEnumerable<KeyValuePair<TKey, TValue>>
    {
        readonly Dictionary<TKey, LinkedListNode<KeyValuePair<TKey, TValue>>> _map = new Dictionary<TKey, LinkedListNode<KeyValuePair<TKey, TValue>>>();
        readonly LinkedList<KeyValuePair<TKey, TValue>> _list = new LinkedList<KeyValuePair<TKey, TValue>>();

        public int Count => _map.Count;
        public bool ContainsKey(TKey k) => _map.ContainsKey(k);

        public bool TryGetValue(TKey k, out TValue v)
        {
            if (_map.TryGetValue(k, out var n)) { v = n.Value.Value; return true; }
            v = default;
            return false;
        }

        /// <summary>Set replaces in place (keeps the position); a new key goes at the end.</summary>
        public TValue this[TKey k]
        {
            get => _map[k].Value.Value;
            set
            {
                if (_map.TryGetValue(k, out var n)) n.Value = new KeyValuePair<TKey, TValue>(k, value);
                else _map[k] = _list.AddLast(new KeyValuePair<TKey, TValue>(k, value));
            }
        }

        public bool Remove(TKey k)
        {
            if (!_map.TryGetValue(k, out var n)) return false;
            _list.Remove(n);
            _map.Remove(k);
            return true;
        }

        public void Clear() { _map.Clear(); _list.Clear(); }

        /// <summary>A snapshot of the values, safe to iterate while the map changes.</summary>
        public List<TValue> Values()
        {
            var o = new List<TValue>(_list.Count);
            foreach (var kv in _list) o.Add(kv.Value);
            return o;
        }

        public List<TKey> Keys()
        {
            var o = new List<TKey>(_list.Count);
            foreach (var kv in _list) o.Add(kv.Key);
            return o;
        }

        /// <summary>Live iteration (don't change the map meanwhile).</summary>
        public IEnumerable<TValue> Each()
        {
            foreach (var kv in _list) yield return kv.Value;
        }

        public IEnumerator<KeyValuePair<TKey, TValue>> GetEnumerator() => _list.GetEnumerator();
        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    }
}
