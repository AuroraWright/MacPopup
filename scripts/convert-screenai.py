#!/usr/bin/env python3
"""Converts Chrome's Screen AI OCR models to Core ML for MacPopup's "Screen AI" OCR engine.

The models are Google's and can't be redistributed, so they are converted on your machine from the copy Chrome
downloads (its "screen_ai" component) and packed into a zip that MacPopup loads (Settings > OCR Mode > Screen AI
models > Load).

Needs Python 3.10-3.12 with coremltools, ai-edge-litert, flatbuffers and numpy:
    python3 -m venv ~/screenai-venv
    ~/screenai-venv/bin/pip install coremltools ai-edge-litert flatbuffers numpy
    ~/screenai-venv/bin/python scripts/convert-screenai.py [component folder] [-o ScreenAI-CoreML.zip]

coremltools has no TFLite frontend, so this reads the .tflite flatbuffers and rebuilds each graph with coremltools'
MIL builder, in 32-bit floats. Tensors keep TFLite's NHWC layout; convolutions are wrapped in transposes, which
coremltools folds away. Every quantized tensor is rounded and clamped to its int8/uint8 grid like TFLite does, so
the results match the original closely. Inputs are raw byte values (0-255) as floats; outputs are real values
(quantized outputs: scale * (q - zero_point)).

The detector's outputs go back to NHWC as a 3-D transpose between reshapes (see flattened_nhwc): Core ML's CPU engine
reads past the end of a buffer in the 4-D transpose of a small tensor (a head's 7 channels at 1/32 scale of a 32- or
64-wide input), which crashed when that reached unmapped memory. On the GPU the results are the same.
"""

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

try:
    import numpy as np
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import Function, Program, get_new_symbol, types
    from ai_edge_litert import schema_py_generated as S
except ImportError as e:
    sys.exit(f"{e.name} is missing. Install the requirements first:\n"
             "    pip install coremltools ai-edge-litert flatbuffers numpy")

BUILTIN = {v: k for k, v in vars(S.BuiltinOperator).items() if not k.startswith("_")}
TTYPE = {v: k for k, v in vars(S.TensorType).items() if not k.startswith("_")}
NP = {"INT8": np.int8, "UINT8": np.uint8, "INT32": np.int32, "INT64": np.int64, "FLOAT32": np.float32,
      "FLOAT16": np.float16}
QRANGE = {"INT8": (-128, 127), "UINT8": (0, 255)}


class Tensor:
    def __init__(self, model, graph, index):
        t = graph.Tensors(index)
        self.index = index
        self.name = t.Name().decode()
        self.type = TTYPE[t.Type()]
        self.shape = [int(d) for d in t.ShapeAsNumpy()] if t.ShapeLength() else []
        self.signature = [int(d) for d in t.ShapeSignatureAsNumpy()] if t.ShapeSignatureLength() else self.shape
        q = t.Quantization()
        self.scale = q.ScaleAsNumpy().astype(np.float32) if q and q.ScaleLength() else None
        self.zero_point = q.ZeroPointAsNumpy().astype(np.int64) if q and q.ZeroPointLength() else None
        self.qdim = q.QuantizedDimension() if q else 0
        buf = model.Buffers(t.Buffer())
        self.data = None
        if buf is not None and buf.DataLength():
            raw = buf.DataAsNumpy().tobytes()
            self.data = (np.frombuffer(raw, dtype=NP[self.type]).reshape(self.shape) if self.type in NP else
                         np.frombuffer(raw, dtype=np.uint8))  # strings: TFLite's packed string buffer

    @property
    def quantized(self):
        return self.scale is not None and self.type in QRANGE

    def real(self):
        """A constant's real values."""
        d = self.data
        if self.scale is None or self.type in ("FLOAT32", "FLOAT16"):
            return d.astype(np.float32)
        shape = [1] * d.ndim
        if len(self.scale) > 1:
            shape[self.qdim] = -1
        s = self.scale.reshape(shape)
        zp = self.zero_point.reshape(shape) if self.zero_point is not None else 0
        return ((d.astype(np.float64) - zp) * s).astype(np.float32)


def options(op, cls):
    o = cls()
    t = op.BuiltinOptions()
    o.Init(t.Bytes, t.Pos)
    return o


def activation(x, kind):
    if kind == S.ActivationFunctionType.NONE:
        return x
    if kind == S.ActivationFunctionType.RELU:
        return mb.relu(x=x)
    if kind == S.ActivationFunctionType.RELU6:
        return mb.relu6(x=x)
    if kind == S.ActivationFunctionType.RELU_N1_TO_1:
        return mb.clip(x=x, alpha=-1.0, beta=1.0)
    raise NotImplementedError(f"fused activation {kind}")


class Converter:
    def __init__(self, path):
        buf = open(path, "rb").read()
        self.model = S.Model.GetRootAsModel(buf, 0)
        self.graph = self.model.Subgraphs(0)
        self.tensors = [Tensor(self.model, self.graph, i) for i in range(self.graph.TensorsLength())]
        self.ops = [self.graph.Operators(k) for k in range(self.graph.OperatorsLength())]
        self.producer = {}
        for k, op in enumerate(self.ops):
            for o in op.OutputsAsNumpy():
                self.producer[int(o)] = k
        self.inputs = [int(i) for i in self.graph.InputsAsNumpy()]
        self.outputs = [int(o) for o in self.graph.OutputsAsNumpy()]
        # Signature names (e.g. decode_logits) when the model has them.
        self.output_names = {o: self.tensors[o].name for o in self.outputs}
        self.input_names = {i: self.tensors[i].name for i in self.inputs}
        if self.model.SignatureDefsLength():
            sig = self.model.SignatureDefs(0)
            for i in range(sig.OutputsLength()):
                self.output_names[sig.Outputs(i).TensorIndex()] = sig.Outputs(i).Name().decode()
            for i in range(sig.InputsLength()):
                self.input_names[sig.Inputs(i).TensorIndex()] = sig.Inputs(i).Name().decode()

    def code(self, op):
        oc = self.model.OperatorCodes(op.OpcodeIndex())
        return BUILTIN[max(oc.BuiltinCode(), oc.DeprecatedBuiltinCode())]

    def needed_ops(self, outputs):
        need, stack = set(), list(outputs)
        while stack:
            t = stack.pop()
            k = self.producer.get(t)
            if k is None or k in need:
                continue
            need.add(k)
            stack.extend(int(i) for i in self.ops[k].InputsAsNumpy() if i >= 0)
        return sorted(need)

    def inputs_of(self, outputs):
        ins = set()
        for k in self.needed_ops(outputs):
            ins |= {int(i) for i in self.ops[k].InputsAsNumpy() if i in self.inputs}
        return [i for i in self.inputs if i in ins]

    # -- values -------------------------------------------------------------------------------------------------

    def value(self, i):
        if i not in self.env:
            t = self.tensors[i]
            if t.data is None:
                raise KeyError(f"tensor {i} {t.name} has no value")
            self.env[i] = mb.const(val=t.real())
        return self.env[i]

    def const(self, i):
        t = self.tensors[i]
        assert t.data is not None, t.name
        return t.data

    def quantize(self, x, t):
        """Puts x on t's quantization grid, as TFLite rounds and clamps it."""
        if not t.quantized:
            return x
        assert len(t.scale) == 1, t.name
        s, zp = float(t.scale[0]), int(t.zero_point[0])
        lo, hi = QRANGE[t.type]
        q = mb.round(x=mb.real_div(x=x, y=np.float32(s)))
        q = mb.clip(x=q, alpha=np.float32(lo - zp), beta=np.float32(hi - zp))
        return mb.mul(x=q, y=np.float32(s))

    # -- ops ----------------------------------------------------------------------------------------------------

    def conv(self, op, depthwise):
        ins = [int(i) for i in op.InputsAsNumpy()]
        x, w = self.value(ins[0]), self.tensors[ins[1]].real()
        bias = self.tensors[ins[2]].real() if len(ins) > 2 and ins[2] >= 0 else None
        if depthwise:
            o = options(op, S.DepthwiseConv2DOptions)
            cin = self.tensors[ins[0]].shape[3]
            weight = np.transpose(w, (3, 0, 1, 2))  # [1,H,W,C*M] -> [C*M,1,H,W]
            groups = cin
        else:
            o = options(op, S.Conv2DOptions)
            weight = np.transpose(w, (0, 3, 1, 2))  # [O,H,W,I] -> [O,I,H,W]
            groups = 1
        pad = "same" if o.Padding() == S.Padding.SAME else "valid"
        y = mb.transpose(x=x, perm=[0, 3, 1, 2])
        kw = dict(x=y, weight=weight, strides=[o.StrideH(), o.StrideW()], pad_type=pad,
                  dilations=[o.DilationHFactor(), o.DilationWFactor()], groups=groups)
        if bias is not None:
            kw["bias"] = bias
        y = mb.conv(**kw)
        y = mb.transpose(x=y, perm=[0, 2, 3, 1])
        return activation(y, o.FusedActivationFunction())

    def binary(self, op, fn, opts_cls):
        a, b = (int(i) for i in op.InputsAsNumpy())
        y = fn(x=self.value(a), y=self.value(b))
        return activation(y, options(op, opts_cls).FusedActivationFunction()) if op.BuiltinOptions() else y

    def convert_op(self, op):
        code = self.code(op)
        ins = [int(i) for i in op.InputsAsNumpy()]
        outs = [int(o) for o in op.OutputsAsNumpy()]
        if code == "CONV_2D":
            ys = [self.conv(op, False)]
        elif code == "DEPTHWISE_CONV_2D":
            ys = [self.conv(op, True)]
        elif code == "ADD":
            ys = [self.binary(op, mb.add, S.AddOptions)]
        elif code == "SUB":
            ys = [self.binary(op, mb.sub, S.SubOptions)]
        elif code == "MUL":
            ys = [self.binary(op, mb.mul, S.MulOptions)]
        elif code in ("QUANTIZE", "DEQUANTIZE", "CAST"):
            ys = [self.value(ins[0])]
        elif code == "HARD_SWISH":
            x = self.value(ins[0])
            ys = [mb.mul(x=x, y=mb.sigmoid_hard(x=x, alpha=1.0 / 6, beta=0.5))]
        elif code == "LOGISTIC":
            ys = [mb.sigmoid(x=self.value(ins[0]))]
        elif code == "MEAN":
            keep = options(op, S.ReducerOptions).KeepDims()
            axes = [int(a) for a in np.atleast_1d(self.const(ins[1]))]
            ys = [mb.reduce_mean(x=self.value(ins[0]), axes=axes, keep_dims=bool(keep))]
        elif code == "RESHAPE":
            if len(ins) > 1 and ins[1] >= 0:
                shape = [int(d) for d in self.const(ins[1])]
            else:
                shape = [int(d) for d in options(op, S.ReshapeOptions).NewShapeAsNumpy()]
            # A fixed batch dimension follows the input's (the models are converted with other batch sizes).
            out = self.tensors[outs[0]]
            if out.signature and out.signature[0] == -1:
                shape[0] = -1
            ys = [mb.reshape(x=self.value(ins[0]), shape=shape)]
        elif code == "STRIDED_SLICE":
            o = options(op, S.StridedSliceOptions)
            assert o.EllipsisMask() == 0 and o.NewAxisMask() == 0 and not o.Offset()
            begin, end, stride = (self.const(i).astype(np.int32) for i in ins[1:4])
            n = len(begin)
            bits = lambda m: [bool(m >> d & 1) for d in range(n)]
            ys = [mb.slice_by_index(x=self.value(ins[0]), begin=begin, end=end, stride=stride,
                                    begin_mask=bits(o.BeginMask()), end_mask=bits(o.EndMask()),
                                    squeeze_mask=bits(o.ShrinkAxisMask()))]
        elif code == "UNPACK":
            o = options(op, S.UnpackOptions)
            parts = mb.split(x=self.value(ins[0]), num_splits=o.Num(), axis=o.Axis())
            ys = [mb.squeeze(x=p, axes=[o.Axis()]) for p in parts]
        elif code == "DEPTH_TO_SPACE":
            bs = options(op, S.DepthToSpaceOptions).BlockSize()
            y = mb.transpose(x=self.value(ins[0]), perm=[0, 3, 1, 2])
            y = mb.depth_to_space(x=y, block_size=bs)
            ys = [mb.transpose(x=y, perm=[0, 2, 3, 1])]
        else:
            raise NotImplementedError(code)
        assert len(ys) == len(outs), code
        for o, y in zip(outs, ys):
            self.env[o] = self.quantize(y, self.tensors[o])

    # -- program ------------------------------------------------------------------------------------------------

    def program(self, outputs, batch=None, flexible_hw=False, flat_outputs=False):
        inputs = self.inputs_of(outputs)
        specs = {}
        for i in inputs:
            shape = list(self.tensors[i].shape)
            if batch:
                shape[0] = batch
            if flexible_hw:
                shape[1], shape[2] = get_new_symbol(), get_new_symbol()
            specs[safe(self.input_names[i])] = mb.placeholder(shape=shape, dtype=types.fp32)
        self.env = {}
        with Function(specs, opset_version=ct.target.macOS14) as fn:
            for i in inputs:
                x = fn.inputs[safe(self.input_names[i])]
                t = self.tensors[i]
                if t.quantized:  # raw bytes -> real values
                    zp = int(t.zero_point[0])
                    x = mb.mul(x=mb.sub(x=x, y=np.float32(zp)) if zp else x, y=np.float32(t.scale[0]))
                self.env[i] = x
            for k in self.needed_ops(outputs):
                self.convert_op(self.ops[k])
            outs = [mb.identity(x=flattened_nhwc(self.env[o], self.tensors[o].shape[3]) if flat_outputs else self.env[o],
                                name=safe(self.output_names[o])) for o in outputs]
            fn.set_outputs(outs)
        prog = Program()
        prog.add_function("main", fn)
        return prog


def flattened_nhwc(x, channels):
    """x (NHWC, computed from NCHW by a transpose that coremltools folds) with that transpose done on [1, C, H*W]
    instead: Core ML's CPU engine reads out of bounds in the 4-D one for small tensors (see the top)."""
    y = mb.transpose(x=x, perm=[0, 3, 1, 2])
    shape = mb.shape(x=y)
    h, w = mb.slice_by_index(x=shape, begin=[2], end=[3]), mb.slice_by_index(x=shape, begin=[3], end=[4])
    y = mb.reshape(x=y, shape=mb.concat(values=[np.array([1, channels], np.int32), mb.mul(x=h, y=w)], axis=0))
    y = mb.transpose(x=y, perm=[0, 2, 1])
    return mb.reshape(x=y, shape=mb.concat(values=[np.array([1], np.int32), h, w, np.array([channels], np.int32)], axis=0))


def safe(name):
    return "".join(c if c.isalnum() or c == "_" else "_" for c in name)


# -- the models archive ----------------------------------------------------------------------------------------------

DETECTION_DIR = "gocr/gocr_models/detection"
RECOGNITION_DIR = "gocr/gocr_models/line_recognition_mobile_convnext320_omni"
RECOGNIZER_BATCH = 8  # num_chunk_per_batch of every shipped recognizer config


def find_resources(path):
    """The Screen AI component folder: the one given, or a known install location."""
    candidates = [Path(path).expanduser()] if path else [Path("~/.config/screen_ai/resources").expanduser()]
    if not path:
        for browser in ("Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "Microsoft Edge"):
            base = Path("~/Library/Application Support").expanduser() / browser / "screen_ai"
            if base.is_dir():
                candidates += sorted((p for p in base.iterdir() if p.is_dir()), key=lambda p: p.name, reverse=True)
    for c in candidates:
        if (c / RECOGNITION_DIR).is_dir() and (c / DETECTION_DIR).is_dir():
            return c
    sys.exit("Can't find the Screen AI models" + (f" in {path}" if path else "") +
             ": pass the folder that contains gocr/gocr_models (Chrome's screen_ai component).")


def save(conv, outs, path, batch=None, enumerated_hw=False, flat_outputs=False):
    """Converts the graph computing `outs` to an fp32 .mlpackage. With `enumerated_hw`, the inputs take the sizes the
    detector feeds them: one side the declared size, the other a multiple of 32 up to it. With `flat_outputs`, NHWC
    outputs are transposed as flattened_nhwc does."""
    prog = conv.program(outs, batch=batch, flexible_hw=enumerated_hw, flat_outputs=flat_outputs)
    inputs = None
    if enumerated_hw:
        inputs = []
        for i in conv.inputs_of(outs):
            n, h, w, c = conv.tensors[i].shape
            shapes = sorted({(n, h, k, c) for k in range(32, w + 1, 32)} | {(n, k, w, c) for k in range(32, h + 1, 32)})
            shape = (ct.EnumeratedShapes(shapes=shapes, default=(n, h, w, c)) if len(shapes) <= 128 else
                     ct.Shape((n, ct.RangeDim(32, h, default=h), ct.RangeDim(32, w, default=w), c)))
            inputs.append(ct.TensorType(name=safe(conv.input_names[i]), shape=shape))
    ml = ct.convert(prog, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                    compute_precision=ct.precision.FLOAT32, inputs=inputs)
    ml.save(str(path))


def convert_detector(res, out):
    models = sorted((res / DETECTION_DIR).glob("*.tflite"))
    if len(models) != 1:
        sys.exit(f"Expected one detection model in {res / DETECTION_DIR}")
    conv = Converter(str(models[0]))
    # One model per pyramid level input: Core ML can't run the combined graph with the unused levels left empty.
    for i in conv.inputs:
        outs = [o for o in conv.outputs if conv.inputs_of([o]) == [i]]
        if outs:
            name = f"det_{safe(conv.input_names[i])}"
            print(f"  {name}", flush=True)
            save(conv, outs, out / f"{name}.mlpackage", enumerated_hw=True, flat_outputs=True)


def convert_recognizers(res, out):
    """Converts every line recognizer; returns their uint8 output quantization, which the app applies to the Core ML
    outputs to get the original's values back."""
    quantization = {}
    for path in sorted((res / RECOGNITION_DIR).glob("*.tflite")):
        if path.stem == "tflite_langid":
            continue
        print(f"  {path.stem}", flush=True)
        conv = Converter(str(path))
        save(conv, conv.outputs, out / f"{path.stem}.mlpackage", batch=RECOGNIZER_BATCH)
        q = {}
        for o in conv.outputs:
            t = conv.tensors[o]
            if t.quantized:
                q[safe(conv.output_names[o])] = {"scale": float(t.scale[0]), "zero_point": int(t.zero_point[0])}
        quantization[path.stem] = q
    return quantization


def string_tensor(t):
    """A TFLite string tensor's strings (count, offsets, data)."""
    raw = t.data.tobytes() if t.data is not None else b""
    n = int.from_bytes(raw[0:4], "little")
    offsets = [int.from_bytes(raw[4 + 4 * k:8 + 4 * k], "little") for k in range(n + 1)]
    return [raw[offsets[k]:offsets[k + 1]].decode() for k in range(n)]


def export_langid(res, out):
    """The language identifier's weights (its custom ops can't be converted; the app computes it directly)."""
    from flatbuffers import flexbuffers

    path = res / RECOGNITION_DIR / "tflite_langid.tflite"
    model = S.Model.GetRootAsModel(path.read_bytes(), 0)
    graph = model.Subgraphs(0)
    tensors = [Tensor(model, graph, i) for i in range(graph.TensorsLength())]
    blob = bytearray()

    def add(a):
        while len(blob) % 4:
            blob.append(0)
        spec = {"offset": len(blob), "shape": list(a.shape)}
        blob.extend(np.ascontiguousarray(a).astype(a.dtype.newbyteorder("<")).tobytes())
        return spec

    manifest = {"ngram": None, "embeddings": [], "layers": [], "labels": None}
    unstacked = []
    for k in range(graph.OperatorsLength()):
        op = graph.Operators(k)
        oc = model.OperatorCodes(op.OpcodeIndex())
        code = BUILTIN[max(oc.BuiltinCode(), oc.DeprecatedBuiltinCode())]
        ins = [int(i) for i in op.InputsAsNumpy()]
        if code == "CUSTOM" and oc.CustomCode().decode() == "NGramHash":
            o = flexbuffers.Loads(op.CustomOptionsAsNumpy().tobytes())
            manifest["ngram"] = {"seed": int(o["seed"]), "ngram_lengths": [int(v) for v in o["ngram_lengths"]],
                                 "vocab_sizes": [int(v) for v in o["vocab_sizes"]],
                                 "max_splits": int(o.get("max_splits", 128)),
                                 "lowercase": bool(o.get("lowercase_input", True))}
        elif code == "UNPACK":
            unstacked = [int(i) for i in op.OutputsAsNumpy()]
        elif code == "CUSTOM" and oc.CustomCode().decode() == "KmeansEmbeddingLookup":
            manifest["embeddings"].append((unstacked.index(ins[0]), {"codes": add(tensors[ins[1]].data),
                                                                     "codebook": add(tensors[ins[2]].data)}))
        elif code == "FULLY_CONNECTED":
            w, b = tensors[ins[1]], tensors[ins[2]]
            act = options(op, S.FullyConnectedOptions).FusedActivationFunction()
            if w.type != "INT8" or len(w.scale) != 1 or act not in (S.ActivationFunctionType.NONE,
                                                                    S.ActivationFunctionType.RELU):
                sys.exit("Unexpected language identifier layer")
            manifest["layers"].append({"weights": add(w.data), "bias": add(b.data), "scale": float(w.scale[0]),
                                       "relu": act == S.ActivationFunctionType.RELU})
    manifest["embeddings"] = [e for _, e in sorted(manifest["embeddings"], key=lambda e: e[0])]
    labels = [t for t in tensors if t.name.endswith("IndexToClassID")]
    if not manifest["ngram"] or not labels or len(manifest["embeddings"]) != len(manifest["ngram"]["ngram_lengths"]):
        sys.exit("Unexpected language identifier model")
    manifest["labels"] = string_tensor(labels[0])
    out.mkdir(parents=True)
    (out / "langid.bin").write_bytes(bytes(blob))
    (out / "langid.json").write_text(json.dumps(manifest, indent=1))


LAYOUT_MODEL = "gocr/layout/cluster_sort/model_v2.tflite"
# The ops the layout model uses, with the options the app reads: (options class, {name: getter}).
LAYOUT_OPS = {
    "ADD": None, "SUB": None, "MUL": None, "DIV": None, "MAXIMUM": None, "MINIMUM": None, "EXP": None, "RSQRT": None,
    "LESS": None, "LESS_EQUAL": None, "GREATER_EQUAL": None, "LOGICAL_AND": None, "SELECT": None, "CAST": None,
    "SHAPE": None, "FILL": None, "RESHAPE": None, "EXPAND_DIMS": None, "TRANSPOSE": None, "BROADCAST_TO": None,
    "SLICE": None, "GATHER_ND": None, "SCATTER_ND": None, "UNSORTED_SEGMENT_PROD": None, "FULLY_CONNECTED": None,
    "CONCATENATION": (S.ConcatenationOptions, {"axis": "Axis"}),
    "GATHER": (S.GatherOptions, {"axis": "Axis", "batch_dims": "BatchDims"}),
    "SUM": (S.ReducerOptions, {"keep_dims": "KeepDims"}),
    "REDUCE_ALL": (S.ReducerOptions, {"keep_dims": "KeepDims"}),
    "STRIDED_SLICE": (S.StridedSliceOptions, {"begin_mask": "BeginMask", "end_mask": "EndMask",
                                              "ellipsis_mask": "EllipsisMask", "new_axis_mask": "NewAxisMask",
                                              "shrink_axis_mask": "ShrinkAxisMask", "offset": "Offset"}),
}
# Fused activations the app doesn't apply: they must be NONE.
FUSED = {"ADD": S.AddOptions, "SUB": S.SubOptions, "MUL": S.MulOptions, "DIV": S.DivOptions,
         "CONCATENATION": S.ConcatenationOptions, "FULLY_CONNECTED": S.FullyConnectedOptions}


def export_layout(res, out):
    """The layout analysis' graph network (line reading order), as its operators and constants: its dynamic shapes
    don't convert to Core ML, so the app runs the graph itself (it is small)."""
    path = res / LAYOUT_MODEL
    if not path.is_file():
        sys.exit(f"Can't find the layout model {path}")
    model = S.Model.GetRootAsModel(path.read_bytes(), 0)
    graph = model.Subgraphs(0)
    tensors = [Tensor(model, graph, i) for i in range(graph.TensorsLength())]
    blob = bytearray()
    manifest = {"tensors": [], "operators": [], "inputs": [int(i) for i in graph.InputsAsNumpy()],
                "outputs": [int(i) for i in graph.OutputsAsNumpy()]}
    computed = set(manifest["inputs"])
    for k in range(graph.OperatorsLength()):
        computed.update(int(i) for i in graph.Operators(k).OutputsAsNumpy())
    for t in tensors:
        if t.type not in ("FLOAT32", "INT32", "INT64", "BOOL") or t.quantized:
            sys.exit(f"Unexpected layout model tensor type {t.type}")
        spec = {"type": t.type.lower(), "shape": t.shape}
        if t.index not in computed:  # a constant (empty ones have no data)
            data = t.data if t.data is not None else np.zeros(t.shape, dtype=NP.get(t.type, np.bool_))
            while len(blob) % 8:
                blob.append(0)
            spec["offset"] = len(blob)
            blob.extend(np.ascontiguousarray(data).astype(data.dtype.newbyteorder("<")).tobytes())
        manifest["tensors"].append(spec)
    for k in range(graph.OperatorsLength()):
        op = graph.Operators(k)
        oc = model.OperatorCodes(op.OpcodeIndex())
        code = BUILTIN[max(oc.BuiltinCode(), oc.DeprecatedBuiltinCode())]
        if code not in LAYOUT_OPS:
            sys.exit(f"Unexpected layout model operator {code}")
        entry = {"op": code, "inputs": [int(i) for i in op.InputsAsNumpy()],
                 "outputs": [int(i) for i in op.OutputsAsNumpy()]}
        if code in FUSED and options(op, FUSED[code]).FusedActivationFunction() != S.ActivationFunctionType.NONE:
            sys.exit(f"Unexpected fused activation in the layout model's {code}")
        if code == "FULLY_CONNECTED" and not options(op, S.FullyConnectedOptions).KeepNumDims():
            sys.exit("Unexpected layout model FULLY_CONNECTED options")
        if LAYOUT_OPS[code]:
            cls, fields = LAYOUT_OPS[code]
            o = options(op, cls)
            entry["options"] = {name: int(getattr(o, getter)()) for name, getter in fields.items()}
        manifest["operators"].append(entry)
    out.mkdir(parents=True)
    (out / "layout.bin").write_bytes(bytes(blob))
    (out / "layout.json").write_text(json.dumps(manifest, separators=(",", ":")))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("resources", nargs="?",
                    help="the Screen AI component folder (default: ~/.config/screen_ai/resources, or Chrome's)")
    ap.add_argument("-o", "--output", default="ScreenAI-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    res = find_resources(a.resources)
    output = Path(a.output).expanduser().resolve()
    print(f"Converting the models in {res}")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "coreml").mkdir()
        print("Text detector:", flush=True)
        convert_detector(res, root / "coreml")
        print("Line recognizers:", flush=True)
        quantization = convert_recognizers(res, root / "coreml")
        (root / "coreml" / "recognizers.json").write_text(json.dumps(quantization, indent=1))
        print("Language identifier", flush=True)
        export_langid(res, root / "langid")
        print("Layout model", flush=True)
        export_layout(res, root / "layout")
        # The configs, label maps and language models, under their original paths.
        for path in sorted((res / "gocr/gocr_models").rglob("*")):
            if path.is_file() and path.suffix != ".tflite":
                dst = root / path.relative_to(res)
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dst)
        (root / "screenai.json").write_text(json.dumps({"format": 1, "source": str(res)}, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > OCR Mode > Screen AI models > Load, and pick this file.")


if __name__ == "__main__":
    main()
