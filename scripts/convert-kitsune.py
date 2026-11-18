#!/usr/bin/env python3
"""Converts Kitsune-Transcribe P-0.3B (Japanese speech recognition) for MacPopup's "Read text from audio".

Kitsune (https://huggingface.co/Multy123/kitsune-transcribe-p0.3b-ja, by Multy123) is free for non-commercial use only
(CC BY-NC 4.0), so it can't come with MacPopup. This script downloads it and converts it into a zip. In MacPopup,
load it in Settings > Transcription > Kitsune models.

Needs Python 3.10-3.12:
    python3 -m venv ~/kitsune-venv
    ~/kitsune-venv/bin/pip install torch "transformers>=5.13" "coremltools>=9" huggingface_hub numpy
    ~/kitsune-venv/bin/python scripts/convert-kitsune.py [-o Kitsune-CoreML.zip]
"""
# How the conversion works:
# The model is the encoder and CTC head, in 16-bit floats, as one Core ML model with a function per input length
# ("b512" ... "b3008", in 10 ms feature frames, up to 30 s): MacPopup pads the features to the shortest that fits.
# Its inputs are the features and the number of valid frames, from which it makes the padding mask. The mask's value
# for padding is -10000 rather than the lowest float, which in 16-bit floats is -infinity and makes rows of padding
# NaN. Each length is its own fixed-shape function because a model with flexible input shapes keeps its shape
# arithmetic, which Core ML then runs entirely on the CPU. MacPopup computes the log-mel features itself; the zip has
# the mel filters (mel.bin, 80 x 257 float32) and the vocabulary (vocab.json, with the special tokens empty).


import argparse
import inspect
import math
import json
import shutil
import sys
import tempfile
import textwrap
import zipfile
from pathlib import Path

try:
    import numpy as np
    import torch
    import coremltools as ct
    from huggingface_hub import snapshot_download
    from transformers import AutoProcessor, ParakeetForCTC
    from transformers.models.parakeet import modeling_parakeet
except ImportError as e:
    sys.exit(f"{e.name} is missing. Install the requirements first:\n"
             '    pip install torch "transformers>=5.13" "coremltools>=9" huggingface_hub numpy')

REPO = "Multy123/kitsune-transcribe-p0.3b-ja"
REVISION = "f549ad62827458caf06394296cd4213f3e977c93"
# Input lengths in feature frames (10 ms each): 5.1, 10.2, 20.5 and 30 s.
BUCKETS = [512, 1024, 2048, 3008]


def patch_mask_value():
    """Replaces the attention's padding mask value (the lowest float) with -10000."""
    source = textwrap.dedent(inspect.getsource(modeling_parakeet.ParakeetEncoderAttention.forward))
    old = "torch.finfo(matrix_bd.dtype).min"
    if source.count(old) != 1:
        sys.exit("This version of transformers' Parakeet attention isn't the one this script patches.")
    scope = dict(vars(modeling_parakeet))
    exec(source.replace(old, "-1e4"), scope)
    modeling_parakeet.ParakeetEncoderAttention.forward = scope["forward"]


class Encoder(torch.nn.Module):
    """Features and the number of valid frames to logits."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_features, length):
        mask = (torch.arange(input_features.shape[1], dtype=torch.int32)[None, :] < length[:, None]).long()
        return self.model(input_features=input_features, attention_mask=mask).logits


def convert(model, root, parts):
    encoder = Encoder(model).eval()
    descriptor = ct.utils.MultiFunctionDescriptor()
    for frames in BUCKETS:
        print(f"Encoder for {frames} frames", flush=True)
        example = (torch.randn(1, frames, 80), torch.tensor([frames - 100], dtype=torch.int32))
        traced = torch.jit.trace(encoder, example, check_trace=False)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input_features", shape=(1, frames, 80), dtype=np.float32),
                    ct.TensorType(name="length", shape=(1,), dtype=np.int32)],
            outputs=[ct.TensorType(name="logits", dtype=np.float32)],
            convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS15, skip_model_load=True)
        path = parts / f"b{frames}.mlpackage"
        mlmodel.save(str(path))
        descriptor.add_function(str(path), src_function_name="main", target_function_name=f"b{frames}")
    descriptor.default_function_name = f"b{BUCKETS[0]}"
    ct.utils.save_multifunction(descriptor, str(root / "coreml" / "Kitsune.mlpackage"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="Kitsune-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()

    print(f"Downloading {REPO}", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION, allow_patterns=[
        "config.json", "generation_config.json", "model.safetensors", "processor_config.json", "tokenizer.json",
        "tokenizer_config.json", "LICENSE*", "README.md"]))
    patch_mask_value()
    processor = AutoProcessor.from_pretrained(source)
    model = ParakeetForCTC.from_pretrained(source, dtype=torch.float32, attn_implementation="eager").eval()
    features = processor.feature_extractor
    expected = dict(feature_size=80, sampling_rate=16000, hop_length=160, n_fft=512, win_length=400, preemphasis=0.97)
    if any(getattr(features, k) != v for k, v in expected.items()):
        sys.exit(f"The model's features aren't the ones MacPopup computes: {expected}")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "zip"
        parts = Path(tmp) / "parts"
        (root / "coreml").mkdir(parents=True)
        parts.mkdir()
        with torch.no_grad():
            convert(model, root, parts)

        # The mel filters as [80][257], row by row.
        mel = np.ascontiguousarray(features.mel_filters.numpy().astype("<f4"))
        assert mel.shape == (80, 257), mel.shape
        (root / "mel.bin").write_bytes(mel.tobytes())
        tokenizer = json.loads((source / "tokenizer.json").read_text("utf-8"))
        pieces = {piece: index for piece, index in tokenizer["model"]["vocab"].items()}
        vocab = [""] * model.config.vocab_size
        for piece, index in pieces.items():
            vocab[index] = piece
        # Special tokens (<unk>, <blank>) aren't text.
        for token in tokenizer["added_tokens"]:
            vocab[token["id"]] = ""
        (root / "vocab.json").write_text(json.dumps(vocab, ensure_ascii=False))
        for path in sorted(source.glob("LICENSE*")) + [source / "README.md"]:
            shutil.copyfile(path, root / path.name)
        encoder = model.config.encoder_config
        (root / "kitsune.json").write_text(json.dumps({
            "format": 1, "model": REPO, "revision": REVISION, "buckets": BUCKETS,
            "blank": processor.tokenizer.convert_tokens_to_ids(processor.blank_token),
            # The encoder's output length: frames = floor((frames + 2 * ((kernel - 1) // 2) - kernel) / stride + 1), once
            # per layer.
            "subsampling": {"kernel": encoder.subsampling_conv_kernel_size, "stride": encoder.subsampling_conv_stride,
                            "layers": int(math.log2(encoder.subsampling_factor))},
            "preemphasis": features.preemphasis, "nFFT": features.n_fft, "window": features.win_length,
            "hop": features.hop_length, "sampleRate": features.sampling_rate,
        }, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > Kitsune models > Load, and pick this file.")


if __name__ == "__main__":
    main()
