import AppKit
import IOSurface
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import CoreMedia

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ok    \(name)") }
    else { failed += 1; print("  FAIL  \(name)  \(detail())") }
}

// MARK: Text
print("== Text")
let sample = "line one\nline two\r\nnaïve €uro 😀"
let wire = ClipboardSync.windowsText(sample)
let wireUnits = stride(from: 0, to: wire.count - 2, by: 2).map { UInt16(wire[$0]) | UInt16(wire[$0 + 1]) << 8 }
check("ends with a UTF-16 NUL", wire.suffix(2) == Data([0, 0]))
check("LF becomes CRLF without doubling an existing CR",
      String(decoding: wireUnits, as: UTF16.self) == "line one\r\nline two\r\nnaïve €uro 😀")
check("round trip back to Mac text", ClipboardSync.macText(utf16: wire) == "line one\nline two\nnaïve €uro 😀")
check("stops at the first NUL", ClipboardSync.macText(utf16: Data([0x41, 0, 0, 0, 0x42, 0])) == "A")
check("odd byte count is safe", ClipboardSync.macText(utf16: Data([0x41, 0, 0x42])) == "A")

// MARK: File lists
print("== File list: ours, read by FreeRDP's own parser")
let files = [
    OutgoingFile(url: URL(fileURLWithPath: "/tmp/x"), path: "Folder", isDirectory: true, size: 0, modified: Date()),
    OutgoingFile(url: URL(fileURLWithPath: "/tmp/y"), path: "Folder\\a.txt", isDirectory: false, size: 12345, modified: Date()),
    OutgoingFile(url: URL(fileURLWithPath: "/tmp/z"), path: "Folder\\Sub\\b é😀.bin", isDirectory: false,
                 size: 5_000_000_000, modified: Date()),
]
var packed = Data()
var count = UInt32(files.count).littleEndian
packed.append(Data(bytes: &count, count: 4))
files.forEach { packed.append(ClipboardSync.descriptor(for: $0)) }
check("each descriptor is 592 bytes", ClipboardSync.descriptor(for: files[0]).count == 592)

var names = [CChar](repeating: 0, count: 8 * 260)
var attrs = [UInt32](repeating: 0, count: 8)
var sizes = [UInt64](repeating: 0, count: 8)
let parsedCount = packed.withUnsafeBytes { raw in
    shim_parse_file_list(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count), &names, &attrs, &sizes, 8)
}
check("FreeRDP parses our list", parsedCount == 3, "got \(parsedCount)")
func name(_ i: Int) -> String {
    names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * 260) }
}
for (i, f) in files.enumerated() where parsedCount == 3 {
    check("entry \(i) name \(f.path)", name(i) == f.path, "got \(name(i))")
    check("entry \(i) attributes", attrs[i] == (f.isDirectory ? 0x10 : 0x80), "got \(attrs[i])")
    check("entry \(i) size", sizes[i] == f.size, "got \(sizes[i])")
}

print("== File list: FreeRDP's, read by ours")
let srcNames = ["Report.docx", "Logs", "Logs\\ime.log"]
let srcAttrs: [UInt32] = [0x20, 0x10, 0x20]
let srcSizes: [UInt64] = [98765, 0, 3_000_000_000]
var outPtr: UnsafeMutablePointer<UInt8>?
var outLen: UInt32 = 0
let cNames = srcNames.map { strdup($0) }
let rc = cNames.map { UnsafePointer<CChar>($0) }.withUnsafeBufferPointer { nb in
    shim_serialize_file_list(nb.baseAddress, srcAttrs, srcSizes, 3, &outPtr, &outLen)
}
check("FreeRDP serialised", rc == 0 && outPtr != nil)
if let outPtr {
    let remote = ClipboardSync.parseFileList(Data(bytes: outPtr, count: Int(outLen)))
    check("we read 3 entries", remote.count == 3, "got \(remote.count)")
    for i in 0..<min(3, remote.count) {
        check("entry \(i) path", remote[i].path == srcNames[i], "got \(remote[i].path)")
        check("entry \(i) directory flag", remote[i].isDirectory == (srcAttrs[i] & 0x10 != 0))
        check("entry \(i) size", remote[i].size == srcSizes[i], "got \(String(describing: remote[i].size))")
    }
    free(outPtr)
}
cNames.forEach { free($0) }

// MARK: Images
print("== Images")
func makePNG(width: Int, height: Int, alpha: Bool) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))   // top half red
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: alpha ? 0 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))                     // bottom half blue or clear
    return ClipboardSync.encode(ctx.makeImage()!, as: .png)!
}
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let o = (y * image.width + x) * 4   // row 0 is the top in the bitmap
    return (p[o], p[o + 1], p[o + 2], p[o + 3])
}

let png = makePNG(width: 37, height: 20, alpha: true)
let dib = ClipboardSync.dib(fromImageData: png)
check("Mac image converts to CF_DIB", dib != nil)
if let dib {
    check("DIB header is BITMAPINFOHEADER, 32 bpp", dib[0] == 40 && dib[14] == 32)
    check("DIB size is header plus pixels", dib.count == 40 + 37 * 20 * 4, "got \(dib.count)")
    if let back = ClipboardSync.image(fromDIB: dib) {
        check("DIB decodes to the same size", back.width == 37 && back.height == 20)
        let top = pixel(back, 5, 2), bottom = pixel(back, 5, 17)
        check("top half is red", top.0 > 240 && top.1 < 15 && top.2 < 15, "\(top)")
        check("transparent half became white, not black", bottom.0 > 240 && bottom.1 > 240 && bottom.2 > 240, "\(bottom)")
        check("result is opaque", bottom.3 == 255 && top.3 == 255)
    } else { check("DIB decodes", false) }
}

// A Windows-style 32 bpp BI_RGB DIB whose alpha bytes are all zero must not
// come out transparent.
var raw = Data()
func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) } }
func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) } }
put32(40); put32(2); put32(UInt32(bitPattern: -2)); put16(1); put16(32); put32(0)   // top-down
put32(16); put32(0); put32(0); put32(0); put32(0)
raw.append(contentsOf: [0, 255, 0, 0,   255, 0, 0, 0])      // row 0: green, blue (BGRA, alpha 0)
raw.append(contentsOf: [0, 0, 255, 0,   0, 0, 0, 0])        // row 1: red, black
if let img = ClipboardSync.image(fromDIB: raw) {
    let g = pixel(img, 0, 0), b = pixel(img, 1, 0), r = pixel(img, 0, 1)
    check("zero-alpha DIB is opaque", g.3 == 255 && r.3 == 255)
    check("top-down DIB keeps row order and colours", g.1 == 255 && b.2 == 255 && r.0 == 255, "\(g) \(b) \(r)")
} else { check("zero-alpha DIB decodes", false) }

// MARK: Keyboard and wheel
print("== Keyboard mapping")
check("A",            rdp_scancode_for_mac_keycode(0x00, false) == 0x1E)
check("Left arrow is extended", rdp_scancode_for_mac_keycode(0x7B, false) == 0x14B)
check("Return",       rdp_scancode_for_mac_keycode(0x24, false) == 0x1C)
check("ISO § key on an ISO Mac maps to the key left of 1", rdp_scancode_for_mac_keycode(0x0A, true) == 0x29)
check("ISO < key on an ISO Mac maps to the key left of Z", rdp_scancode_for_mac_keycode(0x32, true) == 0x56)
check("same keys unswapped on ANSI", rdp_scancode_for_mac_keycode(0x0A, false) == 0x56)
print("  this Mac's keyboard is ISO: \(rdp_mac_keyboard_is_iso())")

print("== Wheel encoding, MS-RDPBCGR 2.2.8.1.1.3.1.1.3")
check("+120 vertical",  rdp_wheel_flags(false, 120) == 0x0200 | 120)
check("-120 vertical",  rdp_wheel_flags(false, -120) == 0x0200 | 0x0100 | 0x88, String(rdp_wheel_flags(false, -120), radix: 16))
check("-1 is 0x1FF",    rdp_wheel_flags(false, -1) & 0x1FF == 0x1FF)
check("horizontal flag", rdp_wheel_flags(true, 40) == 0x0400 | 40)
check("clamped to 255", rdp_wheel_flags(false, 1000) & 0x1FF == 255)

// MARK: Surfaces
print("== Surface pool")
let w = 64, h = 32, rowBytes = w * 4
var frame = [UInt8](repeating: 0, count: rowBytes * h)
func fill(_ x0: Int, _ y0: Int, _ ww: Int, _ hh: Int, _ v: UInt8) {
    for y in y0..<y0 + hh { for x in x0..<x0 + ww { let o = y * rowBytes + x * 4; frame[o] = v; frame[o + 1] = v; frame[o + 2] = v; frame[o + 3] = 0 } }
}
func read(_ s: IOSurface, _ x: Int, _ y: Int) -> (UInt8, UInt8) {
    s.lock(options: .readOnly, seed: nil); defer { s.unlock(options: .readOnly, seed: nil) }
    let p = s.baseAddress.assumingMemoryBound(to: UInt8.self)
    let o = y * s.bytesPerRow + x * 4
    return (p[o], p[o + 3])
}
let pool = SurfacePool()
fill(0, 0, w, h, 10)
let s1 = frame.withUnsafeBufferPointer { pool.write(pixels: $0.baseAddress!, width: w, height: h, stride: rowBytes,
                                                   dirty: RDPRect(x: 0, y: 0, width: Int32(w), height: Int32(h)), full: true) }
check("first frame gives a surface to show", s1 != nil)
check("pixel copied and alpha forced opaque", s1.map { read($0, 3, 3) } .map { $0 == (10, 255) } ?? false)

fill(10, 10, 5, 5, 99)
let again = frame.withUnsafeBufferPointer { pool.write(pixels: $0.baseAddress!, width: w, height: h, stride: rowBytes,
                                                      dirty: RDPRect(x: 10, y: 10, width: 5, height: 5), full: false) }
check("while one is waiting to be shown, no second hop is scheduled", again == nil)
check("the waiting surface got the update", read(s1!, 12, 12).0 == 99)
pool.didDisplay(s1!)

fill(40, 2, 3, 3, 200)
let s2 = frame.withUnsafeBufferPointer { pool.write(pixels: $0.baseAddress!, width: w, height: h, stride: rowBytes,
                                                   dirty: RDPRect(x: 40, y: 2, width: 3, height: 3), full: false) }
check("the shown surface is never written: a second one is used", s2 != nil && s2 !== s1)
if let s2 {
    check("new surface has the latest change", read(s2, 41, 3).0 == 200)
    check("new surface also has earlier content it never saw", read(s2, 12, 12).0 == 99 && read(s2, 60, 30).0 == 10)
    check("shown surface left untouched", read(s1!, 41, 3).0 == 10)
    pool.didDisplay(s2)
    fill(0, 0, 2, 2, 7)
    let s3 = frame.withUnsafeBufferPointer { pool.write(pixels: $0.baseAddress!, width: w, height: h, stride: rowBytes,
                                                       dirty: RDPRect(x: 0, y: 0, width: 2, height: 2), full: false) }
    if let s3 {
        check("third write catches up on what it missed", read(s3, 41, 3).0 == 200 && read(s3, 1, 1).0 == 7)
    } else { check("third write gives a surface", false) }
}
let resized = [UInt8](repeating: 5, count: 32 * 4 * 16).withUnsafeBufferPointer {
    pool.write(pixels: $0.baseAddress!, width: 32, height: 16, stride: 32 * 4,
               dirty: RDPRect(x: 0, y: 0, width: 1, height: 1), full: false)
}
check("a size change starts fresh with a full copy", resized.map { $0.width == 32 && read($0, 31, 15).0 == 5 } ?? false)

// MARK: Settings
print("== Settings")
let old = #"{"hosts":[{"id":"6F1C0E1A-2B3C-4D5E-8F90-112233445566","address":"192.0.2.10","label":"files"}],"keyboardLayout":"0x080C"}"#
var decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
check("a config missing most keys still decodes", decoded != nil)
check("and keeps its hosts", decoded?.hosts.first?.address == "192.0.2.10")
check("and fills defaults", decoded?.dynamicResolution == true && decoded?.keyboardMode == .characters)
check("a host saved before Dock labels has none", decoded?.hosts.first?.dockLabel == "")
decoded?.normalize()
check("hosts without a gateway go to direct connections",
      decoded.map { $0.gateways.count == 1 && $0.gateways[0].isDirect && $0.hosts[0].gatewayID == $0.gateways[0].id } ?? false)

var fresh = AppSettings()
fresh.normalize()
check("a new install starts with direct connections", fresh.gateways.count == 1 && fresh.gateways[0].isDirect
      && fresh.gateways[0].title == "Direct connections")
check("and has no hosts or accounts", fresh.hosts.isEmpty && fresh.accounts.isEmpty)

var two = AppSettings()
let admin = Account(username: "admin", domain: "corp.example"), user = Account(username: "user@example.com", domain: "")
two.accounts = [admin, user]
two.gateways = [Gateway(name: "", host: "rdg.example.com", transport: .rpc, serverAccountID: admin.id,
                        separateAccount: true, gatewayAccountID: user.id),
                Gateway(name: "Lab", host: "")]
let lab = two.gateways[1].id
two.hosts = [Host(address: "192.0.2.10", label: "files"), Host(address: "192.0.2.20", label: "", gatewayID: lab)]
two.normalize()
check("a direct group is not added twice", two.gateways.filter(\.isDirect).count == 1)
check("a host without a gateway goes to direct connections", two.hosts[0].gatewayID == lab)
two.accounts.removeAll { $0.id == user.id }
two.normalize()
check("removing an account clears it from gateways", two.gateways[0].gatewayAccountID == nil)
check("a host keeps its own gateway", two.hosts[1].gatewayID == lab)
check("gateway(for:) finds it", two.gateway(for: two.hosts[1])?.title == "Lab")
two.gateways.removeFirst()
two.normalize()
check("hosts of a removed gateway fall back to direct connections",
      two.hosts.allSatisfy { $0.gatewayID == lab } && two.lastGatewayID == two.gateways[0].id)
// security -g, as seen from security itself: plain text quoted, anything else hex.
check("Keychain: plain password", Keychain.revealed(#"password: "plain""#) == "plain")
check("Keychain: quotes inside", Keychain.revealed(#"password: "a"b""#) == #"a"b"#)
check("Keychain: non-ASCII comes as hex", Keychain.revealed(#"password: 0x70C3A4737377C3B67264  "p\303\244ssw\303\266rd""#) == "pässwörd")
check("Keychain: a password that looks like hex stays itself", Keychain.revealed(#"password: "0xdead""#) == "0xdead")

// MARK: Export and import
print("== Export and import")
var source = AppSettings()
source.accounts = [admin]
source.gateways = [Gateway(name: "Office", host: "rdg.example.com", transport: .http, serverAccountID: admin.id)]
source.hosts = [Host(address: "192.0.2.10", label: "files", gatewayID: source.gateways[0].id, dockLabel: "F",
                     labelColor: "#FF9F0A"),
                Host(address: "198.51.100.5", label: "lab pc")]
source.normalize()
let exported = try! source.exportedHosts()
let exportedText = String(decoding: exported, as: UTF8.self)
check("the export has gateways and hosts", exportedText.contains("rdg.example.com") && exportedText.contains("198.51.100.5"))
check("but no accounts", !exportedText.contains("admin") && !exportedText.contains("corp.example")
      && !exportedText.contains(admin.id.uuidString))
var target = AppSettings()
target.normalize()
let first = try? target.importHosts(from: exported)
check("importing into an empty list adds everything", first?.hosts == 2 && first?.gateways == 1 && first?.skipped == 0)
check("the gateway keeps its transport and name",
      target.gateways.contains { $0.host == "rdg.example.com" && $0.transport == .http && $0.name == "Office" })
check("direct hosts land in direct connections",
      target.hosts.first { $0.address == "198.51.100.5" }.flatMap { target.gateway(for: $0) }?.isDirect == true)
check("the label comes along", target.hosts.first { $0.address == "192.0.2.10" }?.dockLabel == "F")
check("and so does its colour", target.hosts.first { $0.address == "192.0.2.10" }?.labelColor == "#FF9F0A")
check("signing out of Windows is a normal end", ConnectError.endReason("ERRINFO_LOGOFF_BY_USER") != nil
      && ConnectError.endReason("ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER") != nil
      && ConnectError.endReason("ERRCONNECT_LOGON_FAILURE") == nil)
check("near-black label colours are lightened", (NSColor(hex: "#000000")?.visibleOnBlack.hexString ?? "#000000") != "#000000"
      && NSColor(hex: "#FFB020")?.visibleOnBlack.hexString == "#FFB020")
let reimport = try? target.importHosts(from: exported)
check("importing again adds nothing", reimport?.hosts == 0 && reimport?.gateways == 0 && reimport?.skipped == 2)
check("a file that is not a host list is refused",
      (try? target.importHosts(from: Data(#"{"format":"other","gateways":[]}"#.utf8))) == nil)

// MARK: H.264
print("== H.264")
// The local test server can't send H.264, so the Mac's own encoder makes a
// frame and FreeRDP's AVC420 path, the one Windows streams take, decodes it.
func encodeRedFrame(width: Int, height: Int) -> Data? {
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                     codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                     imageBufferAttributes: nil, compressedDataAllocator: nil,
                                     outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
          let session else { return nil }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
    guard let pixels else { return nil }
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height { for x in 0..<width {
        let p = base + y * stride + x * 4
        p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255           // BGRA red
    } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var annexB = Data()
    let startCode = Data([0, 0, 0, 1])
    let done = DispatchSemaphore(value: 0)
    VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: .zero, duration: .invalid,
                                    frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                                    infoFlagsOut: nil) { status, _, sample in
        defer { done.signal() }
        guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample) else { return }
        // Parameter sets first, then the frame, each with an Annex B start code.
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            if let pointer { annexB += startCode + Data(bytes: pointer, count: size) }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return }
        let bytes = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= bytes.count {           // AVCC: 4-byte big-endian lengths
            let nal = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            annexB += startCode + bytes.subdata(in: offset + 4 ..< offset + 4 + nal)
            offset += 4 + nal
        }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    done.wait()
    VTCompressionSessionInvalidate(session)
    return annexB.isEmpty ? nil : annexB
}
if let frame = encodeRedFrame(width: 64, height: 64) {
    var decodedPixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
    let status = frame.withUnsafeBytes { shim_h264_decode($0.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                           UInt32(frame.count), 64, 64, &decodedPixels) }
    check("FreeRDP decodes H.264 with the built-in FFmpeg", status >= 0, "status \(status)")
    let center = (32 * 64 + 32) * 4
    let (b, g, r) = (decodedPixels[center], decodedPixels[center + 1], decodedPixels[center + 2])
    check("and the red frame comes out red", r > 200 && g < 60 && b < 60, "BGR \(b) \(g) \(r)")
} else {
    // Virtual Macs (like CI runners) may have no hardware H.264 encoder.
    print("  skip  no H.264 encoder on this Mac to make a test frame")
}

// MARK: Certificates
print("== Certificates")
// A throwaway self-signed certificate; its SHA-256 checked with: openssl x509 -fingerprint -sha256
let pem = """
-----BEGIN CERTIFICATE-----
MIICqjCCAZICCQCy7Esh2028MjANBgkqhkiG9w0BAQsFADAXMRUwEwYDVQQDDAx0
ZXN0LmV4YW1wbGUwHhcNMjYxMDI2MDAxODQ3WhcNMzYxMDIzMDAxODQ3WjAXMRUw
EwYDVQQDDAx0ZXN0LmV4YW1wbGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
AoIBAQCiysYL7rf/EwSd9oEHqmbA4FzXPVM4BLrIF5sCSM6+YJyqMlxkOwi1r/B5
0rKIZTlneWdR471HewKz7Q+Ilw6N3aQgo9Cz4CNXzHv/vVAz3pqxyZeU1Rq9x4pQ
rabKq6FiBZOoLaV0pHcIHv4ObkcKHbnP97AcU4rvQyYk+i0W83BuWPEjvwtOxjod
I/DwLKogFSeJRqQ0yocg8uVUqIFbSVr7pORPrFgHbaDQnu2EI5JEwE3ZndoUEQHV
i94wsy1sUzQGuTQeLmLw0zJk5Cj9Y63xCvVgasaHnInKMeZbusfIKaMjCCjDOoRX
JIwMrLs0H9GU9iPxK/6oyxGyCi41AgMBAAEwDQYJKoZIhvcNAQELBQADggEBADaY
JYRrG5B6OeiKRjzk9aQFf/W/kWlFmPmy6SKXRtCZnZoynKLaJey6jbghBgBHJ63z
CoZuPQMyypfBs8z2jWgQV4+wLFN/k/e9JaltrqEmnQz3LDmbkvpiu+Tre57p2NA3
iuypMCgE1p1xHcVnI3qj9c5jElpAUddbbv4QjIZKtZOyl9VuwozQeFc5YHqaj/E9
tjinp3cikyEm7V998hBgK9Pq2qqShSWIOumVAZ+VFlRgYm/x/QskVolgaSaw2kC5
gkDY7UQCfFNvLs0FTvSnlewUHoFlHdQ30xo4jVPrHDOT5eHUb6oOTogRAnPfdQ8h
ZQZXSZEP/7x/gX7W9Q0=
-----END CERTIFICATE-----
"""
check("PEM certificates show their SHA-256", CertificateInfo.fingerprint(pem, isPEM: true)
      == "E0:71:A3:8D:4D:E6:3F:F4:F3:12:EE:D9:76:EE:10:4A:10:06:95:38:A2:89:57:45:9C:1F:24:DB:87:87:75:66")
check("other fingerprints pass through", CertificateInfo.fingerprint("ab:cd", isPEM: false) == "ab:cd")
check("with a chain, the fingerprint is the server's own certificate",
      CertificateInfo.fingerprint(pem + "\n" + pem.replacingOccurrences(of: "MII", with: "MIJ"), isPEM: true)
      == CertificateInfo.fingerprint(pem, isPEM: true))
check("every certificate in a chain is read", CertificateInfo.certificates(inPEM: pem + "\n" + pem).count == 2)
func certificateInfo(pem: String, host: String) -> CertificateInfo {
    pem.withCString { p in host.withCString { h in
        CertificateInfo(RDPCertificate(host: h, port: 3389, commonName: h, subject: h, issuer: h, fingerprint: p,
                                       isPEM: true, gateway: false, changed: false, mismatch: false,
                                       oldSubject: nil, oldIssuer: nil, oldFingerprint: nil, oldIsPEM: false))
    } }
}
check("macOS does not trust a self-signed certificate", !certificateInfo(pem: pem, host: "test.example").trustedByMac)

// MARK: NTLM crypto
print("== NTLM crypto")
// NTLM needs MD4 and RC4, which OpenSSL 3 only has in a module a static build
// lacks. FreeRDP's own copies must stand in. Test vectors: RFC 1320 for MD4,
// and the widely published RC4 vector (key "Key", plaintext "Plaintext").
var md4 = [UInt8](repeating: 0, count: 16)
let md4OK = shim_md4(Array("abc".utf8), 3, &md4) == 1
check("MD4 works", md4OK && md4.map { String(format: "%02x", $0) }.joined() == "a448017aaf21d8525fc10ae87aa6729d",
      md4.map { String(format: "%02x", $0) }.joined())
var rc4 = [UInt8](repeating: 0, count: 9)
let rc4OK = shim_rc4(Array("Key".utf8), 3, Array("Plaintext".utf8), 9, &rc4) == 1
check("RC4 works", rc4OK && rc4.map { String(format: "%02X", $0) }.joined() == "BBF316E8D940AF0AD3",
      rc4.map { String(format: "%02X", $0) }.joined())

let gw = try? JSONDecoder().decode(Gateway.self, from: Data(#"{"host":"rdg.example.com","transport":"weird"}"#.utf8))
check("a gateway with odd values still decodes", gw?.host == "rdg.example.com" && gw?.transport == .automatic)
check("detected keyboard layout is one of ours", KeyboardLayout.allCases.contains(KeyboardLayout.detected()))
print("  detected layout here: \(KeyboardLayout.detected().label)")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
