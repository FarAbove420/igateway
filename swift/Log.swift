//
//  Log.swift
//
//  The app's own log, next to FreeRDP's: which host, gateway and account a
//  session used, every state change and error, and what the clipboard did.
//  Passwords and clipboard contents are never written.
//

import AppKit

enum AppLog {
    private static let queue = DispatchQueue(label: "igateway.log")
    private static let maxSize: UInt64 = 5 << 20

    static var url: URL { Store.logDirectory.appendingPathComponent("app.log") }
    static var freerdpURL: URL { Store.logDirectory.appendingPathComponent("freerdp.log") }

    /// Selects both logs in Finder. They are plain text, so any editor opens them.
    static func reveal() {
        let files = [url, freerdpURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            try? FileManager.default.createDirectory(at: Store.logDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Store.logDirectory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    static func write(_ message: String) {
        let date = Date()
        queue.async {
            let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current,
                                                    formatOptions: [.withInternetDateTime, .withFractionalSeconds])
            let line = Data("\(stamp)  \(message)\n".utf8)
            let fm = FileManager.default
            try? fm.createDirectory(at: Store.logDirectory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxSize {
                let old = Store.logDirectory.appendingPathComponent("app.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            // O_APPEND: session processes write to the same file.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            line.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }
}
