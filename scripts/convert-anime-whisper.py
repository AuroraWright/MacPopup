#!/usr/bin/env python3
"""Converts anime-whisper (Japanese speech recognition for games and anime) for MacPopup's "Read text from audio".

anime-whisper (https://huggingface.co/litagin/anime-whisper, by litagin, MIT licence) has no Core ML version, so this
script converts it on your Mac into a zip. In MacPopup, load it in Settings > Transcription > anime-whisper models.

Needs Python 3.11 (whisperkittools pins its own versions of torch and transformers):
    python3.11 -m venv ~/whisperkit-venv
    ~/whisperkit-venv/bin/pip install "whisperkit @ git+https://github.com/argmaxinc/whisperkittools@84f77a83c8f530022ae55fbb1a64b3351ef63c7a"
    ~/whisperkit-venv/bin/python scripts/convert-anime-whisper.py [-o AnimeWhisper-CoreML.zip]
"""
# How the conversion works:
# whisperkittools converts with its tests, which check each converted model against PyTorch and only then keep it.
# They run on the CPU here. The audio encoder's attention is split per head but not along the audio
# (whisperkittools splits it into 256-frame pieces too): Core ML's first preparation of it for the Neural Engine then
# takes under 2 minutes rather than 15 or more (M1 Max), and it runs about as fast.
# anime-whisper's decoder keeps kotoba-whisper's 2 layers but its settings name word-timing attention heads of
# large-v3's 32, so word timings (which MacPopup doesn't use) are left out of the decoder. The tokenizer is Whisper
# large-v3's: anime-whisper has the same vocabulary but only the older tokenizer files, and WhisperKit reads
# tokenizer.json.


import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from types import SimpleNamespace

try:
    import coremltools as ct
    from argmaxtools import _sdpa, test_utils
    from huggingface_hub import hf_hub_download, snapshot_download
    from tests import test_audio_encoder, test_text_decoder
except ImportError as e:
    sys.exit(f"{e.name} is missing. Install the requirements first:\n"
             '    pip install "whisperkit @ git+https://github.com/argmaxinc/whisperkittools'
             '@84f77a83c8f530022ae55fbb1a64b3351ef63c7a"')

REPO = "litagin/anime-whisper"
REVISION = "22e2008a8182b357da3922a6308d095008f72973"
TOKENIZER_REPO = "openai/whisper-large-v3"
TOKENIZER_REVISION = "06f233fe06e710322aca913c1bc4249a0d71fce1"
MODELS = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="AnimeWhisper-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()

    print(f"Downloading {REPO}", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION))
    test_utils.TEST_COMPUTE_UNIT = ct.ComputeUnit.CPU_ONLY
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "zip"
        models = root / "coreml"
        models.mkdir(parents=True)
        # whisperkittools' command line (scripts/generate_model.py), with word timings off.
        args = SimpleNamespace(
            model_version=str(source), test_model_version=str(source), persistent_cache_dir=str(models),
            generate_quantized_variants=False, palettizer_tests=False, generate_decoder_context_prefill_data=False,
            context_prefill_tests=False, disable_default_tests=False, allowed_nbits=[], outlier_decomp=False,
            palettization_group_size=None, force_recipe_nbits=False, disable_token_timestamps=True,
            test_seq_len=None, sdpa_implementation="Cat", melspectrogram_tests=False)
        print("Text decoder", flush=True)
        test_text_decoder.main(args)
        print("Audio encoder", flush=True)
        args.sdpa_implementation = "SplitHeadsQ"
        _sdpa.SplitHeadsQ.chunk_size = 1500  # Whisper's 30 s of audio: one piece
        args.melspectrogram_tests = True
        test_audio_encoder.main(args)
        for name in MODELS:
            if not (models / f"{name}.mlmodelc").is_dir():
                sys.exit(f"The {name} model wasn't converted, or didn't match PyTorch (see the errors above).")
        for path in models.iterdir():
            if path.name not in {f"{name}.mlmodelc" for name in MODELS}:
                shutil.rmtree(path) if path.is_dir() else path.unlink()

        for name in ["config.json", "generation_config.json"]:
            shutil.copyfile(source / name, models / name)
        for name in ["tokenizer.json", "tokenizer_config.json"]:
            shutil.copyfile(hf_hub_download(TOKENIZER_REPO, name, revision=TOKENIZER_REVISION), models / name)
        shutil.copyfile(source / "README.md", root / "README.md")
        (root / "animewhisper.json").write_text(json.dumps(
            {"format": 1, "model": REPO, "revision": REVISION, "license": "MIT", "encoderOnNeuralEngine": True},
            indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > anime-whisper models > Load, and pick this file.")


if __name__ == "__main__":
    main()
