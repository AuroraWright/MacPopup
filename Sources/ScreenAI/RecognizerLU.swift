import Foundation

// Eigen's PartialPivLU<MatrixXf> as the vendored Eigen computes it on arm64 (NEON with fused multiply-add), operation
// for operation: ApplyThinPlateSplineWarp solves its spline system with it, and the warp is sensitive enough that the
// last bit of the coefficients shows in the recognizer's confidences. Checked bit for bit against the C++ on random
// spline systems: exact on all of them up to n = 207 (curves of up to 100 points). Larger products split their rows
// and columns into cache-sized blocks, which isn't modelled here, so those can be an ulp off now and then.

/// Eigen's partial_lu_impl::unblocked_lu on the panel of rows r0..<n, columns c0..<c0+w (w <= n - r0): pivots by the
/// first largest magnitude, swaps rows within the panel, divides the column, rank-1 updates the panel (unfused).
/// Returns the pivot rows.
private func unblockedLU(_ a: inout [Float], _ n: Int, _ r0: Int, _ c0: Int, _ w: Int) -> [Int] {
    let rows = n - r0
    let size = min(rows, w)
    let endk = rows == w ? size - 1 : size
    var piv = [Int](repeating: 0, count: size)
    for k in 0..<size { piv[k] = r0 + k }
    for k in 0..<max(endk, 0) {
        let col = c0 + k, row = r0 + k
        var best = row
        var bestScore = abs(a[col * n + row])
        for i in (row + 1)..<n where abs(a[col * n + i]) > bestScore {
            bestScore = abs(a[col * n + i])
            best = i
        }
        piv[k] = best
        if bestScore != 0 {
            if best != row { for j in c0..<(c0 + w) { a.swapAt(j * n + row, j * n + best) } }
            let pivot = a[col * n + row]
            for i in (row + 1)..<n { a[col * n + i] = a[col * n + i] / pivot }
        }
        if row + 1 < n {
            for j in (col + 1)..<(c0 + w) {
                let u = a[j * n + row]
                for i in (row + 1)..<n { a[j * n + i] = a[j * n + i] - u * a[col * n + i] }
            }
        }
    }
    return piv
}

/// One element of Eigen's gebp kernel: the product of a row of the left block and a column of the right block over
/// `depth`, accumulated with fused multiply-adds in the order the kernel's register block for that element uses.
@inline(__always) private func gebpDot(_ lhs: (Int) -> Float, _ rhs: (Int) -> Float, _ depth: Int, _ mode: Int) -> Float {
    switch mode {
    case 1:  // 1pX4 and half-packet X4: even k and odd k in two accumulators (depth peeled by 8)
        let peeled = depth & ~7
        var c: Float = 0, d: Float = 0
        var k = 0
        while k < peeled {
            c = c.addingProduct(lhs(k), rhs(k))
            d = d.addingProduct(lhs(k + 1), rhs(k + 1))
            k += 2
        }
        c = c + d
        while k < depth {
            c = c.addingProduct(lhs(k), rhs(k))
            k += 1
        }
        return c
    case 2:  // single row X 4 columns (swapped traits): accumulators by k mod 4, then (c0 + c1) + (c2 + c3)
        var c = [Float](repeating: 0, count: 4)
        let end4 = depth / 4 * 4
        var k = 0
        while k < end4 {
            for q in 0..<4 { c[q] = c[q].addingProduct(lhs(k + q), rhs(k + q)) }
            k += 4
        }
        var s = (c[0] + c[1]) + (c[2] + c[3])
        while k < depth {
            s = s.addingProduct(lhs(k), rhs(k))
            k += 1
        }
        return s
    default:
        var c: Float = 0
        for k in 0..<depth { c = c.addingProduct(lhs(k), rhs(k)) }
        return c
    }
}

/// res(rows x cols) -= lhs(rows x depth) * rhs(depth x cols) as Eigen's gebp kernel computes it (float NEON: mr = 12,
/// nr = 8; row blocks of 12, 8, 4, 2, then single rows; column blocks of 8, 4, then single columns).
private func gebpSub(_ rows: Int, _ cols: Int, _ depth: Int, _ lhs: (Int, Int) -> Float, _ rhs: (Int, Int) -> Float,
             _ res: (Int, Int, Float) -> Void) {
    let mc3 = rows / 12 * 12
    let mc2 = mc3 + (rows - mc3) / 8 * 8
    let mc1 = mc2 + (rows - mc2) / 4 * 4
    let mcHalf = mc1 + (rows - mc1) / 2 * 2
    let cols8 = cols / 8 * 8, cols4 = cols / 4 * 4
    for i in 0..<rows {
        for j in 0..<cols {
            var mode = 0
            if j >= cols8 && j < cols4 {
                if i >= mc2 && i < mcHalf { mode = 1 } else if i >= mcHalf { mode = 2 }
            }
            res(i, j, gebpDot({ lhs(i, $0) }, { rhs($0, j) }, depth, mode))
        }
    }
}

/// Eigen's redux of `count` rounded products (DefaultTraversal): in order below 16 terms, else eight interleaved
/// accumulators (the tail joining the first) summed as a tree.
private func dotRedux(_ count: Int, _ term: (Int) -> Float) -> Float {
    if count < 16 {
        var s = term(0)
        for q in 1..<count { s = s + term(q) }
        return s
    }
    var acc = (0..<8).map(term)
    let end = count - count % 8
    var q = 8
    while q < end {
        for l in 0..<8 { acc[l] = acc[l] + term(q + l) }
        q += 8
    }
    while q < count { acc[0] = acc[0] + term(q); q += 1 }
    return ((acc[0] + acc[1]) + (acc[2] + acc[3])) + ((acc[4] + acc[5]) + (acc[6] + acc[7]))
}

/// Eigen's PartialPivLU<MatrixXf> decomposition (partial_lu_impl::blocked_lu) of the n x n column-major matrix in
/// place; returns the row transpositions.
private func luDecompose(_ a: inout [Float], _ n: Int) -> [Int] {
    if n <= 16 { return unblockedLU(&a, n, 0, 0, n) }
    let blockSize = min(max(n / 8 / 16 * 16, 8), 256)
    var trans = [Int](repeating: 0, count: n)
    var k = 0
    while k < n {
        let bs = min(n - k, blockSize)
        let tsize = n - k - bs
        let piv = unblockedLU(&a, n, k, k, bs)
        for i in 0..<bs { trans[k + i] = piv[i] }
        // apply the panel's transpositions to the columns left and right of it
        for j in Array(0..<k) + Array((k + bs)..<n) {
            for i in k..<(k + bs) where trans[i] != i { a.swapAt(j * n + i, j * n + trans[i]) }
        }
        if tsize > 0 {
            // A12 = A11^-1 A12 (unit lower): packet kernel (fused) on whole groups of 4 columns, scalar on the rest
            let packetCols = tsize >= 4 ? tsize / 4 * 4 : 0
            for jj in 0..<tsize {
                let j = k + bs + jj
                if tsize < 4 {
                    // too few columns for the packet kernel: diagonal panels of 12, gebp below each
                    var k1 = 0
                    while k1 < bs {
                        let w = min(bs - k1, 12)
                        for c in k1..<(k1 + w) {
                            let y = a[j * n + k + c]
                            for r in (c + 1)..<(k1 + w) { a[j * n + k + r] = a[j * n + k + r] - y * a[(k + c) * n + k + r] }
                        }
                        for r in (k1 + w)..<bs {
                            var acc: Float = 0
                            for c in k1..<(k1 + w) { acc = acc.addingProduct(a[(k + c) * n + k + r], a[j * n + k + c]) }
                            a[j * n + k + r] = a[j * n + k + r] - acc
                        }
                        k1 += w
                    }
                    continue
                }
                for r in 1..<bs {
                    for c in 0..<r {
                        let l = a[(k + c) * n + k + r], y = a[j * n + k + c]
                        if jj < packetCols {
                            a[j * n + k + r] = a[j * n + k + r].addingProduct(-l, y)
                        } else {
                            a[j * n + k + r] = a[j * n + k + r] - y * l
                        }
                    }
                }
            }
            // A22 -= A21 * A12
            let r0 = k + bs
            if bs + tsize + tsize < 20 {
                // coefficient-based product, slice-vectorized: packets of 4 rows (fused chain over the depth), the
                // rows past them one dot product each (rounded products summed in order)
                let packetRows = tsize / 4 * 4
                for jj in 0..<tsize {
                    for ii in 0..<tsize {
                        var acc: Float
                        if ii < packetRows {
                            acc = 0
                            for q in 0..<bs { acc = acc.addingProduct(a[(k + q) * n + r0 + ii], a[(r0 + jj) * n + k + q]) }
                        } else {
                            acc = dotRedux(bs) { a[(k + $0) * n + r0 + ii] * a[(r0 + jj) * n + k + $0] }
                        }
                        a[(r0 + jj) * n + r0 + ii] = a[(r0 + jj) * n + r0 + ii] - acc
                    }
                }
            } else {
                var snapshot = a
                gebpSub(tsize, tsize, bs, { i, q in snapshot[(k + q) * n + r0 + i] },
                        { q, j in snapshot[(r0 + j) * n + k + q] }) { i, j, v in
                    snapshot[(r0 + j) * n + r0 + i] = snapshot[(r0 + j) * n + r0 + i] - v
                }
                a = snapshot
            }
        }
        k += bs
    }
    return trans
}

/// Solves A X = B (A n x n, B n x m, both column-major) the way Eigen's PartialPivLU<MatrixXf>::solve does: the blocked
/// decomposition, then the unit-lower and upper triangular solves.
func luSolve(_ a: inout [Float], _ n: Int, _ rhs: inout [Float], _ m: Int) {
    let perm = luDecompose(&a, n)
    // dst = P rhs (the transpositions in order)
    for k in 0..<n where perm[k] != k {
        for j in 0..<m { rhs.swapAt(j * n + k, j * n + perm[k]) }
    }
    // Eigen's triangular_solve_matrix (2 right-hand sides, so no packet kernel): diagonal panels of 12 rows solved
    // one row after the other, then the rows past the panel updated by gebp (each a fused multiply-add chain over
    // the panel, then subtracted).
    let panel = 12
    for j in 0..<m {
        let o = j * n
        // unit lower, panels from the top
        var k1 = 0
        while k1 < n {
            let w = min(n - k1, panel)
            for k in k1..<(k1 + w) {
                let x = rhs[o + k]
                if k + 1 < k1 + w { for i in (k + 1)..<(k1 + w) { rhs[o + i] = rhs[o + i] - x * a[k * n + i] } }
            }
            if k1 + w < n {
                for i in (k1 + w)..<n {
                    var acc: Float = 0
                    for k in k1..<(k1 + w) { acc = acc.addingProduct(a[k * n + i], rhs[o + k]) }
                    rhs[o + i] = rhs[o + i] - acc
                }
            }
            k1 += w
        }
        // upper, panels from the bottom
        var top = n
        while top > 0 {
            let w = min(top, panel)
            let start = top - w
            for k in stride(from: top - 1, through: start, by: -1) {
                let x = rhs[o + k] * (1 / a[k * n + k])
                rhs[o + k] = x
                for i in start..<k { rhs[o + i] = rhs[o + i] - x * a[k * n + i] }
            }
            if start > 0 {
                for i in 0..<start {
                    var acc: Float = 0
                    for k in start..<top { acc = acc.addingProduct(a[k * n + i], rhs[o + k]) }
                    rhs[o + i] = rhs[o + i] - acc
                }
            }
            top = start
        }
    }
}
