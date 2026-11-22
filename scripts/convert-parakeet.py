#!/usr/bin/env python3
"""Packages Parakeet TDT 0.6B v3 (speech recognition in 25 European languages) for MacPopup's "Read text from audio".

Downloads NVIDIA's Parakeet (CC BY 4.0: free to use with attribution) in FluidInference's Core ML build
(https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) and packs it into a zip. In MacPopup, load it in
Settings > Transcription > Parakeet models.

Languages: Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian,
Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish,
Ukrainian. It detects the language itself.

Needs Python 3 with huggingface_hub:
    python3 -m venv ~/parakeet-venv
    ~/parakeet-venv/bin/pip install huggingface_hub
    ~/parakeet-venv/bin/python scripts/convert-parakeet.py [-o Parakeet-CoreML.zip]
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

REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
REVISION = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
# Encoder_v2 is the int8 build FluidInference made after the first one garbled some words
# (https://github.com/FluidInference/FluidAudio/issues/760).
MODELS = {"Preprocessor.mlmodelc": "Preprocessor.mlmodelc", "Encoder_v2.mlmodelc": "Encoder.mlmodelc",
          "Decoder.mlmodelc": "Decoder.mlmodelc", "JointDecision.mlmodelc": "Joint.mlmodelc"}
LICENSE = "https://creativecommons.org/licenses/by/4.0/legalcode.txt"
ATTRIBUTION = """parakeet-tdt-0.6b-v3 by NVIDIA (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/, the licence's text is in LICENSE). Converted to Core ML by
FluidInference (https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml, README.md); the files are
renamed and repacked, not changed.
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="Parakeet-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()

    print(f"Downloading {REPO}", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION,
                                    allow_patterns=[f"{m}/*" for m in MODELS] + ["parakeet_vocab.json", "README.md"]))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "coreml").mkdir()
        for name, target in MODELS.items():
            shutil.copytree(source / name, root / "coreml" / target)
        # The tokens by id, as a list.
        pieces = json.loads((source / "parakeet_vocab.json").read_text())
        if sorted(map(int, pieces)) != list(range(len(pieces))):
            sys.exit("parakeet_vocab.json doesn't number its tokens from 0 without gaps.")
        (root / "vocab.json").write_text(json.dumps([pieces[str(i)] for i in range(len(pieces))], ensure_ascii=False))
        shutil.copyfile(source / "README.md", root / "README.md")
        # creativecommons.org refuses Python's own User-Agent.
        with urllib.request.urlopen(urllib.request.Request(LICENSE, headers={"User-Agent": "convert-parakeet.py"})) as response:
            (root / "LICENSE").write_bytes(response.read())
        (root / "ATTRIBUTION").write_text(ATTRIBUTION)
        (root / "parakeet.json").write_text(json.dumps(
            {"format": 1, "model": REPO, "revision": REVISION, "samples": 240000, "blank": 8192,
             "durations": [0, 1, 2, 3, 4]}, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > Parakeet models > Load, and pick this file.")


if __name__ == "__main__":
    main()
