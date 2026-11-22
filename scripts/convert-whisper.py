#!/usr/bin/env python3
"""Packages Whisper large-v3 turbo (speech recognition in 99 languages) for MacPopup's "Read text from audio".

Downloads OpenAI's Whisper (MIT licence) in Argmax's Core ML build (https://huggingface.co/argmaxinc/whisperkit-coreml)
and packs it into a zip. In MacPopup, load it in Settings > Transcription > Whisper models.

The default is the compressed build (632 MB). --full is the full build (1.6 GB): slightly more accurate, same speed.
The audio encoder's attention is rewritten to take each head in one piece (see merge_attention_pieces), so that Core ML
prepares it for the Neural Engine in under 3 minutes rather than 10 (M1 Max).

Needs Python 3 with huggingface_hub:
    python3 -m venv ~/whisper-venv
    ~/whisper-venv/bin/pip install huggingface_hub
    ~/whisper-venv/bin/python scripts/convert-whisper.py [--full] [-o Whisper-CoreML.zip]
"""

import argparse
import json
import re
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

OP = re.compile(r"^(\s*)tensor<(\w+), \[([\d, ]*)\]> (\w+) = (\w+)\((.*)$")
IDENTIFIER = re.compile(r"[A-Za-z_]\w*")
STRING = re.compile(r'"[^"]*"')


def merge_attention_pieces(program):
    """Rewrites the audio encoder's program (model.mil) so that each attention head attends in one piece.

    Argmax's encoder splits each head's attention along the audio as well (whisperkittools' SplitHeadsQ): 4 pieces of
    375 frames, each through einsum, scale, softmax and einsum, then concatenated. Core ML's first preparation of that
    for the Neural Engine takes about 10 minutes (M1 Max); in one piece per head, under 3, and it runs faster. The
    first piece's ops are widened to the whole audio, the concatenation becomes an identity, and the other pieces are
    left out. The weights don't change, and on the CPU the output is identical.
    """
    lines = program.split("\n")
    ops = {}  # output name: (line, op, shape)
    for index, line in enumerate(lines):
        if m := OP.match(line):
            ops[m[4]] = (index, m[5], [int(x) for x in m[3].split(", ")] if m[3] else [])

    def call(name):
        return OP.match(lines[ops[name][0]])[6].split(")[name")[0]

    def argument(name, key):
        return re.search(rf"\b{key} = (\w+)", call(name))[1]

    def values(name):
        return re.search(r"values = \(([^)]*)\)", call(name))[1].split(", ")

    def widen(name, length):
        index, _, shape = ops[name]
        old, new = (f"[{', '.join(map(str, s))}]>" for s in (shape, shape[:-1] + [length]))
        lines[index] = lines[index].replace(old, new, 1)

    merged = 0
    for name, (index, op, shape) in list(ops.items()):
        pieces = values(name) if op == "concat" else []
        if len(pieces) < 2 or not all(ops.get(p, (0, ""))[1] == "einsum" for p in pieces):
            continue
        # The first piece: einsum(value, softmax(mul(einsum(key, slice_by_index(query)), scale)))
        out = pieces[0]
        value, probabilities = values(out)
        scaled = argument(probabilities, "x")
        weights = argument(scaled, "x")
        key, piece = values(weights)
        query = argument(piece, "x")
        kinds = [ops[n][1] for n in (probabilities, scaled, weights, piece)]
        if kinds != ["softmax", "mul", "einsum", "slice_by_index"] or ops[query][2][-1] != shape[-1]:
            sys.exit("The audio encoder isn't laid out as this script expects.")
        weights_line = ops[weights][0]
        lines[weights_line] = lines[weights_line].replace(f"({key}, {piece})", f"({key}, {query})", 1)
        for n in (weights, scaled, probabilities, out):
            widen(n, shape[-1])
        m = OP.match(lines[index])
        lines[index] = f'{m[1]}tensor<{m[2]}, [{m[3]}]> {name} = identity(x = {out})' \
            f'[name = tensor<string, []>("{name}")];'
        merged += 1
    if merged == 0:
        sys.exit("The audio encoder has no attention split along the audio.")

    # Leaves out what nothing uses any more: the other pieces, and their constants.
    while True:
        used = set()
        for line in filter(None, lines):
            m = OP.match(line)
            used.update(IDENTIFIER.findall(STRING.sub("", m[6] if m else line)))
        unused = [name for name, (index, _, _) in ops.items() if name not in used and lines[index] is not None]
        if not unused:
            break
        for name in unused:
            lines[ops[name][0]] = None
    return "\n".join(line for line in lines if line is not None)


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
        program = models / "AudioEncoder.mlmodelc" / "model.mil"
        program.write_text(merge_attention_pieces(program.read_text()))
        for name in ["tokenizer.json", "tokenizer_config.json"]:
            shutil.copyfile(hf_hub_download(TOKENIZER_REPO, name, revision=TOKENIZER_REVISION), models / name)
        (root / "whisper.json").write_text(json.dumps(
            {"format": 1, "model": f"{REPO}/{build}", "revision": REVISION, "full": a.full, "license": "MIT",
             "encoderOnNeuralEngine": True}, indent=1))
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
