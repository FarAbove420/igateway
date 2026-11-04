//
//  Askpass.swift
//
//  Saved SSH passwords, the safe way. With SSH_ASKPASS_REQUIRE=force (ssh(1),
//  ENVIRONMENT) ssh doesn't read a password from the terminal: it runs a
//  helper and reads the answer from it. The helper is this app's own
//  executable. It asks the session that started ssh, over a private socket,
//  and prints the answer for ssh. A password never goes through the
//  terminal, so text a server prints can't get one.
//
//  The session answers only ssh's own password prompt for exactly the host's,
//  or its jump host's, user@address, from the Keychain. Everything else (a
//  new host key, a key's passphrase, a one-time code) is shown as a sheet.
//  Only a process started by that session's ssh, with the session's token,
//  gets an answer.
//

import Foundation
import Security

enum Askpass {
    static let socketVariable = "IGATEWAY_ASKPASS_SOCKET"
    static let tokenVariable = "IGATEWAY_ASKPASS_TOKEN"
    /// A var only so the tests can use their own binary.
    static var helperPath = Bundle.main.executablePath ?? ""

    enum Prompt: Equatable {
        case password(SSHCommand.Login)
        /// A key file's passphrase, by the key's path.
        case passphrase(String)
        case hostKey(String)
        case other(String)
    }

    /// What ssh is asking. Only ssh's own password prompt for one of the
    /// logins counts: "user@host's password: ", or for keyboard-interactive
    /// login "(user@host) Password:".
    static func classify(_ prompt: String, logins: [SSHCommand.Login]) -> Prompt {
        for login in logins {
            let userAt = "\(login.effectiveUser)@\(login.address)"
            if prompt == "\(userAt)'s password: " { return .password(login) }
            if prompt.hasPrefix("(\(userAt)) "),
               prompt.dropFirst(userAt.count + 3).trimmingCharacters(in: .whitespaces).lowercased() == "password:" {
                return .password(login)
            }
        }
        // "Enter passphrase for key '<path>': ", the path cut off at 100
        // characters (tested with OpenSSH 10.3): only a whole path, of a key
        // that is there, counts.
        let head = "Enter passphrase for key '", tail = "': "
        if prompt.hasPrefix(head), prompt.hasSuffix(tail) {
            let path = String(prompt.dropFirst(head.count).dropLast(tail.count))
            if path.hasPrefix("/"), path.count < 100, FileManager.default.fileExists(atPath: path) {
                return .passphrase(path)
            }
        }
        if prompt.contains("Are you sure you want to continue connecting") { return .hostKey(prompt) }
        return .other(prompt)
    }

    // MARK: The helper, run by ssh

    /// Asks the session, prints the answer for ssh. Exit 1 means cancelled.
    static func runHelper() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let path = env[socketVariable], let token = env[tokenVariable] else { return 1 }
        let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }
        defer { close(fd) }
        guard var address = unixAddress(path) else { return 1 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, let request = try? JSONEncoder().encode(["token": token, "prompt": prompt]),
              writeAll(fd, request) else { return 1 }
        shutdown(fd, SHUT_WR)
        guard let reply = try? JSONDecoder().decode([String: String].self, from: readAll(fd)),
              let answer = reply["answer"] else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }

    // MARK: Plumbing

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// Up to 64 KB: a prompt or a password, nothing bigger.
    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The helper's parent is ssh, or for a jump host the ssh that ssh
    /// started for it.
    static func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        guard ancestor > 1 else { return false }
        var current = pid
        for _ in 0..<4 {
            guard let up = parent(of: current), up > 1 else { return false }
            if up == ancestor { return true }
            current = up
        }
        return false
    }
}

/// The session's end of the socket. Lives as long as its ssh.
final class AskpassServer {
    let socketPath: String
    let token = Askpass.randomHex(32)
    private let directory: URL
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "askpass")

    /// - isFromSSH: whether a process was started by this session's ssh.
    /// - handle: on the main thread, a prompt and where its answer goes.
    init?(isFromSSH: @escaping (pid_t) -> Bool, handle: @escaping (String, @escaping (String?) -> Void) -> Void) {
        // A folder only this user can enter, with a short path: a socket's
        // path has to fit in 104 bytes.
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iga-" + Askpass.randomHex(6))
        socketPath = directory.appendingPathComponent("s").path
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])) != nil,
              var address = Askpass.unixAddress(socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let token = self.token
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Self.serve(client, token: token, isFromSSH: isFromSSH, handle: handle)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private static func serve(_ fd: Int32, token: String, isFromSSH: (pid_t) -> Bool,
                              handle: @escaping (String, @escaping (String?) -> Void) -> Void) {
        // This user, and a process ssh started: checked before reading a byte.
        var uid = uid_t(), gid = gid_t()
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, isFromSSH(pid) else {
            close(fd)
            return
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = try? JSONDecoder().decode([String: String].self, from: Askpass.readAll(fd)),
              let given = request["token"], Self.sameToken(given, token), let prompt = request["prompt"] else {
            close(fd)
            return
        }
        DispatchQueue.main.async {
            handle(prompt) { answer in
                DispatchQueue.global().async {
                    let reply: [String: String] = answer.map { ["answer": $0] } ?? [:]
                    if let data = try? JSONEncoder().encode(reply) { _ = Askpass.writeAll(fd, data) }
                    close(fd)
                }
            }
        }
    }

    /// Takes as long whatever the difference, so it can't be guessed byte
    /// by byte.
    private static func sameToken(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func stop() {
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}
