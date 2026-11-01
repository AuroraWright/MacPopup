import Foundation
import VisionKit

/// A choice in a menu: the stored value and its label.
struct SettingsOption: Hashable {
    let value: String
    let label: String

    init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

struct SettingsField: Identifiable {
    enum Kind {
        case checkbox
        /// An on/off setting shown as two choices side by side.
        case toggleChoice(off: String, on: String)
        case number(min: Double? = nil, max: Double? = nil, step: Double? = nil)
        /// A fraction from 0 to 1, shown as a percentage.
        case percentSlider(step: Double)
        /// A whole number in a range, shown as it is.
        case slider(min: Double, max: Double, step: Double)
        /// - Parameter match: The option to show for a stored value that isn't one of them (e.g. one
        ///   saved in an older format), if any.
        case select([SettingsOption], match: ((String) -> String?)? = nil)
        /// A menu of numbers (option values are the numbers as text).
        case numberSelect([SettingsOption])
        case text(test: ConnectionTest? = nil)
        /// Free text, e.g. CSS.
        case textarea
        /// A list of strings, one per line.
        case lines
        /// A JSON array.
        case json
        /// Replacements applied to lines (see web/src/lib/replacements.js).
        case replacements
        /// Yomitan's audio sources, [{type, url, voice}] (see web/src/lib/audio-sources.js).
        case audioSources
        /// Custom scan inputs (see web/src/lib/scan-inputs.js).
        case scanInputs
        /// Keyboard shortcuts for popups, [{action, argument, key, modifiers, enabled}] (see Hotkeys.swift).
        case hotkeys
        /// Yomitan's sentence termination characters, [{enabled, character1, character2 (null for a
        /// terminator), includeCharacterAtStart, includeCharacterAtEnd}].
        case terminationCharacters
        /// A value copied by Import Yomitan, which is only edited in Yomitan: a summary and a button to clear it.
        /// - Parameter details: A longer description, shown as a tooltip.
        case imported(describe: ([Any]) -> String, emptyText: String, details: (([Any]) -> String)? = nil)
        /// The handlebars templates in yomitanAnkiTemplates.
        case ankiTemplates
        /// The window read in screen OCR mode, chosen on screen (see WindowPicker.swift).
        case ocrWindow
        /// An index into the connected displays (NSScreen.screens, the main one first).
        case display
        /// One global keyboard shortcut, {key, modifiers} or null.
        case shortcut
        /// Keys pressed in turn, [{key, modifiers}].
        case keySequence
        /// An audio input's name ("" for the system's default input).
        case audioInput
        /// A field name of the note types in Anki (from AnkiConnect).
        case ankiField
        /// Whether a macOS permission is granted, with buttons to ask for it (not a setting).
        case permission(Permission)
    }

    enum ConnectionTest {
        case yomitan, anki
    }

    let key: String
    let label: String
    let kind: Kind
    var hint: String?
    var showIf: (([String: Any]) -> Bool)?

    var id: String { key }

    init(_ key: String, _ label: String, _ kind: Kind, hint: String? = nil, showIf: (([String: Any]) -> Bool)? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.hint = hint
        self.showIf = showIf
    }

    /// Shown across the whole width, below its label.
    var isWide: Bool {
        switch kind {
        case .textarea, .lines, .json, .replacements, .audioSources, .scanInputs, .hotkeys, .terminationCharacters, .ankiTemplates: true
        default: false
        }
    }
}

struct SettingsSection: Identifiable {
    let title: String
    let symbol: String
    var description: String?
    let fields: [SettingsField]

    var id: String { title }
}

/// The settings shown in the Settings window. Their defaults are in web/src/lib/settings-defaults.js.
@MainActor
enum SettingsSchema {
    static let scanInputsHint =
        "Scanning happens while every key or button of one entry is held. An empty entry scans on hover. "
        + "Like in Yomitan, entries combine the modifier keys meta (Command), ctrl, alt (Option) and shift with the mouse buttons "
        + "mouse0 (left), mouse1 (right), mouse2 (middle), mouse3 (back), mouse4 (forward) and mouse5. "
        + "A name with a leading - must not be held, like Yomitan’s “exclude”: “shift -mouse0” scans with shift, but not while the left button is held. "
        + "Add terms or kanji to look up only terms or only kanji, like Yomitan’s “Search terms” and “Search kanji”: “alt kanji”."

    private static let scanModifierOptions = [
        SettingsOption("none", "No key"),
        SettingsOption("alt", "Opt"),
        SettingsOption("ctrl", "Ctrl"),
        SettingsOption("shift", "Shift"),
        SettingsOption("meta", "Cmd"),
        SettingsOption("custom", "Other (scanning inputs)"),
    ]

    private static let collapseModeNames = [
        "not-collapsible": "Not collapsible", "collapsed": "Collapsed", "expanded": "Expanded",
        "force-collapsed": "Force collapsed", "force-expanded": "Force expanded",
    ]

    /// Imported collapse modes grouped by mode, in Yomitan's menu order, with the dictionaries' names.
    private static func collapseModes(_ values: [Any]) -> [(label: String, names: [String])] {
        var byMode: [String: [String]] = [:]
        for case let item as [String: Any] in values {
            guard let name = item["name"] as? String, let mode = item["mode"] as? String else { continue }
            byMode[mode, default: []].append(name)
        }
        let order = ["not-collapsible", "collapsed", "expanded", "force-collapsed", "force-expanded"]
        return byMode.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { (collapseModeNames[$0] ?? $0, byMode[$0]!) }
    }

    /// Yomitan's popup themes; "Auto" follows the text box.
    private static let themeOptions = [
        SettingsOption("site", "Auto (follows text box)"), SettingsOption("light", "Light"), SettingsOption("dark", "Dark"), SettingsOption("browser", "Browser (follows macOS)"),
    ]

    /// The languages Live Text can read, as macOS reports them (they vary with its version), by name.
    private static let ocrLanguages: [SettingsOption] = {
        let english = Locale(identifier: "en")
        return ImageAnalyzer.supportedTextRecognitionLanguages.map { identifier in
            let name = english.localizedString(forIdentifier: identifier)
                ?? Locale(identifier: identifier).language.languageCode.flatMap { english.localizedString(forLanguageCode: $0.identifier) }
                ?? identifier
            return SettingsOption(identifier, name)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }()

    /// The supported language a stored one stands for, e.g. "ja-JP" for "ja" (saved by older versions).
    private static func matchLanguage(_ value: String) -> String? {
        let language = Locale.Language(identifier: value)
        return ocrLanguages.first {
            let option = Locale.Language(identifier: $0.value)
            return option.languageCode == language.languageCode && (language.script == nil || option.script == language.script)
        }?.value
    }

    static let sections: [SettingsSection] = {
        let support = SettingsSupport.shared
        return [
            SettingsSection(title: "General", symbol: "gearshape", fields: [
                SettingsField("ocrMode", "Mode", .toggleChoice(off: "Window Mode", on: "OCR Mode")),
                SettingsField("displayIndex", "Display", .display),
                SettingsField("windowLevel", "Window level", .select([
                    SettingsOption("floating", "Floating"),
                    SettingsOption("statusBar", "Status bar"),
                    SettingsOption("popUpMenu", "Pop-up menu"),
                    SettingsOption("screenSaver", "Screen saver"),
                    SettingsOption("shielding", "Shielding (above captured displays)"),
                ])),
                SettingsField(
                    "ocrWindow", "Captured window", .ocrWindow,
                    hint: "OCR mode reads this window, and Anki screenshots ({screenshot}) show only it. Without one, both use the whole screen the overlay is on."
                ),
            ]),
            SettingsSection(title: "WebSockets", symbol: "network", fields: [
                SettingsField("websocketUrls", "WebSockets (one per line)", .lines),
                SettingsField(
                    "continuousReconnect", "Continuous reconnect", .checkbox,
                    hint: "For Window Mode. In OCR Mode with “Use WebSocket lines” on, WebSockets always reconnect."
                ),
                SettingsField("showConnectionErrors", "Show connection errors", .checkbox),
            ]),
            SettingsSection(title: "Window Mode", symbol: "text.alignleft", fields: [
                SettingsField("boxOpacity", "Background opacity", .percentSlider(step: 0.05)),
                SettingsField(
                    "clipboardMonitor", "Enable background clipboard text monitoring", .checkbox,
                    hint: "Text copied in any app is added to the text box as a line. Text that password managers mark as concealed is skipped."
                ),
                SettingsField(
                    "clipboardMaxLength", "Maximum clipboard text search length", .number(min: 1),
                    hint: "Limit the number of characters used when searching clipboard text.",
                    showIf: { $0["clipboardMonitor"] as? Bool == true }
                ),
                SettingsField("theme", "Theme", .select(support.themes.map { SettingsOption($0) })),
                SettingsField("fontSize", "Font size", .number(min: 1)),
                SettingsField("linePadding", "Line padding", .number(min: 0, step: 0.1)),
                SettingsField("onlineFont", "Online font", .select(support.onlineFonts.map { SettingsOption($0) })),
                SettingsField("preventLastDuplicate", "Prevent last line duplicate", .number(min: 0)),
                SettingsField("maxLines", "Max lines (0 = unlimited)", .number(min: 0)),
                SettingsField("preventGlobalDuplicate", "Prevent global duplicates", .checkbox),
                SettingsField("mergeEqualLineStarts", "Merge equal line starts", .checkbox),
                SettingsField("filterNonCJKLines", "Filter non-CJK lines", .checkbox),
                SettingsField("preserveWhitespace", "Preserve whitespace", .checkbox),
                SettingsField("removeAllWhitespace", "Remove all whitespace", .checkbox),
                SettingsField("reverseLineOrder", "Reverse line order", .checkbox),
                SettingsField("displayVertical", "Display text vertically", .checkbox),
                SettingsField("showLinePoints", "Show line points", .checkbox),
                SettingsField("enableLineAnimation", "Enable line animation", .checkbox),
                SettingsField("showFurigana", "Show furigana", .checkbox),
                SettingsField(
                    "furiganaReadingMode", "Reading mode", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("hiragana", "ひらがな"),
                        SettingsOption("katakana", "カタカナ"),
                        SettingsOption("romaji", "Romaji"),
                        SettingsOption("dictionary-reading", "Dictionary reading"),
                    ]),
                    hint: "Change what type of furigana is displayed for parsed text: in the text box (with “Show furigana”) and in the sentence furigana of Anki cards ({sentence-furigana}; as in Yomitan, only hiragana and katakana change those)."
                ),
                SettingsField("termSpacing", "Show space between parsed words", .checkbox),
                SettingsField(
                    "replacements", "Replacements", .replacements,
                    hint: "Applied to each new line in order, before it’s shown. Patterns are JavaScript regular expressions; in the replacement, $1 inserts the first group, and \\n and \\t a newline and a tab."
                ),
                SettingsField("customCSS", "Custom CSS (text box)", .textarea),
            ]),
            SettingsSection(
                title: "OCR Mode", symbol: "text.viewfinder",
                description: "Instead of the text box, read the captured window (Settings → General), or the whole screen without one, and show popups when hovering its text. "
                    + "Needs the Screen Recording permission.",
                fields: [
                    SettingsField(
                        "ocrEngine", "Text recognition",
                        .select([SettingsOption("liveText", "Live Text"), SettingsOption("meikiocr", "meikiocr")]),
                        hint: "Live Text is Apple’s, as in Preview and Photos. meikiocr (by rtr46) is made for Japanese game text and reads only Japanese; it runs with Core ML."
                    ),
                    SettingsField(
                        "ocrLanguage", "Language", .select(ocrLanguages, match: matchLanguage),
                        hint: "For Live Text: the languages it can read on this version of macOS. English is always read too."
                    ),
                    SettingsField(
                        "ocrResolution", "Read at",
                        .select([SettingsOption("auto", "Automatic"), SettingsOption("full", "Full resolution"), SettingsOption("1x", "1x")]),
                        hint: "Automatic reads windows drawn at 1x (e.g. a VM or a game that isn’t Retina aware, enlarged by macOS) at 1x, which is faster and loses nothing, and others at full Retina resolution. Choose one if text is misread: full resolution for small text, 1x if automatic picks full resolution for a window drawn at 1x."
                    ),
                    SettingsField(
                        "ocrUseWebsocket", "Use WebSocket lines", .checkbox,
                        hint: "New lines from the WebSocket trigger reading the window, and recognized text that matches the line is replaced by it."
                    ),
                    SettingsField(
                        "ocrChangeThreshold", "Change threshold (%)", .number(min: 0, step: 0.1),
                        hint: "The window is read again when this share of it (or of one of the chosen areas) changes (for the dialogue area while a WebSocket is connected, only briefly after each line)."
                    ),
                    SettingsField(
                        "ocrPollInterval", "Check for changes every (in milliseconds)", .number(min: 50),
                        hint: "How often the window is compared with the last reading to notice new text: all the time, or with “Watch after mouse use” only for a while after the mouse is used. Shorter notices changes sooner but uses more CPU. While a WebSocket is connected, its lines are the cue instead, and the window is only watched briefly after each one."
                    ),
                    SettingsField(
                        "ocrMouseWatch", "Watch after mouse use", .checkbox,
                        hint: "Without a WebSocket (and for areas after the first, the dialogue, either way): only check for changes for a while after the mouse moves or clicks (e.g. to advance the text), instead of all the time, to save work while you read. Text that starts appearing in that time is read once it’s finished, however long that takes."
                    ),
                    SettingsField(
                        "ocrMouseWatchTime", "Watch for (in milliseconds)", .number(min: 0),
                        hint: "How long changes are checked for after the mouse moves or clicks. Raise it if a game shows its next line only after a longer transition (otherwise it’s only read once you move the mouse again); keep it well above “Check for changes every”, so it’s checked several times.",
                        showIf: { $0["ocrMouseWatch"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrSettleTime", "Wait until unchanged for (in milliseconds)", .number(min: 0),
                        hint: "Text is read once the picture stops changing, so lines that are still being drawn aren’t read half-finished. With several areas, only the first (the dialogue) waits; the others are read as soon as they change."
                    ),
                    SettingsField(
                        "ocrStillTolerance", "Ignore changes fainter than", .slider(min: 0, max: 255, step: 1),
                        hint: "How much a pixel’s brightness (0–255) has to change to count as still changing while waiting. Higher reads sooner when text fades in slowly or the picture is grainy (e.g. a video background), but may read text before its last characters are fully drawn. Lower waits for every faint change."
                    ),
                    SettingsField(
                        "ocrMaxWait", "Read anyway after (in milliseconds)", .number(min: 100),
                        hint: "If the picture keeps changing (e.g. slow text, or an animated background or effect), the window is read after this long anyway, and again once it stops changing. Choosing areas around the text avoids most of these waits."
                    ),
                    SettingsField(
                        "ocrShowBoxes", "Outline recognized text", .checkbox,
                        hint: "For debugging: shows the recognized text and outlines its lines over the window, red for plain OCR text and green for lines corrected with the WebSocket line."
                    ),
                ]
            ),
            SettingsSection(title: "Scanning", symbol: "cursorarrow.rays", fields: [
                SettingsField("yomitanApiUrl", "Yomitan API URL", .text(test: .yomitan)),
                SettingsField(
                    "language", "Language", .select(support.languages.map { SettingsOption($0.iso, $0.name) }),
                    hint: "The language of your Yomitan profile, which Import → Yomitan Settings copies. Lookups use Yomitan’s own setting; this one sets the audio sources, how text is displayed and whether word scan resolution applies."
                ),
                SettingsField("scanModifier", "Scan modifier key (text box)", .select(scanModifierOptions)),
                SettingsField("scanInputs", "Scanning inputs (text box)", .scanInputs, showIf: { $0["scanModifier"] as? String == "custom" }),
                SettingsField("popupScanModifier", "Scan modifier key (popup, for nested lookups)", .select(scanModifierOptions)),
                SettingsField("popupScanInputs", "Scanning inputs (popup)", .scanInputs, showIf: { $0["popupScanModifier"] as? String == "custom" }),
                SettingsField(
                    "popupNestingMaxDepth", "Maximum number of child popups", .number(min: 0),
                    hint: "Popups opened by scanning in popups. 0 turns them off."
                ),
                SettingsField(
                    "popupSearchOnClick", "Search terms when clicking text from the results list", .checkbox,
                    hint: "Clicking a word in a popup’s definitions looks it up in that popup; its back button returns to the previous results."
                ),
                SettingsField(
                    "popupScanExpressions", "Allow scanning popup source terms", .checkbox,
                    hint: "Headwords and their readings in popups can be scanned too."
                ),
                SettingsField(
                    "preventBackForwardInPopups", "Prevent mouse back and forward buttons in popups", .checkbox,
                    hint: "Off: the mouse’s back and forward buttons go through a popup’s history, as in Yomitan."
                ),
                SettingsField("scanLength", "Text scan length", .number(min: 1)),
                SettingsField(
                    "scanResolution", "Scan resolution",
                    .select([SettingsOption("character", "Character"), SettingsOption("word", "Word")]),
                    hint: "Start the lookup scan at the word or character of the cursor position. As in Yomitan, words aren’t used when the language is Japanese, Chinese, Cantonese or Korean."
                ),
                SettingsField("scanDelay", "Scan delay (in milliseconds)", .number(min: 0)),
                SettingsField(
                    "scanWithoutMousemove", "Scan without mouse move", .checkbox,
                    hint: "Allow scanning words under the pointer without the pointer being in motion: pressing the scan key looks up the word under the resting pointer."
                ),
                SettingsField("selectMatchedText", "Select matched text", .checkbox, hint: "Highlights the text that was looked up."),
                SettingsField("parser", "Parse sentences using", .select([SettingsOption("scanning-parser", "Yomitan's internal parser"), SettingsOption("mecab", "MeCab")])),
                SettingsField("autoHideResults", "Auto-hide search popup", .checkbox),
                SettingsField("hideDelay", "Auto-hide search popup delay (in milliseconds)", .number(min: 0)),
                SettingsField("hidePopupOnCursorExit", "Hide popup on cursor exit", .checkbox),
                SettingsField("hidePopupOnCursorExitDelay", "Hide popup on cursor exit delay (in milliseconds)", .number(min: 0)),
                SettingsField("sentenceScanExtent", "Sentence scanning extent", .number(min: 1)),
                SettingsField("sentenceTerminationCharacterMode", "Sentence termination characters", .select([
                    SettingsOption("custom", "Custom"),
                    SettingsOption("custom-no-newlines", "Custom, no newlines"),
                    SettingsOption("newlines", "Newlines only"),
                    SettingsOption("none", "None"),
                ])),
                SettingsField(
                    "sentenceTerminationCharacters", "Custom sentence termination characters", .terminationCharacters,
                    hint: "Sentences are terminated by punctuation (terminators) and quotation marks (quotes). “Include character in sentence” keeps a terminator, or a quote’s first or second character, in the sentence.",
                    showIf: { ["custom", "custom-no-newlines"].contains($0["sentenceTerminationCharacterMode"] as? String ?? "custom") }
                ),
            ]),
            SettingsSection(
                title: "Yomitan Popup", symbol: "rectangle.on.rectangle",
                fields: [
                    SettingsField("popupTheme", "Theme (body)", .select(themeOptions)),
                    SettingsField("popupOuterTheme", "Theme (shadow)", .select(themeOptions + [SettingsOption("none", "None")])),
                    SettingsField("popupWidth", "Size (width)", .number(min: 1)),
                    SettingsField("popupHeight", "Size (height)", .number(min: 1)),
                    SettingsField("popupScalingFactor", "Scale", .numberSelect(
                        [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5].map { SettingsOption("\($0 as NSNumber)", "\(Int(($0 * 100).rounded()))%") }
                    )),
                    SettingsField("popupHorizontalOffset", "Horizontal text offset (x)", .number()),
                    SettingsField("popupVerticalOffset", "Horizontal text offset (y)", .number()),
                    SettingsField("popupHorizontalTextPosition", "Horizontal text positioning", .select([
                        SettingsOption("below", "Below text"), SettingsOption("above", "Above text"),
                    ])),
                    SettingsField("popupVerticalTextPosition", "Vertical text positioning", .select([
                        SettingsOption("default", "Same as horizontal text"),
                        SettingsOption("before", "Before reading direction"),
                        SettingsOption("after", "After reading direction"),
                        SettingsOption("left", "Left of text"),
                        SettingsOption("right", "Right of text"),
                    ])),
                    SettingsField("popupDisplayMode", "Display mode", .select([SettingsOption("default", "Default"), SettingsOption("full-width", "Full width")])),
                    SettingsField(
                        "popupFullWidthPosition", "Popup position", .select([
                            SettingsOption("top", "Top"), SettingsOption("above-cursor", "Follow Cursor"), SettingsOption("bottom", "Bottom"),
                        ]),
                        showIf: { $0["popupDisplayMode"] as? String == "full-width" }
                    ),
                    SettingsField("fontFamily", "Font family", .text()),
                    SettingsField("popupFontSize", "Font size", .number(min: 1)),
                    SettingsField("lineHeight", "Line height", .text()),
                    SettingsField("glossaryLayoutMode", "Compact glossaries", .select([
                        SettingsOption("default", "Default"), SettingsOption("compact", "Compact Popup"), SettingsOption("compact-popup-anki", "Compact Popup and Anki"),
                    ])),
                    SettingsField("compactTags", "Compact tags", .checkbox),
                    SettingsField(
                        "showSearchTags", "Show tags for expressions and their readings", .checkbox,
                        hint: "These tags can be scanned if “Allow scanning popup source terms” is on."
                    ),
                    SettingsField("averageFrequency", "Average frequencies", .checkbox),
                    SettingsField("frequencyDisplayMode", "Frequency display style", .select([
                        SettingsOption("tags", "Tags"),
                        SettingsOption("tags-grouped", "Tags, grouped content"),
                        SettingsOption("split-tags", "Split tags"),
                        SettingsOption("split-tags-grouped", "Split tags, grouped content"),
                        SettingsOption("inline-list", "Inline list"),
                        SettingsOption("list", "List"),
                        SettingsOption("list-bordered", "List, bordered"),
                    ])),
                    SettingsField("termDisplayMode", "Term display style", .select([
                        SettingsOption("ruby", "Term furigana"),
                        SettingsOption("ruby-and-reading", "Term furigana and reading"),
                        SettingsOption("term-and-reading", "Plain term and reading"),
                        SettingsOption("term-only", "Plain term"),
                    ])),
                    SettingsField("showPitchAccentDownstepNotation", "Pitch accent display styles (downstep notation)", .checkbox),
                    SettingsField("showPitchAccentPositionNotation", "Pitch accent display styles (downstep position)", .checkbox),
                    SettingsField("showPitchAccentGraph", "Pitch accent display styles (graph)", .checkbox),
                    SettingsField("popupCurrentIndicatorMode", "Selection indicator style", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("asterisk", "Asterisk"),
                        SettingsOption("triangle", "Triangle"),
                        SettingsOption("bar-left", "Vertical bar (left)"),
                        SettingsOption("bar-right", "Vertical bar (right)"),
                        SettingsOption("dot-left", "Small dot (left)"),
                        SettingsOption("dot-right", "Small dot (right)"),
                    ])),
                    SettingsField("popupActionBarVisibility", "Action bar appearance (visibility)", .select([
                        SettingsOption("auto", "Auto"), SettingsOption("always", "Always"),
                    ])),
                    SettingsField("popupActionBarLocation", "Action bar appearance (location)", .select([
                        SettingsOption("left", "Left"), SettingsOption("right", "Right"), SettingsOption("top", "Top"), SettingsOption("bottom", "Bottom"),
                    ])),
                    SettingsField(
                        "definitionsCollapsible", "Collapsible dictionaries", .select([
                            SettingsOption("not-collapsible", "Not collapsible"),
                            SettingsOption("collapsed", "Collapsed"),
                            SettingsOption("expanded", "Expanded"),
                            SettingsOption("force-collapsed", "Force collapsed"),
                            SettingsOption("force-expanded", "Force expanded"),
                        ]),
                        hint: "For dictionaries without their own mode from Yomitan (below)."
                    ),
                    SettingsField(
                        "dictionaryCollapsible", "Collapsible dictionaries (from Import Yomitan)",
                        .imported(
                            describe: { values in
                                collapseModes(values).map { "\($0.label): \($0.names.count)" }.joined(separator: ", ")
                            },
                            emptyText: "None. Use Import → Yomitan Settings to copy them.",
                            details: { values in
                                collapseModes(values).map { "\($0.label): \($0.names.joined(separator: ", "))" }.joined(separator: "\n\n")
                            }
                        ),
                        hint: "Each enabled dictionary’s mode in Yomitan’s “Configure collapsible dictionaries”."
                    ),
                    SettingsField("audioEnabled", "Enable audio playback for terms", .checkbox, hint: "Show a clickable speaker icon next to search results."),
                    SettingsField("audioAutoPlay", "Auto-play search result audio", .checkbox),
                    SettingsField("audioVolume", "Audio volume", .number(min: 0, max: 100), hint: "Adjust the volume audio is played at, in percent."),
                    SettingsField(
                        "audioFallbackSound", "Audio fallback sound", .select([
                            SettingsOption("none", "None"), SettingsOption("click", "Click"), SettingsOption("bloop", "Bloop"),
                        ]),
                        hint: "Played when no audio is found."
                    ),
                    SettingsField(
                        "audioSources", "Audio sources", .audioSources,
                        hint: "Tried in order when a play button is clicked; right-click one to choose among the audio every source has, as in Yomitan. The audio played from that menu is also used for Anki cards. Without sources, the Yomitan API plays the audio from Yomitan’s own sources. Import → Yomitan Settings copies them."
                    ),
                    SettingsField(
                        "audioDefaultSources", "Enable default audio sources", .checkbox,
                        hint: "Yomitan’s default sources (JapanesePod101, LanguagePod101 and Jisho.org) are tried after the ones above when they aren’t among them."
                    ),
                    SettingsField("customPopupCss", "Popup CSS", .textarea),
                    SettingsField("customPopupOuterCss", "Popup outer CSS", .textarea),
                    SettingsField(
                        "dictionaryStyles", "Dictionary styles (from Import Yomitan)",
                        .imported(
                            describe: { values in values.compactMap { ($0 as? [String: Any])?["name"] as? String }.joined(separator: ", ") },
                            emptyText: "None. Use Import → Yomitan Settings to copy them."
                        )
                    ),
                ]
            ),
            SettingsSection(
                title: "Popup Shortcuts", symbol: "keyboard",
                description: "Yomitan’s keyboard shortcuts for popups. They work while a popup shows, also when another app such as a game is in front; their keys go to the popup instead until it closes.",
                fields: [SettingsField("hotkeys", "", .hotkeys)]
            ),
            SettingsSection(
                title: "Anki", symbol: "rectangle.stack.badge.plus",
                description: "Card formats and handlebars come from the active Yomitan profile through the Yomitan API.",
                fields: [
                    SettingsField("ankiEnabled", "Enable Anki integration", .checkbox),
                    SettingsField("ankiConnectUrl", "AnkiConnect server address", .text(test: .anki)),
                    SettingsField("ankiConnectKey", "API key", .text()),
                    SettingsField("ankiTags", "Card tags", .text(), hint: "Separated by spaces."),
                    SettingsField(
                        "ankiRenderTemplatesLocally", "Render the field templates below instead of using the Yomitan API", .checkbox,
                        hint: "Enable this to let templates use text selected in the popup (getMedia \"popupSelectionText\"), e.g. to pick a dictionary by selecting its name. The API can’t see the selection."
                    ),
                    SettingsField(
                        "yomitanAnkiTemplates", "Field templates (Yomitan “Configure Anki card templates”)", .ankiTemplates,
                        hint: "Copied by Import Yomitan. Only used with the option above; otherwise the API uses the templates in Yomitan."
                    ),
                    SettingsField("checkForDuplicates", "Check for card duplicates", .checkbox),
                    SettingsField("duplicateScope", "Duplicate card scope", .select([
                        SettingsOption("collection", "Collection"), SettingsOption("deck", "Deck"), SettingsOption("deck-root", "Deck root"),
                    ])),
                    SettingsField("duplicateScopeCheckAllModels", "Check for duplicates across all models", .checkbox),
                    SettingsField("duplicateBehavior", "When a duplicate is detected", .select([
                        SettingsOption("prevent", "Prevent adding"), SettingsOption("overwrite", "Allow overwriting"), SettingsOption("new", "Allow adding"),
                    ])),
                    SettingsField(
                        "ankiNoteDupeCheckFirst", "Prioritize Anki note duplicate checks before note creation", .checkbox,
                        hint: "Shows the note buttons early, disabled, from a quick duplicate check on the term alone, and enables them once the notes are made.",
                        showIf: { $0["checkForDuplicates"] as? Bool == true }
                    ),
                    SettingsField("ankiDisplayTagsAndFlags", "Show card tags and flags", .select([
                        SettingsOption("never", "Never"), SettingsOption("always", "Always"),
                        SettingsOption("non-standard", "Non-standard"), SettingsOption("custom", "Custom"),
                    ]), hint: "For notes that already exist. Non-standard leaves out the card tags above; Custom shows only the target tags."),
                    SettingsField(
                        "ankiTargetTags", "Target tags", .text(), hint: "List of space or comma separated tags.",
                        showIf: { $0["ankiDisplayTagsAndFlags"] as? String == "custom" }
                    ),
                    SettingsField("ankiSuspendNewCards", "Suspend new cards", .checkbox, hint: "New cards will be suspended when a note is added."),
                    SettingsField("ankiForceSync", "Force Anki sync on adding card", .checkbox),
                    SettingsField(
                        "ankiDownloadTimeout", "Idle download timeout (in milliseconds)", .number(min: 0),
                        hint: "The maximum time before an idle download will be cancelled; 0 = no limit (at most a minute). For audio chosen in the play button menu; the Yomitan API downloads other audio with Yomitan’s own setting."
                    ),
                    SettingsField("noteGuiMode", "Note viewer window", .select([SettingsOption("browse", "Card browser"), SettingsOption("edit", "Note editor")])),
                    SettingsField("screenshotFormat", "Screenshot format", .select([SettingsOption("png", "PNG"), SettingsOption("jpeg", "JPEG")])),
                    SettingsField("screenshotQuality", "Screenshot format (quality %)", .number(min: 0, max: 100)),
                ]
            ),
            SettingsSection(
                title: "Anki Sentence Audio", symbol: "waveform",
                description: "A shortcut records the voice of the line just mined and adds it to the newest Anki cards with that sentence. It switches to the game, presses the keys that open its backlog (where the line can be replayed), records until the voice ends, and presses the keys that close the backlog. Recording asks for Microphone permission, and pressing keys for Accessibility.",
                fields: [
                    SettingsField("sentenceAudioEnabled", "Enable sentence audio recording", .checkbox),
                    SettingsField(
                        "sentenceAudioShortcut", "Shortcut", .shortcut,
                        hint: "Works in any app. Pressed while recording, it stops the recording and keeps it."
                    ),
                    SettingsField(
                        "sentenceAudioDevice", "Audio input", .audioInput,
                        hint: "What’s recorded: e.g. a virtual device (Loopback, BlackHole) that the game’s sound goes to."
                    ),
                    SettingsField(
                        "sentenceAudioField", "Sentence audio field", .ankiField,
                        hint: "The recording goes into this field of the newest card added today, and of the other cards added today with the same sentence, where it’s empty. Their sentence field is the one their Yomitan card format fills with {sentence}."
                    ),
                    SettingsField("sentenceAudioApp", "Switch to", .select([
                        SettingsOption("captured", "The captured window"),
                        SettingsOption("named", "Another app"),
                        SettingsOption("none", "Don’t switch apps"),
                    ]), hint: "Before pressing keys, so the game gets them. The captured window is the one chosen in Settings → General, also outside OCR mode."),
                    SettingsField(
                        "sentenceAudioAppName", "App name", .text(), hint: "As the Dock shows it, e.g. Parallels Desktop.",
                        showIf: { $0["sentenceAudioApp"] as? String == "named" }
                    ),
                    SettingsField("sentenceAudioOpenKeys", "Keys that open the backlog", .keySequence, hint: "Pressed in turn before recording, e.g. to open the backlog and replay the line’s voice."),
                    SettingsField("sentenceAudioCloseKeys", "Keys that close the backlog", .keySequence, hint: "Pressed in turn after recording."),
                    SettingsField("sentenceAudioKeyDelay", "Wait before pressing keys (in milliseconds)", .number(min: 0), hint: "After switching apps, until the game takes keys."),
                    SettingsField("sentenceAudioKeyInterval", "Wait between keys (in milliseconds)", .number(min: 0)),
                    SettingsField("sentenceAudioKeyHold", "Hold each key for (in milliseconds)", .number(min: 0)),
                    SettingsField("sentenceAudioRecordDelay", "Wait before recording (in milliseconds)", .number(min: 0), hint: "After the keys, e.g. until the backlog’s own sounds are over. Not used with “Detect when the voice starts and ends”, which waits for the voice instead."),
                    SettingsField(
                        "sentenceAudioDetectVoice", "Detect when the voice starts and ends", .checkbox,
                        hint: "Detects speech (not music or sound effects) with macOS’s sound classifier: recording stops when the voice ends, and only the voice is kept. Off: press the shortcut again to stop."
                    ),
                    SettingsField(
                        "sentenceAudioVoiceWait", "Wait for the voice for (in seconds)", .number(min: 1),
                        hint: "Nothing is saved if no voice is heard by then.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "sentenceAudioPause", "The voice has ended after (in milliseconds)", .number(min: 100),
                        hint: "Without speech: recording stops then (or after the padding below, if it’s longer). Raise it if lines are cut off at pauses.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "sentenceAudioPadding", "Detected voice padding (in milliseconds)", .number(min: 0),
                        hint: "Kept before the voice starts and after it ends.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField("sentenceAudioMaxLength", "Record at most (in seconds)", .number(min: 1)),
                    SettingsField("sentenceAudioPlay", "Play the recording after adding it", .checkbox),
                    SettingsField("sentenceAudioBrowse", "Show the cards in Anki’s card browser", .checkbox),
                ]
            ),
            SettingsSection(
                title: "Permissions", symbol: "lock.shield",
                description: "What MacPopup needs macOS’s permission for. Each one is only asked for when it’s first needed, or here. A permission turned off in System Settings can only be turned on again there.",
                fields: [
                    SettingsField(
                        "permission.screenRecording", "Screen Recording", .permission(.screenRecording),
                        hint: "For OCR Mode (choosing and reading the captured window) and for screenshots on Anki cards ({screenshot}). macOS may ask to reopen MacPopup once it’s granted."
                    ),
                    SettingsField(
                        "permission.microphone", "Microphone", .permission(.microphone),
                        hint: "For Anki Sentence Audio: recording its audio input, also a virtual device such as Loopback or BlackHole."
                    ),
                    SettingsField(
                        "permission.accessibility", "Accessibility", .permission(.accessibility),
                        hint: "For Anki Sentence Audio: pressing the keys that open and close the game’s backlog, and bringing the captured window to the front."
                    ),
                ]
            ),
        ]
    }()
}
