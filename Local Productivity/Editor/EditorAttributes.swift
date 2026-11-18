//
//  EditorAttributes.swift
//  Local Productivity
//
//  The editor never shows Markdown syntax, so the meaning of the text has to live
//  somewhere else: in attributes on the text storage. These "semantic" attributes say
//  what a run *is* (bold, a link, part of a to-do item). Fonts and colours are derived
//  from them by `EditorStyler`, and the file on disk is derived from them by
//  `DocumentConverter`. Nothing ever reads meaning back out of a font.
//

import AppKit

nonisolated extension NSAttributedString.Key {
    /// `BlockAttribute`, set on every character of a paragraph including its line ending.
    static let lpBlock = NSAttributedString.Key("LPBlock")
    /// The emphasis delimiter as a `String` ("*" or "_").
    static let lpBold = NSAttributedString.Key("LPBold")
    static let lpItalic = NSAttributedString.Key("LPItalic")
    static let lpStrike = NSAttributedString.Key("LPStrike")
    static let lpHighlight = NSAttributedString.Key("LPHighlight")
    static let lpCode = NSAttributedString.Key("LPCode")
    /// Source kept verbatim, such as inline HTML or math.
    static let lpRaw = NSAttributedString.Key("LPRaw")
    /// A literal character that was backslash-escaped in the file.
    static let lpEscaped = NSAttributedString.Key("LPEscaped")
    /// `LinkAttribute`
    static let lpLink = NSAttributedString.Key("LPLink")
    /// `WikiAttribute`
    static let lpWiki = NSAttributedString.Key("LPWiki")

    /// Presentation only: marks a task's due date so it can be drawn as a chip. The value says how
    /// soon it is: "overdue", "today", "later" or "done".
    static let lpDueDate = NSAttributedString.Key("LPDueDate")

    /// Every key that describes inline meaning.
    static let lpInlineKeys: [NSAttributedString.Key] = [
        .lpBold, .lpItalic, .lpStrike, .lpHighlight, .lpCode, .lpRaw, .lpEscaped, .lpLink, .lpWiki
    ]

    /// Presentation attributes the styler owns and rewrites from scratch.
    static let lpDerivedKeys: [NSAttributedString.Key] = [
        .strikethroughStyle, .strikethroughColor, .underlineStyle, .underlineColor, .link,
        .backgroundColor, .baselineOffset, .kern, .toolTip, .obliqueness, .expansion, .shadow, .superscript, .lpDueDate
    ]
}

// MARK: - Attribute values

/// What kind of block a paragraph is, plus the source details needed to write it back unchanged.
nonisolated final class BlockAttribute: NSObject {

    let kind: BlockKind
    let indent: Int
    let blankLinesBefore: Int?
    let sourceIndent: String?

    init(kind: BlockKind, indent: Int = 0, blankLinesBefore: Int? = nil, sourceIndent: String? = nil) {
        self.kind = kind
        self.indent = max(0, indent)
        self.blankLinesBefore = blankLinesBefore
        self.sourceIndent = sourceIndent
    }

    convenience init(_ block: Block) {
        self.init(kind: block.kind, indent: block.indent, blankLinesBefore: block.blankLinesBefore,
                  sourceIndent: block.sourceIndent)
    }

    static let paragraph = BlockAttribute(kind: .paragraph)

    /// A block of a different kind. Recorded spacing no longer applies once the kind changes.
    func with(kind: BlockKind) -> BlockAttribute {
        BlockAttribute(kind: kind, indent: indent)
    }

    func with(indent: Int) -> BlockAttribute {
        BlockAttribute(kind: kind, indent: indent, blankLinesBefore: blankLinesBefore)
    }

    /// The same block as created fresh in the editor, with no memory of source formatting.
    var fresh: BlockAttribute {
        BlockAttribute(kind: kind, indent: indent)
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockAttribute else { return false }
        return kind == other.kind && indent == other.indent
            && blankLinesBefore == other.blankLinesBefore && sourceIndent == other.sourceIndent
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(indent)
        return hasher.finalize()
    }
}

nonisolated final class LinkAttribute: NSObject {
    let info: LinkInfo

    init(_ info: LinkInfo) {
        self.info = info
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? LinkAttribute)?.info == info
    }

    override var hash: Int { info.hashValue }
}

/// A wiki link. Compared by identity so two links side by side never merge into one.
nonisolated final class WikiAttribute: NSObject {
    let info: WikiLinkInfo

    init(_ info: WikiLinkInfo) {
        self.info = info
    }
}

// MARK: - Inline style bridging

nonisolated enum InlineAttributes {

    static func attributes(for style: InlineStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let bold = style.bold { attributes[.lpBold] = String(bold.rawValue) }
        if let italic = style.italic { attributes[.lpItalic] = String(italic.rawValue) }
        if style.strikethrough { attributes[.lpStrike] = true }
        if style.highlight { attributes[.lpHighlight] = true }
        if style.code { attributes[.lpCode] = true }
        if style.raw { attributes[.lpRaw] = true }
        if style.escaped { attributes[.lpEscaped] = true }
        if let link = style.link { attributes[.lpLink] = LinkAttribute(link) }
        if let wiki = style.wikiLink { attributes[.lpWiki] = WikiAttribute(wiki) }
        return attributes
    }

    static func style(from attributes: [NSAttributedString.Key: Any]) -> InlineStyle {
        var style = InlineStyle()
        if let marker = attributes[.lpBold] as? String { style.bold = marker == "_" ? .underscore : .asterisk }
        if let marker = attributes[.lpItalic] as? String { style.italic = marker == "_" ? .underscore : .asterisk }
        style.strikethrough = attributes[.lpStrike] != nil
        style.highlight = attributes[.lpHighlight] != nil
        style.code = attributes[.lpCode] != nil
        style.raw = attributes[.lpRaw] != nil
        style.escaped = attributes[.lpEscaped] != nil
        style.link = (attributes[.lpLink] as? LinkAttribute)?.info
        style.wikiLink = (attributes[.lpWiki] as? WikiAttribute)?.info
        return style
    }
}

// MARK: - Storage helpers

nonisolated extension NSAttributedString {

    /// The line separator used inside a block. A real newline always ends the block.
    static let softBreak = "\u{2028}"
    static let attachmentCharacter = "\u{FFFC}"

    func block(at location: Int) -> BlockAttribute {
        guard location >= 0, location < length else { return .paragraph }
        return attribute(.lpBlock, at: location, effectiveRange: nil) as? BlockAttribute ?? .paragraph
    }

    /// The range of the paragraph containing `location`, including its line ending.
    func paragraphRange(at location: Int) -> NSRange {
        (string as NSString).paragraphRange(for: NSRange(location: min(max(location, 0), length), length: 0))
    }

    /// Calls `body` with the range of every paragraph that touches `range`.
    func enumerateParagraphs(in range: NSRange, _ body: (NSRange) -> Void) {
        let text = string as NSString
        guard text.length > 0 else { return }
        var location = min(range.location, text.length - 1)
        let end = min(NSMaxRange(range), text.length)
        repeat {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            body(paragraph)
            location = NSMaxRange(paragraph)
        } while location < end && location < text.length
    }

    /// A paragraph's range without its trailing newline.
    func contentRange(of paragraph: NSRange) -> NSRange {
        guard paragraph.length > 0 else { return paragraph }
        let last = (string as NSString).character(at: NSMaxRange(paragraph) - 1)
        return last == 0x0A ? NSRange(location: paragraph.location, length: paragraph.length - 1) : paragraph
    }
}
