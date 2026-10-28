//
//  Failure.swift
//
//  Turns how far a failed connection got into plain words: which step
//  failed and why, as far as FreeRDP and the gateway tell. The facts come
//  from the bridge (RDPDiagnosis): the connection stage, the gateway tunnel's
//  furthest state, the gateway's own reason code and logged sign-in errors.
//

import Foundation

struct ConnectionFailure {
    enum Step: Int, CaseIterable {
        case reachGateway, gatewayLogin, gatewayPolicy, gatewayToServer, reachServer, serverLogin, sessionStart
    }
    enum Status { case done, failed, notReached }
    enum Login { case server, gateway }

    let headline: String
    let detail: String
    let failedStep: Step?
    let steps: [(title: String, status: Status)]
    /// Which password to ask for again, when a sign-in was rejected.
    let login: Login?
    /// For "Copy Details": everything known, in one block.
    let technical: String

    static let serverLoginCodes: Set<String> = [
        "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_WRONG_PASSWORD", "ERRCONNECT_AUTHENTICATION_FAILED",
        "ERRCONNECT_NO_OR_MISSING_CREDENTIALS",
    ]
    static let accountCodes: Set<String> = [
        "ERRCONNECT_ACCOUNT_LOCKED_OUT", "ERRCONNECT_PASSWORD_EXPIRED", "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED",
        "ERRCONNECT_PASSWORD_MUST_CHANGE", "ERRCONNECT_ACCOUNT_DISABLED", "ERRCONNECT_ACCOUNT_EXPIRED",
        "ERRCONNECT_ACCOUNT_RESTRICTION", "ERRCONNECT_INSUFFICIENT_PRIVILEGES",
        "ERRCONNECT_LOGON_TYPE_NOT_GRANTED",
    ]
    static let unreachableCodes: Set<String> = ["ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_CONNECT_TRANSPORT_FAILED"]
    static let dnsCodes: Set<String> = ["ERRCONNECT_DNS_NAME_NOT_FOUND", "ERRCONNECT_DNS_ERROR"]
    static let tlsCodes: Set<String> = ["ERRCONNECT_TLS_CONNECT_FAILED"]

    /// The gateway's reason codes, from FreeRDP's libfreerdp/core/gateway/tsg.h.
    static let gatewayReasons: [UInt32: String] = [
        0x800759D8: "E_PROXY_INTERNALERROR", 0x800759DA: "E_PROXY_RAP_ACCESSDENIED",
        0x800759DB: "E_PROXY_NAP_ACCESSDENIED", 0x800759DD: "E_PROXY_TS_CONNECTFAILED",
        0x800759DF: "E_PROXY_ALREADYDISCONNECTED", 0x800759E9: "E_PROXY_CAPABILITYMISMATCH",
        0x800759ED: "E_PROXY_QUARANTINE_ACCESSDENIED", 0x800759EE: "E_PROXY_NOCERTAVAILABLE",
        0x800759F7: "E_PROXY_COOKIE_BADPACKET", 0x800759F8: "E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED",
        0x800759F9: "E_PROXY_UNSUPPORTED_AUTHENTICATION_METHOD", 0x000059E6: "E_PROXY_MAXCONNECTIONSREACHED",
        0x000059F6: "E_PROXY_SESSIONTIMEOUT", 0x000059FA: "E_PROXY_REAUTH_AUTHN_FAILED",
        0x000059FB: "E_PROXY_REAUTH_CAP_FAILED", 0x000059FC: "E_PROXY_REAUTH_RAP_FAILED",
    ]

    static let tunnelStates = ["started", "signed in", "allowed by policy", "server reached", "ready"]

    /// - Parameters:
    ///   - code: FreeRDP's error name as the session reported it.
    ///   - refused: the certificate the user chose not to trust, if any.
    static func diagnose(_ d: RDPDiagnosis, code: String, host: Host, gateway: Gateway,
                         refused: CertificateInfo?) -> ConnectionFailure {
        let viaGateway = !gateway.isDirect
        let server = host.title
        let gw = gateway.host
        let progress = Int(d.gatewayProgress)
        let reason = gatewayReasons[d.gatewayReason]
        let stage = d.stage

        func result(_ step: Step?, _ headline: String, _ detail: String, login: Login? = nil) -> ConnectionFailure {
            ConnectionFailure(headline: headline, detail: detail, failedStep: step,
                              steps: steps(failed: step, viaGateway: viaGateway, server: server, gateway: gw),
                              login: login,
                              technical: technical(d, code: code, host: host, gateway: gateway, failed: step))
        }

        // Things the user decided.
        if let refused {
            return result(refused.isGateway ? .reachGateway : (viaGateway ? .gatewayToServer : .reachServer),
                          "Certificate not trusted",
                          "You chose not to trust the certificate of \(refused.address), so the connection was stopped.")
        }
        // The client only ever looks up the gateway's name when there is one.
        if dnsCodes.contains(code) {
            let name = viaGateway ? gw : host.address
            return result(viaGateway ? .reachGateway : .reachServer, "Couldn't find \(name)",
                          "The name \(name) couldn't be looked up. Check the spelling, and your network or VPN.")
        }

        if viaGateway {
            switch reason {
            case "E_PROXY_RAP_ACCESSDENIED"?, "E_PROXY_REAUTH_RAP_FAILED"?:
                return result(.gatewayPolicy, "Not allowed to this server",
                              "The gateway \(gw) doesn't allow your account to connect to \(server).")
            case "E_PROXY_NAP_ACCESSDENIED"?, "E_PROXY_QUARANTINE_ACCESSDENIED"?:
                return result(.gatewayPolicy, "Refused by the gateway's health policy",
                              "The gateway \(gw) refused this Mac because of its health policy.")
            case "E_PROXY_REAUTH_CAP_FAILED"?:
                return result(.gatewayPolicy, "Not allowed through the gateway",
                              "The gateway \(gw) doesn't allow your account to connect through it.")
            case "E_PROXY_TS_CONNECTFAILED"?:
                return result(.gatewayToServer, "The gateway couldn't reach \(server)",
                              "The gateway \(gw) couldn't connect to \(server). It may be off, or not accepting remote desktop connections.")
            case "E_PROXY_MAXCONNECTIONSREACHED"?:
                return result(.gatewayPolicy, "The gateway is full",
                              "The gateway \(gw) has reached its maximum number of connections.")
            case "E_PROXY_SESSIONTIMEOUT"?:
                return result(.gatewayPolicy, "The gateway's time limit was reached",
                              "The gateway \(gw) ended the connection because its session time limit was reached.")
            case "E_PROXY_REAUTH_AUTHN_FAILED"?:
                return result(.gatewayLogin, "Gateway sign-in failed",
                              "The gateway \(gw) asked you to sign in again, and that failed.", login: .gateway)
            case "E_PROXY_CAPABILITYMISMATCH"?, "E_PROXY_UNSUPPORTED_AUTHENTICATION_METHOD"?,
                 "E_PROXY_NOCERTAVAILABLE"?, "E_PROXY_COOKIE_BADPACKET"?,
                 "E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED"?:
                return result(.gatewayLogin, "Unsupported gateway sign-in",
                              "The gateway \(gw) wants a sign-in method this app doesn't support.")
            case "E_PROXY_INTERNALERROR"?:
                return result(nil, "The gateway reported an error",
                              "The gateway \(gw) reported an internal error. Try again, or ask its administrator.")
            default:
                break
            }

            let signInFailed = (d.authError && d.authErrorProgress < 1)
                || (progress < 1 && (code == "ERRCONNECT_ACCESS_DENIED" || serverLoginCodes.contains(code)))
            if signInFailed {
                let detail = code == "ERRCONNECT_ACCESS_DENIED" || serverLoginCodes.contains(code)
                    ? "The gateway \(gw) rejected the user name or password."
                    : "Signing in to the gateway \(gw) didn't work."
                return result(.gatewayLogin, "Gateway sign-in failed", detail, login: .gateway)
            }
            switch progress {
            case 1:
                return result(.gatewayPolicy, "Not allowed through the gateway",
                              "The gateway \(gw) signed you in, but its policy doesn't allow this connection.")
            case 2:
                return result(.gatewayToServer, "The gateway couldn't reach \(server)",
                              "The gateway \(gw) allowed the connection but couldn't open one to \(server).")
            case 0:
                return result(.gatewayLogin, "Gateway sign-in failed",
                              "The gateway \(gw) answered, but signing in to it didn't work.", login: .gateway)
            case -1 where stage == RDPStageTransport:
                if tlsCodes.contains(code) {
                    return result(.reachGateway, "Couldn't connect securely to the gateway",
                                  "A secure connection to the gateway \(gw) couldn't be set up.")
                }
                return result(.reachGateway, "Couldn't reach the gateway",
                              "The gateway \(gw) didn't respond. Check your network or VPN.")
            default:
                break   // tunnel ready, or a gateway that doesn't report its states: the server's turn
            }
        }

        // The server itself, directly or through a working tunnel.
        if serverLoginCodes.contains(code) {
            return result(.serverLogin, "Sign-in rejected",
                          "\(server) rejected the user name or password.", login: .server)
        }
        if accountCodes.contains(code) {
            return result(.serverLogin, "Sign-in not possible", ConnectError.explain(code), login: .server)
        }
        switch stage {
        case RDPStageTransport:
            if tlsCodes.contains(code) {
                return result(viaGateway ? .gatewayToServer : .reachServer, "Couldn't connect securely",
                              "A secure connection to \(server) couldn't be set up.")
            }
            if code == "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED" {
                return result(viaGateway ? .gatewayToServer : .reachServer, "Couldn't agree on security",
                              "\(server) and this app couldn't agree on how to secure the connection.")
            }
            if viaGateway {
                return result(.gatewayToServer, "The connection through the gateway closed",
                              "The connection through \(gw) closed before \(server) answered.")
            }
            return result(.reachServer, "Couldn't reach \(server)",
                          "Nothing answered at \(host.address). Check the address, that the computer is on, and your network or VPN.")
        case RDPStageLogin:
            return result(.serverLogin, "Sign-in failed", "Signing in to \(server) didn't work. "
                          + ConnectError.explain(code), login: .server)
        case RDPStageLicensing:
            return result(.sessionStart, "No remote desktop license",
                          "\(server) couldn't license this session.")
        default:
            if code == "ERRCONNECT_ACTIVATION_TIMEOUT" {
                return result(.sessionStart, "The session didn't start",
                              "\(server) accepted you but the session never started.")
            }
            return result(.sessionStart, "The session couldn't start",
                          "\(server) ended the connection while the session was starting. " + ConnectError.explain(code))
        }
    }

    /// Without a diagnosis, for failures before FreeRDP even started.
    static func plain(code: String) -> ConnectionFailure {
        ConnectionFailure(headline: "Could not connect", detail: ConnectError.explain(code), failedStep: nil,
                          steps: [], login: nil, technical: "Error: \(code.isEmpty ? "none reported" : code)")
    }

    static func steps(failed: Step?, viaGateway: Bool, server: String, gateway: String)
        -> [(title: String, status: Status)] {
        guard let failed else { return [] }
        let order: [(Step, String)] = viaGateway
            ? [(.reachGateway, "Reach gateway \(gateway)"), (.gatewayLogin, "Sign in to the gateway"),
               (.gatewayPolicy, "Gateway allows the connection"), (.gatewayToServer, "Gateway reaches \(server)"),
               (.serverLogin, "Sign in to \(server)"), (.sessionStart, "Start the session")]
            : [(.reachServer, "Reach \(server)"), (.serverLogin, "Sign in"), (.sessionStart, "Start the session")]
        guard let index = order.firstIndex(where: { $0.0 == failed }) else { return [] }
        return order.enumerated().map { i, step in
            (step.1, i < index ? .done : (i == index ? .failed : .notReached))
        }
    }

    static func technical(_ d: RDPDiagnosis, code: String, host: Host, gateway: Gateway, failed: Step?) -> String {
        func text<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = [
            "iGateway.exe \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Host: \(host.display)" + (gateway.isDirect ? ", direct" : " through \(gateway.host) (\(gateway.transport.label))"),
            "Failed step: \(failed.map { "\($0)" } ?? "unknown")",
            "Error: \(code.isEmpty ? text(d.errorName) : code) (0x\(String(d.errorCode, radix: 16, uppercase: true)))",
            "Connection state: \(text(d.stateName))",
        ]
        if !gateway.isDirect {
            let progress = Int(d.gatewayProgress)
            lines.append("Gateway tunnel: " + (tunnelStates.indices.contains(progress) ? tunnelStates[progress] : "no state reported"))
            if d.gatewayReason != 0 {
                lines.append("Gateway reason: \(gatewayReasons[d.gatewayReason] ?? "unknown") (0x\(String(d.gatewayReason, radix: 16, uppercase: true)))")
            }
        }
        if d.authError { lines.append("A sign-in error was logged") }
        let recent = text(d.details).trimmingCharacters(in: .whitespacesAndNewlines)
        if !recent.isEmpty { lines.append("Recent errors:\n" + recent) }
        return lines.joined(separator: "\n")
    }
}
