The text detection and recognition models of [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga), by
Kellenok (fine-tuned from PaddlePaddle's PP-OCRv6 tiny detector and small recognizer for manga and anime), converted
to Core ML by `scripts/convert-ppocr-manga.py`:

- PPOCRMangaDetection: det/manga_det_v0.2.onnx
- PPOCRMangaRecognition: rec/manga_rec_v0.2.onnx
- PPOCRMangaCharacters.txt: ppocrv6_dict.txt, the recognizer's characters

from https://huggingface.co/Kellenok/PP-OCRv6_manga at revision 02af751fcea728fba69ee421a95838f3e549daa2. They're
licensed under the Apache License 2.0 (`LICENSE`). They're separate files in the app (`Contents/Resources/Models`).

`Sources/MacPopup/PPOCRManga.swift` follows the repository's examples/onnx_openvino.py.
