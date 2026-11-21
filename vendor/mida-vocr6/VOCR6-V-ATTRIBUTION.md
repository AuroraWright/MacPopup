# VOCR6-V (vita-vn-ocr v0.4.2-vertical6.1): licences and attribution

`VOCR6_V_w8.vocr` holds the int8 weights of bee-san/vita-vn-ocr's CTC line recognizer (GPL-3.0-or-later code). It
reads vertical text: a column turned 90 degrees anticlockwise, in Rubi's vertical mode (`ocr_vertical`). It replaces
VOCR5-V (`VOCR5_V_w8.vocr`, release v0.3.2-vertical.1) and has VOCR5-V's shape. It is VOCR5-V's checkpoint
fine-tuned again (issue #159, `docs/vocr6v.md`), so it carries everything VOCR5-V was trained on (the first section)
plus the sources of the second.

## What VOCR5-V was trained on (v0.3.2-vertical.1's ATTRIBUTION.md, in short)

- **VOCR5-S**, VOCR5-V's starting point, and everything v0.3.0's ATTRIBUTION.md lists for it:
  - NVIDIA OCR-Synthetic-Multilingual-v1 (Chesler, 2026),
    https://huggingface.co/datasets/nvidia/OCR-Synthetic-Multilingual-v1, revision
    `69696a1cc543ef3a0f8e9892a89c17293e915263`, CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Its Japanese
    line crops were modified (cut from the pages, grey, height 32, out-of-vocabulary lines dropped). They are not
    redistributed.
  - The vocabulary `data/vocab_4987_proof.txt`, ordered by Jiten's word and kanji frequency lists
    (https://jiten.moe/frequency-dictionaries, CC BY-SA 4.0).
  - Synthetic dialogue boxes in the generators' `personal` profile. That profile includes:
    - fonts and texts free for non-commercial use only: JF Dot non-commercial and Zpix; JDD and NUCC (CC BY-NC-ND
      4.0); BSD (CC BY-NC-SA 4.0); Aratako's gpt-4o-mini roleplay (CC BY-NC-SA 4.0 and OpenAI's terms);
    - text of unclear licence (OpenSubtitles, なりきり posts);
    - two fonts the owner supplied.

    The full list is `data/manifests/synth3_text_sources.json`. The scenes are crops of training-side VNDB
    screenshots.
  - Real lines of PS Vita, PSP and scaled PC screenshots on VNDB (https://vndb.org; database ODbL 1.0, contents DbCL
    1.0). They were labelled by local OCR engines and reviewed by Claude (Anthropic), with a Codex second vote in
    realplus v3. The owner's earlier console captures (owner pools v1 and v2, private) were used too.
- **VOCR5-V's vertical data:**
  - synthetic vertical columns of the same `personal` profile;
  - vertical text columns of training-side VNDB screenshots, labelled by MeikiOCR and PP-OCRv6 small.

  The screenshots belong to their publishers and are not redistributed.

## What VOCR6-V adds

VOCR6-V was fine-tuned for 10,000 steps on:

- **The owner's hooked PS Vita corpus (private): one vertical title.** Yunohana SpRING! (PCSG00653, VNDB v17343) has
  863 native frames, labelled with the game's own hooked text and its column boxes (vita-vn-ocr #125,
  `docs/vocr6-data.md`). The run used all of them: train pages, hval pages and their guard bands. It used two forms
  of each column:
  - the column's box crop;
  - the column finder's own crop of the page, labelled from the hooked text (`data/vertical_hooked.py`).

  The frames and texts are the publisher's copyrighted game data, used as training input only. Nothing of them is
  redistributed; the repository holds ids, hashes and counts only.
- **New synthetic vertical columns.** `synth/vertical_render.py` generation 3, 400,000 crops
  (`data/manifests/vertical_shards_g3.json`), in the same `personal` profile as above. Its scene pools leave out every
  screenshot of the vertical development and test sets' VNs.
- **VOCR5-V's real VNDB columns** again (the agreed and the PP-OCRv6-small columns of #103).

**Manga109 and Manga109-s were not used by these weights.** The owner's Manga109 download (the dataset's
super-resolution version: volume covers only) was read for a check of the column finder. A candidate trained with 19
labelled columns of Manga109-s covers did not pass its pre-registered rule and was not released.

**Use these weights for non-commercial purposes only.** Two reasons:

- the synthetic inputs carry non-commercial terms;
- the hooked corpus is copyrighted game data, used for training only.

## Disclosures for test-set numbers

- Yunohana SpRING! is a test-cluster VN of vita-vn-ocr #103's vertical test set (one PS Vita page, 30 characters),
  and VOCR6-V trained on that game's hooked pages. That test page is a VNDB screenshot, not one of the owner's
  frames. Rubi's 1 MB LM (v0.3.7-lm6.2's `vocr_lm6_o3_1000k.vlm`) holds the hooked text of its pages too.
- *Black Jack ni Yoroshiku* (ブラックジャックによろしく 佐藤秀峰; free secondary use, https://densho810.com/free/) was
  used for evaluation only (development vol. 1, test vol. 13), as for VOCR5-V.
