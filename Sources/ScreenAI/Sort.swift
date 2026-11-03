import Foundation

// libc++'s std::sort (introsort with pdqsort-style partitioning, LLVM 17+, the path for non-trivial comparators).
// The original sorts keys that can tie in several places (equal link costs, projections, paragraph ids), where the
// order the tied elements end up in changes the output; this reproduces it.

extension Array {
    mutating func libcxxSort(by c: (Element, Element) -> Bool) {
        var n = count, log2 = 0
        while n > 1 {
            n >>= 1
            log2 += 1
        }
        withoutActuallyEscaping(c) { c in
            withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var s = LibcxxSorter(a: base, c: c)
                s.introsort(0, buf.count, 2 * log2, true)
            }
        }
    }

    /// std::push_heap: the last element joins the heap in front of it (`c` is the heap's less-than).
    mutating func libcxxPushHeap(by c: (Element, Element) -> Bool) {
        withoutActuallyEscaping(c) { c in
            withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                LibcxxSorter(a: base, c: c).siftUp(0, buf.count, buf.count)
            }
        }
    }

    /// std::pop_heap, then removes the top (the greatest under `c`) and returns it.
    mutating func libcxxPopHeap(by c: (Element, Element) -> Bool) -> Element {
        withoutActuallyEscaping(c) { c in
            withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress, buf.count > 1 else { return }
                let s = LibcxxSorter(a: base, c: c)
                let top = base[0]
                var hole = s.floydSiftDown(0, buf.count)
                let back = buf.count - 1
                if hole == back {
                    base[hole] = top
                } else {
                    base[hole] = base[back]
                    hole += 1
                    base[back] = top
                    s.siftUp(0, hole, hole)
                }
            }
        }
        return removeLast()
    }

    /// std::stable_sort.
    mutating func stableSort(by c: (Element, Element) -> Bool) {
        let order = indices.sorted { i, j in c(self[i], self[j]) || (!c(self[j], self[i]) && i < j) }
        self = order.map { self[$0] }
    }
}

private struct LibcxxSorter<T> {
    let a: UnsafeMutablePointer<T>
    let c: (T, T) -> Bool

    @inline(__always) func less(_ i: Int, _ j: Int) -> Bool { c(a[i], a[j]) }
    @inline(__always) func swapAt(_ i: Int, _ j: Int) {
        let t = a[i]
        a[i] = a[j]
        a[j] = t
    }

    @discardableResult
    func sort3(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        if !less(y, x) {
            if !less(z, y) { return false }
            swapAt(y, z)
            if less(y, x) { swapAt(x, y) }
            return true
        }
        if less(z, y) {
            swapAt(x, z)
            return true
        }
        swapAt(x, y)
        if less(z, y) { swapAt(y, z) }
        return true
    }

    func sort4(_ x1: Int, _ x2: Int, _ x3: Int, _ x4: Int) {
        sort3(x1, x2, x3)
        if less(x4, x3) {
            swapAt(x3, x4)
            if less(x3, x2) {
                swapAt(x2, x3)
                if less(x2, x1) { swapAt(x1, x2) }
            }
        }
    }

    func sort5(_ x1: Int, _ x2: Int, _ x3: Int, _ x4: Int, _ x5: Int) {
        sort4(x1, x2, x3, x4)
        if less(x5, x4) {
            swapAt(x4, x5)
            if less(x4, x3) {
                swapAt(x3, x4)
                if less(x3, x2) {
                    swapAt(x2, x3)
                    if less(x2, x1) { swapAt(x1, x2) }
                }
            }
        }
    }

    func insertionSort(_ first: Int, _ last: Int, guarded: Bool) {
        if first == last { return }
        var i = first + 1
        while i != last {
            var j = i - 1
            if less(i, j) {
                let t = a[i]
                var k = j
                j = i
                repeat {
                    a[j] = a[k]
                    j = k
                    if guarded && j == first { break }
                    k -= 1
                } while c(t, a[k])
                a[j] = t
            }
            i += 1
        }
    }

    func insertionSortIncomplete(_ first: Int, _ last: Int) -> Bool {
        switch last - first {
        case 0, 1: return true
        case 2:
            if less(last - 1, first) { swapAt(first, last - 1) }
            return true
        case 3:
            sort3(first, first + 1, last - 1)
            return true
        case 4:
            sort4(first, first + 1, first + 2, last - 1)
            return true
        case 5:
            sort5(first, first + 1, first + 2, first + 3, last - 1)
            return true
        default: break
        }
        var j = first + 2
        sort3(first, first + 1, j)
        let limit = 8
        var count = 0
        var i = j + 1
        while i != last {
            if less(i, j) {
                let t = a[i]
                var k = j
                j = i
                repeat {
                    a[j] = a[k]
                    j = k
                    if j == first { break }
                    k -= 1
                } while c(t, a[k])
                a[j] = t
                count += 1
                if count == limit {
                    i += 1
                    return i == last
                }
            }
            j = i
            i += 1
        }
        return true
    }

    func partitionWithEqualsOnRight(_ begin: Int, _ end: Int) -> (Int, Bool) {
        var first = begin, last = end
        let pivot = a[first]
        repeat { first += 1 } while c(a[first], pivot)
        if begin == first - 1 {
            while first < last {
                last -= 1
                if c(a[last], pivot) { break }
            }
        } else {
            repeat { last -= 1 } while !c(a[last], pivot)
        }
        let alreadyPartitioned = first >= last
        while first < last {
            swapAt(first, last)
            repeat { first += 1 } while c(a[first], pivot)
            repeat { last -= 1 } while !c(a[last], pivot)
        }
        let pivotPos = first - 1
        if begin != pivotPos { a[begin] = a[pivotPos] }
        a[pivotPos] = pivot
        return (pivotPos, alreadyPartitioned)
    }

    func partitionWithEqualsOnLeft(_ begin: Int, _ end: Int) -> Int {
        var first = begin, last = end
        let pivot = a[first]
        if c(pivot, a[last - 1]) {
            repeat { first += 1 } while !c(pivot, a[first])
        } else {
            first += 1
            while first < last && !c(pivot, a[first]) { first += 1 }
        }
        if first < last {
            repeat { last -= 1 } while c(pivot, a[last])
        }
        while first < last {
            swapAt(first, last)
            repeat { first += 1 } while !c(pivot, a[first])
            repeat { last -= 1 } while c(pivot, a[last])
        }
        let pivotPos = first - 1
        if begin != pivotPos { a[begin] = a[pivotPos] }
        a[pivotPos] = pivot
        return first
    }

    func siftDown(_ first: Int, _ len: Int, _ start0: Int) {
        var start = start0
        var child = start - first
        if len < 2 || (len - 2) / 2 < child { return }
        child = 2 * child + 1
        var ci = first + child
        if child + 1 < len && less(ci, ci + 1) {
            ci += 1
            child += 1
        }
        if less(ci, start) { return }
        let top = a[start]
        repeat {
            a[start] = a[ci]
            start = ci
            if (len - 2) / 2 < child { break }
            child = 2 * child + 1
            ci = first + child
            if child + 1 < len && less(ci, ci + 1) {
                ci += 1
                child += 1
            }
        } while !c(a[ci], top)
        a[start] = top
    }

    func floydSiftDown(_ first: Int, _ len: Int) -> Int {
        var hole = first, ci = first
        var child = 0
        while true {
            ci += child + 1
            child = 2 * child + 1
            if child + 1 < len && less(ci, ci + 1) {
                ci += 1
                child += 1
            }
            a[hole] = a[ci]
            hole = ci
            if child > (len - 2) / 2 { return hole }
        }
    }

    func siftUp(_ first: Int, _ last0: Int, _ len0: Int) {
        var last = last0, len = len0
        if len > 1 {
            len = (len - 2) / 2
            var ptr = first + len
            last -= 1
            if less(ptr, last) {
                let t = a[last]
                repeat {
                    a[last] = a[ptr]
                    last = ptr
                    if len == 0 { break }
                    len = (len - 1) / 2
                    ptr = first + len
                } while c(a[ptr], t)
                a[last] = t
            }
        }
    }

    func heapSort(_ first: Int, _ last0: Int) {
        var last = last0
        let n = last - first
        if n == 0 { return }
        if n > 1 {
            for start in stride(from: (n - 2) / 2, through: 0, by: -1) { siftDown(first, n, first + start) }
        }
        var m = n
        while m > 1 {
            let top = a[first]
            var hole = floydSiftDown(first, m)
            let back = last - 1
            if hole == back {
                a[hole] = top
            } else {
                a[hole] = a[back]
                hole += 1
                a[back] = top
                siftUp(first, hole, hole - first)
            }
            last -= 1
            m -= 1
        }
    }

    mutating func introsort(_ first0: Int, _ last0: Int, _ depth0: Int, _ leftmost0: Bool) {
        var first = first0, last = last0, depth = depth0, leftmost = leftmost0
        let limit = 24, nintherThreshold = 128
        while true {
            let len = last - first
            switch len {
            case 0, 1: return
            case 2:
                if less(last - 1, first) { swapAt(first, last - 1) }
                return
            case 3:
                sort3(first, first + 1, last - 1)
                return
            case 4:
                sort4(first, first + 1, first + 2, last - 1)
                return
            case 5:
                sort5(first, first + 1, first + 2, first + 3, last - 1)
                return
            default: break
            }
            if len < limit {
                insertionSort(first, last, guarded: leftmost)
                return
            }
            if depth == 0 {
                heapSort(first, last)
                return
            }
            depth -= 1
            let half = len / 2
            if len > nintherThreshold {
                sort3(first, first + half, last - 1)
                sort3(first + 1, first + (half - 1), last - 2)
                sort3(first + 2, first + (half + 1), last - 3)
                sort3(first + (half - 1), first + half, first + (half + 1))
                swapAt(first, first + half)
            } else {
                sort3(first + half, first, last - 1)
            }
            if !leftmost && !less(first - 1, first) {
                first = partitionWithEqualsOnLeft(first, last)
                continue
            }
            var (i, alreadyPartitioned) = partitionWithEqualsOnRight(first, last)
            if alreadyPartitioned {
                let fs = insertionSortIncomplete(first, i)
                if insertionSortIncomplete(i + 1, last) {
                    if fs { return }
                    last = i
                    continue
                }
                if fs {
                    i += 1
                    first = i
                    continue
                }
            }
            introsort(first, i, depth, leftmost)
            leftmost = false
            i += 1
            first = i
        }
    }
}
