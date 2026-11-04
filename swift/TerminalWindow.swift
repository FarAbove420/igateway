//
//  TerminalWindow.swift
//
//  An SSH session: the Mac's own ssh in a SwiftTerm terminal view, in the
//  host's own session app like an RDP session.
//
//  What the server may make the Mac do is kept to the minimum. Not SwiftTerm's
//  LocalProcessTerminalView, because that one lets the server read and write
//  the clipboard. Here the server can't touch the clipboard, can't set the
//  window title, and gets no answer to title or window queries (SwiftTerm's
//  default). Links open only after showing the address, and only http and
//  https.
//

import AppKit
import SwiftTerm

final class SSHTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    private var process: LocalProcess!
    var onExit: ((Int32?) -> Void)?
    var isRunning: Bool { process.running }
    /// ssh's process id, 0 before it starts.
    var processID: pid_t { process.shellPid }

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        process = LocalProcess(delegate: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func start(arguments: [String], environment: [String]) {
        process.startProcess(executable: SSHCommand.executable, args: arguments,
                             environment: environment, execName: "ssh")
    }

    func terminate() { process.terminate() }

    /// Several lines pasted into a program that doesn't mark pastes run as
    /// separate commands, the first one right away: ask first.
    override func paste(_ sender: Any) {
        guard let window, let text = NSPasteboard.general.string(forType: .string),
              Self.pasteNeedsConfirmation(text, bracketed: terminal.bracketedPasteMode) else {
            super.paste(sender)
            return
        }
        let lines = text.split(whereSeparator: \.isNewline).count
        let alert = NSAlert()
        alert.messageText = lines > 1 ? "Paste \(lines) lines?" : "Paste a line that ends in Return?"
        alert.informativeText = "The server runs each line as soon as it arrives."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { super.paste(sender) }
        }
    }

    static func pasteNeedsConfirmation(_ text: String, bracketed: Bool) -> Bool {
        !bracketed && text.contains(where: \.isNewline)
    }

    /// Only web links, so a link on a server can't open a file or an app.
    static func openableLink(_ link: String) -> URL? {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard process.running else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { process.send(data: data) }

    /// The window keeps the host's name: a server could otherwise make it say
    /// anything.
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) { NSSound.beep() }

    /// OSC 52 from the server: never on the clipboard, never read from it.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    /// iTerm2's OSC 1337 (file transfers and the like): ignored.
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = Self.openableLink(link), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: LocalProcessDelegate

    /// SwiftTerm 1.20 hands over waitpid's raw status, not the exit code (the
    /// session test checks this). nil: ended by a signal, or unknown.
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let code = exitCode.flatMap { $0 & 0x7f == 0 ? ($0 >> 8) & 0xff : nil }
        DispatchQueue.main.async { self.onExit?(code) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) { feed(byteArray: slice) }

    func getWindowSize() -> winsize {
        let scale = window?.backingScaleFactor ?? 2
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
                       ws_xpixel: UInt16(min(bounds.width * scale, 65535)),
                       ws_ypixel: UInt16(min(bounds.height * scale, 65535)))
    }
}

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let host: Host
    private let terminalView: SSHTerminalView
    private var historyID: UUID?
    private var closing = false
    private var askpass: AskpassServer?
    /// How often ssh asked for each login's password this session: a second
    /// time means the one given was refused.
    private var asked: [String: Int] = [:]
    /// The Keychain; memory in the tests.
    var passwords = SSHPasswords.keychain
    /// Shows a question from ssh and calls back with the answer and whether
    /// to save it. Sheets; canned answers in the tests.
    lazy var ask: (Askpass.Prompt, _ retry: Bool, @escaping (String?, Bool) -> Void) -> Void = {
        [unowned self] prompt, retry, done in self.showSheet(prompt, retry: retry, done: done)
    }

    var isActive: Bool { terminalView.isRunning }

    /// What the appearance was last set from, to skip setting it again.
    private var appearance: (TerminalFont, Double, String)?

    init(host: Host) {
        self.host = host
        let frame = NSRect(x: 0, y: 0, width: 820, height: 520)
        terminalView = SSHTerminalView(frame: frame)
        terminalView.nativeBackgroundColor = .black
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = host.title
        window.contentView = terminalView
        window.backgroundColor = .black
        window.center()
        // Saved in the session app's own defaults, so per host.
        window.setFrameAutosaveName("Terminal")
        super.init(window: window)
        window.delegate = self
        terminalView.onExit = { [weak self] code in self?.ended(exitCode: code) }
        applyAppearance()
    }

    static let defaultTextColor = NSColor(white: 0.9, alpha: 1)

    static func font(_ choice: TerminalFont, size: Double) -> NSFont {
        let size = CGFloat(min(max(size, 9), 24))
        return choice.postScriptName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// From the saved settings, so a change in the host list shows up when
    /// the window comes to the front.
    private func applyAppearance() {
        let s = Store.read() ?? AppSettings()
        guard appearance.map({ $0 != (s.terminalFont, s.terminalFontSize, s.terminalTextColor) }) ?? true else { return }
        appearance = (s.terminalFont, s.terminalFontSize, s.terminalTextColor)
        terminalView.font = Self.font(s.terminalFont, size: s.terminalFontSize)
        let text = NSColor(hex: s.terminalTextColor)?.visibleOnBlack ?? Self.defaultTextColor
        terminalView.nativeForegroundColor = text
        // A solid block in the text colour with the letter under it in black.
        // SwiftTerm's default, a pale block with the letter in the text
        // colour, looks like an empty space on black.
        terminalView.caretColor = text
        terminalView.caretTextColor = .black
    }

    func windowDidBecomeKey(_ notification: Notification) { applyAppearance() }

    required init?(coder: NSCoder) { fatalError("not used") }

    func start() {
        let arguments: [String]
        do {
            arguments = try SSHCommand.arguments(for: host)
        } catch {
            AppLog.write("\(host.display): not a valid SSH host, not connecting")
            note("This host's address, user, port or key file is not valid. Edit it in the host list.")
            return
        }
        let user = host.sshUser.isEmpty ? "ssh" : host.sshUser
        historyID = History.begin(host: host, account: user)
        if let id = historyID {
            History.update(id) { $0.state = .connected; $0.connected = Date() }
        }
        // The arguments hold no secrets.
        AppLog.write("Connecting to \(host.display) over SSH: ssh " + arguments.joined(separator: " "))
        var environment = SSHCommand.environment()
        let view = terminalView
        askpass = AskpassServer(isFromSSH: { Askpass.descends($0, from: view.processID) },
                                handle: { [weak self] prompt, reply in
                                    guard let self else { return reply(nil) }
                                    self.answer(prompt, reply: reply)
                                })
        if let askpass {
            environment += ["SSH_ASKPASS=\(Askpass.helperPath)", "SSH_ASKPASS_REQUIRE=force",
                            "\(Askpass.socketVariable)=\(askpass.socketPath)", "\(Askpass.tokenVariable)=\(askpass.token)"]
        } else {
            AppLog.write("\(host.display): could not set up saved passwords, ssh asks in the terminal")
        }
        terminalView.start(arguments: arguments, environment: environment)
        window?.makeFirstResponder(terminalView)
    }

    /// The host's login and its jump host's, the only ones a saved password
    /// goes to.
    private var logins: [SSHCommand.Login] {
        [SSHCommand.login(for: host)] + [(try? SSHCommand.jump(host.jumpHost)) ?? nil].compactMap { $0 }
    }

    private func answer(_ prompt: String, reply: @escaping (String?) -> Void) {
        let kind = Askpass.classify(prompt, logins: logins)
        let key: String
        let what: String
        switch kind {
        case .password(let login):
            key = login.keychainKey
            what = "the password of \(login.effectiveUser)@\(login.address)"
        case .passphrase(let path):
            key = SSHKeys.keychainKey(path)
            what = "the passphrase of the key \((path as NSString).lastPathComponent)"
        case .hostKey, .other:
            // Prompts hold no secrets, answers do: only the prompt is logged.
            AppLog.write("\(host.display): ssh asks: \(prompt.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            ask(kind, false) { text, _ in reply(text) }
            return
        }
        let attempt = (asked[key] ?? 0) + 1
        asked[key] = attempt
        AppLog.write("\(host.display): ssh asks for \(what)" + (attempt > 1 ? ", attempt \(attempt)" : ""))
        Task { @MainActor in
            if attempt == 1, let saved = await self.passwords.get(key) {
                AppLog.write("\(self.host.display): sent the saved one")
                reply(saved)
                return
            }
            // Asked again: the last one was refused, so it goes.
            if attempt > 1 { await self.passwords.delete(key) }
            self.ask(kind, attempt > 1) { text, save in
                if let text, save { Task { await self.passwords.set(text, key) } }
                reply(text)
            }
        }
    }

    private func showSheet(_ prompt: Askpass.Prompt, retry: Bool, done: @escaping (String?, Bool) -> Void) {
        guard let window else { return done(nil, false) }
        let alert = NSAlert()
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        field.font = .systemFont(ofSize: 15)
        let save = NSButton(checkboxWithTitle: "Save in the Keychain", target: nil, action: nil)
        save.state = .on
        switch prompt {
        case .password(let login):
            let who = "\(login.effectiveUser)@\(login.address)"
            alert.messageText = retry ? "That password didn't work" : "Password for \(who)"
            alert.informativeText = retry ? "Try again for \(who)." : "ssh asks for it to log in."
            let stack = NSStackView(views: [field, save])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 62)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Log In")
        case .passphrase(let path):
            let name = (path as NSString).lastPathComponent
            alert.messageText = retry ? "That passphrase didn't work" : "Passphrase for the key \(name)"
            alert.informativeText = retry ? "Try again for \(name)." : "ssh needs it to use the key."
            let stack = NSStackView(views: [field, save])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 62)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Use Key")
        case .hostKey(let text):
            alert.messageText = "First connection to this server"
            alert.informativeText = text + "\n\nCompare the fingerprint with the one the server's admin has."
            alert.addButton(withTitle: "Connect")
        case .other(let text):
            alert.messageText = "ssh asks"
            alert.informativeText = text
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
        }
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let ok = response == .alertFirstButtonReturn
            if case .hostKey = prompt { return done(ok ? "yes" : "no", false) }
            done(ok ? field.stringValue : nil, save.state == .on)
        }
    }

    /// ssh exits with the remote command's status, or 255 when it couldn't
    /// connect or log in (ssh(1), EXIT STATUS).
    private func ended(exitCode: Int32?) {
        askpass?.stop()
        askpass = nil
        let failed = exitCode == 255 && !closing
        AppLog.write("\(host.display): ssh ended, exit \(exitCode.map(String.init) ?? "by signal")")
        if let id = historyID {
            History.update(id) { entry in
                entry.ended = Date()
                entry.state = failed ? .failed : .ended
                entry.detail = failed ? "ssh could not connect or log in." : (self.closing ? "closed" : nil)
            }
            historyID = nil
        }
        if failed {
            note("ssh stopped. Its message is above. Close the window when you're done reading.")
        } else if !closing {
            window?.close()
        }
    }

    /// A dimmed line from iGateway itself, after whatever ssh printed.
    private func note(_ text: String) {
        terminalView.feed(text: "\r\n\u{1b}[2m[\(text)]\u{1b}[0m\r\n")
    }

    func disconnectForQuit() {
        closing = true
        terminalView.terminate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isActive else { return true }
        let alert = NSAlert()
        alert.messageText = "Close the session to \(host.title)?"
        alert.informativeText = "Whatever is running in it stops."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.disconnectForQuit()
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if isActive { disconnectForQuit() }
    }
}

/// Where SSH passwords are kept: the Keychain, or memory in the tests.
struct SSHPasswords {
    var get: (String) async -> String?
    var set: (_ password: String, _ key: String) async -> Void
    var delete: (String) async -> Void

    static let keychain = SSHPasswords(
        get: { await Keychain.passwordAsync(for: $0) },
        set: { _ = await Keychain.setPasswordAsync($0, for: $1, description: "SSH password") },
        delete: { key in await Task.detached { Keychain.deletePassword(for: key) }.value })
}
