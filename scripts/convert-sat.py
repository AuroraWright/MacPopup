#!/usr/bin/env python3
"""Converts SaT (Segment any Text, sat-3l-sm) for MacPopup's "Read text from audio": it finds where sentences end in
transcriptions without punctuation, so that lines end between sentences rather than at every pause.

SaT (https://huggingface.co/segment-any-text/sat-3l-sm, MIT licence) reads 85 languages; it uses XLM-RoBERTa's
tokenizer (https://huggingface.co/FacebookAI/xlm-roberta-base, MIT licence). This script converts it on your Mac into a
zip. In MacPopup, load it in Settings > Transcription > SaT models.

Needs Python 3.10-3.12:
    python3 -m venv ~/sat-venv
    ~/sat-venv/bin/pip install torch transformers "coremltools>=9" huggingface_hub safetensors numpy
    ~/sat-venv/bin/python scripts/convert-sat.py [-o SaT-CoreML.zip]
"""
# How the conversion works:
# SaT is XLM-RoBERTa with 3 layers and one output per token: where a sentence ends after it (sigmoid). Its word
# embeddings (250,002 x 768, nearly all of its weights) are written to embeddings.bin in 8 bits with a scale per row
# (float32 scales, then the int8 rows), and MacPopup looks up the rows itself; the Core ML model takes those embeddings
# and adds the rest (positions, layers, the output), with 16-bit weights, with the input padded to a fixed length. MacPopup tokenizes with tokenizer.json's
# unigram pieces (after NFKC, as the tokenizer's own normalization) and gives each token's output to its last
# character, as wtpsplit does.

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

try:
    import numpy as np
    import torch
    import coremltools as ct
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file
    from transformers import XLMRobertaConfig, XLMRobertaForTokenClassification
except ImportError as e:
    sys.exit(f"{e.name} is missing. Install the requirements first:\n"
             '    pip install torch transformers "coremltools>=9" huggingface_hub safetensors numpy')

REPO = "segment-any-text/sat-3l-sm"
REVISION = "137da054051ad9f1eac42025f758db4ac9f22535"
TOKENIZER_REPO = "FacebookAI/xlm-roberta-base"
TOKENIZER_REVISION = "e73636d4f797dec63c3081bb6ed5c7b0bb3f2089"
# Input lengths in tokens (with the start and end tokens): the embeddings are padded to the shortest that fits. Each
# length is a function of its own, loaded as its own model: with a flexible length or a set of lengths in one function,
# Core ML prepared the model again whenever the length changed (about 200 ms a text instead of 10-35).
BUCKETS = [32, 64, 128, 256, 512]


class Layers(torch.nn.Module):
    """The model from its word embeddings on: sentence end logits per token, for the first `length` (the rest is
    padding, which the attention leaves out)."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, embeddings, length):
        # Added to the attention scores: -10000 for padding (the lowest float would be -infinity in 16 bits).
        padding = (torch.arange(embeddings.shape[1])[None] >= length[:, None]).to(embeddings.dtype)
        return self.model(inputs_embeds=embeddings, attention_mask=(padding * -1e4)[:, None, None, :]).logits[..., 0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="SaT-CoreML.zip", help="the archive to write")
    a = ap.parse_args()
    output = Path(a.output).expanduser().resolve()

    print(f"Downloading {REPO} and {TOKENIZER_REPO}'s tokenizer", flush=True)
    source = Path(snapshot_download(REPO, revision=REVISION, allow_patterns=["config.json", "model.safetensors", "README.md"]))
    tokenizer = Path(snapshot_download(TOKENIZER_REPO, revision=TOKENIZER_REVISION, allow_patterns=["tokenizer.json"]))
    settings = json.loads((source / "config.json").read_text())
    if settings.get("lookahead") is not None or settings.get("num_labels", len(settings["id2label"])) != 1:
        sys.exit("This SaT model isn't the plain token classifier this script converts.")
    config = XLMRobertaConfig(**{k: v for k, v in settings.items() if k not in ("model_type", "architectures", "_name_or_path")})
    config._attn_implementation = "eager"
    model = XLMRobertaForTokenClassification(config).eval()
    model.load_state_dict(load_file(source / "model.safetensors"), strict=True)
    words = model.roberta.embeddings.word_embeddings.weight.detach().numpy().astype(np.float32)

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "zip"
        (root / "coreml").mkdir(parents=True)
        ids = [0, 6, 9, 2]
        example = torch.zeros(1, BUCKETS[0], config.hidden_size)
        example[0, :len(ids)] = torch.from_numpy(words[ids])
        with torch.no_grad():
            traced = torch.jit.trace(Layers(model).eval(), (example, torch.tensor([len(ids)], dtype=torch.int32)))
            padded = traced(example, torch.tensor([len(ids)], dtype=torch.int32))[:, :len(ids)]
            if not torch.allclose(padded, model(input_ids=torch.tensor([ids])).logits[..., 0], atol=1e-4):
                sys.exit("The traced model doesn't match the original.")
        descriptor = ct.utils.MultiFunctionDescriptor()
        parts = Path(tmp) / "parts"
        parts.mkdir()
        for tokens in BUCKETS:
            print(f"Model for {tokens} tokens", flush=True)
            mlmodel = ct.convert(traced, inputs=[
                    ct.TensorType("embeddings", shape=(1, tokens, config.hidden_size), dtype=np.float32),
                    ct.TensorType("length", shape=(1,), dtype=np.int32)],
                outputs=[ct.TensorType("logits", dtype=np.float32)], compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.macOS15, skip_model_load=True)
            path = parts / f"b{tokens}.mlpackage"
            mlmodel.save(str(path))
            descriptor.add_function(str(path), src_function_name="main", target_function_name=f"b{tokens}")
        descriptor.default_function_name = f"b{BUCKETS[0]}"
        ct.utils.save_multifunction(descriptor, str(root / "coreml" / "SaT.mlpackage"))

        # Each row in 8 bits with its own scale.
        scales = np.maximum(np.abs(words).max(axis=1), 1e-8) / 127
        rows = np.clip(np.rint(words / scales[:, None]), -127, 127).astype(np.int8)
        with open(root / "embeddings.bin", "wb") as f:
            f.write(scales.astype("<f4").tobytes())
            f.write(rows.tobytes())
        shutil.copyfile(tokenizer / "tokenizer.json", root / "tokenizer.json")
        shutil.copyfile(source / "README.md", root / "README.md")
        (root / "sat.json").write_text(json.dumps({
            "format": 1, "model": REPO, "revision": REVISION, "tokenizer": TOKENIZER_REPO,
            "tokenizerRevision": TOKENIZER_REVISION, "buckets": BUCKETS, "vocabulary": words.shape[0],
            "hidden": words.shape[1], "start": config.bos_token_id, "end": config.eos_token_id}, indent=1))
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > SaT models > Load, and pick this file.")


if __name__ == "__main__":
    main()
