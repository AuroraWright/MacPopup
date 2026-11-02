import Foundation

// MSVC STL algorithms, step for step. oneocr's comparators aren't always strict weak orderings and its
// containers are iterated in hash order, so results depend on exactly how MSVC's std::sort, nth_element,
// partial_sort, heaps and unordered_map work.
enum MSVC {
    private static let isortMax = 32

    static func sort<T>(_ a: inout [T], _ less: (T, T) -> Bool) {
        sortRange(&a, 0, a.count, a.count, less)
    }

    static func partialSort<T>(_ a: inout [T], _ mid0: Int, _ less: (T, T) -> Bool) {
        let last = a.count
        let mid = min(mid0, last)
        makeHeap(&a, 0, mid, less)
        var next = mid
        while next < last {
            if less(a[next], a[0]) {
                let val = a[next]
                a[next] = a[0]
                popHeapHole(&a, 0, 0, mid, val, less)
            }
            next += 1
        }
        sortHeap(&a, 0, mid, less)
    }

    static func makeHeap<T>(_ a: inout [T], _ less: (T, T) -> Bool) { makeHeap(&a, 0, a.count, less) }

    /// std::push_heap after appending.
    static func pushHeap<T>(_ a: inout [T], _ less: (T, T) -> Bool) {
        let n = a.count
        if n >= 2 { pushHeapHole(&a, 0, n - 1, 0, a[n - 1], less) }
    }

    /// std::pop_heap: the top moves to the end (the caller removes it).
    static func popHeap<T>(_ a: inout [T], _ less: (T, T) -> Bool) {
        let n = a.count
        if n >= 2 {
            let val = a[n - 1]
            a[n - 1] = a[0]
            popHeapHole(&a, 0, 0, n - 1, val, less)
        }
    }

    static func nthElement<T>(_ a: inout [T], _ nth: Int, _ less: (T, T) -> Bool) {
        var first = 0, last = a.count
        if nth >= last { return }
        while isortMax < last - first {
            let (midFirst, midLast) = partitionByMedianGuess(&a, first, last, less)
            if midLast <= nth {
                first = midLast
            } else if midFirst <= nth {
                return
            } else {
                last = midFirst
            }
        }
        insertionSort(&a, first, last, less)
    }

    private static func sortRange<T>(_ a: inout [T], _ first0: Int, _ last0: Int, _ ideal0: Int, _ less: (T, T) -> Bool) {
        var first = first0, last = last0, ideal = ideal0
        while true {
            if last - first <= isortMax {
                insertionSort(&a, first, last, less)
                return
            }
            if ideal <= 0 {
                makeHeap(&a, first, last, less)
                sortHeap(&a, first, last, less)
                return
            }
            let (midFirst, midLast) = partitionByMedianGuess(&a, first, last, less)
            ideal = (ideal >> 1) + (ideal >> 2)
            if midFirst - first < last - midLast {
                sortRange(&a, first, midFirst, ideal, less)
                first = midLast
            } else {
                sortRange(&a, midLast, last, ideal, less)
                last = midFirst
            }
        }
    }

    private static func pushHeapHole<T>(_ a: inout [T], _ first: Int, _ hole0: Int, _ top: Int, _ val: T,
                                        _ less: (T, T) -> Bool) {
        var hole = hole0
        var idx = (hole - 1) >> 1
        while top < hole && less(a[first + idx], val) {
            a[first + hole] = a[first + idx]
            hole = idx
            idx = (hole - 1) >> 1
        }
        a[first + hole] = val
    }

    private static func popHeapHole<T>(_ a: inout [T], _ first: Int, _ hole0: Int, _ bottom: Int, _ val: T,
                                       _ less: (T, T) -> Bool) {
        let top = hole0
        var hole = hole0, idx = hole0
        let maxNonLeaf = (bottom - 1) >> 1
        while idx < maxNonLeaf {
            idx = 2 * idx + 2
            if less(a[first + idx], a[first + idx - 1]) { idx -= 1 }
            a[first + hole] = a[first + idx]
            hole = idx
        }
        if idx == maxNonLeaf && bottom % 2 == 0 {
            a[first + hole] = a[first + bottom - 1]
            hole = bottom - 1
        }
        pushHeapHole(&a, first, hole, top, val, less)
    }

    private static func makeHeap<T>(_ a: inout [T], _ first: Int, _ last: Int, _ less: (T, T) -> Bool) {
        let bottom = last - first
        var hole = bottom >> 1
        while hole > 0 {
            hole -= 1
            popHeapHole(&a, first, hole, bottom, a[first + hole], less)
        }
    }

    private static func sortHeap<T>(_ a: inout [T], _ first: Int, _ last0: Int, _ less: (T, T) -> Bool) {
        var last = last0
        while last - first >= 2 {
            last -= 1
            let val = a[last]
            a[last] = a[first]
            popHeapHole(&a, first, 0, last - first, val, less)
        }
    }

    private static func insertionSort<T>(_ a: inout [T], _ first: Int, _ last: Int, _ less: (T, T) -> Bool) {
        if last - first < 2 { return }
        for mid in (first + 1)..<last {
            let val = a[mid]
            if less(val, a[first]) {
                var k = mid
                while k > first {
                    a[k] = a[k - 1]
                    k -= 1
                }
                a[first] = val
            } else {
                var hole = mid
                while less(val, a[hole - 1]) {
                    a[hole] = a[hole - 1]
                    hole -= 1
                }
                a[hole] = val
            }
        }
    }

    private static func med3<T>(_ a: inout [T], _ f: Int, _ m: Int, _ l: Int, _ less: (T, T) -> Bool) {
        if less(a[m], a[f]) { a.swapAt(m, f) }
        if less(a[l], a[m]) {
            a.swapAt(l, m)
            if less(a[m], a[f]) { a.swapAt(m, f) }
        }
    }

    private static func guessMedian<T>(_ a: inout [T], _ f: Int, _ m: Int, _ l: Int, _ less: (T, T) -> Bool) {
        let count = l - f
        if count > 40 {
            let step = (count + 1) >> 3
            let two = step << 1
            med3(&a, f, f + step, f + two, less)
            med3(&a, m - step, m, m + step, less)
            med3(&a, l - two, l - step, l, less)
            med3(&a, f + step, m, l - step, less)
        } else {
            med3(&a, f, m, l, less)
        }
    }

    private static func partitionByMedianGuess<T>(_ a: inout [T], _ first: Int, _ last: Int,
                                                  _ less: (T, T) -> Bool) -> (Int, Int) {
        let mid = first + ((last - first) >> 1)
        guessMedian(&a, first, mid, last - 1, less)
        var pf = mid, pl = mid + 1
        while first < pf && !less(a[pf - 1], a[pf]) && !less(a[pf], a[pf - 1]) { pf -= 1 }
        while pl < last && !less(a[pl], a[pf]) && !less(a[pf], a[pl]) { pl += 1 }
        var gf = pl, gl = pf
        while true {
            while gf < last {
                if less(a[pf], a[gf]) {
                } else if less(a[gf], a[pf]) {
                    break
                } else {
                    if pl != gf { a.swapAt(pl, gf) }
                    pl += 1
                }
                gf += 1
            }
            while first < gl {
                if less(a[gl - 1], a[pf]) {
                } else if less(a[pf], a[gl - 1]) {
                    break
                } else {
                    pf -= 1
                    if pf != gl - 1 { a.swapAt(pf, gl - 1) }
                }
                gl -= 1
            }
            if gl == first && gf == last { return (pf, pl) }
            if gl == first {
                if pl != gf { a.swapAt(pf, pl) }
                pl += 1
                a.swapAt(pf, gf)
                pf += 1
                gf += 1
            } else if gf == last {
                gl -= 1
                pf -= 1
                if gl != pf { a.swapAt(gl, pf) }
                pl -= 1
                a.swapAt(pf, pl)
            } else {
                gl -= 1
                a.swapAt(gf, gl)
                gf += 1
            }
        }
    }

    /// std::hash: 64-bit FNV-1a.
    static func fnv1a<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return h
    }

    static func hash(_ k: Int32) -> UInt64 {
        withUnsafeBytes(of: k.littleEndian) { fnv1a($0) }
    }

    static func hash(_ s: String) -> UInt64 { fnv1a(s.utf8) }
}

/// std::unordered_map's iteration order as MSVC lays it out: one list holding every bucket as a contiguous run.
/// A new key goes to the end of the list if its bucket is empty, else in front of the bucket's first node; a rehash
/// walks the old list and moves each node in front of its new bucket's run. Buckets start at 8 and grow 8× while
/// below 512. Only insertion and update are modelled.
struct MsvcUnorderedMap<Key: Hashable, Value> {
    private let hashOf: (Key) -> UInt64
    private var vals: [Key: Value] = [:]
    private var hashes: [Key: UInt64] = [:]
    private(set) var keys: [Key] = []
    private var buckets = 8
    private var lo: [Int: Key] = [:]

    init(hash: @escaping (Key) -> UInt64) { hashOf = hash }

    var count: Int { vals.count }

    subscript(_ k: Key) -> Value? {
        get { vals[k] }
        set {
            guard let v = newValue else { return }
            if vals[k] == nil { insert(k) }
            vals[k] = v
        }
    }

    var items: [(Key, Value)] { keys.map { ($0, vals[$0]!) } }

    private mutating func insert(_ k: Key) {
        let h = hashOf(k)
        hashes[k] = h
        let n = vals.count
        if Float(1) < Float(n + 1) / Float(buckets) {
            var want = max(8, Int(Float(n + 1).rounded(.up)))
            if buckets < want {
                if buckets < 512 && want <= 8 * buckets { want = 8 * buckets }
            } else {
                want = buckets
            }
            rehash(want)
        }
        let b = Int(h & UInt64(buckets - 1))
        if let first = lo[b] {
            keys.insert(k, at: keys.firstIndex(of: first)!)
        } else {
            keys.append(k)
        }
        lo[b] = k
    }

    private mutating func rehash(_ want: Int) {
        let v = max(0, (want - 1) | 1)
        let nb = 1 << (Int.bitWidth - v.leadingZeroBitCount)
        buckets = nb
        var out: [Key] = []
        var newLo: [Int: Key] = [:]
        for k in keys {
            let b = Int(hashes[k]! & UInt64(nb - 1))
            if let first = newLo[b] {
                out.insert(k, at: out.firstIndex(of: first)!)
            } else {
                out.append(k)
            }
            newLo[b] = k
        }
        keys = out
        lo = newLo
    }
}
