import Foundation

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
        case select([SettingsOption])
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
        /// - Parameters:
        ///   - details: A longer description, shown as a tooltip.
        ///   - isList: Whether the summary is a list that can wrap over several lines: it's then aligned to
        ///     the left, instead of right before the button.
        case imported(describe: ([Any]) -> String, emptyText: String, details: (([Any]) -> String)? = nil, isList: Bool = false)
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
        /// Whether an engine's converted models are loaded, with buttons to load and remove them (not a setting).
        case convertedModels(ConvertedModelsKind)
    }

    enum ConnectionTest {
        case yomitan, anki
    }

    let key: String
    let label: String
    let kind: Kind
    var hint: String?
    var showIf: (([String: Any]) -> Bool)?
    /// A problem with the settings, shown in red under the field, if any.
    var warning: (([String: Any]) -> String?)?

    var id: String { key }

    init(
        _ key: String, _ label: String, _ kind: Kind, hint: String? = nil, showIf: (([String: Any]) -> Bool)? = nil,
        warning: (([String: Any]) -> String?)? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.hint = hint
        self.showIf = showIf
        self.warning = warning
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
        "Hold all keys and mouse buttons in an entry to look up words, or leave an entry empty to look up on hover. "
        + "You can combine modifier keys (meta for Command, ctrl, alt for Option, shift) with mouse buttons "
        + "(mouse0 for left, mouse1 for right, mouse2 for middle, mouse3 for back, mouse4 for forward, mouse5). "
        + "Add a minus sign (-) to ignore lookups while a key or button is held (e.g. “shift -mouse0” looks up with Shift, unless the left mouse button is pressed). "
        + "Add “terms” or “kanji” to restrict lookups to words or individual kanji (e.g. “alt kanji”)."

    private static let scanModifierOptions = [
        SettingsOption("none", "No key"),
        SettingsOption("alt", "Option (⌥)"),
        SettingsOption("ctrl", "Control (⌃)"),
        SettingsOption("shift", "Shift (⇧)"),
        SettingsOption("meta", "Command (⌘)"),
        SettingsOption("custom", "Other"),
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
        SettingsOption("site", "Auto (match text box)"),
        SettingsOption("light", "Light"),
        SettingsOption("dark", "Dark"),
        SettingsOption("browser", "Browser (match macOS)"),
    ]

    static let sections: [SettingsSection] = {
        let support = SettingsSupport.shared
        return [
            SettingsSection(title: "General", symbol: "gearshape", fields: [
                SettingsField(
                    "ocrMode", "Mode", .toggleChoice(off: "Window Mode", on: "OCR Mode"),
                    hint: "Window Mode displays incoming text in a floating box. OCR Mode reads text directly from a game or app window on screen."
                ),
                SettingsField(
                    "language", "Language", .select(support.languages.map { SettingsOption($0.iso, $0.name) }),
                    hint: "Should match your active Yomitan profile language (automatically set when importing Yomitan settings). Used to select default audio sources, format text, and choose the language OCR Mode reads (text in other scripts is skipped)."
                ),
                SettingsField(
                    "displayIndex", "Display", .display,
                    hint: "The screen where the overlay and dictionary popups appear."
                ),
                SettingsField("windowLevel", "Overlay window level", .select([
                    SettingsOption("floating", "Floating (above standard windows)"),
                    SettingsOption("statusBar", "Status bar"),
                    SettingsOption("popUpMenu", "Pop-up menu"),
                    SettingsOption("screenSaver", "Screen saver (default)"),
                    SettingsOption("shielding", "Shielding (highest, above games that take over the display)"),
                ])),
                SettingsField(
                    "ocrWindow", "Captured window", .ocrWindow,
                    hint: "The target window read in OCR Mode and captured for Anki {screenshot} fields. If none is selected, the entire screen is used."
                ),
                SettingsField(
                    "theme", "Theme", .select(support.themes.map { SettingsOption($0) }),
                    hint: "The colors of the text box in Window Mode. In OCR Mode, it only sets the color of text highlights."
                ),
                SettingsField(
                    "furiganaReadingMode", "Furigana style", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("hiragana", "Hiragana (ひらがな)"),
                        SettingsOption("katakana", "Katakana (カタカナ)"),
                        SettingsOption("romaji", "Romaji"),
                        SettingsOption("dictionary-reading", "Dictionary reading"),
                    ]),
                    hint: "Controls how readings appear in the text box (when “Show furigana above words” is on) and in Anki’s {sentence-furigana} field. In OCR Mode, it only applies to Anki cards. Note: on Anki cards, only Hiragana and Katakana change the furigana."
                ),
                SettingsField(
                    "replacements", "Text replacements", .replacements,
                    hint: "Find-and-replace rules applied in order to each new line before it appears. Supports regular expressions ($1 inserts the first capture group, \\n adds a line break, and \\t adds a tab). In OCR Mode, they only apply to WebSocket lines, before they’re matched with the recognized text."
                ),
            ]),
            SettingsSection(title: "WebSockets", symbol: "network", fields: [
                SettingsField(
                    "websocketUrls", "WebSocket URLs (one per line)", .lines,
                    hint: "Addresses of tools that send text to MacPopup (such as Textractor, Agent, LunaTranslator or owocr). Accepts plain text or texthooker JSON."
                ),
                SettingsField(
                    "continuousReconnect", "Automatically reconnect", .checkbox,
                    hint: "Keep trying to reconnect if a WebSocket disconnects in Window Mode. (In OCR Mode with “Match and fix OCR with WebSocket text” enabled, MacPopup always reconnects automatically.)"
                ),
                SettingsField("showConnectionErrors", "Show connection error messages", .checkbox),
            ]),
            SettingsSection(title: "Window Mode", symbol: "text.alignleft", fields: [
                SettingsField("boxOpacity", "Background opacity", .percentSlider(step: 0.05)),
                SettingsField(
                    "clipboardMonitor", "Read copied text from clipboard", .checkbox,
                    hint: "Automatically add text copied in other apps as a new line in the text box. Passwords from password managers are ignored."
                ),
                SettingsField(
                    "clipboardMaxLength", "Maximum clipboard text length", .number(min: 1),
                    hint: "Copied text longer than this character limit is truncated.",
                    showIf: { $0["clipboardMonitor"] as? Bool == true }
                ),
                SettingsField("fontSize", "Font size (px)", .number(min: 1)),
                SettingsField("linePadding", "Line spacing", .number(min: 0, step: 0.1)),
                SettingsField("onlineFont", "Web font", .select(support.onlineFonts.map { SettingsOption($0) })),
                SettingsField(
                    "preventLastDuplicate", "Skip duplicates within last N lines", .number(min: 0),
                    hint: "Ignores a new line if it matches any of the last N lines shown (0 = off)."
                ),
                SettingsField("maxLines", "Maximum lines kept (0 = unlimited)", .number(min: 0)),
                SettingsField(
                    "preventGlobalDuplicate", "Skip all duplicate lines", .checkbox,
                    hint: "Never show the same line more than once in the text box."
                ),
                SettingsField(
                    "mergeEqualLineStarts", "Combine lines that start with the previous line", .checkbox,
                    hint: "Replaces the previous line when a new line starts with the exact same text (useful for hooks that send growing lines character by character)."
                ),
                SettingsField("filterNonCJKLines", "Hide lines without CJK characters", .checkbox),
                SettingsField("preserveWhitespace", "Keep original spacing and indentation", .checkbox),
                SettingsField("removeAllWhitespace", "Remove all spaces", .checkbox),
                SettingsField("reverseLineOrder", "Show newest lines at the top", .checkbox),
                SettingsField("displayVertical", "Vertical text layout", .checkbox),
                SettingsField("showLinePoints", "Show bullet beside each line", .checkbox),
                SettingsField("enableLineAnimation", "Animate new lines", .checkbox),
                SettingsField("showFurigana", "Show furigana above words", .checkbox),
                SettingsField("termSpacing", "Add spaces between parsed words", .checkbox),
                SettingsField("customCSS", "Custom CSS (text box)", .textarea),
            ]),
            SettingsSection(
                title: "OCR Mode", symbol: "text.viewfinder",
                description: "Hides the floating text box and lets you hover directly over text in the captured window (or anywhere on screen if no window is selected). Requires Screen Recording permission.",
                fields: [
                    SettingsField(
                        "ocrEngine", "Text recognition engine",
                        .select([
                            SettingsOption("liveText", "Live Text"),
                            SettingsOption("meikiocr", "meikiocr"),
                            SettingsOption("screenai", "Screen AI"),
                            SettingsOption("oneocr", "OneOCR"),
                            SettingsOption("ppocrmanga", "PP-OCRv6 Manga"),
                        ]),
                        hint: "Live Text is built into macOS. meikiocr (by rtr46) is fast and specialized for Japanese game text. PP-OCRv6 Manga (by Kellenok) is specialized for Japanese and Chinese manga. Screen AI (Chrome’s OCR) and OneOCR (the Windows Snipping Tool’s) recognize most languages automatically, but require importing their model files below.",
                        warning: { settings in
                            let language = settings["language"] as? String ?? "ja"
                            let engine = settings["ocrEngine"] as? String ?? "liveText"
                            guard !OCRLanguage.isRead(language, by: engine) else { return nil }
                            let name = support.languages.first { $0.iso == language }?.name ?? language
                            return "\(name) (selected in Settings → General) isn’t supported by this engine: " + (engine == "liveText" ? "Live Text will only recognize English." : engine == "meikiocr" ? "meikiocr only recognizes Japanese." : "PP-OCRv6 Manga only recognizes Japanese and Chinese.")
                        }
                    ),
                    SettingsField(
                        "screenAIModels", "Screen AI models", .convertedModels(.screenAI),
                        hint: "Run scripts/convert-screenai.py to package the models downloaded by Google Chrome on this Mac into a .zip file, then click Load.",
                        showIf: { $0["ocrEngine"] as? String == "screenai" }
                    ),
                    SettingsField(
                        "oneOCRModels", "OneOCR models", .convertedModels(.oneOCR),
                        hint: "Run scripts/convert-oneocr.py to package the decrypted Windows Snipping Tool models (config.json and the Model_Edge folder) into a .zip file, then click Load.",
                        showIf: { $0["ocrEngine"] as? String == "oneocr" }
                    ),
                    SettingsField(
                        "ocrCloudEngine", "Cloud recognition (second pass)",
                        .select([SettingsOption("none", "None"), SettingsOption("googleLens", "Google Lens"), SettingsOption("bing", "Bing")]),
                        hint: "Re-reads the dialogue area using Google Lens or Bing for higher accuracy after local OCR finishes. Because online lookups take about a second, text updates slightly later. Sends an image of the dialogue area to Google or Microsoft. Lines matched with a WebSocket line keep its text."
                    ),
                    SettingsField(
                        "ocrResolution", "Capture resolution",
                        .select([SettingsOption("auto", "Automatic"), SettingsOption("full", "Full Retina resolution"), SettingsOption("1x", "Standard (1x)")]),
                        hint: "Automatic captures standard 1x windows (such as virtual machines or non-Retina games) at 1x for speed, and Retina windows at full resolution. Try Full Retina resolution if small text is misread, or Standard (1x) to speed up recognition."
                    ),
                    SettingsField(
                        "ocrStripFurigana", "Ignore furigana", .checkbox,
                        hint: "Skips small kana readings above or beside kanji so they aren’t read as separate lines of text (Japanese only).",
                        showIf: { $0["language"] as? String ?? "ja" == "ja" }
                    ),
                    SettingsField(
                        "ocrUseWebsocket", "Match and fix OCR with WebSocket text", .checkbox,
                        hint: "When connected to a WebSocket, scans the window whenever a new line arrives and replaces matching on-screen OCR text with the exact text from the WebSocket."
                    ),
                    SettingsField(
                        "ocrMatchThreshold", "Minimum WebSocket match (%)", .number(min: 1, max: 100),
                        hint: "How closely on-screen OCR text must match a WebSocket line to be replaced by it. Lower values fix heavily misread text, but may accidentally replace unrelated on-screen text.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrEarlierLines", "Previous WebSocket lines to match", .number(min: 0),
                        hint: "For games that keep multiple lines on screen at once, also match and fix up to this many earlier WebSocket lines. Set to 0 to only match the newest line.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrNewLineWait", "Max wait for screen update (ms)", .number(min: 0),
                        hint: "When a WebSocket line arrives, MacPopup waits for the window to visibly update before scanning, up to this time limit. Increase if a game starts drawing text late and the previous line gets read again; decrease if lines already on screen show up late.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrChangeThreshold", "Minimum screen change (%)", .number(min: 0, step: 0.1),
                        hint: "The minimum percentage of the window (or selected area) that must visually change to trigger a new scan. Helps ignore blinking cursors or subtle animations."
                    ),
                    SettingsField(
                        "ocrPollInterval", "Check for screen changes every (ms)", .number(min: 50),
                        hint: "How often the window is checked for new text. Shorter intervals detect text faster but use more CPU."
                    ),
                    SettingsField(
                        "ocrMouseWatch", "Only check for changes after mouse activity", .checkbox,
                        hint: "Saves CPU by checking for new text only briefly after you move or click the mouse (for example, when clicking to advance dialogue)."
                    ),
                    SettingsField(
                        "ocrMouseWatchTime", "Keep checking after activity for (ms)", .number(min: 0),
                        hint: "How long to keep watching for screen changes after moving or clicking the mouse, or after new dialogue arrives. Increase this if your game has long transitions before dialogue appears. Keep this value well above the check interval above.",
                        showIf: { $0["ocrMouseWatch"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrSettleTime", "Text must stay unchanged for (ms)", .number(min: 0),
                        hint: "Scans the dialogue area repeatedly until the recognized text stays unchanged for this duration, avoiding half-typed lines. WebSocket matches and secondary capture areas don’t wait."
                    ),
                    SettingsField(
                        "ocrMaxWait", "Show reading anyway after (ms)", .number(min: 100),
                        hint: "If text keeps changing continuously (such as very slow typewriter text), use the latest reading after this time limit and keep updating as more text appears."
                    ),
                    SettingsField(
                        "ocrShowBoxes", "Highlight recognized text boxes (debug)", .checkbox,
                        hint: "Draws colored outlines over recognized text for troubleshooting: red for local OCR, orange for cloud OCR, and green for WebSocket-corrected lines. Also logs each scan to ~/Library/Application Support/MacPopup/ocr-debug.jsonl."
                    ),
                ]
            ),
            SettingsSection(title: "Scanning", symbol: "cursorarrow.rays", fields: [
                SettingsField("yomitanApiUrl", "Yomitan API URL", .text(test: .yomitan)),
                SettingsField("scanModifier", "Scan modifier key (text box)", .select(scanModifierOptions)),
                SettingsField("scanInputs", "Advanced scanning inputs (text box)", .scanInputs, showIf: { $0["scanModifier"] as? String == "custom" }),
                SettingsField("popupScanModifier", "Scan modifier key (popup, for nested lookups)", .select(scanModifierOptions)),
                SettingsField("popupScanInputs", "Advanced scanning inputs (popup)", .scanInputs, showIf: { $0["popupScanModifier"] as? String == "custom" }),
                SettingsField(
                    "popupNestingMaxDepth", "Maximum number of child popups", .number(min: 0),
                    hint: "How many child popups can open from inside another popup. Set to 0 to disable nested popups."
                ),
                SettingsField(
                    "popupSearchOnClick", "Search terms when clicking text from the results list", .checkbox,
                    hint: "Clicking any word inside a popup’s definition looks it up in the same popup. Use the back button to return to the previous entry."
                ),
                SettingsField(
                    "popupScanExpressions", "Allow scanning popup source terms", .checkbox,
                    hint: "Lets you hover the main dictionary word and its reading at the top of a popup to look them up."
                ),
                SettingsField(
                    "preventBackForwardInPopups", "Disable mouse back/forward buttons in popups", .checkbox,
                    hint: "When off, your mouse’s side buttons navigate backward and forward through a popup’s lookup history."
                ),
                SettingsField(
                    "scanLength", "Text scan length", .number(min: 1),
                    hint: "How many characters ahead of the cursor to include when searching for matching dictionary terms."
                ),
                SettingsField(
                    "scanResolution", "Scan resolution",
                    .select([SettingsOption("character", "Character"), SettingsOption("word", "Word")]),
                    hint: "Start the lookup scan at the word or character of the cursor position. (Japanese, Chinese, Cantonese, and Korean always start at the character under the cursor.)"
                ),
                SettingsField(
                    "scanDelay", "Scan delay (in milliseconds)", .number(min: 0),
                    hint: "How long the cursor must rest on a word before a popup opens when no modifier key is used."
                ),
                SettingsField(
                    "scanWithoutMousemove", "Scan without mouse move", .checkbox,
                    hint: "Allow scanning words under the pointer without the pointer being in motion: pressing the scan key looks up the word under the resting pointer."
                ),
                SettingsField("selectMatchedText", "Select matched text", .checkbox, hint: "Visually highlights the matched word while its popup is open."),
                SettingsField("parser", "Parse sentences using", .select([SettingsOption("scanning-parser", "Yomitan's internal parser"), SettingsOption("mecab", "MeCab")])),
                SettingsField("autoHideResults", "Auto-hide search popup", .checkbox),
                SettingsField("hideDelay", "Auto-hide search popup delay (in milliseconds)", .number(min: 0)),
                SettingsField("hidePopupOnCursorExit", "Hide popup on cursor exit", .checkbox),
                SettingsField("hidePopupOnCursorExitDelay", "Hide popup on cursor exit delay (in milliseconds)", .number(min: 0)),
                SettingsField(
                    "sentenceScanExtent", "Sentence scanning extent", .number(min: 1),
                    hint: "How many characters around the looked-up word to scan when extracting the context sentence for Anki cards."
                ),
                SettingsField("sentenceTerminationCharacterMode", "Sentence termination characters", .select([
                    SettingsOption("custom", "Custom"),
                    SettingsOption("custom-no-newlines", "Custom, no newlines"),
                    SettingsOption("newlines", "Newlines only"),
                    SettingsOption("none", "None"),
                ])),
                SettingsField(
                    "sentenceTerminationCharacters", "Custom sentence termination characters", .terminationCharacters,
                    hint: "Defines which punctuation marks (terminators) and quotation marks end an extracted sentence, and whether to keep the mark itself inside the sentence.",
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
                        "definitionsCollapsible", "Default dictionary collapse behavior", .select([
                            SettingsOption("not-collapsible", "Not collapsible"),
                            SettingsOption("collapsed", "Collapsed"),
                            SettingsOption("expanded", "Expanded"),
                            SettingsOption("force-collapsed", "Force collapsed"),
                            SettingsOption("force-expanded", "Force expanded"),
                        ]),
                        hint: "Applies to dictionaries that don’t have a custom rule imported from Yomitan below."
                    ),
                    SettingsField(
                        "dictionaryCollapsible", "Per-dictionary collapse rules (imported from Yomitan)",
                        .imported(
                            describe: { values in
                                collapseModes(values).map { "\($0.label): \($0.names.count)" }.joined(separator: ", ")
                            },
                            emptyText: "None. Use Import → Yomitan Settings to copy them.",
                            details: { values in
                                collapseModes(values).map { "\($0.label): \($0.names.joined(separator: ", "))" }.joined(separator: "\n\n")
                            }
                        ),
                        hint: "Imported from Yomitan’s “Configure collapsible dictionaries” menu."
                    ),
                    SettingsField("audioEnabled", "Enable audio playback for terms", .checkbox, hint: "Show a clickable speaker icon next to search results."),
                    SettingsField("audioAutoPlay", "Auto-play search result audio", .checkbox),
                    SettingsField("audioVolume", "Audio volume", .number(min: 0, max: 100), hint: "Adjust the volume audio is played at, in percent."),
                    SettingsField(
                        "audioFallbackSound", "Audio fallback sound", .select([
                            SettingsOption("none", "None"), SettingsOption("click", "Click"), SettingsOption("bloop", "Bloop"),
                        ]),
                        hint: "Plays a short sound effect when none of your audio sources have a recording for the word."
                    ),
                    SettingsField(
                        "audioSources", "Audio sources", .audioSources,
                        hint: "Checked in order when you click a speaker icon. Right-click the speaker icon to pick from all available recordings; your choice is also used when creating an Anki card. Leave empty to use Yomitan’s own audio sources (or import them via Import → Yomitan Settings)."
                    ),
                    SettingsField(
                        "audioDefaultSources", "Enable default audio sources", .checkbox,
                        hint: "Also check Yomitan’s built-in sources (such as JapanesePod101, LanguagePod101, and Jisho.org) if the sources above don’t have a recording."
                    ),
                    SettingsField("customPopupCss", "Popup CSS", .textarea),
                    SettingsField("customPopupOuterCss", "Popup outer CSS", .textarea),
                    SettingsField(
                        "dictionaryStyles", "Imported dictionary styles",
                        .imported(
                            describe: { values in values.compactMap { ($0 as? [String: Any])?["name"] as? String }.joined(separator: ", ") },
                            emptyText: "None. Use Import → Yomitan Settings to copy them.",
                            isList: true
                        )
                    ),
                ]
            ),
            SettingsSection(
                title: "Popup Shortcuts", symbol: "keyboard",
                description: "Keyboard shortcuts that work whenever a dictionary popup is open—even while a game or another app is in the foreground. While a popup is visible, these keys control the popup instead of the active app.",
                fields: [SettingsField("hotkeys", "", .hotkeys)]
            ),
            SettingsSection(
                title: "Anki", symbol: "rectangle.stack.badge.plus",
                description: "Creates flashcards using the decks, note types, and field mappings from your active Yomitan profile.",
                fields: [
                    SettingsField("ankiEnabled", "Enable Anki integration", .checkbox),
                    SettingsField("ankiConnectUrl", "AnkiConnect server address", .text(test: .anki)),
                    SettingsField("ankiConnectKey", "API key", .text(), hint: "Optional. Only needed if you configured an API key in AnkiConnect."),
                    SettingsField("ankiTags", "Card tags", .text(), hint: "Tags added to every new card, separated by spaces."),
                    SettingsField(
                        "ankiRenderTemplatesLocally", "Use local Handlebars templates (enables popup text selection)", .checkbox,
                        hint: "Renders card fields directly in MacPopup instead of Yomitan so templates can use text highlighted inside a popup (via popupSelectionText)."
                    ),
                    SettingsField(
                        "yomitanAnkiTemplates", "Anki field templates (Handlebars)", .ankiTemplates,
                        hint: "Imported from Yomitan’s “Configure Anki card templates”. Only used when the local template option above is enabled."
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
                        hint: "Runs a quick duplicate check on the headword first so the add-card buttons appear right away (disabled), then enables them once the full card fields are ready.",
                        showIf: { $0["checkForDuplicates"] as? Bool == true }
                    ),
                    SettingsField("ankiDisplayTagsAndFlags", "Show card tags and flags", .select([
                        SettingsOption("never", "Never"), SettingsOption("always", "Always"),
                        SettingsOption("non-standard", "Non-standard"), SettingsOption("custom", "Custom"),
                    ]), hint: "Displays tags and flags for words already in your Anki collection. “Non-standard” hides the default card tags set above; “Custom” shows only the specific tags listed below."),
                    SettingsField(
                        "ankiTargetTags", "Target tags", .text(), hint: "List of space or comma separated tags.",
                        showIf: { $0["ankiDisplayTagsAndFlags"] as? String == "custom" }
                    ),
                    SettingsField("ankiSuspendNewCards", "Suspend new cards", .checkbox, hint: "New cards will be suspended when a note is added."),
                    SettingsField("ankiForceSync", "Force Anki sync on adding card", .checkbox),
                    SettingsField(
                        "ankiDownloadTimeout", "Idle download timeout (in milliseconds)", .number(min: 0),
                        hint: "The maximum time before an idle download will be cancelled; 0 = no limit (at most a minute). Applies to audio chosen from the speaker button’s right-click menu."
                    ),
                    SettingsField("noteGuiMode", "Note viewer window", .select([SettingsOption("browse", "Card browser"), SettingsOption("edit", "Note editor")])),
                    SettingsField("screenshotFormat", "Screenshot format", .select([SettingsOption("png", "PNG"), SettingsOption("jpeg", "JPEG")])),
                    SettingsField("screenshotQuality", "Screenshot format (quality %)", .number(min: 0, max: 100)),
                    SettingsField(
                        "screenshotResolution", "Screenshot resolution",
                        .select([SettingsOption("1x", "Standard (1x)"), SettingsOption("full", "Full Retina resolution")]),
                        hint: "Standard (1x) keeps image files small. Full Retina resolution captures sharp images at twice the width and height."
                    ),
                ]
            ),
            SettingsSection(
                title: "Anki Sentence Audio", symbol: "waveform",
                description: "Press a shortcut to automatically replay and record voice audio from your game and attach it to the Anki card you just created. MacPopup can switch to the game, press keys to open its dialogue backlog and replay the voice line, record until the character finishes speaking, and close the backlog. Requires Microphone and Accessibility permissions.",
                fields: [
                    SettingsField("sentenceAudioEnabled", "Enable sentence audio recording", .checkbox),
                    SettingsField(
                        "sentenceAudioShortcut", "Recording shortcut", .shortcut,
                        hint: "Works globally from any app. Press the shortcut again while recording to stop early and save."
                    ),
                    SettingsField(
                        "sentenceAudioDevice", "Audio input device", .audioInput,
                        hint: "The audio source to record from—typically a virtual audio device (such as BlackHole or Loopback) routed from your game."
                    ),
                    SettingsField(
                        "sentenceAudioField", "Target Anki field", .ankiField,
                        hint: "The Anki field where the recorded audio will be saved. Updates the newest card created today, and any other cards from today with the same {sentence}, if this field is empty."
                    ),
                    SettingsField("sentenceAudioApp", "App to focus before recording", .select([
                        SettingsOption("captured", "Captured window"),
                        SettingsOption("named", "Specific app by name"),
                        SettingsOption("none", "Don’t switch apps"),
                    ]), hint: "Brings the game to the front so it receives the backlog keystrokes."),
                    SettingsField(
                        "sentenceAudioAppName", "Application name", .text(), hint: "Exact app name as shown in the Dock (e.g. Parallels Desktop).",
                        showIf: { $0["sentenceAudioApp"] as? String == "named" }
                    ),
                    SettingsField(
                        "sentenceAudioOpenKeys", "Keys to open backlog and replay voice", .keySequence,
                        hint: "Keystrokes sent in order before recording starts (for example, to open the game’s text log and replay the voice line)."
                    ),
                    SettingsField(
                        "sentenceAudioCloseKeys", "Keys to close backlog", .keySequence,
                        hint: "Keystrokes sent in order after recording finishes to return to the game."
                    ),
                    SettingsField(
                        "sentenceAudioKeyDelay", "Delay after switching apps (ms)", .number(min: 0),
                        hint: "Gives the game window a moment to become active before sending keystrokes."
                    ),
                    SettingsField("sentenceAudioKeyInterval", "Delay between keystrokes (ms)", .number(min: 0)),
                    SettingsField("sentenceAudioKeyHold", "Key press duration (ms)", .number(min: 0)),
                    SettingsField(
                        "sentenceAudioRecordDelay", "Delay before recording starts (ms)", .number(min: 0),
                        hint: "Waits after pressing the replay keys before recording (useful for skipping menu sound effects). Ignored when automatic speech detection is enabled."
                    ),
                    SettingsField(
                        "sentenceAudioDetectVoice", "Automatically detect start and end of speech", .checkbox,
                        hint: "Uses speech detection to ignore background music and sound effects, keeping only the spoken line and stopping automatically when the voice ends. If turned off, press the shortcut a second time to stop recording."
                    ),
                    SettingsField(
                        "sentenceAudioVoiceWait", "Cancel if no speech is heard within (seconds)", .number(min: 1),
                        hint: "Aborts the recording without saving if no voice is detected within this time.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "sentenceAudioPause", "Stop recording after silence of (ms)", .number(min: 100),
                        hint: "How long the voice must stay silent to count as finished. Increase this if pauses in dialogue cut the recording off early.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "sentenceAudioPadding", "Padding around detected speech (ms)", .number(min: 0),
                        hint: "Extra audio kept right before the voice starts and right after it ends so words aren’t clipped.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField("sentenceAudioMaxLength", "Maximum recording length (seconds)", .number(min: 1)),
                    SettingsField("sentenceAudioPlay", "Preview recording after saving to Anki", .checkbox),
                ]
            ),
            SettingsSection(
                title: "Permissions", symbol: "lock.shield",
                description: "macOS permissions used by MacPopup features. You can grant them here or when first using a feature. If a permission was previously denied, it must be re-enabled in macOS System Settings.",
                fields: [
                    SettingsField(
                        "permission.screenRecording", "Screen Recording", .permission(.screenRecording),
                        hint: "Required for OCR Mode and for taking Anki {screenshot} captures. You may need to reopen MacPopup after granting access."
                    ),
                    SettingsField(
                        "permission.microphone", "Microphone", .permission(.microphone),
                        hint: "Required for Anki Sentence Audio to record from your chosen audio input device."
                    ),
                    SettingsField(
                        "permission.accessibility", "Accessibility", .permission(.accessibility),
                        hint: "Required for Anki Sentence Audio to focus your game window and send keystrokes to replay dialogue."
                    ),
                ]
            ),
        ]
    }()
}
