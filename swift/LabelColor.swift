//
//  LabelColor.swift
//
//  A host's label colour, stored as "#RRGGBB" in sRGB.
//

import AppKit

extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Black or white, whichever reads better on this colour.
    var readableText: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// This colour, lightened toward white until it reads on the black Dock
    /// screen. Black and near-black become a visible grey of the same hue.
    var visibleOnBlack: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        func luminance(_ c: NSColor) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        var result = c
        var mix: CGFloat = 0
        while luminance(result) < 0.18 && mix < 1 {
            mix += 0.05
            result = c.blended(withFraction: mix, of: .white)?.usingColorSpace(.sRGB) ?? .white
        }
        return result
    }
}

extension Host {
    /// Never too dark to read on the Dock screen.
    var color: NSColor? { NSColor(hex: labelColor)?.visibleOnBlack }
}
