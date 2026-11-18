//
//  MarkdownModel.swift
//  Local Productivity
//
//  The in-memory shape of a Markdown file. A document is a flat list of blocks;
//  nesting is expressed with an indent level, exactly like the editor shows it.
//  Details that only matter for writing the file back out the way it was found
//  (which bullet character, how many blank lines, how it was indented) ride along
//  so that opening and editing a note never reformats the parts left untouched.
//

import Foundation

// MARK: - Inline content

/// The delimiter a source document used for emphasis.
nonisolated enum EmphasisMarker: Character, Hashable, Sendable {
    case asterisk = "*"
    case underscore = "_"
}

nonisolated struct LinkInfo: Hashable, Sendable {
    enum Form: Hashable, Sendable {
        case inline          // [text](destination)
        case angleAutolink   // <https://example.com>
        case bareAutolink    // https://example.com
    }

    /// The destination exactly as written in the source.
    var destination: String
    var title: String? = nil
    var form: Form = .inline
}

nonisolated struct WikiLinkInfo: Hashable, Sendable {
    /// The link target as written, for example `Projects/Roadmap#Goals`.
    var target: String
    /// True when the visible text is an alias (`[[target|alias]]`) rather than the target itself.
    var hasAlias: Bool
}

nonisolated struct InlineStyle: Hashable, Sendable {
    var bold: EmphasisMarker? = nil
    var italic: EmphasisMarker? = nil
    var strikethrough = false
    var highlight = false
    var code = false
    /// Source that is preserved verbatim and not interpreted (inline HTML, math, footnote references…).
    var raw = false
    /// A literal character that was backslash-escaped in the source.
    var escaped = false
    var link: LinkInfo? = nil
    var wikiLink: WikiLinkInfo? = nil

    static let plain = InlineStyle()

    var isPlain: Bool { self == .plain }
}

nonisolated struct InlineRun: Hashable, Sendable {
    var text: String
    var style: InlineStyle = .plain

    static func plain(_ text: String) -> InlineRun { InlineRun(text: text) }
}

// MARK: - Blocks

nonisolated struct CodeFence: Hashable, Sendable {
    var character: Character = "`"
    var length: Int = 3
    /// A four-space indented code block, which has no fence at all.
    var isIndented = false

    static let standard = CodeFence()
}

nonisolated struct ImageInfo: Hashable, Sendable {
    /// Path or URL exactly as written.
    var source: String
    var alt: String = ""
    var title: String? = nil
    /// `![[image.png]]` rather than `![alt](image.png)`.
    var isWikiEmbed = false
    /// Obsidian's display width hint, `![[image.png|320]]`.
    var width: Int? = nil
}

nonisolated struct TableInfo: Hashable, Sendable {
    enum Alignment: Hashable, Sendable { case none, left, center, right }

    var alignments: [Alignment]
    /// Cell contents as Markdown source.
    var header: [String]
    var rows: [[String]]
    /// The original text. Written back verbatim until the table is edited.
    var source: String? = nil

    var columnCount: Int { alignments.count }
}

nonisolated enum HeadingStyle: Hashable, Sendable {
    case atx
    case setext(underline: String)
}

nonisolated enum BlockKind: Hashable, Sendable {
    case paragraph
    case heading(level: Int, style: HeadingStyle)
    case bullet(marker: Character)
    /// `number` is the number as written. The first item's sets where the list starts; later
    /// items are renumbered on save unless the list repeats one number throughout ("1. 1. 1.").
    case numbered(number: Int, delimiter: Character)
    /// `status` is the character between the brackets: a space means open, anything else done.
    case todo(status: Character, marker: String)
    case quote
    case callout(type: String, fold: String, hasTitle: Bool)
    case code(info: String, fence: CodeFence)
    case divider(source: String)
    case image(ImageInfo)
    case table(TableInfo)
    /// Markdown this app does not render (HTML blocks, math blocks…). Kept byte for byte.
    case raw
}

nonisolated extension BlockKind {
    static let heading1 = BlockKind.heading(level: 1, style: .atx)
    static let heading2 = BlockKind.heading(level: 2, style: .atx)
    static let heading3 = BlockKind.heading(level: 3, style: .atx)
    static let bulletItem = BlockKind.bullet(marker: "-")
    static let numberedItem = BlockKind.numbered(number: 1, delimiter: ".")
    static let openTodo = BlockKind.todo(status: " ", marker: "-")
    static let codeBlock = BlockKind.code(info: "", fence: .standard)
    static let rule = BlockKind.divider(source: "---")
    static let note = BlockKind.callout(type: "note", fold: "", hasTitle: false)

    /// Characters accepted between the brackets of a task item. Anything else, such as the
    /// `[1]` of a citation, is left as ordinary text.
    static let taskStatuses: Set<Character> = [" ", "x", "X", "-", "/", ">", "<", "!", "?"]

    var isListItem: Bool {
        switch self {
        case .bullet, .numbered, .todo: return true
        default: return false
        }
    }

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    /// Blocks whose whole content is a single attachment in the editor.
    var isAttachment: Bool {
        switch self {
        case .divider, .image, .table: return true
        default: return false
        }
    }

    /// Blocks that hold verbatim text rather than formatted inline content.
    var isVerbatim: Bool {
        switch self {
        case .code, .raw: return true
        default: return false
        }
    }

    /// Blocks where Return adds a line inside the block instead of starting a new one.
    var keepsLineBreaksInside: Bool {
        switch self {
        case .quote, .callout, .code, .raw: return true
        default: return false
        }
    }

    var isChecked: Bool {
        if case .todo(let status, _) = self { return status != " " }
        return false
    }

    var headingLevel: Int? {
        if case .heading(let level, _) = self { return level }
        return nil
    }
}

nonisolated struct Block: Hashable, Sendable {
    var kind: BlockKind
    /// Nesting depth inside lists. Zero is the top level.
    var indent: Int = 0
    /// Inline content. Verbatim blocks hold a single plain run with `\n` between lines.
    var runs: [InlineRun] = []
    /// Blank lines that preceded the block in the source. `nil` means "use the canonical spacing".
    var blankLinesBefore: Int? = nil
    /// Leading whitespace as written. `nil` means "use the canonical indentation".
    var sourceIndent: String? = nil

    var plainText: String { runs.map(\.text).joined() }

    static func paragraph(_ text: String) -> Block {
        Block(kind: .paragraph, runs: text.isEmpty ? [] : [.plain(text)])
    }
}

nonisolated struct MarkdownDocument: Hashable, Sendable {
    /// YAML between the opening and closing `---`, without the fences.
    var frontMatter: String? = nil
    var blocks: [Block] = []
    var usesCRLF = false
    var usesTabIndentation = false

    static let empty = MarkdownDocument()
}

// MARK: - Character classes

nonisolated extension Character {
    /// Unicode punctuation or symbol, the class CommonMark uses for emphasis flanking.
    var isMarkdownPunctuation: Bool { isPunctuation || isSymbol }

    var isASCIIPunctuation: Bool { isASCII && (isPunctuation || isSymbol) }

    var isWordCharacter: Bool { isLetter || isNumber }
}

nonisolated extension StringProtocol {
    var trimmingTrailingWhitespace: String {
        var view = self[...]
        while let last = view.last, last == " " || last == "\t" { view = view.dropLast() }
        return String(view)
    }

    var trimmingWhitespace: String {
        trimmingCharacters(in: .whitespaces)
    }
}
