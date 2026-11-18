//
//  EditorLayoutManager.swift
//  Local Productivity
//
//  The parts of a block that are not text: bullets, numbers, checkboxes, the bar
//  beside a quote, the panel behind a code block or callout. None of them exist in
//  the text itself, so the caret can never land inside one. They are drawn here from
//  each paragraph's block attribute, using the same geometry the text view uses to
//  work out what was clicked.
//

import AppKit

// MARK: - Text container

/// Spaces blocks apart. The gap between two paragraphs is left *outside* their line
/// fragments, so the caret and the selection highlight stay exactly one line tall.
nonisolated final class EditorTextContainer: NSTextContainer {

    var theme = EditorTheme()

    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        // When a line turns out taller than proposed (an image, a table), the typesetter asks again,
        // starting from the origin returned the first time. Placing the line against a fixed target,
        // rather than adding the gap to whatever was proposed, keeps that second request from adding
        // the gap twice.
        var proposed = proposedRect
        if let layoutManager, let storage = layoutManager.textStorage {
            let length = storage.length
            if characterIndex == 0 {
                let top = theme.gap(after: nil, before: length > 0 ? storage.block(at: 0).kind : nil)
                proposed.origin.y = max(proposed.origin.y, top)
            } else if characterIndex <= length, storage.mutableString.character(at: characterIndex - 1) == 0x0A {
                let previous = storage.block(at: characterIndex - 1).kind
                let current: BlockKind? = characterIndex < length ? storage.block(at: characterIndex).kind : nil
                let gap = theme.gap(after: previous, before: current)
                let previousGlyph = layoutManager.glyphIndexForCharacter(at: characterIndex - 1)
                let previousLine = layoutManager.lineFragmentRect(forGlyphAt: previousGlyph, effectiveRange: nil,
                                                                  withoutAdditionalLayout: true)
                if previousLine.isEmpty {
                    proposed.origin.y += gap
                } else {
                    proposed.origin.y = max(proposed.origin.y, previousLine.maxY + gap)
                }
            }
        }
        return super.lineFragmentRect(forProposedRect: proposed, at: characterIndex,
                                      writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

// MARK: - Layout manager

nonisolated final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    var theme = EditorTheme()

    /// Where a block sits, in text container coordinates.
    struct BlockFrame {
        /// The union of the block's line fragments.
        var lines: NSRect
        var firstLine: NSRect
        /// The y position of the first line's baseline.
        var baseline: CGFloat
    }

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    private var columnWidth: CGFloat {
        textContainers.first?.size.width ?? 0
    }

    // MARK: Line metrics

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let character = characterIndexForGlyph(at: glyphRange.location)
        guard character < storage.length else { return false }
        let kind = storage.block(at: character).kind
        guard !kind.isAttachment else { return false }
        // Centre the text in its line box instead of letting it sink to the bottom.
        baselineOffset.pointee = theme.baselineOffset(for: kind)
        return true
    }

    // MARK: Geometry

    func frame(ofParagraph paragraph: NSRange) -> BlockFrame? {
        let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return BlockFrame(lines: first.union(last), firstLine: first,
                          baseline: first.minY + location(forGlyphAt: glyphs.location).y)
    }

    /// The full rectangle a block occupies, including the padding of its panel if it has one.
    func boxRect(for block: BlockAttribute, frame: BlockFrame) -> NSRect {
        let inner = theme.innerPadding(for: block.kind)
        let x = theme.boxOrigin(indent: block.indent)
        return NSRect(x: x, y: frame.lines.minY - inner, width: max(0, columnWidth - x), height: frame.lines.height + inner * 2)
    }

    /// The clickable control at the start of a block: a to-do's checkbox or a callout's icon.
    func controlRect(for block: BlockAttribute, frame: BlockFrame) -> NSRect? {
        let origin = theme.boxOrigin(indent: block.indent)
        switch block.kind {
        case .todo:
            let size = (16 * theme.scale).rounded()
            let capHeight = theme.baseFont(for: block.kind).capHeight
            let centre = frame.baseline - capHeight / 2
            return NSRect(x: origin + 3, y: (centre - size / 2).rounded(), width: size, height: size)
        case .callout:
            let size: CGFloat = 20
            return NSRect(x: origin + 13, y: (frame.firstLine.midY - size / 2).rounded(), width: size, height: size)
        default:
            return nil
        }
    }

    /// The language tag in the corner of a code block, or nil when it is not shown.
    func languageLabel(for block: BlockAttribute, paragraph: NSRange, frame: BlockFrame) -> (text: NSAttributedString, rect: NSRect)? {
        guard case .code(let info, _) = block.kind else { return nil }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == ":" }).first.map(String.init) ?? ""
        let label = NSAttributedString(string: language.isEmpty ? "plain text" : language, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: language.isEmpty ? NSColor.lpInkFaint : NSColor.lpInkTertiary
        ])
        let size = label.size()
        let box = boxRect(for: block, frame: frame)
        let rect = NSRect(x: box.maxX - size.width - 12, y: box.minY + 8, width: ceil(size.width), height: ceil(size.height))

        // Stay out of the way of a long first line.
        let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        if glyphs.length > 0 {
            let used = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            if used.maxX > rect.minX - 12 { return nil }
        }
        return (label, rect)
    }

    /// The number shown beside a numbered list item.
    func ordinal(ofNumberedParagraphAt location: Int) -> Int {
        guard let storage = textStorage else { return 1 }
        let target = storage.block(at: location)
        guard case .numbered(let start, _) = target.kind else { return 1 }

        var first = start
        var count = 0
        var cursor = storage.paragraphRange(at: location).location
        while cursor > 0 {
            let previous = storage.paragraphRange(at: cursor - 1)
            let block = storage.block(at: previous.location)
            cursor = previous.location
            if block.kind == .paragraph, storage.contentRange(of: previous).length == 0 { continue }
            if block.indent > target.indent { continue }
            guard block.indent == target.indent, case .numbered(let number, _) = block.kind else { break }
            first = number
            count += 1
        }
        return first + count
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawPanels(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawMarkers(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Selected block attachments draw their own selection ring rather than a tinted band.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        if charRange.length == 1, let storage = textStorage, charRange.location < storage.length,
           let attachment = storage.attribute(.attachment, at: charRange.location, effectiveRange: nil) as? BlockAttachment,
           attachment.content != .divider {
            return
        }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    private func forEachBlock(inGlyphRange glyphRange: NSRange, _ body: (NSRange, BlockAttribute, BlockFrame) -> Void) {
        guard let storage = textStorage, storage.length > 0, glyphRange.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        storage.enumerateParagraphs(in: characters) { paragraph in
            guard let frame = frame(ofParagraph: paragraph) else { return }
            body(paragraph, storage.block(at: paragraph.location), frame)
        }
    }

    /// Everything that sits behind the text: code and callout panels, inline code and highlights.
    private func drawPanels(forGlyphRange glyphRange: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        forEachBlock(inGlyphRange: glyphRange) { paragraph, block, frame in
            switch block.kind {
            case .code, .raw:
                let rect = boxRect(for: block, frame: frame).offsetBy(dx: origin.x, dy: origin.y)
                NSColor.lpFillSubtle.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            case .callout(let type, _, _):
                let rect = boxRect(for: block, frame: frame).offsetBy(dx: origin.x, dy: origin.y)
                CalloutStyle.style(for: type).tint.withAlphaComponent(0.11).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            default:
                break
            }
            guard !block.kind.isVerbatim, !block.kind.isAttachment else { return }

            let content = storage.contentRange(of: paragraph)
            guard content.length > 0 else { return }
            let font = theme.baseFont(for: block.kind)
            let baselineOffset = theme.baselineOffset(for: block.kind)
            let pillTop = baselineOffset - font.capHeight - 4.5
            let pillHeight = font.capHeight + 9

            func fill(_ key: NSAttributedString.Key, color: NSColor, outset: CGFloat, radius: CGFloat) {
                storage.enumerateAttribute(key, in: content, options: []) { value, range, _ in
                    guard value != nil else { return }
                    let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    color.setFill()
                    enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                        guard rect.width > 0.5 else { return }
                        let pill = NSRect(x: rect.minX - outset + origin.x, y: rect.minY + pillTop + origin.y,
                                          width: rect.width + outset * 2, height: pillHeight)
                        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
                    }
                }
            }
            fill(.lpHighlight, color: .lpHighlight, outset: 1.5, radius: 3.5)
            fill(.lpCode, color: .lpFillInlineCode, outset: 2.5, radius: 4.5)

            // A task's due date sits on a small chip tinted by how soon it is.
            let chipFont = theme.chipFont
            storage.enumerateAttribute(.lpDueDate, in: content, options: []) { value, range, _ in
                guard let state = value as? String else { return }
                let tint: NSColor
                switch state {
                case "overdue": tint = NSColor.systemRed.withAlphaComponent(0.12)
                case "today": tint = NSColor.controlAccentColor.withAlphaComponent(0.14)
                default: tint = .lpFillInlineCode
                }
                tint.setFill()
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
                    guard rect.width > 0.5 else { return }
                    let baseline = rect.minY + baselineOffset
                    let chip = NSRect(x: rect.minX - 4 + origin.x, y: baseline - chipFont.ascender - 2 + origin.y,
                                      width: rect.width + 8, height: chipFont.ascender - chipFont.descender + 4)
                    NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
                }
            }
        }
    }

    /// Everything that sits beside the text: list markers, checkboxes, bars, icons and labels.
    private func drawMarkers(forGlyphRange glyphRange: NSRange, at origin: NSPoint) {
        forEachBlock(inGlyphRange: glyphRange) { paragraph, block, frame in
            let left = theme.boxOrigin(indent: block.indent) + origin.x
            let baseline = frame.baseline + origin.y
            let font = theme.baseFont(for: block.kind)

            switch block.kind {
            case .bullet:
                let centre = NSPoint(x: left + (theme.indentStep * 0.46).rounded(), y: baseline - font.xHeight / 2 - 0.5)
                let radius = 2.75 * theme.scale
                let rect = NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                NSColor.lpInk.setFill()
                NSColor.lpInk.setStroke()
                switch block.indent % 3 {
                case 0:
                    NSBezierPath(ovalIn: rect).fill()
                case 1:
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
                    ring.lineWidth = 1.2
                    ring.stroke()
                default:
                    NSBezierPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), xRadius: 1, yRadius: 1).fill()
                }

            case .numbered(_, let delimiter):
                let number = ordinal(ofNumberedParagraphAt: paragraph.location)
                let label = NSAttributedString(string: "\(number)\(delimiter)", attributes: [
                    .font: theme.typeface == .standard
                        ? NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) : font,
                    .foregroundColor: NSColor.lpInkSecondary
                ])
                let size = label.size()
                let textStart = left + theme.indentStep
                label.draw(at: NSPoint(x: textStart - size.width - 6, y: baseline - font.ascender))

            case .todo(let status, _):
                guard let rect = controlRect(for: block, frame: frame)?.offsetBy(dx: origin.x, dy: origin.y) else { return }
                Self.drawCheckbox(in: rect, status: status)

            case .quote:
                let bar = NSRect(x: left, y: frame.lines.minY + origin.y + 1, width: 3, height: max(4, frame.lines.height - 2))
                NSColor.lpQuoteBar.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()

            case .callout(let type, _, _):
                guard let rect = controlRect(for: block, frame: frame)?.offsetBy(dx: origin.x, dy: origin.y) else { return }
                let style = CalloutStyle.style(for: type)
                let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white, style.tint]))
                if let symbol = NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.label)?
                    .withSymbolConfiguration(configuration) {
                    let size = symbol.size
                    symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }

            case .code:
                if let label = languageLabel(for: block, paragraph: paragraph, frame: frame) {
                    label.text.draw(at: NSPoint(x: label.rect.minX + origin.x, y: label.rect.minY + origin.y))
                }

            default:
                break
            }
        }
    }

    private static func drawCheckbox(in rect: NSRect, status: Character) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
        guard status != " " else {
            box.lineWidth = 1.5
            NSColor.lpInkTertiary.setStroke()
            box.stroke()
            return
        }

        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()

        let unit = rect.width / 16
        let mark = NSBezierPath()
        if status == "-" {
            // Cancelled
            mark.move(to: NSPoint(x: rect.minX + 4.5 * unit, y: rect.midY))
            mark.line(to: NSPoint(x: rect.maxX - 4.5 * unit, y: rect.midY))
        } else if status == "/" {
            // In progress
            mark.move(to: NSPoint(x: rect.minX + 5 * unit, y: rect.maxY - 4.5 * unit))
            mark.line(to: NSPoint(x: rect.maxX - 5 * unit, y: rect.minY + 4.5 * unit))
        } else {
            mark.move(to: NSPoint(x: rect.minX + 4.3 * unit, y: rect.minY + 8.3 * unit))
            mark.line(to: NSPoint(x: rect.minX + 7 * unit, y: rect.minY + 11 * unit))
            mark.line(to: NSPoint(x: rect.minX + 11.8 * unit, y: rect.minY + 5.3 * unit))
        }
        mark.lineWidth = 1.8 * unit
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        NSColor.white.setStroke()
        mark.stroke()
    }
}
