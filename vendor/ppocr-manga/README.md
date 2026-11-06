The text detection and recognition models of [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga), by
Kellenok (fine-tuned from PaddlePaddle's PP-OCRv6 tiny detector and small recognizer for manga and anime), converted
to Core ML by `scripts/convert-ppocr-manga.py`:

- PPOCRMangaDetection: det/manga_det.onnx (v0.3)
- PPOCRMangaRecognition: rec/manga_rec.onnx (v0.3)
- PPOCRMangaCharacters.txt: ppocrv6_dict.txt, the recognizer's characters

from https://huggingface.co/Kellenok/PP-OCRv6_manga at revision d65838996a00ef6b1c73ca3a700d7a8c5fbbef8a (the
repository's optional language model, lm/manga_lm.npz, which it calls experimental, isn't used). They're licensed
under the Apache License 2.0 (`LICENSE`). They're separate files in the app (`Contents/Resources/Models`).

`Sources/MacPopup/PPOCRManga.swift` follows the repository's examples/onnx_openvino.py, with the widening its
README recommends.
