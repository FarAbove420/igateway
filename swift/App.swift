//
//  App.swift
//
//  iGateway.exe: an RDP client for macOS that links FreeRDP as a library, so
//  the app owns its windows, keyboard and clipboard.
//
//  Plain AppKit, no SwiftUI: some Command Line Tools releases ship without
//  the SwiftUIMacros plugin, and AppKit builds with the tools alone.
//

import AppKit

final class AppController {
    private(set) var settings: AppSettings
    private var launcher: LauncherWindowController?
    private(set) var sessions: [SessionWindowController] = []
    /// SSH sessions in windows here, only when their own app couldn't start.
    private var terminals: [TerminalWindowController] = []
    private let persist: Bool

    init() {
        settings = Store.load()
        persist = true
    }

    /// For rendering and tests: never reads or writes the real config.
    init(previewSettings: AppSettings) {
        settings = previewSettings
        persist = false
    }

    /// Starts from what is saved, so changes a session process made in the
    /// meantime are kept.
    func update(_ change: (inout AppSettings) -> Void) {
        if persist, let saved = Store.read() { settings = saved }
        change(&settings)
        if persist { Store.save(settings) }
    }

    /// The host list, shown.
    func launcherWindow() -> LauncherWindowController {
        showLauncher()
        return launcher!
    }

    /// The host list shows a newer release as a button in its title bar.
    func releaseInfoChanged() { launcher?.showUpdate() }

    func showLauncher() {
        if launcher == nil { launcher = LauncherWindowController(app: self) }
        launcher?.reload()
        launcher?.showWindow(nil)
        launcher?.window?.makeKeyAndOrderFront(nil)
    }

    /// Each session runs as its own app, for its own Dock tile. Only if that
    /// fails does it open in a window of this process.
    func openSession(host: Host, gateway: Gateway, server: Account, gatewayAccount: Account?,
                     password: String, gatewayPassword: String?) {
        if persist, SessionBundle.open(host: host, password: password, gatewayPassword: gatewayPassword) { return }
        if let size = UserDefaults.standard.array(forKey: "lastSessionSize") as? [Double], size.count == 2 {
            update { $0.windowWidth = max(640, size[0]); $0.windowHeight = max(400, size[1]) }
        }
        let session = SessionWindowController(
            host: host, gateway: gateway, server: server, gatewayAccount: gatewayAccount, password: password,
            gatewayPassword: gatewayPassword,
            settings: { [unowned self] in self.settings },
            onDynamicResolutionFailed: { [weak self] host in
                self?.update { s in
                    if !s.hostsWithoutDynamicResolution.contains(host.id) {
                        s.hostsWithoutDynamicResolution.append(host.id)
                    }
                }
                self?.launcher?.reload()
            },
            onClose: { [weak self] closed in
                self?.sessions.removeAll { $0 === closed }
            })
        sessions.append(session)
        session.start()
    }

    /// An SSH host in its own app, or in a window here if that fails.
    func openTerminal(host: Host) {
        if persist, SessionBundle.open(host: host, password: nil, gatewayPassword: nil) { return }
        terminals.removeAll { !($0.window?.isVisible ?? false) }
        let terminal = TerminalWindowController(host: host)
        terminals.append(terminal)
        terminal.showWindow(nil)
        terminal.start()
    }

    var activeSessions: [SessionWindowController] { sessions.filter(\.isActive) }

    /// A session to this host is open: its own app, or a window here.
    func isSessionOpen(hostID: UUID) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SessionBundle.bundleIdentifier(for: hostID)).isEmpty
            || sessions.contains { $0.host.id == hostID && $0.isActive }
            || terminals.contains { $0.host.id == hostID && $0.isActive }
    }

    func showSession(hostID: UUID) {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: SessionBundle.bundleIdentifier(for: hostID)).first {
            SessionBundle.bringToFront(running)
        } else if let window = sessions.first(where: { $0.host.id == hostID })?.window
                    ?? terminals.first(where: { $0.host.id == hostID })?.window {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MenuTarget, NSMenuItemValidation {
    let controller = AppController()
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        AppLog.write("iGateway.exe \(version) started, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
                     + "FreeRDP \(String(cString: rdp_freerdp_version()))")
        installMainMenu(target: self)
        SessionBundle.prune(keeping: controller.settings.hosts)
        SessionBundle.refresh(hosts: controller.settings.hosts)
        Store.pruneClipboardCaches()
        controller.showLauncher()
        NSApp.activate(ignoringOtherApps: true)
        startUpdateChecks()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller.showLauncher() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = controller.activeSessions
        guard !active.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? "Quit and close the session to \(active[0].host.title)?"
            : "Quit and close \(active.count) sessions?"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        active.forEach { $0.disconnectForQuit() }
        // Give the sessions a moment to say goodbye to the servers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Store.clipboardCache)
    }

    @objc func showHosts() { controller.showLauncher() }

    @objc func showLogs() { AppLog.reveal() }

    @objc func importHosts() { controller.launcherWindow().importHosts() }

    @objc func exportHosts() { controller.launcherWindow().exportHosts() }

    @objc func createSSHKey() { controller.launcherWindow().createSSHKey() }

    @objc func openSSHFolder() { SSHKeys.openFolder() }

    // MARK: Updates

    /// Looks at launch and every hour after, but asks GitHub at most once a
    /// day, and only while the automatic check is on.
    private func startUpdateChecks() {
        checkForUpdatesIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdatesIfDue()
        }
    }

    private func checkForUpdatesIfDue() {
        let settings = controller.settings
        guard settings.checkForUpdates, UpdateCheck.isDue(lastCheck: settings.lastUpdateCheck) else { return }
        checkForUpdates(manual: false)
    }

    @objc func checkForUpdatesNow() { checkForUpdates(manual: true) }

    @objc func toggleAutomaticUpdateChecks() {
        controller.update { $0.checkForUpdates.toggle() }
        controller.releaseInfoChanged()
        checkForUpdatesIfDue()
    }

    private func checkForUpdates(manual: Bool) {
        UpdateCheck.fetch { [weak self] result in
            guard let self else { return }
            switch result {
            case .latest(let version):
                controller.update {
                    $0.lastUpdateCheck = Date()
                    $0.latestRelease = version
                }
                controller.releaseInfoChanged()
                let newer = UpdateCheck.isNewer(version, than: UpdateCheck.installed)
                if newer { AppLog.write("iGateway.exe \(version) is out") }
                if manual { showUpdateResult(newer ? version : nil) }
            case .failed(let reason):
                AppLog.write("Update check failed: \(reason)")
                guard manual else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = reason
                alert.runModal()
            }
        }
    }

    private func showUpdateResult(_ newer: String?) {
        let alert = NSAlert()
        guard let newer else {
            alert.messageText = "iGateway.exe \(UpdateCheck.installed) is the latest version."
            alert.runModal()
            return
        }
        alert.messageText = "iGateway.exe \(newer) is out"
        alert.informativeText = "You have \(UpdateCheck.installed)."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(UpdateCheck.releasePage(newer)) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticUpdateChecks) {
            menuItem.state = controller.settings.checkForUpdates ? .on : .off
        }
        return true
    }
}

extension NSApplication {
    /// The standard About panel, with the projects the app is built on.
    @objc func showAboutWithCredits(_ sender: Any?) {
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                   .foregroundColor: NSColor.secondaryLabelColor]
        let credits = NSMutableAttributedString(string: "Built on ", attributes: style)
        let projects = [("FreeRDP", "https://github.com/FreeRDP/FreeRDP"), ("OpenSSL", "https://www.openssl.org"),
                        ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm")]
        for (index, (title, link)) in projects.enumerated() {
            var attributes = style
            attributes[.link] = URL(string: link)
            credits.append(NSAttributedString(string: title, attributes: attributes))
            credits.append(NSAttributedString(string: index == projects.count - 2 ? " and " : index < projects.count - 1 ? ", " : "",
                                              attributes: style))
        }
        credits.append(NSAttributedString(string: ", with Unicode data, and the Mac's own OpenSSH. "
                                          + "Their licences are under Acknowledgements.", attributes: style))
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The third-party notices that travel with the app.
    @objc func showAcknowledgements(_ sender: Any?) {
        let app = Bundle.main.object(forInfoDictionaryKey: SessionBundle.appKey) as? String ?? Bundle.main.bundlePath
        let notices = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/THIRD_PARTY_NOTICES.md")
        guard FileManager.default.fileExists(atPath: notices.path) else { return }
        NSWorkspace.shared.open([notices], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// What the Window menu's own items call.
@objc protocol MenuTarget: NSObjectProtocol {
    func showHosts()
    func showLogs()
    /// Only the main app has a host list to import into.
    @objc optional func importHosts()
    @objc optional func exportHosts()
    @objc optional func createSSHKey()
    @objc optional func openSSHFolder()
    /// Only the main app checks for updates.
    @objc optional func checkForUpdatesNow()
    @objc optional func toggleAutomaticUpdateChecks()
}

/// The menu bar, for the main app and for session processes. The app's name
/// in the items is the bundle's, so a session process says "Quit fileserver".
func installMainMenu(target: MenuTarget) {
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "iGateway.exe"
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About \(name)",
                    action: #selector(NSApplication.showAboutWithCredits(_:)), keyEquivalent: "")
    appMenu.addItem(withTitle: "Acknowledgements",
                    action: #selector(NSApplication.showAcknowledgements(_:)), keyEquivalent: "")
    if target.responds(to: #selector(MenuTarget.checkForUpdatesNow)) {
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(MenuTarget.checkForUpdatesNow),
                        keyEquivalent: "").target = target
        appMenu.addItem(withTitle: "Check for Updates Automatically",
                        action: #selector(MenuTarget.toggleAutomaticUpdateChecks), keyEquivalent: "").target = target
    }
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let others = appMenu.addItem(withTitle: "Hide Others",
                                 action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    others.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    if target.responds(to: #selector(MenuTarget.importHosts)) {
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Import Hosts...", action: #selector(MenuTarget.importHosts), keyEquivalent: "").target = target
        file.addItem(withTitle: "Export Hosts...", action: #selector(MenuTarget.exportHosts), keyEquivalent: "").target = target
        file.addItem(.separator())
        file.addItem(withTitle: "Create SSH Key...", action: #selector(MenuTarget.createSSHKey), keyEquivalent: "").target = target
        file.addItem(withTitle: "Open SSH Keys Folder", action: #selector(MenuTarget.openSSHFolder), keyEquivalent: "").target = target
        fileItem.submenu = file
        main.addItem(fileItem)
    }

    // Without an Edit menu, copy and paste do not work in text fields.
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    let full = windowMenu.addItem(withTitle: "Enter Full Screen",
                                  action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    full.keyEquivalentModifierMask = [.command, .control]
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Hosts", action: #selector(MenuTarget.showHosts), keyEquivalent: "0").target = target
    windowMenu.addItem(withTitle: "Show Logs", action: #selector(MenuTarget.showLogs), keyEquivalent: "").target = target
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = main
}

@main
enum Main {
    static func main() {
        // Run by ssh as its password helper: answer it and stop, no app.
        if ProcessInfo.processInfo.environment[Askpass.socketVariable] != nil { exit(Askpass.runHelper()) }
        // FreeRDP's log goes through the bridge: into freerdp.log, and read
        // along to tell which step of a failed connection went wrong.
        try? FileManager.default.createDirectory(at: Store.logDirectory, withIntermediateDirectories: true)
        rdp_log_init(Store.logDirectory.path)
        // A session process that dies before reading its pipe must not take
        // the main app down with it.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        let delegate: NSApplicationDelegate
        if let raw = Bundle.main.object(forInfoDictionaryKey: SessionBundle.hostKey) as? String,
           let hostID = UUID(uuidString: raw) {
            delegate = SessionAppDelegate(hostID: hostID)
        } else {
            delegate = AppDelegate()
        }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
