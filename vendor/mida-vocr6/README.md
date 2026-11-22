The models of meikipop's "mida + VOCR6 (local)" OCR provider (https://github.com/rtr46/meikipop, as of commit
c5ca5b1), converted to Core ML by `scripts/convert-mida-vocr6.py` (with VOCR6.2-L's cell calibration as meikipop pull 131
refit it):

- MidaDetection: `mida_l_alpha_v0.0.2.onnx` (SHA-256 7a09988b…), the mida text line detector by rtr46, from
  https://huggingface.co/rtr46/mida. Its page states no licence.
- VOCR6Recognition, VOCR6Head.bin and MidaVOCR6.json's "horizontal": `VOCR6.2_L_fast.onnx` (SHA-256 3084fb3b…), the
  Large VOCR6.2 line recognizer of https://github.com/bee-san/vita-vn-ocr, from its pre-release v0.5.1-onnx.2, for
  horizontal lines.
- VOCR6VerticalRecognition, VOCR6VerticalHead.bin and MidaVOCR6.json's "vertical": `VOCR6_V_fast.onnx` (SHA-256
  080f0651…), vita-vn-ocr's VOCR6-V vertical column recognizer (`VOCR6_V_w8.vocr`, release v0.4.2-vertical6.1),
  converted to ONNX by rtr46 with vita-vn-ocr's own converter, from https://huggingface.co/rtr46/vocr6.

The Core ML recognizers end at the features of their heads; the .bin files hold the heads' weights (little-endian
floats: [96][characters], then a bias per character) and MidaVOCR6.json their characters, sizes, cell calibrations
and VOCR6.2-L's gate (MidaVOCR6.swift runs them).

VOCR6's weights are released under GPL-3.0-or-later, **for non-commercial use only**: the terms of their training
inputs (`VOCR6-ATTRIBUTION.md` and `VOCR6-V-ATTRIBUTION.md`, and `ONNX-ATTRIBUTION.md` for the ONNX files, from those
releases). They're separate files in the app (`Contents/Resources/Models`).

`Sources/OCREngines/MidaVOCR6.swift` follows the provider's `mida_detector.py` (its decode after vita-vn-ocr's and
mida's own), `line_crops.py` and `vocr_onnx.py` (vita-vn-ocr's `tools/vocr_onnx.py`), all GPL-3.0-or-later.
