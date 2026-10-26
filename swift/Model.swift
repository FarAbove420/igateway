//
//  Model.swift
//
//  Gateways, hosts, accounts, settings and the Keychain. Nothing is built in:
//  a new install starts with direct connections only.
//

import Foundation

struct Host: Codable, Hashable, Identifiable {
    var id = UUID()
    var address: String
    var label: String
    /// The gateway this host is reached through.
    var gatewayID: UUID?
    /// A few characters for the badge in the list and the Dock icon. Empty
    /// means no badge and an empty screen on the icon.
    var dockLabel = ""
    /// The label's colour as "#RRGGBB" (sRGB). Empty means the default.
    var labelColor = ""

    var title: String { label.isEmpty ? address : label }
    var display: String { label.isEmpty ? address : "\(label) (\(address))" }

    enum CodingKeys: String, CodingKey { case id, address, label, gatewayID, dockLabel, labelColor }

    init(address: String, label: String, gatewayID: UUID? = nil, dockLabel: String = "", labelColor: String = "") {
        self.address = address
        self.label = label
        self.gatewayID = gatewayID
        self.dockLabel = dockLabel
        self.labelColor = labelColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        address = c.value(.address, or: "")
        label = c.value(.label, or: "")
        gatewayID = c.value(.gatewayID, or: nil)
        dockLabel = c.value(.dockLabel, or: "")
        labelColor = c.value(.labelColor, or: "")
    }
}

struct Account: Codable, Hashable, Identifiable {
    var id = UUID()
    var username: String
    var domain: String

    var keychainKey: String { domain.isEmpty ? username : "\(username)@\(domain)" }
    var display: String { domain.isEmpty ? username : "\(domain)\\\(username)" }

    enum CodingKeys: String, CodingKey { case id, username, domain }

    init(username: String, domain: String) {
        self.username = username
        self.domain = domain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        username = c.value(.username, or: "")
        domain = c.value(.domain, or: "")
    }
}

/// How FreeRDP talks to the gateway: the `type:` of its /gateway option.
enum GatewayTransport: String, Codable, CaseIterable {
    case automatic = "auto"
    case rpc
    case http

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .rpc:       return "RPC over HTTP"
        case .http:      return "HTTP"
        }
    }
}

/// An RD Gateway and the hosts behind it. A blank address means the hosts are
/// reached directly.
struct Gateway: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var transport: GatewayTransport = .automatic
    /// Account used for the hosts behind this gateway.
    var serverAccountID: UUID?
    /// Some gateways want a different account than the hosts behind them.
    var separateAccount = false
    var gatewayAccountID: UUID?

    var isDirect: Bool { host.trimmingCharacters(in: .whitespaces).isEmpty }
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return isDirect ? "Direct connections" : host
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, transport, serverAccountID, separateAccount, gatewayAccountID
    }

    init(name: String = "", host: String = "", transport: GatewayTransport = .automatic,
         serverAccountID: UUID? = nil, separateAccount: Bool = false, gatewayAccountID: UUID? = nil) {
        self.name = name
        self.host = host
        self.transport = transport
        self.serverAccountID = serverAccountID
        self.separateAccount = separateAccount
        self.gatewayAccountID = gatewayAccountID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        name = c.value(.name, or: "")
        host = c.value(.host, or: "")
        transport = c.value(.transport, or: .automatic)
        serverAccountID = c.value(.serverAccountID, or: nil)
        separateAccount = c.value(.separateAccount, or: false)
        gatewayAccountID = c.value(.gatewayAccountID, or: nil)
    }
}

/// Raw values are the ids from `sdl-freerdp /list:kbd` and the keys stored in
/// config.json, so they must not change. New cases can be added freely.
enum KeyboardLayout: String, Codable, CaseIterable {
    case automatic     = ""
    case belgianFrench = "0x080C"
    case belgianPeriod = "0x0813"
    case belgianComma  = "0x1080C"
    case french        = "0x040C"
    case swissFrench   = "0x100C"
    case german        = "0x0407"
    case swissGerman   = "0x0807"
    case dutch         = "0x0413"
    case unitedStates  = "0x0409"
    case unitedKingdom = "0x0809"
    case spanish       = "0x040A"
    case italian       = "0x0410"
    case portuguese    = "0x0816"
    case danish        = "0x0406"
    case swedish       = "0x041D"
    case norwegian     = "0x0414"
    case finnish       = "0x040B"

    var label: String {
        switch self {
        case .automatic:     return "Let the server decide"
        case .belgianFrench: return "Belgian French (AZERTY)"
        case .belgianPeriod: return "Belgian (Period)"
        case .belgianComma:  return "Belgian (Comma)"
        case .french:        return "French (AZERTY)"
        case .swissFrench:   return "Swiss French"
        case .german:        return "German (QWERTZ)"
        case .swissGerman:   return "Swiss German"
        case .dutch:         return "Dutch"
        case .unitedStates:  return "United States (QWERTY)"
        case .unitedKingdom: return "United Kingdom"
        case .spanish:       return "Spanish"
        case .italian:       return "Italian"
        case .portuguese:    return "Portuguese"
        case .danish:        return "Danish"
        case .swedish:       return "Swedish"
        case .norwegian:     return "Norwegian"
        case .finnish:       return "Finnish"
        }
    }
}

enum KeyboardMode: String, Codable, CaseIterable {
    /// Typed text goes over as the characters the Mac produced, so every
    /// symbol comes out exactly as on the Mac whatever the layouts. Shortcuts
    /// and non-text keys go as key positions.
    case characters
    /// Everything goes as key positions, for apps that read raw keys.
    case scancodes

    var label: String {
        switch self {
        case .characters: return "Type what the Mac types"
        case .scancodes:  return "Send raw keys"
        }
    }
}

/// Every key is read with a fallback. The synthesized Codable decoder throws on
/// a missing key instead of using the default, which would wipe saved hosts
/// whenever a field is added.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

struct AppSettings: Codable {
    var gateways: [Gateway] = []
    var hosts: [Host] = []
    var accounts: [Account] = []
    var lastGatewayID: UUID?
    var lastHostID: UUID?

    var keyboardLayout: KeyboardLayout = .detected()
    var keyboardMode: KeyboardMode = .characters
    var sound = true
    var shareFolder = false
    var sharedFolderPath = NSHomeDirectory()
    var sharpOnRetina = false
    var openFullscreen = false
    var dynamicResolution = true
    /// Hosts that timed out during activation with dynamic resolution on and
    /// were reconnected without it. Remembered so it only happens once.
    var hostsWithoutDynamicResolution: [UUID] = []
    /// Gateways folded shut in the sidebar.
    var collapsedGateways: [UUID] = []
    var windowWidth: Double = 1440
    var windowHeight: Double = 900

    enum CodingKeys: String, CodingKey {
        case gateways, hosts, accounts, lastGatewayID, lastHostID, keyboardLayout, keyboardMode
        case sound, shareFolder, sharedFolderPath, sharpOnRetina, openFullscreen
        case dynamicResolution, hostsWithoutDynamicResolution, collapsedGateways, windowWidth, windowHeight
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        gateways = c.value(.gateways, or: [])
        hosts = c.value(.hosts, or: d.hosts)
        accounts = c.value(.accounts, or: d.accounts)
        lastGatewayID = c.value(.lastGatewayID, or: nil)
        lastHostID = c.value(.lastHostID, or: nil)
        keyboardLayout = c.value(.keyboardLayout, or: d.keyboardLayout)
        keyboardMode = c.value(.keyboardMode, or: d.keyboardMode)
        sound = c.value(.sound, or: d.sound)
        shareFolder = c.value(.shareFolder, or: d.shareFolder)
        sharedFolderPath = c.value(.sharedFolderPath, or: d.sharedFolderPath)
        sharpOnRetina = c.value(.sharpOnRetina, or: d.sharpOnRetina)
        openFullscreen = c.value(.openFullscreen, or: d.openFullscreen)
        dynamicResolution = c.value(.dynamicResolution, or: d.dynamicResolution)
        hostsWithoutDynamicResolution = c.value(.hostsWithoutDynamicResolution, or: [])
        collapsedGateways = c.value(.collapsedGateways, or: [])
        windowWidth = c.value(.windowWidth, or: d.windowWidth)
        windowHeight = c.value(.windowHeight, or: d.windowHeight)
    }

    /// Makes sure there is at least one gateway, every host belongs to one,
    /// and the selections point at things that exist.
    mutating func normalize() {
        // Hosts reached without a gateway always have a group of their own.
        if !gateways.contains(where: \.isDirect) { gateways.append(Gateway()) }
        let ids = Set(gateways.map(\.id))
        // A host without a (known) gateway is reached directly.
        let direct = gateways.first(where: \.isDirect)!.id
        for i in hosts.indices where hosts[i].gatewayID.map({ !ids.contains($0) }) ?? true {
            hosts[i].gatewayID = direct
        }
        let accountIDs = Set(accounts.map(\.id))
        for i in gateways.indices {
            if let a = gateways[i].serverAccountID, !accountIDs.contains(a) { gateways[i].serverAccountID = nil }
            if let a = gateways[i].gatewayAccountID, !accountIDs.contains(a) { gateways[i].gatewayAccountID = nil }
        }
        if lastGatewayID.map({ !ids.contains($0) }) ?? true { lastGatewayID = gateways[0].id }
        collapsedGateways.removeAll { !ids.contains($0) }
    }

    func gateway(for host: Host) -> Gateway? {
        gateways.first { $0.id == host.gatewayID } ?? gateways.first
    }
}

enum Store {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iGateway", isDirectory: true)
    }
    static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/iGateway", isDirectory: true)
    }
    private static var clipboardRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iGateway/Clipboard", isDirectory: true)
    }
    /// One folder per process: a session closing clears only its own files.
    static var clipboardCache: URL {
        clipboardRoot.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// Clears the folders of processes that ended without cleaning up.
    static func pruneClipboardCaches() {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: clipboardRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = Int32(folder.lastPathComponent) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? fm.removeItem(at: folder) }
        }
    }

    static func load() -> AppSettings {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var settings = AppSettings()
        if let data = try? Data(contentsOf: configURL) {
            if let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
                settings = decoded
            } else {
                // Unreadable: keep it aside instead of overwriting the user's hosts.
                let aside = directory.appendingPathComponent("config-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: configURL, to: aside)
                AppLog.write("config.json could not be read; kept as \(aside.lastPathComponent)")
            }
        }
        settings.normalize()
        save(settings)
        return settings
    }

    /// What is saved, without migrating or writing anything. For session
    /// processes, and to pick up what another process saved.
    static func read() -> AppSettings? {
        guard let data = try? Data(contentsOf: configURL),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return nil }
        settings.normalize()
        return settings
    }

    static func save(_ settings: AppSettings) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}

/// Passwords through /usr/bin/security, never on the main thread: blocking on
/// Process.waitUntilExit there pumps the run loop, which has crashed before.
enum Keychain {
    static let service = "iGateway"

    @discardableResult
    /// `fromStandardError` reads what security prints there instead, which is
    /// where `-g` puts the password.
    private static func run(_ arguments: [String], stdin: String? = nil,
                            fromStandardError: Bool = false) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = fromStandardError ? FileHandle.nullDevice : output
        process.standardError = fromStandardError ? output : FileHandle.nullDevice
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch { return (-1, "") }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        return (process.terminationStatus, text)
    }

    /// Read with `-g`, not `-w`: `-w` prints a password with non-ASCII
    /// characters as bare hex, indistinguishable from a password that is hex.
    static func password(for account: String) -> String? {
        let (status, text) = run(["find-generic-password", "-a", account, "-s", service, "-g"],
                                 fromStandardError: true)
        guard status == 0 else { return nil }
        let line = text.split(separator: "\n").first { $0.hasPrefix("password: ") }
        return line.flatMap { revealed(String($0)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The password from security's `-g` line: `password: "text"` for plain
    /// ASCII, `password: 0x<hex>  "<escaped>"` for anything else.
    static func revealed(_ line: String) -> String? {
        guard line.hasPrefix("password: ") else { return nil }
        let value = line.dropFirst("password: ".count)
        if value.hasPrefix("0x") {
            let hex = Array(value.dropFirst(2).prefix { $0.isHexDigit })
            guard hex.count % 2 == 0 else { return nil }
            var bytes: [UInt8] = []
            for i in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(hex[i...i + 1]), radix: 16) else { return nil }
                bytes.append(byte)
            }
            return String(bytes: bytes, encoding: .utf8)
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    /// `-w` must be the last argument: with anything after it, security takes
    /// the next argument as the password, prints its usage and stores nothing.
    /// It then prompts twice on stdin, so the value goes in twice. A write is
    /// only trusted once it reads back.
    @discardableResult
    static func setPassword(_ password: String, for account: String) -> Bool {
        let (status, _) = run(["add-generic-password", "-a", account, "-s", service, "-U",
                               "-l", "iGateway.exe (\(account))", "-D", "RDP password", "-w"],
                              stdin: "\(password)\n\(password)\n")
        guard status == 0 else { return false }
        return Self.password(for: account) == password
    }

    static func deletePassword(for account: String) {
        run(["delete-generic-password", "-a", account, "-s", service])
    }

    static func passwordAsync(for account: String) async -> String? {
        await Task.detached { password(for: account) }.value
    }

    static func setPasswordAsync(_ password: String, for account: String) async -> Bool {
        await Task.detached { setPassword(password, for: account) }.value
    }
}

/// Plain language for the ERRCONNECT_* names FreeRDP reports. Names from the
/// FreeRDP 3 headers.
enum ConnectError {
    /// Reasons Windows gives for ending a session on purpose. These are a
    /// normal close, not a failure. Names from FreeRDP's error.h.
    static func endReason(_ token: String) -> String? {
        switch token {
        case "ERRINFO_LOGOFF_BY_USER", "ERRINFO_RPC_INITIATED_LOGOFF":
            return "signed out of Windows"
        case "ERRINFO_RPC_INITIATED_DISCONNECT", "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER":
            return "disconnected from Windows"
        case "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION":
            return "taken over by another connection"
        case "ERRINFO_IDLE_TIMEOUT":
            return "ended after being idle"
        default:
            return nil
        }
    }

    static func explain(_ token: String) -> String {
        switch token {
        case "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_WRONG_PASSWORD",
             "ERRCONNECT_AUTHENTICATION_FAILED", "ERRCONNECT_NO_OR_MISSING_CREDENTIALS":
            return "The username or password was rejected."
        case "ERRCONNECT_ACCOUNT_LOCKED_OUT":
            return "That account is locked out."
        case "ERRCONNECT_PASSWORD_EXPIRED", "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED",
             "ERRCONNECT_PASSWORD_MUST_CHANGE":
            return "That password has expired. Change it in Windows first."
        case "ERRCONNECT_ACCOUNT_DISABLED", "ERRCONNECT_ACCOUNT_EXPIRED",
             "ERRCONNECT_ACCOUNT_RESTRICTION":
            return "That account is disabled, expired or restricted."
        case "ERRCONNECT_INSUFFICIENT_PRIVILEGES", "ERRCONNECT_LOGON_TYPE_NOT_GRANTED",
             "ERRCONNECT_ACCESS_DENIED":
            return "The account works but is not allowed to sign in to this host over RDP."
        case "ERRCONNECT_DNS_NAME_NOT_FOUND", "ERRCONNECT_DNS_ERROR":
            return "That name could not be resolved. Check the VPN."
        case "ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_CONNECT_TRANSPORT_FAILED":
            return "The connection could not be made, or dropped."
        case "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED", "ERRCONNECT_TLS_CONNECT_FAILED":
            return "The login could not be set up. Show Log has the details."
        case "ERRCONNECT_ACTIVATION_TIMEOUT":
            return "The host accepted you but the session never started."
        case "ERRCONNECT_KDC_UNREACHABLE":
            return "The Kerberos KDC could not be reached."
        case "ERRCONNECT_TARGET_BOOTING":
            return "The host is still starting up. Try again shortly."
        case "ERRCONNECT_CONNECT_CANCELLED":
            return "The connection was cancelled."
        default:
            return token.isEmpty ? "The connection ended." : "FreeRDP reported \(token)."
        }
    }
}
