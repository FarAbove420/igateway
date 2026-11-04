import AppKit
// Started by the stand-in ssh below as its password helper, like the app.
if ProcessInfo.processInfo.environment[Askpass.socketVariable] != nil { exit(Askpass.runHelper()) }
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
check("executable is its own copy, not a link",
      a[.type] as? FileAttributeType == .typeRegular && (a[.systemFileNumber] as? Int) != (b[.systemFileNumber] as? Int))
let verify = Process()
verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
verify.arguments = ["--verify", "--strict", bundle.path]
verify.standardError = FileHandle.nullDevice
try! verify.run(); verify.waitUntilExit()
check("its signature is valid for this bundle", verify.terminationStatus == 0)
_ = SessionBundle.make(for: host)
let again = try! FileManager.default.attributesOfItem(atPath: exe.path)
check("an unchanged host isn't copied and signed again",
      (again[.systemFileNumber] as? Int) == (a[.systemFileNumber] as? Int))

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
// An SSH session with a stand-in for ssh: no network, no window on screen.
final class MemoryPasswords { var saved: [String: String] = [:] }
func runFakeSSH(exitCode: Int32, script body: String? = nil,
                setUp: (TerminalWindowController) -> Void = { _ in }) -> HistoryEntry? {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("igateway-fake-ssh-\(exitCode)")
    try? (body ?? "#!/bin/sh\necho \"fake ssh $*\"\nexit \(exitCode)\n").write(to: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    defer { try? FileManager.default.removeItem(at: script) }
    SSHCommand.executable = script.path
    var fake = Host(address: "192.0.2.40", label: "fake \(exitCode)")
    fake.kind = .ssh
    fake.sshUser = "admin"
    fake.sshAuth = .password
    let terminal = TerminalWindowController(host: fake)
    setUp(terminal)
    terminal.start()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if let entry = History.read().first(where: { $0.hostID == fake.id }), entry.ended != nil { return entry }
    }
    return nil
}
let loggedOut = runFakeSSH(exitCode: 0)
check("ssh: a normal end is recorded as ended", loggedOut?.state == .ended)
let refused = runFakeSSH(exitCode: 255)
check("ssh: exit 255 is recorded as failed", refused?.state == .failed && refused?.detail != nil)
// Saved passwords: the stand-in asks through the real helper, as ssh does.
let askingSSH = """
#!/bin/sh
answer=$("$SSH_ASKPASS" "admin@192.0.2.40's password: ")
[ "$answer" = "s3cret" ] && exit 0
answer=$("$SSH_ASKPASS" "admin@192.0.2.40's password: ")
[ "$answer" = "typed" ] && exit 0
exit 255

"""
let memory = MemoryPasswords()
let key = SSHCommand.Login(user: "admin", address: "192.0.2.40", port: nil).keychainKey
func useMemory(_ t: TerminalWindowController) {
    t.passwords = SSHPasswords(get: { memory.saved[$0] }, set: { memory.saved[$1] = $0 },
                               delete: { memory.saved[$0] = nil })
}
memory.saved[key] = "s3cret"
var asked = 0
let savedRun = runFakeSSH(exitCode: 1, script: askingSSH) { t in
    useMemory(t)
    t.ask = { _, _, done in asked += 1; done(nil, false) }
}
check("a saved password reaches ssh through the helper, without asking", savedRun?.state == .ended && asked == 0)
memory.saved[key] = "wrong"
var retried = false
let retryRun = runFakeSSH(exitCode: 2, script: askingSSH) { t in
    useMemory(t)
    t.ask = { prompt, retry, done in
        if case .password = prompt, retry { retried = true }
        done("typed", true)
    }
}
check("a refused saved password is asked again, and the new one is saved",
      retryRun?.state == .ended && retried && memory.saved[key] == "typed")

// The helper's socket answers only a process started by its ssh, with the token.
func runHelper(socket: String, token: String) -> (Int32, String) {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: Askpass.helperPath)
    helper.arguments = ["admin@192.0.2.40's password: "]
    helper.environment = [Askpass.socketVariable: socket, Askpass.tokenVariable: token]
    let out = Pipe()
    helper.standardOutput = out
    try? helper.run()
    // The answer comes from the main thread, so keep it turning.
    while helper.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return (helper.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
var handled = 0
let notOurs = AskpassServer(isFromSSH: { Askpass.descends($0, from: 999_999) }, handle: { _, reply in handled += 1; reply("x") })!
check("a process ssh didn't start gets nothing", runHelper(socket: notOurs.socketPath, token: notOurs.token).0 != 0 && handled == 0)
notOurs.stop()
let ours = AskpassServer(isFromSSH: { Askpass.descends($0, from: getpid()) }, handle: { _, reply in handled += 1; reply("x") })!
check("nor one with the wrong token", runHelper(socket: ours.socketPath, token: String(repeating: "0", count: 64)).0 != 0 && handled == 0)
let good = runHelper(socket: ours.socketPath, token: ours.token)
check("the right process with the token gets the answer", good.0 == 0 && good.1 == "x\n" && handled == 1)
ours.stop()
check("the socket's folder goes when the session ends", !FileManager.default.fileExists(atPath: ours.socketPath))
SSHCommand.executable = "/usr/bin/ssh"

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
