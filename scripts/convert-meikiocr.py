"""Converts meikiocr's ONNX models (https://github.com/rtr46/meikiocr) to Core ML, into vendor/meikiocr.

The converted models are checked in, so this only needs running to update them. It needs Python 3.12 (coremltools
has no native build for newer versions) with the packages below, e.g.:

    uv venv -p 3.12 .venv-meikiocr
    VIRTUAL_ENV=.venv-meikiocr uv pip install onnx onnx2torch coremltools "torch==2.7.0" numpy
    .venv-meikiocr/bin/python scripts/convert-meikiocr.py

ONNX goes to PyTorch (onnx2torch), then to Core ML (coremltools). The size input each model takes, which only scales
the boxes it outputs, is fixed to the model's own input size: boxes come out in input pixels. The models are kept
in 32-bit floats: in 16 bits they misread characters (badly when Core ML runs them on the CPU).
"""

import hashlib
import os
import sys
import urllib.request

import coremltools as ct
import numpy as np
import onnx
import onnx2torch
import torch
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as torch_ops
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from onnx2torch.node_converters.registry import add_converter
from onnx2torch.utils.common import OperationConverterResult, onnx_mapping_from_node

DETECTION = ("rtr46/meiki.text.detect.v0", "a9cffa4f60cbf72ddb87edf19c6f98a01cd042e6")
RECOGNITION = ("rtr46/meiki.txt.recognition.v0", "a28cf5874dc2438ebb1c86336be26bcec51e3375")
# (repository, file, SHA-256, output name, input width, input height, output names)
MODELS = [
    (DETECTION, "meiki.text.detect.v0.1.960x544.onnx",
     "40b6a016667745cae7d3055929ae3b8b1e7716aac795f5904cd3c2c7c3b8404b",
     "MeikiDetection", 960, 544, ["labels", "boxes", "scores"]),
    (RECOGNITION, "meiki.text.rec.v0.960x32.onnx",
     "3e96bc772fbee9717e536a6353032bb944c3382dd2f6960ef4890decda43b000",
     "MeikiRecognition", 960, 32, ["char_codes", "boxes", "scores"]),
    (RECOGNITION, "meiki.text.rec.v0.vertical.32x480.onnx",
     "2c2a83a23bc3b7e6c63962175f507ecc6c5e85cc174f17bdec37d9bbd0bf895a",
     "MeikiVerticalRecognition", 32, 480, ["char_codes", "boxes", "scores"]),
]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vendor", "meikiocr")


class GridSample(torch.nn.Module):
    def __init__(self, mode, padding_mode, align_corners):
        super().__init__()
        self.mode, self.padding_mode, self.align_corners = mode, padding_mode, align_corners

    def forward(self, x, grid):
        return torch.nn.functional.grid_sample(
            x, grid, mode=self.mode, padding_mode=self.padding_mode, align_corners=self.align_corners
        )


# onnx2torch has no GridSample; it's PyTorch's grid_sample.
@add_converter(operation_type="GridSample", version=16)
def _(node, graph):
    attributes = node.attributes
    module = GridSample(
        attributes.get("mode", "bilinear"),
        attributes.get("padding_mode", "zeros"),
        bool(attributes.get("align_corners", 0)),
    )
    return OperationConverterResult(torch_module=module, onnx_mapping=onnx_mapping_from_node(node))


# D-FINE's box refinement multiplies a matrix by a vector, which MIL's matmul doesn't take.
@register_torch_op(torch_alias=["bmm", "mm"], override=True)
def matmul(context, node):
    x, y = torch_ops._get_inputs(context, node, expected=2)
    if y.rank == 1:
        product = mb.matmul(x=x, y=mb.expand_dims(x=y, axes=[-1]))
        context.add(mb.squeeze(x=product, axes=[-1], name=node.name))
    else:
        context.add(mb.matmul(x=x, y=y, name=node.name))


class FixedSize(torch.nn.Module):
    """The model with its size input fixed, returning only TopK's values for its scores."""

    def __init__(self, net, width, height):
        super().__init__()
        self.net = net
        self.register_buffer("sizes", torch.tensor([[width, height]], dtype=torch.int64))

    def forward(self, images):
        return tuple(o[0] if isinstance(o, (list, tuple)) else o for o in self.net(images, self.sizes))


def download(repository, filename, sha256):
    (name, revision) = repository
    url = f"https://huggingface.co/{name}/resolve/{revision}/{filename}"
    print(f"downloading {url}")
    with urllib.request.urlopen(url) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"{filename}: unexpected checksum")
    return onnx.load_model_from_string(data)


def convert(graph, width, height, outputs):
    # Optional inputs left out with an empty name (e.g. Clip without a max) look like dynamic values to
    # onnx2torch: drop trailing ones, and give a missing Clip min a constant.
    for node in graph.graph.node:
        while node.input and node.input[-1] == "":
            node.input.pop()
        if node.op_type == "Clip" and len(node.input) > 1 and node.input[1] == "":
            name = node.name + "_min"
            graph.graph.initializer.append(onnx.numpy_helper.from_array(np.array(-np.inf, np.float32), name))
            node.input[1] = name
    model = FixedSize(onnx2torch.convert(graph).eval(), width, height).eval()
    example = torch.rand(1, 3, height, width)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, check_trace=False)
    return ct.convert(
        traced,
        inputs=[ct.TensorType(name="images", shape=example.shape)],
        outputs=[ct.TensorType(name=name) for name in outputs],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    for repository, filename, sha256, name, width, height, outputs in MODELS:
        model = convert(download(repository, filename, sha256), width, height, outputs)
        model.short_description = f"{filename} from huggingface.co/{repository[0]} ({repository[1][:7]}), converted"
        model.license = "LGPL-3.0"
        path = os.path.join(OUT, f"{name}.mlpackage")
        model.save(path)
        print(f"saved {path}")


if __name__ == "__main__":
    main()
