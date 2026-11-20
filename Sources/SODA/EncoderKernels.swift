import Foundation
import SODAKernels

/// The ops only the encoders use, as libsoda's TFLite computes them.
extension Context {
    /// DEPTHWISE_CONV_2D (NHWC, filter [1, H, W, C], depth multiplier 1). With int8 weights (the hybrid kernel), the
    /// input is put on an asymmetric int8 grid over each batch entry, accumulated in int32, and scaled as TFLite's
    /// optimized kernel does: (acc · channel scale) · input scale + bias.
    mutating func depthwiseConv2D(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0), w = input(op, 1)
        let o = op.options
        // DepthwiseConv2DOptions: padding, stride_w, stride_h, depth_multiplier, activation, dilation_w, dilation_h.
        let same = (o?.scalar(0, Int8(0)) ?? 0) == 0
        let strideW = Int(o?.scalar(1, Int32(1)) ?? 1), strideH = Int(o?.scalar(2, Int32(1)) ?? 1)
        let multiplier = Int(o?.scalar(3, Int32(1)) ?? 1)
        let activation = o?.scalar(4, Int8(0)) ?? 0
        let dilationW = Int(o?.scalar(5, Int32(1)) ?? 1), dilationH = Int(o?.scalar(6, Int32(1)) ?? 1)
        guard multiplier == 1, x.shape.count == 4, w.shape.count == 4 else { throw SODAError("unsupported depthwise conv") }
        let (batches, height, width, channels) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])
        let (fh, fw) = (w.shape[1], w.shape[2])
        func outSize(_ n: Int, _ f: Int, _ s: Int, _ d: Int) -> Int {
            let effective = (f - 1) * d + 1
            return same ? (n + s - 1) / s : (n - effective + s) / s
        }
        let outH = outSize(height, fh, strideH, dilationH), outW = outSize(width, fw, strideW, dilationW)
        func pad(_ n: Int, _ out: Int, _ f: Int, _ s: Int, _ d: Int) -> Int {
            same ? max(0, ((out - 1) * s + (f - 1) * d + 1 - n) / 2) : 0
        }
        let padH = pad(height, outH, fh, strideH, dilationH), padW = pad(width, outW, fw, strideW, dilationW)
        let bias = hasInput(op, 2) ? input(op, 2).floats : [Float](repeating: 0, count: channels)
        let xs = x.floats
        let plane = height * width * channels
        var out = [Float](repeating: 0, count: batches * outH * outW * channels)
        if case .int8(let weights) = w.data {
            let scales = w.quantization.scales.count == channels ? w.quantization.scales
                : [Float](repeating: w.quantization.scale, count: channels)
            var q = [Int8](repeating: 0, count: xs.count)
            var acc = [Int32](repeating: 0, count: outH * outW * channels)
            for b in 0..<batches {
                let (scale, zero) = Self.quantizeAsymmetric(xs, (b * plane)..<((b + 1) * plane), into: &q)
                soda_depthwise_s8(Array(q[(b * plane)..<((b + 1) * plane)]), zero, Int32(height), Int32(width), Int32(channels), weights, Int32(fh), Int32(fw),
                                  Int32(strideH), Int32(strideW), Int32(dilationH), Int32(dilationW), Int32(padH),
                                  Int32(padW), Int32(outH), Int32(outW), &acc)
                let base = b * outH * outW * channels
                for i in acc.indices {
                    let c = i % channels
                    out[base + i] = Float(acc[i]) * scales[c] * scale + bias[c]
                }
            }
        } else {
            // Float: the taps in order, as TFLite's reference loop.
            let weights = w.floats
            for b in 0..<batches {
                for oy in 0..<outH {
                    for ox in 0..<outW {
                        for c in 0..<channels {
                            var acc: Float = 0
                            for ky in 0..<fh {
                                let iy = oy * strideH - padH + ky * dilationH
                                if iy < 0 || iy >= height { continue }
                                for kx in 0..<fw {
                                    let ix = ox * strideW - padW + kx * dilationW
                                    if ix < 0 || ix >= width { continue }
                                    acc += xs[b * plane + (iy * width + ix) * channels + c] * weights[(ky * fw + kx) * channels + c]
                                }
                            }
                            out[((b * outH + oy) * outW + ox) * channels + c] = acc + bias[c]
                        }
                    }
                }
            }
        }
        Self.activate(&out, activation)
        set(op, 0, Tensor(out, shape: [batches, outH, outW, channels]))
    }

    /// MAX_POOL_2D and AVERAGE_POOL_2D in float (NHWC), as TFLite's optimized kernels: each input adds into every
    /// output window holding it, in input order, and an average divides by the inputs it took (padding left out).
    mutating func pool2D(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0)
        guard x.shape.count == 4, case .float(let xs) = x.data else { throw SODAError("unsupported pooling") }
        let o = op.options
        // Pool2DOptions: padding, stride_w, stride_h, filter_width, filter_height, activation.
        let same = (o?.scalar(0, Int8(0)) ?? 0) == 0
        let strideW = Int(o?.scalar(1, Int32(1)) ?? 1), strideH = Int(o?.scalar(2, Int32(1)) ?? 1)
        let fw = Int(o?.scalar(3, Int32(1)) ?? 1), fh = Int(o?.scalar(4, Int32(1)) ?? 1)
        let activation = o?.scalar(5, Int8(0)) ?? 0
        let (batches, height, width, channels) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])
        let outH = same ? (height + strideH - 1) / strideH : (height - fh + strideH) / strideH
        let outW = same ? (width + strideW - 1) / strideW : (width - fw + strideW) / strideW
        let padH = max(0, ((outH - 1) * strideH + fh - height) / 2), padW = max(0, ((outW - 1) * strideW + fw - width) / 2)
        let average = op.code == Op.averagePool2D
        var out = [Float](repeating: average ? 0 : -.greatestFiniteMagnitude, count: batches * outH * outW * channels)
        var counts = [Float](repeating: 0, count: batches * outH * outW)
        for b in 0..<batches {
            for h in 0..<height {
                for w in 0..<width {
                    let hp = h + padH, wp = w + padW
                    let hStart = hp < fh ? 0 : (hp - fh) / strideH + 1, hEnd = min(hp / strideH + 1, outH)
                    let wStart = wp < fw ? 0 : (wp - fw) / strideW + 1, wEnd = min(wp / strideW + 1, outW)
                    let from = ((b * height + h) * width + w) * channels
                    for ph in hStart..<max(hStart, hEnd) {
                        for pw in wStart..<max(wStart, wEnd) {
                            let cell = (b * outH + ph) * outW + pw, to = cell * channels
                            for c in 0..<channels {
                                out[to + c] = average ? out[to + c] + xs[from + c] : max(out[to + c], xs[from + c])
                            }
                            counts[cell] += 1
                        }
                    }
                }
            }
        }
        if average {
            for i in out.indices { out[i] /= counts[i / channels] }
        }
        Self.activate(&out, activation)
        set(op, 0, Tensor(out, shape: [batches, outH, outW, channels]))
    }

    /// BATCH_MATMUL as TFLite's reference kernel (libsoda's choice): in float, each output sums its products in order.
    mutating func batchMatMul(_ op: TFLiteModel.Operator) throws {
        let a = input(op, 0), b = input(op, 1)
        // BatchMatMulOptions: adj_x, adj_y.
        let adjX = op.options?.bool(0) ?? false, adjY = op.options?.bool(1) ?? false
        guard a.shape.count >= 2, b.shape.count >= 2 else { throw SODAError("BATCH_MATMUL rank") }
        let ar = a.shape.count, br = b.shape.count
        let rows = adjX ? a.shape[ar - 1] : a.shape[ar - 2], depth = adjX ? a.shape[ar - 2] : a.shape[ar - 1]
        let cols = adjY ? b.shape[br - 2] : b.shape[br - 1]
        let (batchShape, ia, ib) = Self.broadcast(Array(a.shape.dropLast(2)), Array(b.shape.dropLast(2)))
        let aSize = a.shape[ar - 2] * a.shape[ar - 1], bSize = b.shape[br - 2] * b.shape[br - 1]
        if case .int8(let w) = b.data {
            // Int8 weights: per batch entry, TFLite's hybrid layer with the weights as [cols, depth] rows (each input
            // row quantized on its own, the same scaling as FULLY_CONNECTED's).
            guard !adjX else { throw SODAError("hybrid BATCH_MATMUL with adj_x") }
            let asymmetric = op.options?.bool(2) ?? false
            let x = a.floats
            var out: [Float] = [], sums: [Int32] = []
            out.reserveCapacity(ia.count * rows * cols)
            for n in ia.indices {
                let bo = ib[n] * bSize
                let rowsOfW = adjY ? Array(w[bo..<bo + bSize])
                    : (0..<cols * depth).map { w[bo + ($0 % depth) * cols + $0 / depth] }
                let rowSums = (0..<cols).map { j in rowsOfW[(j * depth)..<((j + 1) * depth)].reduce(Int32(0)) { $0 + Int32($1) } }
                out += Self.hybrid(Array(x[(ia[n] * aSize)..<(ia[n] * aSize + aSize)]), batch: rows,
                                   weights: HybridWeights(values: rowsOfW, rowSums: rowSums), units: cols, columns: depth, quantization: b.quantization,
                                   bias: nil, asymmetric: asymmetric, sums: &sums)
            }
            return set(op, 0, Tensor(out, shape: batchShape + [rows, cols]))
        }
        let x = a.floats, y = b.floats
        var out = [Float](repeating: 0, count: ia.count * rows * cols)
        // Strides of i, j and k in each operand.
        let (li, lk) = adjX ? (1, rows) : (depth, 1), (rj, rk) = adjY ? (depth, 1) : (1, cols)
        var scratch = [Float](repeating: 0, count: rj == 1 ? 0 : depth * cols)
        x.withUnsafeBufferPointer { x in
            y.withUnsafeBufferPointer { y in
                out.withUnsafeMutableBufferPointer { out in
                    scratch.withUnsafeMutableBufferPointer { scratch in
                        for n in ia.indices where rows > 0 && cols > 0 {
                            soda_matmul_f32(x.baseAddress! + ia[n] * aSize, y.baseAddress! + ib[n] * bSize,
                                            out.baseAddress! + n * rows * cols, Int32(rows), Int32(cols), Int32(depth),
                                            li, lk, rj, rk, scratch.baseAddress)
                        }
                    }
                }
            }
        }
        set(op, 0, Tensor(out, shape: batchShape + [rows, cols]))
    }

    /// CUMSUM along an axis, in order.
    mutating func cumsum(_ op: TFLiteModel.Operator) throws {
        let a = input(op, 0)
        let rank = a.shape.count
        var axis = input(op, 1).ints[0]
        if axis < 0 { axis += rank }
        let exclusive = op.options?.bool(0) ?? false, reverse = op.options?.bool(1) ?? false
        let inner = a.shape[(axis + 1)...].reduce(1, *), n = a.shape[axis], outer = a.count / max(1, n * inner)
        guard case .float(let x) = a.data else { throw SODAError("CUMSUM of non-float values") }
        var out = [Float](repeating: 0, count: x.count)
        for o in 0..<outer {
            for i in 0..<inner {
                var sum: Float = 0
                for s in 0..<n {
                    let k = (o * n + (reverse ? n - 1 - s : s)) * inner + i
                    if exclusive {
                        out[k] = sum
                        sum += x[k]
                    } else {
                        sum += x[k]
                        out[k] = sum
                    }
                }
            }
        }
        set(op, 0, Tensor(out, shape: a.shape))
    }
}
