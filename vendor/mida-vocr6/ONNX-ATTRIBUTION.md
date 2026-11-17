# ONNX files of VOCR6.2 and textspot8 (vita-vn-ocr pre-release v0.5.1-onnx.2): licences and attribution

`VOCR6.2_S_exact.onnx`, `VOCR6.2_S_fast.onnx`, `VOCR6.2_N_exact.onnx`, `VOCR6.2_N_fast.onnx`, `VOCR6.2_L_exact.onnx`
and `VOCR6.2_L_fast.onnx` are conversions of release v0.5.0's int8 recognizers `VOCR6.2_S_w8.vocr`,
`VOCR6.2_N_w8g2.vocr` and `VOCR6.2_L_w8_2l.vocr`; `textspot8_exact.onnx` and `textspot8_int8.onnx` of its line
spotter `textspot8_t64n8c16_w8.vtsp`. They hold the same int8 weights (and the blobs' head gate and two-level head),
written into ONNX graphs by bee-san/vita-vn-ocr's `tools/export_onnx.py` (`docs/onnx.md`, issue #163). Nothing was
retrained, re-quantised or calibrated for them. The only numbers they add to the blobs' are in the recognizers'
metadata: the character-box calibration of `eval/charboxes_cal.json` (9 small integers per tier, fit on VOCR5 and
training-side lines, `docs/char-boxes.md`).

## The terms are the blobs' terms

- **Recognizers:** `VOCR6-ATTRIBUTION.md` (in this release, byte for byte from v0.5.0) lists what the weights were
  trained on and their licences.
- **Spotter:** `SPOTTER-ATTRIBUTION.md` (in this release, byte for byte from v0.5.0).
- **The character LM** `vocr_lm6_o3_1000k.vlm` (byte for byte from v0.5.0, first published on v0.3.7-lm6.2):
  `LM-ATTRIBUTION.md` (CC BY-SA 4.0 and its own sources).

The weights are released under the repository's licence (GPL-3.0-or-later), subject to the non-commercial terms of
their training inputs. **Use these files for non-commercial purposes only.** The training inputs include the owner's
private captures of copyrighted games (native frames with each game's hooked text), used as training input only: no
frame, crop or running text of them is in any file of this release. The LM, `vocr_lm6_o3_1000k.vlm`, holds character
3-gram statistics of that hooked text (`LM-ATTRIBUTION.md`).

## Credit

The conversion method follows a report by astra, an outside researcher on the GameSentenceMiner side ("VOCR 6.2 and
textspot8: ONNX conversion and CPU precision findings", 2026-10-31): the int16 activations' base-256 digits through two
`MatMulInteger` calls, their int32 reconstruction, and float64 for the spotter's requantisation. vita-vn-ocr added the
convolutions in the C runtime's order (bit-identical logits), the head that skips the gated frames and the parity run
against the C runtime (`docs/onnx.md`).

## The code

`vocr_onnx.py` is bee-san/vita-vn-ocr's `tools/vocr_onnx.py` at this release's commit (GPL-3.0-or-later).
