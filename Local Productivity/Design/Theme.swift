//
//  Theme.swift
//  Local Productivity
//
//  The visual vocabulary of the app: one neutral "paper and ink" palette that adapts
//  to light and dark, the system accent colour for anything interactive, and a small
//  set of shared measurements. Views pull from here instead of inventing values, which
//  is what keeps the interface feeling like one piece.
//

import AppKit
import SwiftUI

// MARK: - Palette

nonisolated extension NSColor {

    /// A colour that resolves differently in light and dark appearances.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// The page itself.
    static let lpCanvas = adaptive(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1B1B1D))
    /// Surfaces that float above the page: menus, cards, the command palette.
    static let lpSurface = adaptive(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x2A2A2D))

    /// Primary text. Deliberately not pure black or pure white.
    static let lpInk = adaptive(light: NSColor(hex: 0x1D1D1F), dark: NSColor(hex: 0xF2F2F4))
    // Every text level clears WCAG AA (4.5:1) on the canvas, the sidebar and the board's lists,
    // in both modes: secondary at about 7:1, tertiary at about 5:1.
    static let lpInkSecondary = adaptive(light: NSColor(hex: 0x1D1D1F, alpha: 0.74), dark: NSColor(hex: 0xF2F2F4, alpha: 0.70))
    static let lpInkTertiary = adaptive(light: NSColor(hex: 0x1D1D1F, alpha: 0.64), dark: NSColor(hex: 0xF2F2F4, alpha: 0.56))
    /// For decoration only (chevrons, separators, outlines), never for words.
    static let lpInkFaint = adaptive(light: NSColor(hex: 0x1D1D1F, alpha: 0.24), dark: NSColor(hex: 0xF2F2F4, alpha: 0.22))

    static let lpHairline = adaptive(light: NSColor(hex: 0x000000, alpha: 0.09), dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))
    static let lpFillHover = adaptive(light: NSColor(hex: 0x000000, alpha: 0.045), dark: NSColor(hex: 0xFFFFFF, alpha: 0.06))
    static let lpFillSelected = adaptive(light: NSColor(hex: 0x000000, alpha: 0.08), dark: NSColor(hex: 0xFFFFFF, alpha: 0.105))
    /// Quiet backgrounds for code blocks and inset cards.
    static let lpFillSubtle = adaptive(light: NSColor(hex: 0x000000, alpha: 0.035), dark: NSColor(hex: 0xFFFFFF, alpha: 0.05))

    // Status, for text and icons. Each clears 4.5:1 on the surface and on its own 12% tint
    // in both modes, so it can label small text; status always comes with an icon or word.
    static let lpCritical = adaptive(light: NSColor(hex: 0xB42318), dark: NSColor(hex: 0xFF6B61))
    static let lpWarning = adaptive(light: NSColor(hex: 0xA14A0A), dark: NSColor(hex: 0xF5A25D))
    static let lpAccentText = adaptive(light: NSColor(hex: 0x1C5CAB), dark: NSColor(hex: 0x86B6EF))
    /// Done. The same green in both modes; used for icons, never alone.
    static let lpGood = NSColor(hex: 0x0CA30C)

    // Chart marks, validated for colour-vision deficiency and contrast against the canvas.
    static let lpSeriesPrimary = adaptive(light: NSColor(hex: 0x2A78D6), dark: NSColor(hex: 0x3987E5))
    static let lpSeriesContext = NSColor(hex: 0x898781)
    static let lpFillInlineCode = adaptive(light: NSColor(hex: 0x000000, alpha: 0.06), dark: NSColor(hex: 0xFFFFFF, alpha: 0.09))

    static let lpHighlight = adaptive(light: NSColor(hex: 0xFFD60A, alpha: 0.38), dark: NSColor(hex: 0xFFD60A, alpha: 0.30))
    static let lpQuoteBar = adaptive(light: NSColor(hex: 0x1D1D1F, alpha: 0.22), dark: NSColor(hex: 0xF2F2F4, alpha: 0.26))
}

extension Color {
    /// A colour from "#RRGGBB", as calendars and boards store them. Falls back to grey.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Color(nsColor: .systemGray)
            return
        }
        self = Color(nsColor: NSColor(hex: value))
    }

    static let lpCanvas = Color(nsColor: .lpCanvas)
    static let lpSurface = Color(nsColor: .lpSurface)
    static let lpInk = Color(nsColor: .lpInk)
    static let lpInkSecondary = Color(nsColor: .lpInkSecondary)
    static let lpInkTertiary = Color(nsColor: .lpInkTertiary)
    static let lpInkFaint = Color(nsColor: .lpInkFaint)
    static let lpHairline = Color(nsColor: .lpHairline)
    static let lpFillHover = Color(nsColor: .lpFillHover)
    static let lpFillSelected = Color(nsColor: .lpFillSelected)
    static let lpFillSubtle = Color(nsColor: .lpFillSubtle)
    static let lpCritical = Color(nsColor: .lpCritical)
    static let lpWarning = Color(nsColor: .lpWarning)
    static let lpAccentText = Color(nsColor: .lpAccentText)
    static let lpGood = Color(nsColor: .lpGood)
    static let lpSeriesPrimary = Color(nsColor: .lpSeriesPrimary)
    static let lpSeriesContext = Color(nsColor: .lpSeriesContext)
}

// MARK: - Measurements

/// The size of LP's own text, set by Settings → Editor → Interface. Views read it through
/// `Font.lp`, so they redraw when it changes.
@Observable
final class InterfaceScale {
    static let shared = InterfaceScale()
    var value: CGFloat = 1
}

extension Font {
    /// System text at `size` points, scaled by the interface size setting.
    static func lp(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: (size * InterfaceScale.shared.value * 2).rounded() / 2, weight: weight, design: design)
    }
}

enum Metrics {
    /// Corner radii, from controls up to large surfaces.
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 16

    static let sidebarRowHeight: CGFloat = 30
    static let sidebarIndent: CGFloat = 14

    /// The widest a column of prose gets before it stops being comfortable to read.
    static let readingWidth: CGFloat = 720
    static let pageMargin: CGFloat = 56
}

extension Animation {
    /// Quick, slightly springy feedback for hover and selection. With Reduce Motion on, a
    /// brief fade instead.
    static var lpQuick: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18)
    }
    /// Layout changes such as disclosure and panels.
    static var lpSmooth: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)
    }
}

// MARK: - Callout styling

/// How a callout type (`> [!note]`) is drawn. Shared by the editor and anything that previews notes.
nonisolated struct CalloutStyle: Sendable {
    let symbol: String
    let tint: NSColor
    let label: String

    static func style(for type: String) -> CalloutStyle {
        switch type.lowercased() {
        case "tip", "hint", "important":
            return CalloutStyle(symbol: "lightbulb.circle.fill", tint: .systemTeal, label: "Tip")
        case "success", "check", "done":
            return CalloutStyle(symbol: "checkmark.circle.fill", tint: .systemGreen, label: "Success")
        case "question", "help", "faq":
            return CalloutStyle(symbol: "questionmark.circle.fill", tint: .systemPurple, label: "Question")
        case "warning", "caution", "attention":
            return CalloutStyle(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, label: "Warning")
        case "danger", "error", "failure", "fail", "missing", "bug":
            return CalloutStyle(symbol: "xmark.octagon.fill", tint: .systemRed, label: "Danger")
        case "example":
            return CalloutStyle(symbol: "list.bullet.circle.fill", tint: .systemIndigo, label: "Example")
        case "quote", "cite":
            return CalloutStyle(symbol: "quote.bubble.fill", tint: .systemGray, label: "Quote")
        case "abstract", "summary", "tldr":
            return CalloutStyle(symbol: "line.3.horizontal.circle.fill", tint: .systemMint, label: "Summary")
        case "todo":
            return CalloutStyle(symbol: "checkmark.square.fill", tint: .systemBlue, label: "To-do")
        default:
            return CalloutStyle(symbol: "info.circle.fill", tint: .systemBlue, label: "Note")
        }
    }

    /// The types offered when a callout's kind is changed from the editor.
    static let choices: [(type: String, style: CalloutStyle)] = ["note", "tip", "success", "question", "warning", "danger"]
        .map { ($0, style(for: $0)) }
}
