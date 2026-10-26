//
//  Clipboard.swift
//
//  Mac clipboard <-> Windows clipboard over the cliprdr channel, MS-RDPECLIP.
//
//  Text is fetched as soon as something is copied in Windows, because it is
//  small and should still paste after the session closes. Images and files are
//  promised to the Mac pasteboard and only transferred when something actually
//  pastes them, so copying a big file inside Windows never drags it to the Mac.
//
//  A clipboard written from one session is never announced back to that same
//  session. Otherwise copying in Excel and pasting in Excel would round-trip
//  through the Mac and lose Excel's own formats.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

// Predefined Windows clipboard formats.
private let CF_TEXT: UInt32 = 1
private let CF_DIB: UInt32 = 8
private let CF_UNICODETEXT: UInt32 = 13
private let CF_DIBV5: UInt32 = 17

// Ids for our registered formats. A client picks its own (>= 0xC000) and
// sends the name alongside.
private let ID_PNG: UInt32 = 0xC0A0
private let ID_FILES: UInt32 = 0xC0A1
private let NAME_PNG = "PNG"
private let NAME_FILES = "FileGroupDescriptorW"

private let CB_STREAM_FILECLIP_ENABLED: UInt32 = 0x0000_0004
private let CB_HUGE_FILE_SUPPORT_ENABLED: UInt32 = 0x0000_0020

private let entryType = NSPasteboard.PasteboardType("igateway.entry")
/// On every pasteboard write by a session, so the other session processes
/// recognise it and leave its promises alone.
private let sessionType = NSPasteboard.PasteboardType("igateway.session")

/// Windows clipboard pixels are sRGB. Device RGB would push them through the
/// display's wide gamut and shift the colours.
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// What the Mac clipboard held at one changeCount.
struct LocalClipboard {
    let changeCount: Int
    var text: String?
    var image: Data?
    var imageIsPNG = false
    var files: [URL] = []
    /// The session that wrote this, if any.
    var origin: ObjectIdentifier?
}

/// Watches the Mac pasteboard for all sessions. Main thread only.
final class PasteboardWatcher {
    static let shared = PasteboardWatcher()

    private var timer: Timer?
    private var lastChangeCount = -1
    private var owners: [Int: ObjectIdentifier] = [:]
    private let syncs = NSHashTable<ClipboardSync>.weakObjects()
    private(set) var current = LocalClipboard(changeCount: -1)

    func register(_ sync: ClipboardSync) {
        syncs.add(sync)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.check()
            }
        }
        check()
        sync.localChanged(current)
    }

    func unregister(_ sync: ClipboardSync) {
        syncs.remove(sync)
        if syncs.allObjects.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Records that a session just wrote the pasteboard.
    func markOwned(changeCount: Int, by sync: ClipboardSync) {
        owners[changeCount] = ObjectIdentifier(sync)
    }

    /// Returns true if the Mac clipboard changed since the last look.
    @discardableResult
    func check() -> Bool {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return false }
        lastChangeCount = pb.changeCount
        current = read(pb)
        for sync in syncs.allObjects { sync.localChanged(current) }
        return true
    }

    private func read(_ pb: NSPasteboard) -> LocalClipboard {
        var snapshot = LocalClipboard(changeCount: pb.changeCount)
        snapshot.text = pb.string(forType: .string)
        if let owner = owners[pb.changeCount] {
            // Written by a session. Only its text was written eagerly; reading
            // the promised image or files would pull them from that server.
            snapshot.origin = owner
            return snapshot
        }
        if pb.types?.contains(sessionType) == true {
            // Written by a session in another process: same rule.
            snapshot.origin = ObjectIdentifier(PasteboardWatcher.self)
            return snapshot
        }

        owners = owners.filter { $0.key >= pb.changeCount - 50 }
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        snapshot.files = urls
        if urls.isEmpty {
            if let png = pb.data(forType: .png) {
                snapshot.image = png
                snapshot.imageIsPNG = true
            } else if let tiff = pb.data(forType: .tiff) {
                snapshot.image = tiff
            }
        }
        return snapshot
    }
}

/// One file or folder offered to Windows.
struct OutgoingFile {
    let url: URL
    let path: String          // relative, backslash separated
    let isDirectory: Bool
    let size: UInt64
    let modified: Date
}

/// One file or folder Windows offered.
struct RemoteFile {
    let path: String
    let isDirectory: Bool
    let size: UInt64?
}

final class ClipboardSync: NSObject, @unchecked Sendable {
    weak var connection: Connection?

    private let lock = NSLock()
    /// Held while queueing a waiter and sending its request, so requests from
    /// the main thread and the session thread cannot interleave. Answers are
    /// matched to requests purely by order.
    private let requestLock = NSLock()
    private var ready = false
    private var latestLocal = LocalClipboard(changeCount: -1)
    private var announced: LocalClipboard?
    private var outgoing: [OutgoingFile] = []
    private var openFile: (index: Int, handle: FileHandle)?

    private var generation = 0
    private var dataWaiters: [(format: UInt32, done: (Data?) -> Void)] = []
    private var fileWaiters: [UInt32: (Data?) -> Void] = [:]
    private var nextStream: UInt32 = 1

    // Remote clipboard, per generation.
    private var remoteImageFormat: UInt32?
    private var remoteFilesFormat: UInt32?
    private var remoteFiles: [RemoteFile] = []
    private var downloaded: [String: URL] = [:]
    private var downloadRoot: URL?

    // MARK: Lifecycle

    func attach() {
        DispatchQueue.main.async { PasteboardWatcher.shared.register(self) }
    }

    func sessionEnded() {
        lock.lock()
        ready = false
        generation += 1
        let waiters = dataWaiters.map(\.done) + Array(fileWaiters.values)
        dataWaiters.removeAll()
        fileWaiters.removeAll()
        try? openFile?.handle.close()
        openFile = nil
        lock.unlock()
        waiters.forEach { $0(nil) }
        DispatchQueue.main.async { PasteboardWatcher.shared.unregister(self) }
    }

    // MARK: Mac to Windows

    /// Session thread: the channel is up.
    func channelReady() {
        lock.lock()
        ready = true
        let local = latestLocal
        lock.unlock()
        announce(local)
    }

    /// Main thread: the Mac clipboard changed.
    func localChanged(_ snapshot: LocalClipboard) {
        lock.lock()
        latestLocal = snapshot
        let isReady = ready
        lock.unlock()
        guard isReady, snapshot.origin != ObjectIdentifier(self) else { return }
        announce(snapshot)
    }

    private func announce(_ snapshot: LocalClipboard) {
        guard let handle = connection?.handle else { return }
        let serverFlags = rdp_session_clip_server_flags(handle)

        var formats: [(UInt32, String?)] = []
        if snapshot.text != nil { formats.append((CF_UNICODETEXT, nil)) }
        if snapshot.image != nil {
            formats.append((CF_DIB, nil))
            formats.append((ID_PNG, NAME_PNG))
        }
        if !snapshot.files.isEmpty, serverFlags & CB_STREAM_FILECLIP_ENABLED != 0 {
            formats.append((ID_FILES, NAME_FILES))
        }

        lock.lock()
        announced = snapshot
        outgoing = []
        try? openFile?.handle.close()
        openFile = nil
        lock.unlock()

        // The names have to stay alive for the duration of the call.
        let names = formats.map { $0.1.map { strdup($0) } ?? nil }
        defer { names.forEach { free($0) } }
        var list = formats.enumerated().map { i, f in RDPClipFormat(id: f.0, name: names[i]) }
        _ = rdp_session_clip_announce(handle, &list, Int32(list.count))
    }

    /// Session thread: Windows is pasting.
    func provide(formatId: UInt32) -> Data? {
        lock.lock()
        let snapshot = announced
        lock.unlock()
        guard let snapshot else { return nil }

        switch formatId {
        case CF_UNICODETEXT:
            return snapshot.text.map(Self.windowsText)
        case CF_DIB:
            return snapshot.image.flatMap(Self.dib(fromImageData:))
        case ID_PNG:
            guard let image = snapshot.image else { return nil }
            return snapshot.imageIsPNG ? image : Self.png(fromImageData: image)
        case ID_FILES:
            return fileList(for: snapshot.files)
        default:
            return nil
        }
    }

    /// Windows wants CRLF line ends and a terminating NUL, as UTF-16LE.
    static func windowsText(_ text: String) -> Data {
        let crlf = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        var data = Data()
        for unit in crlf.utf16 { withUnsafeBytes(of: unit.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: [0, 0])
        return data
    }

    /// Builds the packed file list, MS-RDPECLIP 2.2.5.2.3, and remembers the
    /// files so their contents can be served by index.
    private func fileList(for urls: [URL]) -> Data? {
        guard let handle = connection?.handle else { return nil }
        let huge = rdp_session_clip_server_flags(handle) & CB_HUGE_FILE_SUPPORT_ENABLED != 0
        var files: [OutgoingFile] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        func add(_ url: URL, path: String) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let size = UInt64(values?.fileSize ?? 0)
            // Without huge-file support a Windows server can hang on files of
            // 2 GB or more (FreeRDP cliprdr_utils.c, Microsoft KB 2258090).
            if !isDir, !huge, size >= 0x8000_0000 { return }
            files.append(OutgoingFile(url: url, path: path, isDirectory: isDir, size: size,
                                      modified: values?.contentModificationDate ?? Date()))
            guard isDir, let children = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return }
            for case let child as URL in children {
                guard child.path.hasPrefix(url.path) else { continue }
                let relative = child.path.dropFirst(url.path.count).split(separator: "/").joined(separator: "\\")
                let childValues = try? child.resourceValues(forKeys: Set(keys))
                let childIsDir = childValues?.isDirectory ?? false
                let childSize = UInt64(childValues?.fileSize ?? 0)
                if !childIsDir, !huge, childSize >= 0x8000_0000 { continue }
                files.append(OutgoingFile(url: child, path: path + "\\" + relative, isDirectory: childIsDir,
                                          size: childSize,
                                          modified: childValues?.contentModificationDate ?? Date()))
            }
        }
        for url in urls { add(url, path: url.lastPathComponent) }
        guard !files.isEmpty else { return nil }

        lock.lock()
        outgoing = files
        try? openFile?.handle.close()
        openFile = nil
        lock.unlock()

        var data = Data()
        var count = UInt32(files.count).littleEndian
        data.append(Data(bytes: &count, count: 4))
        for file in files { data.append(Self.descriptor(for: file)) }
        return data
    }

    /// FILEDESCRIPTORW as FreeRDP's cliprdr_write_filedescriptor lays it out:
    /// flags 0, reserved 4..35, attributes 36, reserved 40..55, write time 56,
    /// size high 64, size low 68, name 72 (520 bytes). 592 bytes in total.
    static func descriptor(for file: OutgoingFile) -> Data {
        var d = Data(count: 592)
        func put32(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        func put64(_ value: UInt64, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(offset..<offset + 8, with: $0) }
        }
        let FD_ATTRIBUTES: UInt32 = 0x4, FD_WRITESTIME: UInt32 = 0x20
        let FD_FILESIZE: UInt32 = 0x40, FD_SHOWPROGRESSUI: UInt32 = 0x4000
        put32(FD_ATTRIBUTES | FD_WRITESTIME | FD_FILESIZE | FD_SHOWPROGRESSUI, at: 0)
        put32(file.isDirectory ? 0x10 : 0x80, at: 36)   // FILE_ATTRIBUTE_DIRECTORY / NORMAL
        // FILETIME counts 100 ns intervals since 1601.
        let filetime = UInt64(max(0, (file.modified.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
        put64(filetime, at: 56)
        put32(UInt32(file.size >> 32), at: 64)
        put32(UInt32(file.size & 0xFFFF_FFFF), at: 68)
        let name = Array(file.path.utf16.prefix(259))
        for (i, unit) in name.enumerated() {
            withUnsafeBytes(of: unit.littleEndian) { d.replaceSubrange(72 + i * 2..<72 + i * 2 + 2, with: $0) }
        }
        return d
    }

    /// Session thread: Windows is reading one of our files.
    func provideFile(index: Int, sizeOnly: Bool, offset: UInt64, count: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < outgoing.count else { return nil }
        let file = outgoing[index]
        if sizeOnly {
            var size = file.size.littleEndian
            return Data(bytes: &size, count: 8)
        }
        if file.isDirectory { return Data() }
        if openFile?.index != index {
            try? openFile?.handle.close()
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
            openFile = (index, handle)
        }
        guard let handle = openFile?.handle else { return nil }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }

    // MARK: Windows to Mac

    /// Session thread: something was copied in Windows.
    func serverChanged(formats: [(UInt32, String?)]) {
        let ids = Set(formats.map(\.0))
        let named = Dictionary(formats.compactMap { f in f.1.map { ($0, f.0) } },
                               uniquingKeysWith: { a, _ in a })

        lock.lock()
        generation += 1
        let gen = generation
        remoteImageFormat = named[NAME_PNG]
            ?? (ids.contains(CF_DIBV5) ? CF_DIBV5 : nil)
            ?? (ids.contains(CF_DIB) ? CF_DIB : nil)
        remoteFilesFormat = named[NAME_FILES]
        remoteFiles = []
        downloaded = [:]
        if let root = downloadRoot { try? FileManager.default.removeItem(at: root) }
        downloadRoot = nil
        lock.unlock()

        let textFormat: UInt32? = ids.contains(CF_UNICODETEXT) ? CF_UNICODETEXT
            : (ids.contains(CF_TEXT) ? CF_TEXT : nil)

        // Fetch the small things now: the text, and the list of files.
        func finish(text: String?) {
            lock.lock()
            let filesFormat = remoteFilesFormat
            lock.unlock()
            if let filesFormat {
                request(filesFormat) { [weak self] data in
                    guard let self else { return }
                    let files = data.map(Self.parseFileList) ?? []
                    self.lock.lock()
                    guard gen == self.generation else { self.lock.unlock(); return }
                    self.remoteFiles = files
                    self.lock.unlock()
                    self.publish(generation: gen, text: text)
                }
            } else {
                publish(generation: gen, text: text)
            }
        }

        if let textFormat {
            request(textFormat) { data in
                let text = data.map { textFormat == CF_UNICODETEXT ? Self.macText(utf16: $0) : Self.macText(ansi: $0) }
                finish(text: text)
            }
        } else {
            finish(text: nil)
        }
    }

    private func request(_ format: UInt32, done: @escaping (Data?) -> Void) {
        guard let handle = connection?.handle else { done(nil); return }
        requestLock.lock()
        lock.lock()
        dataWaiters.append((format, done))
        lock.unlock()
        let sent = rdp_session_clip_request(handle, format)
        if !sent {
            lock.lock()
            if let i = dataWaiters.lastIndex(where: { $0.format == format }) { dataWaiters.remove(at: i) }
            lock.unlock()
        }
        requestLock.unlock()
        if !sent { done(nil) }
    }

    /// Session thread: answer to a format request. Answers come back in the
    /// order they were asked for.
    func received(formatId: UInt32, data: Data?) {
        lock.lock()
        let waiter = dataWaiters.isEmpty ? nil : dataWaiters.removeFirst()
        lock.unlock()
        waiter?.done(data)
    }

    func receivedFile(streamId: UInt32, data: Data?) {
        lock.lock()
        let waiter = fileWaiters.removeValue(forKey: streamId)
        lock.unlock()
        waiter?(data)
    }

    static func macText(utf16 data: Data) -> String {
        let bytes = [UInt8](data)
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let unit = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        return String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func macText(ansi data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }
        return (String(data: bytes, encoding: .windowsCP1252) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Writes what Windows copied to the Mac pasteboard. Text directly, images
    /// and files as promises.
    private func publish(generation gen: Int, text: String?) {
        lock.lock()
        let imageFormat = remoteImageFormat
        let files = remoteFiles
        let current = generation
        lock.unlock()
        guard gen == current else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            var items: [NSPasteboardItem] = []
            let topLevel = files.filter { !$0.path.contains("\\") }

            if !topLevel.isEmpty {
                for entry in topLevel {
                    let item = NSPasteboardItem()
                    item.setString(entry.path, forType: entryType)
                    item.setDataProvider(self, forTypes: [.fileURL])
                    items.append(item)
                }
            } else {
                let item = NSPasteboardItem()
                if let text { item.setString(text, forType: .string) }
                if imageFormat != nil { item.setDataProvider(self, forTypes: [.png, .tiff]) }
                if text != nil || imageFormat != nil { items.append(item) }
            }
            guard !items.isEmpty else { return }
            items[0].setString("\(ProcessInfo.processInfo.processIdentifier)", forType: sessionType)

            pb.clearContents()
            pb.writeObjects(items)
            PasteboardWatcher.shared.markOwned(changeCount: pb.changeCount, by: self)
            PasteboardWatcher.shared.check()
        }
    }

    // MARK: Waiting for answers on the main thread

    /// Blocks the calling thread until the session thread answers. Only used
    /// when something on the Mac is actually pasting a promise, and the
    /// session thread never waits on the main thread, so this cannot deadlock.
    private func fetchSync(_ format: UInt32, timeout: TimeInterval = 15) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        request(format) { data in result = data; semaphore.signal() }
        return semaphore.wait(timeout: .now() + timeout) == .success ? result : nil
    }

    private func fetchFileSync(index: Int, sizeOnly: Bool, offset: UInt64, count: Int,
                               timeout: TimeInterval = 60) -> Data? {
        guard let handle = connection?.handle else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        lock.lock()
        let stream = nextStream
        nextStream &+= 1
        fileWaiters[stream] = { data in result = data; semaphore.signal() }
        lock.unlock()
        guard rdp_session_clip_request_file(handle, stream, UInt32(index), sizeOnly, offset, UInt32(count)) else {
            lock.lock(); fileWaiters[stream] = nil; lock.unlock()
            return nil
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); fileWaiters[stream] = nil; lock.unlock()
            return nil
        }
        return result
    }

    // MARK: Remote files

    static func parseFileList(_ data: Data) -> [RemoteFile] {
        guard data.count >= 4 else { return [] }
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        let count = Int(u32(0))
        var files: [RemoteFile] = []
        for i in 0..<count {
            let base = 4 + i * 592
            guard base + 592 <= bytes.count else { break }
            let flags = u32(base)
            let attributes = u32(base + 36)
            let size = UInt64(u32(base + 64)) << 32 | UInt64(u32(base + 68))
            var units: [UInt16] = []
            var o = base + 72
            while o + 1 < base + 592 {
                let unit = UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
                if unit == 0 { break }
                units.append(unit)
                o += 2
            }
            let path = String(decoding: units, as: UTF16.self)
            guard !path.isEmpty else { continue }
            files.append(RemoteFile(path: path, isDirectory: attributes & 0x10 != 0,
                                    size: flags & 0x40 != 0 ? size : nil))
        }
        return files
    }

    /// Main thread, from a paste: brings one copied file or folder over.
    private func download(entry: String) -> URL? {
        lock.lock()
        let files = remoteFiles
        let gen = generation
        if let done = downloaded[entry] { lock.unlock(); return done }
        if downloadRoot == nil {
            downloadRoot = Store.clipboardCache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        let root = downloadRoot!
        lock.unlock()

        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        for (index, file) in files.enumerated()
        where file.path == entry || file.path.hasPrefix(entry + "\\") {
            // Never let a remote name escape the download folder: split on
            // both separators, drop dot components, then check where it lands.
            let parts = file.path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
                .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            let local = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
            guard local.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }

            if file.isDirectory {
                try? fm.createDirectory(at: local, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: local.path, contents: nil),
                  let out = try? FileHandle(forWritingTo: local) else { return nil }
            defer { try? out.close() }

            var size = file.size
            if size == nil, let raw = fetchFileSync(index: index, sizeOnly: true, offset: 0, count: 8),
               raw.count >= 8 {
                size = raw.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            }
            guard let total = size else { return nil }
            var offset: UInt64 = 0
            while offset < total {
                lock.lock(); let stillCurrent = gen == generation; lock.unlock()
                guard stillCurrent else { return nil }
                let chunk = Int(min(UInt64(4 << 20), total - offset))
                guard let data = fetchFileSync(index: index, sizeOnly: false, offset: offset, count: chunk),
                      !data.isEmpty else { return nil }
                // The throwing write: the plain one raises an exception (a crash)
                // when the disk is full.
                guard (try? out.write(contentsOf: data)) != nil else { return nil }
                offset += UInt64(data.count)
            }
        }

        let result = root.appendingPathComponent(entry.split(separator: "\\").last.map(String.init) ?? entry)
        lock.lock()
        if gen == generation { downloaded[entry] = result }
        lock.unlock()
        return result
    }

    // MARK: Images

    /// CF_DIB for Windows: 32 bpp BI_RGB, bottom-up, flattened onto white so
    /// apps that ignore alpha don't show black.
    static func dib(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = context.data else { return nil }

        var out = Data(capacity: 40 + w * h * 4)
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put32(40); put32(UInt32(w)); put32(UInt32(h))   // positive height: bottom-up
        put16(1); put16(32); put32(0)                    // planes, bpp, BI_RGB
        put32(UInt32(w * h * 4)); put32(2835); put32(2835); put32(0); put32(0)
        let rowBytes = context.bytesPerRow
        for row in stride(from: h - 1, through: 0, by: -1) {
            out.append(pixels.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: w * 4)
        }
        return out
    }

    static func png(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image, as: .png)
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// CF_DIB or CF_DIBV5 from Windows to a CGImage. 24 and 32 bpp are decoded
    /// directly, because 32 bpp BI_RGB often carries an alpha byte of 0, which
    /// ImageIO would show as fully transparent. Anything else is wrapped as a
    /// BMP file and left to ImageIO.
    static func image(fromDIB data: Data) -> CGImage? {
        let b = [UInt8](data)
        guard b.count >= 40 else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o+1]) << 8 }
        let headerSize = Int(u32(0))
        let width = Int(Int32(bitPattern: u32(4)))
        let rawHeight = Int(Int32(bitPattern: u32(8)))
        let bpp = Int(u16(14))
        let compression = u32(16)
        let colorsUsed = Int(u32(32))
        let height = abs(rawHeight)
        let topDown = rawHeight < 0
        // Capped before any arithmetic, so a crafted header can't overflow it.
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              headerSize >= 40, headerSize < b.count else { return nil }

        var masks = 0
        if headerSize == 40, compression == 3 { masks = 12 }
        if headerSize == 40, compression == 6 { masks = 16 }
        let palette = bpp <= 8 ? (colorsUsed > 0 ? colorsUsed : 1 << bpp) * 4 : colorsUsed * 4
        let pixelOffset = headerSize + masks + palette

        if (bpp == 32 || bpp == 24), compression == 0 || compression == 3 {
            let rowStride = ((width * bpp + 31) / 32) * 4
            guard pixelOffset + rowStride * height <= b.count else { return nil }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            var anyAlpha = false
            let alphaMask = headerSize >= 56 ? u32(52) : 0
            for y in 0..<height {
                let srcRow = topDown ? y : height - 1 - y
                for x in 0..<width {
                    let s = pixelOffset + srcRow * rowStride + x * (bpp / 8)
                    let d = (y * width + x) * 4
                    rgba[d] = b[s + 2]; rgba[d + 1] = b[s + 1]; rgba[d + 2] = b[s]
                    rgba[d + 3] = bpp == 32 ? b[s + 3] : 255
                    if bpp == 32, b[s + 3] != 0 { anyAlpha = true }
                }
            }
            // Treat alpha as real only when the bitmap says it has some.
            let useAlpha = bpp == 32 && anyAlpha && (alphaMask != 0 || headerSize >= 108)
            if !useAlpha { for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 } }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: sRGB,
                           bitmapInfo: CGBitmapInfo(rawValue: (useAlpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        var file = Data([0x42, 0x4D])
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }
        put32(UInt32(14 + data.count)); put32(0); put32(UInt32(14 + pixelOffset))
        file.append(data)
        guard let source = CGImageSourceCreateWithData(file as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Promises

extension ClipboardSync: NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png, .tiff:
            lock.lock(); let format = remoteImageFormat; lock.unlock()
            guard let format, let data = fetchSync(format) else { return }
            let cgImage: CGImage?
            if format == CF_DIB || format == CF_DIBV5 {
                cgImage = Self.image(fromDIB: data)
            } else if type == .png {
                item.setData(data, forType: .png)
                return
            } else {
                cgImage = CGImageSourceCreateWithData(data as CFData, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            guard let cgImage,
                  let encoded = Self.encode(cgImage, as: type == .png ? .png : .tiff) else { return }
            item.setData(encoded, forType: type)
        case .fileURL:
            guard let entry = item.string(forType: entryType),
                  let url = download(entry: entry) else { return }
            item.setString(url.absoluteString, forType: .fileURL)
        default:
            break
        }
    }
}
