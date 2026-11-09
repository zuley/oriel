import AppKit
import SwiftUI

/// Neutral surfaces and text; 05A coral is reserved for small action/state accents.
/// Brand colors are separate from stock-market and destructive-action semantics.
@MainActor
enum OrielPalette {
    static let background = color(0xFEFEFE)
    static let sidebar = color(0xF5F5F5)
    static let surface = color(0xFFFFFF)
    static let field = color(0xF1F1F1)
    static let ink = color(0x363636)
    static let secondary = color(0x6F6F6F)
    static let disabled = color(0xB9B9B9)
    static let accent = color(0xB43D2B)
    static let selection = color(0xEFEFEF)
    static let textSelection = color(0xE4E4E4)
    static let amber = color(0x956014)
    static let divider = color(0xE9E9E9)
    static let border = color(0x949494)
    static let hover = color(0xEFEFEF)
    static let pressed = color(0xE2E2E2)
    static let terminal = color(0x000000)
    static let terminalInk = color(0xE6E6E6)

    static var tint: Color { Color(nsColor: accent) }
    static var text: Color { Color(nsColor: ink) }
    static var mutedText: Color { Color(nsColor: secondary) }

    // The browser's own start/error pages share these roles; external sites keep
    // their own design. Immutable CSS is also usable by the non-UI page builder.
    nonisolated static let browserCSS = """
    :root { color-scheme: light; --oriel-canvas: #FEFEFE; --oriel-field: #F1F1F1;
        --oriel-ink: #363636; --oriel-muted: #6F6F6F; --oriel-accent: #B43D2B;
        --oriel-selection: #EFEFEF; --oriel-highlight: #E4E4E4; }
    """

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
