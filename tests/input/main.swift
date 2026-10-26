import AppKit
import IOSurface

final class Recorder: InputSink {
    var log: [String] = []
    var unicodeWorks = true
    var isActive: Bool { true }
    func sendMouse(flags: UInt16, at p: CGPoint) { log.append(String(format: "mouse %04X %d,%d", flags, Int(p.x), Int(p.y))) }
    func sendXButton(_ b: Int, down: Bool, at p: CGPoint) { log.append("xbutton \(b) \(down ? "down" : "up")") }
    func sendWheel(horizontal: Bool, units: Int) { log.append("\(horizontal ? "hwheel" : "wheel") \(units)") }
    func sendKey(scancode: UInt16, down: Bool, repeat r: Bool) { log.append(String(format: "key %03X %@", scancode, down ? "down" : "up")) }
    func sendText(_ text: String) -> Bool { if unicodeWorks { log.append("text \(text)") }; return unicodeWorks }
    func scancode(forMacKey k: UInt16) -> UInt16 { rdp_scancode_for_mac_keycode(k, rdp_mac_keyboard_is_iso()) }
}

var passed = 0, failed = 0
func expect(_ name: String, _ got: [String], _ want: [String]) {
    if got == want { passed += 1; print("  ok    \(name)") }
    else { failed += 1; print("  FAIL  \(name)\n        got  \(got)\n        want \(want)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)            // no Dock icon, nothing on screen
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250), styleMask: [.titled],
                      backing: .buffered, defer: true)
let view = DesktopView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
window.contentView = view
window.makeFirstResponder(view)
let rec = Recorder()
view.connection = rec

// Device-dependent bits, IOLLEvent.h, on top of the device-independent flags.
func flags(_ independent: NSEvent.ModifierFlags, _ device: UInt) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: independent.rawValue | device)
}
func mod(_ code: UInt16, _ f: NSEvent.ModifierFlags) {
    view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, characters: "",
                                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
}
func key(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, _ f: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: window.windowNumber,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}
func run(_ name: String, want: [String], _ body: () -> Void) {
    rec.log = []
    body()
    expect(name, rec.log, want)
    view.releaseAll(); rec.log = []
}

let cmdL = flags(.command, 0x8), cmdR = flags(.command, 0x10)
let optL = flags(.option, 0x20), shiftL = flags(.shift, 0x2), ctlL = flags(.control, 0x1)

print("== Shortcuts")
run("Cmd-C becomes Ctrl+C, key pressed and released at once",
    want: ["key 01D down", "key 02E down", "key 02E up", "key 01D up"]) {
    mod(0x37, cmdL)
    _ = view.performKeyEquivalent(with: key(.keyDown, 0x08, "c", cmdL))
    mod(0x37, [])
}
run("Cmd-Q is left to macOS", want: ["key 01D down"]) {
    mod(0x37, cmdL)
    let handled = view.performKeyEquivalent(with: key(.keyDown, 0x0C, "q", cmdL))
    if handled { rec.log.append("WRONGLY CAPTURED") }
}
run("Right Cmd is the Windows key", want: ["key 15B down", "key 15B up"]) {
    mod(0x36, cmdR); mod(0x36, [])
}
run("Mac Control + key goes by position and is held until key up",
    want: ["key 01D down", "key 011 down", "key 011 up", "key 01D up"]) {
    mod(0x3B, ctlL)
    view.keyDown(with: key(.keyDown, 0x0D, "w", ctlL))
    view.keyUp(with: key(.keyUp, 0x0D, "w", ctlL))
    mod(0x3B, [])
}

print("== Typing")
run("plain letter is sent as the character", want: ["text a"]) {
    view.keyDown(with: key(.keyDown, 0x0C, "a"))
    view.keyUp(with: key(.keyUp, 0x0C, "a"))
}
run("AZERTY é is sent as é", want: ["text é"]) {
    view.keyDown(with: key(.keyDown, 0x13, "é"))
    view.keyUp(with: key(.keyUp, 0x13, "é"))
}
run("Option character: no Alt reaches Windows", want: ["text @"]) {
    mod(0x3A, optL)
    view.keyDown(with: key(.keyDown, 0x0A, "@", optL))
    view.keyUp(with: key(.keyUp, 0x0A, "@", optL))
    mod(0x3A, [])
}
run("Option+Tab: Alt only around the key, released with Option",
    want: ["key 038 down", "key 00F down", "key 00F up", "key 038 up"]) {
    mod(0x3A, optL)
    view.keyDown(with: key(.keyDown, 0x30, "\t", optL))
    view.keyUp(with: key(.keyUp, 0x30, "\t", optL))
    mod(0x3A, [])
}
run("Shift+Left selects, by position", want: ["key 02A down", "key 14B down", "key 14B up", "key 02A up"]) {
    mod(0x38, shiftL)
    view.keyDown(with: key(.keyDown, 0x7B, "\u{F702}", shiftL))
    view.keyUp(with: key(.keyUp, 0x7B, "\u{F702}", shiftL))
    mod(0x38, [])
}
run("Return goes by position", want: ["key 01C down", "key 01C up"]) {
    view.keyDown(with: key(.keyDown, 0x24, "\r")); view.keyUp(with: key(.keyUp, 0x24, "\r"))
}
rec.unicodeWorks = false
run("no Unicode support on the server: falls back to the key", want: ["key 010 down", "key 010 up"]) {
    view.keyDown(with: key(.keyDown, 0x0C, "a")); view.keyUp(with: key(.keyUp, 0x0C, "a"))
}
rec.unicodeWorks = true
run("leaving the window lets go of everything held", want: ["key 01D down", "key 01D up"]) {
    mod(0x37, cmdL)
    view.releaseAll()
}

print("== Scrolling")
func scroll(_ dy: Int32, _ dx: Int32) {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
    view.scrollWheel(with: NSEvent(cgEvent: cg)!)
}
run("content-down delta scrolls Windows up (positive)", want: ["wheel 20"]) { scroll(10, 0) }
run("opposite delta scrolls Windows down", want: ["wheel -20"]) { scroll(-10, 0) }
run("horizontal is flipped to Windows' convention", want: ["hwheel -20"]) { scroll(0, 10) }

print("== Mouse position")
let surface = IOSurface(properties: [.width: 1000, .height: 500, .bytesPerElement: 4, .pixelFormat: 0x42475241])!
view.display(surface: surface, size: CGSize(width: 1000, height: 500))
func click(at p: NSPoint) {
    view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1)!)
}
run("view point maps to desktop pixel, y flipped", want: ["mouse 9000 200,100"]) { click(at: NSPoint(x: 100, y: 200)) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
