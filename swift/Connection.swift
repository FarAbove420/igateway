//
//  Connection.swift
//
//  One RDP session: wraps the C bridge, owns the frame surfaces, cursors and
//  the clipboard sync for that session.
//

import AppKit
import IOSurface

protocol ConnectionDelegate: AnyObject {
    func connection(_ connection: Connection, didChange state: Connection.State)
    func connection(_ connection: Connection, didDisplay surface: IOSurface, size: CGSize)
    func connection(_ connection: Connection, didSetCursor cursor: RemoteCursor)
    /// A certificate to ask the user about. Call `decide` once, on any thread.
    func connection(_ connection: Connection, verify certificate: CertificateInfo,
                    decide: @escaping (CertificateInfo.Decision) -> Void)
}

/// Carries an answer from the main thread back to the waiting session thread.
private final class Answer: @unchecked Sendable {
    var value = CertificateInfo.Decision.refuse
}

enum RemoteCursor {
    case system
    case hidden
    case image(NSImage, hotSpot: NSPoint, pixelSize: NSSize)
}

/// Double or triple buffered IOSurfaces, written on the session thread and
/// displayed by Core Animation without a copy.
///
/// Core Animation offers no public way to say "this surface changed", so a
/// surface is never written while it is on screen. Each surface remembers the
/// area it is missing, so only changed pixels are ever copied.
final class SurfacePool: @unchecked Sendable {
    private final class Entry {
        let surface: IOSurface
        var missing: CGRect
        init(_ surface: IOSurface, missing: CGRect) { self.surface = surface; self.missing = missing }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var front: IOSurface?
    private var pending: Entry?
    private var width = 0, height = 0

    private static let pixelFormat: UInt32 = 0x42475241   // 'BGRA'

    /// Copies the changed area. Returns a surface when a new one should be put
    /// on screen; nil while an earlier one is still waiting to be shown.
    func write(pixels: UnsafePointer<UInt8>, width w: Int, height h: Int, stride: Int,
               dirty: RDPRect, full: Bool) -> IOSurface? {
        lock.lock(); defer { lock.unlock() }

        var full = full
        if w != width || h != height {
            entries.removeAll()
            front = nil
            pending = nil
            width = w; height = h
            full = true
        }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let region = full ? bounds
            : CGRect(x: Int(dirty.x), y: Int(dirty.y), width: Int(dirty.width), height: Int(dirty.height))
                .intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return nil }

        let target: Entry
        if let pending {
            target = pending
        } else if let free = entries.first(where: { $0.surface !== front && !$0.surface.isInUse }) {
            target = free
        } else if entries.count < 3, let surface = Self.makeSurface(width: w, height: h) {
            target = Entry(surface, missing: bounds)
            entries.append(target)
        } else if let any = entries.first(where: { $0.surface !== front }) {
            target = any
        } else {
            return nil
        }

        let copy = target.missing.isNull ? region : target.missing.union(region).intersection(bounds)
        target.surface.lock(options: [], seed: nil)
        rdp_copy_rect_opaque(target.surface.baseAddress.assumingMemoryBound(to: UInt8.self),
                             target.surface.bytesPerRow, pixels, stride,
                             Int32(copy.minX), Int32(copy.minY),
                             Int32(copy.width), Int32(copy.height))
        target.surface.unlock(options: [], seed: nil)
        target.missing = .null
        for entry in entries where entry !== target {
            entry.missing = entry.missing.isNull ? region : entry.missing.union(region)
        }

        if pending != nil { return nil }
        pending = target
        return target.surface
    }

    /// Main thread, once the surface is the layer's contents.
    func didDisplay(_ surface: IOSurface) {
        lock.lock(); defer { lock.unlock() }
        front = surface
        if pending?.surface === surface { pending = nil }
    }

    private static func makeSurface(width: Int, height: Int) -> IOSurface? {
        guard let surface = IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: pixelFormat,
        ]) else { return nil }
        // The desktop is sRGB. Tagged, Core Animation shows it with correct
        // colours on wide-gamut Mac displays instead of oversaturated.
        if let plist = sRGB.copyPropertyList() {
            IOSurfaceSetValue(surface as IOSurfaceRef, kIOSurfaceColorSpace, plist)
        }
        return surface
    }
}

/// What the desktop view needs from a session. A protocol so the keyboard and
/// mouse handling can be tested without a server.
protocol InputSink: AnyObject {
    var isActive: Bool { get }
    func sendMouse(flags: UInt16, at point: CGPoint)
    func sendXButton(_ button: Int, down: Bool, at point: CGPoint)
    func sendWheel(horizontal: Bool, units: Int)
    func sendKey(scancode: UInt16, down: Bool, repeat isRepeat: Bool)
    /// Sets Caps Lock in Windows to the Mac's state.
    func syncLocks(capsLock: Bool)
    func sendText(_ text: String) -> Bool
    func scancode(forMacKey keyCode: UInt16) -> UInt16
}

extension InputSink {
    func sendKey(scancode: UInt16, down: Bool) { sendKey(scancode: scancode, down: down, repeat: false) }
}

final class Connection: InputSink {
    enum State: Equatable {
        case idle, connecting, connected
        case disconnected
        case failed(code: String)
    }

    let host: Host
    let gateway: Gateway
    let server: Account
    let gatewayAccount: Account?
    let settings: AppSettings
    let useDynamicResolution: Bool
    /// "nla" for real hosts. Only the local test server needs anything else.
    var securityProtocol = "nla"

    weak var delegate: ConnectionDelegate?
    private(set) var state: State = .idle
    /// This attempt's entry in the shared history.
    private var historyID: UUID?
    /// Why Windows ended the session, when it did so on purpose.
    private(set) var endReason: String?
    /// Which step failed and why, once the connection failed.
    private(set) var failure: ConnectionFailure?
    /// A certificate the user chose not to trust in this attempt.
    private var refusedCertificate: CertificateInfo?
    private(set) var remoteSize: CGSize = .zero
    let clipboard: ClipboardSync

    private var session: OpaquePointer?
    private var retained: Unmanaged<Connection>?
    fileprivate let surfaces = SurfacePool()
    private var cursors: [UInt32: RemoteCursor] = [:]   // main thread
    private let isISO = rdp_mac_keyboard_is_iso()

    init(host: Host, gateway: Gateway, server: Account, gatewayAccount: Account?, settings: AppSettings,
         useDynamicResolution: Bool) {
        self.host = host
        self.gateway = gateway
        self.server = server
        self.gatewayAccount = gatewayAccount
        self.settings = settings
        self.useDynamicResolution = useDynamicResolution
        self.clipboard = ClipboardSync()
        clipboard.connection = self
    }

    deinit {
        clipboard.connection = nil
    }

    var isActive: Bool { state == .connecting || state == .connected }

    // MARK: Lifecycle

    func connect(pixelSize: CGSize, scale: UInt32, password: String, gatewayPassword: String?) {
        state = .connecting
        historyID = History.begin(host: host, account: server)
        delegate?.connection(self, didChange: state)

        var arguments = [
            "igateway",
            "/v:\(host.address)",
            "/sec:\(securityProtocol)",
            "/size:\(Int(pixelSize.width) & ~1)x\(Int(pixelSize.height))",
            "/t:\(host.display)",
        ]
        if !gateway.isDirect {
            let address = gateway.host.trimmingCharacters(in: .whitespaces)
            arguments.append("/gateway:g:\(address),type:\(gateway.transport.rawValue)")
        }
        if useDynamicResolution { arguments.append("/dynamic-resolution") }
        if settings.keyboardLayout != .automatic {
            arguments.append("/kbd:layout:\(settings.keyboardLayout.rawValue)")
        }
        if settings.sound { arguments.append("/sound:sys:mac") }
        if settings.shareFolder {
            // Commas would split the /drive: value, so a path with one is skipped.
            let path = settings.sharedFolderPath
            if !path.contains(",") {
                let name = (path as NSString).lastPathComponent
                arguments.append("/drive:\(name.isEmpty ? "Mac" : name),\(path)")
            }
        }

        // No passwords in here: those go straight into FreeRDP's settings.
        AppLog.write("Connecting to \(host.display) as \(server.display)"
                     + (gatewayAccount.map { ", gateway account \($0.display)" } ?? "")
                     + ": " + arguments.dropFirst().joined(separator: " "))

        let cStrings = arguments.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv = cStrings.map { UnsafePointer<CChar>($0) }

        let box = Unmanaged.passRetained(self)
        retained = box
        let callbacks = Self.makeCallbacks(user: box.toOpaque())

        let gw = gatewayAccount
        let created: OpaquePointer? = server.username.withCString { user in
            server.domain.withCString { domain in
                password.withCString { pass in
                    (gw?.username ?? "").withCString { gwUser in
                        (gw?.domain ?? "").withCString { gwDomain in
                            (gatewayPassword ?? "").withCString { gwPass in
                                var creds = RDPCredentials(
                                    username: user, domain: domain, password: pass,
                                    gatewayUsername: gw == nil ? nil : gwUser,
                                    gatewayDomain: gw == nil ? nil : gwDomain,
                                    gatewayPassword: gw == nil ? nil : gwPass,
                                    scaleFactor: scale)
                                var cb = callbacks
                                return argv.withUnsafeMutableBufferPointer { buffer in
                                    rdp_session_create(buffer.baseAddress, Int32(buffer.count),
                                                       &creds, &cb)
                                }
                            }
                        }
                    }
                }
            }
        }

        guard let created else {
            fail(code: "")
            return
        }
        session = created
        if let error = rdp_session_error(created) {
            fail(code: String(cString: error))
            return
        }
        if !rdp_session_start(created) {
            fail(code: "")
        }
    }

    private func fail(code: String) {
        AppLog.write("\(host.display): could not start \(code.isEmpty ? "(no error code)" : code)")
        failure = ConnectionFailure.plain(code: code)
        state = .failed(code: code)
        record(state)
        delegate?.connection(self, didChange: state)
        teardown()
    }

    /// Keeps the shared history in step with this attempt.
    private func record(_ state: State) {
        guard let id = historyID else { return }
        History.update(id) { entry in
            switch state {
            case .connecting:
                entry.state = .connecting
            case .connected:
                entry.state = .connected
                entry.connected = Date()
            case .disconnected:
                guard entry.state != .failed else { return }
                entry.state = .ended
                entry.ended = Date()
                entry.detail = endReason
            case .failed(let code):
                entry.state = .failed
                entry.ended = Date()
                entry.detail = failure?.headline ?? ConnectError.explain(code)
            case .idle:
                break
            }
        }
    }

    /// Stops the session off the main thread; stopping waits for the session
    /// thread to finish.
    func disconnect() {
        if isActive { AppLog.write("\(host.display): closed") }
        teardown()
        if state != .disconnected {
            state = .disconnected
            record(state)
            delegate?.connection(self, didChange: state)
        }
    }

    private func teardown() {
        guard let session else {
            retained?.release(); retained = nil
            return
        }
        self.session = nil
        let box = retained
        retained = nil
        clipboard.sessionEnded()
        DispatchQueue.global(qos: .userInitiated).async {
            rdp_session_stop(session)
            rdp_session_free(session)
            DispatchQueue.main.async { box?.release() }
        }
    }

    // MARK: Bridge access for input and clipboard

    var handle: OpaquePointer? { session }

    func requestSize(pixels: CGSize, scale: UInt32) {
        guard let session else { return }
        rdp_session_request_size(session, Int32(pixels.width), Int32(pixels.height), scale)
    }

    var canResize: Bool { session.map { rdp_session_can_resize($0) } ?? false }

    func sendMouse(flags: UInt16, at point: CGPoint) {
        guard let session else { return }
        rdp_session_send_mouse(session, flags, UInt16(clamping: Int(point.x)), UInt16(clamping: Int(point.y)))
    }

    func sendXButton(_ button: Int, down: Bool, at point: CGPoint) {
        guard let session else { return }
        rdp_session_send_xbutton(session, Int32(button), down,
                                 UInt16(clamping: Int(point.x)), UInt16(clamping: Int(point.y)))
    }

    func sendWheel(horizontal: Bool, units: Int) {
        guard let session else { return }
        rdp_session_send_wheel(session, horizontal, Int32(units))
    }

    func sendKey(scancode: UInt16, down: Bool, repeat isRepeat: Bool) {
        guard let session, scancode != 0 else { return }
        rdp_session_send_key(session, scancode, down, isRepeat)
    }

    /// Num Lock stays on: a Mac keypad always types digits.
    func syncLocks(capsLock: Bool) {
        guard let session else { return }
        rdp_session_send_locks(session, capsLock, true)
    }

    /// False when the server does not take Unicode input.
    func sendText(_ text: String) -> Bool {
        guard let session else { return false }
        for unit in text.utf16 {
            if !rdp_session_send_unicode(session, unit, true) { return false }
            _ = rdp_session_send_unicode(session, unit, false)
        }
        return true
    }

    func scancode(forMacKey keyCode: UInt16) -> UInt16 {
        rdp_scancode_for_mac_keycode(keyCode, isISO)
    }

    // MARK: Callbacks from the session thread

    private static func me(_ user: UnsafeMutableRawPointer?) -> Connection? {
        guard let user else { return nil }
        return Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue()
    }

    private static func makeCallbacks(user: UnsafeMutableRawPointer) -> RDPCallbacks {
        var cb = RDPCallbacks()
        cb.user = user
        cb.frame = { user, pixels, width, height, stride, dirty, full in
            guard let me = Connection.me(user), let pixels else { return }
            guard let surface = me.surfaces.write(pixels: pixels, width: Int(width), height: Int(height),
                                                  stride: Int(stride), dirty: dirty, full: full) else { return }
            let size = CGSize(width: Int(width), height: Int(height))
            DispatchQueue.main.async {
                me.remoteSize = size
                me.delegate?.connection(me, didDisplay: surface, size: size)
                me.surfaces.didDisplay(surface)
            }
        }
        cb.state = { user, state, detail in
            guard let me = Connection.me(user) else { return }
            let code = detail.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { me.apply(state: state, code: code) }
        }
        cb.cursorNew = { user, id, bgra, width, height, hotX, hotY in
            guard let me = Connection.me(user), let bgra, width > 0, height > 0 else { return }
            guard let cursor = Connection.makeCursor(bgra: bgra, width: Int(width), height: Int(height),
                                                     hotX: Int(hotX), hotY: Int(hotY)) else { return }
            DispatchQueue.main.async { me.cursors[id] = cursor }
        }
        cb.cursorFree = { user, id in
            guard let me = Connection.me(user) else { return }
            DispatchQueue.main.async { me.cursors[id] = nil }
        }
        cb.cursorSet = { user, id in
            guard let me = Connection.me(user) else { return }
            DispatchQueue.main.async {
                let cursor: RemoteCursor
                switch id {
                case UInt32(RDP_CURSOR_DEFAULT): cursor = .system
                case UInt32(RDP_CURSOR_HIDDEN): cursor = .hidden
                default: cursor = me.cursors[id] ?? .system
                }
                me.delegate?.connection(me, didSetCursor: cursor)
            }
        }
        cb.clipReady = { user in Connection.me(user)?.clipboard.channelReady() }
        cb.clipServerFormats = { user, formats, count in
            guard let me = Connection.me(user), let formats else { return }
            var list: [(UInt32, String?)] = []
            for i in 0..<Int(count) {
                list.append((formats[i].id, formats[i].name.map { String(cString: $0) }))
            }
            me.clipboard.serverChanged(formats: list)
        }
        cb.clipData = { user, formatId, data, length, ok in
            guard let me = Connection.me(user) else { return }
            let bytes = (ok && data != nil && length > 0) ? Data(bytes: data!, count: length) : nil
            me.clipboard.received(formatId: formatId, data: bytes)
        }
        cb.clipProvide = { user, formatId, data, length in
            guard let me = Connection.me(user), let data, let length,
                  let bytes = me.clipboard.provide(formatId: formatId) else { return false }
            return Connection.handOver(bytes, data, length)
        }
        cb.clipFileProvide = { user, index, sizeOnly, offset, count, data, length in
            guard let me = Connection.me(user), let data, let length,
                  let bytes = me.clipboard.provideFile(index: Int(index), sizeOnly: sizeOnly,
                                                       offset: offset, count: Int(count)) else { return false }
            return Connection.handOver(bytes, data, length)
        }
        cb.clipFileData = { user, streamId, data, length, ok in
            guard let me = Connection.me(user) else { return }
            let bytes = (ok && data != nil) ? Data(bytes: data!, count: length) : nil
            me.clipboard.receivedFile(streamId: streamId, data: bytes)
        }
        // The session thread waits here while the user decides.
        cb.certificate = { user, certificate in
            guard let me = Connection.me(user), let certificate else { return 0 }
            let info = CertificateInfo(certificate.pointee)
            // What macOS trusts needs no question. Accepted for this connection
            // only, not stored, so expiry and revocation are checked every time.
            if info.trustedByMac {
                AppLog.write("\(me.host.display): certificate of \(info.address) is trusted by macOS")
                return CertificateInfo.Decision.trustOnce.rawValue
            }
            let answer = Answer()
            let decided = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                guard let delegate = me.delegate else { decided.signal(); return }
                delegate.connection(me, verify: info) { decision in
                    if decision == .refuse { me.refusedCertificate = info }
                    answer.value = decision
                    decided.signal()
                }
            }
            decided.wait()
            AppLog.write("\(me.host.display): certificate of \(info.address) (\(info.fingerprint)): \(answer.value)")
            return answer.value.rawValue
        }
        return cb
    }

    /// Hands bytes to the bridge as malloc'd memory, which the bridge frees.
    private static func handOver(_ bytes: Data,
                                 _ data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                                 _ length: UnsafeMutablePointer<Int>) -> Bool {
        let buffer = malloc(max(bytes.count, 1))!.assumingMemoryBound(to: UInt8.self)
        bytes.copyBytes(to: buffer, count: bytes.count)
        data.pointee = buffer
        length.pointee = bytes.count
        return true
    }

    private func apply(state raw: RDPSessionState, code: String) {
        var newState: State
        switch raw {
        case RDPSessionStateConnecting: newState = .connecting
        case RDPSessionStateConnected: newState = .connected
        case RDPSessionStateDisconnected: newState = .disconnected
        case RDPSessionStateFailed: newState = .failed(code: code)
        default: newState = .idle
        }
        // Signing out of Windows and the like end the session; they are no failure.
        if case .failed(let code) = newState, let reason = ConnectError.endReason(code) {
            endReason = reason
            newState = .disconnected
        }
        // Once the user disconnected, late events from the old session don't count.
        if state == .disconnected, newState != .disconnected { return }
        if newState == state { return }
        state = newState
        switch newState {
        case .failed(let code):
            var diagnosis = RDPDiagnosis()
            if let session, rdp_session_diagnosis(session, &diagnosis) {
                failure = ConnectionFailure.diagnose(diagnosis, code: code, host: host, gateway: gateway,
                                                     refused: refusedCertificate)
            } else {
                failure = ConnectionFailure.plain(code: code)
            }
            AppLog.write("\(host.display): failed \(code.isEmpty ? "(no error code)" : code): "
                         + "\(failure?.headline ?? ""), step \(failure?.failedStep.map { "\($0)" } ?? "unknown")")
        default: AppLog.write("\(host.display): \(newState)")
        }
        record(newState)
        delegate?.connection(self, didChange: state)
        if case .failed = newState { teardown() }
        if newState == .disconnected { teardown() }
    }

    private static func makeCursor(bgra: UnsafePointer<UInt8>, width: Int, height: Int,
                                   hotX: Int, hotY: Int) -> RemoteCursor? {
        let length = width * height * 4
        let data = Data(bytes: bgra, count: length)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // BGRA in memory, straight alpha.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)
            .union(.byteOrder32Little)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: sRGB,
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let size = NSSize(width: width, height: height)
        return .image(NSImage(cgImage: image, size: size),
                      hotSpot: NSPoint(x: hotX, y: hotY), pixelSize: size)
    }
}
