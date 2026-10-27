import AppKit
import IOSurface

final class Probe: ConnectionDelegate {
    var states: [String] = []
    var frames = 0
    var size = CGSize.zero
    var cursors = 0
    var lastSurface: IOSurface?
    func connection(_ c: Connection, didChange state: Connection.State) { states.append("\(state)") }
    func connection(_ c: Connection, didDisplay surface: IOSurface, size: CGSize) {
        frames += 1; self.size = size; lastSurface = surface
    }
    func connection(_ c: Connection, didSetCursor cursor: RemoteCursor) { cursors += 1 }
    var certificates = 0
    /// The test server's certificate is self-signed. Trusted for this
    /// connection only, so nothing is stored in ~/.config/freerdp.
    func connection(_ c: Connection, verify certificate: CertificateInfo,
                    decide: @escaping (CertificateInfo.Decision) -> Void) {
        certificates += 1
        decide(.trustOnce)
    }
}

var settings = AppSettings()
settings.sound = true
settings.shareFolder = true
settings.sharedFolderPath = CommandLine.arguments[1]
let host = Host(address: "127.0.0.1:13389", label: "local test")
let probe = Probe()
let direct = Gateway()                     // never touch a real gateway from a test
let connection = Connection(host: host, gateway: direct, server: Account(username: "t", domain: ""), gatewayAccount: nil,
                            settings: settings, useDynamicResolution: true)
connection.securityProtocol = "tls"   // TLS, so there is a certificate to ask about
connection.delegate = probe
connection.connect(pixelSize: CGSize(width: 1023, height: 700), scale: 100, password: "t", gatewayPassword: nil)
// Wait for the session, then change Caps Lock while it is live.
let start = Date()
while connection.state != .connected, Date().timeIntervalSince(start) < 5 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
connection.syncLocks(capsLock: true)
connection.syncLocks(capsLock: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
let upAfterLocks = connection.state == .connected
RunLoop.main.run(until: start.addingTimeInterval(6))


var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ok    \(name)") } else { failed += 1; print("  FAIL  \(name)  \(detail())") }
}
check("connects", probe.states.contains("connected"), probe.states.joined(separator: " -> "))
check("asks about the self-signed certificate once", probe.certificates == 1, "\(probe.certificates)")
check("frames arrive", probe.frames > 0)
check("a Caps Lock change leaves the session up", upAfterLocks)
check("width is rounded down to even", Int(probe.size.width) == 1022, "\(probe.size)")
if let s = probe.lastSurface {
    s.lock(options: .readOnly, seed: nil)
    let p = s.baseAddress.assumingMemoryBound(to: UInt8.self)
    var opaque = true
    outer: for y in 0..<s.height { for x in 0..<s.width where p[y * s.bytesPerRow + x * 4 + 3] != 255 { opaque = false; break outer } }
    s.unlock(options: .readOnly, seed: nil)
    check("surfaces are opaque", opaque)
    check("surfaces are tagged sRGB", IOSurfaceCopyValue(s, kIOSurfaceColorSpace) != nil)
} else {
    check("a surface was shown", false)
}
connection.disconnect()
RunLoop.main.run(until: Date().addingTimeInterval(3))
check("disconnects cleanly", probe.states.last == "disconnected" && !connection.isActive)
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
