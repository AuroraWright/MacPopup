#!/usr/bin/env python3
"""Converts oneocr's models (the OCR of the Windows Snipping Tool) for MacPopup's "OneOCR" engine.

The models are Microsoft's and can't be redistributed, so they are converted on your machine and packed into a zip
that MacPopup loads (Settings > OCR Mode > OneOCR models > Load).

The input is the folder of decrypted models: config.json next to the Model_Edge folder (for example the output of
the oneocr_native project's `python -m oneocr_native.extract_models`). This script doesn't decrypt anything.

Needs Python 3.10-3.13 with coremltools, onnx and numpy:
    python3 -m venv ~/oneocr-venv
    ~/oneocr-venv/bin/pip install coremltools onnx numpy
    ~/oneocr-venv/bin/python scripts/convert-oneocr.py <models folder> [-o OneOCR-CoreML.zip]

What it writes:
  coreml/Detector.mlpackage      the int8 text detector, run exactly: uint8 codes are carried as floats and every
                                 convolution is integer-valued, so Core ML gives ONNX Runtime's results bit for bit.
                                 Its input is the quantized image (detector.json has the quantization).
  coreml/AuxMltCls.mlpackage,    the script / handwriting / orientation classifier and the CJK line layout
  coreml/LineLayout_CJK.mlpackage  classifier (float models).
  coreml/Character_<name>.mlpackage  each recognizer's convolutional part, up to its "convfeat" features.
  tail/<name>.json + .bin        each recognizer's two quantized bidirectional LSTMs and output layer, which
                                 MacPopup computes on the CPU the way ONNX Runtime does (dynamic quantization).
  scores/{conf,rej}/<name>.json  the word confidence and line rejection models (small MLPs).
  config.json and the other files under Model_Edge (character tables, calibration maps), under their paths.
"""

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from fractions import Fraction
from pathlib import Path

try:
    import numpy as np
    import onnx
    from onnx import numpy_helper
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import Function, Program, types
except ImportError as e:
    sys.exit(f"{e.name} is missing. Install the requirements first:\n"
             "    pip install coremltools onnx numpy")

f32 = np.float32


def attrs(n):
    out = {}
    for a in n.attribute:
        if a.type == onnx.AttributeProto.GRAPH:
            out[a.name] = a.g
        else:
            v = onnx.helper.get_attribute_value(a)
            out[a.name] = v.decode() if isinstance(v, bytes) else v
    return out


def rne(v):
    """Round half to even, spelled out: Core ML's GPU rounds ties away from zero once `round` is fused with the ops
    around it. floor(v + 0.5) is exact for the values requantized here (|v| < 2^22)."""
    f = mb.floor(x=mb.add(x=v, y=f32(0.5)))
    tie = mb.equal(x=mb.sub(x=f, y=v), y=f32(0.5))
    odd = mb.equal(x=mb.mod(x=mb.abs(x=f), y=f32(2.0)), y=f32(1.0))
    return mb.select(cond=mb.logical_and(x=tie, y=odd), a=mb.sub(x=f, y=f32(1.0)), b=f)


# -- MLAS logistic, for the QLinearSigmoid tables ------------------------------------------------------------------

def _round_f32(x: Fraction) -> np.float32:
    """x rounded to the nearest float32 (ties to even), without double rounding."""
    d = float(x)                     # correctly rounded to double
    r = f32(d)
    if np.isfinite(r) and Fraction(float(r)) != x:
        # double rounding can only go wrong when d is exactly halfway between two float32s
        lo, hi = (np.nextafter(r, f32(-np.inf)), r) if Fraction(float(r)) > x else (r, np.nextafter(r, f32(np.inf)))
        mid = (Fraction(float(lo)) + Fraction(float(hi))) / 2
        if x < mid:
            r = lo
        elif x > mid:
            r = hi
        else:
            r = lo if int(lo.view(np.uint32)) % 2 == 0 else hi
    return f32(r)


def _fma(a, b, c) -> np.float32:
    return _round_f32(Fraction(float(a)) * Fraction(float(b)) + Fraction(float(c)))


_LA = [f32(v) for v in (4.37031012579801e-11, 1.15627324459942e-07, 6.08574864600143e-05, 8.51377133304701e-03,
                        2.48287947061529e-01)]
_LB = [f32(v) for v in (6.10247389755681e-13, 5.76102136993427e-09, 6.29106785017040e-06, 1.70198817374094e-03,
                        1.16817656904453e-01, 9.93151921023180e-01)]


def mlas_logistic(x: np.float32) -> np.float32:
    """MlasComputeLogistic (logistic.cpp) as its NEON path computes it, with fused multiply-adds."""
    v = min(max(f32(x), f32(-18)), f32(18))
    v2 = f32(v * v)
    p = _fma(v2, _LA[0], _LA[1])
    for c in _LA[2:]:
        p = _fma(p, v2, c)
    p = f32(p * v)
    q = _fma(v2, _LB[0], _LB[1])
    for c in _LB[2:]:
        q = _fma(q, v2, c)
    return min(max(f32(f32(p / q) + f32(0.5)), f32(0)), f32(1))


def sigmoid_table(xs, xz, ys, yz):
    """ONNX Runtime's QLinearSigmoid lookup table: dequantize every code, MLAS logistic, quantize again."""
    out = np.zeros(256, np.float32)
    for code in range(256):
        y = mlas_logistic(f32(f32(code - xz) * f32(xs)))
        q = np.rint(min(max(f32(y / f32(ys)), f32(-yz)), f32(255 - yz))) + yz
        out[code] = min(max(q, 0), 255)
    return out


# -- ONNX to Core ML -----------------------------------------------------------------------------------------------

class Converter:
    """Rebuilds an ONNX graph with coremltools' MIL builder. `exact`: quantized ops carry uint8 codes as floats and
    repeat ONNX Runtime's integer arithmetic."""

    def __init__(self, model, exact=False):
        self.g = model.graph
        self.exact = exact
        self.inits = {t.name: numpy_helper.to_array(t) for t in self.g.initializer}
        self.env = {}
        self.shape_of = {}  # name of a Shape output -> the var whose shape it is

    def val(self, name):
        if name in self.env:
            return self.env[name]
        if name in self.inits:
            return self.inits[name]
        raise KeyError(name)

    def var(self, name):
        v = self.val(name)
        if isinstance(v, np.ndarray):
            v = mb.const(val=v.astype(np.float32) if v.dtype in (np.float64, np.float32) else v)
        return v

    def const(self, name):
        v = self.val(name)
        assert isinstance(v, np.ndarray), name
        return v

    @staticmethod
    def conv_args(a, w):
        k = list(w.shape[2:])
        pads = a.get("pads", [0] * (2 * len(k)))
        # ONNX pads [h_begin, w_begin, h_end, w_end] -> MIL [top, bottom, left, right]
        return dict(strides=a.get("strides", [1, 1]), dilations=a.get("dilations", [1, 1]), groups=a.get("group", 1),
                    pad_type="custom", pad=[pads[0], pads[2], pads[1], pads[3]])

    def node(self, n):
        a = attrs(n)
        op = n.op_type
        I = list(n.input)
        if op == "Conv":
            w = self.const(I[1]).astype(np.float32)
            kw = dict(x=self.var(I[0]), weight=w, **self.conv_args(a, w))
            if len(I) > 2 and I[2]:
                kw["bias"] = self.const(I[2]).astype(np.float32)
            return [mb.conv(**kw)]
        if op == "Relu":
            return [mb.relu(x=self.var(I[0]))]
        if op == "MaxPool":
            k = a["kernel_shape"]
            pads = a.get("pads", [0] * 4)
            assert a.get("ceil_mode", 0) == 0
            x = self.var(I[0])
            if any(pads):
                # MaxPool pads with -inf; every value here is above the pad value used
                x = mb.pad(x=x, pad=[0, 0, 0, 0, pads[0], pads[2], pads[1], pads[3]], mode="constant",
                           constant_val=f32(-3.0e38))
            return [mb.max_pool(x=x, kernel_sizes=k, strides=a.get("strides", k), pad_type="valid")]
        if op == "Transpose":
            return [mb.transpose(x=self.var(I[0]), perm=a["perm"])]
        if op == "Reshape":
            shape = [int(d) for d in self.const(I[1])]
            x = self.var(I[0])
            if 0 in shape:  # ONNX 0 = copy the input dimension
                s = mb.shape(x=x)
                parts = [mb.slice_by_index(x=s, begin=[i], end=[i + 1]) if d == 0 else np.array([d], np.int32)
                         for i, d in enumerate(shape)]
                return [mb.reshape(x=x, shape=mb.concat(values=parts, axis=0))]
            return [mb.reshape(x=x, shape=shape)]
        if op == "Constant":
            return [numpy_helper.to_array(a["value"]) if "value" in a else np.array(a["value_float"], np.float32)]
        if op == "Identity":
            return [self.var(I[0])]
        if op == "Add":
            return [mb.add(x=self.var(I[0]), y=self.var(I[1]))]
        if op == "Sub":
            return [mb.sub(x=self.var(I[0]), y=self.var(I[1]))]
        if op == "Div":
            return [mb.real_div(x=self.var(I[0]), y=self.var(I[1]))]
        if op == "MatMul":
            return [mb.matmul(x=self.var(I[0]), y=self.var(I[1]))]
        if op == "ReduceMean":
            return [mb.reduce_mean(x=self.var(I[0]), axes=a["axes"], keep_dims=bool(a.get("keepdims", 1)))]
        if op == "Shape":
            self.shape_of[n.output[0]] = I[0]
            return [None]
        if op == "Expand":
            ref = self.shape_of[I[1]]  # Expand(x, Shape(ref)): broadcast x to ref's shape
            return [mb.add(x=self.var(I[0]), y=mb.fill_like(ref_tensor=self.var(ref), value=0.0))]
        if op == "Concat":
            return [mb.concat(values=[self.var(i) for i in I], axis=a["axis"])]
        if op == "Split":
            sizes = [int(s) for s in self.const(I[1])]
            return list(mb.split(x=self.var(I[0]), split_sizes=sizes, axis=a["axis"]))
        if op == "Resize":
            assert a["mode"] == "nearest" and a["coordinate_transformation_mode"] == "asymmetric"
            scales = self.const(I[2])
            assert scales[0] == scales[1] == 1 and scales[2] == scales[3] and scales[2] == int(scales[2])
            s = int(scales[2])
            return [mb.upsample_nearest_neighbor(x=self.var(I[0]), scale_factor_height=s, scale_factor_width=s)]
        if op == "If":
            cond = self.const(I[0])
            branch = a["then_branch"] if bool(cond.reshape(-1)[0]) else a["else_branch"]
            for bn in branch.node:
                for o, y in zip(bn.output, self.node(bn)):
                    self.env[o] = y
            return [self.var(o.name) for o in branch.output]
        # -- quantized ops (the detector) ----------------------------------------------------------------------
        assert self.exact, op
        if op == "QuantizeLinear":
            s, zp = float(self.const(I[1])), int(self.const(I[2]))
            q = rne(mb.real_div(x=self.var(I[0]), y=f32(s)))
            return [mb.clip(x=mb.add(x=q, y=f32(zp)), alpha=f32(0), beta=f32(255))]
        if op == "DequantizeLinear":
            s, zp = self.const(I[1]).astype(np.float32), int(self.const(I[2]))
            return [mb.mul(x=mb.sub(x=self.var(I[0]), y=f32(zp)), y=s)]
        if op == "QLinearConv":
            return [self.qlinear_conv(n, a)]
        if op == "QLinearAdd":
            xa, sa, za, xb, sb, zb, sc, zc = I
            sa, sb, sc = (f32(self.const(s)) for s in (sa, sb, sc))
            za, zb, zc = (int(self.const(z)) for z in (za, zb, zc))
            ra, rb = f32(sa / sc), f32(sb / sc)
            y = mb.add(x=mb.mul(x=mb.sub(x=self.var(xa), y=f32(za)), y=ra),
                       y=mb.mul(x=mb.sub(x=self.var(xb), y=f32(zb)), y=rb))
            return [mb.clip(x=mb.add(x=rne(y), y=f32(zc)), alpha=f32(0), beta=f32(255))]
        if op == "QLinearSigmoid":
            xs, xz, ys, yz = (self.const(i) for i in I[1:5])
            table = sigmoid_table(f32(xs), int(xz), f32(ys), int(yz))
            return [mb.gather(x=table, indices=mb.cast(x=self.var(I[0]), dtype="int32"), axis=0)]
        raise NotImplementedError(op)

    def qlinear_conv(self, n, a):
        x, xs, xz, w, ws, wz, ys, yz = n.input[:8]
        B = n.input[8] if len(n.input) > 8 and n.input[8] else None
        wq = self.const(w).astype(np.float32)
        xs, xz = f32(self.const(xs)), int(self.const(xz))
        ws = self.const(ws).astype(np.float32).reshape(-1)
        wz = self.const(wz).astype(np.float32).reshape(-1)
        ys, yz = f32(self.const(ys)), int(self.const(yz))
        if ws.size == 1:
            ws = np.repeat(ws, wq.shape[0])
        if wz.size == 1:
            wz = np.repeat(wz, wq.shape[0])
        wi = wq - wz[:, None, None, None]  # integer-valued weights
        acc = mb.conv(x=mb.sub(x=self.var(x), y=f32(xz)), weight=wi, **self.conv_args(a, wq))
        if B is not None:
            acc = mb.add(x=acc, y=self.const(B).astype(np.float32).reshape(1, -1, 1, 1))
        scale = ((xs * ws) / ys).astype(np.float32)  # ONNX Runtime: X_scale * W_scale / Y_scale
        y = mb.mul(x=acc, y=scale.reshape(1, -1, 1, 1))
        y = mb.clip(x=y, alpha=f32(0 - yz), beta=f32(255 - yz))
        return mb.add(x=rne(y), y=f32(yz))

    def input_quantization(self):
        """The detector's Sub -> Div -> QuantizeLinear on its input: (mean, std, scale, zero point, output, skipped)."""
        nodes = {o: n for n in self.g.node for o in n.output}
        q = next(n for n in self.g.node if n.op_type == "QuantizeLinear")
        div = nodes[q.input[0]]
        sub = nodes[div.input[0]]
        assert div.op_type == "Div" and sub.op_type == "Sub" and sub.input[0] == "data"
        return (self.inits[sub.input[1]], self.inits[div.input[1]], float(self.inits[q.input[1]]),
                int(self.inits[q.input[2]]), q.output[0], {sub.output[0], div.output[0], q.output[0]})

    def program(self, input_shapes, outputs, codes_input=False):
        """codes_input: the detector takes its quantized input codes ("data_q", computed by the caller) instead of
        the image, as Core ML's GPU divides inexactly."""
        specs = {name: mb.placeholder(shape=shape, dtype=types.fp32) for name, shape in input_shapes.items()}
        skip = set()
        # only the nodes the outputs depend on (a recognizer stops at its convolutional features)
        producer = {o: n for n in self.g.node for o in n.output}
        needed, todo = set(), list(outputs)
        while todo:
            n = producer.get(todo.pop())
            if n is not None and id(n) not in needed:
                needed.add(id(n))
                todo.extend(n.input)
        with Function(specs, opset_version=ct.target.macOS14) as fn:
            if codes_input:
                *_, qname, skip = self.input_quantization()
                self.env[qname] = fn.inputs["data_q"]
            for name in input_shapes:
                self.env[name] = fn.inputs[name]
            for n in self.g.node:
                if n.output[0] in skip or id(n) not in needed:
                    continue
                for o, y in zip(n.output, self.node(n)):
                    if o:
                        self.env[o] = y
            fn.set_outputs([mb.identity(x=self.var(o), name=o) for o in outputs])
        prog = Program()
        prog.add_function("main", fn)
        return prog


# Passes that would turn the exact detector's integer arithmetic into something else: folding the requantization
# scale or the bias into the convolution weights, and replacing divisions with multiplications by reciprocals.
EXACT_UNSAFE_PASSES = ["common::fuse_conv_scale", "common::fuse_conv_bias", "common::fuse_conv_batchnorm",
                       "common::fuse_elementwise_to_batchnorm", "common::divide_to_multiply"]


def save(prog, inputs, path, exact=False):
    pipeline = ct.PassPipeline.DEFAULT
    if exact:
        pipeline.remove_passes(EXACT_UNSAFE_PASSES)
    ml = ct.convert(prog, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                    compute_precision=ct.precision.FLOAT32, inputs=inputs, pass_pipeline=pipeline)
    ml.save(str(path))


def convert_detector(models, cfg, out):
    m = onnx.load(models / cfg["det_model"][0]["model_pack"]["onnx"]["model_path"])
    conv = Converter(m, exact=True)
    # feature_p2 feeds the relation network, which oneocr doesn't enable
    outputs = [o.name for o in m.graph.output if o.name != "feature_p2"]
    h, w = ct.RangeDim(32, 4096, default=768), ct.RangeDim(32, 4096, default=1152)
    prog = conv.program({"data_q": (1, 3, h.symbol, w.symbol)}, outputs, codes_input=True)
    save(prog, [ct.TensorType(name="data_q", shape=(1, 3, h, w))], out / "coreml" / "Detector.mlpackage", exact=True)
    mean, std, scale, zp, *_ = conv.input_quantization()
    (out / "detector.json").write_text(json.dumps({
        "mean": [float(v) for v in np.asarray(mean, np.float32).reshape(-1)],
        "std": [float(v) for v in np.asarray(std, np.float32).reshape(-1)],
        "scale": float(f32(scale)), "zero_point": zp}, indent=1))


def convert_classifier(models, path, name, out):
    m = onnx.load(models / path)
    w = ct.RangeDim(16, 16384, default=512)
    prog = Converter(m).program({"data": (1, 3, 60, w.symbol)}, [o.name for o in m.graph.output])
    save(prog, [ct.TensorType(name="data", shape=(1, 3, 60, w))], out / "coreml" / f"{name}.mlpackage")


def convert_recognizer(models, entry, out):
    """The CNN up to convfeat goes to Core ML; the LSTMs and the output layer are exported for the CPU."""
    m = onnx.load(models / entry["model_pack"]["onnx"]["model_path"])
    name = entry["name"]
    nodes = {o: n for n in m.graph.node for o in n.output}
    assert "convfeat" in nodes, f"{name}: no convfeat tensor"
    w = ct.RangeDim(16, 16384, default=512)
    prog = Converter(m).program({"data": (1, 3, 60, w.symbol)}, ["convfeat"])
    save(prog, [ct.TensorType(name="data", shape=(1, 3, 60, w))], out / "coreml" / f"Character_{name}.mlpackage")

    I = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}
    lstms = [n for n in m.graph.node if n.op_type == "DynamicQuantizeLSTM"]
    qn = next(n for n in m.graph.node if n.op_type == "QuantizeLinear")
    mm = next(n for n in m.graph.node if n.op_type == "MatMulIntegerToFloat")
    assert len(lstms) == 2 and all(attrs(n).get("direction") == "bidirectional" for n in lstms), name
    blob = bytearray()
    manifest = {"layers": []}

    def put(arr, dtype):
        a = np.ascontiguousarray(np.asarray(arr).astype(dtype))
        while len(blob) % 16:
            blob.append(0)
        entry = {"offset": len(blob), "count": int(a.size), "shape": list(a.shape)}
        blob.extend(a.tobytes())
        return entry

    for n in lstms:
        a = attrs(n)
        H = int(a["hidden_size"])
        W, R, B = I[n.input[1]], I[n.input[2]], I[n.input[3]]
        ws, wz, rs, rz = (I[k] for k in n.input[8:12])
        assert W.dtype == np.int8 and R.dtype == np.int8, name
        assert not np.any(wz) and not np.any(rz), f"{name}: LSTM weight zero points aren't 0"
        assert W.shape[0] == 2 and W.shape[2] == 4 * H and R.shape == (2, H, 4 * H) and B.shape == (2, 8 * H), name
        manifest["layers"].append({
            "hidden": H, "input": int(W.shape[1]),
            "W": put(W, np.int8), "R": put(R, np.int8), "B": put(B, np.float32),
            "w_scale": put(np.asarray(ws, np.float32).reshape(2, 4 * H), np.float32),
            "r_scale": put(np.asarray(rs, np.float32).reshape(2, 4 * H), np.float32)})
    A, Bq, sa, sb, za, zb, bias = mm.input
    assert A == qn.output[0], name
    s, z = f32(I[qn.input[1]]), int(I[qn.input[2]])
    assert int(I[za]) == z and not np.any(I[zb]), f"{name}: unexpected output layer zero points"
    Bw = I[Bq]
    assert Bw.dtype == np.int8, name
    manifest["linear"] = {
        "scale": float(s), "zero_point": z, "a_scale": float(f32(I[sa])),
        "B": put(Bw, np.int8), "b_scale": put(np.asarray(I[sb], np.float32).reshape(-1), np.float32),
        "bias": put(np.asarray(I[bias], np.float32).reshape(-1), np.float32),
        "classes": int(Bw.shape[1])}
    # what follows the output layer: LogSoftmax over the classes
    assert any(n.op_type == "LogSoftmax" for n in m.graph.node), name
    (out / "tail").mkdir(exist_ok=True)
    (out / "tail" / f"{name}.bin").write_bytes(bytes(blob))
    (out / "tail" / f"{name}.json").write_text(json.dumps(manifest, indent=1))


def floats(a):
    return [float(v) for v in np.asarray(a, np.float32).reshape(-1)]


def export_score_model(models, entry, kind, out):
    """The confidence / rejection MLPs: (x + mean) / std, Gemm + ReLU layers, softmax, and for the confidence models
    a piecewise linear calibration of softmax[1] between the two nearest points of a 51-point grid."""
    m = onnx.load(models / entry["model_pack"]["onnx"]["model_path"])
    I = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}
    consts = {n.output[0]: numpy_helper.to_array(n.attribute[0].t) for n in m.graph.node if n.op_type == "Constant"}
    val = lambda k: I[k] if k in I else consts[k]
    ops = [n.op_type for n in m.graph.node]
    add = next(n for n in m.graph.node if n.op_type == "Add")
    div = next(n for n in m.graph.node if n.op_type == "Div")
    for n in m.graph.node:
        if n.op_type == "Slice":   # the rejection models slice the features to 21
            starts, ends = val(n.input[1]), val(n.input[2])
            assert int(starts[0]) == 0 and int(ends[0]) >= 21, entry["name"]
    layers = []
    for n in m.graph.node:
        if n.op_type == "Gemm":
            a = attrs(n)
            assert a.get("transB") == 1 and a.get("alpha", 1.0) == 1.0 and a.get("beta", 1.0) == 1.0
            layers.append({"weight": [floats(r) for r in val(n.input[1])], "bias": floats(val(n.input[2]))})
    assert ops.count("Relu") == len(layers) - 1 and "Softmax" in ops, entry["name"]
    model = {"mean": floats(val(add.input[1])), "std": floats(val(div.input[1])), "layers": layers}
    if "TopK" in ops:
        # calibration: grid (Sub's constant), table (Gather's constant), the two nearest grid points (TopK k=2)
        topk = [n for n in m.graph.node if n.op_type == "TopK"]
        assert [int(val(n.input[1])[0]) for n in topk] == [2, 1, 1, 1, 1], entry["name"]
        sub = next(n for n in m.graph.node if n.op_type == "Sub" and n.input[0] in consts and consts[n.input[0]].size == 51)
        grid = consts[sub.input[0]]
        # the table is gathered at the two nearest points (TopK's indices); the grid itself is gathered too
        gather = next(n for n in m.graph.node if n.op_type == "Gather" and n.input[1] == topk[0].output[1])
        model["calibration"] = {"grid": floats(grid), "table": floats(consts[gather.input[0]])}
    (out / "scores" / kind).mkdir(parents=True, exist_ok=True)
    (out / "scores" / kind / f"{entry['name']}.json").write_text(json.dumps(model))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("models", help="the folder of decrypted models (config.json and Model_Edge)")
    ap.add_argument("-o", "--output", default="OneOCR-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    models = Path(a.models).expanduser().resolve()
    if not (models / "config.json").is_file() or not (models / "Model_Edge").is_dir():
        sys.exit(f"{models} doesn't have config.json and Model_Edge")
    cfg = json.loads((models / "config.json").read_text("utf-8"))
    output = Path(a.output).expanduser().resolve()
    print(f"Converting the models in {models}")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "coreml").mkdir()
        print("Text detector", flush=True)
        convert_detector(models, cfg, root)
        print("Classifiers", flush=True)
        convert_classifier(models, cfg["aux_mlt_cls_model"][0]["model_pack"]["onnx"]["model_path"], "AuxMltCls", root)
        for e in cfg["line_layout_cls_model"]:
            convert_classifier(models, e["model_pack"]["onnx"]["model_path"], f"LineLayout_{e['name']}", root)
        for e in cfg["char_model"]:
            print(f"Recognizer {e['name']}", flush=True)
            convert_recognizer(models, e, root)
        for kind in ("conf", "rej"):
            for e in cfg.get(f"{kind}_model", []):
                export_score_model(models, e, kind, root)
        # The character tables and calibration maps, under their original paths.
        for path in sorted((models / "Model_Edge").rglob("*")):
            if path.is_file() and path.suffix != ".onnx" and not path.name.startswith("."):
                dst = root / path.relative_to(models)
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dst)
        shutil.copyfile(models / "config.json", root / "config.json")
        (root / "oneocr.json").write_text(json.dumps({"format": 1}, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > OCR Mode > OneOCR models > Load, and pick this file.")


if __name__ == "__main__":
    main()
