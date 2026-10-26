import AppKit
NSApplication.shared.setActivationPolicy(.prohibited)   // nothing on screen
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "  ok    \(name)" : "  FAIL  \(name)"); if ok { passed += 1 } else { failed += 1 } }

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "secrets" {
    let s = Secrets.fromStandardInput()
    print(s.map { "password=\($0.password) gateway=\($0.gatewayPassword ?? "nil")" } ?? "none")
    exit(0)
}

let host = Host(address: "192.0.2.10", label: "fileserver (main office)", gatewayID: nil)
guard let bundle = SessionBundle.make(for: host) else { print("make failed"); exit(1) }
check("bundle is named after the host", bundle.lastPathComponent == "fileserver (main office).app")
check("it sits in a .noindex folder, out of Spotlight", bundle.path.contains("/Sessions.noindex/"))
let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
check("CFBundleName is the host", info["CFBundleName"] as? String == host.title)
check("bundle id is per host", info["CFBundleIdentifier"] as? String == SessionBundle.bundleIdentifier(for: host.id))
check("host id key present", info[SessionBundle.hostKey] as? String == host.id.uuidString)
let exe = bundle.appendingPathComponent("Contents/MacOS/\(Bundle.main.executableURL!.lastPathComponent)")
let a = try! FileManager.default.attributesOfItem(atPath: exe.path)
let b = try! FileManager.default.attributesOfItem(atPath: Bundle.main.executableURL!.resolvingSymlinksInPath().path)
check("executable is a hard link, not a copy or symlink",
      a[.type] as? FileAttributeType == .typeRegular && (a[.systemFileNumber] as? Int) == (b[.systemFileNumber] as? Int))

var renamed = host
renamed.label = "printserver"
let second = SessionBundle.make(for: renamed)!
let folder = second.deletingLastPathComponent()
let left = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
check("renaming the host replaces the old bundle", left == ["printserver.app"])

SessionBundle.prune(keeping: [])
check("prune removes bundles of hosts that are gone", !FileManager.default.fileExists(atPath: folder.path))

var s = AppSettings()
s.gateways = [Gateway(name: "", host: "rdg.example.com")]
s.normalize()
check("a direct group is always there", s.gateways.count == 2 && s.gateways[1].isDirect)
s.normalize()
check("and only once", s.gateways.filter(\.isDirect).count == 1)

// The repository root, three folders up from this file.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
NSApp.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("icon/SessionIcon.icns"))
let colors: [NSColor?] = [nil, NSColor(hex: "#0000FF")?.visibleOnBlack, nil, NSColor(hex: "#000000")?.visibleOnBlack]
for (n, t) in ["SCCM", "DC1", "", "PRN"].enumerated() {
    let i = SessionAppDelegate.icon(labelled: t, color: colors[n])
    let r = NSBitmapImageRep(data: i.tiffRepresentation!)!
    try! r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/dock-\(n).png"))
}
let icon = SessionAppDelegate.icon(labelled: "fileserver (main office)")
let rep = NSBitmapImageRep(data: icon.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/dock-icon.png"))
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
