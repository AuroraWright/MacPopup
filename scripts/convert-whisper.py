#!/usr/bin/env python3
"""Packages Whisper large-v3 turbo (speech recognition in 99 languages) for MacPopup's "Read text from audio".

Downloads OpenAI's Whisper (MIT licence) in Argmax's Core ML build (https://huggingface.co/argmaxinc/whisperkit-coreml)
and packs it into a zip. In MacPopup, load it in Settings > Transcription > Whisper models.

The default is the compressed build (632 MB). --full is the full build (1.6 GB): slightly more accurate, same speed.

Needs Python 3 with huggingface_hub:
    python3 -m venv ~/whisper-venv
    ~/whisper-venv/bin/pip install huggingface_hub
    ~/whisper-venv/bin/python scripts/convert-whisper.py [--full] [-o Whisper-CoreML.zip]
"""

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

try:
    from huggingface_hub import hf_hub_download, snapshot_download
except ImportError:
    sys.exit("huggingface_hub is missing. Install it first:\n    pip install huggingface_hub")

REPO = "argmaxinc/whisperkit-coreml"
REVISION = "0f63a7800b00dd0226abd051b906c246e1907482"
BUILDS = {False: "openai_whisper-large-v3-v20240930_turbo_632MB", True: "openai_whisper-large-v3-v20240930_turbo"}
TOKENIZER_REPO = "openai/whisper-large-v3-turbo"
TOKENIZER_REVISION = "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--full", action="store_true", help="the full 1.6 GB build instead of the compressed one")
    ap.add_argument("-o", "--output", default="Whisper-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()
    build = BUILDS[a.full]

    print(f"Downloading {build} from {REPO}", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION, allow_patterns=[f"{build}/*"])) / build
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        models = root / "coreml"
        shutil.copytree(source, models)
        for name in ["tokenizer.json", "tokenizer_config.json"]:
            shutil.copyfile(hf_hub_download(TOKENIZER_REPO, name, revision=TOKENIZER_REVISION), models / name)
        (root / "whisper.json").write_text(json.dumps(
            {"format": 1, "model": f"{REPO}/{build}", "revision": REVISION, "full": a.full, "license": "MIT"}, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > Whisper models > Load, and pick this file.")


if __name__ == "__main__":
    main()
