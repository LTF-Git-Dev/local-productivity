//
//  EditorTheme.swift
//  Local Productivity
//
//  Every typographic decision the editor makes lives here: which font a block uses,
//  how tall its lines are, how much air sits between two blocks, and how far text is
//  inset. Layout, drawing and hit-testing all ask the theme, so they cannot disagree.
//

import AppKit

nonisolated struct EditorTheme: Equatable, Sendable {

    enum Typeface: Equatable, Sendable {
        case standard, rounded, serif, mono
        /// An installed font family, chosen by name.
        case family(String)
    }

    /// The text size people pick from, in points; the rest of the type scale follows it.
    static let defaultTextSize: CGFloat = 15
    static let textSizes: ClosedRange<CGFloat> = 12...24

    var typeface: Typeface = .standard
    /// Size of body text, in points.
    var textSize: CGFloat = EditorTheme.defaultTextSize
    /// Height of a line of body text, as a multiple of its size.
    var lineSpacing: CGFloat = 1.55

    /// How the type scale relates to the 16 pt it was designed at; spacing and indents follow it.
    var scale: CGFloat { textSize / 16 }

    // MARK: Fonts

    var bodySize: CGFloat { textSize.rounded() }
    var codeSize: CGFloat { (textSize * 0.87 * 2).rounded() / 2 }

    func fontSize(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading(let level, _):
            switch level {
            case 1: return (textSize * 1.75).rounded()
            case 2: return (textSize * 1.4).rounded()
            case 3: return (textSize * 1.2).rounded()
            case 4: return (textSize * 1.07).rounded()
            default: return bodySize
            }
        case .code, .raw: return codeSize
        case .divider, .image, .table: return 1
        default: return bodySize
        }
    }

    /// The page title above the text.
    var titleSize: CGFloat { (textSize * 2.15).rounded() }

    /// Small type for metadata inside a line, such as a task's due date.
    var chipFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: (bodySize * 0.8125 * 2).rounded() / 2, weight: .medium)
    }

    /// The icon at the start of a chip, such as the calendar emoji of a due date.
    var chipIconFont: NSFont {
        NSFont.systemFont(ofSize: (bodySize * 0.6875).rounded())
    }

    func fontWeight(for kind: BlockKind) -> NSFont.Weight {
        switch kind {
        case .heading(let level, _): return level <= 2 ? .bold : .semibold
        default: return .regular
        }
    }

    func lineHeight(for kind: BlockKind) -> CGFloat {
        // Headings stay tighter than body text; looser spacing opens them up a little too.
        let headingSpacing = 1.25 + (lineSpacing - 1.55) * 0.4
        switch kind {
        case .heading(let level, _):
            let spacing = level <= 2 ? headingSpacing : headingSpacing + 0.06
            return max(bodySize * lineSpacing, fontSize(for: kind) * spacing).rounded()
        case .code, .raw: return (codeSize * (lineSpacing - 0.05)).rounded()
        case .divider, .image, .table: return 0
        default: return (bodySize * lineSpacing).rounded()
        }
    }

    private var design: NSFontDescriptor.SystemDesign {
        switch typeface {
        case .standard, .family: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    private var family: String? {
        if case .family(let name) = typeface { return name }
        return nil
    }

    /// The font a block's text is set in before any inline styling.
    func baseFont(for kind: BlockKind) -> NSFont {
        font(for: kind, bold: false, italic: false, code: false)
    }

    func font(for kind: BlockKind, bold: Bool, italic: Bool, code: Bool) -> NSFont {
        let isVerbatim = kind.isVerbatim
        var size = fontSize(for: kind)
        var weight = fontWeight(for: kind)
        var design = design
        if isVerbatim {
            design = .monospaced
        } else if code {
            design = .monospaced
            size = (size * 0.88 * 2).rounded() / 2
        }
        if bold { weight = kind.isHeading ? .heavy : .semibold }
        if !isVerbatim, !code, let family {
            return Self.font(family: family, size: size, weight: weight, italic: italic)
        }
        return Self.font(size: size, weight: weight, design: design, italic: italic)
    }

    /// Where the baseline sits below the top of a line, chosen so text is centred in its line box.
    func baselineOffset(for kind: BlockKind) -> CGFloat {
        let font = baseFont(for: kind)
        let height = lineHeight(for: kind)
        return (((height - (font.ascender - font.descender)) / 2 + font.ascender) * 2).rounded() / 2
    }

    func textColor(for kind: BlockKind) -> NSColor {
        switch kind {
        case .heading(let level, _): return level >= 6 ? .lpInkSecondary : .lpInk
        case .todo(let status, _): return status == " " ? .lpInk : .lpInkTertiary
        case .raw: return .lpInkSecondary
        default: return .lpInk
        }
    }

    private static let fontCache = NSCache<NSString, NSFont>()

    static func font(size: CGFloat, weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign, italic: Bool) -> NSFont {
        let key = "\(size)|\(weight.rawValue)|\(design.rawValue)|\(italic)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if design != .default, let designed = descriptor.withDesign(design) { descriptor = designed }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        let font = NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        fontCache.setObject(font, forKey: key)
        return font
    }

    /// A face of an installed family, as close to `weight` as the family has; the system font
    /// when the family is not installed.
    static func font(family: String, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let key = "\(family)|\(size)|\(weight.rawValue)|\(italic)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        // NSFontManager weighs faces from 0 to 15, with 5 regular and 9 bold.
        let managerWeight: Int = switch weight {
        case ..<NSFont.Weight.medium: 5
        case ..<NSFont.Weight.semibold: 6
        case ..<NSFont.Weight.bold: 8
        case ..<NSFont.Weight.heavy: 9
        default: 11
        }
        let traits: NSFontTraitMask = italic ? .italicFontMask : []
        let found = NSFontManager.shared.font(withFamily: family, traits: traits, weight: managerWeight, size: size)
        let font = found ?? Self.font(size: size, weight: weight, design: .default, italic: italic)
        fontCache.setObject(font, forKey: key)
        return font
    }

    // MARK: Horizontal layout

    /// Width of one level of list nesting, which is also the column a list marker sits in.
    var indentStep: CGFloat { (26 * scale).rounded() }

    /// Padding between the edge of a boxed block (code, callout) and its text.
    var boxPadding: CGFloat { 16 }

    /// Distance from the left edge of the column to where a block's text starts.
    func leadingInset(for kind: BlockKind, indent: Int) -> CGFloat {
        let base = CGFloat(max(indent, 0)) * indentStep
        switch kind {
        case .bullet, .numbered, .todo: return base + indentStep
        case .quote: return base + 18
        case .callout: return base + 44
        case .code, .raw: return base + boxPadding
        default: return base
        }
    }

    func trailingInset(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .callout, .code, .raw: return boxPadding
        default: return 0
        }
    }

    /// Left edge of the block's own box (its marker column, bar or background), before the text inset.
    func boxOrigin(indent: Int) -> CGFloat {
        CGFloat(max(indent, 0)) * indentStep
    }

    // MARK: Vertical rhythm

    /// Extra room inside a boxed block, above its first line and below its last.
    func innerPadding(for kind: BlockKind?) -> CGFloat {
        switch kind {
        case .code, .raw: return 14
        case .callout: return 13
        default: return 0
        }
    }

    private func spaceBefore(_ kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading(let level, _):
            switch level {
            case 1: return 34
            case 2: return 28
            case 3: return 22
            default: return 18
            }
        case .quote: return 12
        case .callout, .code, .raw, .image, .table: return 14
        case .divider: return 8
        default: return 9
        }
    }

    private func spaceAfter(_ kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading(let level, _):
            switch level {
            case 1: return 8
            case 2: return 6
            default: return 4
            }
        case .quote: return 12
        case .callout, .code, .raw, .image, .table: return 14
        case .divider: return 8
        default: return 9
        }
    }

    /// The empty space between the bottom of one block and the top of the next, including the
    /// padding of any box either of them draws. `previous` is nil for the first block.
    func gap(after previous: BlockKind?, before current: BlockKind?) -> CGFloat {
        let inner = innerPadding(for: previous) + innerPadding(for: current)
        guard let previous else { return inner }
        let current = current ?? .paragraph

        var space = max(spaceAfter(previous), spaceBefore(current))
        if previous.isListItem, current.isListItem {
            space = 3
        } else if previous.isHeading, current.isHeading {
            space = min(space, 12)
        }
        // Looser line spacing gets a little more room between blocks as well.
        return (space * scale * (0.6 + 0.4 * lineSpacing / 1.55)).rounded() + inner
    }

    // MARK: Paragraph styles

    func paragraphStyle(for kind: BlockKind, indent: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight(for: kind)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        let leading = leadingInset(for: kind, indent: indent)
        style.firstLineHeadIndent = leading
        style.headIndent = leading
        style.tailIndent = -trailingInset(for: kind)
        style.lineBreakMode = .byWordWrapping
        if kind.isVerbatim {
            let advance = baseFont(for: kind).maximumAdvancement.width
            style.tabStops = []
            style.defaultTabInterval = advance * 4
        }
        return style
    }
}
