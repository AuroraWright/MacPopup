The models of meikipop's "mida + VOCR6 (local)" OCR provider (https://github.com/rtr46/meikipop, pull request 131),
converted to Core ML by `scripts/convert-mida-vocr6.py`:

- MidaDetection: `mida_l_alpha_v0.0.1.onnx` (SHA-256 9f72bce5…), the mida text line detector by rtr46, from
  https://huggingface.co/rtr46/mida. Its page states no licence.
- VOCR6Recognition, VOCR6Head.bin and MidaVOCR6.json: `VOCR6.2_L_fast.onnx` (SHA-256 3084fb3b…), the Large VOCR6.2
  line recognizer of https://github.com/bee-san/vita-vn-ocr, from its pre-release v0.5.1-onnx.2. The Core ML model ends
  at the features of the recognizer's head; VOCR6Head.bin holds the head's weights (little-endian floats: [96][5631],
  then 5631 biases) and MidaVOCR6.json its characters, sizes and gate (MidaVOCR6.swift runs it).

VOCR6's weights are released under GPL-3.0-or-later, **for non-commercial use only**: the terms of their training
inputs (`VOCR6-ATTRIBUTION.md`, and `ONNX-ATTRIBUTION.md` for the ONNX files, both from that release). They're
separate files in the app (`Contents/Resources/Models`).

`Sources/OCREngines/MidaVOCR6.swift` follows the provider's `mida_detector.py` (its decode from vita-vn-ocr's
`eval/mida_det.py`) and `vocr_onnx.py` (vita-vn-ocr's `tools/vocr_onnx.py`), both GPL-3.0-or-later, with the
provider's character cell calibration.
