//
//  SessionWindow.swift
//
//  One window per session. A normal macOS window: the green button gives
//  native fullscreen with the menu bar and title bar on hover, and any size
//  change is passed to Windows, which redraws at the new size.
//

import AppKit
import IOSurface

final class SessionWindowController: NSWindowController, NSWindowDelegate, ConnectionDelegate {
    let host: Host
    private let gateway: Gateway
    private let server: Account
    private let gatewayAccount: Account?
    private var password: String
    private var gatewayPassword: String?
    private let settingsProvider: () -> AppSettings
    private let onDynamicResolutionFailed: (Host) -> Void
    private let onClose: (SessionWindowController) -> Void

    private(set) var connection: Connection?
    private let desktop = DesktopView(frame: .zero)
    private let overlay = NSVisualEffectView()
    private let overlayTitle = NSTextField(labelWithString: "")
    private let overlayDetail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let passwordButton = NSButton(title: "Enter password", target: nil, action: nil)
    private let logButton = NSButton(title: "Show Log", target: nil, action: nil)
    private var resizeWork: DispatchWorkItem?
    private var retriedWithoutDynamic = false
    private var closing = false

    var isActive: Bool { connection?.isActive ?? false }

    init(host: Host, gateway: Gateway, server: Account, gatewayAccount: Account?, password: String,
         gatewayPassword: String?, settings: @escaping () -> AppSettings,
         onDynamicResolutionFailed: @escaping (Host) -> Void,
         onClose: @escaping (SessionWindowController) -> Void) {
        self.host = host
        self.gateway = gateway
        self.server = server
        self.gatewayAccount = gatewayAccount
        self.password = password
        self.gatewayPassword = gatewayPassword
        self.settingsProvider = settings
        self.onDynamicResolutionFailed = onDynamicResolutionFailed
        self.onClose = onClose

        let s = settings()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: s.windowWidth, height: s.windowHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = host.display
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 400, height: 300)
        window.backgroundColor = .black
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
        window.setFrameAutosaveName("")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        desktop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(desktop)

        overlay.material = .hudWindow
        // The HUD material is always dark, so its text must be too, whatever
        // the system appearance. Otherwise light mode gives dark on dark.
        overlay.appearance = NSAppearance(named: .darkAqua)
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12
        overlay.translatesAutoresizingMaskIntoConstraints = false

        overlayTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        overlayDetail.font = .systemFont(ofSize: 12)
        overlayDetail.textColor = .secondaryLabelColor
        overlayDetail.preferredMaxLayoutWidth = 320
        spinner.style = .spinning
        spinner.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnect)
        reconnectButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        passwordButton.target = self
        passwordButton.action = #selector(enterPassword)
        logButton.target = self
        logButton.action = #selector(showLog)
        logButton.toolTip = "Shows app.log and freerdp.log in Finder"

        let buttons = NSStackView(views: [logButton, closeButton, passwordButton, reconnectButton])
        let header = NSStackView(views: [spinner, overlayTitle])
        let stack = NSStackView(views: [header, overlayDetail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        content.addSubview(overlay)

        NSLayoutConstraint.activate([
            desktop.topAnchor.constraint(equalTo: content.topAnchor),
            desktop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            desktop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            desktop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            overlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
        ])
        render(state: .connecting)
    }

    // MARK: Connecting

    func start() {
        showWindow(nil)
        window?.makeFirstResponder(desktop)
        if settingsProvider().openFullscreen, let window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            // Connecting happens once the window has its fullscreen size.
            return
        }
        connect()
    }

    private var scale: UInt32 {
        settingsProvider().sharpOnRetina ? UInt32(min(500, max(100, (window?.backingScaleFactor ?? 1) * 100))) : 100
    }

    /// The size to ask Windows for: the window's content in points, or in
    /// pixels when "sharp on Retina" is on (then Windows scales its UI up to
    /// match, so things stay the same size but sharper).
    private var desiredPixelSize: CGSize {
        let points = desktop.bounds.size.width > 0 ? desktop.bounds.size
            : (window?.contentLayoutRect.size ?? CGSize(width: 1440, height: 900))
        let factor = settingsProvider().sharpOnRetina ? (window?.backingScaleFactor ?? 1) : 1
        return CGSize(width: (points.width * factor).rounded(.down), height: (points.height * factor).rounded(.down))
    }

    private func connect() {
        connection?.delegate = nil
        connection?.disconnect()

        let settings = settingsProvider()
        let dynamic = settings.dynamicResolution && !settings.hostsWithoutDynamicResolution.contains(host.id)
        let connection = Connection(host: host, gateway: gateway, server: server, gatewayAccount: gatewayAccount,
                                    settings: settings, useDynamicResolution: dynamic)
        connection.delegate = self
        desktop.connection = connection
        desktop.keyboardMode = settings.keyboardMode
        self.connection = connection
        connection.clipboard.attach()
        connection.connect(pixelSize: desiredPixelSize, scale: scale,
                           password: password, gatewayPassword: gatewayPassword)
    }

    @objc private func reconnect() { connect() }

    @objc private func closeWindow() { window?.performClose(nil) }

    @objc private func showLog() { AppLog.reveal() }

    /// For a rejected login: asks again, saves the new password and reconnects.
    @objc private func enterPassword() {
        guard let window else { return }
        PasswordSheet.present(on: window, title: "Password for \(server.display)") { [weak self] entered, save in
            guard let self, let entered else { return }
            self.password = entered
            if self.gatewayAccount == nil { self.gatewayPassword = nil }
            let key = self.server.keychainKey
            Task {
                if save { _ = await Keychain.setPasswordAsync(entered, for: key) }
                await MainActor.run { self.connect() }
            }
        }
    }

    private func showOverlay(title: String, detail: String, busy: Bool, actions: Bool, askPassword: Bool = false) {
        passwordButton.isHidden = !askPassword
        overlay.isHidden = false
        overlayTitle.stringValue = title
        overlayDetail.stringValue = detail
        overlayDetail.isHidden = detail.isEmpty
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        reconnectButton.isHidden = !actions
        closeButton.isHidden = !actions
        logButton.isHidden = !actions
    }

    // MARK: ConnectionDelegate

    func connection(_ connection: Connection, didChange state: Connection.State) {
        guard connection === self.connection else { return }
        render(state: state, from: connection)
    }

    /// Updates the window for a state. Also used to preview the states.
    func render(state: Connection.State, from connection: Connection? = nil) {
        switch state {
        case .idle:
            break
        case .connecting:
            showOverlay(title: "Connecting to \(host.title)",
                        detail: gateway.isDirect ? "Direct connection" : "via \(gateway.host)",
                        busy: true, actions: false)
        case .connected:
            overlay.isHidden = true
            spinner.stopAnimation(nil)
            window?.makeFirstResponder(desktop)
            desktop.syncLocks()
            scheduleResize()
        case .disconnected:
            guard !closing else { return }
            desktop.releaseAll()
            let reason = connection?.endReason.map { "The session ended: \($0)." } ?? "The session ended."
            showOverlay(title: "Disconnected", detail: reason, busy: false, actions: true)
        case .failed(let code):
            desktop.releaseAll()
            // A host that accepted the login but never started the session,
            // with dynamic resolution on: try once more without it and
            // remember that for this host.
            if code == "ERRCONNECT_ACTIVATION_TIMEOUT", connection?.useDynamicResolution == true,
               !retriedWithoutDynamic {
                retriedWithoutDynamic = true
                AppLog.write("\(host.display): retrying without dynamic resolution, remembered for this host")
                onDynamicResolutionFailed(host)
                showOverlay(title: "Reconnecting", detail: "This host did not accept resizing. Retrying without it.",
                            busy: true, actions: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.connect() }
                return
            }
            let login = ["ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_WRONG_PASSWORD",
                         "ERRCONNECT_AUTHENTICATION_FAILED", "ERRCONNECT_NO_OR_MISSING_CREDENTIALS"].contains(code)
            showOverlay(title: "Could not connect", detail: ConnectError.explain(code), busy: false,
                        actions: true, askPassword: login)
        }
    }

    func connection(_ connection: Connection, didDisplay surface: IOSurface, size: CGSize) {
        guard connection === self.connection else { return }
        desktop.display(surface: surface, size: size)
    }

    func connection(_ connection: Connection, didSetCursor cursor: RemoteCursor) {
        guard connection === self.connection else { return }
        desktop.setRemoteCursor(cursor)
    }

    func connection(_ connection: Connection, verify certificate: CertificateInfo,
                    decide: @escaping (CertificateInfo.Decision) -> Void) {
        guard connection === self.connection, let window, !closing else { decide(.refuse); return }
        CertificatePrompt.present(certificate, on: window, done: decide)
    }

    // MARK: Resizing

    private func scheduleResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let connection = self.connection, connection.state == .connected else { return }
            connection.requestSize(pixels: self.desiredPixelSize, scale: self.scale)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func windowDidResize(_ notification: Notification) {
        scheduleResize()
        if let window, !window.styleMask.contains(.fullScreen) {
            let size = window.contentLayoutRect.size
            UserDefaults.standard.set([size.width, size.height], forKey: "lastSessionSize")
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) { scheduleResize() }
    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleResize() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if connection == nil { connect() } else { scheduleResize() }
    }

    func windowDidExitFullScreen(_ notification: Notification) { scheduleResize() }

    func windowDidResignKey(_ notification: Notification) { desktop.releaseAll() }

    func windowDidBecomeKey(_ notification: Notification) {
        PasteboardWatcher.shared.check()
        window?.makeFirstResponder(desktop)
        desktop.syncLocks()
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        desktop.releaseAll()
        connection?.delegate = nil
        connection?.disconnect()
        desktop.connection = nil
        connection = nil
        onClose(self)
    }

    func disconnectForQuit() {
        closing = true
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
    }
}
