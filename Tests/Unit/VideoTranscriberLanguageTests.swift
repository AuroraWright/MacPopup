// Whether an IINA video's subtitle track is in the language read (VideoTranscriber.isLanguage), which decides if the
// video is transcribed: tracks by ISO 639-1 or -2 code, and ones without a language known, in the video or added as a
// file.
import Testing
@testable import MacPopup

@MainActor
@Test(arguments: [
    // A track's code, either form, against Yomitan's language codes.
    ("ja", "ja", true), ("jpn", "ja", true), ("eng", "en", true), ("en", "en", true),
    ("en", "ja", false), ("eng", "ja", false), ("jpn", "en", false), ("zho", "zh", true), ("chi", "ja", false),
    // No language known, in the video: English.
    ("", "en", true), ("", "ja", false), ("und", "en", true), ("und", "ja", false), ("xx", "ja", false), ("xx", "en", true),
])
func aVideosTrack(track: String, language: String, matches: Bool) {
    #expect(VideoTranscriber.isLanguage(track, language) == matches)
}

@MainActor
@Test(arguments: [
    // A subtitle file without a language known: the language read.
    ("", "ja", true), ("", "en", true), ("und", "ja", true), ("xx", "ja", true),
    // With one, it's that.
    ("ja", "ja", true), ("eng", "ja", false), ("jpn", "en", false),
])
func aSubtitleFile(track: String, language: String, matches: Bool) {
    #expect(VideoTranscriber.isLanguage(track, language, unknown: true) == matches)
}
