//
//  HistoryPanel.swift
//
//  The "Recent" list under the settings: each connection with its account,
//  when it started, how long it was open or why it failed. A session that is
//  still open can be brought to the front; anything else connects again.
//

import AppKit

final class HistoryPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Whether a session to this host is open right now.
    var isLive: (UUID) -> Bool = { _ in false }
    /// Whether the host still exists, so it can be connected to.
    var canConnect: (UUID) -> Bool = { _ in false }
    var onShow: (UUID) -> Void = { _ in }
    var onConnect: (UUID) -> Void = { _ in }

    private struct Row: Equatable {
        var hostID: UUID
        var title: String
        var detail: String
        var tooltip: String
        var color: NSColor
        var live: Bool
        var enabled: Bool
    }

    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "No connections yet")
    private var rows: [Row] = []
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    private func build() {
        let heading = NSTextField(labelWithString: "Recent")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .inline
        clear.controlSize = .small
        clear.toolTip = "Forget finished connections"
        let header = NSStackView(views: [heading, NSView(), clear])

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 38
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.selectionHighlightStyle = .regular
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.textColor = .tertiaryLabelColor
        empty.font = .systemFont(ofSize: 12)

        for view in [header, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        ])
    }

    // MARK: Contents

    func refresh(force: Bool = false) {
        var seen = Set<UUID>()
        let fresh = History.read().map { entry -> Row in
            // Only the newest entry per host can be the open session.
            let newest = seen.insert(entry.hostID).inserted
            let live = newest && (entry.state == .connecting || entry.state == .connected) && isLive(entry.hostID)
            return row(for: entry, live: live)
        }
        guard force || fresh != rows else { return }
        rows = fresh
        table.reloadData()
        empty.isHidden = !rows.isEmpty
    }

    private func row(for entry: HistoryEntry, live: Bool) -> Row {
        let started = Self.time(entry.started)
        let status: String
        let color: NSColor
        switch entry.state {
        case .connecting where live:
            status = "connecting since \(started)"
            color = .systemOrange
        case .connected where live:
            status = "open since \(started), \(Self.duration(from: entry.connected ?? entry.started, to: Date()))"
            color = .systemGreen
        case .failed:
            status = "\(started), \(entry.detail ?? "could not connect")"
            color = .systemRed
        default:
            if let connected = entry.connected, let ended = entry.ended {
                status = "\(started), \(Self.duration(from: connected, to: ended))"
                    + (entry.detail.map { ", \($0)" } ?? "")
            } else if entry.connected != nil || entry.state == .connected {
                status = "\(started), ended"
            } else {
                status = "\(started), cancelled"
            }
            color = .tertiaryLabelColor
        }
        return Row(hostID: entry.hostID, title: entry.title, detail: "\(entry.account)  ·  \(status)",
                   tooltip: "\(entry.title) (\(entry.address))\n\(status)", color: color, live: live,
                   enabled: live || canConnect(entry.hostID))
    }

    /// "14:32" today, "26 Oct 14:32" before.
    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm")
        return formatter.string(from: date)
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        if minutes < 1 { return "under a minute" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = row.color.cgColor
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: row.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for field in [title, detail] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let button = NSButton(title: row.live ? "Show" : "Connect", target: self, action: #selector(buttonClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = index
        button.isEnabled = row.enabled
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [dot, text, spacer, button])
        line.spacing = 8
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.toolTip = row.tooltip
        cell.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Actions

    private func open(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if row.live { onShow(row.hostID) } else if row.enabled { onConnect(row.hostID) }
    }

    @objc private func buttonClicked(_ sender: NSButton) { open(sender.tag) }

    @objc private func rowDoubleClicked() { open(table.clickedRow) }

    @objc private func clearHistory() {
        let open = Set(History.read().map(\.hostID).filter { isLive($0) })
        History.clear(keepingOpen: open)
        refresh()
    }
}
