import AppKit
import Carbon

/// A keyboard shortcut as Yomitan stores it: a KeyboardEvent.code ("KeyE", "ArrowUp") and modifier
/// names ("alt", "ctrl", "shift", "meta").
struct KeyCombination: Equatable {
    let key: String
    let modifiers: [String]

    static let modifierNames = ["ctrl", "alt", "shift", "meta"]

    /// KeyboardEvent.code → macOS virtual key code.
    static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "KeyA": kVK_ANSI_A, "KeyB": kVK_ANSI_B, "KeyC": kVK_ANSI_C, "KeyD": kVK_ANSI_D, "KeyE": kVK_ANSI_E,
            "KeyF": kVK_ANSI_F, "KeyG": kVK_ANSI_G, "KeyH": kVK_ANSI_H, "KeyI": kVK_ANSI_I, "KeyJ": kVK_ANSI_J,
            "KeyK": kVK_ANSI_K, "KeyL": kVK_ANSI_L, "KeyM": kVK_ANSI_M, "KeyN": kVK_ANSI_N, "KeyO": kVK_ANSI_O,
            "KeyP": kVK_ANSI_P, "KeyQ": kVK_ANSI_Q, "KeyR": kVK_ANSI_R, "KeyS": kVK_ANSI_S, "KeyT": kVK_ANSI_T,
            "KeyU": kVK_ANSI_U, "KeyV": kVK_ANSI_V, "KeyW": kVK_ANSI_W, "KeyX": kVK_ANSI_X, "KeyY": kVK_ANSI_Y,
            "KeyZ": kVK_ANSI_Z,
            "Digit0": kVK_ANSI_0, "Digit1": kVK_ANSI_1, "Digit2": kVK_ANSI_2, "Digit3": kVK_ANSI_3, "Digit4": kVK_ANSI_4,
            "Digit5": kVK_ANSI_5, "Digit6": kVK_ANSI_6, "Digit7": kVK_ANSI_7, "Digit8": kVK_ANSI_8, "Digit9": kVK_ANSI_9,
            "Minus": kVK_ANSI_Minus, "Equal": kVK_ANSI_Equal, "BracketLeft": kVK_ANSI_LeftBracket,
            "BracketRight": kVK_ANSI_RightBracket, "Backslash": kVK_ANSI_Backslash, "Semicolon": kVK_ANSI_Semicolon,
            "Quote": kVK_ANSI_Quote, "Backquote": kVK_ANSI_Grave, "Comma": kVK_ANSI_Comma, "Period": kVK_ANSI_Period,
            "Slash": kVK_ANSI_Slash, "IntlYen": kVK_JIS_Yen, "IntlRo": kVK_JIS_Underscore, "IntlBackslash": kVK_ISO_Section,
            "Escape": kVK_Escape, "Enter": kVK_Return, "Tab": kVK_Tab, "Space": kVK_Space, "Backspace": kVK_Delete,
            "Delete": kVK_ForwardDelete, "Insert": kVK_Help, "Home": kVK_Home, "End": kVK_End, "PageUp": kVK_PageUp,
            "PageDown": kVK_PageDown, "ArrowUp": kVK_UpArrow, "ArrowDown": kVK_DownArrow, "ArrowLeft": kVK_LeftArrow,
            "ArrowRight": kVK_RightArrow,
            "Numpad0": kVK_ANSI_Keypad0, "Numpad1": kVK_ANSI_Keypad1, "Numpad2": kVK_ANSI_Keypad2,
            "Numpad3": kVK_ANSI_Keypad3, "Numpad4": kVK_ANSI_Keypad4, "Numpad5": kVK_ANSI_Keypad5,
            "Numpad6": kVK_ANSI_Keypad6, "Numpad7": kVK_ANSI_Keypad7, "Numpad8": kVK_ANSI_Keypad8,
            "Numpad9": kVK_ANSI_Keypad9, "NumpadAdd": kVK_ANSI_KeypadPlus, "NumpadSubtract": kVK_ANSI_KeypadMinus,
            "NumpadMultiply": kVK_ANSI_KeypadMultiply, "NumpadDivide": kVK_ANSI_KeypadDivide,
            "NumpadDecimal": kVK_ANSI_KeypadDecimal, "NumpadEnter": kVK_ANSI_KeypadEnter, "NumpadEqual": kVK_ANSI_KeypadEquals,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { codes["F\(index + 1)"] = code }
        return codes
    }()

    private static let keyNames: [Int: String] = Dictionary(keyCodes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

    private static let symbols: [String: String] = [
        "Escape": "Esc", "Enter": "↩", "Tab": "⇥", "Space": "Space", "Backspace": "⌫", "Delete": "⌦", "Insert": "Help",
        "Home": "↖", "End": "↘", "PageUp": "Page Up", "PageDown": "Page Down", "ArrowUp": "↑", "ArrowDown": "↓",
        "ArrowLeft": "←", "ArrowRight": "→", "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]",
        "Backslash": "\\", "Semicolon": ";", "Quote": "'", "Backquote": "`", "Comma": ",", "Period": ".", "Slash": "/",
        "IntlYen": "¥", "IntlRo": "_", "IntlBackslash": "§", "NumpadAdd": "Keypad +", "NumpadSubtract": "Keypad -",
        "NumpadMultiply": "Keypad *", "NumpadDivide": "Keypad /", "NumpadDecimal": "Keypad .", "NumpadEnter": "Keypad ↩",
        "NumpadEqual": "Keypad =",
    ]

    init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = Self.modifierNames.filter(modifiers.contains)
    }

    /// The shortcut a key press makes, if the key is one Yomitan shortcuts can use.
    init?(event: NSEvent) {
        guard let key = Self.keyNames[Int(event.keyCode)] else { return nil }
        let flags: [(NSEvent.ModifierFlags, String)] = [(.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "meta")]
        self.init(key: key, modifiers: flags.filter { event.modifierFlags.contains($0.0) }.map(\.1))
    }

    var keyCode: Int? { Self.keyCodes[key] }

    var carbonModifiers: UInt32 {
        let flags: [String: Int] = ["ctrl": controlKey, "alt": optionKey, "shift": shiftKey, "meta": cmdKey]
        return modifiers.reduce(0) { $0 | UInt32(flags[$1] ?? 0) }
    }

    /// As macOS menus show shortcuts, e.g. "⌥E".
    var displayName: String {
        let symbols: [String: String] = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "meta": "⌘"]
        let name: String
        if let symbol = Self.symbols[key] {
            name = symbol
        } else if key.hasPrefix("Key") || key.hasPrefix("Digit") {
            name = String(key.last!)
        } else if key.hasPrefix("Numpad") {
            name = "Keypad \(key.dropFirst(6))"
        } else {
            name = key
        }
        return modifiers.compactMap { symbols[$0] }.joined() + name
    }
}

/// Global hotkeys: popup keyboard shortcuts, registered only while a popup shows (see
/// web/src/overlay.js), and the sentence audio shortcut (SentenceAudio.swift). The overlay never has keyboard focus, so the app being read keeps it; a
/// registered hotkey's key goes to MacPopup instead, and back to that app once it's unregistered.
/// Global hotkeys need no permission.
@MainActor
final class HotkeyController {
    /// Called with the index of the pressed hotkey in the list last set.
    var onPress: ((Int) -> Void)?

    private var registered: [EventHotKeyRef?] = []
    private var current: [KeyCombination] = []
    private var handler: EventHandlerRef?

    /// Tells this controller's hotkeys from other controllers' (each installs its own handler).
    private let signature: OSType

    init(signature: OSType = 0x4D50_484B) { // "MPHK"
        self.signature = signature
    }

    /// Registers these shortcuts in place of the previous ones. Returns whether each one could be
    /// (another app may already use it).
    @discardableResult
    func set(_ combinations: [KeyCombination]) -> [Bool] {
        if combinations == current { return registered.map { $0 != nil } }
        installHandler()
        unregisterAll()
        current = combinations
        registered = combinations.enumerated().map { index, combination in
            guard let keyCode = combination.keyCode else { return nil }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(index))
            let status = RegisterEventHotKey(UInt32(keyCode), combination.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            return status == noErr ? ref : nil
        }
        return registered.map { $0 != nil }
    }

    private func unregisterAll() {
        for ref in registered.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
        registered = []
        current = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotkeyController>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == controller.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { controller.onPress?(Int(id.id)) }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
