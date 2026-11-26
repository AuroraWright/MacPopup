"""Converts the mida + VOCR6 OCR models (meikipop's "mida + VOCR6 (local)" provider, github.com/rtr46/meikipop, as of
commit c5ca5b1) to Core ML, into vendor/mida-vocr6:

- mida (`mida_l_alpha_v0.0.2.onnx`, huggingface.co/rtr46/mida, by meikiocr's author) finds the text lines, horizontal
  and vertical.
- VOCR6.2-L (`VOCR6.2_L_fast.onnx`, github.com/bee-san/vita-vn-ocr, release v0.5.1-onnx.2) reads the horizontal ones.
- VOCR6-V (`VOCR6_V_fast.onnx`, huggingface.co/rtr46/vocr6: vita-vn-ocr's VOCR6_V_w8.vocr from release
  v0.4.2-vertical6.1, converted to ONNX with vita-vn-ocr's own converter) reads the vertical ones, turned anticlockwise.

The converted models are checked in, so this only needs running to update them. It needs Python 3.12 (coremltools
has no native build for newer versions) with the packages below, e.g.:

    uv venv -p 3.12 .venv-mida
    VIRTUAL_ENV=.venv-mida uv pip install onnx coremltools numpy onnxruntime
    .venv-mida/bin/python scripts/convert-mida-vocr6.py [--models <folder>]

It downloads the models (checked against their SHA-256), unless --models names a folder that has them under their
file names above. The ONNX graphs are rebuilt with coremltools' MIL builder, op by op (see Converter): their shapes
follow the input's size (the detector's attention and the crops after its upsampling), which tracing through PyTorch
would make constant. They stay in 32-bit floats. Each converted model is checked against onnxruntime at a few sizes.

The recognizers' last step isn't converted. VOCR6.2-L's "fast" head picks, per frame, whether to score the 5,127 rarer
characters as well as the 504 common ones (an `If` with NonZero and ScatterND); VOCR6-V's scores all 4,987 of its
characters. The Core ML models end at the 96 features of each frame, and MidaVOCR6.swift scores them, with the heads'
weights from VOCR6Head.bin and VOCR6VerticalHead.bin and the rest (L's gate, the characters, the cells' calibration:
VOCR6-V's own, and pull 131's refit for VOCR6.2-L) from MidaVOCR6.json.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.request

import numpy as np
import onnx
import onnxruntime
from onnx import helper, numpy_helper

MIDA = ("mida_l_alpha_v0.0.2.onnx", "https://huggingface.co/rtr46/mida/resolve/main/mida_l_alpha_v0.0.2.onnx",
        "7a09988b2596ef3fda2e5dfa815bfebbba6d3dcc385cc905cbb329cd8c95a4fa")
VOCR = ("VOCR6.2_L_fast.onnx", "https://github.com/bee-san/vita-vn-ocr/releases/download/v0.5.1-onnx.2/VOCR6.2_L_fast.onnx",
        "3084fb3bd1332832c872009d869d267d5acd1bd69d26c80f742aa2f31a80c938")
VOCR_V = ("VOCR6_V_fast.onnx", "https://huggingface.co/rtr46/vocr6/resolve/main/VOCR6_V_fast.onnx",
          "080f0651fe2f23e87befea16995c21089e02da85be96b6189c26c2ab413ac5eb")
# meikipop pull 131's refit of VOCR6.2-L's cell calibration (its vocr_onnx.py CHARBOX_CAL): the model's own, fit on
# VOCR5-L, puts cells about 11% of a character too far right. meikipop now uses the model's own (c5ca5b1); against
# Google Lens on 500 game pictures, the refit puts 92% of characters within a quarter cell of Lens' (the model's 82%).
REFIT_CALIBRATION = [-107, 0, 183, 4, 38, 7, -4, 44, 8]
# The recognizers' last node before their heads: the features, [96, frames].
VOCR_FEATURES = "reshape_181"
OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vendor", "mida-vocr6"))


def model_data(folder, name, url, sha256):
    path = os.path.join(folder, name) if folder else None
    if path and os.path.isfile(path):
        data = open(path, "rb").read()
    else:
        print(f"downloading {url}")
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "macpopup"}), timeout=120) as r:
            data = r.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"{name}: unexpected checksum (this script converts exactly the file with SHA-256 {sha256})")
    return data


class Converter:
    """An ONNX graph as a MIL program. Values computable without the input (weights, constant shapes) are worked out
    with numpy; the rest become MIL ops, shapes included (mb.shape), so the program takes any input size."""

    def __init__(self, model, biases_after=False):
        self.graph = model.graph
        self.biases_after = biases_after
        self.values = {t.name: numpy_helper.to_array(t) for t in self.graph.initializer}

    def run(self, input_name, x, outputs):
        from coremltools.converters.mil import Builder as mb
        self.mb = mb
        self.values[input_name] = x
        for node in self.graph.node:
            if all(o in self.values for o in node.output):
                continue
            ins = [self.values[i] if i else None for i in node.input]
            attrs = {a.name: helper.get_attribute_value(a) for a in node.attribute}
            if all(i is None or isinstance(i, np.ndarray) for i in ins) and node.op_type != "Shape":
                out = self.fold(node.op_type, ins, attrs)
            else:
                out = self.op(node.op_type, ins, attrs)
            for name, value in zip(node.output, out if isinstance(out, tuple) else (out,)):
                self.values[name] = value
            if all(o in self.values for o in outputs):
                break
        return [self.values[o] for o in outputs]

    @staticmethod
    def fold(op, ins, attrs):
        if op == "Constant":
            return numpy_helper.to_array(attrs["value"])
        if op == "Cast":
            return ins[0].astype(helper.tensor_dtype_to_np_dtype(attrs["to"]))
        if op in ("Add", "Sub", "Mul", "Div"):
            a, b = ins
            if op == "Div" and np.issubdtype(a.dtype, np.integer):
                return a // b
            return {"Add": np.add, "Sub": np.subtract, "Mul": np.multiply, "Div": np.divide}[op](a, b)
        if op == "Unsqueeze":
            return np.expand_dims(ins[0], tuple(int(a) for a in ins[1]))
        if op == "Concat":
            return np.concatenate(ins, axis=attrs["axis"])
        if op == "Gather":
            return np.take(ins[0], ins[1], axis=attrs.get("axis", 0))
        if op == "Pow":
            return np.power(ins[0], ins[1])
        raise NotImplementedError(f"can't fold {op} into a constant")

    def ints(self, x):
        """A shape-like value as int32, for MIL."""
        mb = self.mb
        if isinstance(x, np.ndarray):
            return x.astype(np.int32)
        return x if x.dtype.__name__ == "int32" else mb.cast(x=x, dtype="int32")

    def op(self, op, ins, attrs):
        mb = self.mb
        x = ins[0]
        if op == "Conv":
            pads = attrs.get("pads", [0, 0, 0, 0])
            bias = ins[2] if len(ins) > 2 else None
            y = mb.conv(x=x, weight=ins[1], bias=None if self.biases_after else bias, strides=attrs.get("strides", [1, 1]),
                        pad_type="custom", pad=[pads[0], pads[2], pads[1], pads[3]],
                        dilations=attrs.get("dilations", [1, 1]), groups=attrs.get("group", 1))
            return mb.add(x=y, y=bias.reshape(1, -1, 1, 1)) if self.biases_after and bias is not None else y
        if op == "Relu":
            return mb.relu(x=x)
        if op in ("Add", "Sub", "Mul", "Div", "Pow"):
            a, b = ins
            integer = any(isinstance(v, np.ndarray) and np.issubdtype(v.dtype, np.integer) for v in (a, b)) or \
                any(not isinstance(v, np.ndarray) and v.dtype.__name__.startswith("int") for v in (a, b))
            if integer:
                a, b = self.ints(a), self.ints(b)
            else:
                a = a.astype(np.float32) if isinstance(a, np.ndarray) else a
                b = b.astype(np.float32) if isinstance(b, np.ndarray) else b
            fn = {"Add": mb.add, "Sub": mb.sub, "Mul": mb.mul, "Pow": mb.pow,
                  "Div": mb.floor_div if integer else mb.real_div}[op]
            return fn(x=a, y=b)
        if op == "MatMul":
            return mb.matmul(x=x, y=ins[1])
        if op == "Transpose":
            return mb.transpose(x=x, perm=attrs["perm"])
        if op == "Reshape":
            shape = ins[1]
            if isinstance(shape, np.ndarray):
                assert 0 not in shape.tolist() or attrs.get("allowzero", 0) == 0
                if 0 in shape.tolist():  # 0: keep that dimension
                    actual = mb.shape(x=x)
                    shape = mb.concat(values=[mb.slice_by_index(x=actual, begin=[i], end=[i + 1]) if v == 0 else
                                              np.array([v], np.int32) for i, v in enumerate(shape.tolist())], axis=0)
            return mb.reshape(x=x, shape=self.ints(shape))
        if op == "LayerNormalization":
            assert attrs.get("axis", -1) == -1
            return mb.layer_norm(x=x, axes=[-1], gamma=ins[1], beta=ins[2], epsilon=float(attrs.get("epsilon", 1e-5)))
        if op == "Softmax":
            return mb.softmax(x=x, axis=attrs.get("axis", -1))
        if op == "Resize":
            scales = ins[2]
            assert attrs["mode"] == b"nearest" and attrs["coordinate_transformation_mode"] == b"asymmetric" and \
                attrs["nearest_mode"] == b"floor" and scales[:2].tolist() == [1, 1] and \
                all(float(s).is_integer() for s in scales[2:])
            # Whole factors: each pixel repeated, as ONNX's nearest (asymmetric, floor) does.
            return mb.upsample_nearest_neighbor(x=x, scale_factor_height=float(scales[2]), scale_factor_width=float(scales[3]))
        if op == "Shape":
            return mb.shape(x=x)
        if op == "Gather":
            index = ins[1]
            assert isinstance(index, np.ndarray) and attrs.get("axis", 0) == 0 and x.rank == 1
            index = index % x.shape[0]  # from the end if negative
            if index.ndim == 0:
                return mb.squeeze(x=mb.slice_by_index(x=x, begin=[int(index)], end=[int(index) + 1]), axes=[0])
            return mb.gather(x=x, indices=index.astype(np.int32), axis=0)
        if op == "Unsqueeze":
            return mb.expand_dims(x=x, axes=[int(a) for a in ins[1]])
        if op == "Concat":
            if any(not isinstance(v, np.ndarray) and v.dtype.__name__.startswith("int") for v in ins) or \
                    all(isinstance(v, np.ndarray) and np.issubdtype(v.dtype, np.integer) for v in ins if isinstance(v, np.ndarray)):
                return mb.concat(values=[self.ints(v) for v in ins], axis=attrs["axis"])
            return mb.concat(values=ins, axis=attrs["axis"])
        if op == "Cast":
            to = attrs["to"]
            if to == onnx.TensorProto.FLOAT:
                return x if x.dtype.__name__ == "fp32" else mb.cast(x=x, dtype="fp32")
            if to in (onnx.TensorProto.INT64, onnx.TensorProto.INT32):
                return self.ints(x)
            raise NotImplementedError(f"Cast to {to}")
        if op == "Slice":
            starts, ends = ins[1], ins[2]
            axes = ins[3] if len(ins) > 3 and ins[3] is not None else np.arange(len(starts) if isinstance(starts, np.ndarray) else 1)
            steps = ins[4] if len(ins) > 4 and ins[4] is not None else None
            assert isinstance(axes, np.ndarray) and (steps is None or set(steps.tolist()) == {1})
            rank = x.rank
            begin, end = [np.array([0], np.int32)] * rank, [np.array([0], np.int32)] * rank
            begin_mask, end_mask = [True] * rank, [True] * rank
            for k, axis in enumerate(axes.tolist()):
                axis %= rank
                start = starts[k:k + 1] if isinstance(starts, np.ndarray) else mb.reshape(x=self.ints(starts), shape=[1])
                stop = ends[k:k + 1] if isinstance(ends, np.ndarray) else mb.reshape(x=self.ints(ends), shape=[1])
                begin[axis], begin_mask[axis] = self.ints(start), False
                if isinstance(stop, np.ndarray) and int(stop[0]) >= 2 ** 31 - 1:
                    continue
                end[axis], end_mask[axis] = self.ints(stop), False
            dynamic = any(not isinstance(v, np.ndarray) for v in begin + end)
            if dynamic:
                begin, end = mb.concat(values=begin, axis=0), mb.concat(values=end, axis=0)
            else:
                begin, end = np.concatenate(begin), np.concatenate(end)
            return mb.slice_by_index(x=x, begin=begin, end=end, begin_mask=begin_mask, end_mask=end_mask)
        raise NotImplementedError(f"unsupported ONNX op {op}")


def convert(onnx_model, input_name, shape, output_names, renamed, biases_after=False):
    """The ONNX graph computing `output_names` (named as `renamed`) as an fp32 Core ML model taking `shape` (with
    RangeDims), its input as floats. With `biases_after`, convolutions add their biases as separate ops (for the GPU, see
    the top)."""
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import Function, Program, get_new_symbol, types

    symbolic = [get_new_symbol() if isinstance(d, ct.RangeDim) else d for d in shape]
    with Function({input_name: mb.placeholder(shape=symbolic, dtype=types.fp32)}, opset_version=ct.target.macOS14) as fn:
        outs = Converter(onnx_model, biases_after).run(input_name, fn.inputs[input_name], output_names)
        fn.set_outputs([mb.identity(x=o, name=n) for o, n in zip(outs, renamed)])
    program = Program()
    program.add_function("main", fn)
    passes = ct.PassPipeline.DEFAULT
    if biases_after:
        # The pass that would put them back into the convolutions.
        passes.remove_passes({"common::fuse_conv_bias"})
    return ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                      compute_precision=ct.precision.FLOAT32, pass_pipeline=passes,
                      inputs=[ct.TensorType(name=input_name, shape=ct.Shape(shape=shape))])


def check(name, ml, onnx_bytes, input_name, ml_input, onnx_output, ml_output, inputs, tolerance):
    """Core ML (CPU) against onnxruntime on each input; exits if they're further apart than `tolerance` (relative to the
    output's largest value)."""
    session = onnxruntime.InferenceSession(onnx_bytes, providers=["CPUExecutionProvider"])
    feeds_extra = {i.name: np.array(True) for i in session.get_inputs() if i.name == "head_sections"}
    for onnx_input, coreml_input in inputs:
        expected = session.run([onnx_output], {input_name: onnx_input, **feeds_extra})[0]
        actual = ml.predict({ml_input: coreml_input})[ml_output]
        error = np.abs(actual.reshape(expected.shape) - expected).max() / max(1e-6, np.abs(expected).max())
        print(f"{name} at {list(coreml_input.shape)}: largest difference {error:.2e} of the largest value")
        if error > tolerance:
            sys.exit(f"{name}: Core ML and onnxruntime differ at {list(coreml_input.shape)}")


def with_output(model_bytes, name):
    """The model with an internal value as an extra output (for checking against it)."""
    model = onnx.load_model_from_string(model_bytes)
    model.graph.output.append(helper.make_empty_tensor_value_info(name))
    return model.SerializeToString()


def graph_values(model):
    """The graph's weights and constants, its subgraphs' too."""
    values = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}

    def collect(graph):
        for node in graph.node:
            if node.op_type == "Constant":
                values[node.output[0]] = numpy_helper.to_array(node.attribute[0].t)
            for a in node.attribute:
                if a.type == onnx.AttributeProto.GRAPH:
                    values.update({t.name: numpy_helper.to_array(t) for t in a.g.initializer})
                    collect(a.g)

    collect(model.graph)
    return values


def recognizer_head(model):
    """VOCR6.2-L's head's weights and its gate's (see MidaVOCR6.swift), from the graph's values."""
    values = graph_values(model)
    # The classes' weights: int8 times a scale per class, as the graph's Cast and Mul make them.
    weights = values["wq_237"].astype(np.float32) * values["scale_240"]
    bias = values["b_386"].reshape(-1).astype(np.float32)
    assert weights.shape == (96, 5631) and np.array_equal(values["b_251"].reshape(-1), bias[:504])
    assert np.array_equal(values["b_337"].reshape(-1), bias[504:]) and np.array_equal(values["wq_256"], values["wq_389"])
    # What the gate's int8 product reads: the features scaled to ±32767 per frame and rounded (sign × floor(|x| + 0.5)),
    # times the uint8 weights less 128, exactly (the graph splits it into two uint8 products).
    expected = {"c_192": 32767.0, "c_203": 0.5, "c_210": -32767.0, "c_213": 256.0, "c_222": 128.0, "c_261": 256,
                "zp_254": 128, "zp_255": 0, "c_187": 0.0, "c_6": 1.0}
    for key, value in expected.items():
        assert values[key].reshape(-1)[0] == value, key
    gate = {
        "weights": (values["wq_256"].astype(np.int32) - 128).tolist(),  # [96][16]
        "scale": values["scale_268"].reshape(-1).tolist(),
        "bias": values["bias_273"].reshape(-1).tolist(),
        "commonMax": values["wl1_282"].reshape(-1).tolist(),
        "blank": values["wb0_287"].reshape(-1).tolist(),
        "output": values["w2_294"].reshape(-1).tolist(),
        "outputBias": float(values["b0_301"].reshape(-1)[0]),
        "threshold": float(values["c_317"].reshape(-1)[0]),
    }
    return weights, bias, gate


def vertical_head(model):
    """VOCR6-V's head's weights: every character scored from the features (the graph's MatMul and Add, then TopK)."""
    values = graph_values(model)
    weights = values["wq_237"].astype(np.float32) * values["scale_240"]
    bias = values["b_246"].reshape(-1).astype(np.float32)
    nodes = {n.output[0]: n for n in model.graph.node}
    assert weights.shape == (96, 4987) and nodes["matmul_244"].input[0] == "transpose_235"
    assert nodes["add_247"].input == ["matmul_244", "b_246"] and nodes["transpose_235"].input[0] == VOCR_FEATURES
    return weights, bias


def recognizer_info(meta):
    """A recognizer's characters, sizes and cells' calibration, from its metadata."""
    if meta.get("vocr.format") != "1" or meta.get("vocr.kind") != "recognizer" or meta.get("vocr.mode") != "fast":
        sys.exit("unexpected recognizer metadata")
    return {
        "vocabulary": json.loads(meta["vocr.vocab"]),
        "height": int(meta["vocr.height"]), "stride": int(meta["vocr.stride"]),
        "minWidth": int(meta["vocr.min_width"]), "maxWidth": int(meta["vocr.max_width"]),
        "calibration": json.loads(meta["vocr.charbox_cal"]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--models", help="a folder with the ONNX files (otherwise they're downloaded)")
    args = parser.parse_args()
    import coremltools as ct

    mida_bytes = model_data(args.models, *MIDA)
    vocr_bytes = model_data(args.models, *VOCR)
    vertical_bytes = model_data(args.models, *VOCR_V)
    vocr = onnx.load_model_from_string(vocr_bytes)
    vertical = onnx.load_model_from_string(vertical_bytes)
    info = {
        "horizontal": recognizer_info({p.key: p.value for p in vocr.metadata_props}),
        "vertical": recognizer_info({p.key: p.value for p in vertical.metadata_props}),
    }
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(0)

    def save(model, name):
        path = os.path.join(OUT, f"{name}.mlpackage")
        if os.path.exists(path):
            shutil.rmtree(path)
        model.save(path)
        print(f"saved {path}")

    # Up to 4096 pixels a side: the provider feeds pictures of up to 600,000 pixels at their own size.
    detector = convert(onnx.load_model_from_string(mida_bytes), "images",
                       (1, 3, ct.RangeDim(16, 4096, default=544), ct.RangeDim(16, 4096, default=960)),
                       ["maps"], ["maps"], biases_after=True)
    detector.short_description = f"{MIDA[0]} from huggingface.co/rtr46/mida, converted"
    samples = []
    for h, w in ((544, 960), (581, 1032), (544, 725), (411, 960), (37, 960), (1140, 526), (146, 4096)):
        image = rng.random((1, 3, h, w), dtype=np.float32)
        samples.append((image, image))
    check("detector", detector, mida_bytes, "images", "images", "maps", "maps", samples, 1e-4)
    save(detector, "MidaDetection")

    for model, model_bytes, name, source in ((vocr, vocr_bytes, "VOCR6Recognition", f"{VOCR[0]} (vita-vn-ocr v0.5.1-onnx.2)"),
                                             (vertical, vertical_bytes, "VOCR6VerticalRecognition",
                                              f"{VOCR_V[0]} (vita-vn-ocr v0.4.2-vertical6.1, from huggingface.co/rtr46/vocr6)")):
        recognizer = convert(model, "grey", (1, 1, 32, ct.RangeDim(8, 1024, default=256)), [VOCR_FEATURES], ["features"])
        recognizer.short_description = f"{source} up to its head's features, converted"
        recognizer.license = "GPL-3.0-or-later, non-commercial use only (" + \
            ("VOCR6-ATTRIBUTION.md)" if model is vocr else "VOCR6-V-ATTRIBUTION.md)")
        samples = []
        for w in (8, 64, 256, 1024):
            grey = rng.integers(0, 256, (1, 1, 32, w), dtype=np.uint8)
            samples.append((grey, grey.astype(np.float32)))
        check(name, recognizer, with_output(model_bytes, VOCR_FEATURES), "grey", "grey", VOCR_FEATURES,
              "features", samples, 1e-4)
        save(recognizer, name)

    weights, bias, gate = recognizer_head(vocr)
    info["horizontal"]["calibration"] = REFIT_CALIBRATION
    info["horizontal"]["commonClasses"] = int({p.key: p.value for p in vocr.metadata_props}["vocr.level1_classes"])
    info["horizontal"]["gate"] = gate
    vertical_weights, vertical_bias = vertical_head(vertical)
    check_vertical_head(vertical_bytes, vertical_weights, vertical_bias, rng)
    # The classes' weights ([96][classes]), then their biases, as little-endian floats.
    for name, (w, b) in (("VOCR6Head.bin", (weights, bias)), ("VOCR6VerticalHead.bin", (vertical_weights, vertical_bias))):
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(w.astype("<f4").tobytes() + b.astype("<f4").tobytes())
    with open(os.path.join(OUT, "MidaVOCR6.json"), "w") as f:
        json.dump(info, f, ensure_ascii=False)
    print(f"saved VOCR6Head.bin, VOCR6VerticalHead.bin and MidaVOCR6.json in {OUT}")


def check_vertical_head(model_bytes, weights, bias, rng):
    """The head's weights give the graph's best classes, from its features."""
    session = onnxruntime.InferenceSession(with_output(model_bytes, VOCR_FEATURES), providers=["CPUExecutionProvider"])
    for w in (64, 512):
        grey = rng.integers(0, 256, (1, 1, 32, w), dtype=np.uint8)
        features, best = session.run([VOCR_FEATURES, "best"], {"grey": grey})
        scores = features.T @ weights + bias
        if not np.array_equal(scores.argmax(1), best):
            sys.exit("the vertical recognizer's head doesn't give the graph's classes")
    print("vertical head: same classes as onnxruntime")


if __name__ == "__main__":
    main()
