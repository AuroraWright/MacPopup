#!/usr/bin/env python3
"""Converts SenseVoice Small (speech recognition in Chinese, Cantonese, Japanese, Korean and English) for MacPopup's
"Read text from audio".

Converts Alibaba's SenseVoice Small (https://huggingface.co/FunAudioLLM/SenseVoiceSmall, FunASR model licence: free to
use with attribution) on your Mac into a zip, with the feature extractor of FluidInference's Core ML build
(https://huggingface.co/FluidInference/sensevoice-small-coreml). In MacPopup, load it in Settings > Transcription >
SenseVoice models.

Needs Python 3.10-3.12:
    python3 -m venv ~/sensevoice-venv
    ~/sensevoice-venv/bin/pip install torch torchaudio funasr "coremltools>=9" huggingface_hub numpy
    ~/sensevoice-venv/bin/python scripts/convert-sensevoice.py [-o SenseVoice-CoreML.zip]
"""
# How the conversion works:
# The encoder and CTC head as FluidInference's build has them (the same inputs and outputs), traced from FunASR's
# model: the 4 query embeddings (language, event, emotion, text normalization) before the features, then the encoder
# and the CTC layer's logits. FunASR's encode() isn't traceable (random numbers, dictionaries), so this is its inference
# path. 16-bit floats, which only the Neural Engine runs without NaNs, and 8-bit weights (as accurate). The input
# lengths are those MacPopup sends, up to 30 seconds (60 ms feature frames); FluidInference's build also has 1024 and
# 1800, which made macOS's first preparation for the Neural Engine take 15 minutes instead of 1.5.

import argparse
import json
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

try:
    import numpy as np
    import torch
    import coremltools as ct
    from huggingface_hub import snapshot_download
    from funasr import AutoModel
except ImportError as e:
    sys.exit(f"{e.name} is missing. Install the requirements first:\n"
             '    pip install torch torchaudio funasr "coremltools>=9" huggingface_hub numpy')

REPO = "FunAudioLLM/SenseVoiceSmall"
REVISION = "3847d57b6bdf2dd8875cb1508d2af43d80a16bf7"
FEATURES_REPO = "FluidInference/sensevoice-small-coreml"
FEATURES_REVISION = "74bdbe74b2258f25b5400db72f6cbfbef7c74ded"
LICENSE = "https://raw.githubusercontent.com/modelscope/FunASR/main/MODEL_LICENSE"
# Input lengths in feature frames (60 ms each): 7.7, 15.4 and 30.7 s.
BUCKETS = [128, 256, 512]


class Encoder(torch.nn.Module):
    """FunASR's SenseVoiceSmall.inference up to the CTC logits, for one input."""

    def __init__(self, model):
        super().__init__()
        self.embed, self.encoder, self.ctc = model.embed, model.encoder, model.ctc.ctc_lo

    def forward(self, speech, speech_lengths, language, textnorm):
        # Language, then event and emotion (embeddings 1 and 2), then text normalization.
        queries = torch.cat([self.embed(language)[:, None], self.embed(torch.tensor([[1, 2]])),
                             self.embed(textnorm)[:, None]], dim=1)
        out, _ = self.encoder(torch.cat([queries, speech], dim=1), speech_lengths + 4)
        if isinstance(out, tuple):
            out = out[0]
        return self.ctc(out)


def convert(model, path):
    encoder = Encoder(model).eval()
    example = (torch.randn(1, BUCKETS[-1], 560), torch.tensor([300], dtype=torch.int32),
               torch.tensor([model.lid_dict["ja"]], dtype=torch.int32),
               torch.tensor([model.textnorm_dict["withitn"]], dtype=torch.int32))
    with torch.no_grad():
        traced = torch.jit.trace(encoder, example)
        if not torch.equal(traced(*example).argmax(-1), encoder(*example).argmax(-1)):
            sys.exit("The traced model doesn't match FunASR's.")
    print("Converting", flush=True)
    mlmodel = ct.convert(traced, inputs=[
            ct.TensorType("speech", shape=ct.EnumeratedShapes([[1, n, 560] for n in BUCKETS], default=[1, BUCKETS[-1], 560]),
                          dtype=np.float32),
            ct.TensorType("speech_lengths", shape=(1,), dtype=np.int32),
            ct.TensorType("language", shape=(1,), dtype=np.int32),
            ct.TensorType("textnorm", shape=(1,), dtype=np.int32)],
        outputs=[ct.TensorType("ctc_logits")], compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14)
    mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric")))
    mlmodel.save(str(path))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="SenseVoice-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()

    print(f"Downloading {REPO} and {FEATURES_REPO}", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION, allow_patterns=[
        "model.pt", "config.yaml", "am.mvn", "*.bpe.model", "configuration.json", "README.md"]))
    features = Path(snapshot_download(FEATURES_REPO, revision=FEATURES_REVISION, allow_patterns=[
        "SenseVoicePreprocessor.mlmodelc/*", "vocab.json"]))
    model = AutoModel(model=str(source), device="cpu", disable_update=True, disable_pbar=True, log_level="ERROR").model.eval()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "coreml").mkdir()
        convert(model, root / "coreml" / "SenseVoiceSmall_int8.mlpackage")
        shutil.copytree(features / "SenseVoicePreprocessor.mlmodelc", root / "coreml" / "SenseVoicePreprocessor.mlmodelc")
        shutil.copyfile(features / "vocab.json", root / "vocab.json")
        shutil.copyfile(source / "README.md", root / "README.md")
        with urllib.request.urlopen(LICENSE) as response:
            (root / "MODEL_LICENSE").write_bytes(response.read())
        (root / "sensevoice.json").write_text(json.dumps(
            {"format": 1, "model": REPO, "revision": REVISION, "features": FEATURES_REPO,
             "featuresRevision": FEATURES_REVISION, "buckets": BUCKETS}, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > SenseVoice models > Load, and pick this file.")


if __name__ == "__main__":
    main()
