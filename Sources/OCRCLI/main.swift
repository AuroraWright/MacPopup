// ocr-cli read <engine> <list> <pictures folder> <output folder> [--limit count] [--cpu] [--language code]:
// reads each picture in <list> (paths relative to <pictures folder>, one per line) with one of the app's OCR engines
// (liveText, screenAI, oneOCR, meikiocr, ppocrManga, midaVOCR6) and writes what it read, before OCR mode's layout, to
// <output folder>/<engine>/<path>.json: the app's read-N-areaK.json format, [{"text", "box": [x, y, width, height],
// "words": [[text, x, y, width, height]]}], boxes normalized to the picture, origin at the top left. Live Text reads
// Japanese and English, as OCR mode does with Japanese as the language. Screen AI's and oneocr's models from
// MACPOPUP_MODELS_DIRECTORY (or Application Support's), the others' from MACPOPUP_BUNDLED_MODELS_DIRECTORY (e.g. an
// app's Contents/Resources/Models). For the test corpus (test-corpus/tools).
//   --cpu runs the Core ML models on the CPU only (OCRCompute.cpuOnly, as the app's crash guard does).
//   --language gives Screen AI OCR mode's language (an ISO code of Yomitan's), as the app does: it then only uses the
//   script recognizers that language needs (OCRLanguage.screenAIRecognizers). Without it, all of them.
// Pictures that already have a reading are skipped, so a run can be stopped and started again. Failures go to
// <output folder>/<engine>/failures.txt.
//
// For checking the ports against the originals when Google's or Microsoft's engines change:
//
// ocr-cli screenai-stages <models dir> <out dir> <image>...: Screen AI's stage layouts, as the C++ port dumps them.
//
// ocr-cli oneocr crt <function> <in> <out> | detect <models> <out.json> <image.bgr>... |
//   recnet <models> <char model> <line.bgr>... | scores <models> <conf|rej> <name> <in> <out> |
//   ocr <models> <out.json> <image.bgr>...: oneocr's pieces, as the Python reimplementation runs them.
import Foundation
import OCREngines

// MACPOPUP_MODELS_DIRECTORY and MACPOPUP_BUNDLED_MODELS_DIRECTORY, as in a development build of the app.
DevelopmentEnvironment.enabled = true

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: ocr-cli read liveText|screenAI|oneOCR|meikiocr|ppocrManga|midaVOCR6 <list> <pictures folder> <output folder> [--limit count] [--cpu] [--language code]
           ocr-cli screenai-stages <models dir> <out dir> <image>...
           ocr-cli oneocr crt <function> <in> <out>
           ocr-cli oneocr detect <models> <out.json> <image.bgr>...
           ocr-cli oneocr recnet <models> <char model> <line.bgr>...
           ocr-cli oneocr scores <models> <conf|rej> <name> <in> <out>
           ocr-cli oneocr ocr <models> <out.json> <image.bgr>...

    """.utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "read": try await read(Array(arguments.dropFirst()))
    case "screenai-stages": try screenAIStages(Array(arguments.dropFirst()))
    case "oneocr": try oneOCRChecks(Array(arguments.dropFirst()))
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
