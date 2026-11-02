//
//  SessionApp.swift
//
//  Each session runs as its own process from a small app bundle per host, so
//  every server gets its own Dock tile, Cmd-Tab entry and Mission Control
//  name.
//
//  The bundle is an Info.plist named after the host plus a copy of this app's
//  executable, signed ad hoc for that bundle. Not a link: with the main app's
//  signature the bundle's own Info.plist breaks it, and macOS then refuses the
//  session the Desktop and Documents folders without asking. Not a symlink
//  either: LaunchServices resolves one back to the main app and shows its name
//  instead (tested). A tile kept in the Dock opens that host directly, using
//  saved passwords. Passwords go to the session process over a pipe, never on
//  the command line.
//

import AppKit

enum SessionBundle {
    /// Info.plist keys that make the executable run as one session.
    static let hostKey = "iGatewayHostID"
    static let appKey = "iGatewayApp"
    /// File number of the main app's executable the bundle was built from.
    static let buildKey = "iGatewayBuild"

    static var directory: URL { Store.directory.appendingPathComponent("Sessions.noindex", isDirectory: true) }

    /// "<main app id>.session.", also right when called from a session process.
    static var idPrefix: String {
        let own = Bundle.main.bundleIdentifier ?? "igateway"
        return (own.components(separatedBy: ".session.").first ?? own) + ".session."
    }

    static func bundleIdentifier(for hostID: UUID) -> String {
        idPrefix + hostID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Opens the host in its own process, or brings its session to the front
    /// when it is already open. False when that could not be done, so the
    /// caller can run the session inside the main app instead.
    static func open(host: Host, password: String, gatewayPassword: String?) -> Bool {
        let id = bundleIdentifier(for: host.id)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            bringToFront(running)
            return true
        }
        // Started a moment ago and not registered with the system yet.
        if let starting = launching[host.id], starting.isRunning {
            return true
        }
        guard let bundle = make(for: host),
              let executable = Bundle(url: bundle)?.executableURL else { return false }

        let process = Process()
        process.executableURL = executable
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            AppLog.write("\(host.display): session app ended (exit \(process.terminationStatus))")
            DispatchQueue.main.async { running.removeAll { $0 === process } }
        }
        do {
            try process.run()
            let secrets = try JSONEncoder().encode(Secrets(password: password, gatewayPassword: gatewayPassword))
            try pipe.fileHandleForWriting.write(contentsOf: secrets)
            try pipe.fileHandleForWriting.close()
        } catch {
            AppLog.write("\(host.display): could not start its session app: \(error.localizedDescription)")
            if process.isRunning { process.terminate() }
            return false
        }
        running.append(process)
        launching[host.id] = process
        if #available(macOS 14.0, *) { NSApp.yieldActivation(toApplicationWithBundleIdentifier: id) }
        AppLog.write("\(host.display): started its session app, pid \(process.processIdentifier)")
        return true
    }

    /// Kept until they exit, so Foundation can reap them.
    private static var running: [Process] = []
    /// The newest session process per host, for the moment before macOS lists it.
    private static var launching: [UUID: Process] = [:]

    /// Activates a session app the way the Dock does, so a minimised window
    /// comes back too (the session app handles the reopen).
    static func bringToFront(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { app.activate(options: []); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The main app, also when asked from inside a session process, whose own
    /// bundle is the per-host one.
    static var mainApp: Bundle {
        if let path = Bundle.main.object(forInfoDictionaryKey: appKey) as? String, let app = Bundle(path: path) {
            return app
        }
        return Bundle.main
    }

    private static func inode(_ path: String?) -> UInt64? {
        guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// True when this session process runs an older build than the installed
    /// app: its bundle still holds the executable from before an update. Read
    /// from disk, so it turns false once the bundle has been rebuilt.
    static var runningStaleBuild: Bool {
        guard Bundle.main !== mainApp, let current = inode(mainApp.executablePath) else { return false }
        let info = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
        return info?[buildKey] as? String != String(current)
    }

    /// Relinks the bundles of hosts that aren't open, so tiles kept in the Dock
    /// start the current build after an update.
    static func refresh(hosts: [Host]) {
        for host in hosts where FileManager.default.fileExists(atPath: directory.appendingPathComponent(host.id.uuidString).path)
            && NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier(for: host.id)).isEmpty {
            _ = make(for: host)
        }
    }

    /// Builds or refreshes the bundle for a host: on every connect, so a new
    /// label or a reinstalled app is picked up.
    static func make(for host: Host) -> URL? {
        let fm = FileManager.default
        let app = mainApp
        guard let executable = app.executableURL?.resolvingSymlinksInPath() else { return nil }
        let name = host.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let hostDirectory = directory.appendingPathComponent(host.id.uuidString, isDirectory: true)
        let bundle = hostDirectory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        do {
            // A renamed host leaves a bundle under its old name behind.
            for old in (try? fm.contentsOfDirectory(at: hostDirectory, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent != bundle.lastPathComponent {
                try? fm.removeItem(at: old)
            }
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let version = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            var info: [String: Any] = [
                "CFBundleName": host.title,
                "CFBundleDisplayName": host.title,
                "CFBundleIdentifier": bundleIdentifier(for: host.id),
                "CFBundleExecutable": executable.lastPathComponent,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": version,
                "LSMinimumSystemVersion": "13.0",
                "NSHighResolutionCapable": true,
                hostKey: host.id.uuidString,
                appKey: app.bundlePath,
                buildKey: inode(executable.path).map(String.init) ?? "",
            ]
            // Sessions show a PC, the main app an apple.
            let icon = app.url(forResource: "SessionIcon", withExtension: "icns")
                ?? app.url(forResource: "AppIcon", withExtension: "icns")
            if icon != nil { info["CFBundleIconFile"] = "AppIcon" }
            let infoURL = contents.appendingPathComponent("Info.plist")
            let target = macOS.appendingPathComponent(executable.lastPathComponent)
            // Built from this app with these settings already: signing it
            // again would only slow down every connect.
            if NSDictionary(contentsOf: infoURL) == NSDictionary(dictionary: info),
               fm.fileExists(atPath: target.path),
               fm.fileExists(atPath: contents.appendingPathComponent("_CodeSignature").path) {
                return bundle
            }
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: infoURL, options: .atomic)
            // Replacing the executable of a running session is safe: the
            // running process keeps its own copy.
            try? fm.removeItem(at: target)
            try fm.copyItem(at: executable, to: target)
            if let icon { try? link(icon, to: resources.appendingPathComponent("AppIcon.icns")) }
            sign(bundle, host: host)
            // A new date makes macOS reread the bundle and its icon.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
            return bundle
        } catch {
            AppLog.write("\(host.display): could not build its session app: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ad-hoc signature for the bundle as it is now, so macOS asks before a
    /// session reads Desktop or Documents instead of refusing it.
    private static func sign(_ bundle: URL, host: Host) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--force", "--sign", "-", bundle.path]
        task.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        task.standardError = errors
        do {
            try task.run()
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                AppLog.write("\(host.display): could not sign its session app: "
                             + String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            AppLog.write("\(host.display): could not sign its session app: \(error.localizedDescription)")
        }
    }

    /// Hard link, falling back to a symlink. Only for the icon: the
    /// executable needs its own copy to carry its own signature.
    private static func link(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        do {
            try fm.linkItem(at: source, to: target)
        } catch {
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }

    /// Removes the bundles of hosts that are gone, unless one is still running.
    static func prune(keeping hosts: [Host]) {
        let fm = FileManager.default
        let keep = Set(hosts.map(\.id.uuidString))
        for folder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(folder.lastPathComponent) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier(for: id)).isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }
}

/// What the main app hands a session process over its pipe.
struct Secrets: Codable {
    var password: String
    var gatewayPassword: String?

    /// Only from a pipe: started from a Dock tile there is none, and from a
    /// terminal stdin is the keyboard, which must not be waited on.
    static func fromStandardInput() -> Secrets? {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }
}

/// The app running as one session.
final class SessionAppDelegate: NSObject, NSApplicationDelegate, MenuTarget {
    private let hostID: UUID
    private var settings = AppSettings()
    private var session: SessionWindowController?

    init(hostID: UUID) {
        self.hostID = hostID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu(target: self)
        let secrets = Secrets.fromStandardInput()
        guard let loaded = Store.read(),
              let host = loaded.hosts.first(where: { $0.id == hostID }),
              let gateway = loaded.gateway(for: host),
              let server = loaded.accounts.first(where: { $0.id == gateway.serverAccountID }) ?? loaded.accounts.first
        else {
            AppLog.write("Session app for \(hostID): host or account no longer configured")
            openMainApp()
            NSApp.terminate(nil)
            return
        }
        // Started from a Dock tile after an update: relink to the current build
        // and start that instead, once. Started from the host list, the bundle
        // was just made, so this never applies with passwords on the pipe.
        if secrets == nil, SessionBundle.runningStaleBuild, let fresh = SessionBundle.make(for: host),
           !SessionBundle.runningStaleBuild || fresh.path != Bundle.main.bundlePath {
            AppLog.write("\(host.display): session app was an older build, restarting it")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: fresh, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        settings = loaded
        let gatewayAccount = gateway.separateAccount && !gateway.isDirect
            ? loaded.accounts.first(where: { $0.id == gateway.gatewayAccountID }) : nil
        let separate = gatewayAccount.map { $0.keychainKey != server.keychainKey } ?? false
        // Each host remembers its own window size: the defaults are per bundle.
        if let size = UserDefaults.standard.array(forKey: "lastSessionSize") as? [Double], size.count == 2 {
            settings.windowWidth = max(640, size[0])
            settings.windowHeight = max(400, size[1])
        }
        NSApp.applicationIconImage = Self.icon(labelled: host.dockLabel, color: host.color)

        Task { @MainActor in
            var password = secrets?.password
            if password == nil { password = await Keychain.passwordAsync(for: server.keychainKey) }
            var gatewayPassword = separate ? secrets?.gatewayPassword : nil
            if separate, gatewayPassword == nil, let gatewayAccount {
                gatewayPassword = await Keychain.passwordAsync(for: gatewayAccount.keychainKey)
            }
            // Started from a Dock tile without saved passwords: let the main
            // app ask for them, rather than trying a login without one.
            guard let password, !separate || gatewayPassword != nil else {
                AppLog.write("\(host.display): no saved password, opening the host list instead")
                self.openMainApp()
                NSApp.terminate(nil)
                return
            }
            self.start(host: host, gateway: gateway, server: server,
                       gatewayAccount: separate ? gatewayAccount : nil,
                       password: password, gatewayPassword: gatewayPassword)
        }
    }

    private func start(host: Host, gateway: Gateway, server: Account, gatewayAccount: Account?,
                       password: String, gatewayPassword: String?) {
        let session = SessionWindowController(
            host: host, gateway: gateway, server: server, gatewayAccount: gatewayAccount,
            password: password, gatewayPassword: gatewayPassword,
            settings: { [unowned self] in self.settings },
            onDynamicResolutionFailed: { [weak self] host in
                guard var fresh = Store.read() else { return }
                if !fresh.hostsWithoutDynamicResolution.contains(host.id) {
                    fresh.hostsWithoutDynamicResolution.append(host.id)
                    Store.save(fresh)
                }
                self?.settings.hostsWithoutDynamicResolution = fresh.hostsWithoutDynamicResolution
            },
            onClose: { _ in })
        self.session = session
        // Step each new session window away from the ones already open.
        let others = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier?.hasPrefix(SessionBundle.idPrefix) ?? false)
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.count
        if let window = session.window, others > 0 {
            let step = CGFloat(min(others, 8) * 26)
            window.setFrameOrigin(NSPoint(x: window.frame.minX + step, y: window.frame.minY - step))
        }
        session.start()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock click or Show in the host list: a minimised window comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = session?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session, session.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Close the session to \(session.host.title)?"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        session.disconnectForQuit()
        // Give the session a moment to say goodbye to the server.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Store.clipboardCache)
    }

    @objc func showHosts() { openMainApp() }

    @objc func showLogs() { AppLog.reveal() }

    private func openMainApp() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: SessionBundle.appKey) as? String else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// The PC icon, read straight from the main app's file. The bundle's own
    /// icon goes through macOS's icon cache, which can hold an older one.
    static func sessionIcon() -> NSImage {
        if let app = Bundle.main.object(forInfoDictionaryKey: SessionBundle.appKey) as? String,
           let image = NSImage(contentsOfFile: app + "/Contents/Resources/SessionIcon.icns") {
            return image
        }
        return NSApp.applicationIconImage ?? NSImage()
    }

    /// The session icon, a PC, with the host's label big on its screen so
    /// Dock tiles tell apart. No label, no text. Short labels get large type;
    /// long ones shrink and wrap to a second line.
    static func icon(labelled text: String, color: NSColor? = nil) -> NSImage {
        let base = sessionIcon()
        guard !text.isEmpty else { return base }
        let side: CGFloat = 512
        let s = SessionIconLayout.screen
        let area = NSRect(x: side * s.minX, y: side * s.minY, width: side * s.width, height: side * s.height)
            .insetBy(dx: side * 0.025, dy: side * 0.02)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = 0.9
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 8

        // The largest size at which the label fits in two lines.
        var label = NSAttributedString(string: text)
        var textHeight: CGFloat = 0
        for size in stride(from: CGFloat(170), through: 30, by: -4) {
            let font = NSFont.systemFont(ofSize: size, weight: .heavy)
            label = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color ?? NSColor.white, .paragraphStyle: style, .shadow: shadow,
            ])
            let lineHeight = ceil((font.ascender - font.descender + font.leading) * 0.9)
            textHeight = ceil(label.boundingRect(with: NSSize(width: area.width, height: 10_000), options: options).height)
            if textHeight <= min(area.height, lineHeight * 2 + 1) { break }
        }
        let fitted = min(textHeight, area.height)
        let textRect = NSRect(x: area.minX, y: area.midY - fitted / 2, width: area.width, height: fitted)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            label.draw(with: textRect, options: options)
            return true
        }
    }
}

/// Where make-icon.swift draws the session icon's screen, as fractions of the
/// icon. Keep in step with `screen` there.
enum SessionIconLayout {
    static let screen = NSRect(x: 160.0 / 1024, y: 352.0 / 1024, width: 704.0 / 1024, height: 448.0 / 1024)
}
