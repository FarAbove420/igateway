import AppKit
import SwiftTerm
// Renders the README's screenshots into the folder given, from example data
// only (documentation addresses and example.com), in windows that are never
// shown. Run with: tests/run.zsh --screenshots
NSApplication.shared.setActivationPolicy(.prohibited)
NSApp.appearance = NSAppearance(named: .darkAqua)
let out = CommandLine.arguments[1]

/// The whole window, title bar included, at Retina scale. SwiftTerm paints
/// its background on a layer, which this render leaves transparent: `fill`
/// puts the content area on that colour, as the screen shows it.
func render(_ window: NSWindow, to name: String, fill: NSColor? = nil) {
    let frame = window.contentView!.superview!
    window.displayIfNeeded()
    frame.layoutSubtreeIfNeeded()
    func bitmap() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width * 2),
                                   pixelsHigh: Int(frame.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = frame.bounds.size
        return rep
    }
    var rep = bitmap()
    frame.cacheDisplay(in: frame.bounds, to: rep)
    if let fill {
        let under = bitmap()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: under)
        NSBezierPath(roundedRect: frame.bounds, xRadius: 10, yRadius: 10).addClip()
        fill.setFill()
        window.contentView!.frame.fill()
        rep.draw(in: frame.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        rep = under
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
    print("Wrote \(name), \(rep.pixelsWide) x \(rep.pixelsHigh)")
}

// MARK: The host list

let jane = Account(username: "jane", domain: "CORP")
let office = Gateway(name: "Office", host: "rdg.example.com", serverAccountID: jane.id)
func ssh(_ address: String, _ label: String, user: String, jump: String = "", badge: String = "", color: String = "",
         auth: SSHAuth = .key) -> Host {
    var h = Host(address: address, label: label, dockLabel: badge, labelColor: color)
    h.kind = .ssh
    h.sshUser = user
    h.jumpHost = jump
    h.sshAuth = auth
    return h
}
let files = Host(address: "192.0.2.10", label: "File server", gatewayID: office.id, dockLabel: "FS", labelColor: "#0A84FF")
let printer = Host(address: "192.0.2.11", label: "Print server", gatewayID: office.id, dockLabel: "PRN", labelColor: "#FF9F0A")
let build = Host(address: "192.0.2.12", label: "Build agent", gatewayID: office.id)
let web = ssh("203.0.113.21", "web-01", user: "jane", jump: "jane@jump.example", badge: "WEB", color: "#BF5AF2")
let db = ssh("203.0.113.22", "db-01", user: "jane", jump: "jane@jump.example")
let core = ssh("198.51.100.2", "Core switch", user: "admin", badge: "SW", color: "#30D158", auth: .password)
let lab = Host(address: "198.51.100.5", label: "Lab PC")

var settings = AppSettings()
settings.accounts = [jane]
settings.gateways = [office]
settings.hosts = [files, printer, build, web, db, core, lab]
settings.normalize()
settings.lastHostID = web.id
settings.lastGatewayID = settings.gateway(for: settings.hosts.first { $0.id == web.id }!)?.id
Store.save(settings)

func entry(_ host: Host, _ account: String, minutesAgo: Double, lasted: Double?, _ state: HistoryEntry.State,
           _ detail: String? = nil) -> HistoryEntry {
    var e = HistoryEntry(hostID: host.id, title: host.title, address: host.address, account: account)
    e.started = Date().addingTimeInterval(-minutesAgo * 60)
    e.connected = state == .failed ? nil : e.started
    e.ended = lasted.map { e.started.addingTimeInterval($0 * 60) }
    e.state = state
    e.detail = detail
    return e
}
History.modify { entries in
    entries = [
        entry(web, "jane", minutesAgo: 30, lasted: 26, .ended),
        entry(files, "CORP\\jane", minutesAgo: 95, lasted: 74, .ended),
        entry(core, "admin", minutesAgo: 180, lasted: 6, .ended),
        entry(build, "CORP\\jane", minutesAgo: 240, lasted: 0.2, .failed, "The username or password was rejected."),
        entry(lab, "CORP\\jane", minutesAgo: 1500, lasted: 52, .ended, "closed"),
    ]
}

let launcher = LauncherWindowController(app: AppController())
launcher.window!.setContentSize(NSSize(width: 900, height: 600))
launcher.reload()
render(launcher.window!, to: "screenshot.png")

// MARK: An SSH session

let terminal = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 260))
terminal.font = TerminalWindowController.font(.sfMono, size: 13)
terminal.nativeBackgroundColor = .black
terminal.nativeForegroundColor = TerminalWindowController.defaultTextColor
terminal.caretColor = TerminalWindowController.defaultTextColor
terminal.caretTextColor = .black
let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
window.title = "web-01"
window.contentView = terminal
window.backgroundColor = .black
let prompt = "\u{1b}[1;32mjane@web-01\u{1b}[0m:\u{1b}[1;34m~\u{1b}[0m$ "
terminal.feed(text: [
    "Linux web-01 6.12.48+deb13-amd64 #1 SMP PREEMPT_DYNAMIC x86_64",
    "Last login: Wed Nov  4 09:12:44 2026 from 203.0.113.1",
    prompt + "uptime",
    " 09:14:02 up 41 days,  3:02,  1 user,  load average: 0.08, 0.05, 0.01",
    prompt + "systemctl status nginx --no-pager",
    "\u{1b}[1;32m●\u{1b}[0m nginx.service - A high performance web server and a reverse proxy server",
    "     Loaded: loaded (/usr/lib/systemd/system/nginx.service; \u{1b}[1;32menabled\u{1b}[0m; preset: \u{1b}[1;32menabled\u{1b}[0m)",
    "     Active: \u{1b}[1;32mactive (running)\u{1b}[0m since Mon 2026-09-23 06:12:01 UTC; 1 month 11 days ago",
    "   Main PID: 812 (nginx)",
    "      Tasks: 3 (limit: 4647)",
    "     Memory: 6.1M (peak: 7.4M)",
    prompt,
].joined(separator: "\r\n"))
render(window, to: "terminal.png", fill: .black)
