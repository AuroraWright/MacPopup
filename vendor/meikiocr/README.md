The text detection and recognition models of [meikiocr](https://github.com/rtr46/meikiocr), by rtr46, converted
to Core ML by `scripts/convert-meikiocr.py`:

- MeikiDetection: meiki.text.detect.v0.1.960x544.onnx from https://huggingface.co/rtr46/meiki.text.detect.v0 at
  revision a9cffa4f60cbf72ddb87edf19c6f98a01cd042e6
- MeikiRecognition and MeikiVerticalRecognition: meiki.text.rec.v0.960x32.onnx and
  meiki.text.rec.v0.vertical.32x480.onnx from https://huggingface.co/rtr46/meiki.txt.recognition.v0 at revision
  a28cf5874dc2438ebb1c86336be26bcec51e3375

The models are licensed under the LGPL-3.0 (`LICENSE-models`). They're separate files in the app
(`Contents/Resources/Models`) and can be replaced with other versions taking the same inputs and outputs.

`Sources/OCREngines/MeikiOCR.swift` follows meikiocr's pipeline (meikiocr/ocr.py at commit
52aa607ecdc1038c7bf390f37cd9a8b306e8a08a), which is licensed under the Apache License 2.0 (`LICENSE-code`).
