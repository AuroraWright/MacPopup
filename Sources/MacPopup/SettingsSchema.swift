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
        /// A list of strings, one per line, at most `max` (the rest are dropped). The web pages' limits match (such as
        /// settings-defaults.js's maxWebsocketUrls).
        case lines(max: Int)
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
        /// Keys pressed in turn, [{key, modifiers}], at most `max` recorded.
        case keySequence(max: Int)
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
        /// The transcripts of IINA's videos kept, with a button to clear them (not a setting).
        case iinaTranscripts
    }

    enum ConnectionTest {
        case yomitan, anki
    }

    let key: String
    let label: String
    let kind: Kind
    /// Shown after a number, shortened (e.g. "ms" or "%").
    var unit: String?
    var hint: String?
    var showIf: (([String: Any]) -> Bool)?
    /// A problem with the settings, shown in red under the field, if any.
    var warning: (([String: Any]) -> String?)?
    /// What Option-clicking the label or hint does, if anything.
    var optionClick: (@MainActor () -> Void)?

    var id: String { key }

    init(
        _ key: String, _ label: String, _ kind: Kind, unit: String? = nil, hint: String? = nil, showIf: (([String: Any]) -> Bool)? = nil,
        warning: (([String: Any]) -> String?)? = nil, optionClick: (@MainActor () -> Void)? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.unit = unit
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
        "Hold all listed inputs to look up words, or leave an entry empty to look up on hover. "
        + "Combine modifier keys (meta for Command, ctrl, alt for Option, shift) with mouse buttons "
        + "(mouse0 for left, mouse1 for right, mouse2 for middle, mouse3 for back, mouse4 for forward, mouse5). "
        + "Prefix - to ignore lookups while held (e.g. “shift -mouse0”), "
        + "or add “terms” or “kanji” to match only words or individual kanji (e.g. “alt kanji”)."

    /// The rows a Yomitan whose API has displayOptions and dictionaryInfo gives (see web/src/lib/yomitan-profile.js),
    /// shown greyed out then: these with useYomitanDisplay on, and `yomitanDictionaryKeys` always.
    static let yomitanDisplayKeys: Set = [
        "popupThemes", "popupScalingFactor", "popupDisplayMode", "fontFamily", "popupFontSize", "lineHeight", "glossaryLayoutMode",
        "compactTags", "showSearchTags", "averageFrequency", "frequencyDisplayMode", "termDisplayMode",
        "showPitchAccentDownstepNotation", "showPitchAccentPositionNotation", "showPitchAccentGraph", "popupCurrentIndicatorMode",
        "popupActionBarVisibility", "popupActionBarLocation", "customPopupCss", "customPopupOuterCss",
    ]
    static let yomitanDictionaryKeys: Set = ["definitionsCollapsible", "dictionaryCollapsible", "dictionaryStyles"]

    /// The stored settings brought within Settings' limits (see `clamped`), at launch: an older version, or a backup
    /// edited by hand, may have saved others.
    static func clampStored() {
        let stored = SettingsStore.shared.dictionary
        let clamped = clamped(stored)
        guard !NSDictionary(dictionary: clamped).isEqual(to: stored) else { return }
        SettingsStore.shared.update(json: SettingsSupport.encode(clamped))
    }

    /// Settings brought within the limits that Settings keeps when editing, for imports: numbers in their range, lists
    /// no longer than their maximum, and one character per sentence termination character (as Yomitan's schema).
    static func clamped(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        func clamp(_ fields: [SettingsField]) {
            for field in fields {
                switch field.kind {
                case .group(let fields):
                    clamp(fields)
                case .number(let min, let max, _):
                    guard let value = (settings[field.key] as? NSNumber)?.doubleValue else { continue }
                    let clamped = Swift.min(Swift.max(value, min ?? -.infinity), max ?? .infinity)
                    if clamped != value { settings[field.key] = storedNumber(clamped) }
                case .lines(let max):
                    // As the editor keeps them: trimmed, with something on them, the first `max`.
                    guard let items = settings[field.key] as? [Any] else { continue }
                    let kept = EditedLines(limit: max).items(items.compactMap { $0 as? String }.joined(separator: "\n"))
                    if kept != items as? [String] { settings[field.key] = kept }
                case .keySequence(let max):
                    if let items = settings[field.key] as? [Any], items.count > max { settings[field.key] = Array(items.prefix(max)) }
                case .terminationCharacters:
                    guard let items = settings[field.key] as? [Any] else { continue }
                    settings[field.key] = items.map { item -> Any in
                        guard var item = item as? [String: Any] else { return item }
                        for key in ["character1", "character2"] {
                            if let text = item[key] as? String, text.count > 1 { item[key] = String(text.prefix(1)) }
                        }
                        return item
                    }
                default:
                    break
                }
            }
        }
        sections.forEach { clamp($0.fields) }
        return settings
    }

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

    /// Yomitan's popup themes; "Auto" follows the Theme setting (the text box's colors).
    private static let themeOptions = [
        SettingsOption("site", "Auto (match theme)"),
        SettingsOption("light", "Light"),
        SettingsOption("dark", "Dark"),
        SettingsOption("browser", "Browser (match macOS)"),
    ]

    /// Whether Anki Audio's Visual novel backlog capture is on.
    nonisolated private static func capturesBacklog(_ values: [String: Any]) -> Bool {
        values["sentenceAudioBacklog"] as? Bool ?? true
    }

    /// Whether Anki Audio looks for the voice: in the recorded audio, or in a backlog recording with speech detection on.
    nonisolated private static func detectsVoice(_ values: [String: Any]) -> Bool {
        ((values["sentenceAudioHistory"] as? NSNumber)?.doubleValue ?? 5) > 0
            || (capturesBacklog(values) && values["sentenceAudioDetectVoice"] as? Bool ?? true)
    }

    static let sections: [SettingsSection] = {
        let support = SettingsSupport.shared
        return [
            SettingsSection(title: "General", symbol: "gearshape", fields: [
                SettingsField(
                    "ocrMode", "Overlay type", .toggleChoice(off: "Floating window", on: "OCR"),
                    hint: "Floating Window displays lines in a customizable text box; OCR Overlay lets you look up words directly on screen."
                ),
                SettingsField(
                    "overlayHideShortcut", "Overlay hide key/buttons", .shortcutAndButtons(buttons: "overlayHideButtons"),
                    hint: "Shows or hides the overlays from any app, with a keyboard shortcut or controller buttons set up in Settings → Controllers. Keyboard shortcuts don’t reach your game, while controller buttons still pass through.",
                    warning: { settings in
                        let buttons = Set(settings["overlayHideButtons"] as? [String] ?? [])
                        guard !buttons.isEmpty else { return nil }
                        if Set(settings["gamepadScanButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already assigned to Controller scan key, which takes priority."
                        }
                        if SentenceAudioController.isEnabled(settings), Set(settings["sentenceAudioButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already used by Anki Audio, which takes priority."
                        }
                        return nil
                    }
                ),
                SettingsField(
                    "overlaySwitchShortcut", "Overlay switch key/buttons", .shortcutAndButtons(buttons: "overlaySwitchButtons"),
                    hint: "Switches between the OCR Overlay and the Floating Window from any app, with a keyboard shortcut or controller buttons set up in Settings → Controllers. Keyboard shortcuts don’t reach your game, while controller buttons still pass through.",
                    warning: { settings in
                        let buttons = Set(settings["overlaySwitchButtons"] as? [String] ?? [])
                        guard !buttons.isEmpty else { return nil }
                        if Set(settings["gamepadScanButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already assigned to Controller scan key, which takes priority."
                        }
                        if SentenceAudioController.isEnabled(settings), Set(settings["sentenceAudioButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already used by Anki Audio, which takes priority."
                        }
                        if Set(settings["overlayHideButtons"] as? [String] ?? []) == buttons {
                            return "These controller buttons are already used by the overlay hide key/buttons, which take priority."
                        }
                        return nil
                    }
                ),
                SettingsField(
                    "displayIndex", "Display", .display,
                    hint: "Display where the overlay and popups appear. When OCR is reading a captured window, the overlay follows that window’s display."
                ),
                SettingsField(
                    "windowLevel", "Overlay window level", .select([
                        SettingsOption("floating", "Floating (above standard windows)"),
                        SettingsOption("statusBar", "Status bar"),
                        SettingsOption("popUpMenu", "Pop-up menu"),
                        SettingsOption("screenSaver", "Screen saver (default)"),
                        SettingsOption("shielding", "Shielding (highest, above games that take over the display)"),
                    ]),
                    hint: "Controls which windows the overlay and popups float above; at lower levels, the menu bar, menus, or other apps’ panels may cover them. Shielding is only needed for exclusive full-screen games."
                ),
                SettingsField(
                    "ocrWindow", "Captured window", .ocrWindow,
                    hint: "Target window for OCR, Anki {screenshot} captures, sentence audio, and transcription. Uses the whole screen and system audio when none is selected."
                ),
                SettingsField(
                    "selectWindowShortcut", "Select captured window key", .shortcut,
                    hint: "Selects the captured window from any app. This shortcut isn’t passed through to your game."
                ),
                SettingsField(
                    "theme", "Theme", .select(support.themes.map { SettingsOption($0) }),
                    hint: "Color theme for the Floating Window’s text box (only affects word highlight colors in OCR Overlay mode)."
                ),
                SettingsField(
                    "language", "Language", .select(support.languages.map { SettingsOption($0.iso, $0.name) }),
                    hint: "Text language (should match your active Yomitan profile; set on Yomitan import). Also picks default audio sources, formats text, filters OCR by script, and sets the speech recognition language."
                ),
                SettingsField(
                    "furiganaReadingMode", "Furigana style", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("hiragana", "Hiragana (ひらがな)"),
                        SettingsOption("katakana", "Katakana (カタカナ)"),
                        SettingsOption("romaji", "Romaji"),
                        SettingsOption("dictionary-reading", "Dictionary reading"),
                    ]),
                    hint: "Japanese only. Furigana above kanji in the Floating Window (with “Show furigana above words” on) and in Anki’s {sentence-furigana} field, where only Hiragana and Katakana change it. In OCR Overlay mode, applies only to Anki cards."
                ),
                SettingsField(
                    "replacements", "Text replacements", .replacements,
                    hint: "Ordered find-and-replace rules (regular expressions) applied to each incoming line before display ($1 inserts capture group 1, \\n a line break, \\t a tab). In OCR Overlay mode, applies to WebSocket lines before matching on-screen text and when creating Anki cards."
                ),
                SettingsField(
                    "ocrShowBoxes", "Debug", .checkbox,
                    hint: "Records diagnostics for bug reports, including your settings and detected text, to a log file (Option-click here to reveal in Finder; deleted when turned off). In OCR Overlay mode, also outlines recognized text by state.",
                    optionClick: { DebugLog.reveal() }
                ),
            ]),
            SettingsSection(title: "WebSockets", symbol: "network", fields: [
                SettingsField(
                    "websocketUrls", "WebSocket URLs (one per line)", .lines(max: 5),
                    hint: "Up to 5 WebSocket addresses for text-sending tools (such as Textractor, Agent, LunaTranslator, or owocr). Accepts plain text or texthooker JSON."
                ),
                SettingsField(
                    "continuousReconnect", "Automatically reconnect", .checkbox,
                    hint: "Keeps trying to reconnect if a WebSocket disconnects (always active when “Match and fix OCR with WebSocket text” is used)."
                ),
                SettingsField("showConnectionErrors", "Show connection error messages", .checkbox, hint: "Shows a message when a WebSocket can’t connect, or loses its connection."),
            ]),
            SettingsSection(title: "Floating Window", symbol: "text.alignleft", fields: [
                SettingsField("boxOpacity", "Background opacity", .percentSlider(step: 0.05), hint: "Adjusts background opacity while keeping text fully visible."),
                SettingsField(
                    "clipboardMonitor", "Read copied text from clipboard", .checkbox,
                    hint: "Adds text copied in other apps as new lines (ignores passwords from password managers)."
                ),
                SettingsField(
                    "clipboardMaxLength", "Maximum clipboard text length", .number(min: 1, max: 10000),
                    hint: "Copied text longer than this character limit is truncated.",
                    showIf: { $0["clipboardMonitor"] as? Bool == true }
                ),
                SettingsField(
                    "floatingWindowOCR", "Read text from OCR", .checkbox,
                    hint: "Reads text from the captured window’s dialogue area (or entire window if no areas are set) into the text box, splitting growing pages into lines and skipping WebSocket duplicates. Uses Settings → OCR and requires Screen Recording permission; macOS may not capture hidden windows."
                ),
                SettingsField(
                    "floatingWindowAudio", "Read text from audio", .checkbox,
                    hint: "Transcribes speech from the captured window’s app (or all apps if none is selected), skipping music and sound effects. Uses Settings → Transcription and requires System Audio Recording permission."
                ),
                SettingsField(
                    "floatingWindowKeepLines", "Keep lines after quitting", .checkbox,
                    hint: "Restores lines when MacPopup reopens. Clearing lines in the text box clears saved lines too."
                ),
                SettingsField(
                    "boxFontFamily", "Font", .font(size: "fontSize", effects: "boxFontEffects"),
                    hint: "Choose the font, size, and text effects in the macOS Fonts panel; a custom text color overrides the theme."
                ),
                SettingsField("linePadding", "Line spacing", .number(min: 0, max: 100), unit: "px", hint: "Space above and below each line (beside it in vertical text)."),
                SettingsField(
                    "preventLastDuplicate", "Skip duplicates within last N lines", .number(min: 0, max: 1000),
                    hint: "Ignores a new line if it matches any of the last N lines shown (0 = off)."
                ),
                SettingsField("maxLines", "Maximum lines kept", .number(min: 0, max: 1000), hint: "Removes the oldest lines once the text box exceeds this limit (0 = 1000)."),
                SettingsField(
                    "preventGlobalDuplicate", "Skip all duplicate lines", .checkbox,
                    hint: "Ignores any line that has already appeared in the text box."
                ),
                SettingsField(
                    "mergeEqualLineStarts", "Combine lines that start with the previous line", .checkbox,
                    hint: "Replaces the previous line when a new line starts with the exact same text (for hooks sending growing lines character by character)."
                ),
                SettingsField(
                    "filterNonCJKLines", "Hide lines not matching the language", .checkbox,
                    hint: "Hides lines containing no characters from the Settings → General language (keeping punctuation-only lines such as “……”); OCR text is always filtered this way."
                ),
                SettingsField("preserveWhitespace", "Keep original spacing and indentation", .checkbox, hint: "Preserves line breaks, indentation, and repeated spaces instead of collapsing whitespace into single spaces."),
                SettingsField("removeAllWhitespace", "Remove all spaces", .checkbox, hint: "Strips all spaces and line breaks from incoming lines, including text sent to Anki and compared for duplicates."),
                SettingsField("reverseLineOrder", "Show newest lines at the top", .checkbox, hint: "Adds new lines at the top of the text box instead of the bottom."),
                SettingsField("displayVertical", "Vertical text layout", .checkbox, hint: "Shows lines from top to bottom in columns from right to left."),
                SettingsField("showLinePoints", "Show bullet beside each line", .checkbox, hint: "Puts a faint • before each line, which shows fully while the pointer is on that line."),
                SettingsField("enableLineAnimation", "Animate new lines", .checkbox, hint: "New lines slide in instead of appearing all at once (skipped during live word-by-word transcription)."),
                SettingsField("showFurigana", "Show furigana above words", .checkbox, hint: "Displays readings above kanji using your Settings → General Furigana style (requires the Yomitan API)."),
                SettingsField("termSpacing", "Add spaces between parsed words", .checkbox, hint: "Adds spacing between parsed words (requires the Yomitan API)."),
                SettingsField("customCSS", "Custom CSS", .textarea, hint: "Custom CSS for the text box, applied on top of the theme (for example, #lines { line-height: 1.8; })."),
            ]),
            SettingsSection(
                title: "OCR Overlay", symbol: "square.on.square.dashed",
                description: "Hides the floating text box so you can hover directly over text inside the captured window (or anywhere on screen if none is selected). Runs only while the window is visible, uses Settings → OCR, and requires Screen Recording permission.",
                fields: [
                    SettingsField(
                        "ocrMouseWatch", "Only check for changes after input activity", .checkbox,
                        hint: "Reduces CPU usage by checking for changes only briefly after mouse, keyboard, or configured controller input. (“Read text from OCR” always monitors continuously.)"
                    ),
                    SettingsField(
                        "ocrMouseWatchTime", "Keep checking after activity for", .number(min: 0, max: 30000), unit: "ms",
                        hint: "How long to keep checking after input activity or new dialogue (keep well above “Check for screen changes every” in Settings → OCR; raise for slow text transitions).",
                        showIf: { $0["ocrMouseWatch"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "gamepadOcrStart", "Controller starting position",
                        .select([SettingsOption("bottom", "Bottom"), SettingsOption("top", "Top")]),
                        hint: "Where controller scanning starts while dialogue is still appearing: the bottom or top sentence (left or right in vertical text). Once text settles, scanning starts at the newest line."
                    ),
                ]
            ),
            SettingsSection(
                title: "OCR", symbol: "text.viewfinder",
                description: "Recognition settings for the captured window (or entire screen if none is selected), shared by OCR Overlay and “Read text from OCR”. Requires Screen Recording permission.",
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
                        hint: "Live Text (macOS): built in. meikiocr (rtr46): fast, for Japanese game text. PP-OCRv6 Manga (Kellenok): for Japanese and Chinese manga. mida + VOCR6 (rtr46 + vita-vn-ocr): the fastest, horizontal and vertical Japanese game text. Screen AI (Chrome): fast and close in accuracy to Google Lens. OneOCR (Windows Snipping Tool): accurate but slower. Screen AI and OneOCR require importing their converted models below.",
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
                        hint: "Re-reads the dialogue area with Google Lens or Bing after local OCR finishes (about a second later; sends an image of the dialogue area to Google or Microsoft). WebSocket-matched lines keep their WebSocket text."
                    ),
                    SettingsField(
                        "ocrResolution", "Capture resolution",
                        .select([SettingsOption("auto", "Automatic"), SettingsOption("full", "Full Retina resolution"), SettingsOption("1x", "Standard (1x)")]),
                        hint: "Automatic captures 1x windows (such as virtual machines or non-Retina games) at 1x for speed, and Retina windows at full resolution. Try Full Retina if small text is misread, or Standard (1x) for speed."
                    ),
                    SettingsField(
                        "ocrStripFurigana", "Ignore furigana", .checkbox,
                        hint: "Skips small kana above or beside kanji so they aren’t read as separate lines (Japanese only).",
                        showIf: { $0["language"] as? String ?? "ja" == "ja" }
                    ),
                    SettingsField(
                        "ocrUseWebsocket", "Match and fix OCR with WebSocket text", .checkbox,
                        hint: "Scans when a WebSocket line arrives and replaces matching OCR text with the exact WebSocket text (also prevents duplicates in “Read text from OCR”).",
                    ),
                    SettingsField(
                        "ocrMatchThreshold", "Minimum WebSocket match", .number(min: 1, max: 100), unit: "%",
                        hint: "Required similarity for OCR text to be replaced by a WebSocket line. Lower values fix heavier misreads but may match unrelated text.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrEarlierLines", "Previous WebSocket lines to match", .number(min: 0, max: 100),
                        hint: "For multi-line screens, also match up to this many earlier WebSocket lines (0 matches only the newest line).",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrNewLineWait", "Max wait for screen update", .number(min: 0, max: 10000), unit: "ms",
                        hint: "Maximum wait for the window to visibly update after a WebSocket line arrives. Increase if the previous line gets re-read; decrease if lines already on screen appear late.",
                        showIf: { $0["ocrUseWebsocket"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "ocrChangeThreshold", "Minimum screen change", .number(min: 0, max: 20, step: 0.1), unit: "%",
                        hint: "Percentage of drawn content (excluding plain backgrounds) that must change to trigger a scan, helping short lines register while ignoring cursors or subtle animations."
                    ),
                    SettingsField(
                        "ocrPollInterval", "Check for screen changes every", .number(min: 50, max: 5000), unit: "ms",
                        hint: "How often the window is checked for new text. Shorter intervals detect text faster but use more CPU."
                    ),
                    SettingsField(
                        "ocrSettleTime", "Text must stay unchanged for", .number(min: 0, max: 5000), unit: "ms",
                        hint: "Time recognized text must stay unchanged before updating, avoiding half-typed lines (WebSocket matches and secondary capture areas don’t wait)."
                    ),
                    SettingsField(
                        "ocrMaxWait", "Show reading anyway after", .number(min: 100, max: 30000), unit: "ms",
                        hint: "If text keeps changing (such as slow typewriter text), waits at most this time to show a reading and then keeps updating as more text appears."
                    ),
                ]
            ),
            SettingsSection(
                title: "Transcription", symbol: "captions.bubble",
                description: "Local speech recognition for “Read text from audio”. Models aren’t included with MacPopup—package one into a .zip file using its script, then load it below.",
                fields: [
                    SettingsField(
                        "transcriptionModel", "Speech recognition model",
                        .select([
                            SettingsOption("soda", "Live Caption"),
                            SettingsOption("kitsune", "Kitsune P-0.3B"),
                            SettingsOption("senseVoice", "SenseVoice Small"),
                            SettingsOption("parakeet", "Parakeet TDT 0.6B v3"),
                            SettingsOption("whisper", "Whisper large-v3 turbo"),
                            SettingsOption("animeWhisper", "anime-whisper"),
                        ]),
                        hint: "Live Caption (Google): 16 languages, fast, punctuated. Kitsune (Multy123): Japanese, very fast. SenseVoice (Alibaba): Chinese, Cantonese, Japanese, Korean, and English; fastest. Parakeet (NVIDIA): 25 European languages, very fast. Whisper (OpenAI): 99 languages, ~1 second per line. anime-whisper (litagin): Japanese, most accurate for game and anime voices; slower.",
                        warning: { settings in
                            let language = settings["language"] as? String ?? "ja"
                            guard let model = SpeechModel(rawValue: settings["transcriptionModel"] as? String ?? "soda") else { return nil }
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
                            case .whisper: "Whisper doesn’t transcribe this language."
                            case .parakeet: "Parakeet only transcribes 25 European languages."
                            case .soda: "Live Caption doesn’t transcribe this language."
                            }
                            return "Your language is \(name) (Settings → General). \(reads)"
                        }
                    ),
                    SettingsField(
                        "kitsuneModels", "Kitsune models", .convertedModels(.kitsune),
                        hint: "Run scripts/convert-kitsune.py to make a .zip file, then click Load.",
                        showIf: { $0["transcriptionModel"] as? String == "kitsune" }
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
                        showIf: { ($0["transcriptionModel"] as? String ?? "soda") == "soda" }
                    ),
                    SettingsField(
                        "transcriptionLive", "Show words as they’re heard", .checkbox,
                        hint: "Fills lines in real time as the speaker talks, then refines them after a pause (unavailable with Whisper and anime-whisper).",
                        showIf: { (SpeechModel(rawValue: $0["transcriptionModel"] as? String ?? "") ?? .soda).hearsLive }
                    ),
                    SettingsField(
                        "transcriptionSentenceEnds", "Detect sentence ends", .checkbox,
                        hint: "Makes line splits more accurate by detecting sentence ends."
                    ),
                    SettingsField(
                        "satModels", "SaT models", .convertedModels(.sat),
                        hint: "Run scripts/convert-sat.py to make a .zip file, then click Load.",
                        showIf: { $0["transcriptionSentenceEnds"] as? Bool == true }
                    ),
                    SettingsField(
                        "transcriptionPause", "Line ends after a pause of", .number(min: 0, max: 5000), unit: "ms",
                        hint: "Silence required before finalizing a line (0 splits about every 10 seconds). Shorter values appear sooner but may split mid-sentence; try 200 ms with continuous speech or “Detect sentence ends”."
                    ),
                ]
            ),
            SettingsSection(title: "Scanning", symbol: "cursorarrow.rays", fields: [
                SettingsField(
                    "yomitanApiUrl", "Yomitan API URL", .text(test: .yomitan),
                    hint: "Click Install, then turn on Advanced and Enable Yomitan API in Yomitan’s settings (Install handles the other setup steps)."
                ),
                SettingsField(
                    "gamePause", "Pause the game while a popup is open", .checkbox,
                    hint: "Pauses the captured app (or frontmost app) while a popup is open, stopping auto-advance, timers, and dialogue. Requires Pause helper below, which automatically resumes the game if MacPopup quits; pauses the entire virtual machine for Parallels games."
                ),
                SettingsField(
                    "permission.pauseHelper", "Pause helper", .permission(.pauseHelper),
                    hint: "Enabled in System Settings → General → Login Items. Runs with root privileges to pause Parallels, acting only when requested by MacPopup.",
                    showIf: { $0["gamePause"] as? Bool == true }
                ),
                SettingsField(
                    "gamePauseShortcut", "Pause and scan shortcut", .shortcut,
                    hint: "Works from any app (not passed through to your game). Pauses the game and lets you look up text as it’s still animating; press again to close and resume.",
                    showIf: { $0["gamePause"] as? Bool == true }
                ),
                SettingsField("scanModifier", "Scan modifier key (text box/OCR text)", .select(scanModifierOptions), hint: "Hold this key to look up words in the Floating Window or OCR Overlay (No key scans on hover; Other combines keys and mouse buttons)."),
                SettingsField("scanInputs", "Advanced scanning inputs", .scanInputs, showIf: { $0["scanModifier"] as? String == "custom" }),
                SettingsField(
                    "gamepadScanButtons", "Controller scan key (text box/OCR text)", .gamepadCombo,
                    hint: "Starts or stops controller scanning using the D-pad or a thumbstick (on controllers set up in Settings → Controllers; steps by Scan resolution). Hides controller input from your game while scanning, though this combination still passes through—choose unused buttons (such as L3 + R3)."
                ),
                SettingsField(
                    "gamepadPopupDelay", "Controller popup delay", .number(min: 0, max: 5000), unit: "ms",
                    hint: "How long to wait after stopping controller navigation before opening the popup."
                ),
                SettingsField("popupScanModifier", "Scan modifier key (popup, for nested lookups)", .select(scanModifierOptions), hint: "Hold this key to look up words inside an open popup (No key looks up on hover)."),
                SettingsField("popupScanInputs", "Advanced scanning inputs (popup)", .scanInputs, showIf: { $0["popupScanModifier"] as? String == "custom" }),
                SettingsField(
                    "popupNestingMaxDepth", "Maximum number of child popups", .number(min: 0, max: 20),
                    hint: "Maximum number of nested child popups (0 disables nested popups)."
                ),
                SettingsField(
                    "popupSearchOnClick", "Search terms when clicking text from the results list", .checkbox,
                    hint: "Clicking any word in a definition opens it in the same popup (use Back to return)."
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
                    "scanLength", "Text scan length", .number(min: 1, max: 100),
                    hint: "Maximum characters read when scanning for terms."
                ),
                SettingsField(
                    "scanResolution", "Scan resolution",
                    .select([SettingsOption("character", "Character"), SettingsOption("word", "Word")]),
                    hint: "Starts lookups at the character under the pointer, or at the beginning of the word. (Japanese, Chinese, Cantonese, and Korean always start at the character.)"
                ),
                SettingsField(
                    "scanDelay", "Scan delay", .number(min: 0, max: 2000), unit: "ms",
                    hint: "Delay before scanning occurs when no modifier key is required."
                ),
                SettingsField(
                    "scanWithoutMousemove", "Scan without mouse move", .checkbox,
                    hint: "Allows scanning under a resting pointer when the scan key is pressed."
                ),
                SettingsField("selectMatchedText", "Select matched text", .checkbox, hint: "Visually highlights the matched word while its popup is open."),
                SettingsField(
                    "parser", "Parse sentences using", .select([SettingsOption("scanning-parser", "Yomitan’s internal parser"), SettingsOption("mecab", "MeCab")]),
                    hint: "Yomitan’s internal parser segments by longest dictionary match without grammar analysis. MeCab (Japanese only) uses its own parser and dictionaries for more accurate results; requires installing MeCab and its native messaging component and enabling MeCab in Yomitan."
                ),
                SettingsField(
                    "autoHideResults", "Auto-hide search popup", .checkbox,
                    hint: "Hides an existing popup when scanning again, even if no definitions are found."
                ),
                SettingsField("hideDelay", "Auto-hide search popup delay", .number(min: 0, max: 5000), unit: "ms", hint: "How long to wait before “Auto-hide search popup” hides the popup."),
                SettingsField(
                    "hidePopupOnCursorExit", "Hide popup on cursor exit", .checkbox,
                    hint: "Hides the popup when the pointer leaves it."
                ),
                SettingsField("hidePopupOnCursorExitDelay", "Hide popup on cursor exit delay", .number(min: 0, max: 5000), unit: "ms", hint: "Delay after the pointer leaves the popup before hiding it."),
                SettingsField(
                    "sentenceScanExtent", "Sentence scanning extent", .number(min: 1, max: 1000),
                    hint: "Maximum characters scanned in both directions to form a sentence."
                ),
                SettingsField("sentenceTerminationCharacterMode", "Sentence termination characters", .select([
                    SettingsOption("custom", "Custom"),
                    SettingsOption("custom-no-newlines", "Custom, no newlines"),
                    SettingsOption("newlines", "Newlines only"),
                    SettingsOption("none", "None"),
                ]), hint: "How Anki sentence boundaries are detected: custom characters and line breaks, custom characters only, line breaks only, or none (up to Sentence scanning extent)."),
                SettingsField(
                    "sentenceTerminationCharacters", "Custom sentence termination characters", .terminationCharacters,
                    hint: "Defines punctuation marks (terminators) and quotation marks that end an extracted sentence, and whether to include the mark itself.",
                    showIf: { ["custom", "custom-no-newlines"].contains($0["sentenceTerminationCharacterMode"] as? String ?? "custom") }
                ),
            ]),
            SettingsSection(
                title: "Yomitan Popup", symbol: "rectangle.on.rectangle",
                fields: [
                    SettingsField(
                        "useYomitanDisplay", "Use Yomitan’s display settings", .checkbox,
                        hint: "Syncs popup appearance (theme, scale, fonts, layout, tags, frequencies, pitch accents, and custom CSS) from Yomitan; synced settings appear dimmed below. Older versions of Yomitan fall back to the settings below."
                    ),
                    SettingsField(
                        "popupThemes", "Theme", .group([
                            SettingsField("popupTheme", "Body", .select(themeOptions)),
                            SettingsField("popupOuterTheme", "Shadow", .select(themeOptions + [SettingsOption("none", "None")])),
                        ]),
                        hint: "Popup inner body and outer shadow themes."
                    ),
                    SettingsField(
                        "popupSize", "Size", .group([
                            SettingsField("popupWidth", "Width", .number(min: 100, max: 2000), unit: "px"),
                            SettingsField("popupHeight", "Height", .number(min: 100, max: 2000), unit: "px"),
                        ]),
                        hint: "Popup width and height."
                    ),
                    SettingsField("popupScalingFactor", "Scale", .numberSelect(
                        [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5].map { SettingsOption("\($0 as NSNumber)", "\(Int(($0 * 100).rounded()))%") }
                    ), hint: "Popup scaling factor."),
                    SettingsField(
                        "popupHorizontalTextOffset", "Horizontal text offset", .group([
                            SettingsField("popupHorizontalOffset", "x", .number(min: -200, max: 200), unit: "px"),
                            SettingsField("popupVerticalOffset", "y", .number(min: -200, max: 200), unit: "px"),
                        ]),
                        hint: "Distance from the popup to horizontal text."
                    ),
                    SettingsField(
                        "popupVerticalTextOffset", "Vertical text offset", .group([
                            SettingsField("popupHorizontalOffset2", "x", .number(min: -200, max: 200), unit: "px"),
                            SettingsField("popupVerticalOffset2", "y", .number(min: -200, max: 200), unit: "px"),
                        ]),
                        hint: "Distance from the popup to vertical text. Unused if Vertical text positioning is Same as horizontal text."
                    ),
                    SettingsField("popupHorizontalTextPosition", "Horizontal text positioning", .select([
                        SettingsOption("below", "Below text"), SettingsOption("above", "Above text"),
                    ]), hint: "Popup position relative to horizontal text."),
                    SettingsField("popupVerticalTextPosition", "Vertical text positioning", .select([
                        SettingsOption("default", "Same as horizontal text"),
                        SettingsOption("before", "Before reading direction"),
                        SettingsOption("after", "After reading direction"),
                        SettingsOption("left", "Left of text"),
                        SettingsOption("right", "Right of text"),
                    ]), hint: "Popup position relative to vertical text."),
                    SettingsField(
                        "popupDisplayMode", "Display mode", .select([SettingsOption("default", "Default"), SettingsOption("full-width", "Full width")]),
                        hint: "Default positions popups relative to scanned text; Full width spans the full screen width at the top or bottom."
                    ),
                    SettingsField(
                        "popupFullWidthPosition", "Popup position", .select([
                            SettingsOption("top", "Top"), SettingsOption("above-cursor", "Follow Cursor"), SettingsOption("bottom", "Bottom"),
                        ]),
                        hint: "Placement in Full width mode: anchored to the top or bottom (switching sides if it would cover the word), or near the cursor.", showIf: { $0["popupDisplayMode"] as? String == "full-width" }
                    ),
                    SettingsField(
                        "fontFamily", "Font family", .text(),
                        hint: "System or CSS fonts for popups, comma-separated (e.g. \"Noto Sans JP\", \"Meiryo\", sans-serif)."
                    ),
                    SettingsField(
                        "popupFontSize", "Font size", .number(min: 8, max: 48), unit: "px",
                        hint: "Popup font size."
                    ),
                    SettingsField(
                        "lineHeight", "Line height", .text(),
                        hint: "Space between lines in popups (usually a decimal between 1 and 2)."
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
                    ]), hint: "How frequency information is presented."),
                    SettingsField("termDisplayMode", "Term display style", .select([
                        SettingsOption("ruby", "Term furigana"),
                        SettingsOption("ruby-and-reading", "Term furigana and reading"),
                        SettingsOption("term-and-reading", "Plain term and reading"),
                        SettingsOption("term-only", "Plain term"),
                    ]), hint: "How terms and their readings are displayed."),
                    SettingsField(
                        "showPitchAccentDownstepNotation", "Pitch accent display styles (downstep notation)", .checkbox,
                        hint: "Japanese only. Shows pitch accents if a pitch accent dictionary is installed."
                    ),
                    SettingsField("showPitchAccentPositionNotation", "Pitch accent display styles (downstep position)", .checkbox, hint: "Shows where the pitch drops as a number in brackets (e.g. [2])."),
                    SettingsField("showPitchAccentGraph", "Pitch accent display styles (graph)", .checkbox, hint: "Shows pitch across each part of the word as a small graph of high and low dots."),
                    SettingsField("popupCurrentIndicatorMode", "Selection indicator style", .select([
                        SettingsOption("none", "None"),
                        SettingsOption("asterisk", "Asterisk"),
                        SettingsOption("triangle", "Triangle"),
                        SettingsOption("bar-left", "Vertical bar (left)"),
                        SettingsOption("bar-right", "Vertical bar (right)"),
                        SettingsOption("dot-left", "Small dot (left)"),
                        SettingsOption("dot-right", "Small dot (right)"),
                    ]), hint: "How the selected definition entry is visually indicated."),
                    SettingsField("popupActionBarVisibility", "Action bar appearance (visibility)", .select([
                        SettingsOption("auto", "Auto"), SettingsOption("always", "Always"),
                    ]), hint: "Controls when the action bar is visible."),
                    SettingsField("popupActionBarLocation", "Action bar appearance (location)", .select([
                        SettingsOption("left", "Left"), SettingsOption("right", "Right"), SettingsOption("top", "Top"), SettingsOption("bottom", "Bottom"),
                    ]), hint: "Which side of the popup shows the action bar (back and forward buttons)."),
                    SettingsField(
                        "definitionsCollapsible", "Default dictionary collapse behavior", .select([
                            SettingsOption("not-collapsible", "Not collapsible"),
                            SettingsOption("collapsed", "Collapsed"),
                            SettingsOption("expanded", "Expanded"),
                            SettingsOption("force-collapsed", "Force collapsed"),
                            SettingsOption("force-expanded", "Force expanded"),
                        ]),
                        hint: "Applies to dictionaries without a custom rule imported below."
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
                        hint: "Automatically plays audio for the first result."
                    ),
                    SettingsField("audioVolume", "Audio volume", .number(min: 0, max: 100), unit: "%", hint: "Audio playback volume."),
                    SettingsField(
                        "audioFallbackSound", "Audio fallback sound", .select([
                            SettingsOption("none", "None"), SettingsOption("click", "Click"), SettingsOption("bloop", "Bloop"),
                        ]),
                        hint: "Sound played when Yomitan fails to fetch audio."
                    ),
                    SettingsField(
                        "audioSources", "Audio sources", .audioSources,
                        hint: "Checked in order when clicking the speaker icon; right-click to pick a specific recording (also used when creating an Anki card). Leave empty to use Yomitan’s sources or import them via Import → Yomitan Settings."
                    ),
                    SettingsField(
                        "audioDefaultSources", "Enable default audio sources", .checkbox,
                        hint: "Also checks Yomitan’s built-in sources (such as JapanesePod101, LanguagePod101, and Jisho.org) if none above have a recording."
                    ),
                    SettingsField("customPopupCss", "Popup CSS", .textarea, hint: "Custom CSS inside popups (copied by Import → Yomitan Settings)."),
                    SettingsField("customPopupOuterCss", "Popup outer CSS", .textarea, hint: "Custom CSS for the popup frame (such as its border or shadow)."),
                    SettingsField(
                        "dictionaryStyles", "Imported dictionary styles",
                        .imported(
                            describe: { values in values.compactMap { ($0 as? [String: Any])?["name"] as? String }.joined(separator: ", ") },
                            emptyText: "None. Use Import → Yomitan Settings to copy them.",
                            isList: true
                        ),
                        hint: "Per-dictionary styles copied from Yomitan (can only be edited in Yomitan)."
                    ),
                ]
            ),
            SettingsSection(
                title: "Popup Shortcuts", symbol: "keyboard",
                description: "Keyboard shortcuts that stay active whenever a dictionary popup is open, intercepting keys from the foreground app. You can also assign controller combinations with Record Buttons (D-pad and thumbsticks stay reserved for text navigation) using controllers from Settings → Controllers—your game won’t react to controller input while a popup is open.",
                fields: [SettingsField("hotkeys", "", .hotkeys)]
            ),
            SettingsSection(
                title: "Controllers", symbol: "gamecontroller",
                description: "Look up words using a game controller (assign a Controller scan key in Settings → Scanning) and navigate popups (Settings → Popup Shortcuts). During lookups, controller input is hidden from your game. Connect a controller, click Set Up…, and follow the prompts.",
                fields: [SettingsField("gamepadLayouts", "", .gamepads)]
            ),
            SettingsSection(
                title: "Anki", symbol: "rectangle.stack.badge.plus",
                description: "Creates flashcards using the decks, note types, and field mappings from your active Yomitan profile.",
                fields: [
                    SettingsField(
                        "ankiEnabled", "Enable Anki integration", .checkbox,
                        hint: "May send information from Yomitan dictionary entries and related settings to Anki. When off, Anki Screenshot, Anki Audio, and IINA screenshots and audio are also disabled."
                    ),
                    SettingsField(
                        "ankiConnectUrl", "AnkiConnect server address", .text(test: .anki),
                        hint: "AnkiConnect URL (local default: http://127.0.0.1:8765). Click Test while Anki is running to check the connection."
                    ),
                    SettingsField("ankiConnectKey", "API key", .text(), hint: "Secret key required only if an API key is configured in AnkiConnect."),
                    SettingsField("ankiTags", "Card tags", .text(), hint: "Space- or comma-separated tags added to the card."),
                    SettingsField(
                        "ankiRenderTemplatesLocally", "Use local Handlebars templates (enables popup text selection)", .checkbox,
                        hint: "Renders card fields in MacPopup instead of Yomitan so templates can use text highlighted in a popup (via popupSelectionText)."
                    ),
                    SettingsField(
                        "yomitanAnkiTemplates", "Anki field templates (Handlebars)", .ankiTemplates,
                        hint: "Imported from Yomitan’s “Configure Anki card templates” (only used when local templates are enabled above)."
                    ),
                    SettingsField("checkForDuplicates", "Check for card duplicates", .checkbox, hint: "Checks Anki for existing cards matching the word, showing them in the popup and applying the rule below."),
                    SettingsField("duplicateScope", "Duplicate card scope", .select([
                        SettingsOption("collection", "Collection"), SettingsOption("deck", "Deck"), SettingsOption("deck-root", "Deck root"),
                    ]), hint: "Considers a card a duplicate if its first field matches across the whole collection, only the target deck (Deck), or the root deck and its subdecks (Deck root)."),
                    SettingsField(
                        "duplicateScopeCheckAllModels", "Check for duplicates across all models", .checkbox,
                        hint: "Checks for duplicates across all note types instead of only the same note type."
                    ),
                    SettingsField("duplicateBehavior", "When a duplicate is detected", .select([
                        SettingsOption("prevent", "Prevent adding"), SettingsOption("overwrite", "Allow overwriting"), SettingsOption("new", "Allow adding"),
                    ]), hint: "Overwriting updates the first matching duplicate of the same note type and can cause data loss. Customize per-field overwriting in Yomitan’s Configure Anki card format… menu."),
                    SettingsField(
                        "ankiNoteDupeCheckFirst", "Prioritize Anki note duplicate checks before note creation", .checkbox,
                        hint: "Checks for duplicates before rendering notes, showing disabled buttons sooner until notes finish. Helpful with high result limits or many active dictionaries.",
                        showIf: { $0["checkForDuplicates"] as? Bool == true }
                    ),
                    SettingsField("ankiDisplayTagsAndFlags", "Show card tags and flags", .select([
                        SettingsOption("never", "Never"), SettingsOption("always", "Always"),
                        SettingsOption("non-standard", "Non-standard"), SettingsOption("custom", "Custom"),
                    ]), hint: "Shows tag and flag buttons when a word already exists in Anki. Non-standard hides tags in Card tags; Custom shows only tags in Target tags."),
                    SettingsField(
                        "ankiTargetTags", "Target tags", .text(), hint: "Space- or comma-separated list of tags.",
                        showIf: { $0["ankiDisplayTagsAndFlags"] as? String == "custom" }
                    ),
                    SettingsField("ankiSuspendNewCards", "Suspend new cards", .checkbox, hint: "Suspends newly added cards."),
                    SettingsField(
                        "ankiForceSync", "Force Anki sync on adding card", .checkbox,
                        hint: "Syncs Anki after adding a card (may cause issues with AnkiConnect Android or slow or metered connections)."
                    ),
                    SettingsField(
                        "ankiDownloadTimeout", "Idle download timeout", .number(min: 0, max: 60000), unit: "ms",
                        hint: "Maximum idle time before cancelling an audio download from the speaker right-click menu (0 = no limit, up to 1 minute)."
                    ),
                    SettingsField(
                        "noteGuiMode", "Note viewer window", .select([SettingsOption("browse", "Card browser"), SettingsOption("edit", "Note editor")]),
                        hint: "Window opened by “View added note”. Note editor requires an AnkiConnect release from after 2022-05-29."
                    ),
                ]
            ),
            SettingsSection(
                title: "Anki Screenshot", symbol: "photo",
                description: "Captures images for cards’ {screenshot} field from the window chosen in Settings → General (excluding overlays and overlapping windows), or the entire screen if none is selected.",
                fields: [
                    SettingsField(
                        "screenshotFormat", "Screenshot format", .select([SettingsOption("png", "PNG"), SettingsOption("jpeg", "JPEG")]),
                        hint: "Format for card screenshots."
                    ),
                    SettingsField("screenshotQuality", "Screenshot quality", .number(min: 0, max: 100), unit: "%", hint: "For JPEG: lower makes smaller, blurrier files (PNG is always full quality)."),
                    SettingsField(
                        "screenshotResolution", "Screenshot resolution",
                        .select([SettingsOption("1x", "Standard (1x)"), SettingsOption("full", "Full Retina resolution")]),
                        hint: "Standard (1x) keeps files small; Full Retina captures at twice the width and height."
                    ),
                    SettingsField(
                        "screenshotHistory", "Screenshots to keep", .number(min: 0, max: 100), unit: "lines",
                        hint: "Captures window screenshots as each line appears so cards show that scene even if the game advances (0 = captures when adding the card). Stored in memory (a few MB for 20 JPEGs, more for PNG or Retina)."
                    ),
                    SettingsField(
                        "screenshotDelay", "Wait before taking a screenshot", .number(min: 0, max: 5000), unit: "ms",
                        hint: "Brief wait so the game finishes drawing text before capturing (OCR lines capture immediately; captures right away if the next line appears sooner).",
                        showIf: { (($0["screenshotHistory"] as? NSNumber)?.intValue ?? 20) > 0 }
                    ),
                ]
            ),
            SettingsSection(
                title: "Anki Audio", symbol: "waveform",
                description: "Attaches spoken game dialogue to Anki cards using a shortcut after adding a card. MacPopup records the last few minutes of audio from the captured app (or all apps if none is selected); if the line is older, Visual novel backlog capture can replay and record it from the game’s backlog. Requires System Audio Recording permission (plus Accessibility for backlog capture).",
                fields: [
                    SettingsField(
                        "sentenceAudioField", "Sentence audio field", .ankiField,
                        hint: "Anki field for sentence audio (game recordings or IINA clips). Only filled if empty unless overwriting is enabled below."
                    ),
                    SettingsField(
                        "sentenceAudioOverwrite", "Replace sentence audio when overwriting cards", .checkbox,
                        hint: "Replaces existing sentence audio when overwriting a card (from IINA or by Option-clicking the add button)."
                    ),
                    SettingsField("sentenceAudioEnabled", "Enable sentence audio recording", .checkbox, hint: "Attaches spoken game dialogue to Anki cards (requires “Enable Anki integration” in Settings → Anki)."),
                    SettingsField(
                        "sentenceAudioShortcut", "Recording key/buttons", .shortcutAndButtons(buttons: "sentenceAudioButtons"),
                        hint: "Works from any app via keyboard shortcut or controller buttons (Settings → Controllers). Attaches dialogue audio to the last added card (and other cards from that line, except nested popups); Option-click a popup’s add button to add and record in one step. Keyboard shortcuts don’t reach your game, while controller buttons still pass through—choose unused buttons.",
                        warning: { settings in
                            let buttons = Set(settings["sentenceAudioButtons"] as? [String] ?? [])
                            guard !buttons.isEmpty, Set(settings["gamepadScanButtons"] as? [String] ?? []) == buttons else { return nil }
                            return "These controller buttons are already assigned to Controller scan key, which takes priority."
                        }
                    ),
                    SettingsField(
                        "sentenceAudioHistory", "Record game audio for the last", .number(min: 0, max: 30), unit: "min",
                        hint: "Continuously records recent game audio in memory (about 11 MB per minute) for immediate extraction (0 = off)."
                    ),
                    SettingsField(
                        "sentenceAudioVoiceWait", "Cancel if no speech is heard within", .number(min: 1, max: 60), unit: "s",
                        hint: "Cancels without saving if no speech is detected within this time after a line appears or the backlog opens.",
                        showIf: Self.detectsVoice
                    ),
                    SettingsField(
                        "sentenceAudioPause", "Stop recording after silence of", .number(min: 100, max: 10000), unit: "ms",
                        hint: "Silence duration required to stop recording (increase if dialogue pauses cut clips short).",
                        showIf: Self.detectsVoice
                    ),
                    SettingsField(
                        "sentenceAudioPadding", "Padding around detected speech", .number(min: 0, max: 2000), unit: "ms",
                        hint: "Extra audio kept before and after speech so words aren’t clipped.",
                        showIf: Self.detectsVoice
                    ),
                    SettingsField("sentenceAudioMaxLength", "Maximum recording length", .number(min: 1, max: 120), unit: "s", hint: "Maximum duration before recording stops, even if speech continues."),
                    SettingsField("sentenceAudioPlay", "Preview recording after saving to Anki", .checkbox, hint: "Plays the saved recording right after adding it to your card."),
                    SettingsField(
                        "sentenceAudioBacklog", "Visual novel backlog capture", .checkbox,
                        hint: "When a line’s voice isn’t in recorded audio (older, cut off, or recording is off), focuses the game, opens the backlog, records the line when you replay it, and closes the backlog. Press the shortcut again to stop early."
                    ),
                    SettingsField("sentenceAudioApp", "App to focus before recording", .select([
                        SettingsOption("captured", "Captured window"),
                        SettingsOption("named", "Specific app by name"),
                        SettingsOption("none", "Don’t switch apps"),
                    ]), hint: "App brought to the front before sending backlog keystrokes.", showIf: Self.capturesBacklog),
                    SettingsField(
                        "sentenceAudioAppName", "Application name", .text(), hint: "The app’s exact name as shown in the Dock (e.g. Parallels Desktop).",
                        showIf: { Self.capturesBacklog($0) && $0["sentenceAudioApp"] as? String == "named" }
                    ),
                    SettingsField(
                        "sentenceAudioOpenKeys", "Keys to open backlog and replay voice", .keySequence(max: 5),
                        hint: "Keystrokes sent in order before recording starts (e.g. to open the text log and replay voice).",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField(
                        "sentenceAudioCloseKeys", "Keys to close backlog", .keySequence(max: 5),
                        hint: "Keystrokes sent in order after recording stops to return to the game.",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField(
                        "sentenceAudioKeyDelay", "Delay after switching apps", .number(min: 0, max: 5000), unit: "ms",
                        hint: "Wait after focusing the game window before sending keystrokes.",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField("sentenceAudioKeyInterval", "Delay between keystrokes", .number(min: 0, max: 5000), unit: "ms", hint: "Wait between backlog keystrokes so the game can react to each one.", showIf: Self.capturesBacklog),
                    SettingsField("sentenceAudioKeyHold", "Key press duration", .number(min: 0, max: 1000), unit: "ms", hint: "How long each key is held (raise if the game misses key presses).", showIf: Self.capturesBacklog),
                    SettingsField(
                        "sentenceAudioDetectVoice", "Automatically detect start and end of speech", .checkbox,
                        hint: "Uses speech detection to skip music and sound effects and stop when speech ends (when off, press the shortcut again to stop).",
                        showIf: Self.capturesBacklog
                    ),
                    SettingsField(
                        "sentenceAudioRecordDelay", "Delay before recording starts", .number(min: 0, max: 5000), unit: "ms",
                        hint: "Wait after replay keys before recording starts (useful for skipping menu sounds).",
                        showIf: { Self.capturesBacklog($0) && !($0["sentenceAudioDetectVoice"] as? Bool ?? true) }
                    ),
                ]
            ),
            SettingsSection(
                title: "IINA Integration", symbol: "film",
                description: "Create flashcards directly from IINA subtitles, including subtitle-free screenshots and audio clips in your Sentence audio field (Settings → Anki Audio). Works with network streams (including yt-dlp) and live streams (~1-minute playback cache).",
                fields: [
                    SettingsField(
                        "iinaPlugin", "IINA plugin", .iinaPlugin,
                        hint: "Opens the plugin in IINA to install it. Then enable it in IINA’s Settings → Plugins, restart IINA, and add ws://localhost:6680 in Settings → WebSockets."
                    ),
                    SettingsField(
                        "iinaScreenshotEnabled", "Use clean screenshots for cards", .checkbox,
                        hint: "Captures the native-resolution video frame at the subtitle’s midpoint without subtitles (when off, follows Settings → Anki Screenshot)."
                    ),
                    SettingsField(
                        "iinaSentenceAudioEnabled", "Use clean audio for cards", .checkbox,
                        hint: "Extracts the subtitle line’s audio clip into your Sentence audio field."
                    ),
                    SettingsField(
                        "iinaSentenceAudioPadding", "Padding around the line", .number(min: 0, max: 2000), unit: "ms",
                        hint: "Extra audio kept before and after each subtitle so slightly early or late speech isn’t clipped.",
                        showIf: { $0["iinaSentenceAudioEnabled"] as? Bool ?? true }
                    ),
                    SettingsField(
                        "iinaTranscribe", "Transcribe videos without subtitles", .checkbox,
                        hint: "Transcribes videos without target-language subtitles using Settings → Transcription and adds a subtitle track in IINA (not supported for live streams; pauses “Read text from audio” while active)."
                    ),
                    SettingsField(
                        "iinaTranscripts", "Saved transcriptions", .iinaTranscripts,
                        hint: "If cleared, videos will need to be transcribed again."
                    ),
                ]
            ),
            SettingsSection(
                title: "Permissions", symbol: "lock.shield",
                description: "Permissions required by MacPopup features. Grant them here or on first use; previously denied permissions must be re-enabled in macOS System Settings.",
                fields: [
                    SettingsField(
                        "permission.screenRecording", "Screen Recording", .permission(.screenRecording),
                        hint: "Required for OCR and Anki {screenshot} captures (you may need to reopen MacPopup after granting)."
                    ),
                    SettingsField(
                        "permission.audioCapture", "System Audio Recording", .permission(.audioCapture),
                        hint: "Required for Anki Audio and “Read text from audio” (listed as Screen & System Audio Recording in System Settings)."
                    ),
                    SettingsField(
                        "permission.accessibility", "Accessibility", .permission(.accessibility),
                        hint: "Required by Visual novel backlog capture to focus the game and send replay keystrokes."
                    ),
                    SettingsField(
                        "permission.pauseHelper", "Pause helper", .permission(.pauseHelper),
                        hint: "Required to pause the game while a popup is open (Settings → Scanning). Enabled in System Settings → General → Login Items; runs with root privileges to pause Parallels."
                    ),
                ]
            ),
        ]
    }()
}
