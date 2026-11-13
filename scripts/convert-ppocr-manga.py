"""Converts PP-OCRv6_manga's ONNX models (https://huggingface.co/Kellenok/PP-OCRv6_manga) to Core ML, into
vendor/ppocr-manga, with its character list.

The converted models are checked in, so this only needs running to update them. It needs Python 3.12 (coremltools
has no native build for newer versions) with the packages below, e.g.:

    uv venv -p 3.12 .venv-ppocr
    VIRTUAL_ENV=.venv-ppocr uv pip install onnx onnx2torch coremltools "torch==2.7.0" numpy onnxruntime
    .venv-ppocr/bin/python scripts/convert-ppocr-manga.py

ONNX goes to PyTorch (onnx2torch), then to Core ML (coremltools), after three changes to the ONNX graphs that give
the same outputs (checked with onnxruntime) but that onnx2torch and tracing need: see fix(). Both models take any
size (the detector a picture whose sides are multiples of 32, the recognizer a line 48 pixels high). They're kept in
32-bit floats: in 16 bits about 1 in 100 characters comes out different.

The detector's convolutions add their biases as separate steps (see BiasAfter): with the biases in the convolutions,
macOS 27's GPU compiler crashed on it (an expand_dims it adds got a garbage axis, then "shape for TensorData is not
static"), at any input size, while a fixed size worked. It's also faster on the GPU on macOS 15 (about a third).
"""

import hashlib
import os
import sys
import urllib.request

import coremltools as ct
import numpy as np
import onnx
import onnx2torch
import onnxruntime
import torch
from onnx import helper, numpy_helper

REPOSITORY = ("Kellenok/PP-OCRv6_manga", "d65838996a00ef6b1c73ca3a700d7a8c5fbbef8a")
# (file, SHA-256, Core ML model name, input name, input shape, output name)
MODELS = [
    ("det/manga_det.onnx", "97c434ae8deaad83513fb132b605d5085a3af8ffac2cb15e2aa096815c206172",
     "PPOCRMangaDetection", "image", (1, 3, ct.RangeDim(32, 2048, default=544), ct.RangeDim(32, 2048, default=960)),
     "probabilities"),
    ("rec/manga_rec.onnx", "5288bd221a9a047c6b7d1ff56bb98de8c875fb613df98ebe8754946448bda540",
     "PPOCRMangaRecognition", "line", (1, 3, 48, ct.RangeDim(16, 4800, default=320)), "logits"),
]
CHARACTERS = ("ppocrv6_dict.txt", "4f0f8971ecb95e3a4d278985d6eaac154413e81fda0b4c941db17389580e9e9b",
              "PPOCRMangaCharacters.txt")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vendor", "ppocr-manga")


def download(filename, sha256):
    (name, revision) = REPOSITORY
    url = f"https://huggingface.co/{name}/resolve/{revision}/{filename}"
    print(f"downloading {url}")
    with urllib.request.urlopen(url) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"{filename}: unexpected checksum")
    return data


def fix(graph):
    """The graph as onnx2torch and tracing can take it."""
    nodes = graph.graph.node
    # 2x2 stride-1 convolutions and max pooling with auto_pad SAME_UPPER, which onnx2torch doesn't take: padded one
    # row and column at the end, as SAME_UPPER pads them.
    for node in nodes:
        attributes = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        if attributes.get("auto_pad", b"NOTSET") == b"NOTSET":
            continue
        assert attributes["auto_pad"] == b"SAME_UPPER" and attributes["kernel_shape"] == [2, 2]
        assert attributes.get("strides", [1, 1]) == [1, 1] and attributes.get("dilations", [1, 1]) == [1, 1]
        kept = [a for a in node.attribute if a.name != "auto_pad"]
        del node.attribute[:]
        node.attribute.extend(kept + [helper.make_attribute("pads", [0, 0, 1, 1])])
    # Identity nodes, which onnx2torch can't follow to a convolution's weights: their outputs' consumers take their
    # input instead.
    outputs = {o.name for o in graph.graph.output}
    renamed = {}
    for node in [n for n in nodes if n.op_type == "Identity" and n.output[0] not in outputs]:
        renamed[node.output[0]] = node.input[0]
        nodes.remove(node)

    def source(name):
        while name in renamed:
            name = renamed[name]
        return name

    for node in nodes:
        for index, name in enumerate(node.input):
            node.input[index] = source(name)
    # The recognizer's reshapes around its attention take their shapes from Shape -> Slice -> Concat, which tracing
    # makes constant (then only the traced width works): with 0 (keep) and -1 (the rest) instead.
    for name, shape in (("Reshape.54", [0, 0, -1]), ("Reshape.73", [0, 1, -1, 120])):
        for node in nodes:
            if node.name == name and any(n.op_type == "Concat" and n.output[0] == node.input[1] for n in nodes):
                graph.graph.initializer.append(numpy_helper.from_array(np.array(shape, np.int64), name + ".shape"))
                node.input[1] = name + ".shape"
    return graph


def check(original, fixed, shape):
    """The fixed graph gives the original's outputs, also at another width than the one it's traced at (a multiple of
    32, as the detector needs)."""
    rng = np.random.default_rng(0)
    for size in (shape, shape[:3] + (shape[3] * 2 + 64,)):
        x = rng.standard_normal(size).astype(np.float32)
        a = onnxruntime.InferenceSession(original).run(None, {"x": x})[0]
        b = onnxruntime.InferenceSession(fixed.SerializeToString()).run(None, {"x": x})[0]
        if not np.array_equal(a, b):
            sys.exit(f"the changed graph gives different outputs at {size}")


class BiasAfter(torch.nn.Module):
    """A convolution without its bias, which is added after it."""

    def __init__(self, conv):
        super().__init__()
        self.conv = conv
        self.bias = torch.nn.Parameter(conv.bias.detach().clone().view(1, -1, 1, 1))
        conv.bias = None

    def forward(self, x):
        return self.conv(x) + self.bias


def biases_after(model):
    """The model with its convolutions' biases added after them (see BiasAfter)."""
    for name, child in list(model.named_children()):
        if isinstance(child, torch.nn.Conv2d) and child.bias is not None:
            setattr(model, name, BiasAfter(child))
        else:
            biases_after(child)
    return model


def convert(graph, input_name, shape, output_name, separate_biases):
    model = onnx2torch.convert(graph).eval()
    passes = ct.PassPipeline.DEFAULT
    if separate_biases:
        model = biases_after(model)
        # The pass that would put them back into the convolutions.
        passes.remove_passes({"common::fuse_conv_bias"})
    example_shape = tuple(d.default if isinstance(d, ct.RangeDim) else d for d in shape)
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.rand(example_shape), check_trace=False)
    return ct.convert(
        traced,
        inputs=[ct.TensorType(name=input_name, shape=ct.Shape(shape=shape))],
        outputs=[ct.TensorType(name=output_name)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
        pass_pipeline=passes,
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    for filename, sha256, name, input_name, shape, output_name in MODELS:
        data = download(filename, sha256)
        fixed = fix(onnx.load_model_from_string(data))
        example_shape = tuple(d.default if isinstance(d, ct.RangeDim) else d for d in shape)
        check(data, fixed, example_shape)
        # Only the detector runs on the GPU.
        model = convert(fixed, input_name, shape, output_name, separate_biases=name == "PPOCRMangaDetection")
        model.short_description = f"{filename} from huggingface.co/{REPOSITORY[0]} ({REPOSITORY[1][:7]}), converted"
        model.license = "Apache-2.0"
        path = os.path.join(OUT, f"{name}.mlpackage")
        model.save(path)
        print(f"saved {path}")
    filename, sha256, name = CHARACTERS
    with open(os.path.join(OUT, name), "wb") as file:
        file.write(download(filename, sha256))
    print(f"saved {os.path.join(OUT, name)}")


if __name__ == "__main__":
    main()
