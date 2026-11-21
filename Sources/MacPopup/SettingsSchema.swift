import Foundation
import OCREngines
import Transcription

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
        case select([SettingsOption])
        /// A menu of numbers (option values are the numbers as text).
        case numberSelect([SettingsOption])
        case text(test: ConnectionTest? = nil)
        /// Free text, e.g. CSS.
        case textarea
        /// A list of strings, one per line.
        case lines
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
        /// The window OCR reads, chosen on screen (see WindowPicker.swift).
        case ocrWindow
        /// An index into the connected displays (NSScreen.screens, the main one first).
        case display
        /// One global keyboard shortcut, {key, modifiers} or null.
        case shortcut
        /// Game controller buttons pressed together, by GameController's names (see Gamepads.swift).
        case gamepadCombo
        /// A global keyboard shortcut (as `shortcut`) with controller buttons for the same (as `gamepadCombo`, in the
        /// setting `buttons`), one above the other.
        case shortcutAndButtons(buttons: String)
        /// A font chosen in the Fonts panel, by its PostScript name ("" for the system font), with its size in pixels in the
        /// setting `size` and the panel's effects in the setting `effects` (see web/src/lib/settings-defaults.js).
        case font(size: String, effects: String)
        /// The connected game controllers, and learning them (gamepadLayouts; see GamepadLearning.swift).
        case gamepads
        /// Keys pressed in turn, [{key, modifiers}].
        case keySequence
        /// Settings shown together in one row, a line each with its own short label (e.g. Width and Height). The
        /// row's key isn't a setting. Only menus and numbers can be grouped.
        case group([SettingsField])
        /// A field name of the note types in Anki (from AnkiConnect).
        case ankiField
        /// Whether a macOS permission is granted, with buttons to ask for it (not a setting).
        case permission(Permission)
        /// Whether an engine's converted models are loaded, with buttons to load and remove them (not a setting).
        case convertedModels(ConvertedModelsKind)
        /// A button that opens the IINA plugin in IINA to install it (not a setting).
        case iinaPlugin
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
    /// What Option-clicking the label or hint does, if anything.
    var optionClick: (@MainActor () -> Void)?

    var id: String { key }

    init(
        _ key: String, _ label: String, _ kind: Kind, hint: String? = nil, showIf: (([String: Any]) -> Bool)? = nil,
        warning: (([String: Any]) -> String?)? = nil, optionClick: (@MainActor () -> Void)? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.hint = hint
        self.showIf = showIf
        self.warning = warning
        self.optionClick = optionClick
    }

    /// Shown across the whole width, below its label.
    var isWide: Bool {
        switch kind {
        case .textarea, .lines, .replacements, .audioSources, .scanInputs, .hotkeys, .terminationCharacters, .ankiTemplates, .gamepads: true
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

    /// The rows a Yomitan whose API has displayOptions and dictionaryInfo gives (see web/src/lib/yomitan-profile.js),
    /// shown greyed out then: these with useYomitanDisplay on, and `yomitanDictionaryKeys` always.
    static let yomitanDisplayKeys: Set = [
        "popupThemes", "popupScalingFactor", "popupDisplayMode", "fontFamily", "popupFontSize", "lineHeight", "glossaryLayoutMode",
        "compactTags", "showSearchTags", "averageFrequency", "frequencyDisplayMode", "termDisplayMode",
        "showPitchAccentDownstepNotation", "showPitchAccentPositionNotation", "showPitchAccentGraph", "popupCurrentIndicatorMode",
        "popupActionBarVisibility", "popupActionBarLocation", "customPopupCss", "customPopupOuterCss",
    ]
    static let yomitanDictionaryKeys: Set = ["definitionsCollapsible", "dictionaryCollapsible", "dictionaryStyles"]

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

    /// Whether Anki Audio's Visual novel backlog capture is on.
    private static func capturesBacklog(_ values: [String: Any]) -> Bool {
        values["sentenceAudioBacklog"] as? Bool ?? true
    }

    /// Whether Anki Audio looks for the voice: in the kept audio, or in a backlog recording with speech detection on.
    private static func detectsVoice(_ values: [String: Any]) -> Bool {
        ((values["sentenceAudioHistory"] as? NSNumber)?.doubleValue ?? 5) > 0
            || (capturesBacklog(values) && values["sentenceAudioDetectVoice"] as? Bool ?? true)
    }

    static let sections: [SettingsSection] = {
        let support = SettingsSupport.shared
        return [
            SettingsSection(title: "General", symbol: "gearshape", fields: [
                SettingsField(
                    "ocrMode", "Overlay type", .toggleChoice(off: "Floating window", on: "OCR"),
                    hint: "The Floating Window displays incoming text in a floating box. The OCR overlay reads text directly from a game or app window on screen, and you hover over it there."
                ),
                SettingsField(
                    "overlayHideShortcut", "Overlay hide key/buttons", .shortcutAndButtons(buttons: "overlayHideButtons"),
                    hint: "Hides the overlays and shows them again from any app, as Hide Overlays in the menu bar does, with a keyboard shortcut or a button combination on a game controller set up in Settings → Controllers. Your game doesn’t see the keyboard shortcut, but it does see the controller buttons, so pick buttons it doesn’t use.",
                    warning: { settings in
                        let buttons = Set(settings["overlayHideButtons"] as? [String] ?? [])
                        guard !buttons.isEmpty else { return nil }
                        if Set(settings["gamepadScanButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already used by the controller scan key, which takes priority."
                        }
                        if SentenceAudioController.isEnabled(settings), Set(settings["sentenceAudioButtons"] as? [String] ?? []) == buttons {
                            return "Anki Audio already uses these buttons, so it takes priority."
                        }
                        return nil
                    }
                ),
                SettingsField(
                    "overlaySwitchShortcut", "Overlay switch key/buttons", .shortcutAndButtons(buttons: "overlaySwitchButtons"),
                    hint: "Switches between the OCR overlay and the Floating Window from any app, with a keyboard shortcut or a button combination on a game controller set up in Settings → Controllers. Your game doesn’t see the keyboard shortcut, but it does see the controller buttons, so pick buttons it doesn’t use.",
                    warning: { settings in
                        let buttons = Set(settings["overlaySwitchButtons"] as? [String] ?? [])
                        guard !buttons.isEmpty else { return nil }
                        if Set(settings["gamepadScanButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already used by the controller scan key, which takes priority."
                        }
                        if SentenceAudioController.isEnabled(settings), Set(settings["sentenceAudioButtons"] as? [String] ?? []) == buttons {
                            return "Anki Audio already uses these buttons, so it takes priority."
                        }
                        if Set(settings["overlayHideButtons"] as? [String] ?? []) == buttons {
                            return "The overlay hide key/buttons already use these buttons, so they take priority."
                        }
                        return nil
                    }
                ),
                SettingsField(
                    "displayIndex", "Display", .display,
                    hint: "The screen where the overlay and dictionary popups appear. While OCR reads a captured window (with the OCR overlay, or “Read text from OCR” in the Floating Window), they follow that window to the screen it’s on instead."
                ),
                SettingsField(
                    "windowLevel", "Overlay window level", .select([
                        SettingsOption("floating", "Floating (above standard windows)"),
                        SettingsOption("statusBar", "Status bar"),
                        SettingsOption("popUpMenu", "Pop-up menu"),
                        SettingsOption("screenSaver", "Screen saver (default)"),
                        SettingsOption("shielding", "Shielding (highest, above games that take over the display)"),
                    ]),
                    hint: "Which windows the overlay and dictionary popups stay in front of. At lower levels, the menu bar, menus and other apps’ floating panels can cover them; Shielding is only needed for games that take over the whole display."
                ),
                SettingsField(
                    "ocrWindow", "Captured window", .ocrWindow,
                    hint: "The target window read by OCR and captured for Anki {screenshot} fields. If none is selected, the entire screen is used."
                ),
                SettingsField(
                    "theme", "Theme", .select(support.themes.map { SettingsOption($0) }),
                    hint: "The colors of the text box in the Floating Window. With the OCR overlay, it only sets the color of text highlights."
                ),
                SettingsField(
                    "language", "Language", .select(support.languages.map { SettingsOption($0.iso, $0.name) }),
                    hint: "Language of the text that is being looked up. Should match your active Yomitan profile language (automatically set when importing Yomitan settings). Also used to select default audio sources, format text, and choose the language OCR reads (text in other scripts is skipped) and transcription expects."
                ),
                SettingsField(
                    "furiganaReadingMode", "Furigana style", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("hiragana", "Hiragana (ひらがな)"),
                        SettingsOption("katakana", "Katakana (カタカナ)"),
                        SettingsOption("romaji", "Romaji"),
                        SettingsOption("dictionary-reading", "Dictionary reading"),
                    ]),
                    hint: "Change what type of furigana is displayed for parsed text, in the text box (when “Show furigana above words” is on) and in Anki’s {sentence-furigana} field. Japanese only. With the OCR overlay, it only applies to Anki cards. Note: on Anki cards, only Hiragana and Katakana change the furigana."
                ),
                SettingsField(
                    "replacements", "Text replacements", .replacements,
                    hint: "Find-and-replace rules applied in order to each new line before it appears. Supports regular expressions ($1 inserts the first capture group, \\n adds a line break, and \\t adds a tab). With the OCR overlay, they only apply to WebSocket lines, before they’re matched with the recognized text."
                ),
                SettingsField(
                    "ocrShowBoxes", "Debug", .checkbox,
                    hint: "For troubleshooting. Keeps a log of what MacPopup does to send with a bug report: lines and OCR readings, popups, shortcuts, cards added, Anki Audio and Anki Screenshot, the controller and game pauses, along with your settings and MacPopup’s version. It’s saved to ~/Library/Application Support/MacPopup/debug.jsonl (Option-click here to show it in Finder) and deleted when this is turned off. Also outlines the text the OCR overlay recognized: red while it’s still changing, orange for local OCR, gold for cloud OCR, and green for lines corrected with WebSocket text (darker with cloud OCR).",
                    optionClick: { DebugLog.reveal() }
                ),
            ]),
            SettingsSection(title: "WebSockets", symbol: "network", fields: [
                SettingsField(
                    "websocketUrls", "WebSocket URLs (one per line)", .lines,
                    hint: "Addresses of tools that send text to MacPopup (such as Textractor, Agent, LunaTranslator or owocr). Accepts plain text or texthooker JSON."
                ),
                SettingsField(
                    "continuousReconnect", "Automatically reconnect", .checkbox,
                    hint: "Keep trying to reconnect if a WebSocket disconnects. (When OCR is in use and “Match and fix OCR with WebSocket text” is on, MacPopup always reconnects.)"
                ),
                SettingsField("showConnectionErrors", "Show connection error messages", .checkbox, hint: "Shows a message when a WebSocket can’t connect, or loses its connection."),
            ]),
            SettingsSection(title: "Floating Window", symbol: "text.alignleft", fields: [
                SettingsField("boxOpacity", "Background opacity", .percentSlider(step: 0.05), hint: "How solid the text box’s background is. The text itself always stays fully visible."),
                SettingsField(
                    "clipboardMonitor", "Read copied text from clipboard", .checkbox,
                    hint: "Automatically add text copied in other apps as a new line in the text box. Passwords from password managers are ignored."
                ),
                SettingsField(
                    "clipboardMaxLength", "Maximum clipboard text length", .number(min: 1),
                    hint: "Copied text longer than this character limit is truncated.",
                    showIf: { $0["clipboardMonitor"] as? Bool == true }
                ),
                SettingsField(
                    "floatingWindowOCR", "Read text from OCR", .checkbox,
                    hint: "Reads the game’s text with OCR and adds it to the text box, like a text hooker. Only the dialogue area of the captured window is read (Settings → General → Captured window), or the whole window if there’s none. When a page fills up over time, each new sentence or paragraph becomes its own line. Lines already received over WebSocket aren’t added twice. A window might not be readable while it isn’t visible. Uses the settings in OCR, and requires Screen Recording permission."
                ),
                SettingsField(
                    "floatingWindowAudio", "Read text from audio", .checkbox,
                    hint: "Transcribes speech from the captured window’s app (or from all apps if no window is captured) and adds each sentence to the text box. Music and sound effects are skipped. Choose the model in Settings → Transcription. Requires System Audio Recording permission."
                ),
                SettingsField(
                    "boxFontFamily", "Font", .font(size: "fontSize", effects: "boxFontEffects"),
                    hint: "Select the font family/size/display properties from the macOS selector. A custom color picked here will override the theme’s color."
                ),
                SettingsField("linePadding", "Line spacing (px)", .number(min: 0), hint: "Space above and below each line in the text box (beside it in vertical text)."),
                SettingsField(
                    "preventLastDuplicate", "Skip duplicates within last N lines", .number(min: 0),
                    hint: "Ignores a new line if it matches any of the last N lines shown (0 = off)."
                ),
                SettingsField("maxLines", "Maximum lines kept (0 = unlimited)", .number(min: 0), hint: "Removes the oldest lines once the text box has more than this many."),
                SettingsField(
                    "preventGlobalDuplicate", "Skip all duplicate lines", .checkbox,
                    hint: "Never show the same line more than once in the text box."
                ),
                SettingsField(
                    "mergeEqualLineStarts", "Combine lines that start with the previous line", .checkbox,
                    hint: "Replaces the previous line when a new line starts with the exact same text (useful for hooks that send growing lines character by character)."
                ),
                SettingsField(
                    "filterNonCJKLines", "Hide lines not matching the language", .checkbox,
                    hint: "Hides lines with none of the characters of the language set in Settings → General (for Japanese, kana or kanji). Lines without letters, such as “……”, are kept. Text read with OCR is always filtered this way."
                ),
                SettingsField("preserveWhitespace", "Keep original spacing and indentation", .checkbox, hint: "Shows line breaks, repeated spaces and indentation as they came. When off, each run of them is shown as a single space."),
                SettingsField("removeAllWhitespace", "Remove all spaces", .checkbox, hint: "Removes every space and line break from new lines, also in what goes to Anki and what’s compared to skip duplicates. Useful for Japanese text that comes with stray spaces."),
                SettingsField("reverseLineOrder", "Show newest lines at the top", .checkbox, hint: "Adds new lines at the top of the text box instead of the bottom."),
                SettingsField("displayVertical", "Vertical text layout", .checkbox, hint: "Shows lines from top to bottom, in columns from right to left, as Japanese books do."),
                SettingsField("showLinePoints", "Show bullet beside each line", .checkbox, hint: "Puts a faint • before each line, which shows fully while the pointer is on that line."),
                SettingsField("enableLineAnimation", "Animate new lines", .checkbox, hint: "New lines slide in instead of appearing all at once (not while transcription shows words as they’re heard)."),
                SettingsField("showFurigana", "Show furigana above words", .checkbox, hint: "Shows readings above words with kanji, in the Furigana style set in Settings → General. Needs the Yomitan API, which splits lines into words."),
                SettingsField("termSpacing", "Add spaces between parsed words", .checkbox, hint: "Leaves a small gap between words, as Yomitan splits the line, so you can see where each word ends. Needs the Yomitan API."),
                SettingsField("customCSS", "Custom CSS (text box)", .textarea, hint: "Your own CSS for the text box, on top of the theme (for example, #lines { line-height: 1.8; })."),
            ]),
            SettingsSection(
                title: "OCR Overlay", symbol: "square.on.square.dashed",
                description: "The OCR overlay hides the floating text box so you can hover directly over the text in the captured window (or anywhere on screen if no window is selected). The window is only read while it’s visible. How text is read is set in OCR. Requires Screen Recording permission.",
                fields: [
                    SettingsField(
                        "ocrMouseWatch", "Only check for changes after input activity", .checkbox,
                        hint: "Saves CPU by checking for new text only briefly after you use the mouse, keyboard or a controller (for example, when clicking or pressing a button to advance dialogue). Controllers count once they’re set up in Settings → Controllers. (“Read text from OCR” in the Floating Window always checks for changes.)"
                    ),
                    SettingsField(
                        "ocrMouseWatchTime", "Keep checking after activity for (ms)", .number(min: 0),
                        hint: "How long to keep watching for screen changes after using the mouse, keyboard or a controller, or after new dialogue arrives. Increase this if your game has long transitions before dialogue appears. Keep this value well above “Check for screen changes every” in Settings → OCR.",
                        showIf: { $0["ocrMouseWatch"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "gamepadOcrStart", "Controller starting position",
                        .select([SettingsOption("bottom", "Bottom"), SettingsOption("top", "Top")]),
                        hint: "Where the controller starts in the OCR overlay while new text is still appearing: the bottom or top sentence of the dialogue (in vertical text, the left or right one). Once the text is complete, the controller starts at the newest line instead, such as the latest one received over WebSocket."
                    ),
                ]
            ),
            SettingsSection(
                title: "OCR", symbol: "text.viewfinder",
                description: "How text is read from the captured window (or anywhere on screen if no window is selected). Used by the OCR overlay and by “Read text from OCR” in the Floating Window. Requires Screen Recording permission.",
                fields: [
                    SettingsField(
                        "ocrEngine", "Text recognition engine",
                        .select([
                            SettingsOption("liveText", "Live Text"),
                            SettingsOption("meikiocr", "meikiocr"),
                            SettingsOption("screenai", "Screen AI"),
                            SettingsOption("oneocr", "OneOCR"),
                            SettingsOption("ppocrmanga", "PP-OCRv6 Manga"),
                            SettingsOption("midavocr6", "mida + VOCR6"),
                        ]),
                        hint: "Live Text is built into macOS. meikiocr (by rtr46) is fast and specialized for Japanese game text. PP-OCRv6 Manga (by Kellenok) is specialized for Japanese and Chinese manga. mida + VOCR6 (rtr46’s line finder with vita-vn-ocr’s reader) is fast and reads horizontal Japanese game text, but not vertical text. Screen AI (Chrome’s OCR) and OneOCR (the Windows Snipping Tool’s) recognize most languages automatically, but require importing their model files below.",
                        warning: { settings in
                            let language = settings["language"] as? String ?? "ja"
                            let engine = settings["ocrEngine"] as? String ?? "liveText"
                            guard !OCRLanguage.isRead(language, by: engine) else { return nil }
                            let name = support.languages.first { $0.iso == language }?.name ?? language
                            return "\(name) (selected in Settings → General) isn’t supported by this engine: " + (engine == "liveText" ? "Live Text will only recognize English." : engine == "meikiocr" ? "meikiocr only recognizes Japanese." : engine == "midavocr6" ? "mida + VOCR6 only recognizes Japanese." : "PP-OCRv6 Manga only recognizes Japanese and Chinese.")
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
                        hint: "Re-reads the dialogue area using Google Lens or Bing for higher accuracy after local OCR finishes. Because online lookups take about a second, text updates slightly later. Sends an image of the dialogue area to Google or Microsoft. Lines matched with a WebSocket line keep the WebSocket text."
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
                        hint: "When connected to a WebSocket, scans the window whenever a new line arrives and replaces matching on-screen OCR text with the exact text from the WebSocket. With “Read text from OCR”, this also keeps lines from being added to the text box twice."
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
                        hint: "How much of what’s drawn in the window (or selected area) must change to trigger a new scan, as a percentage: its text and pictures, not a plain background, so that a short line on an empty screen counts too. Helps ignore blinking cursors or subtle animations."
                    ),
                    SettingsField(
                        "ocrPollInterval", "Check for screen changes every (ms)", .number(min: 50),
                        hint: "How often the window is checked for new text. Shorter intervals detect text faster but use more CPU."
                    ),
                    SettingsField(
                        "ocrSettleTime", "Text must stay unchanged for (ms)", .number(min: 0),
                        hint: "Scans the dialogue area repeatedly until the recognized text stays unchanged for this duration, avoiding half-typed lines. WebSocket matches and secondary capture areas don’t wait."
                    ),
                    SettingsField(
                        "ocrMaxWait", "Show reading anyway after (ms)", .number(min: 100),
                        hint: "If text keeps changing continuously (such as very slow typewriter text), use the latest reading after this time limit and keep updating as more text appears."
                    ),
                ]
            ),
            SettingsSection(
                title: "Transcription", symbol: "captions.bubble",
                description: "Speech recognition for “Read text from audio” in the Floating Window. Models run on this Mac and aren’t included with MacPopup: make a model’s .zip file with its script, then load it here.",
                fields: [
                    SettingsField(
                        "transcriptionModel", "Speech recognition model",
                        .select([
                            SettingsOption("kitsune", "Kitsune P-0.3B"),
                            SettingsOption("animeWhisper", "anime-whisper"),
                            SettingsOption("whisper", "Whisper large-v3 turbo"),
                            SettingsOption("senseVoice", "SenseVoice Small"),
                            SettingsOption("parakeet", "Parakeet TDT 0.6B v3"),
                            SettingsOption("soda", "Live Caption"),
                        ]),
                        hint: "Kitsune (Multy123): Japanese, very fast, non-commercial use only. anime-whisper (litagin): Japanese, best on game and anime voices, slower. Whisper (OpenAI): 99 languages, about a second per line. SenseVoice (Alibaba): Chinese, Cantonese, Japanese, Korean and English, the fastest. Parakeet (NVIDIA): 25 European languages, very fast. Live Caption (Google): 16 languages, fast, with punctuation.",
                        warning: { settings in
                            let language = settings["language"] as? String ?? "ja"
                            guard let model = SpeechModel(rawValue: settings["transcriptionModel"] as? String ?? "kitsune") else { return nil }
                            let name = support.languages.first { $0.iso == language }?.name ?? language
                            // Parakeet reads its languages about as well as Whisper, 10 times faster.
                            if model == .whisper && SpeechModel.parakeet.reads(language) {
                                return "Parakeet transcribes \(name) about as accurately and 10 times faster."
                            }
                            guard !model.reads(language) else { return nil }
                            let reads = switch model {
                            case .kitsune: "Kitsune only transcribes Japanese."
                            case .animeWhisper: "anime-whisper only transcribes Japanese."
                            case .senseVoice: "SenseVoice only transcribes Chinese, Cantonese, Japanese, Korean and English."
                            case .whisper: "Whisper doesn’t transcribe it."
                            case .parakeet: "Parakeet only transcribes 25 European languages."
                            case .soda: "Live Caption doesn’t transcribe it."
                            }
                            return "Your language is \(name) (Settings → General). \(reads)"
                        }
                    ),
                    SettingsField(
                        "kitsuneModels", "Kitsune models", .convertedModels(.kitsune),
                        hint: "Run scripts/convert-kitsune.py to make a .zip file, then click Load.",
                        showIf: { ($0["transcriptionModel"] as? String ?? "kitsune") == "kitsune" }
                    ),
                    SettingsField(
                        "animeWhisperModels", "anime-whisper models", .convertedModels(.animeWhisper),
                        hint: "Run scripts/convert-anime-whisper.py to make a .zip file, then click Load. The first load takes about 2 minutes.",
                        showIf: { $0["transcriptionModel"] as? String == "animeWhisper" }
                    ),
                    SettingsField(
                        "whisperModels", "Whisper models", .convertedModels(.whisper),
                        hint: "Run scripts/convert-whisper.py to make a .zip file (add --full for the slightly more accurate 1.6 GB version), then click Load. The first load takes about 3 minutes.",
                        showIf: { $0["transcriptionModel"] as? String == "whisper" }
                    ),
                    SettingsField(
                        "senseVoiceModels", "SenseVoice models", .convertedModels(.senseVoice),
                        hint: "Run scripts/convert-sensevoice.py to make a .zip file, then click Load. The first load takes about 2 minutes.",
                        showIf: { $0["transcriptionModel"] as? String == "senseVoice" }
                    ),
                    SettingsField(
                        "parakeetModels", "Parakeet models", .convertedModels(.parakeet),
                        hint: "Run scripts/convert-parakeet.py to make a .zip file, then click Load.",
                        showIf: { $0["transcriptionModel"] as? String == "parakeet" }
                    ),
                    SettingsField(
                        "sodaModels", "Live Caption models", .convertedModels(.soda),
                        hint: "Run scripts/convert-soda.py with the languages you want (such as ja-JP en-US) to download Chrome’s language packs and make a .zip file, then click Load.",
                        showIf: { $0["transcriptionModel"] as? String == "soda" }
                    ),
                    SettingsField(
                        "transcriptionLive", "Show words as they’re heard", .checkbox,
                        hint: "Lines are filled in real time as the speaker talks and are then corrected after a pause. Disabled with Whisper and anime-whisper, as they’re not fast enough.",
                        showIf: { (SpeechModel(rawValue: $0["transcriptionModel"] as? String ?? "") ?? .kitsune).hearsLive }
                    ),
                    SettingsField(
                        "transcriptionSentenceEnds", "End lines at sentence ends", .checkbox,
                        hint: "A line goes on after a short pause until its sentence ends, and the model hears its speech again with what follows. Set the pause below to about 200 ms: a line still ends at every longer pause."
                    ),
                    SettingsField(
                        "satModels", "SaT models", .convertedModels(.sat),
                        hint: "SaT finds the sentence ends. Run scripts/convert-sat.py to make a .zip file, then click Load.",
                        showIf: { $0["transcriptionSentenceEnds"] as? Bool == true }
                    ),
                    SettingsField(
                        "transcriptionPause", "Line ends after a pause of (ms, 0 = off)", .number(min: 0),
                        hint: "How long the speaker must pause before a line is added. Shorter pauses show lines sooner, but may cut sentences in two (unless “End lines at sentence ends” is on: then try 200). For someone who talks without stopping, try 200, or 0 for a line about every 10 seconds."
                    ),
                ]
            ),
            SettingsSection(title: "Scanning", symbol: "cursorarrow.rays", fields: [
                SettingsField(
                    "yomitanApiUrl", "Yomitan API URL", .text(test: .yomitan),
                    hint: "To activate the Yomitan API, you need to install a native messaging component for your browser (Install), go to Yomitan’s settings and enable Advanced settings, and turn on Enable Yomitan API (no need to follow the other steps Yomitan mentions: Install here takes care of them)."
                ),
                SettingsField(
                    "gamePause", "Pause the game while a popup is open", .checkbox,
                    hint: "Freezes the game (the captured window’s app, or else the app in front) while you read, so it can’t move on: no auto-advance or timed text, and its voice waits. It goes on when the popup closes. Needs MacPopup’s pause helper, allowed once below; it also resumes the game if MacPopup quits. A Windows game in Parallels pauses all of Windows."
                ),
                SettingsField(
                    "permission.pauseHelper", "Pause helper", .permission(.pauseHelper),
                    hint: "Allowed in System Settings → General → Login Items. It runs as root so it can pause Parallels, and only pauses the game for MacPopup.",
                    showIf: { $0["gamePause"] as? Bool == true }
                ),
                SettingsField(
                    "gamePauseShortcut", "Pause and scan shortcut", .shortcut,
                    hint: "Works from any app. Pauses the game and, with the OCR overlay, reads its window right away, even if the text is still appearing, so you can hover over any text on screen to look it up. Press it again to close the popup and let the game go on. The game doesn’t see this shortcut, so pick keys it doesn’t need.",
                    showIf: { $0["gamePause"] as? Bool == true }
                ),
                SettingsField("scanModifier", "Scan modifier key (text box/OCR text)", .select(scanModifierOptions), hint: "Hold this key to look up words under the pointer in the text box or the OCR overlay. With No key, words are looked up as soon as the pointer rests on them; Other lets you pick keys and mouse buttons."),
                SettingsField("scanInputs", "Advanced scanning inputs", .scanInputs, showIf: { $0["scanModifier"] as? String == "custom" }),
                SettingsField(
                    "gamepadScanButtons", "Controller scan key (text box/OCR text)", .gamepadCombo,
                    hint: "Press this button combination on a game controller to start looking up words, then move through the text box or OCR text with the D-pad or a stick—one character or one word at a time, depending on Scan resolution. Press the combination again to close the popup and hand the controller back to your game. Only controllers set up in Settings → Controllers work, and while you’re looking up words, your game won’t react to them. Your game does see this combination itself, so pick buttons it doesn’t use (for example L3 + R3)."
                ),
                SettingsField(
                    "gamepadPopupDelay", "Controller popup delay (in milliseconds)", .number(min: 0),
                    hint: "How long to wait after you stop moving with the controller before the popup opens."
                ),
                SettingsField("popupScanModifier", "Scan modifier key (popup, for nested lookups)", .select(scanModifierOptions), hint: "Hold this key to look up a word inside a popup, which opens another popup over it. With No key, words in popups are looked up as soon as the pointer rests on them."),
                SettingsField("popupScanInputs", "Advanced scanning inputs (popup)", .scanInputs, showIf: { $0["popupScanModifier"] as? String == "custom" }),
                SettingsField(
                    "popupNestingMaxDepth", "Maximum number of child popups", .number(min: 0),
                    hint: "Change the limit on the number of popups that may be generated. Set to 0 to disable nested popups."
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
                    hint: "Change how many characters are read when scanning for terms."
                ),
                SettingsField(
                    "scanResolution", "Scan resolution",
                    .select([SettingsOption("character", "Character"), SettingsOption("word", "Word")]),
                    hint: "Start the lookup scan at the word or character of the cursor position. The Character option will start scanning at the cursor’s current position, while the Word option will start scanning at the beginning of the word. (Japanese, Chinese, Cantonese, and Korean always start at the character under the cursor.)"
                ),
                SettingsField(
                    "scanDelay", "Scan delay (in milliseconds)", .number(min: 0),
                    hint: "Change the delay before scanning occurs when no modifier key is required."
                ),
                SettingsField(
                    "scanWithoutMousemove", "Scan without mouse move", .checkbox,
                    hint: "Allow scanning words under the pointer without the pointer being in motion. Pressing the scan key looks up the word under the resting pointer."
                ),
                SettingsField("selectMatchedText", "Select matched text", .checkbox, hint: "Visually highlights the matched word while its popup is open."),
                SettingsField(
                    "parser", "Parse sentences using", .select([SettingsOption("scanning-parser", "Yomitan’s internal parser"), SettingsOption("mecab", "MeCab")]),
                    hint: "Yomitan’s internal parser parses sentence words using Yomitan’s dictionaries, by repeatedly detecting the longest term at the start of the sentence. Since grammatical structure is not taken into account, it can sometimes yield incorrect segmentation. MeCab is a third-party program which uses its own dictionaries and parsing algorithm, and may provide more accurate results (Japanese only). For MeCab, both MeCab and a native messaging component must be installed, and MeCab enabled in Yomitan’s settings."
                ),
                SettingsField(
                    "autoHideResults", "Auto-hide search popup", .checkbox,
                    hint: "When an existing popup is present, upon scanning again, hide the existing popup even if no definitions are found when scanning again."
                ),
                SettingsField("hideDelay", "Auto-hide search popup delay (in milliseconds)", .number(min: 0), hint: "How long to wait before “Auto-hide search popup” hides the popup."),
                SettingsField(
                    "hidePopupOnCursorExit", "Hide popup on cursor exit", .checkbox,
                    hint: "When the cursor exits the popup, the popup will be hidden."
                ),
                SettingsField("hidePopupOnCursorExitDelay", "Hide popup on cursor exit delay (in milliseconds)", .number(min: 0), hint: "How long to wait after the pointer leaves the popup before “Hide popup on cursor exit” hides it."),
                SettingsField(
                    "sentenceScanExtent", "Sentence scanning extent", .number(min: 1),
                    hint: "Adjust how many characters are bidirectionally scanned to form a sentence."
                ),
                SettingsField("sentenceTerminationCharacterMode", "Sentence termination characters", .select([
                    SettingsOption("custom", "Custom"),
                    SettingsOption("custom-no-newlines", "Custom, no newlines"),
                    SettingsOption("newlines", "Newlines only"),
                    SettingsOption("none", "None"),
                ]), hint: "What ends the sentence taken around a looked-up word (for Anki’s sentence field): the characters set below and line breaks, only those characters, only line breaks, or nothing (as much text as Sentence scanning extent allows)."),
                SettingsField(
                    "sentenceTerminationCharacters", "Custom sentence termination characters", .terminationCharacters,
                    hint: "Defines which punctuation marks (terminators) and quotation marks end an extracted sentence, and whether to keep the mark itself inside the sentence.",
                    showIf: { ["custom", "custom-no-newlines"].contains($0["sentenceTerminationCharacterMode"] as? String ?? "custom") }
                ),
            ]),
            SettingsSection(
                title: "Yomitan Popup", symbol: "rectangle.on.rectangle",
                fields: [
                    SettingsField(
                        "useYomitanDisplay", "Use Yomitan’s display settings", .checkbox,
                        hint: "Make popups look the way your Yomitan is set up (theme, scale, fonts, layout, tags, frequencies, pitch accents and custom CSS) and stay in sync when you change it there. The settings Yomitan controls are greyed out below. This needs a Yomitan that shares its settings through its API; with an older one, the settings below are used."
                    ),
                    SettingsField(
                        "popupThemes", "Theme", .group([
                            SettingsField("popupTheme", "Body", .select(themeOptions)),
                            SettingsField("popupOuterTheme", "Shadow", .select(themeOptions + [SettingsOption("none", "None")])),
                        ]),
                        hint: "Adjust the style of Yomitan."
                    ),
                    SettingsField(
                        "popupSize", "Size", .group([
                            SettingsField("popupWidth", "Width", .number(min: 1)),
                            SettingsField("popupHeight", "Height", .number(min: 1)),
                        ]),
                        hint: "Control the size of the popup, in pixels."
                    ),
                    SettingsField("popupScalingFactor", "Scale", .numberSelect(
                        [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5].map { SettingsOption("\($0 as NSNumber)", "\(Int(($0 * 100).rounded()))%") }
                    ), hint: "Control the scaling factor of the popup."),
                    SettingsField(
                        "popupHorizontalTextOffset", "Horizontal text offset", .group([
                            SettingsField("popupHorizontalOffset", "x", .number()),
                            SettingsField("popupVerticalOffset", "y", .number()),
                        ]),
                        hint: "Change the distance the popup is placed relative to horizontal text."
                    ),
                    SettingsField(
                        "popupVerticalTextOffset", "Vertical text offset", .group([
                            SettingsField("popupHorizontalOffset2", "x", .number()),
                            SettingsField("popupVerticalOffset2", "y", .number()),
                        ]),
                        hint: "Change the distance the popup is placed relative to vertical text. Used unless Vertical text positioning is Same as horizontal text."
                    ),
                    SettingsField("popupHorizontalTextPosition", "Horizontal text positioning", .select([
                        SettingsOption("below", "Below text"), SettingsOption("above", "Above text"),
                    ]), hint: "Change where the popup is positioned relative to horizontal text."),
                    SettingsField("popupVerticalTextPosition", "Vertical text positioning", .select([
                        SettingsOption("default", "Same as horizontal text"),
                        SettingsOption("before", "Before reading direction"),
                        SettingsOption("after", "After reading direction"),
                        SettingsOption("left", "Left of text"),
                        SettingsOption("right", "Right of text"),
                    ]), hint: "Change where the popup is positioned relative to vertical text."),
                    SettingsField(
                        "popupDisplayMode", "Display mode", .select([SettingsOption("default", "Default"), SettingsOption("full-width", "Full width")]),
                        hint: "Change the layout of the popup. The Default mode will position the popup relative to the scanned text. The Full width mode will anchor the popup to the top or bottom of the screen and take up the full width of the screen."
                    ),
                    SettingsField(
                        "popupFullWidthPosition", "Popup position", .select([
                            SettingsOption("top", "Top"), SettingsOption("above-cursor", "Follow Cursor"), SettingsOption("bottom", "Bottom"),
                        ]),
                        hint: "Where the full-width popup goes: along the top or the bottom of the screen (on the other side if it would cover the word), or next to the word like a normal popup.", showIf: { $0["popupDisplayMode"] as? String == "full-width" }
                    ),
                    SettingsField(
                        "fontFamily", "Font family", .text(),
                        hint: "Change the font family used in Yomitan. The font family can be changed to any font installed on your system. You can input things such as sans-serif, serif, or monospace. If you want to specify one or multiple specific fonts, you can type them in manually separated by commas, for example \"Noto Sans JP\", \"Meiryo\", sans-serif."
                    ),
                    SettingsField(
                        "popupFontSize", "Font size", .number(min: 1),
                        hint: "Change the font size used in popups, in pixels."
                    ),
                    SettingsField(
                        "lineHeight", "Line height", .text(),
                        hint: "Change the space between lines of text in popups. This will usually be a decimal number between 1 and 2."
                    ),
                    SettingsField("glossaryLayoutMode", "Compact glossaries", .select([
                        SettingsOption("default", "Default"), SettingsOption("compact", "Compact Popup"), SettingsOption("compact-popup-anki", "Compact Popup and Anki"),
                    ]), hint: "Display term glossaries using a more compact layout."),
                    SettingsField(
                        "compactTags", "Compact tags", .checkbox,
                        hint: "Show fewer repeated tags for term glossaries."
                    ),
                    SettingsField(
                        "showSearchTags", "Show tags for expressions and their readings", .checkbox,
                        hint: "These tags can be scanned if “Allow scanning popup source terms” is on."
                    ),
                    SettingsField(
                        "averageFrequency", "Average frequencies", .checkbox,
                        hint: "Compress frequency tags into one “Average” frequency tag based on the harmonic mean."
                    ),
                    SettingsField("frequencyDisplayMode", "Frequency display style", .select([
                        SettingsOption("tags", "Tags"),
                        SettingsOption("tags-grouped", "Tags, grouped content"),
                        SettingsOption("split-tags", "Split tags"),
                        SettingsOption("split-tags-grouped", "Split tags, grouped content"),
                        SettingsOption("inline-list", "Inline list"),
                        SettingsOption("list", "List"),
                        SettingsOption("list-bordered", "List, bordered"),
                    ]), hint: "Change how frequency information is presented."),
                    SettingsField("termDisplayMode", "Term display style", .select([
                        SettingsOption("ruby", "Term furigana"),
                        SettingsOption("ruby-and-reading", "Term furigana and reading"),
                        SettingsOption("term-and-reading", "Plain term and reading"),
                        SettingsOption("term-only", "Plain term"),
                    ]), hint: "Change how terms and their readings are displayed."),
                    SettingsField(
                        "showPitchAccentDownstepNotation", "Pitch accent display styles (downstep notation)", .checkbox,
                        hint: "Japanese only. Pitch accents for terms and expressions can be shown if a dictionary supporting pitch accents is installed."
                    ),
                    SettingsField("showPitchAccentPositionNotation", "Pitch accent display styles (downstep position)", .checkbox, hint: "Shows where the pitch drops as a number in brackets, for example [2]."),
                    SettingsField("showPitchAccentGraph", "Pitch accent display styles (graph)", .checkbox, hint: "Shows the pitch of each part of the word as a small graph of high and low dots."),
                    SettingsField("popupCurrentIndicatorMode", "Selection indicator style", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("asterisk", "Asterisk"),
                        SettingsOption("triangle", "Triangle"),
                        SettingsOption("bar-left", "Vertical bar (left)"),
                        SettingsOption("bar-right", "Vertical bar (right)"),
                        SettingsOption("dot-left", "Small dot (left)"),
                        SettingsOption("dot-right", "Small dot (right)"),
                    ]), hint: "Change how the selected definition entry is visually indicated."),
                    SettingsField("popupActionBarVisibility", "Action bar appearance (visibility)", .select([
                        SettingsOption("auto", "Auto"), SettingsOption("always", "Always"),
                    ]), hint: "Control when and where the action bar is visible."),
                    SettingsField("popupActionBarLocation", "Action bar appearance (location)", .select([
                        SettingsOption("left", "Left"), SettingsOption("right", "Right"), SettingsOption("top", "Top"), SettingsOption("bottom", "Bottom"),
                    ]), hint: "Which side of the popup the action bar (with the back and forward buttons) is on."),
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
                        "dictionaryCollapsible", "Per-dictionary collapse rules",
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
                    SettingsField(
                        "audioAutoPlay", "Auto-play search result audio", .checkbox,
                        hint: "The audio for the first result will be played automatically."
                    ),
                    SettingsField("audioVolume", "Audio volume", .number(min: 0, max: 100), hint: "Adjust the volume audio is played at, in percent."),
                    SettingsField(
                        "audioFallbackSound", "Audio fallback sound", .select([
                            SettingsOption("none", "None"), SettingsOption("click", "Click"), SettingsOption("bloop", "Bloop"),
                        ]),
                        hint: "The sound to play when Yomitan fails to fetch audio."
                    ),
                    SettingsField(
                        "audioSources", "Audio sources", .audioSources,
                        hint: "Checked in order when you click a speaker icon. Right-click the speaker icon to pick from all available recordings; your choice is also used when creating an Anki card. Leave empty to use Yomitan’s own audio sources (or import them via Import → Yomitan Settings)."
                    ),
                    SettingsField(
                        "audioDefaultSources", "Enable default audio sources", .checkbox,
                        hint: "Also check Yomitan’s built-in sources (such as JapanesePod101, LanguagePod101, and Jisho.org) if the sources above don’t have a recording."
                    ),
                    SettingsField("customPopupCss", "Popup CSS", .textarea, hint: "Your own CSS for what’s inside popups, like Yomitan’s Popup CSS (Import → Yomitan Settings copies yours)."),
                    SettingsField("customPopupOuterCss", "Popup outer CSS", .textarea, hint: "Your own CSS for the popup’s frame (for example, its border or shadow), like Yomitan’s Popup outer CSS."),
                    SettingsField(
                        "dictionaryStyles", "Imported dictionary styles",
                        .imported(
                            describe: { values in values.compactMap { ($0 as? [String: Any])?["name"] as? String }.joined(separator: ", ") },
                            emptyText: "None. Use Import → Yomitan Settings to copy them.",
                            isList: true
                        ),
                        hint: "The styles your dictionaries bring for their own entries, copied from Yomitan. They can only be changed in Yomitan."
                    ),
                ]
            ),
            SettingsSection(
                title: "Popup Shortcuts", symbol: "keyboard",
                description: "Keyboard shortcuts that work whenever a dictionary popup is open—even while a game or another app is in the foreground. While a popup is visible, these keys control the popup instead of the active app. You can also give a shortcut a game controller button combination with Record Buttons (the D-pad and sticks are left for moving through the text). This works with controllers set up in Settings → Controllers, and while a popup is open, your game won’t react to them.",
                fields: [SettingsField("hotkeys", "", .hotkeys)]
            ),
            SettingsSection(
                title: "Controllers", symbol: "gamecontroller",
                description: "Look up words with a game controller (set a Controller scan key in Scanning) and control popups with its buttons (add buttons to Popup Shortcuts). While you’re doing that, MacPopup takes over the controller so your game doesn’t react to it. MacPopup only uses a controller once it has learned its buttons: connect it, click Set Up, and follow the steps.",
                fields: [SettingsField("gamepadLayouts", "", .gamepads)]
            ),
            SettingsSection(
                title: "Anki", symbol: "rectangle.stack.badge.plus",
                description: "Creates flashcards using the decks, note types, and field mappings from your active Yomitan profile.",
                fields: [
                    SettingsField(
                        "ankiEnabled", "Enable Anki integration", .checkbox,
                        hint: "This option may send information contained in Yomitan dictionary entries and/or relevant user settings to Anki. When off, Anki Screenshot, Anki Audio and IINA’s card screenshots and audio are off too."
                    ),
                    SettingsField(
                        "ankiConnectUrl", "AnkiConnect server address", .text(test: .anki),
                        hint: "Change the URL of the AnkiConnect server. The default address for a server on the same device is http://127.0.0.1:8765. If Anki is running and AnkiConnect is installed, Test shows the current version of AnkiConnect."
                    ),
                    SettingsField("ankiConnectKey", "API key", .text(), hint: "Pass a secret value to AnkiConnect API calls. Only needed if you configured an API key in AnkiConnect."),
                    SettingsField("ankiTags", "Card tags", .text(), hint: "List of space or comma separated tags to add to the card."),
                    SettingsField(
                        "ankiRenderTemplatesLocally", "Use local Handlebars templates (enables popup text selection)", .checkbox,
                        hint: "Renders card fields directly in MacPopup instead of Yomitan so templates can use text highlighted inside a popup (via popupSelectionText)."
                    ),
                    SettingsField(
                        "yomitanAnkiTemplates", "Anki field templates (Handlebars)", .ankiTemplates,
                        hint: "Imported from Yomitan’s “Configure Anki card templates”. Only used when the local template option above is enabled."
                    ),
                    SettingsField("checkForDuplicates", "Check for card duplicates", .checkbox, hint: "Checks whether Anki already has a card for the word, so the popup can show it and handle adding it again as set below."),
                    SettingsField("duplicateScope", "Duplicate card scope", .select([
                        SettingsOption("collection", "Collection"), SettingsOption("deck", "Deck"), SettingsOption("deck-root", "Deck root"),
                    ]), hint: "A card is considered a duplicate if the value of the first field matches that of any other card. By default, this check will include cards across all decks in a collection, but this constraint can be relaxed by using either the Deck or Deck root option. The Deck option will only check for duplicates in the target deck. The Deck root option will additionally check for duplicates in all child decks of the root deck. This allows adding cards that are unique for decks including a subdeck structure. For decks which don’t have any parent-child hierarchy, both options function the same."),
                    SettingsField(
                        "duplicateScopeCheckAllModels", "Check for duplicates across all models", .checkbox,
                        hint: "By default, duplicate checks are only performed for notes created with the same model. Enabling this option will check for duplicates across all model types."
                    ),
                    SettingsField("duplicateBehavior", "When a duplicate is detected", .select([
                        SettingsOption("prevent", "Prevent adding"), SettingsOption("overwrite", "Allow overwriting"), SettingsOption("new", "Allow adding"),
                    ]), hint: "Overwriting a card can result in the loss of data. Duplicate cards of a different note type cannot be overwritten. If there are multiple duplicate cards, the first card found will be overwritten. You can customize overwriting for each field in Yomitan’s Configure Anki card format… menu."),
                    SettingsField(
                        "ankiNoteDupeCheckFirst", "Prioritize Anki note duplicate checks before note creation", .checkbox,
                        hint: "Recommended for those with Yomitan’s “Maximum number of results” set to a high number, and many active dictionaries. Normally, the Anki notes for each dictionary entry are created and rendered, the duplicate check is performed, and then the buttons are displayed, which may take some time. This option will perform duplicate checks first, and then show the buttons earlier, disabled and opaque. Once the notes are made, they will be re-enabled.",
                        showIf: { $0["checkForDuplicates"] as? Bool == true }
                    ),
                    SettingsField("ankiDisplayTagsAndFlags", "Show card tags and flags", .select([
                        SettingsOption("never", "Never"), SettingsOption("always", "Always"),
                        SettingsOption("non-standard", "Non-standard"), SettingsOption("custom", "Custom"),
                    ]), hint: "When coming across a word that is already in an Anki deck, two buttons can appear that show the tags and flags the card has. If set to Non-standard, all tags that are included in the Card tags option will be filtered out from the list. If set to Custom, only tags that are included in the Target tags option will be shown. If no tags remain after filtering, then the tags button will not be shown. If no flags are found, the flags button will not be shown."),
                    SettingsField(
                        "ankiTargetTags", "Target tags", .text(), hint: "List of space or comma separated tags.",
                        showIf: { $0["ankiDisplayTagsAndFlags"] as? String == "custom" }
                    ),
                    SettingsField("ankiSuspendNewCards", "Suspend new cards", .checkbox, hint: "New cards will be suspended when a note is added."),
                    SettingsField(
                        "ankiForceSync", "Force Anki sync on adding card", .checkbox,
                        hint: "May cause issues when using in conjunction with AnkiConnect Android, and/or slow or metered connections."
                    ),
                    SettingsField(
                        "ankiDownloadTimeout", "Idle download timeout (in milliseconds)", .number(min: 0),
                        hint: "The maximum time before an idle download will be cancelled; 0 = no limit (at most a minute). Applies to audio chosen from the speaker button’s right-click menu."
                    ),
                    SettingsField(
                        "noteGuiMode", "Note viewer window", .select([SettingsOption("browse", "Card browser"), SettingsOption("edit", "Note editor")]),
                        hint: "Clicking the View added note button shows this window. AnkiConnect releases after around 2022-05-29 support a new note editor window. If an error occurs, Anki and/or AnkiConnect may need to be updated."
                    ),
                ]
            ),
            SettingsSection(
                title: "Anki Screenshot", symbol: "photo",
                description: "Screenshots for your cards’ {screenshot} field. MacPopup captures only the game window picked in Settings → General, without overlays or windows covering it, or the whole screen if no window is picked.",
                fields: [
                    SettingsField(
                        "screenshotFormat", "Screenshot format", .select([SettingsOption("png", "PNG"), SettingsOption("jpeg", "JPEG")]),
                        hint: "Adjust the format and quality of screenshots created for cards."
                    ),
                    SettingsField("screenshotQuality", "Screenshot format (quality %)", .number(min: 0, max: 100), hint: "For JPEG: lower makes smaller files but blurrier pictures. PNG screenshots are always full quality."),
                    SettingsField(
                        "screenshotResolution", "Screenshot resolution",
                        .select([SettingsOption("1x", "Standard (1x)"), SettingsOption("full", "Full Retina resolution")]),
                        hint: "Standard (1x) keeps image files small. Full Retina resolution captures sharp images at twice the width and height."
                    ),
                    SettingsField(
                        "screenshotHistory", "Screenshots to keep (lines)", .number(min: 0),
                        hint: "Takes a screenshot of the game window each time a new line appears and keeps the most recent ones, so a card shows the scene of its own line even if the game has moved on. For older lines, or without a captured window, the screenshot is taken when you add the card. They’re kept in memory: a few MB for 20 JPEG screenshots, but much more as PNG or at full Retina resolution. Set to 0 to turn this off."
                    ),
                    SettingsField(
                        "screenshotDelay", "Wait before taking a screenshot (ms)", .number(min: 0),
                        hint: "Gives the game time to finish drawing the text. Lines read with OCR are captured right away, and if the next line appears first, the screenshot is taken then.",
                        showIf: { (($0["screenshotHistory"] as? NSNumber)?.intValue ?? 20) > 0 }
                    ),
                ]
            ),
            SettingsSection(
                title: "Anki Audio", symbol: "waveform",
                description: "After adding a card, press a shortcut to add the voice of its line from your game. MacPopup keeps the last few minutes of the game’s audio (from the window picked in Settings → General, or from all apps) and finds the line’s voice in it. With Visual novel backlog capture, lines it doesn’t have are replayed from the game’s backlog and recorded instead. Needs permission to record system audio, plus Accessibility permission for the backlog capture.",
                fields: [
                    SettingsField(
                        "sentenceAudioField", "Sentence audio field", .ankiField,
                        hint: "Where sentence audio goes: the voice recorded from your game, or the audio of a line from a video in IINA. It’s only filled in if it’s empty, unless you overwrite a card (see below)."
                    ),
                    SettingsField(
                        "sentenceAudioOverwrite", "Replace sentence audio when overwriting cards", .checkbox,
                        hint: "When a popup overwrites an existing card, its sentence audio is replaced with the new one: the line’s audio from IINA, or the recording made when you Option-click the add button. When off, only an empty field is filled in."
                    ),
                    SettingsField("sentenceAudioEnabled", "Enable sentence audio recording", .checkbox, hint: "Turns on adding the voice of a game’s lines to your cards. Needs “Enable Anki integration” in Settings → Anki."),
                    SettingsField(
                        "sentenceAudioShortcut", "Recording key/buttons", .shortcutAndButtons(buttons: "sentenceAudioButtons"),
                        hint: "Works from any app, with a keyboard shortcut or a button combination on a game controller set up in Settings → Controllers. The voice is added to the card you last added from a popup, and to any other cards you added from the same line. Cards added from a popup inside a popup don’t get one. You can also Option-click a popup’s add button to add a card and its voice in one go. Your game doesn’t see the keyboard shortcut, but it does see the controller buttons, so pick buttons it doesn’t use.",
                        warning: { settings in
                            let buttons = Set(settings["sentenceAudioButtons"] as? [String] ?? [])
                            guard !buttons.isEmpty, Set(settings["gamepadScanButtons"] as? [String] ?? []) == buttons else { return nil }
                            return "These controller buttons are already used by the controller scan key, which takes priority."
                        }
                    ),
                    SettingsField(
                        "sentenceAudioHistory", "Keep game audio for the last (minutes)", .number(min: 0),
                        hint: "Records the game’s audio in the background and keeps it in memory (about 11 MB per minute), so the shortcut can grab the line’s voice right away. Set to 0 to turn this off."
                    ),
                    SettingsField(
                        "sentenceAudioVoiceWait", "Cancel if no speech is heard within (seconds)", .number(min: 1),
                        hint: "Stops without saving if no voice is heard this long after the line appears (or after the backlog opens).",
                        showIf: Self.detectsVoice
                    ),
                    SettingsField(
                        "sentenceAudioPause", "Stop recording after silence of (ms)", .number(min: 100),
                        hint: "How long the voice has to stay quiet before the line counts as finished. Raise this if pauses in the dialogue cut recordings short.",
                        showIf: Self.detectsVoice
                    ),
                    SettingsField(
                        "sentenceAudioPadding", "Padding around detected speech (ms)", .number(min: 0),
                        hint: "Extra audio kept just before and after the voice, so no words get clipped.",
                        showIf: Self.detectsVoice
                    ),
                    SettingsField("sentenceAudioMaxLength", "Maximum recording length (seconds)", .number(min: 1), hint: "The longest a recording can be: it stops there even if the voice goes on."),
                    SettingsField("sentenceAudioPlay", "Preview recording after saving to Anki", .checkbox, hint: "Plays the recording once it’s added to your card, so you can hear what was saved."),
                    SettingsField(
                        "sentenceAudioBacklog", "Visual novel backlog capture", .checkbox,
                        hint: "If the line’s voice isn’t in the kept audio (it’s too old, you moved on before it finished, or no audio is kept), MacPopup switches to the game, opens its backlog with the keys below, records the voice while you replay it, then closes the backlog. Press the shortcut again to stop recording early."
                    ),
                    SettingsField("sentenceAudioApp", "App to focus before recording", .select([
                        SettingsOption("captured", "Captured window"),
                        SettingsOption("named", "Specific app by name"),
                        SettingsOption("none", "Don’t switch apps"),
                    ]), hint: "Brings the game to the front so it receives the backlog keystrokes.", showIf: Self.capturesBacklog),
                    SettingsField(
                        "sentenceAudioAppName", "Application name", .text(), hint: "The app’s exact name as shown in the Dock (e.g. Parallels Desktop).",
                        showIf: { Self.capturesBacklog($0) && $0["sentenceAudioApp"] as? String == "named" }
                    ),
                    SettingsField(
                        "sentenceAudioOpenKeys", "Keys to open backlog and replay voice", .keySequence,
                        hint: "Keystrokes sent in order before recording starts (for example, to open the game’s text log and replay the voice line).",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField(
                        "sentenceAudioCloseKeys", "Keys to close backlog", .keySequence,
                        hint: "Keystrokes sent in order after recording finishes to return to the game.",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField(
                        "sentenceAudioKeyDelay", "Delay after switching apps (ms)", .number(min: 0),
                        hint: "Gives the game window a moment to become active before sending keystrokes.",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField("sentenceAudioKeyInterval", "Delay between keystrokes (ms)", .number(min: 0), hint: "How long to wait between the backlog keystrokes, so the game has time to react to each one.", showIf: Self.capturesBacklog),
                    SettingsField("sentenceAudioKeyHold", "Key press duration (ms)", .number(min: 0), hint: "How long each key is held down. Raise this if the game misses key presses.", showIf: Self.capturesBacklog),
                    SettingsField(
                        "sentenceAudioDetectVoice", "Automatically detect start and end of speech", .checkbox,
                        hint: "Uses speech detection to leave out background music and sound effects, and stops recording when the voice ends. When off, press the shortcut again to stop recording.",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField(
                        "sentenceAudioRecordDelay", "Delay before recording starts (ms)", .number(min: 0),
                        hint: "How long to wait after pressing the replay keys before recording (handy for skipping menu sounds).",
                        showIf: { Self.capturesBacklog($0) && !($0["sentenceAudioDetectVoice"] as? Bool ?? true) }
                    ),
                ]
            ),
            SettingsSection(
                title: "IINA Integration", symbol: "film",
                description: "Make cards from videos you watch in IINA. With MacPopup’s plugin installed and connected, cards made from subtitles get a clean screenshot of the scene (without subtitles) and the line’s audio in your sentence audio field (Settings → Anki Audio). Works with network streams too, including web videos IINA plays through yt-dlp, and with live streams (from IINA’s cache, which holds about the last minute).",
                fields: [
                    SettingsField(
                        "iinaPlugin", "IINA plugin", .iinaPlugin,
                        hint: "Opens MacPopup’s plugin in IINA to install it. Then turn it on in IINA’s Settings → Plugins, restart IINA, and add ws://localhost:6680 in Settings → WebSockets."
                    ),
                    SettingsField(
                        "iinaScreenshotEnabled", "Use clean screenshots for cards", .checkbox,
                        hint: "Uses the video frame from the middle of the line, without subtitles, at the video’s own size. When off, screenshots are taken as for other cards (Settings → Anki Screenshot)."
                    ),
                    SettingsField(
                        "iinaSentenceAudioEnabled", "Use clean audio for cards", .checkbox,
                        hint: "Cuts the line’s audio from the video for the sentence audio field."
                    ),
                    SettingsField(
                        "iinaSentenceAudioPadding", "Padding around the line (ms)", .number(min: 0),
                        hint: "Extra audio kept before and after each subtitle, since voices often start a little early and end a little late.",
                        showIf: { $0["iinaSentenceAudioEnabled"] as? Bool ?? true }
                    ),
                ]
            ),
            SettingsSection(
                title: "Permissions", symbol: "lock.shield",
                description: "macOS permissions used by MacPopup features. You can grant them here or when first using a feature. If a permission was previously denied, it must be re-enabled in macOS System Settings.",
                fields: [
                    SettingsField(
                        "permission.screenRecording", "Screen Recording", .permission(.screenRecording),
                        hint: "Required for OCR and for taking Anki {screenshot} captures. You may need to reopen MacPopup after granting access."
                    ),
                    SettingsField(
                        "permission.audioCapture", "System Audio Recording", .permission(.audioCapture),
                        hint: "Needed for Anki Audio and for “Read text from audio” in the Floating Window. Shown as Screen & System Audio Recording in System Settings."
                    ),
                    SettingsField(
                        "permission.accessibility", "Accessibility", .permission(.accessibility),
                        hint: "Needed for Anki Audio’s Visual novel backlog capture to bring your game to the front and send it the keys that replay dialogue."
                    ),
                    SettingsField(
                        "permission.pauseHelper", "Pause Helper", .permission(.pauseHelper),
                        hint: "Needed to pause the game while a popup is open (Settings → Scanning). Allowed in System Settings → General → Login Items; it runs as root so it can pause Parallels."
                    ),
                ]
            ),
        ]
    }()
}
