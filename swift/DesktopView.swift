//
//  DesktopView.swift
//
//  Shows the remote desktop and turns Mac input into RDP input.
//
//  Keyboard, in the default "type what the Mac types" mode:
//  - Typed text is sent as the characters the Mac produced (Unicode input),
//    including dead keys and Option characters, so an AZERTY Mac types exactly
//    what it shows whatever layout Windows thinks it has.
//  - Shortcuts and non-text keys go as key positions. Left Cmd acts as Ctrl,
//    so Cmd-C, Cmd-V, Cmd-Z do what a Mac user expects. Right Cmd is the
//    Windows key. Option is only sent as Alt together with a non-text key, so
//    typing an Option character never fires a Windows Alt menu.
//
//  Scrolling uses AppKit's deltas, which already follow the Mac's natural
//  scrolling setting, so it scrolls the same way as everywhere else on the
//  Mac. Sign conventions checked against MS-RDPBCGR and WM_MOUSEWHEEL docs.
//

import AppKit
import IOSurface

final class DesktopView: NSView, NSTextInputClient {
    weak var connection: InputSink?
    var keyboardMode: KeyboardMode = .characters

    private(set) var remoteSize: CGSize = .zero

    // Pointer flags, MS-RDPBCGR 2.2.8.1.1.3.1.1.3.
    private let PTR_MOVE: UInt16 = 0x0800, PTR_DOWN: UInt16 = 0x8000
    private let PTR_B1: UInt16 = 0x1000, PTR_B2: UInt16 = 0x2000, PTR_B3: UInt16 = 0x4000

    // Device-specific modifier bits, IOKit IOLLEvent.h.
    private enum Device {
        static let lCtl: UInt = 0x1, lShift: UInt = 0x2, rShift: UInt = 0x4, lCmd: UInt = 0x8
        static let rCmd: UInt = 0x10, lAlt: UInt = 0x20, rAlt: UInt = 0x40, rCtl: UInt = 0x2000
    }

    /// Mac key codes that never produce text: always sent as key positions.
    private static let nonTextKeys: Set<UInt16> = [
        0x24, 0x4C, 0x30, 0x35, 0x33, 0x75, 0x31,          // return, enter, tab, esc, delete, fwd delete, space
        0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x77, 0x74, 0x79, 0x72, // arrows, home, end, page up/down, help/insert
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, // F1-F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,     // F13-F20
    ]

    private var macModifiers: Set<UInt16> = []          // modifier key codes held on the Mac
    private var remoteModifiers: [UInt16: Int] = [:]    // scancode -> hold count at the server
    private var deferredAlt: UInt16?                    // Alt sent on behalf of Option
    private var downKeys: [UInt16: UInt16] = [:]        // Mac key code -> scancode held at the server
    private var currentEvent: NSEvent?
    private var marked = NSMutableAttributedString()
    private var scrollX: CGFloat = 0, scrollY: CGFloat = 0

    private var remoteCursor: NSCursor = .arrow
    private static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        // No implicit fade when the contents change.
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    // MARK: Display

    func display(surface: IOSurface, size: CGSize) {
        let sizeChanged = size != remoteSize
        remoteSize = size
        layer?.contents = surface
        if sizeChanged { window?.invalidateCursorRects(for: self) }
    }

    /// The part of the view the desktop actually occupies (aspect fit).
    private var imageRect: CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let w = remoteSize.width * scale, h = remoteSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func remotePoint(_ event: NSEvent) -> CGPoint {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, remoteSize.width > 0 else { return .zero }
        let p = convert(event.locationInWindow, from: nil)
        let x = (p.x - rect.minX) / rect.width * remoteSize.width
        // AppKit's y runs upwards, the desktop's downwards.
        let y = (rect.maxY - p.y) / rect.height * remoteSize.height
        return CGPoint(x: min(max(0, x), remoteSize.width - 1), y: min(max(0, y), remoteSize.height - 1))
    }

    // MARK: Cursor

    func setRemoteCursor(_ cursor: RemoteCursor) {
        switch cursor {
        case .system:
            remoteCursor = .arrow
        case .hidden:
            remoteCursor = Self.hiddenCursor
        case .image(let image, let hotSpot, let pixelSize):
            // Remote pixels per point on screen, so the cursor is the size the
            // desktop draws it.
            let ratio = remoteSize.width > 0 ? imageRect.width / remoteSize.width : 1
            let size = NSSize(width: max(1, pixelSize.width * ratio), height: max(1, pixelSize.height * ratio))
            let scaled = NSImage(size: size)
            scaled.addRepresentations(image.representations)
            remoteCursor = NSCursor(image: scaled,
                                    hotSpot: NSPoint(x: hotSpot.x * ratio, y: hotSpot.y * ratio))
        }
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow,
           bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            remoteCursor.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: remoteCursor)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { remoteCursor.set() }

    private func move(_ e: NSEvent) { connection?.sendMouse(flags: PTR_MOVE, at: remotePoint(e)) }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        connection?.sendMouse(flags: PTR_DOWN | PTR_B1, at: remotePoint(e))
    }
    override func mouseUp(with e: NSEvent) { connection?.sendMouse(flags: PTR_B1, at: remotePoint(e)) }
    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        connection?.sendMouse(flags: PTR_DOWN | PTR_B2, at: remotePoint(e))
    }
    override func rightMouseUp(with e: NSEvent) { connection?.sendMouse(flags: PTR_B2, at: remotePoint(e)) }

    override func otherMouseDown(with e: NSEvent) { otherButton(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { otherButton(e, down: false) }

    private func otherButton(_ e: NSEvent, down: Bool) {
        let p = remotePoint(e)
        switch e.buttonNumber {
        case 2: connection?.sendMouse(flags: (down ? PTR_DOWN : 0) | PTR_B3, at: p)
        case 3: connection?.sendXButton(1, down: down, at: p)
        case 4: connection?.sendXButton(2, down: down, at: p)
        default: break
        }
    }

    override func scrollWheel(with e: NSEvent) {
        guard let connection else { return }
        if e.phase == .began { scrollX = 0; scrollY = 0 }
        // A trackpad reports points, a wheel reports lines. One Windows line
        // is 40 units (WHEEL_DELTA 120 = 3 lines), one point is about 2.
        let factor: CGFloat = e.hasPreciseScrollingDeltas ? 2 : 40
        // AppKit: positive deltaY scrolls toward the top, as Windows' positive
        // wheel does. Positive deltaX scrolls toward the left, where Windows'
        // positive horizontal wheel goes right, so that one flips.
        scrollY += e.scrollingDeltaY * factor
        scrollX -= e.scrollingDeltaX * factor
        let y = Int(scrollY), x = Int(scrollX)
        scrollY -= CGFloat(y)
        scrollX -= CGFloat(x)
        if y != 0 { connection.sendWheel(horizontal: false, units: y) }
        if x != 0 { connection.sendWheel(horizontal: true, units: x) }
    }

    // MARK: Modifiers

    private func hold(_ scancode: UInt16) {
        let count = remoteModifiers[scancode, default: 0]
        if count == 0 { connection?.sendKey(scancode: scancode, down: true) }
        remoteModifiers[scancode] = count + 1
    }

    private func letGo(_ scancode: UInt16) {
        guard let count = remoteModifiers[scancode] else { return }
        if count <= 1 {
            remoteModifiers[scancode] = nil
            connection?.sendKey(scancode: scancode, down: false)
        } else {
            remoteModifiers[scancode] = count - 1
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let raw = event.modifierFlags.rawValue
        let code = event.keyCode

        func track(_ mask: UInt, remote: UInt16?) {
            let down = raw & mask != 0
            let wasDown = macModifiers.contains(code)
            guard down != wasDown else { return }
            if down { macModifiers.insert(code) } else { macModifiers.remove(code) }
            if let remote { down ? hold(remote) : letGo(remote) }
        }

        let raw_mode = keyboardMode == .scancodes
        switch code {
        case 0x38: track(Device.lShift, remote: 0x2A)
        case 0x3C: track(Device.rShift, remote: 0x36)
        case 0x3B: track(Device.lCtl, remote: 0x1D)
        case 0x3E: track(Device.rCtl, remote: 0x11D)
        case 0x37: track(Device.lCmd, remote: 0x1D)    // left Cmd works as Ctrl
        case 0x36: track(Device.rCmd, remote: 0x15B)   // right Cmd is the Windows key
        case 0x3A: track(Device.lAlt, remote: raw_mode ? 0x38 : nil)
        case 0x3D: track(Device.rAlt, remote: raw_mode ? 0x138 : nil)
        case 0x39:
            if raw_mode {
                connection?.sendKey(scancode: 0x3A, down: true)
                connection?.sendKey(scancode: 0x3A, down: false)
            }
        default: break
        }

        // Option released: let go of the Alt sent on its behalf. A key went
        // between press and release, so Windows does not open a menu.
        if !optionHeld, let alt = deferredAlt {
            deferredAlt = nil
            connection?.sendKey(scancode: alt, down: false)
        }
    }

    private var optionHeld: Bool { macModifiers.contains(0x3A) || macModifiers.contains(0x3D) }
    private var shortcutHeld: Bool {
        !macModifiers.isDisjoint(with: [0x37, 0x36, 0x3B, 0x3E])
    }

    private func sendDeferredAltIfNeeded() {
        guard keyboardMode == .characters, optionHeld, deferredAlt == nil else { return }
        let alt: UInt16 = macModifiers.contains(0x3D) && !macModifiers.contains(0x3A) ? 0x138 : 0x38
        deferredAlt = alt
        connection?.sendKey(scancode: alt, down: true)
    }

    /// Lets go of everything held at the server. Called when the window stops
    /// being key, so Cmd-Tab away never leaves Ctrl stuck down in Windows.
    func releaseAll() {
        for (_, sc) in downKeys { connection?.sendKey(scancode: sc, down: false) }
        downKeys.removeAll()
        for (sc, _) in remoteModifiers { connection?.sendKey(scancode: sc, down: false) }
        remoteModifiers.removeAll()
        if let alt = deferredAlt { connection?.sendKey(scancode: alt, down: false) }
        deferredAlt = nil
        macModifiers.removeAll()
        marked = NSMutableAttributedString()
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, connection?.isActive == true
        else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Kept for macOS: quit, hide, minimise, cycle windows, fullscreen.
        if ["q", "h", "m", "`"].contains(key) || (key == "f" && flags.contains(.control)) {
            return super.performKeyEquivalent(with: event)
        }
        shortcut(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard connection != nil else { return }
        if event.modifierFlags.contains(.command) {
            shortcut(event)
        } else if keyboardMode == .scancodes || shortcutHeld || Self.nonTextKeys.contains(event.keyCode) {
            keyPosition(event)
        } else {
            currentEvent = event
            interpretKeyEvents([event])
            currentEvent = nil
        }
    }

    override func keyUp(with event: NSEvent) {
        if let sc = downKeys.removeValue(forKey: event.keyCode) {
            connection?.sendKey(scancode: sc, down: false)
        }
    }

    /// Sends a key by position and remembers it is down at the server.
    private func keyPosition(_ event: NSEvent) {
        guard let connection else { return }
        let sc = connection.scancode(forMacKey: event.keyCode)
        guard sc != 0 else { return }
        sendDeferredAltIfNeeded()
        connection.sendKey(scancode: sc, down: true, repeat: event.isARepeat)
        downKeys[event.keyCode] = sc
    }

    /// A Cmd combination, sent as press and release at once: macOS does not
    /// deliver key-up events while Cmd is held, so waiting for one would leave
    /// the key stuck down in Windows.
    private func shortcut(_ event: NSEvent) {
        guard let connection else { return }
        let sc = connection.scancode(forMacKey: event.keyCode)
        guard sc != 0 else { return }
        sendDeferredAltIfNeeded()
        let send = { [weak connection] in
            connection?.sendKey(scancode: sc, down: true, repeat: event.isARepeat)
            connection?.sendKey(scancode: sc, down: false)
        }
        // Pasting: make sure Windows has the latest Mac clipboard first. If it
        // just changed, give the announcement a moment to arrive ahead of the key.
        if event.charactersIgnoringModifiers?.lowercased() == "v", PasteboardWatcher.shared.check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: send)
        } else {
            send()
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString()
        guard !text.isEmpty, let connection else { return }
        if !connection.sendText(text), let event = currentEvent {
            // The server does not take Unicode input: fall back to the key.
            keyPosition(event)
        }
    }

    override func doCommand(by selector: Selector) {
        if let event = currentEvent { keyPosition(event) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            marked = NSMutableAttributedString(attributedString: attributed)
        } else {
            marked = NSMutableAttributedString(string: string as? String ?? "")
        }
    }

    func unmarkText() { marked = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
