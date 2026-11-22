//
//  MarkdownParser.swift
//  Local Productivity
//
//  Reads a Markdown file into the flat block model. It follows CommonMark for the
//  constructs it renders, is deliberately forgiving about list indentation (notes
//  written by hand rarely line up to the spec), and keeps whatever it does not
//  understand as `raw` blocks so no text is ever dropped.
//

import Foundation

nonisolated enum MarkdownParser {

    static func parse(_ input: String) -> MarkdownDocument {
        var document = MarkdownDocument()
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.contains("\r\n") {
            document.usesCRLF = true
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        if text.contains("\r") { text = text.replacingOccurrences(of: "\r", with: "\n") }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var start = 0
        if let close = frontMatterEnd(in: lines) {
            document.frontMatter = lines[1..<close].joined(separator: "\n")
            start = close + 1
        }

        var parser = BlockParser(lines: lines, index: start)
        document.blocks = parser.parse()
        document.usesTabIndentation = parser.sawTabIndentation
        return document
    }

    /// Returns the index of the line closing a YAML front matter block, if the file starts with one.
    static func frontMatterEnd(in lines: [String]) -> Int? {
        guard let first = lines.first, first.trimmingTrailingWhitespace == "---" else { return nil }
        guard let close = lines.indices.dropFirst().first(where: {
            let line = lines[$0].trimmingTrailingWhitespace
            return line == "---" || line == "..."
        }) else { return nil }

        // A leading "---" is also how a note can open with a divider. Only treat the block as
        // front matter when it actually reads like YAML.
        var sawKey = false
        for line in lines[1..<close] {
            let trimmed = line.trimmingWhitespace
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first == " " || line.first == "\t" || trimmed.hasPrefix("- ") || trimmed == "-" {
                guard sawKey else { return nil }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":"), colon > trimmed.startIndex else { return nil }
            let afterColon = trimmed[trimmed.index(after: colon)...]
            guard afterColon.isEmpty || afterColon.first == " " || afterColon.first == "\t" else { return nil }
            sawKey = true
        }
        return close
    }
}

// MARK: - Lines

private nonisolated struct Line {
    let raw: String
    /// Width of the leading whitespace in columns, with tabs advancing to the next multiple of four.
    let indent: Int
    let leading: Substring
    let content: Substring

    var isBlank: Bool { content.isEmpty }

    init(_ raw: String) {
        self.raw = raw
        var columns = 0
        var position = raw.startIndex
        while position < raw.endIndex {
            let character = raw[position]
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - (columns % 4)
            } else {
                break
            }
            position = raw.index(after: position)
        }
        indent = columns
        leading = raw[..<position]
        content = raw[position...]
    }

    /// The line with up to `columns` columns of leading whitespace removed.
    func dropping(columns: Int) -> String {
        var removed = 0
        var position = raw.startIndex
        while position < raw.endIndex, removed < columns {
            let character = raw[position]
            if character == " " {
                removed += 1
            } else if character == "\t" {
                let width = 4 - (removed % 4)
                if removed + width > columns {
                    let leftover = removed + width - columns
                    return String(repeating: " ", count: leftover) + raw[raw.index(after: position)...]
                }
                removed += width
            } else {
                break
            }
            position = raw.index(after: position)
        }
        return String(raw[position...])
    }
}

// MARK: - Block parser

private nonisolated struct BlockParser {

    private struct ListLevel {
        var markerColumn: Int
        var contentColumn: Int
        var isNumbered: Bool
    }

    private struct ListMarker {
        var kind: BlockKind
        var text: String
        var contentColumn: Int
    }

    private struct FenceOpening {
        var character: Character
        var length: Int
        var info: String
    }

    private enum RawBlockEnd {
        /// Runs until the next blank line.
        case blankLine
        /// Runs through the first line containing the text, which may be the opening line itself.
        case lineContaining(String)
        /// Runs through the first line after the opening one that contains the text.
        case laterLineContaining(String)
    }

    let lines: [String]
    var index: Int
    var sawTabIndentation = false
    private var listStack: [ListLevel] = []

    init(lines: [String], index: Int) {
        self.lines = lines
        self.index = index
    }

    mutating func parse() -> [Block] {
        var blocks: [Block] = []
        var blankLines = 0
        while index < lines.count {
            let line = Line(lines[index])
            if line.isBlank {
                blankLines += 1
                index += 1
                continue
            }
            var block = parseBlock(line)
            if blankLines >= 2, !blocks.isEmpty {
                // One blank line separates blocks. Any more are lines the writer left empty on
                // purpose, so they show up in the editor as empty paragraphs.
                blocks.append(Block(kind: .paragraph, blankLinesBefore: 1))
                for _ in 0..<(blankLines - 2) {
                    blocks.append(Block(kind: .paragraph, blankLinesBefore: 0))
                }
                block.blankLinesBefore = 0
            } else {
                block.blankLinesBefore = blankLines
            }
            blankLines = 0
            blocks.append(block)
        }
        return blocks
    }

    private mutating func parseBlock(_ line: Line) -> Block {
        if !Self.isThematicBreak(line.content), let marker = Self.listMarker(in: line) {
            return parseListItem(line, marker)
        }

        // Anything else belongs to the innermost list item it is indented far enough to sit inside.
        while let top = listStack.last, top.contentColumn > line.indent { listStack.removeLast() }
        let depth = listStack.count
        let base = listStack.last?.contentColumn ?? 0

        var block: Block
        if line.indent - base >= 4 {
            block = parseIndentedCode(base: base)
        } else if let fence = Self.fenceOpening(line.content) {
            block = parseFencedCode(line, fence, base: base)
        } else if let heading = Self.atxHeading(line.content) {
            index += 1
            block = heading
        } else if Self.isThematicBreak(line.content) {
            index += 1
            block = Block(kind: .divider(source: line.content.trimmingTrailingWhitespace))
        } else if line.content.hasPrefix(">") {
            block = parseQuote()
        } else if isTableStart(at: index) {
            block = parseTable(base: base)
        } else if let end = Self.rawBlockEnd(line.content, atBlockStart: true) {
            block = parseRaw(until: end, base: base)
        } else {
            block = parseParagraph(base: base)
        }

        block.indent = depth
        if depth > 0 {
            block.sourceIndent = String(line.leading)
            if line.leading.contains("\t") { sawTabIndentation = true }
        }
        return block
    }

    // MARK: Lists

    private static func listMarker(in line: Line) -> ListMarker? {
        let content = line.content
        guard let first = content.first else { return nil }

        var kind: BlockKind
        let markerText: String
        if first == "-" || first == "*" || first == "+" {
            kind = .bullet(marker: first)
            markerText = String(first)
        } else if first.isASCII, first.isNumber {
            let digits = content.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count <= 9 else { return nil }
            guard let delimiter = content.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else {
                return nil
            }
            kind = .numbered(number: Int(digits) ?? 1, delimiter: delimiter)
            markerText = String(digits) + String(delimiter)
        } else {
            return nil
        }

        var rest = content.dropFirst(markerText.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var padding = 0
        while let character = rest.first, character == " " || character == "\t" {
            padding += character == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        if rest.isEmpty || padding > 4 { padding = 1 }

        var text = String(rest)
        let head = Array(text.prefix(4))
        if head.count >= 3, head[0] == "[", head[2] == "]", BlockKind.taskStatuses.contains(head[1]),
           head.count == 3 || head[3] == " " || head[3] == "\t" {
            text = String(text.dropFirst(3).drop(while: { $0 == " " || $0 == "\t" }))
            kind = .todo(status: head[1], marker: markerText)
        }
        return ListMarker(kind: kind, text: text, contentColumn: line.indent + markerText.count + padding)
    }

    private mutating func parseListItem(_ line: Line, _ marker: ListMarker) -> Block {
        // Nesting is decided by where the marker sits relative to the items above it.
        while let top = listStack.last, top.markerColumn >= line.indent {
            listStack.removeLast()
        }
        let depth = listStack.count

        let kind = marker.kind
        var isNumbered = false
        if case .numbered = kind { isNumbered = true }
        listStack.append(ListLevel(markerColumn: line.indent, contentColumn: marker.contentColumn, isNumbered: isNumbered))
        if line.leading.contains("\t") { sawTabIndentation = true }
        index += 1

        var textLines = [marker.text]
        if !marker.text.isEmpty {
            while index < lines.count {
                let next = Line(lines[index])
                if next.isBlank || interruptsParagraph(next) { break }
                textLines.append(String(next.content))
                index += 1
            }
        }

        var block = Block(kind: kind, indent: depth, runs: InlineParser.parse(textLines.joined(separator: "\n")))
        block.sourceIndent = String(line.leading)
        return block
    }

    /// True when `line` ends the paragraph (or list item text) before it instead of continuing it.
    private func interruptsParagraph(_ line: Line) -> Bool {
        let content = line.content
        if Self.atxHeading(content) != nil { return true }
        if Self.fenceOpening(content) != nil { return true }
        if content.hasPrefix(">") { return true }
        if Self.isThematicBreak(content) { return true }
        if let marker = Self.listMarker(in: line) {
            if !listStack.isEmpty { return true }
            if marker.text.isEmpty { return false }
            if case .numbered(let number, _) = marker.kind { return number == 1 }
            return true
        }
        return Self.rawBlockEnd(content, atBlockStart: false) != nil
    }

    // MARK: Paragraphs and headings

    private mutating func parseParagraph(base: Int) -> Block {
        var textLines = [String(Line(lines[index]).content)]
        index += 1
        var heading: BlockKind? = nil

        while index < lines.count {
            let next = Line(lines[index])
            if next.isBlank { break }
            if next.indent - base < 4 {
                let underline = next.content.trimmingTrailingWhitespace
                if underline.allSatisfy({ $0 == "=" }) {
                    heading = .heading(level: 1, style: .setext(underline: underline))
                    index += 1
                    break
                }
                if underline.allSatisfy({ $0 == "-" }) {
                    heading = .heading(level: 2, style: .setext(underline: underline))
                    index += 1
                    break
                }
            }
            if interruptsParagraph(next) || isTableStart(at: index) { break }
            textLines.append(String(next.content))
            index += 1
        }

        if let heading {
            let text = textLines.map(\.trimmingTrailingWhitespace).joined(separator: "\n")
            return Block(kind: heading, runs: InlineParser.parse(text))
        }
        if textLines.count == 1, let image = Self.imageBlock(textLines[0]) {
            return Block(kind: .image(image))
        }
        return Block(kind: .paragraph, runs: InlineParser.parse(textLines.joined(separator: "\n")))
    }

    private static func atxHeading(_ content: Substring) -> Block? {
        let hashes = content.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = content.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }

        var text = rest.trimmingWhitespace
        if let lastOther = text.lastIndex(where: { $0 != "#" }) {
            // An optional closing run of #s, which must be set off by a space.
            if text.index(after: lastOther) < text.endIndex, text[lastOther] == " " || text[lastOther] == "\t" {
                text = String(text[...lastOther]).trimmingWhitespace
            }
        } else {
            text = ""
        }
        return Block(kind: .heading(level: hashes.count, style: .atx), runs: InlineParser.parse(text))
    }

    private static func isThematicBreak(_ content: Substring) -> Bool {
        guard let first = content.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for character in content {
            if character == first {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    // MARK: Images

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "bmp", "tiff", "tif", "avif", "ico"
    ]

    private static func imageBlock(_ text: String) -> ImageInfo? {
        let trimmed = text.trimmingWhitespace
        if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]") {
            let inner = String(trimmed.dropFirst(3).dropLast(2))
            guard !inner.isEmpty, !inner.contains("[["), !inner.contains("]]") else { return nil }
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let path = parts[0].split(separator: "#", maxSplits: 1).first.map(String.init) ?? parts[0]
            guard let ext = path.split(separator: ".").last, path.contains("."),
                  imageExtensions.contains(ext.lowercased()) else { return nil }
            var info = ImageInfo(source: parts[0], isWikiEmbed: true)
            if parts.count > 1 {
                if let width = Self.widthHint(parts[1]) { info.width = width } else { info.alt = parts[1] }
            }
            return info
        }

        guard let image = InlineParser.standaloneImage(trimmed) else { return nil }
        var info = ImageInfo(source: image.destination, alt: image.alt, title: image.title)
        if let pipe = image.alt.lastIndex(of: "|"), let width = Self.widthHint(String(image.alt[image.alt.index(after: pipe)...])) {
            info.alt = String(image.alt[..<pipe])
            info.width = width
        }
        return info
    }

    /// Obsidian's size suffix: `320` or `320x200`.
    private static func widthHint(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "x" }) else { return nil }
        return text.split(separator: "x").first.flatMap { Int($0) }
    }

    // MARK: Quotes and callouts

    private mutating func parseQuote() -> Block {
        var inner: [String] = []
        while index < lines.count {
            let line = Line(lines[index])
            if line.isBlank { break }
            if line.content.hasPrefix(">") {
                var rest = line.content.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                inner.append(String(rest))
            } else if inner.isEmpty || inner.last?.isEmpty == true || interruptsParagraph(line) {
                break
            } else {
                inner.append(String(line.content))
            }
            index += 1
        }

        if let first = inner.first, first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
            let type = String(first[first.index(first.startIndex, offsetBy: 2)..<close])
            var rest = first[first.index(after: close)...]
            var fold = ""
            if let character = rest.first, character == "+" || character == "-" {
                fold = String(character)
                rest = rest.dropFirst()
            }
            if !type.isEmpty, !type.contains(where: \.isWhitespace),
               rest.isEmpty || rest.first == " " || rest.first == "\t" {
                let title = rest.trimmingWhitespace
                var body = Array(inner.dropFirst())
                if !title.isEmpty { body.insert(title, at: 0) }
                return Block(kind: .callout(type: type, fold: fold, hasTitle: !title.isEmpty),
                             runs: InlineParser.parse(body.joined(separator: "\n")))
            }
        }
        return Block(kind: .quote, runs: InlineParser.parse(inner.joined(separator: "\n")))
    }

    // MARK: Code

    private static func fenceOpening(_ content: Substring) -> FenceOpening? {
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let run = content.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let info = content.dropFirst(run.count).trimmingWhitespace
        if first == "`", info.contains("`") { return nil }
        return FenceOpening(character: first, length: run.count, info: info)
    }

    private mutating func parseFencedCode(_ line: Line, _ fence: FenceOpening, base: Int) -> Block {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let next = Line(lines[index])
            let trimmed = next.content.trimmingTrailingWhitespace
            index += 1
            // A closing fence is indented less than four columns; one indented further is a line
            // of the code (CommonMark).
            if next.indent - base < 4, trimmed.count >= fence.length, trimmed.allSatisfy({ $0 == fence.character }) { break }
            body.append(next.dropping(columns: line.indent))
        }
        let text = body.joined(separator: "\n")
        return Block(kind: .code(info: fence.info, fence: CodeFence(character: fence.character, length: fence.length)),
                     runs: text.isEmpty ? [] : [.plain(text)])
    }

    private mutating func parseIndentedCode(base: Int) -> Block {
        var body: [String] = []
        var pendingBlank = 0
        while index < lines.count {
            let next = Line(lines[index])
            if next.isBlank {
                pendingBlank += 1
                index += 1
                continue
            }
            if next.indent - base < 4 { break }
            body.append(contentsOf: Array(repeating: "", count: pendingBlank))
            pendingBlank = 0
            body.append(next.dropping(columns: base + 4))
            index += 1
        }
        index -= pendingBlank
        return Block(kind: .code(info: "", fence: CodeFence(isIndented: true)),
                     runs: [.plain(body.joined(separator: "\n"))])
    }

    // MARK: Tables

    private func isTableStart(at position: Int) -> Bool {
        guard position + 1 < lines.count, lines[position].contains("|"),
              let alignments = Self.delimiterRow(lines[position + 1]) else { return false }
        return Self.cells(of: lines[position]).count == alignments.count
    }

    private static func delimiterRow(_ raw: String) -> [TableInfo.Alignment]? {
        guard raw.contains("|"), raw.contains("-") else { return nil }
        var alignments: [TableInfo.Alignment] = []
        for cell in cells(of: raw) {
            guard !cell.isEmpty else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            var dashes = cell[...]
            if left { dashes = dashes.dropFirst() }
            if right, !dashes.isEmpty { dashes = dashes.dropLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return alignments.isEmpty ? nil : alignments
    }

    static func cells(of raw: String) -> [String] {
        var text = raw.trimmingWhitespace
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingWhitespace)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingWhitespace)
        return cells
    }

    private mutating func parseTable(base: Int) -> Block {
        let first = index
        let header = Self.cells(of: lines[index])
        let alignments = Self.delimiterRow(lines[index + 1]) ?? []
        index += 2

        var rows: [[String]] = []
        while index < lines.count {
            let next = Line(lines[index])
            if next.isBlank || !next.raw.contains("|") || interruptsParagraph(next) { break }
            var cells = Self.cells(of: next.raw)
            if cells.count < alignments.count {
                cells += Array(repeating: "", count: alignments.count - cells.count)
            } else if cells.count > alignments.count {
                cells = Array(cells.prefix(alignments.count))
            }
            rows.append(cells)
            index += 1
        }
        let source = lines[first..<index].map { Line($0).dropping(columns: base) }.joined(separator: "\n")
        return Block(kind: .table(TableInfo(alignments: alignments, header: header, rows: rows, source: source)))
    }

    // MARK: Raw blocks (HTML, math, comments)

    private static let htmlBlockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html",
        "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup",
        "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
        "title", "tr", "track", "ul"
    ]

    /// Decides whether `content` opens a block that is kept verbatim, and how that block ends.
    /// Math blocks, comment blocks and a lone inline tag on its own line only count at the start
    /// of a block; they cannot cut a paragraph short.
    private static func rawBlockEnd(_ content: Substring, atBlockStart: Bool) -> RawBlockEnd? {
        if content.hasPrefix("$$") {
            guard atBlockStart else { return nil }
            let rest = content.dropFirst(2).trimmingTrailingWhitespace
            return rest.count >= 2 && rest.hasSuffix("$$") ? .lineContaining("$$") : .laterLineContaining("$$")
        }
        if content.hasPrefix("%%") {
            guard atBlockStart, !content.dropFirst(2).contains("%%") else { return nil }
            return .laterLineContaining("%%")
        }
        guard content.hasPrefix("<") else { return nil }

        let lowered = content.lowercased()
        if lowered.hasPrefix("<!--") { return .lineContaining("-->") }
        if lowered.hasPrefix("<?") { return .lineContaining("?>") }
        for tag in ["script", "pre", "style", "textarea"] where lowered.hasPrefix("<\(tag)") {
            let after = lowered.dropFirst(tag.count + 1).first
            if after == nil || after == " " || after == ">" || after == "\t" { return .lineContaining("</\(tag)>") }
        }

        var rest = content.dropFirst()
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        let name = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        guard let first = name.first, first.isLetter else { return nil }
        let after = rest.dropFirst(name.count)
        let endsTagName = after.isEmpty || after.first == " " || after.first == "\t" || after.first == ">" || after.hasPrefix("/>")
        guard endsTagName else { return nil }

        if htmlBlockTags.contains(name.lowercased()) { return .blankLine }
        if atBlockStart {
            // One complete tag alone on its line, e.g. `<br>` or `<center>`.
            let line = content.trimmingTrailingWhitespace
            if line.hasSuffix(">"), !line.dropFirst().contains("<"),
               line.firstIndex(of: ">") == line.index(before: line.endIndex) {
                return .blankLine
            }
        }
        return nil
    }

    private mutating func parseRaw(until end: RawBlockEnd, base: Int) -> Block {
        var body: [String] = []
        var isOpeningLine = true
        scan: while index < lines.count {
            let next = Line(lines[index])
            switch end {
            case .blankLine:
                if next.isBlank { break scan }
                body.append(next.dropping(columns: base))
                index += 1
            case .lineContaining(let marker):
                body.append(next.dropping(columns: base))
                index += 1
                if next.raw.contains(marker) { break scan }
            case .laterLineContaining(let marker):
                body.append(next.dropping(columns: base))
                index += 1
                if !isOpeningLine, next.raw.contains(marker) { break scan }
            }
            isOpeningLine = false
        }
        return Block(kind: .raw, runs: [.plain(body.joined(separator: "\n"))])
    }
}
