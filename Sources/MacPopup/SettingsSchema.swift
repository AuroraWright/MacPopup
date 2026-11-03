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
        "Words are looked up while all the keys and buttons of one entry are held; an empty entry looks them up on hover. "
        + "As in Yomitan, an entry combines the keys meta (Command), ctrl, alt (Option) and shift with the mouse buttons "
        + "mouse0 (left), mouse1 (right), mouse2 (middle), mouse3 (back), mouse4 (forward) and mouse5. "
        + "A - in front of a name means it must not be held: “shift -mouse0” looks up with Shift, but not while the left button is down. "
        + "Add terms or kanji to look up only words or only kanji, e.g. “alt kanji”."

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

    static let sections: [SettingsSection] = {
        let support = SettingsSupport.shared
        return [
            SettingsSection(title: "General", symbol: "gearshape", fields: [
                SettingsField("ocrMode", "Mode", .toggleChoice(off: "Window Mode", on: "OCR Mode")),
                SettingsField(
                    "language", "Language", .select(support.languages.map { SettingsOption($0.iso, $0.name) }),
                    hint: "The language of your Yomitan profile (Import → Yomitan Settings sets it). Lookups follow Yomitan’s own setting; this one picks the audio sources, how text is shown, and the language OCR Mode reads (text in other scripts is skipped)."
                ),
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
                    hint: "The window OCR Mode reads, and the one Anki screenshots ({screenshot}) show. Without one, both use the whole screen."
                ),
            ]),
            SettingsSection(title: "WebSockets", symbol: "network", fields: [
                SettingsField("websocketUrls", "WebSockets (one per line)", .lines),
                SettingsField(
                    "continuousReconnect", "Continuous reconnect", .checkbox,
                    hint: "Keep trying to reconnect when a WebSocket drops, in Window Mode. In OCR Mode with “Use WebSocket lines” on, it always does."
                ),
                SettingsField("showConnectionErrors", "Show connection errors", .checkbox),
            ]),
            SettingsSection(title: "Window Mode", symbol: "text.alignleft", fields: [
                SettingsField("boxOpacity", "Background opacity", .percentSlider(step: 0.05)),
                SettingsField(
                    "clipboardMonitor", "Enable background clipboard text monitoring", .checkbox,
                    hint: "Text you copy in any app is added to the text box as a new line. Passwords copied from password managers are skipped."
                ),
                SettingsField(
                    "clipboardMaxLength", "Maximum clipboard text search length", .number(min: 1),
                    hint: "Longer copied text is cut to this many characters.",
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
                    hint: "The kind of furigana shown in the text box (with “Show furigana” on) and in the sentence furigana of Anki cards ({sentence-furigana}). As in Yomitan, cards only use the hiragana and katakana choices."
                ),
                SettingsField("termSpacing", "Show space between parsed words", .checkbox),
                SettingsField(
                    "replacements", "Replacements", .replacements,
                    hint: "Applied in order to each new line before it’s shown. Patterns are regular expressions; in the replacement, $1 inserts the first group, \\n a line break and \\t a tab."
                ),
                SettingsField("customCSS", "Custom CSS (text box)", .textarea),
            ]),
            SettingsSection(
                title: "OCR Mode", symbol: "text.viewfinder",
                description: "Instead of the text box, reads the text in the captured window (Settings → General), or on the whole screen if none is chosen, and shows popups when you hover it. "
                    + "Needs the Screen Recording permission.",
                fields: [
                    SettingsField(
                        "ocrEngine", "Text recognition",
                        .select([SettingsOption("liveText", "Live Text"), SettingsOption("meikiocr", "meikiocr"), SettingsOption("screenai", "Screen AI"),
                                 SettingsOption("oneocr", "OneOCR")]),
                        hint: "Live Text is Apple’s, as in Preview and Photos. meikiocr (by rtr46) is made for Japanese game text and reads only Japanese. "
                            + "Screen AI (Chrome’s) and OneOCR (Windows’, as in the Snipping Tool) read most languages and detect the language themselves, but their models have to be loaded first (below).",
                        warning: { settings in
                            let language = settings["language"] as? String ?? "ja"
                            let engine = settings["ocrEngine"] as? String ?? "liveText"
                            guard !OCRLanguage.isRead(language, by: engine) else { return nil }
                            let name = support.languages.first { $0.iso == language }?.name ?? language
                            return "\(name) (Settings → General) isn’t supported: " + (engine == "liveText" ? "Live Text will read English instead." : "meikiocr reads only Japanese.")
                        }
                    ),
                    SettingsField(
                        "screenAIModels", "Screen AI models", .convertedModels(.screenAI),
                        hint: "MacPopup can’t include Google’s models: run scripts/convert-screenai.py to turn the ones Chrome downloaded on this Mac into a zip, then load it here.",
                        showIf: { $0["ocrEngine"] as? String == "screenai" }
                    ),
                    SettingsField(
                        "oneOCRModels", "OneOCR models", .convertedModels(.oneOCR),
                        hint: "MacPopup can’t include Microsoft’s models: run scripts/convert-oneocr.py to turn the Snipping Tool’s model file (oneocr.onemodel) into a zip, then load it here.",
                        showIf: { $0["ocrEngine"] as? String == "oneocr" }
                    ),
                    SettingsField(
                        "ocrCloudEngine", "Text recognition (cloud)",
                        .select([SettingsOption("none", "None"), SettingsOption("googleLens", "Google Lens"), SettingsOption("bing", "Bing")]),
                        hint: "Once a new line has been read, Google Lens or Bing reads the dialogue again, often more accurately, and its result is shown. "
                            + "They’re online services that often take a second or more, so lines show up that much later. A line that matched the WebSocket line keeps its text. The image of the dialogue (the first area) is sent to Google or Microsoft."
                    ),
                    SettingsField(
                        "ocrResolution", "Read at",
                        .select([SettingsOption("auto", "Automatic"), SettingsOption("full", "Full resolution"), SettingsOption("1x", "1x")]),
                        hint: "Automatic reads windows drawn at 1x (e.g. a VM, or a game without Retina support that macOS scales up) at 1x, which is faster and just as accurate, and everything else at full Retina resolution. If text is misread, try Full resolution for small text, or 1x if Automatic picks full resolution for a window drawn at 1x."
                    ),
                    SettingsField(
                        "ocrStripFurigana", "Strip furigana", .checkbox,
                        hint: "Leaves out furigana, the small readings over kanji (beside them in vertical text), which would otherwise be read as lines of their own. Japanese only.",
                        showIf: { $0["language"] as? String ?? "ja" == "ja" }
                    ),
                    SettingsField(
                        "ocrUseWebsocket", "Use WebSocket lines", .checkbox,
                        hint: "While a WebSocket is connected, each new line it sends also makes the window be read, and text on screen that matches the line (or part of it, such as one page of a long line) is replaced with the line’s exact text. Without a connection, this does nothing."
                    ),
                    SettingsField(
                        "ocrMatchThreshold", "Match lines from (%)", .number(min: 1, max: 100),
                        hint: "How much of a WebSocket line has to be read correctly for the text on screen to count as that line and be corrected with it. Lower values fix more badly misread text, but may mistake other text for the line.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrEarlierLines", "Earlier lines on the page", .number(min: 0),
                        hint: "Many games add lines to a page one at a time. Up to this many earlier WebSocket lines are corrected too, when they’re fully on screen. 0 corrects only the latest line.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrNewLineWait", "Wait for a new line to appear (in milliseconds)", .number(min: 0),
                        hint: "After a new WebSocket line arrives, the screen still shows the previous one until the window changes, so the new line is read after that change, or after this long without one. Raise it if a game draws lines late and the previous line shows up again; lower it if lines already on screen show up late.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrChangeThreshold", "Change threshold (%)", .number(min: 0, step: 0.1),
                        hint: "How much of the window (or of one of the chosen areas) has to change for it to be read again."
                    ),
                    SettingsField(
                        "ocrPollInterval", "Check for changes every (in milliseconds)", .number(min: 50),
                        hint: "How often the window is checked for new text: all the time, or with “Watch after mouse use” only for a while after you use the mouse. Shorter catches new text sooner but uses more CPU."
                    ),
                    SettingsField(
                        "ocrMouseWatch", "Watch after mouse use", .checkbox,
                        hint: "Only check for changes for a while after you move or click the mouse (e.g. to advance the text), instead of all the time, to save CPU while you read. Text that starts appearing in that time is still read once it’s finished."
                    ),
                    SettingsField(
                        "ocrMouseWatchTime", "Watch for (in milliseconds)", .number(min: 0),
                        hint: "How long to keep checking for changes after you move or click the mouse, and after each new line. Raise it if a game shows its next line after a long transition (otherwise it’s only read when you move the mouse again). Keep it well above “Check for changes every”.",
                        showIf: { $0["ocrMouseWatch"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrSettleTime", "Wait until unchanged for (in milliseconds)", .number(min: 0),
                        hint: "Text is read over and over until it stays the same for this long, so lines that are still being drawn aren’t caught half-finished. Text that matches the WebSocket line is used right away. Only the dialogue (the first area) waits; other areas are read as soon as they change."
                    ),
                    SettingsField(
                        "ocrMaxWait", "Read anyway after (in milliseconds)", .number(min: 100),
                        hint: "If the text keeps changing (e.g. very slow text), the latest reading is used after this long anyway, and later changes are still picked up."
                    ),
                    SettingsField(
                        "ocrShowBoxes", "Outline recognized text", .checkbox,
                        hint: "For troubleshooting: shows the recognized text over the window with each line outlined: red for plain OCR, orange for Google Lens or Bing, and green or dark green for lines corrected with a WebSocket line. Each reading is also logged to ocr-debug.jsonl in ~/Library/Application Support/MacPopup, which helps when reporting a problem."
                    ),
                ]
            ),
            SettingsSection(title: "Scanning", symbol: "cursorarrow.rays", fields: [
                SettingsField("yomitanApiUrl", "Yomitan API URL", .text(test: .yomitan)),
                SettingsField("scanModifier", "Scan modifier key (text box)", .select(scanModifierOptions)),
                SettingsField("scanInputs", "Scanning inputs (text box)", .scanInputs, showIf: { $0["scanModifier"] as? String == "custom" }),
                SettingsField("popupScanModifier", "Scan modifier key (popup, for nested lookups)", .select(scanModifierOptions)),
                SettingsField("popupScanInputs", "Scanning inputs (popup)", .scanInputs, showIf: { $0["popupScanModifier"] as? String == "custom" }),
                SettingsField(
                    "popupNestingMaxDepth", "Maximum number of child popups", .number(min: 0),
                    hint: "How many popups can open from inside other popups. 0 turns this off."
                ),
                SettingsField(
                    "popupSearchOnClick", "Search terms when clicking text from the results list", .checkbox,
                    hint: "Click a word in a popup’s definitions to look it up in the same popup; the back button returns to the previous results."
                ),
                SettingsField(
                    "popupScanExpressions", "Allow scanning popup source terms", .checkbox,
                    hint: "Lets you look up the headwords and readings shown in popups too."
                ),
                SettingsField(
                    "preventBackForwardInPopups", "Prevent mouse back and forward buttons in popups", .checkbox,
                    hint: "When off, the mouse’s back and forward buttons go through a popup’s history, as in Yomitan."
                ),
                SettingsField("scanLength", "Text scan length", .number(min: 1)),
                SettingsField(
                    "scanResolution", "Scan resolution",
                    .select([SettingsOption("character", "Character"), SettingsOption("word", "Word")]),
                    hint: "Start the lookup at the word or at the character under the cursor. As in Yomitan, Japanese, Chinese, Cantonese and Korean always start at the character."
                ),
                SettingsField("scanDelay", "Scan delay (in milliseconds)", .number(min: 0)),
                SettingsField(
                    "scanWithoutMousemove", "Scan without mouse move", .checkbox,
                    hint: "Pressing the scan key looks up the word under the pointer, even when the pointer isn’t moving."
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
                    hint: "Sentences end at punctuation (terminators) and quotation marks (quotes). “Include character in sentence” keeps a terminator, or a quote’s opening or closing mark, in the sentence.",
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
                        hint: "You can look these tags up when “Allow scanning popup source terms” is on."
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
                        hint: "For dictionaries that don’t have their own setting from Yomitan (below)."
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
                        hint: "Each enabled dictionary’s setting in Yomitan’s “Configure collapsible dictionaries”."
                    ),
                    SettingsField("audioEnabled", "Enable audio playback for terms", .checkbox, hint: "Show a speaker button next to search results."),
                    SettingsField("audioAutoPlay", "Auto-play search result audio", .checkbox),
                    SettingsField("audioVolume", "Audio volume", .number(min: 0, max: 100), hint: "The volume audio plays at, in percent."),
                    SettingsField(
                        "audioFallbackSound", "Audio fallback sound", .select([
                            SettingsOption("none", "None"), SettingsOption("click", "Click"), SettingsOption("bloop", "Bloop"),
                        ]),
                        hint: "Played when no audio is found."
                    ),
                    SettingsField(
                        "audioSources", "Audio sources", .audioSources,
                        hint: "Tried in order when you click a play button. Right-click the button to choose from all the audio the sources have, as in Yomitan; what you pick there is also used for Anki cards. With no sources here, Yomitan’s own sources are used. Import → Yomitan Settings copies them."
                    ),
                    SettingsField(
                        "audioDefaultSources", "Enable default audio sources", .checkbox,
                        hint: "Also try Yomitan’s default sources (JapanesePod101, LanguagePod101 and Jisho.org) after the ones above."
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
                description: "Yomitan’s keyboard shortcuts for popups. They work while a popup is open, even when another app such as a game is in front; until the popup closes, these keys go to it instead of the app.",
                fields: [SettingsField("hotkeys", "", .hotkeys)]
            ),
            SettingsSection(
                title: "Anki", symbol: "rectangle.stack.badge.plus",
                description: "Card formats and templates come from your active Yomitan profile, through the Yomitan API.",
                fields: [
                    SettingsField("ankiEnabled", "Enable Anki integration", .checkbox),
                    SettingsField("ankiConnectUrl", "AnkiConnect server address", .text(test: .anki)),
                    SettingsField("ankiConnectKey", "API key", .text()),
                    SettingsField("ankiTags", "Card tags", .text(), hint: "Separate tags with spaces."),
                    SettingsField(
                        "ankiRenderTemplatesLocally", "Render the field templates below instead of using the Yomitan API", .checkbox,
                        hint: "Lets templates use text selected in the popup, e.g. to pick a dictionary by selecting its name (see the README). The Yomitan API can’t see the selection."
                    ),
                    SettingsField(
                        "yomitanAnkiTemplates", "Field templates (Yomitan “Configure Anki card templates”)", .ankiTemplates,
                        hint: "Copied by Import → Yomitan Settings. Only used with the option above; otherwise Yomitan’s own templates are used."
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
                        hint: "Shows the add buttons early, disabled, after a quick duplicate check on the word alone, and enables them once the notes are ready.",
                        showIf: { $0["checkForDuplicates"] as? Bool == true }
                    ),
                    SettingsField("ankiDisplayTagsAndFlags", "Show card tags and flags", .select([
                        SettingsOption("never", "Never"), SettingsOption("always", "Always"),
                        SettingsOption("non-standard", "Non-standard"), SettingsOption("custom", "Custom"),
                    ]), hint: "For notes that already exist. Non-standard hides the card tags above; Custom shows only the target tags."),
                    SettingsField(
                        "ankiTargetTags", "Target tags", .text(), hint: "Separate tags with spaces or commas.",
                        showIf: { $0["ankiDisplayTagsAndFlags"] as? String == "custom" }
                    ),
                    SettingsField("ankiSuspendNewCards", "Suspend new cards", .checkbox, hint: "New cards are suspended when a note is added."),
                    SettingsField("ankiForceSync", "Force Anki sync on adding card", .checkbox),
                    SettingsField(
                        "ankiDownloadTimeout", "Idle download timeout (in milliseconds)", .number(min: 0),
                        hint: "An audio download that stalls for this long is canceled; 0 waits up to a minute. For audio picked from the play button’s menu; other audio uses Yomitan’s own setting."
                    ),
                    SettingsField("noteGuiMode", "Note viewer window", .select([SettingsOption("browse", "Card browser"), SettingsOption("edit", "Note editor")])),
                    SettingsField("screenshotFormat", "Screenshot format", .select([SettingsOption("png", "PNG"), SettingsOption("jpeg", "JPEG")])),
                    SettingsField("screenshotQuality", "Screenshot format (quality %)", .number(min: 0, max: 100)),
                    SettingsField(
                        "screenshotResolution", "Screenshot resolution",
                        .select([SettingsOption("1x", "1x"), SettingsOption("full", "Full resolution")]),
                        hint: "1x keeps screenshots small, the size they’d be on a non-Retina display. Full resolution uses the display’s Retina scale, twice as large in each direction."
                    ),
                ]
            ),
            SettingsSection(
                title: "Anki Sentence Audio", symbol: "waveform",
                description: "A shortcut records the voice of the line you just mined and adds it to the newest Anki cards with that sentence. It switches to the game, presses the keys that open its backlog (where the line can be replayed), records until the voice ends, then presses the keys that close the backlog. Recording needs the Microphone permission, and pressing keys needs Accessibility.",
                fields: [
                    SettingsField("sentenceAudioEnabled", "Enable sentence audio recording", .checkbox),
                    SettingsField(
                        "sentenceAudioShortcut", "Shortcut", .shortcut,
                        hint: "Works in any app. Press it again while recording to stop and keep the recording."
                    ),
                    SettingsField(
                        "sentenceAudioDevice", "Audio input", .audioInput,
                        hint: "What to record, e.g. a virtual device such as Loopback or BlackHole that the game’s sound is sent to."
                    ),
                    SettingsField(
                        "sentenceAudioField", "Sentence audio field", .ankiField,
                        hint: "The recording goes into this field, if it’s empty, on the newest card added today and on other cards added today with the same sentence (the field your Yomitan card format fills with {sentence})."
                    ),
                    SettingsField("sentenceAudioApp", "Switch to", .select([
                        SettingsOption("captured", "The captured window"),
                        SettingsOption("named", "Another app"),
                        SettingsOption("none", "Don’t switch apps"),
                    ]), hint: "The app to bring to the front so the game gets the keys. The captured window is the one chosen in Settings → General, even outside OCR Mode."),
                    SettingsField(
                        "sentenceAudioAppName", "App name", .text(), hint: "As shown in the Dock, e.g. Parallels Desktop.",
                        showIf: { $0["sentenceAudioApp"] as? String == "named" }
                    ),
                    SettingsField("sentenceAudioOpenKeys", "Keys that open the backlog", .keySequence, hint: "Pressed one after another before recording, e.g. to open the backlog and replay the line’s voice."),
                    SettingsField("sentenceAudioCloseKeys", "Keys that close the backlog", .keySequence, hint: "Pressed one after another after recording."),
                    SettingsField("sentenceAudioKeyDelay", "Wait before pressing keys (in milliseconds)", .number(min: 0), hint: "Gives the game time to accept keys after switching to it."),
                    SettingsField("sentenceAudioKeyInterval", "Wait between keys (in milliseconds)", .number(min: 0)),
                    SettingsField("sentenceAudioKeyHold", "Hold each key for (in milliseconds)", .number(min: 0)),
                    SettingsField("sentenceAudioRecordDelay", "Wait before recording (in milliseconds)", .number(min: 0), hint: "After the keys, e.g. to skip the backlog’s own sounds. Not used with “Detect when the voice starts and ends”, which waits for the voice instead."),
                    SettingsField(
                        "sentenceAudioDetectVoice", "Detect when the voice starts and ends", .checkbox,
                        hint: "Listens for speech (not music or sound effects): recording stops when the voice ends, and only the voice is kept. When off, press the shortcut again to stop."
                    ),
                    SettingsField(
                        "sentenceAudioVoiceWait", "Wait for the voice for (in seconds)", .number(min: 1),
                        hint: "Nothing is saved if no voice is heard by then.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "sentenceAudioPause", "The voice has ended after (in milliseconds)", .number(min: 100),
                        hint: "How long a silence ends the voice. Raise it if lines get cut off at pauses.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "sentenceAudioPadding", "Detected voice padding (in milliseconds)", .number(min: 0),
                        hint: "Extra audio kept before the voice starts and after it ends.",
                        showIf: { $0["sentenceAudioDetectVoice"] as? Bool ?? true }
                    ),
                    SettingsField("sentenceAudioMaxLength", "Record at most (in seconds)", .number(min: 1)),
                    SettingsField("sentenceAudioPlay", "Play the recording after adding it", .checkbox),
                ]
            ),
            SettingsSection(
                title: "Permissions", symbol: "lock.shield",
                description: "What MacPopup needs macOS’s permission for. Each one is asked for only when it’s first needed, or from here. A permission turned off in System Settings can only be turned back on there.",
                fields: [
                    SettingsField(
                        "permission.screenRecording", "Screen Recording", .permission(.screenRecording),
                        hint: "For OCR Mode and for screenshots on Anki cards ({screenshot}). macOS may ask you to reopen MacPopup after granting it."
                    ),
                    SettingsField(
                        "permission.microphone", "Microphone", .permission(.microphone),
                        hint: "For Anki Sentence Audio, to record its audio input."
                    ),
                    SettingsField(
                        "permission.accessibility", "Accessibility", .permission(.accessibility),
                        hint: "For Anki Sentence Audio, to press the keys that open and close the game’s backlog and to bring the game to the front."
                    ),
                ]
            ),
        ]
    }()
}
