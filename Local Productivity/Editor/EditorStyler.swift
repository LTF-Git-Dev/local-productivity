//
//  EditorStyler.swift
//  Local Productivity
//
//  Turns meaning into appearance. After every edit the paragraphs that changed are
//  normalised (each paragraph is exactly one block) and restyled from their semantic
//  attributes. Because presentation is always recomputed, it can never drift out of
//  step with what will be written to disk.
//

import AppKit

nonisolated struct EditorStyler {

    var theme: EditorTheme

    /// Brings every paragraph touching `range` into a consistent, styled state.
    /// Returns the range that was processed.
    @discardableResult
    func normalize(_ storage: NSTextStorage, in range: NSRange) -> NSRange {
        guard storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let text = storage.string as NSString
        let location = min(range.location, text.length)
        let length = min(range.length, text.length - location)
        let affected = text.paragraphRange(for: NSRange(location: location, length: length))

        storage.enumerateParagraphs(in: affected) { paragraph in
            var block = dominantBlock(in: storage, paragraph: paragraph)
            let content = storage.contentRange(of: paragraph)
            let soleAttachment = content.length == 1
                ? storage.attribute(.attachment, at: content.location, effectiveRange: nil) as? BlockAttachment
                : nil

            if let soleAttachment {
                // A paragraph holding nothing but an attachment is that attachment's block.
                if !block.kind.isAttachment { block = block.with(kind: Self.kind(for: soleAttachment, fallback: block.kind)) }
            } else if block.kind.isAttachment {
                // The attachment is gone, or text was added next to it: an ordinary paragraph again.
                block = block.with(kind: .paragraph)
            }

            storage.addAttribute(.lpBlock, value: block, range: paragraph)
            style(storage, paragraph: paragraph, block: block)
        }
        return affected
    }

    /// The block a paragraph belongs to. Normally that is the attribute on its first character;
    /// text inserted without attributes falls back to whatever the rest of the paragraph says.
    private func dominantBlock(in storage: NSTextStorage, paragraph: NSRange) -> BlockAttribute {
        if let first = storage.attribute(.lpBlock, at: paragraph.location, effectiveRange: nil) as? BlockAttribute {
            return first
        }
        var found: BlockAttribute? = nil
        storage.enumerateAttribute(.lpBlock, in: paragraph, options: []) { value, _, stop in
            if let value = value as? BlockAttribute {
                found = value
                stop.pointee = true
            }
        }
        return found ?? .paragraph
    }

    private static func kind(for attachment: BlockAttachment, fallback: BlockKind) -> BlockKind {
        switch attachment.content {
        case .divider: return .rule
        case .image(let info): return .image(info)
        case .table(let info): return .table(info)
        }
    }

    // MARK: Styling

    func style(_ storage: NSTextStorage, paragraph: NSRange, block: BlockAttribute) {
        let kind = block.kind
        for key in NSAttributedString.Key.lpDerivedKeys {
            storage.removeAttribute(key, range: paragraph)
        }
        storage.addAttributes([
            .font: theme.baseFont(for: kind),
            .foregroundColor: theme.textColor(for: kind),
            .paragraphStyle: theme.paragraphStyle(for: kind, indent: block.indent)
        ], range: paragraph)

        let content = storage.contentRange(of: paragraph)
        guard content.length > 0, !kind.isAttachment else { return }

        if kind.isVerbatim {
            for key in NSAttributedString.Key.lpInlineKeys {
                storage.removeAttribute(key, range: paragraph)
            }
            return
        }

        if kind.isChecked {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor.lpInkFaint
            ], range: content)
        }

        // The first line of a titled callout is its title.
        var titleRange = NSRange(location: content.location, length: 0)
        if case .callout(_, _, true) = kind {
            let lineBreak = storage.mutableString.range(of: NSAttributedString.softBreak, options: [], range: content)
            titleRange.length = (lineBreak.location == NSNotFound ? NSMaxRange(content) : lineBreak.location) - content.location
            if titleRange.length > 0 {
                storage.addAttribute(.font, value: theme.font(for: kind, bold: true, italic: false, code: false), range: titleRange)
            }
        }

        var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: content, options: []) { attributes, range, _ in
            let isTitle = NSLocationInRange(range.location, titleRange)
            let extra = presentation(for: attributes, kind: kind, emphasized: isTitle)
            if !extra.isEmpty { changes.append((range, extra)) }
        }
        for (range, extra) in changes {
            storage.addAttributes(extra, range: range)
        }

        if case .todo = kind { markDueDates(in: storage, content: content, isDone: kind.isChecked) }
    }

    /// `📅 2026-11-20` (the Obsidian Tasks format) or `due: 2026-11-20` inside a to-do, with a
    /// time after the date when there is one (`📅 2026-11-20 14:30`, `2:30 pm`, `9am`).
    private static let dueDatePattern = try? NSRegularExpression(
        pattern: "(?:\\x{1F4C5}\\x{FE0F}?|\\b[Dd]ue::?)[ \\t]*(\\d{4}-\\d{2}-\\d{2})"
            + "(?:[ \\t]+(?:\\d{1,2}:\\d{2}(?:[ \\t]?[AaPp][Mm])?|\\d{1,2}[ \\t]?[AaPp][Mm])(?![\\w:]))?"
    )

    /// Sets a task's due date apart as a small chip. The text itself is untouched, so it is saved
    /// exactly as written and can still be edited.
    private func markDueDates(in storage: NSTextStorage, content: NSRange, isDone: Bool) {
        guard let pattern = Self.dueDatePattern else { return }
        let text = storage.string as NSString
        let today = Day.today
        for match in pattern.matches(in: storage.string, range: content) {
            guard let day = Day(iso: text.substring(with: match.range(at: 1))) else { continue }
            let state: String
            let color: NSColor
            if isDone {
                (state, color) = ("done", .lpInkTertiary)
            } else if day < today {
                (state, color) = ("overdue", .lpCritical)
            } else if day == today {
                (state, color) = ("today", .controlAccentColor)
            } else {
                (state, color) = ("later", .lpInkSecondary)
            }
            storage.addAttributes([.lpDueDate: state, .font: theme.chipFont, .foregroundColor: color], range: match.range)

            // The calendar emoji becomes a small icon at the start of the chip rather than a full-size picture.
            let date = match.range(at: 1)
            let prefix = NSRange(location: match.range.location, length: date.location - match.range.location)
            if text.substring(with: prefix).unicodeScalars.contains(where: { $0.value == 0x1F4C5 }) {
                var emoji = prefix
                while emoji.length > 0, text.character(at: NSMaxRange(emoji) - 1) == 0x20 { emoji.length -= 1 }
                storage.addAttributes([.font: theme.chipIconFont, .baselineOffset: 1], range: emoji)
            }
            // A little air between the chip and the word before it.
            let before = match.range.location - 1
            if before >= content.location, text.character(at: before) == 0x20 {
                storage.addAttribute(.kern, value: 5, range: NSRange(location: before, length: 1))
            }
        }
    }

    /// The fonts and colours that a run's semantic attributes call for, beyond the block's base style.
    private func presentation(for attributes: [NSAttributedString.Key: Any], kind: BlockKind,
                              emphasized: Bool = false) -> [NSAttributedString.Key: Any] {
        let isBold = attributes[.lpBold] != nil || emphasized
        let isItalic = attributes[.lpItalic] != nil
        let isCode = attributes[.lpCode] != nil
        let isRaw = attributes[.lpRaw] != nil
        let isLink = attributes[.lpLink] != nil || attributes[.lpWiki] != nil

        var extra: [NSAttributedString.Key: Any] = [:]
        if (isBold && !emphasized) || isItalic || isCode || isRaw {
            extra[.font] = theme.font(for: kind, bold: isBold, italic: isItalic, code: isCode || isRaw)
        }
        if attributes[.lpStrike] != nil {
            extra[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            extra[.strikethroughColor] = NSColor.lpInkSecondary
        }
        if isRaw {
            extra[.foregroundColor] = NSColor.lpInkTertiary
        }
        if isLink {
            extra[.foregroundColor] = kind.isChecked ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.controlAccentColor
            extra[.link] = "lp-link" as NSString
        }
        return extra
    }

    /// Attributes for text about to be typed into `block`, carrying over the given inline styles.
    func typingAttributes(for block: BlockAttribute, inline: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if !block.kind.isVerbatim {
            for key in NSAttributedString.Key.lpInlineKeys where key != .lpEscaped {
                if let value = inline[key] { attributes[key] = value }
            }
        }
        attributes[.lpBlock] = block
        attributes[.font] = theme.baseFont(for: block.kind)
        attributes[.foregroundColor] = theme.textColor(for: block.kind)
        attributes[.paragraphStyle] = theme.paragraphStyle(for: block.kind, indent: block.indent)
        if block.kind.isChecked {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.lpInkFaint
        }
        for (key, value) in presentation(for: attributes, kind: block.kind) {
            attributes[key] = value
        }
        attributes.removeValue(forKey: .link)
        return attributes
    }
}
