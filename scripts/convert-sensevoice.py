#!/usr/bin/env python3
"""Packages SenseVoice Small (speech recognition in Chinese, Cantonese, Japanese, Korean and English) for MacPopup's
"Read text from audio".

Downloads Alibaba's SenseVoice Small (FunASR model licence: free to use with attribution) in FluidInference's Core ML
build (https://huggingface.co/FluidInference/sensevoice-small-coreml) and packs it into a zip. In MacPopup, load it in
Settings > Transcription > SenseVoice models.

Needs Python 3 with huggingface_hub:
    python3 -m venv ~/sensevoice-venv
    ~/sensevoice-venv/bin/pip install huggingface_hub
    ~/sensevoice-venv/bin/python scripts/convert-sensevoice.py [-o SenseVoice-CoreML.zip]
"""

import argparse
import json
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

try:
    from huggingface_hub import snapshot_download
except ImportError:
    sys.exit("huggingface_hub is missing. Install it first:\n    pip install huggingface_hub")

REPO = "FluidInference/sensevoice-small-coreml"
REVISION = "74bdbe74b2258f25b5400db72f6cbfbef7c74ded"
MODELS = ["SenseVoicePreprocessor.mlmodelc", "SenseVoiceSmall_int8.mlmodelc"]
LICENSE = "https://raw.githubusercontent.com/modelscope/FunASR/main/MODEL_LICENSE"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="SenseVoice-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()

    print(f"Downloading {REPO}", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION,
                                    allow_patterns=[f"{m}/*" for m in MODELS] + ["vocab.json", "README.md"]))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "coreml").mkdir()
        for name in MODELS:
            shutil.copytree(source / name, root / "coreml" / name)
        shutil.copyfile(source / "vocab.json", root / "vocab.json")
        shutil.copyfile(source / "README.md", root / "README.md")
        with urllib.request.urlopen(LICENSE) as response:
            (root / "MODEL_LICENSE").write_bytes(response.read())
        (root / "sensevoice.json").write_text(json.dumps(
            {"format": 1, "model": REPO, "revision": REVISION, "buckets": [128, 256, 512, 1024, 1800]}, indent=1))
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
