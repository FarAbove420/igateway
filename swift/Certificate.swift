//
//  Certificate.swift
//
//  Certificates FreeRDP could not verify itself. Its OpenSSL only knows the CA
//  file in /etc/ssl, which lags behind the Mac's trust store and lacks the
//  CAs an administrator or the user added. So macOS is asked first, the way
//  any Mac app checks a certificate. Only what macOS does not trust either is
//  shown to the user. Trusted certificates are stored by FreeRDP in
//  ~/.config/freerdp/server, so each one is asked about once.
//

import AppKit
import CryptoKit
import Security

struct CertificateInfo {
    /// FreeRDP's answers: store it, accept it for this connection, or refuse.
    enum Decision: UInt32 {
        case refuse = 0
        case trust = 1
        case trustOnce = 2
    }

    let host: String
    let port: UInt16
    /// The certificate and the chain the server sent, when FreeRDP gave them.
    let pem: String?
    let subject: String
    let issuer: String
    let fingerprint: String
    let isGateway: Bool
    let changed: Bool
    let mismatch: Bool
    let oldSubject: String?
    let oldIssuer: String?
    let oldFingerprint: String?

    /// Copies everything out of FreeRDP's strings, which only live for the call.
    init(_ c: RDPCertificate) {
        func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        host = text(c.host)
        port = c.port
        pem = c.isPEM ? text(c.fingerprint) : nil
        subject = text(c.subject)
        issuer = text(c.issuer)
        fingerprint = Self.fingerprint(text(c.fingerprint), isPEM: c.isPEM)
        isGateway = c.gateway
        changed = c.changed
        mismatch = c.mismatch
        oldSubject = c.oldSubject.map { String(cString: $0) }
        oldIssuer = c.oldIssuer.map { String(cString: $0) }
        oldFingerprint = c.oldFingerprint.map { Self.fingerprint(String(cString: $0), isPEM: c.oldIsPEM) }
    }

    /// The SHA-256 of the server's own certificate as browsers and Windows
    /// show it. FreeRDP hands over the certificate itself in PEM, followed by
    /// the rest of the chain.
    static func fingerprint(_ value: String, isPEM: Bool) -> String {
        guard isPEM, let der = certificates(inPEM: value).first else { return value }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Each certificate in a PEM text, in order, as DER.
    static func certificates(inPEM pem: String) -> [Data] {
        var result: [Data] = []
        var base64 = ""
        var inside = false
        for line in pem.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                inside = true
                base64 = ""
            } else if line.hasPrefix("-----END CERTIFICATE") {
                if let der = Data(base64Encoded: base64) { result.append(der) }
                inside = false
            } else if inside {
                base64 += line.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// Whether macOS trusts the certificate for this host: Apple's roots plus
    /// any an administrator or the user trusted, and the name must match.
    /// Missing intermediates may be fetched, as Safari would.
    var trustedByMac: Bool {
        guard let pem else { return false }
        let chain = Self.certificates(inPEM: pem).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !chain.isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
                == errSecSuccess, let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// "host", or "host:port" when the port is not the usual one.
    var address: String {
        port == (isGateway ? 443 : 3389) ? host : "\(host):\(port)"
    }
}

enum CertificatePrompt {
    static func present(_ info: CertificateInfo, on window: NSWindow,
                        done: @escaping (CertificateInfo.Decision) -> Void) {
        let alert = NSAlert()
        let who = info.isGateway ? "The gateway \(info.address)" : info.address
        let details = "Subject: \(info.subject)\nIssuer: \(info.issuer)\nSHA-256: \(info.fingerprint)"
        let answers: [CertificateInfo.Decision]
        if info.changed {
            alert.alertStyle = .critical
            alert.messageText = "The certificate of \(info.address) changed"
            var text = "\(who) presents a different certificate than the one trusted before. "
                + "That is normal after a renewal, but it can also mean someone is intercepting the connection."
            text += "\n\nNew:\n\(details)"
            text += "\n\nBefore:\nSubject: \(info.oldSubject ?? "")\nIssuer: \(info.oldIssuer ?? "")"
                + "\nSHA-256: \(info.oldFingerprint ?? "")"
            alert.informativeText = text
            // Cancel first, so Return does the safe thing.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Trust the New Certificate")
            answers = [.refuse, .trust]
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Trust the certificate of \(info.address)?"
            var text = "\(who) presents a certificate this Mac can't verify. "
                + "Windows servers often use their own, which is fine if you expected this server."
            if info.mismatch { text += "\n\nThe name on the certificate does not match the address." }
            alert.informativeText = text + "\n\n" + details
            alert.addButton(withTitle: "Trust")
            alert.addButton(withTitle: "Trust Once")
            alert.addButton(withTitle: "Cancel")
            answers = [.trust, .trustOnce, .refuse]
        }
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            done(answers.indices.contains(index) ? answers[index] : .refuse)
        }
    }
}
