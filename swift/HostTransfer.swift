//
//  HostTransfer.swift
//
//  Exports the host list to a JSON file and imports one, to share it or move
//  it to another Mac. Gateways and hosts only: never accounts or passwords.
//

import AppKit
import UniformTypeIdentifiers

struct HostListFile: Codable {
    static let formatName = "igateway-hosts"

    var format = formatName
    var version = 1
    var gateways: [ExportedGateway]

    struct ExportedGateway: Codable {
        var name: String
        /// Blank for hosts reached directly.
        var host: String
        var transport: GatewayTransport
        var hosts: [ExportedHost]

        init(name: String, host: String, transport: GatewayTransport, hosts: [ExportedHost]) {
            self.name = name
            self.host = host
            self.transport = transport
            self.hosts = hosts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.value(.name, or: "")
            host = c.value(.host, or: "")
            transport = c.value(.transport, or: .automatic)
            hosts = c.value(.hosts, or: [])
        }
    }

    struct ExportedHost: Codable {
        var address: String
        var label: String
        var dockLabel: String
        var labelColor: String
        /// SSH hosts only, so an RDP host exports as before. No key file:
        /// a path means nothing on another Mac.
        var kind: HostKind?
        var sshUser: String?
        var port: Int?
        var sshAuth: SSHAuth?
        var jumpHost: String?

        init(_ host: Host) {
            address = host.address
            label = host.label
            dockLabel = host.dockLabel
            labelColor = host.labelColor
            if host.isSSH {
                kind = .ssh
                sshUser = host.sshUser
                port = host.port
                sshAuth = host.sshAuth
                jumpHost = host.jumpHost.isEmpty ? nil : host.jumpHost
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = c.value(.address, or: "")
            label = c.value(.label, or: "")
            dockLabel = c.value(.dockLabel, or: "")
            labelColor = c.value(.labelColor, or: "")
            kind = c.value(.kind, or: nil)
            sshUser = c.value(.sshUser, or: nil)
            port = c.value(.port, or: nil)
            sshAuth = c.value(.sshAuth, or: nil)
            jumpHost = c.value(.jumpHost, or: nil)
        }
    }
}

enum HostImportError: LocalizedError {
    case notAHostList

    var errorDescription: String? { "This is not a host list exported by iGateway.exe." }
}

extension AppSettings {
    func exportedHosts() throws -> Data {
        // A jump host isn't a gateway: its hosts carry it in their own
        // field, so they go with the direct ones and the group comes back
        // on import.
        let jumpIDs = Set(gateways.filter(\.isJump).map(\.id))
        let file = HostListFile(gateways: gateways.filter { !$0.isJump }.map { gateway in
            .init(name: gateway.name, host: gateway.host, transport: gateway.transport,
                  hosts: hosts.filter {
                      $0.gatewayID == gateway.id || (gateway.isDirect && jumpIDs.contains($0.gatewayID ?? gateway.id))
                  }.map { .init($0) })
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    struct ImportResult {
        var hosts = 0
        var gateways = 0
        var skipped = 0
    }

    /// Adds what the file has and this list lacks. A gateway matches on its
    /// address (blank matches direct connections), a host on its address
    /// within that gateway. Matches are left as they are.
    mutating func importHosts(from data: Data) throws -> ImportResult {
        let file = try JSONDecoder().decode(HostListFile.self, from: data)
        guard file.format == HostListFile.formatName else { throw HostImportError.notAHostList }
        func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).lowercased() }

        var result = ImportResult()
        for incoming in file.gateways {
            let gatewayID: UUID
            if let existing = gateways.first(where: { key($0.host) == key(incoming.host) }) {
                gatewayID = existing.id
            } else {
                let added = Gateway(name: incoming.name.trimmingCharacters(in: .whitespaces),
                                    host: incoming.host.filter { $0 != "," && !$0.isWhitespace },
                                    transport: incoming.transport)
                gateways.append(added)
                gatewayID = added.id
                result.gateways += 1
            }
            for host in incoming.hosts {
                let address = host.address.trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { continue }
                var added = Host(address: address, label: host.label.trimmingCharacters(in: .whitespaces),
                                 gatewayID: gatewayID,
                                 dockLabel: host.dockLabel.trimmingCharacters(in: .whitespaces),
                                 labelColor: host.labelColor)
                if host.kind == .ssh {
                    added.kind = .ssh
                    added.sshUser = (host.sshUser ?? "").trimmingCharacters(in: .whitespaces)
                    added.port = host.port
                    added.sshAuth = host.sshAuth ?? .key
                    added.jumpHost = (host.jumpHost ?? "").trimmingCharacters(in: .whitespaces)
                    added.gatewayID = gateways.first(where: \.isDirect)?.id ?? gatewayID
                }
                // A file from elsewhere: an SSH host ssh would refuse, or read
                // as an option, is left out.
                if added.isSSH, (try? SSHCommand.arguments(for: added)) == nil {
                    result.skipped += 1
                    continue
                }
                let duplicate = added.isSSH
                    ? hosts.contains { $0.isSSH && key($0.address) == key(address) && $0.jumpHost == added.jumpHost
                                       && $0.sshUser == added.sshUser && $0.port == added.port }
                    : hosts.contains { $0.gatewayID == added.gatewayID && !$0.isSSH && key($0.address) == key(address) }
                if duplicate {
                    result.skipped += 1
                    continue
                }
                hosts.append(added)
                result.hosts += 1
            }
        }
        normalize()
        return result
    }
}

extension LauncherWindowController {
    func exportHosts() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "iGateway Hosts.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Gateways and hosts only. Accounts and passwords are not included."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.app.settings.exportedHosts().write(to: url, options: .atomic)
            } catch {
                self.alert("Could not export the hosts", error.localizedDescription)
            }
        }
    }

    func importHosts() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = try Data(contentsOf: url)
                var result = AppSettings.ImportResult()
                var failure: Error?
                self.app.update { s in
                    do { result = try s.importHosts(from: data) } catch { failure = error }
                }
                if let failure { throw failure }
                self.reload()
                self.alert("Hosts imported", Self.summary(result))
            } catch {
                self.alert("Could not import the hosts", error.localizedDescription)
            }
        }
    }

    private static func summary(_ result: AppSettings.ImportResult) -> String {
        func count(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        var parts = ["Added \(count(result.hosts, "host"))"]
        if result.gateways > 0 { parts[0] += " and \(count(result.gateways, "gateway"))" }
        parts[0] += "."
        if result.skipped > 0 {
            parts.append("\(count(result.skipped, "host")) \(result.skipped == 1 ? "was" : "were") already in the list.")
        }
        return parts.joined(separator: " ")
    }
}
