//
//  SSHKeys.swift
//
//  The SSH keys in ~/.ssh, and making a new one with the Mac's own
//  ssh-keygen. A key is a private key file with its .pub next to it; a
//  certificate for it is <key>-cert.pub, which ssh uses by itself.
//

import Foundation

enum SSHKeys {
    static var directory: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true) }

    /// Private keys in ~/.ssh, by name.
    static func list() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in
            !name.hasSuffix(".pub") && !name.hasPrefix(".")
                && fm.fileExists(atPath: directory.appendingPathComponent(name + ".pub").path)
        }.sorted().map { directory.appendingPathComponent($0).path }
    }

    static func hasCertificate(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "-cert.pub")
    }

    static func publicKey(_ path: String) -> String? {
        (try? String(contentsOfFile: path + ".pub", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a saved passphrase for a key lives in the Keychain.
    static func keychainKey(_ path: String) -> String { "sshkey:\(path)" }

    enum Problem: Error { case name, exists, failed(String) }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// A new ed25519 key in ~/.ssh. The passphrase, empty for none, goes to
    /// ssh-keygen on stdin, never on its command line.
    static func create(name: String, passphrase: String) throws -> String {
        guard isValidName(name) else { throw Problem.name }
        let fm = FileManager.default
        let path = directory.appendingPathComponent(name).path
        guard !fm.fileExists(atPath: path), !fm.fileExists(atPath: path + ".pub") else { throw Problem.exists }
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac"
        keygen.arguments = ["-q", "-t", "ed25519", "-C", "\(NSUserName())@\(host) iGateway", "-f", path]
        let input = Pipe(), errors = Pipe()
        keygen.standardInput = input
        keygen.standardOutput = FileHandle.nullDevice
        keygen.standardError = errors
        try keygen.run()
        // Asked twice: the passphrase and again to confirm.
        try input.fileHandleForWriting.write(contentsOf: Data("\(passphrase)\n\(passphrase)\n".utf8))
        try input.fileHandleForWriting.close()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0, fm.fileExists(atPath: path) else {
            // ssh-keygen also writes its questions there; the last line is what went wrong.
            throw Problem.failed(message.split(separator: "\n").last.map(String.init) ?? "ssh-keygen failed")
        }
        return path
    }
}
