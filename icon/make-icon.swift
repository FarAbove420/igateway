//
//  make-icon.swift
//
//  Draws the two icons, 1024 px each:
//  - the app: the artwork in AppIcon-art.webp, cut out and put on the grid;
//  - a session: a minimal PC, a black screen with a white outline. The app writes the
//    server's Dock label on that screen at runtime, so SessionApp.swift has
//    the screen's position too (SessionIconLayout). Keep them in step.
//  The PC is a generic shape on purpose: no Windows logo.
//
//  Run by make-icon.zsh, which turns the PNGs into .icns files.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(UInt32, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: locations)!
}

func canvas() -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

/// Apple's macOS icon grid: an 824 px tile with a 100 px margin, and a shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

func drawTile(_ ctx: CGContext, top: UInt32, bottom: UInt32) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(bottom))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(top, 1), (bottom, 1)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
}

// MARK: - The app: the artwork in AppIcon-art.webp

/// The artwork is a dark rounded tile on plain black, without transparency.
/// The black around the tile is flood-filled from the edges and made
/// transparent: dark parts inside the tile (the sunglasses) aren't reached.
/// The tile is then scaled onto Apple's grid with the usual shadow.
func drawArtwork(_ ctx: CGContext, _ path: String) {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let art = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let w = art.width, h = art.height
    let pixels = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pixels.draw(art, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = pixels.data!.assumingMemoryBound(to: UInt8.self)
    func dark(_ i: Int) -> Bool { max(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) <= 4 }

    var outside = [Bool](repeating: false, count: w * h)
    var stack = (0..<w).flatMap { [$0, (h - 1) * w + $0] } + (0..<h).flatMap { [$0 * w, $0 * w + w - 1] }
    while let i = stack.popLast() {
        guard !outside[i], dark(i) else { continue }
        outside[i] = true
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }
        if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }
        if y < h - 1 { stack.append(i + w) }
    }
    var minX = w, minY = h, maxX = 0, maxY = 0
    for i in 0..<(w * h) {
        if outside[i] {
            p[i * 4] = 0; p[i * 4 + 1] = 0; p[i * 4 + 2] = 0; p[i * 4 + 3] = 0
        } else {
            let x = i % w, y = i / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Rows of the buffer run top to bottom; cropping works in the same order.
    let cut = pixels.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.35))
    ctx.draw(cut, in: tile)
    ctx.restoreGState()
}

// MARK: - A session: a PC monitor

/// Screen of the monitor. SessionIconLayout in SessionApp.swift has the same
/// rectangle as fractions of the icon: x 160, y 352, 704 x 448.
let screen = CGRect(x: 160, y: 352, width: 704, height: 448)

func drawPC(_ ctx: CGContext) {
    // Near-black tile, a black screen with a white outline, a white stand.
    // Minimal on purpose: any label colour reads on black.
    drawTile(ctx, top: 0x1C1D21, bottom: 0x060607)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 488, y: 268, width: 48, height: 84), cornerWidth: 6, cornerHeight: 6,
                       transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 392, y: 236, width: 240, height: 32), cornerWidth: 16, cornerHeight: 16,
                       transform: nil))
    ctx.fillPath()

    let screenPath = CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.addPath(screenPath)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.strokePath()
}

let app = canvas()
drawArtwork(app, CommandLine.arguments[1])
save(app, CommandLine.arguments[2])

let session = canvas()
drawPC(session)
save(session, CommandLine.arguments[3])
