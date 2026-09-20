import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated extension Color {
    /// Creates a colour from a "#rrggbb" string.
    public init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.drop(while: { $0 == "#" }))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A colour that resolves differently in light and dark appearance.
    public init(light: Color, dark: Color) {
        #if os(watchOS)
        // The watch is always dark.
        self = dark
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

/// Gumbo's supplied logo colours, with semantic roles for light and dark interfaces.
public enum Palette {
    public static let brand = Color(hex: "#0826FF")
    public static let silver = Color(hex: "#D4D5D6")
    public static let black = Color(hex: "#000000")
    public static let ink = Color(light: black, dark: silver)
    public static let onInk = Color(light: silver, dark: black)
    public static let paper = Color(light: silver, dark: black)
    public static let neutralTint = silver
    /// Blue text is readable on silver; silver keeps unfilled controls legible on black.
    public static let accent = Color(light: brand, dark: silver)
    /// Primary actions use the exact brand blue in both appearances.
    public static let onBrand = silver
}
