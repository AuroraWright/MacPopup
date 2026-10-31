import AppKit

/// Lets the user click the window to read in screen OCR mode, then optionally drag rectangles over
/// the parts with text. Covers every display with a transparent window above everything else.
@MainActor
final class WindowPicker {
    struct Result {
        var windowID: CGWindowID
        var ownerName: String
        var ownerPID: pid_t
        var title: String
        /// Normalized to the window (0–1, origin top left). Empty means the whole window.
        var regions: [CGRect]
    }

    private static var current: WindowPicker?

    static func cancel() {
        current?.finish(nil)
    }

    /// Calls `completion` with the choice, or nil when cancelled.
    static func pick(above level: NSWindow.Level, completion: @escaping (Result?) -> Void) {
        guard current == nil else { return }
        let picker = WindowPicker(level: NSWindow.Level(rawValue: level.rawValue + 2), completion: completion)
        current = picker
        picker.begin()
    }

    enum Phase {
        case window
        case regions(OCRController.WindowInfo)
    }

    private(set) var phase: Phase = .window
    private(set) var hovered: OCRController.WindowInfo?
    /// Regions in global coordinates (origin at the top left of the main display).
    private(set) var regions: [CGRect] = []
    private(set) var dragRect: CGRect?
    private var dragStart: CGPoint?

    private let level: NSWindow.Level
    private let completion: (Result?) -> Void
    private var windows: [PickerWindow] = []
    private var keyMonitor: Any?
    /// Development aid: MACPOPUP_DEBUG_PICKER_DIR=<dir> saves what the picker draws (only its own
    /// drawing, not the screen) after each change.
    private let debugDirectory = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_PICKER_DIR"]
    private var debugCount = 0

    private init(level: NSWindow.Level, completion: @escaping (Result?) -> Void) {
        self.level = level
        self.completion = completion
    }

    private func begin() {
        for screen in NSScreen.screens {
            let window = PickerWindow(screen: screen, picker: self)
            window.level = level
            windows.append(window)
            window.orderFrontRegardless()
        }
        // The panels take the keyboard without activating MacPopup, so the app in front stays in front.
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.keyDown(event) ? nil : event
        }
        mouseMoved(to: Self.globalPoint(NSEvent.mouseLocation))
    }

    private func finish(_ result: Result?) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        Self.current = nil
        completion(result)
    }

    static func globalPoint(_ point: NSPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }

    private func redraw() {
        windows.forEach { $0.contentView?.needsDisplay = true }
        if let debugDirectory, let view = windows.first?.contentView {
            DispatchQueue.main.async {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                self.debugCount += 1
                let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent("picker-\(self.debugCount).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    // MARK: Buttons

    enum Button: CaseIterable {
        case cancel, undo, done

        var title: String {
            switch self {
            case .cancel: "Cancel  esc"
            case .undo: "Undo  ⌫"
            case .done: "Done  ↩"
            }
        }
    }

    /// The buttons shown in the current phase.
    var buttons: [Button] {
        switch phase {
        case .window: [.cancel]
        case .regions: [.cancel, .undo, .done]
        }
    }

    func press(_ button: Button) {
        switch button {
        case .cancel: finish(nil)
        case .undo: undo()
        case .done: done()
        }
    }

    private func done() {
        guard case let .regions(window) = phase else { return }
        let bounds = window.bounds
        let normalized = regions.map {
            CGRect(
                x: ($0.minX - bounds.minX) / bounds.width, y: ($0.minY - bounds.minY) / bounds.height,
                width: $0.width / bounds.width, height: $0.height / bounds.height
            )
        }
        finish(Result(windowID: window.id, ownerName: window.ownerName, ownerPID: window.ownerPID,
                      title: window.title, regions: normalized))
    }

    /// Removes the last area, or goes back to choosing the window.
    private func undo() {
        if !regions.isEmpty {
            regions.removeLast()
        } else if case .regions = phase {
            phase = .window
            hovered = nil
            mouseMoved(to: Self.globalPoint(NSEvent.mouseLocation))
        }
        redraw()
    }

    // MARK: Events

    func mouseMoved(to point: CGPoint) {
        guard case .window = phase else { return }
        let window = OCRController.onScreenWindows().first { $0.bounds.contains(point) }
        if window?.id != hovered?.id {
            hovered = window
            redraw()
        }
    }

    func mouseDown(at point: CGPoint) {
        switch phase {
        case .window:
            mouseMoved(to: point)
            if let hovered {
                phase = .regions(hovered)
                redraw()
            }
        case let .regions(window):
            guard window.bounds.contains(point) else { return }
            dragStart = point
            dragRect = nil
        }
    }

    func mouseDragged(to point: CGPoint) {
        guard case let .regions(window) = phase, let dragStart else { return }
        let rect = CGRect(
            x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y)
        )
        dragRect = rect.intersection(window.bounds)
        redraw()
    }

    func mouseUp() {
        if let dragRect, dragRect.width >= 8, dragRect.height >= 8 {
            regions.append(dragRect)
        }
        dragStart = nil
        dragRect = nil
        redraw()
    }

    /// Returns whether the key was handled.
    private func keyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            finish(nil)
        case 36, 76: // Return, Enter
            done()
        case 51, 117: // Delete, Forward Delete
            undo()
        default:
            return false
        }
        return true
    }
}

private final class PickerWindow: NSPanel {
    init(screen: NSScreen, picker: WindowPicker) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Set explicitly, or clicks on the transparent parts (the chosen window) go to the window below.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size), picker: picker)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    private weak var picker: WindowPicker?
    private var buttonRects: [(button: WindowPicker.Button, rect: CGRect)] = []

    init(frame: CGRect, picker: WindowPicker) {
        self.picker = picker
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_PICKER_DIR"] != nil else { return }
        FileHandle.standardError.write("[picker] \(message)\n".data(using: .utf8)!)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    /// The view's origin in global coordinates (origin at the top left of the main display).
    private var globalOrigin: CGPoint {
        guard let screen = window?.screen ?? NSScreen.main else { return .zero }
        return OCRController.globalFrame(of: screen).origin
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return WindowPicker.globalPoint(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        picker?.mouseMoved(to: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        debugLog("mouseDown \(globalPoint(event))")
        let local = convert(event.locationInWindow, from: nil)
        if let button = buttonRects.first(where: { $0.rect.contains(local) })?.button {
            picker?.press(button)
            return
        }
        picker?.mouseDown(at: globalPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        debugLog("mouseDragged \(globalPoint(event))")
        picker?.mouseDragged(to: globalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        debugLog("mouseUp \(globalPoint(event))")
        picker?.mouseUp()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let picker else { return }
        let accent = NSColor.controlAccentColor
        let instructions: String

        switch picker.phase {
        case .window:
            NSColor.black.withAlphaComponent(0.15).setFill()
            bounds.fill()
            if let hovered = picker.hovered {
                let rect = local(hovered.bounds)
                NSColor.clear.setFill()
                rect.fill(using: .copy)
                accent.withAlphaComponent(0.2).setFill()
                rect.fill()
                accent.setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
                border.lineWidth = 3
                border.stroke()
                let name = hovered.title.isEmpty ? hovered.ownerName : "\(hovered.ownerName) — \(hovered.title)"
                drawLabel(name, centeredAt: CGPoint(x: rect.midX, y: rect.midY))
            }
            instructions = "Click the window to read with OCR"
        case let .regions(window):
            // Dim everything except the window, and the marked areas inside it even more clearly.
            NSColor.black.withAlphaComponent(0.45).setFill()
            bounds.fill()
            let windowRect = local(window.bounds)
            NSColor.black.withAlphaComponent(picker.regions.isEmpty && picker.dragRect == nil ? 0 : 0.3).setFill()
            windowRect.fill(using: .copy)
            let areas = picker.regions + [picker.dragRect].compactMap({ $0 })
            for rect in areas {
                let localRect = local(rect)
                NSColor.clear.setFill()
                localRect.fill(using: .copy)
                accent.setStroke()
                let border = NSBezierPath(rect: localRect.insetBy(dx: 1, dy: 1))
                border.lineWidth = 2
                border.stroke()
            }
            // The first area is the dialogue, matched with WebSocket lines; the others are read at once.
            for (index, rect) in areas.enumerated() {
                drawTag(index == 0 ? "Dialogue" : "Other text", at: local(rect).origin)
            }
            accent.setStroke()
            let border = NSBezierPath(rect: windowRect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            border.stroke()
            instructions = picker.regions.isEmpty
                ? "Drag over the dialogue to read only the parts with text (optional), or click Done to read the whole window"
                : "Drag over other parts with text (read as soon as they change, without the WebSocket line), or click Done"
        }

        let menuBar = window?.screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        drawLabel(instructions, centeredAt: CGPoint(x: bounds.midX, y: max(menuBar, 0) + 40))
        drawButtons(picker.buttons, top: max(menuBar, 0) + 72)
    }

    private func drawButtons(_ buttons: [WindowPicker.Button], top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let titles = buttons.map { NSAttributedString(string: $0.title, attributes: attributes) }
        let sizes = titles.map { CGSize(width: $0.size().width + 32, height: $0.size().height + 14) }
        let spacing: CGFloat = 12
        var x = bounds.midX - (sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))) / 2
        buttonRects = []
        for (index, button) in buttons.enumerated() {
            let rect = CGRect(x: x, y: top, width: sizes[index].width, height: sizes[index].height)
            (button == .done ? NSColor.controlAccentColor : NSColor.darkGray).withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            titles[index].draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 7))
            buttonRects.append((button, rect))
            if ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_PICKER_DIR"] != nil {
                let global = rect.offsetBy(dx: globalOrigin.x, dy: globalOrigin.y)
                FileHandle.standardError.write("[picker] button \(button) at \(global.midX),\(global.midY)\n".data(using: .utf8)!)
            }
            x += rect.width + spacing
        }
    }

    /// A small label at the top left corner of an area, outside it when there's room.
    private func drawTag(_ text: String, at corner: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let height = size.height + 4
        let box = CGRect(x: corner.x, y: corner.y >= height ? corner.y - height : corner.y, width: size.width + 10, height: height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2))
    }

    private func drawLabel(_ text: String, centeredAt center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: center.x - size.width / 2 - 14, y: center.y - size.height / 2 - 8,
                         width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        string.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 8))
    }
}
