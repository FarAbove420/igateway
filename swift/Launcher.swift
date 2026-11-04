//
//  Launcher.swift
//
//  The sidebar lists gateways, each folding open to its hosts. A gateway has
//  its own accounts. Single click selects, double click connects. Kept
//  compact: explanations live in tooltips.
//

import AppKit

/// A gateway or a host in the sidebar. NSOutlineView keeps rows expanded by
/// object identity, so these are cached by id and survive reloads.
private final class SidebarItem: NSObject {
    let id: UUID
    let isGateway: Bool
    init(id: UUID, isGateway: Bool) {
        self.id = id
        self.isGateway = isGateway
    }
}

final class LauncherWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                      NSMenuDelegate {
    let app: AppController
    private let outline = NSOutlineView()
    private var items: [UUID: SidebarItem] = [:]
    /// Set while the sidebar is rebuilt, so the expand and select callbacks
    /// that fire during it are not taken for clicks.
    private var reloading = false
    private var grid: NSGridView!
    private let serverPopup = NSPopUpButton()
    private let gatewayToggle = NSButton(checkboxWithTitle: "Gateway uses a different account", target: nil, action: nil)
    private let gatewayPopup = NSPopUpButton()
    private let keyboardPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let displayPopup = NSPopUpButton()
    private let sharpToggle = NSButton(checkboxWithTitle: "Sharp on Retina", target: nil, action: nil)
    private let soundToggle = NSButton(checkboxWithTitle: "Sound", target: nil, action: nil)
    private let shareToggle = NSButton(checkboxWithTitle: "Share a folder", target: nil, action: nil)
    private let shareButton = NSButton(title: "", target: nil, action: nil)
    private let resizeToggle = NSButton(checkboxWithTitle: "Resize Windows with the window", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    // An SSH host shows these instead of the Remote Desktop options.
    private var sshGrid: NSGridView!
    private let sshUserValue = NSTextField(labelWithString: "")
    private let sshPortValue = NSTextField(labelWithString: "")
    private let sshAuthValue = NSTextField(wrappingLabelWithString: "")
    private let sshJumpValue = NSTextField(labelWithString: "")
    private let copyKeyButton = NSButton(title: "Show Public Key", target: nil, action: nil)
    // For all SSH sessions.
    private let fontPopup = NSPopUpButton()
    private let fontSizePopup = NSPopUpButton()
    private let textColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    private static let fontSizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 24]
    private let history = HistoryPanel(frame: .zero)
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerDetail = NSTextField(labelWithString: "")

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "iGateway.exe"
        window.contentMinSize = NSSize(width: 700, height: 420)
        window.isRestorable = false
        super.init(window: window)
        build()
        reload()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var settings: AppSettings { app.settings }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }

        // Left: gateways, each folding open to its hosts
        let column = NSTableColumn(identifier: .init("item"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(sidebarDoubleClicked)
        outline.allowsEmptySelection = false
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let add = smallButton("plus", #selector(addClicked(_:)), "Add a host or a gateway")
        let remove = smallButton("minus", #selector(removeSelected), "Remove the selected host or gateway")
        let edit = smallButton("pencil", #selector(editSelected), "Edit the selected host or gateway")
        let hint = NSTextField(labelWithString: "Double-click to connect")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [add, remove, edit, NSView(), hint])
        buttons.spacing = 2

        let left = NSStackView(views: [scroll, buttons])
        left.orientation = .vertical
        left.spacing = 4
        left.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        // Right: details
        headerTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        headerTitle.lineBreakMode = .byTruncatingTail
        headerDetail.textColor = .secondaryLabelColor
        headerDetail.lineBreakMode = .byTruncatingTail
        for field in [headerTitle, headerDetail] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for popup in [serverPopup, gatewayPopup, keyboardPopup, modePopup, displayPopup] {
            popup.target = self
            popup.action = #selector(optionChanged)
        }
        for toggle in [gatewayToggle, sharpToggle, soundToggle, shareToggle, resizeToggle] {
            toggle.target = self
            toggle.action = #selector(optionChanged)
        }
        KeyboardLayout.allCases.forEach { keyboardPopup.addItem(withTitle: $0.label) }
        KeyboardMode.allCases.forEach { modePopup.addItem(withTitle: $0.label) }
        displayPopup.addItems(withTitles: ["Window", "Fullscreen"])

        let manage = NSButton(title: "Manage...", target: self, action: #selector(manageAccounts))
        shareButton.target = self
        shareButton.action = #selector(chooseFolder)
        shareButton.bezelStyle = .rounded
        shareButton.controlSize = .small
        shareButton.toolTip = "Choose the folder to share"

        keyboardPopup.toolTip = "The layout Windows uses for shortcuts and raw keys. Typed text always comes out as the Mac types it."
        modePopup.toolTip = "\"Type what the Mac types\" sends your characters, so AZERTY symbols and accents come out right. \"Send raw keys\" sends key positions, for apps that need them."
        serverPopup.toolTip = "The account for the hosts behind this gateway."
        gatewayToggle.toolTip = "The RD Gateway can require a different account than the hosts behind it."
        displayPopup.toolTip = "Fullscreen is the normal macOS fullscreen: move the pointer to the top for the menu bar and window buttons."
        sharpToggle.toolTip = "Asks Windows for the full Retina resolution with 200% scaling: same size, sharper text."
        shareToggle.toolTip = "This folder shows up in Windows under This PC."
        resizeToggle.toolTip = "Resizing the window, or going fullscreen, changes the Windows resolution to fit. If a host refuses, the app turns this off for that host by itself."

        grid = NSGridView(views: [
            [label("Account"), row(serverPopup, manage)],
            [NSGridCell.emptyContentView, gatewayToggle],
            [label("Gateway"), gatewayPopup],
            [label("Keyboard"), keyboardPopup],
            [label("Typing"), modePopup],
            [label("Display"), displayPopup],
            [NSGridCell.emptyContentView, row(resizeToggle, sharpToggle)],
            [NSGridCell.emptyContentView, row(soundToggle, shareToggle, shareButton)],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // Otherwise a wide window stretches the grid and the label column
        // takes all the extra width, pushing the controls to the far right.
        grid.setContentHuggingPriority(.init(700), for: .horizontal)

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.controlSize = .large
        connectButton.target = self
        connectButton.action = #selector(connectSelected)

        sshAuthValue.preferredMaxLayoutWidth = 380
        TerminalFont.allCases.forEach { fontPopup.addItem(withTitle: $0.label) }
        fontPopup.toolTip = "The font of all SSH sessions"
        fontSizePopup.addItems(withTitles: Self.fontSizes.map { "\(Int($0)) pt" })
        if #available(macOS 13.0, *) { textColorWell.colorWellStyle = .minimal }
        textColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        textColorWell.toolTip = "The text colour of all SSH sessions. Very dark colours are lightened, so text stays readable on black."
        for control in [fontPopup, fontSizePopup, textColorWell] as [NSControl] {
            control.target = self
            control.action = #selector(terminalAppearanceChanged)
        }
        copyKeyButton.target = self
        copyKeyButton.action = #selector(showPublicKey)
        copyKeyButton.bezelStyle = .rounded
        copyKeyButton.controlSize = .small
        let resetColor = NSButton(title: "Default", target: self, action: #selector(resetTerminalTextColor))
        resetColor.controlSize = .small
        resetColor.bezelStyle = .rounded
        sshGrid = NSGridView(views: [
            [label("User"), sshUserValue],
            [label("Port"), sshPortValue],
            [label("Jump host"), sshJumpValue],
            [label("Sign in"), sshAuthValue],
            [NSGridCell.emptyContentView, copyKeyButton],
            [label("Font"), row(fontPopup, fontSizePopup)],
            [label("Text colour"), row(textColorWell, resetColor)],
        ])
        sshGrid.rowSpacing = 8
        sshGrid.columnSpacing = 10
        sshGrid.column(at: 0).xPlacement = .trailing
        sshGrid.rowAlignment = .firstBaseline
        sshGrid.isHidden = true

        let details = NSStackView(views: [headerTitle, headerDetail, grid, sshGrid, connectButton])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 10
        details.setCustomSpacing(18, after: headerDetail)
        details.setCustomSpacing(22, after: grid)
        details.setCustomSpacing(22, after: sshGrid)

        // Recent connections fill the rest of the pane.
        history.isLive = { [weak self] id in self?.app.isSessionOpen(hostID: id) ?? false }
        history.canConnect = { [weak self] id in self?.settings.hosts.contains { $0.id == id } ?? false }
        history.onShow = { [weak self] id in self?.app.showSession(hostID: id) }
        history.onConnect = { [weak self] id in self?.connect(hostID: id) }
        history.refresh(force: true)

        let right = NSView()
        for view in [details, history] {
            view.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(view)
        }
        NSLayoutConstraint.activate([
            details.topAnchor.constraint(equalTo: right.topAnchor, constant: 20),
            details.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            details.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor, constant: -20),
            history.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 28),
            history.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            history.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -20),
            history.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -16),
            history.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        // The divider can be dragged; the sidebar keeps its width when the
        // window is resized, and the width is remembered.
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            serverPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            gatewayPopup.widthAnchor.constraint(equalTo: serverPopup.widthAnchor),
            keyboardPopup.widthAnchor.constraint(equalTo: serverPopup.widthAnchor),
            modePopup.widthAnchor.constraint(equalTo: serverPopup.widthAnchor),
            displayPopup.widthAnchor.constraint(equalTo: serverPopup.widthAnchor),
        ])
        let autosave = "LauncherSidebar"
        let remembered = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosave)") != nil
        split.autosaveName = autosave
        if !remembered {
            content.layoutSubtreeIfNeeded()
            split.setPosition(250, ofDividerAt: 0)
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 12
        return stack
    }

    private func smallButton(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                              target: self, action: action)
        button.bezelStyle = .smallSquare
        button.isBordered = true
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    // MARK: State

    private var selectedItem: SidebarItem? { outline.item(atRow: outline.selectedRow) as? SidebarItem }

    private var selectedHost: Host? {
        guard let item = selectedItem, !item.isGateway else { return nil }
        return settings.hosts.first { $0.id == item.id }
    }

    /// The selected gateway, or the gateway of the selected host.
    private var currentGateway: Gateway? {
        if let item = selectedItem {
            if item.isGateway { return settings.gateways.first { $0.id == item.id } }
            if let host = selectedHost { return settings.gateway(for: host) }
        }
        return settings.gateways.first { $0.id == settings.lastGatewayID } ?? settings.gateways.first
    }

    func reload() {
        let s = settings
        let live = Set(s.gateways.map(\.id) + s.hosts.map(\.id))
        items = items.filter { live.contains($0.key) }

        reloading = true
        outline.reloadData()
        for gateway in s.gateways {
            let item = sidebarItem(gateway.id, isGateway: true)
            if s.collapsedGateways.contains(gateway.id) {
                outline.collapseItem(item)
            } else {
                outline.expandItem(item)
            }
        }
        var row = -1
        if let id = s.lastHostID, let item = items[id] { row = outline.row(forItem: item) }
        if row < 0, let id = s.lastGatewayID, let item = items[id] { row = outline.row(forItem: item) }
        if outline.numberOfRows > 0 {
            outline.selectRowIndexes([max(0, row)], byExtendingSelection: false)
            outline.scrollRowToVisible(max(0, row))
        }
        reloading = false
        showSelection()
    }

    /// Fills the right side for whatever is selected.
    private func showSelection() {
        let s = settings
        let gateway = currentGateway

        for popup in [serverPopup, gatewayPopup] {
            popup.removeAllItems()
            s.accounts.forEach { popup.menu?.addItem(withTitle: $0.display, action: nil, keyEquivalent: "") }
            if s.accounts.isEmpty { popup.addItem(withTitle: "No accounts yet") }
        }
        if let i = s.accounts.firstIndex(where: { $0.id == gateway?.serverAccountID }) { serverPopup.selectItem(at: i) }
        if let i = s.accounts.firstIndex(where: { $0.id == gateway?.gatewayAccountID }) { gatewayPopup.selectItem(at: i) }

        let direct = gateway?.isDirect ?? true
        grid.row(at: 1).isHidden = direct
        grid.row(at: 2).isHidden = direct
        gatewayToggle.state = gateway?.separateAccount == true ? .on : .off
        gatewayPopup.isEnabled = gateway?.separateAccount == true
        keyboardPopup.selectItem(at: KeyboardLayout.allCases.firstIndex(of: s.keyboardLayout) ?? 0)
        modePopup.selectItem(at: KeyboardMode.allCases.firstIndex(of: s.keyboardMode) ?? 0)
        displayPopup.selectItem(at: s.openFullscreen ? 1 : 0)
        sharpToggle.state = s.sharpOnRetina ? .on : .off
        soundToggle.state = s.sound ? .on : .off
        shareToggle.state = s.shareFolder ? .on : .off
        resizeToggle.state = s.dynamicResolution ? .on : .off
        shareButton.title = s.sharedFolderPath == NSHomeDirectory()
            ? "Home folder" : (s.sharedFolderPath as NSString).lastPathComponent
        shareButton.isEnabled = s.shareFolder

        fontPopup.selectItem(at: TerminalFont.allCases.firstIndex(of: s.terminalFont) ?? 0)
        fontSizePopup.selectItem(at: Self.fontSizes.firstIndex(of: s.terminalFontSize) ?? 3)
        textColorWell.color = NSColor(hex: s.terminalTextColor)?.visibleOnBlack ?? TerminalWindowController.defaultTextColor

        let ssh = selectedHost?.isSSH == true
        // A jump group has no options of its own, only the terminal's.
        let jumpGroup = selectedHost == nil && currentGateway?.isJump == true
        grid.isHidden = ssh || jumpGroup
        sshGrid.isHidden = !(ssh || jumpGroup)
        for i in 0..<4 { sshGrid.row(at: i).isHidden = jumpGroup }
        let keyFile = selectedHost.map { $0.isSSH && $0.sshAuth == .key ? $0.identityFile : "" } ?? ""
        sshGrid.row(at: 4).isHidden = jumpGroup || keyFile.isEmpty || SSHKeys.publicKey(keyFile) == nil
        if let host = selectedHost, ssh {
            sshUserValue.stringValue = host.sshUser.isEmpty ? "\(NSUserName()), your Mac user name" : host.sshUser
            sshPortValue.stringValue = host.port.map(String.init) ?? "22"
            sshJumpValue.stringValue = host.jumpHost.isEmpty ? "None" : host.jumpHost
            sshAuthValue.stringValue = host.sshAuth == .password
                ? "Password: asked in a window, and saved in the Keychain if you tick the box."
                : "Key or certificate"
                    + (host.identityFile.isEmpty ? ", any of yours." : ": \((host.identityFile as NSString).lastPathComponent).")
                    + " ssh never asks for a password."
        }
        updateHeader()
    }

    private func updateHeader() {
        if let host = selectedHost, let gateway = settings.gateway(for: host) {
            headerTitle.stringValue = host.title
            var detail = host.isSSH ? "\(host.address), SSH" + (host.jumpHost.isEmpty ? "" : " through \(host.jumpHost)")
                : gateway.isDirect ? "\(host.address), direct" : "\(host.address) through \(gateway.host)"
            if settings.hostsWithoutDynamicResolution.contains(host.id) {
                detail += "  ·  resizing off for this host"
            }
            headerDetail.stringValue = detail
        } else if let gateway = currentGateway {
            let count = settings.hosts.filter { $0.gatewayID == gateway.id }.count
            headerTitle.stringValue = gateway.title
            var parts = gateway.isDirect ? ["No gateway"]
                : gateway.isJump ? ["SSH jump host"] : [gateway.host, gateway.transport.label]
            parts.append(count == 0 ? "no hosts yet, add one with +" : count == 1 ? "1 host" : "\(count) hosts")
            headerDetail.stringValue = parts.joined(separator: "  ·  ")
        }
        connectButton.isEnabled = selectedHost != nil
    }

    @objc private func terminalAppearanceChanged() {
        // Black or nearly black would vanish on the terminal's background.
        let visible = textColorWell.color.visibleOnBlack
        if visible.hexString != textColorWell.color.hexString { textColorWell.color = visible }
        app.update { s in
            s.terminalFont = TerminalFont.allCases[max(0, fontPopup.indexOfSelectedItem)]
            s.terminalFontSize = Self.fontSizes[max(0, fontSizePopup.indexOfSelectedItem)]
            s.terminalTextColor = visible.hexString
        }
    }

    /// From the File menu: a key on its own, not for one host.
    func createSSHKey() {
        guard let window else { return }
        KeySheet.present(on: window, suggestedName: "id_ed25519") { [weak self] _ in self?.showSelection() }
    }

    @objc private func showPublicKey() {
        guard let host = selectedHost, !host.identityFile.isEmpty, let window else { return }
        PublicKeySheet.present(on: window, path: host.identityFile)
    }

    @objc private func resetTerminalTextColor() {
        app.update { $0.terminalTextColor = "" }
        textColorWell.color = TerminalWindowController.defaultTextColor
    }

    @objc private func optionChanged() {
        let gatewayID = currentGateway?.id
        app.update { s in
            if let g = s.gateways.firstIndex(where: { $0.id == gatewayID }) {
                if s.accounts.indices.contains(serverPopup.indexOfSelectedItem) {
                    s.gateways[g].serverAccountID = s.accounts[serverPopup.indexOfSelectedItem].id
                }
                if s.accounts.indices.contains(gatewayPopup.indexOfSelectedItem) {
                    s.gateways[g].gatewayAccountID = s.accounts[gatewayPopup.indexOfSelectedItem].id
                }
                s.gateways[g].separateAccount = gatewayToggle.state == .on && !s.gateways[g].isDirect
            }
            s.keyboardLayout = KeyboardLayout.allCases[max(0, keyboardPopup.indexOfSelectedItem)]
            s.keyboardMode = KeyboardMode.allCases[max(0, modePopup.indexOfSelectedItem)]
            s.openFullscreen = displayPopup.indexOfSelectedItem == 1
            s.sharpOnRetina = sharpToggle.state == .on
            s.sound = soundToggle.state == .on
            s.shareFolder = shareToggle.state == .on
            let dynamic = resizeToggle.state == .on
            if dynamic && !s.dynamicResolution { s.hostsWithoutDynamicResolution = [] }
            s.dynamicResolution = dynamic
        }
        gatewayPopup.isEnabled = currentGateway?.separateAccount == true
        shareButton.isEnabled = settings.shareFolder
        updateHeader()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.sharedFolderPath)
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if url.path.contains(",") {
                self.alert("That folder can't be shared", "FreeRDP uses commas to separate drive options, so a path with a comma in it won't work.")
                return
            }
            self.app.update { $0.sharedFolderPath = url.path }
            self.showSelection()
        }
    }

    // MARK: Sidebar

    private func sidebarItem(_ id: UUID, isGateway: Bool) -> SidebarItem {
        if let existing = items[id] { return existing }
        let item = SidebarItem(id: id, isGateway: isGateway)
        items[id] = item
        return item
    }

    private func children(of item: Any?) -> [SidebarItem] {
        guard let item = item as? SidebarItem else {
            return settings.gateways.map { sidebarItem($0.id, isGateway: true) }
        }
        guard item.isGateway else { return [] }
        return settings.hosts.filter { $0.gatewayID == item.id }.map { sidebarItem($0.id, isGateway: false) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.isGateway ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarItem)?.isGateway == true ? 28 : 36
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let views: [NSView]
        let cell = NSTableCellView()
        if item.isGateway, let gateway = settings.gateways.first(where: { $0.id == item.id }) {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: gateway.isDirect ? "network"
                                    : gateway.isJump ? "arrow.triangle.branch" : "lock.shield",
                                 accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            let title = NSTextField(labelWithString: gateway.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let count = NSTextField(labelWithString: "\(settings.hosts.filter { $0.gatewayID == gateway.id }.count)")
            count.font = .systemFont(ofSize: 11)
            count.textColor = .tertiaryLabelColor
            count.setContentHuggingPriority(.required, for: .horizontal)
            let line = NSStackView(views: [icon, title, NSView(), count])
            line.spacing = 5
            views = [line]
            cell.toolTip = gateway.isDirect ? "Hosts reached without a gateway"
                : gateway.isJump ? "SSH hosts reached through the jump host \(gateway.host)" : "Through \(gateway.host)"
        } else if let host = settings.hosts.first(where: { $0.id == item.id }) {
            let title = NSTextField(labelWithString: host.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField(labelWithString: host.isSSH
                ? (host.label.isEmpty ? "SSH" : "SSH  ·  \(host.address)") : host.address)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            // The short label, the one on the Dock icon, as a badge before the name.
            var first: NSView = title
            if !host.dockLabel.isEmpty {
                let badge = NSTextField(labelWithString: " \(host.dockLabel) ")
                badge.font = .systemFont(ofSize: 10, weight: .bold)
                let fill = host.color ?? .controlAccentColor
                badge.textColor = host.color?.readableText ?? .white
                badge.alignment = .center
                badge.wantsLayer = true
                badge.layer?.backgroundColor = fill.cgColor
                badge.layer?.cornerRadius = 4
                badge.setContentCompressionResistancePriority(.required, for: .horizontal)
                badge.setContentHuggingPriority(.required, for: .horizontal)
                badge.widthAnchor.constraint(greaterThanOrEqualTo: badge.heightAnchor).isActive = true
                let line = NSStackView(views: [badge, title])
                line.spacing = 5
                line.alignment = .centerY
                first = line
            }
            views = host.label.isEmpty && !host.isSSH ? [first] : [first, detail]
            cell.toolTip = host.display
        } else {
            return nil
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if item.isGateway, let line = views.first { line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        let gatewayID = currentGateway?.id
        let hostID = selectedHost?.id
        app.update { s in
            s.lastGatewayID = gatewayID ?? s.lastGatewayID
            s.lastHostID = hostID
        }
        showSelection()
    }

    func outlineViewItemDidExpand(_ notification: Notification) { rememberFolding(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { rememberFolding(notification, collapsed: true) }

    private func rememberFolding(_ notification: Notification, collapsed: Bool) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? SidebarItem, item.isGateway else { return }
        app.update { s in
            s.collapsedGateways.removeAll { $0 == item.id }
            if collapsed { s.collapsedGateways.append(item.id) }
        }
    }

    /// Double-click connects to a host and folds a gateway open or shut.
    @objc private func sidebarDoubleClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        if item.isGateway {
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        } else {
            connectSelected()
        }
    }

    /// Right-click menu. The clicked row is selected first, so the actions
    /// below work on the selection as the buttons do.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.clickedRow
        if clicked >= 0 { outline.selectRowIndexes([clicked], byExtendingSelection: false) }
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        let item = clicked >= 0 ? outline.item(atRow: clicked) as? SidebarItem : nil
        if let item, !item.isGateway {
            add("Connect", #selector(connectSelected))
            menu.addItem(.separator())
            add("Edit Host...", #selector(editSelected))
            add("Remove Host", #selector(removeSelected))
        } else if let item, settings.gateways.first(where: { $0.id == item.id })?.isJump == true {
            add("Add Host...", #selector(addHost))
        } else if item != nil {
            add("Add Host...", #selector(addHost))
            menu.addItem(.separator())
            add("Edit Gateway...", #selector(editSelected))
            if let gateway = settings.gateways.first(where: { $0.id == item?.id }), canRemove(gateway) {
                add("Remove Gateway...", #selector(removeSelected))
            }
        } else {
            add("Add Host...", #selector(addHost))
            add("Add Gateway...", #selector(addGateway))
        }
    }

    // MARK: Adding, editing, removing

    @objc private func addClicked(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Add Host...", action: #selector(addHost), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Gateway...", action: #selector(addGateway), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func editSelected() {
        if let host = selectedHost {
            editHost(host)
        } else if let item = selectedItem, let gateway = settings.gateways.first(where: { $0.id == item.id }) {
            if gateway.isJump {
                alert("A jump host follows its hosts",
                      "Change or clear the Jump host field of the hosts under it.")
            } else {
                editGateway(gateway)
            }
        }
    }

    @objc private func removeSelected() {
        if let host = selectedHost {
            removeHost(host)
        } else if let item = selectedItem, let gateway = settings.gateways.first(where: { $0.id == item.id }) {
            if gateway.isJump {
                alert("A jump host follows its hosts",
                      "It goes away by itself when no host uses it anymore.")
            } else {
                removeGateway(gateway)
            }
        }
    }

    @objc private func addHost() {
        let group = currentGateway
        HostSheet.present(on: window!, host: nil, gateways: settings.gateways,
                          gatewayID: group?.id, jumpHost: group?.isJump == true ? group?.host : nil) { [weak self] host in
            self?.app.update { s in
                s.hosts.append(host)
                s.normalize()
                let placed = s.hosts.first { $0.id == host.id }
                s.lastHostID = host.id
                s.lastGatewayID = placed?.gatewayID ?? s.lastGatewayID
                s.collapsedGateways.removeAll { $0 == placed?.gatewayID }
            }
            self?.reload()
        }
    }

    private func editHost(_ host: Host) {
        HostSheet.present(on: window!, host: host, gateways: settings.gateways,
                          gatewayID: host.gatewayID) { [weak self] edited in
            self?.app.update { s in
                if let i = s.hosts.firstIndex(where: { $0.id == edited.id }) { s.hosts[i] = edited }
                s.normalize()
                let placed = s.hosts.first { $0.id == edited.id }
                s.lastGatewayID = placed?.gatewayID ?? s.lastGatewayID
                s.collapsedGateways.removeAll { $0 == placed?.gatewayID }
            }
            // A saved password belongs to the login it was for.
            if host.isSSH, !edited.isSSH || SSHCommand.login(for: host) != SSHCommand.login(for: edited) {
                Keychain.deletePassword(for: SSHCommand.login(for: host).keychainKey)
            }
            self?.reload()
        }
    }

    private func removeHost(_ host: Host) {
        app.update { s in
            s.hosts.removeAll { $0.id == host.id }
            s.hostsWithoutDynamicResolution.removeAll { $0 == host.id }
            s.lastHostID = nil
            s.lastGatewayID = host.gatewayID ?? s.lastGatewayID
            // A jump host left without hosts goes too.
            s.normalize()
        }
        if host.isSSH { Keychain.deletePassword(for: SSHCommand.login(for: host).keychainKey) }
        reload()
    }

    @objc private func addGateway() {
        GatewaySheet.present(on: window!, gateway: nil) { [weak self] gateway in
            self?.app.update { s in
                s.gateways.append(gateway)
                s.lastGatewayID = gateway.id
                s.lastHostID = nil
            }
            self?.reload()
        }
    }

    private func editGateway(_ gateway: Gateway) {
        GatewaySheet.present(on: window!, gateway: gateway) { [weak self] edited in
            self?.app.update { s in
                if let i = s.gateways.firstIndex(where: { $0.id == edited.id }) { s.gateways[i] = edited }
            }
            self?.reload()
        }
    }

    /// The one group for direct connections stays: it would only come back.
    private func canRemove(_ gateway: Gateway) -> Bool {
        !gateway.isDirect || settings.gateways.filter(\.isDirect).count > 1
    }

    /// Asks first when hosts would go with it.
    private func removeGateway(_ gateway: Gateway) {
        guard canRemove(gateway) else { NSSound.beep(); return }
        let hosts = settings.hosts.filter { $0.gatewayID == gateway.id }
        let remove = { [weak self] in
            self?.app.update { s in
                s.gateways.removeAll { $0.id == gateway.id }
                s.hosts.removeAll { $0.gatewayID == gateway.id }
                s.hostsWithoutDynamicResolution.removeAll { id in hosts.contains { $0.id == id } }
                s.lastHostID = nil
                s.normalize()
            }
            self?.reload()
        }
        guard !hosts.isEmpty, let window else { remove(); return }
        let alert = NSAlert()
        alert.messageText = "Remove \(gateway.title)?"
        alert.informativeText = hosts.count == 1
            ? "Its host \(hosts[0].title) is removed too."
            : "Its \(hosts.count) hosts are removed too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { remove() }
        }
    }

    @objc private func manageAccounts() {
        AccountsSheet.present(on: window!, app: app, gatewayID: currentGateway?.id) { [weak self] in self?.showSelection() }
    }

    // MARK: Connect

    /// Selects a host, opening its gateway's group, and connects to it.
    private func connect(hostID: UUID) {
        guard let host = settings.hosts.first(where: { $0.id == hostID }) else { return }
        app.update { s in
            s.lastHostID = host.id
            s.lastGatewayID = host.gatewayID ?? s.lastGatewayID
            s.collapsedGateways.removeAll { $0 == host.gatewayID }
        }
        reload()
        connectSelected()
    }

    @objc private func connectSelected() {
        if let host = selectedHost, host.isSSH {
            app.openTerminal(host: host)
            return
        }
        guard let host = selectedHost, let gw = settings.gateway(for: host) else { return }
        let s = settings
        guard let server = s.accounts.first(where: { $0.id == gw.serverAccountID }) ?? s.accounts.first else {
            manageAccounts()
            return
        }
        let gateway = gw.separateAccount && !gw.isDirect
            ? s.accounts.first(where: { $0.id == gw.gatewayAccountID }) : nil
        let separate = gateway != nil && gateway!.keychainKey != server.keychainKey

        Task { @MainActor in
            guard let serverPassword = await self.password(for: server, role: "Server") else { return }
            var gatewayPassword: String?
            if separate, let gateway {
                guard let pw = await self.password(for: gateway, role: "Gateway") else { return }
                gatewayPassword = pw
            }
            self.app.openSession(host: host, gateway: gw, server: server, gatewayAccount: separate ? gateway : nil,
                                 password: serverPassword, gatewayPassword: gatewayPassword)
        }
    }

    /// Saved password, or asks for one.
    @MainActor
    private func password(for account: Account, role: String) async -> String? {
        if let saved = await Keychain.passwordAsync(for: account.keychainKey) { return saved }
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            PasswordSheet.present(on: window, title: "\(role) password for \(account.display)") { entered, save in
                guard let entered else { continuation.resume(returning: nil); return }
                if save {
                    Task {
                        let ok = await Keychain.setPasswordAsync(entered, for: account.keychainKey)
                        if !ok {
                            self.alert("Password not saved",
                                       "The Keychain did not keep it. You'll be asked again next time.")
                        }
                    }
                }
                continuation.resume(returning: entered)
            }
        }
    }

    func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - Sheets

/// Small sheets built from a grid of fields.
private class FormSheet: NSWindowController {
    var onDone: ((Bool) -> Void)?
    /// Returns what's wrong, shown in the sheet, or nil to save.
    var validate: (() -> String?)?
    private(set) var grid: NSGridView!
    private let problem = NSTextField(wrappingLabelWithString: "")

    convenience init(title: String, rows: [[NSView]], okTitle: String = "Save") {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: window)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let grid = NSGridView(views: rows)
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: okTitle, target: self, action: #selector(ok))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        problem.textColor = .systemRed
        problem.isHidden = true
        let stack = NSStackView(views: [heading, grid, problem, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            problem.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            stack.widthAnchor.constraint(equalToConstant: 400),
        ])
    }

    @objc func ok() {
        if let text = validate?() {
            problem.stringValue = text
            problem.isHidden = false
            return
        }
        finish(true)
    }
    @objc func cancel() { finish(false) }

    func finish(_ accepted: Bool) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        onDone?(accepted)
        onDone = nil
    }

    static func field(_ value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return field
    }

    static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
}

/// Retains open sheets until they finish.
private var openSheets: [NSWindowController] = []

private func show(_ sheet: FormSheet, on parent: NSWindow, done: @escaping (Bool) -> Void) {
    openSheets.append(sheet)
    sheet.onDone = { accepted in
        openSheets.removeAll { $0 === sheet }
        done(accepted)
    }
    parent.beginSheet(sheet.window!)
}

enum HostSheet {
    static func present(on parent: NSWindow, host: Host?, gateways allGateways: [Gateway], gatewayID: UUID?,
                        jumpHost: String? = nil, done: @escaping (Host) -> Void) {
        // Jump hosts follow the hosts' own field, they aren't picked here.
        let gateways = allGateways.filter { !$0.isJump }
        let kind = NSSegmentedControl(labels: ["Remote Desktop", "SSH"], trackingMode: .selectOne,
                                      target: nil, action: nil)
        kind.selectedSegment = host?.isSSH == true || jumpHost != nil ? 1 : 0
        let address = FormSheet.field(host?.address ?? "", placeholder: "192.168.1.20, a name, or host:port")
        let label = FormSheet.field(host?.label ?? "", placeholder: "Optional")
        let dockLabel = NSTextField(string: host?.dockLabel ?? "")
        dockLabel.placeholderString = "Optional, a few characters"
        dockLabel.widthAnchor.constraint(equalToConstant: 208).isActive = true
        dockLabel.toolTip = "Shown as a badge in the host list and big on this server's Dock icon while it is open."
        // The label's colour: the badge in the list and the text on the Dock icon.
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
        well.color = host?.color ?? .controlAccentColor
        well.toolTip = "The label's colour, in the host list and on the Dock icon"
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        var colorChosen = false
        let wellHandler = PopupHandler {
            colorChosen = true
            // Black or nearly black would vanish on the Dock screen.
            let visible = well.color.visibleOnBlack
            if visible.hexString != well.color.hexString { well.color = visible }
        }
        well.target = wellHandler
        well.action = #selector(PopupHandler.changed)
        let labelRow = NSStackView(views: [dockLabel, well])
        labelRow.spacing = 8
        let gatewayPopup = NSPopUpButton()
        gateways.forEach { gatewayPopup.menu?.addItem(withTitle: $0.title, action: nil, keyEquivalent: "") }
        gatewayPopup.selectItem(at: gateways.firstIndex { $0.id == gatewayID } ?? gateways.firstIndex(where: \.isDirect) ?? 0)

        // SSH
        let user = FormSheet.field(host?.sshUser ?? "", placeholder: "Your Mac user name if empty")
        let port = FormSheet.field(host?.port.map(String.init) ?? "", placeholder: "22")
        let jump = FormSheet.field(host?.jumpHost ?? jumpHost ?? "", placeholder: "Optional: user@jumpserver")
        jump.toolTip = "A server to go through first. Hosts with the same jump host are grouped under it."
        let auth = NSPopUpButton()
        auth.addItems(withTitles: ["Key or certificate", "Password"])
        auth.selectItem(at: host?.sshAuth == .password ? 1 : 0)
        auth.toolTip = "With a key or certificate, ssh never asks for a password, so a fake server can't ask for one either. A password is asked in a window and can be saved in the Keychain."
        var identity = host?.identityFile ?? ""
        // The keys in ~/.ssh, a file elsewhere, or a new one.
        let keyRow = NSPopUpButton()
        keyRow.widthAnchor.constraint(equalToConstant: 260).isActive = true
        keyRow.toolTip = "A certificate next to the key (<key>-cert.pub) is used too."
        var keyPaths: [String] = []
        func fillKeys() {
            keyRow.removeAllItems()
            keyPaths = [""] + SSHKeys.list()
            if !identity.isEmpty, !keyPaths.contains(identity) { keyPaths.append(identity) }
            // Through the menu: the popup's own addItem drops equal titles.
            for path in keyPaths {
                let name = (path as NSString).lastPathComponent
                let title = path.isEmpty ? "Any of my keys" : SSHKeys.hasCertificate(path) ? "\(name), with certificate" : name
                keyRow.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "").toolTip = path.isEmpty ? nil : path
            }
            keyRow.menu?.addItem(.separator())
            keyRow.menu?.addItem(withTitle: "Choose a File...", action: nil, keyEquivalent: "")
            keyRow.menu?.addItem(withTitle: "Create a New Key...", action: nil, keyEquivalent: "")
            keyRow.selectItem(at: keyPaths.firstIndex(of: identity) ?? 0)
        }
        fillKeys()
        var sheetWindow: NSWindow?
        let keyHandler = PopupHandler {
            let index = keyRow.indexOfSelectedItem
            if index < keyPaths.count {
                identity = keyPaths[index]
            } else if index == keyPaths.count + 1 {
                let panel = NSOpenPanel()
                panel.message = "The private key, not the .pub file."
                panel.directoryURL = SSHKeys.directory
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let url = panel.url { identity = url.path }
                fillKeys()
            } else if let sheetWindow {
                let base = label.stringValue.isEmpty ? address.stringValue : label.stringValue
                let suggested = "id_ed25519_" + base.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                KeySheet.present(on: sheetWindow, suggestedName: suggested) { path in
                    if let path { identity = path }
                    fillKeys()
                }
            }
        }
        keyRow.target = keyHandler
        keyRow.action = #selector(PopupHandler.changed)

        var rows: [[NSView]] = [[FormSheet.label("Type"), kind], [FormSheet.label("Address"), address],
                                [FormSheet.label("Label"), labelRow], [FormSheet.label("Friendly name"), label]]
        let gatewayRow = gateways.count > 1 ? rows.count : nil
        if gatewayRow != nil { rows.append([FormSheet.label("Gateway"), gatewayPopup]) }
        let sshRows = rows.count
        rows += [[FormSheet.label("User"), user], [FormSheet.label("Port"), port],
                 [FormSheet.label("Jump host"), jump],
                 [FormSheet.label("Sign in with"), auth], [FormSheet.label("Key"), keyRow]]
        let sheet = FormSheet(title: host == nil ? "Add a host" : "Edit host", rows: rows)
        sheetWindow = sheet.window

        func layout() {
            let ssh = kind.selectedSegment == 1
            if let gatewayRow { sheet.grid.row(at: gatewayRow).isHidden = ssh }
            for i in sshRows..<(sshRows + 4) { sheet.grid.row(at: i).isHidden = !ssh }
            sheet.grid.row(at: sshRows + 4).isHidden = !ssh || auth.indexOfSelectedItem != 0
            address.placeholderString = ssh ? "server.example.com or 192.168.1.20" : "192.168.1.20, a name, or host:port"
        }
        let layoutHandler = PopupHandler { layout() }
        for control in [kind, auth] as [NSControl] {
            control.target = layoutHandler
            control.action = #selector(PopupHandler.changed)
        }
        layout()

        /// For SSH, "name:22" is the address plus a port.
        func sshAddress() -> (address: String, port: Int?)? {
            var text = address.stringValue.trimmingCharacters(in: .whitespaces)
            var number = port.stringValue.trimmingCharacters(in: .whitespaces)
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2, Int(parts[1]) != nil, number.isEmpty {
                text = String(parts[0])
                number = String(parts[1])
            }
            if number.isEmpty { return (text, nil) }
            guard let value = Int(number), (1...65535).contains(value) else { return nil }
            return (text, value)
        }
        sheet.validate = {
            let trimmed = address.stringValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "Fill in the address." }
            guard kind.selectedSegment == 1 else { return nil }
            guard let parsed = sshAddress() else { return "The port is a number from 1 to 65535." }
            if !SSHCommand.isValidAddress(parsed.address) {
                return "That's not a host name or IP address ssh can use."
            }
            if !SSHCommand.isValidUser(user.stringValue.trimmingCharacters(in: .whitespaces)) {
                return "The user can have letters, digits and . _ - \\ @ only, and can't start with a dash."
            }
            if (try? SSHCommand.jump(jump.stringValue)) == nil, !jump.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                return "The jump host is user@server or user@server:port, one server."
            }
            return nil
        }

        show(sheet, on: parent) { accepted in
            _ = (wellHandler, keyHandler, layoutHandler)
            well.deactivate()
            NSColorPanel.shared.orderOut(nil)
            let trimmed = address.stringValue.trimmingCharacters(in: .whitespaces)
            guard accepted, !trimmed.isEmpty else { return }
            var result = host ?? Host(address: trimmed, label: "")
            if colorChosen { result.labelColor = well.color.hexString }
            result.address = trimmed
            result.label = label.stringValue.trimmingCharacters(in: .whitespaces)
            result.dockLabel = dockLabel.stringValue.trimmingCharacters(in: .whitespaces)
            if kind.selectedSegment == 1, let parsed = sshAddress() {
                result.kind = .ssh
                result.address = parsed.address
                result.port = parsed.port
                result.sshUser = user.stringValue.trimmingCharacters(in: .whitespaces)
                result.sshAuth = auth.indexOfSelectedItem == 1 ? .password : .key
                result.identityFile = result.sshAuth == .key ? identity : ""
                result.jumpHost = jump.stringValue.trimmingCharacters(in: .whitespaces)
                // An RD Gateway only carries RDP; normalize() puts the host
                // under its jump host, if it has one.
                result.gatewayID = gateways.first(where: \.isDirect)?.id ?? gatewayID
            } else {
                result.kind = .rdp
                result.jumpHost = ""
                let index = gatewayPopup.indexOfSelectedItem
                result.gatewayID = gateways.indices.contains(index) ? gateways[index].id
                    : gateways.first(where: \.isDirect)?.id ?? gatewayID
            }
            done(result)
        }
    }
}

/// A new SSH key in ~/.ssh, then its public key to copy.
enum KeySheet {
    static func present(on parent: NSWindow, suggestedName: String, done: @escaping (String?) -> Void) {
        let name = FormSheet.field(suggestedName, placeholder: "id_ed25519_work")
        let passphrase = NSSecureTextField()
        passphrase.placeholderString = "Optional, but better"
        passphrase.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let again = NSSecureTextField()
        again.placeholderString = "The same again"
        again.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let save = NSButton(checkboxWithTitle: "Save the passphrase in the Keychain", target: nil, action: nil)
        save.state = .on
        save.toolTip = "Then iGateway gives it to ssh when ssh asks, the same safe way as passwords."
        let sheet = FormSheet(title: "Create a new SSH key", rows: [
            [FormSheet.label("Name"), name],
            [FormSheet.label("Passphrase"), passphrase],
            [FormSheet.label("Again"), again],
            [NSGridCell.emptyContentView, save],
        ], okTitle: "Create")
        sheet.validate = {
            let n = name.stringValue.trimmingCharacters(in: .whitespaces)
            if !SSHKeys.isValidName(n) { return "The name can have letters, digits, dots, dashes and underscores." }
            if FileManager.default.fileExists(atPath: SSHKeys.directory.appendingPathComponent(n).path) {
                return "There's already a key with that name."
            }
            if passphrase.stringValue != again.stringValue { return "The passphrases aren't the same." }
            return nil
        }
        show(sheet, on: parent) { accepted in
            guard accepted else { return done(nil) }
            do {
                let path = try SSHKeys.create(name: name.stringValue.trimmingCharacters(in: .whitespaces),
                                              passphrase: passphrase.stringValue)
                if !passphrase.stringValue.isEmpty, save.state == .on {
                    Keychain.setPassword(passphrase.stringValue, for: SSHKeys.keychainKey(path), description: "SSH key passphrase")
                }
                AppLog.write("Created the SSH key \(path)")
                done(path)
                PublicKeySheet.present(on: parent, path: path)
            } catch {
                done(nil)
                let alert = NSAlert()
                alert.messageText = "The key could not be made"
                if case SSHKeys.Problem.failed(let message) = error { alert.informativeText = message }
                alert.beginSheetModal(for: parent)
            }
        }
    }
}

/// A key's public half, to put on servers or have signed.
enum PublicKeySheet {
    static func present(on window: NSWindow, path: String) {
        guard let key = SSHKeys.publicKey(path) else { return }
        let alert = NSAlert()
        alert.messageText = "Public key of \((path as NSString).lastPathComponent)"
        alert.informativeText = "Put this on the server for the account you log in as, or have your CA sign it. "
            + "The private key stays on this Mac."
        let text = NSTextField(wrappingLabelWithString: key)
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.frame = NSRect(origin: .zero, size: text.sizeThatFits(NSSize(width: 360, height: 400)))
        alert.accessoryView = text
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
        }
    }
}

/// Name, address and transport of a gateway. A blank address means direct.
enum GatewaySheet {
    static func present(on parent: NSWindow, gateway: Gateway?, done: @escaping (Gateway) -> Void) {
        let name = FormSheet.field(gateway?.name ?? "", placeholder: "Optional, for example Work")
        let address = FormSheet.field(gateway?.host ?? "", placeholder: "rdg.example.com, blank for direct")
        let transport = NSPopUpButton()
        GatewayTransport.allCases.forEach { transport.addItem(withTitle: $0.label) }
        transport.selectItem(at: GatewayTransport.allCases.firstIndex(of: gateway?.transport ?? .automatic) ?? 0)
        transport.toolTip = "How FreeRDP talks to the gateway. Automatic lets FreeRDP choose; pick one if a gateway only works one way."
        address.toolTip = "Add :port if the gateway does not use 443. Leave blank for hosts you reach without a gateway."
        let sheet = FormSheet(title: gateway == nil ? "Add a gateway" : "Edit gateway", rows: [
            [FormSheet.label("Name"), name],
            [FormSheet.label("Gateway"), address],
            [FormSheet.label("Transport"), transport],
        ])
        show(sheet, on: parent) { accepted in
            guard accepted else { return }
            // Commas and spaces would break FreeRDP's /gateway option.
            let host = address.stringValue.filter { $0 != "," && !$0.isWhitespace }
            var result = gateway ?? Gateway()
            result.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            result.host = host
            result.transport = GatewayTransport.allCases[max(0, transport.indexOfSelectedItem)]
            if result.isDirect { result.separateAccount = false }
            done(result)
        }
    }
}

enum PasswordSheet {
    static func present(on parent: NSWindow, title: String, done: @escaping (String?, Bool) -> Void) {
        let field = NSSecureTextField()
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let save = NSButton(checkboxWithTitle: "Save in the Keychain", target: nil, action: nil)
        save.state = .on
        let sheet = FormSheet(title: title, rows: [[FormSheet.label("Password"), field],
                                                   [NSGridCell.emptyContentView, save]], okTitle: "Connect")
        sheet.window?.initialFirstResponder = field
        show(sheet, on: parent) { accepted in
            done(accepted && !field.stringValue.isEmpty ? field.stringValue : nil, save.state == .on)
        }
    }
}

/// Add, edit and remove accounts. Renaming keeps nothing behind: the old
/// Keychain entry stays where it is and the new name gets asked for once.
enum AccountsSheet {
    static func present(on parent: NSWindow, app: AppController, gatewayID: UUID?, done: @escaping () -> Void) {
        let popup = NSPopUpButton()
        func fill() {
            popup.removeAllItems()
            popup.addItem(withTitle: "New account")
            app.settings.accounts.forEach { popup.menu?.addItem(withTitle: $0.display, action: nil, keyEquivalent: "") }
        }
        fill()
        let user = FormSheet.field("", placeholder: "name or name@example.com")
        let domain = FormSheet.field("", placeholder: "Optional")
        let remove = NSButton(checkboxWithTitle: "Remove this account", target: nil, action: nil)
        let handler = PopupHandler {
            let i = popup.indexOfSelectedItem - 1
            let account = app.settings.accounts.indices.contains(i) ? app.settings.accounts[i] : nil
            user.stringValue = account?.username ?? ""
            domain.stringValue = account?.domain ?? ""
            remove.isEnabled = account != nil
            remove.state = .off
        }
        popup.target = handler
        popup.action = #selector(PopupHandler.changed)
        if app.settings.accounts.isEmpty { popup.selectItem(at: 0) } else { popup.selectItem(at: 1) }
        handler.changed()

        let sheet = FormSheet(title: "Accounts", rows: [
            [FormSheet.label("Account"), popup],
            [FormSheet.label("Username"), user],
            [FormSheet.label("Domain"), domain],
            [NSGridCell.emptyContentView, remove],
        ])
        show(sheet, on: parent) { accepted in
            _ = handler
            guard accepted else { return }
            let i = popup.indexOfSelectedItem - 1
            let name = user.stringValue.trimmingCharacters(in: .whitespaces)
            let dom = domain.stringValue.trimmingCharacters(in: .whitespaces)
            app.update { s in
                if s.accounts.indices.contains(i) {
                    if remove.state == .on {
                        let key = s.accounts[i].keychainKey
                        Task.detached { Keychain.deletePassword(for: key) }
                        s.accounts.remove(at: i)
                        s.normalize()
                    } else if !name.isEmpty {
                        s.accounts[i].username = name
                        s.accounts[i].domain = dom
                    }
                } else if !name.isEmpty {
                    let account = Account(username: name, domain: dom)
                    s.accounts.append(account)
                    if let g = s.gateways.firstIndex(where: { $0.id == gatewayID }),
                       s.gateways[g].serverAccountID == nil {
                        s.gateways[g].serverAccountID = account.id
                    }
                }
            }
            done()
        }
    }
}

private final class PopupHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed() { action() }
}
