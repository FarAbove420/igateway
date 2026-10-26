//
//  make-icon.swift
//
//  Draws the two icons, 1024 px each:
//  - the app: a glossy apple on a dark tile, lit from the top left;
//  - a session: a minimal PC, a black screen with a white outline. The app writes the
//    server's Dock label on that screen at runtime, so SessionApp.swift has
//    the screen's position too (SessionIconLayout). Keep them in step.
//  Generic shapes on purpose: no Apple or Windows logo.
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

// MARK: - The app: an apple

func drawApple(_ ctx: CGContext) {
    drawTile(ctx, top: 0x2A2F3D, bottom: 0x0C0E14)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // A soft light from the top left, falling across the tile.
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.16), (0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 860), endRadius: 620, options: [])
    // Warm light behind the apple.
    ctx.drawRadialGradient(gradient([(0xFF5A4E, 0.28), (0xFF5A4E, 0)], [0, 1]),
                           startCenter: CGPoint(x: 512, y: 480), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 480), endRadius: 360, options: [])
    // Its shadow on the floor.
    ctx.drawRadialGradient(gradient([(0x000000, 0.55), (0x000000, 0)], [0, 1]),
                           startCenter: CGPoint(x: 512, y: 236), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 236), endRadius: 200,
                           options: [])
    ctx.restoreGState()

    // The body: two shoulders with a dip for the stem, a small dip at the bottom.
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 512, y: 650))
    body.addCurve(to: CGPoint(x: 736, y: 520), control1: CGPoint(x: 600, y: 722), control2: CGPoint(x: 736, y: 690))
    body.addCurve(to: CGPoint(x: 616, y: 262), control1: CGPoint(x: 736, y: 384), control2: CGPoint(x: 684, y: 280))
    body.addCurve(to: CGPoint(x: 512, y: 284), control1: CGPoint(x: 578, y: 252), control2: CGPoint(x: 548, y: 272))
    body.addCurve(to: CGPoint(x: 408, y: 262), control1: CGPoint(x: 476, y: 272), control2: CGPoint(x: 446, y: 252))
    body.addCurve(to: CGPoint(x: 288, y: 520), control1: CGPoint(x: 340, y: 280), control2: CGPoint(x: 288, y: 384))
    body.addCurve(to: CGPoint(x: 512, y: 650), control1: CGPoint(x: 288, y: 690), control2: CGPoint(x: 424, y: 722))
    body.closeSubpath()

    // Stem, behind the leaf.
    ctx.saveGState()
    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 508, y: 632))
    stem.addCurve(to: CGPoint(x: 540, y: 772), control1: CGPoint(x: 512, y: 690), control2: CGPoint(x: 520, y: 740))
    ctx.addPath(stem)
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x5A3A22))
    ctx.strokePath()
    ctx.restoreGState()

    // Body: lit from the top left, darker toward the edge.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(0xFF8A78, 1), (0xF0322E, 1), (0xB3151E, 1), (0x5E0912, 1)], [0, 0.32, 0.72, 1]),
                           startCenter: CGPoint(x: 420, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 500, y: 470), endRadius: 330, options: [.drawsAfterEndLocation])
    // A cool rim light on the right edge.
    ctx.drawRadialGradient(gradient([(0x7FD4FF, 0), (0x7FD4FF, 0.0), (0x7FD4FF, 0.45)], [0, 0.82, 1]),
                           startCenter: CGPoint(x: 470, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 470), endRadius: 290, options: [])
    // Specular highlight.
    ctx.saveGState()
    ctx.translateBy(x: 392, y: 572)
    ctx.rotate(by: 0.55)
    ctx.scaleBy(x: 1, y: 0.62)
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.85), (0xFFFFFF, 0)], [0, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 70, options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    // Leaf.
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: 534, y: 716))
    leaf.addCurve(to: CGPoint(x: 690, y: 786), control1: CGPoint(x: 570, y: 790), control2: CGPoint(x: 640, y: 808))
    leaf.addCurve(to: CGPoint(x: 534, y: 716), control1: CGPoint(x: 676, y: 726), control2: CGPoint(x: 600, y: 690))
    leaf.closeSubpath()
    ctx.saveGState()
    ctx.addPath(leaf)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x9BE36A, 1), (0x2F9E44, 1)], [0, 1]),
                           start: CGPoint(x: 560, y: 790), end: CGPoint(x: 680, y: 700), options: [])
    ctx.restoreGState()
    let rib = CGMutablePath()
    rib.move(to: CGPoint(x: 548, y: 724))
    rib.addCurve(to: CGPoint(x: 676, y: 778), control1: CGPoint(x: 590, y: 752), control2: CGPoint(x: 630, y: 770))
    ctx.addPath(rib)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.35))
    ctx.strokePath()
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
drawApple(app)
save(app, CommandLine.arguments[1])

let session = canvas()
drawPC(session)
save(session, CommandLine.arguments[2])
