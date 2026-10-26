//
//  KeyboardDetect.swift
//
//  Picks the Windows keyboard layout matching the Mac's current input source,
//  so a new user does not have to. Kept in its own file because it needs
//  Carbon, whose names are best kept out of the rest of the app.
//

import Carbon

extension KeyboardLayout {
    /// The Windows layout for the Mac's current keyboard layout, or "let the
    /// server decide" when there is no good match. Typed text does not depend
    /// on this; it matters for shortcuts and raw keys.
    static func detected() -> KeyboardLayout {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return .automatic
        }
        // For example "com.apple.keylayout.French-numerical".
        let id = (Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String).lowercased()
        let matches: [(String, KeyboardLayout)] = [
            ("belgian", .belgianFrench),
            ("swissfrench", .swissFrench), ("swiss french", .swissFrench),
            ("swissgerman", .swissGerman), ("swiss german", .swissGerman),
            // Before "french": Canadian French is a different layout, and the
            // ABC variants are named after the layout, not a language.
            ("canadian", .automatic),
            ("abc-azerty", .french),
            ("abc-qwertz", .german),
            ("french", .french),
            ("german", .german),
            ("british", .unitedKingdom),
            ("dutch", .dutch),
            ("spanish", .spanish),
            ("italian", .italian),
            ("portuguese", .portuguese),
            ("danish", .danish),
            ("swedish", .swedish),
            ("norwegian", .norwegian),
            ("finnish", .finnish),
            ("keylayout.us", .unitedStates), ("keylayout.abc", .unitedStates),
        ]
        return matches.first { id.contains($0.0) }?.1 ?? .automatic
    }
}
