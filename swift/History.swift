//
//  History.swift
//
//  Recent connections, shown under the settings in the host list. Each
//  session runs in its own process, so the sessions write to a shared file
//  and the host list reads it. Writes take a file lock, so two sessions
//  changing state at once cannot lose each other's entries.
//

import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case connecting, connected, ended, failed
    }

    var id = UUID()
    var hostID: UUID
    var title: String
    var address: String
    var account: String
    var started = Date()
    var connected: Date?
    var ended: Date?
    var state: State = .connecting
    /// Why it failed, in plain language.
    var detail: String?
}

enum History {
    static let limit = 30

    static var url: URL { Store.directory.appendingPathComponent("history.json") }
    private static var lockURL: URL { Store.directory.appendingPathComponent("history.lock") }

    /// Newest first.
    static func read() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    static func modify(_ change: (inout [HistoryEntry]) -> Void) {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        let lock = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        var entries = read()
        change(&entries)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A new connection attempt. Returns its id for `update`.
    static func begin(host: Host, account: Account) -> UUID {
        let entry = HistoryEntry(hostID: host.id, title: host.title, address: host.address, account: account.display)
        modify { $0.insert(entry, at: 0) }
        return entry.id
    }

    static func update(_ id: UUID, _ change: (inout HistoryEntry) -> Void) {
        modify { entries in
            if let i = entries.firstIndex(where: { $0.id == id }) { change(&entries[i]) }
        }
    }

    /// Clears everything except the sessions still open, given by host.
    /// Entries left "connecting" by a crashed session go too.
    static func clear(keepingOpen open: Set<UUID>) {
        modify { $0.removeAll { !(($0.state == .connecting || $0.state == .connected) && open.contains($0.hostID)) } }
    }
}
