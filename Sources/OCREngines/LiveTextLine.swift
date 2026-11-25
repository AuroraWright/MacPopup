import CoreGraphics
import LiveText

extension RecognizedLine {
    /// A line Live Text read (MPLiveText), with its corners.
    public init(_ item: MPLiveTextItem) {
        self.init(text: item.text, box: item.box, words: item.words.map { ($0.text, $0.box) },
                  corners: [item.topLeft, item.topRight, item.bottomRight, item.bottomLeft])
    }
}
