//
//  MarkdownSerializer.swift
//  Local Productivity
//
//  Writes the block model back out as Markdown. Two promises matter here:
//
//  1. What is written parses back to the same blocks. Spacing and escaping are
//     chosen so no block is swallowed by, or mistaken for, its neighbour.
//  2. Blocks that were not changed are written the way they were found, using the
//     indentation, markers and blank lines recorded when the file was read.
//

import Foundation

/// Remembers how paragraphs were written last time, so saving a long note again only does the
/// work for paragraphs that changed. Keeps the entries the last save used. Safe to share between
/// a background warm-up and saving: entries are pure results, so which pass stored one never
/// affects what is written.
nonisolated final class SerializerCache: @unchecked Sendable {
    fileprivate struct Key: Hashable {
        var runs: [InlineRun]
        var context: String
    }
    private let lock = NSLock()
    private var current: [Key: [String]] = [:]
    private var previous: [Key: [String]] = [:]

    init() {}

    fileprivate func lines(for key: Key, make: () -> [String]) -> [String] {
        lock.lock()
        if let found = current[key] ?? previous[key] {
            current[key] = found
            lock.unlock()
            return found
        }
        lock.unlock()
        // The work happens outside the lock so a long warm-up never holds up saving.
        let made = make()
        lock.lock()
        current[key] = made
        lock.unlock()
        return made
    }

    fileprivate func finishPass() {
        lock.lock()
        previous.merge(current) { _, new in new }
        // Entries not used by this pass go on the next one, keeping the cache to one page's worth.
        if previous.count > 2 * max(current.count, 64) { previous = current }
        current = [:]
        lock.unlock()
    }
}

nonisolated enum MarkdownSerializer {

    /// Set while serializing with a cache (see `serialize(_:cache:)`).
    @TaskLocal private static var cache: SerializerCache?

    /// Writes `document`, reusing what `cache` remembers from the previous save of the same page.
    static func serialize(_ document: MarkdownDocument, cache: SerializerCache) -> String {
        let text = $cache.withValue(cache) { serialize(document) }
        cache.finishPass()
        return text
    }

    static func serialize(_ document: MarkdownDocument) -> String {
        // Text that came from the editor is still backed by its text storage, which is very slow to
        // walk character by character. One native copy up front makes writing and checking fast.
        var document = document
        for blockIndex in document.blocks.indices {
            for runIndex in document.blocks[blockIndex].runs.indices {
                document.blocks[blockIndex].runs[runIndex].text.makeContiguousUTF8()
            }
        }
        var lines: [String] = []
        let hasFrontMatter = document.frontMatter != nil
        if let frontMatter = document.frontMatter {
            lines.append("---")
            if !frontMatter.isEmpty { lines.append(contentsOf: frontMatter.components(separatedBy: "\n")) }
            lines.append("---")
        }

        var levels: [ListLevel] = []
        var previous: Block? = nil

        for block in document.blocks {
            var blank = block.blankLinesBefore ?? defaultBlankLines(before: block, after: previous, hasFrontMatter: hasFrontMatter)
            blank = max(blank, minimumBlankLines(before: block, after: previous))
            lines.append(contentsOf: repeatElement("", count: blank))
            defer { previous = block }

            if block.isEmptyParagraph {
                // Empty paragraphs are just blank lines; they do not interrupt a list.
                lines.append("")
                continue
            }

            let depth = min(max(block.indent, 0), levels.count)
            let parent = depth > 0 ? levels[depth - 1] : nil

            if block.kind.isListItem {
                let sibling = depth < levels.count ? levels[depth] : nil
                let prefix: String
                if let source = block.sourceIndent, isValidItemIndent(columns(of: source), parent: parent, sibling: sibling) {
                    prefix = source
                } else if let sibling {
                    prefix = sibling.prefix
                } else {
                    prefix = canonicalIndent(depth: depth, parent: parent, tabs: document.usesTabIndentation)
                }

                var marker = "-"
                var task = ""
                var number: Int? = nil
                var isLazy = false
                var restarts = false
                switch block.kind {
                case .bullet(let character):
                    marker = String(character)
                case .numbered(let written, let delimiter):
                    var value = written
                    if let sibling, let last = sibling.lastNumber {
                        // Extra blank lines are kept as empty paragraphs, so look at both.
                        let afterBlankLine = (block.blankLinesBefore ?? 0) > 0 || previous?.isEmptyParagraph == true
                        if block.blankLinesBefore != nil, afterBlankLine,
                           let previousNumber = sibling.lastWritten, written <= previousNumber {
                            // Two lists separated only by blank lines read as one list. When the
                            // second one counts from the start again, it keeps its own numbers.
                            restarts = true
                        } else {
                            // A list written "1. 1. 1." stays that way; any other list counts up. The
                            // style is read from the first two items, when both came from the file.
                            if sibling.numberedCount == 1 {
                                isLazy = sibling.fromSource && block.blankLinesBefore != nil && written == last
                            } else {
                                isLazy = sibling.isLazy
                            }
                            value = isLazy ? last : last + 1
                        }
                    }
                    marker = "\(value)\(delimiter)"
                    number = value
                case .todo(let status, let source):
                    marker = source
                    task = "[\(status)]"
                default:
                    break
                }

                let numberedCount = number == nil ? 0 : (sibling?.lastNumber == nil || restarts ? 1 : (sibling?.numberedCount ?? 0) + 1)
                var lastWritten: Int? = nil
                if block.blankLinesBefore != nil, case .numbered(let written, _) = block.kind { lastWritten = written }
                levels.removeSubrange(depth...)
                let markerColumn = columns(of: prefix)
                levels.append(ListLevel(prefix: prefix, markerColumn: markerColumn,
                                        contentColumn: markerColumn + marker.count + 1, lastNumber: number,
                                        numberedCount: numberedCount, isLazy: isLazy,
                                        fromSource: block.blankLinesBefore != nil, lastWritten: lastWritten))

                let text = bodyLines(block.runs, as: task.isEmpty ? .listItem : .taskItem)
                var first = prefix + marker
                if !task.isEmpty { first += " " + task }
                if let head = text.first { first += " " + head }
                lines.append(first)
                let continuation = prefix + String(repeating: " ", count: marker.count + 1)
                for line in text.dropFirst() {
                    lines.append(line.isEmpty ? "" : continuation + line)
                }
            } else {
                var prefix = ""
                if let parent {
                    let canonical = canonicalIndent(depth: depth, parent: parent, tabs: document.usesTabIndentation)
                    prefix = canonical
                    if let source = block.sourceIndent, !block.kind.isIndentedCode {
                        let extra = columns(of: source) - parent.contentColumn
                        if extra >= 0, extra < 4 { prefix = source }
                    }
                }
                levels.removeSubrange(depth...)
                for line in render(block, insideList: depth > 0) {
                    lines.append(line.isEmpty ? "" : prefix + line)
                }
            }
        }

        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        if !hasFrontMatter, lines.first?.trimmingTrailingWhitespace == "---" {
            // A note that opens with a "---" divider would be read as front matter if a later line
            // closes it; only then does the divider need a blank line above it.
            let written = lines.joined(separator: "\n").components(separatedBy: "\n")
            if MarkdownParser.frontMatterEnd(in: written) != nil { lines.insert("", at: 0) }
        }
        var text = lines.joined(separator: "\n") + "\n"
        if document.usesCRLF { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        return text
    }

    // MARK: List structure

    private struct ListLevel {
        var prefix: String
        var markerColumn: Int
        var contentColumn: Int
        var lastNumber: Int?
        /// How many numbered items in a row this level has seen.
        var numberedCount = 0
        /// The list repeats one number for every item.
        var isLazy = false
        /// The item was read from the file rather than made in the editor.
        var fromSource = false
        /// The number written in the file for the last item, when it came from the file.
        var lastWritten: Int? = nil
    }

    private static func columns(of whitespace: String) -> Int {
        var columns = 0
        for character in whitespace {
            columns += character == "\t" ? 4 - (columns % 4) : 1
        }
        return columns
    }

    /// An item's recorded indentation can be reused when it still nests the item where the model says.
    private static func isValidItemIndent(_ columns: Int, parent: ListLevel?, sibling: ListLevel?) -> Bool {
        if let parent, columns <= parent.markerColumn { return false }
        if let sibling, columns > sibling.markerColumn { return false }
        if parent == nil, sibling == nil, columns >= 4 { return false }
        return true
    }

    private static func canonicalIndent(depth: Int, parent: ListLevel?, tabs: Bool) -> String {
        guard let parent else { return "" }
        if tabs, depth * 4 >= parent.contentColumn { return String(repeating: "\t", count: depth) }
        return String(repeating: " ", count: parent.contentColumn)
    }

    private static func looksLikeTask(_ text: String) -> Bool {
        let head = Array(text.prefix(4))
        return head.count >= 3 && head[0] == "[" && head[2] == "]" && BlockKind.taskStatuses.contains(head[1])
            && (head.count == 3 || head[3] == " " || head[3] == "\t")
    }

    // MARK: Text that must stay one block

    private enum TextContext {
        case paragraph(insideList: Bool)
        case listItem
        case taskItem
    }

    /// The lines of a paragraph or list item. A line is only escaped when, left bare, the text
    /// would stop reading back as this single block — "1. Introduction" at the start of a
    /// paragraph, say. Checking by parsing keeps untouched notes exactly as they were written.
    private static func bodyLines(_ runs: [InlineRun], as context: TextContext) -> [String] {
        guard let cache else { return makeBodyLines(runs, as: context) }
        return cache.lines(for: SerializerCache.Key(runs: runs, context: "\(context)")) { makeBodyLines(runs, as: context) }
    }

    private static func makeBodyLines(_ runs: [InlineRun], as context: TextContext) -> [String] {
        let lines = textLines(runs)
        guard !lines.isEmpty, !readsBackAsOneBlock(lines, as: context) else { return lines }

        var escaped = lines
        switch context {
        case .paragraph:
            escaped = lines.map(InlineSerializer.escapingBlockStart)
        case .listItem, .taskItem:
            if case .listItem = context, looksLikeTask(escaped[0]) { escaped[0] = "\\" + escaped[0] }
            for index in escaped.indices.dropFirst() {
                escaped[index] = InlineSerializer.escapingBlockStart(escaped[index])
            }
        }
        return escaped
    }

    private static func readsBackAsOneBlock(_ lines: [String], as context: TextContext) -> Bool {
        // A single line that starts with a letter cannot open any other kind of block (heading,
        // list, quote, code, table, HTML, math…), so it reads back as this block without checking.
        if lines.count == 1, lines[0].first?.isLetter == true { return true }
        let indented = lines.map { $0.isEmpty ? "" : "  " + $0 }
        let candidate: [String]
        let expectedIndex: Int
        switch context {
        case .paragraph(let insideList):
            candidate = insideList ? ["- x", ""] + indented : lines
            expectedIndex = insideList ? 1 : 0
        case .listItem:
            candidate = ["- " + lines[0]] + indented.dropFirst()
            expectedIndex = 0
        case .taskItem:
            candidate = ["- [ ] " + lines[0]] + indented.dropFirst()
            expectedIndex = 0
        }

        let parsed = MarkdownParser.parse(candidate.joined(separator: "\n"))
        guard parsed.frontMatter == nil, parsed.blocks.count == expectedIndex + 1 else { return false }
        let block = parsed.blocks[expectedIndex]
        switch (context, block.kind) {
        case (.paragraph, .paragraph), (.listItem, .bullet), (.taskItem, .todo): break
        default: return false
        }
        return InlineSerializer.isEquivalent(block.runs, InlineParser.parse(lines.joined(separator: "\n")))
    }

    // MARK: Spacing

    private static func defaultBlankLines(before block: Block, after previous: Block?, hasFrontMatter: Bool) -> Int {
        guard let previous else { return hasFrontMatter ? 1 : 0 }
        if previous.isEmptyParagraph { return 0 }
        if block.kind.isListItem, previous.kind.isListItem {
            // Items of one list sit together; a numbered list next to a bulleted one is a new list.
            let changesListType = block.kind.isNumbered != previous.kind.isNumbered
            return changesListType && block.indent == 0 && previous.indent == 0 ? 1 : 0
        }
        return 1
    }

    /// The fewest blank lines that keep `block` from being absorbed into, or reinterpreted by, `previous`.
    private static func minimumBlankLines(before block: Block, after previous: Block?) -> Int {
        guard let previous else { return 0 }
        if previous.isEmptyParagraph || block.isEmptyParagraph { return 0 }

        switch previous.kind {
        case .raw, .table: return 1
        default: break
        }

        // Does the previous block end in text that would swallow a following line of plain text?
        let previousAbsorbs: Bool
        switch previous.kind {
        case .paragraph, .image, .bullet, .numbered, .todo, .quote, .callout: previousAbsorbs = true
        default: previousAbsorbs = false
        }

        switch block.kind {
        case .paragraph, .image, .raw, .divider:
            return previousAbsorbs ? 1 : 0
        case .heading(_, let style):
            if case .setext = style { return previousAbsorbs ? 1 : 0 }
            return 0
        case .bullet, .numbered, .todo:
            if previous.kind.isListItem || !previousAbsorbs { return 0 }
            if block.plainText.trimmingWhitespace.isEmpty { return 1 }
            if case .numbered(let number, _) = block.kind, number != 1 { return 1 }
            if case .todo(_, let marker) = block.kind, marker.first?.isNumber == true, !marker.hasPrefix("1") { return 1 }
            return 0
        case .quote, .callout:
            switch previous.kind {
            case .quote, .callout: return 1
            default: return 0
            }
        case .code(_, let fence):
            return fence.isIndented ? 1 : 0
        case .table:
            return 1
        }
    }

    // MARK: Blocks

    private static func textLines(_ runs: [InlineRun]) -> [String] {
        var lines = InlineSerializer.serialize(runs)
            .components(separatedBy: "\n")
            .map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingWhitespace.isEmpty { lines.removeLast() }
        return lines
    }

    private static func quoteLine(_ line: String) -> String {
        line.isEmpty ? ">" : "> " + line
    }

    private static func render(_ block: Block, insideList: Bool) -> [String] {
        switch block.kind {
        case .paragraph, .bullet, .numbered, .todo:
            return bodyLines(block.runs, as: .paragraph(insideList: insideList))

        case .heading(let level, let style):
            let text = textLines(block.runs)
            if case .setext(let underline) = style, !text.isEmpty {
                return text.map(InlineSerializer.escapingBlockStart) + [underline]
            }
            let hashes = String(repeating: "#", count: min(max(level, 1), 6))
            var title = text.joined(separator: " ").trimmingWhitespace
            if title.hasSuffix("#") {
                // A trailing run of #s set off by a space would be read as a closing sequence.
                let body = title.reversed().drop(while: { $0 == "#" })
                if body.isEmpty || body.first == " " {
                    let cut = title.index(title.endIndex, offsetBy: -(title.count - body.count))
                    title.insert("\\", at: cut)
                }
            }
            return [title.isEmpty ? hashes : "\(hashes) \(title)"]

        case .quote:
            return InlineSerializer.serialize(block.runs).components(separatedBy: "\n").map(quoteLine)

        case .callout(let type, let fold, let hasTitle):
            var body = InlineSerializer.serialize(block.runs).components(separatedBy: "\n")
            var header = "> [!\(type)]\(fold)"
            if hasTitle, let title = body.first {
                body.removeFirst()
                if !title.trimmingWhitespace.isEmpty { header += " " + title }
            }
            if body == [""] { body = [] }
            return [header] + body.map(quoteLine)

        case .code(let info, let fence):
            let text = block.plainText
            let body = text.isEmpty ? [] : text.components(separatedBy: "\n")
            if fence.isIndented {
                return body.map { $0.isEmpty ? "" : "    " + $0 }
            }
            var length = max(3, fence.length)
            for line in body {
                let trimmed = line.drop(while: { $0 == " " })
                let run = trimmed.prefix(while: { $0 == fence.character }).count
                if run >= length, trimmed.dropFirst(run).trimmingWhitespace.isEmpty { length = run + 1 }
            }
            let marker = String(repeating: String(fence.character), count: length)
            return [marker + info] + body + [marker]

        case .divider(let source):
            return [source.isEmpty ? "---" : source]

        case .image(let image):
            return [imageMarkdown(image)]

        case .table(let table):
            if let source = table.source { return source.components(separatedBy: "\n") }
            return tableLines(table)

        case .raw:
            return block.plainText.components(separatedBy: "\n")
        }
    }

    static func imageMarkdown(_ image: ImageInfo) -> String {
        if image.isWikiEmbed {
            if let width = image.width { return "![[\(image.source)|\(width)]]" }
            return image.alt.isEmpty ? "![[\(image.source)]]" : "![[\(image.source)|\(image.alt)]]"
        }
        var destination = image.source
        if destination.contains(where: \.isWhitespace) || destination.contains("(") || destination.contains(")") {
            destination = "<\(destination)>"
        }
        let alt = image.width.map { "\(image.alt)|\($0)" } ?? image.alt
        if let title = image.title {
            return "![\(alt)](\(destination) \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\")"
        }
        return "![\(alt)](\(destination))"
    }

    static func tableLines(_ table: TableInfo) -> [String] {
        let count = table.columnCount
        guard count > 0 else { return [] }
        func cell(_ cells: [String], _ column: Int) -> String { column < cells.count ? cells[column] : "" }

        var widths = Array(repeating: 3, count: count)
        for column in 0..<count {
            widths[column] = max(widths[column], cell(table.header, column).count)
            for row in table.rows { widths[column] = max(widths[column], cell(row, column).count) }
        }

        func line(_ cells: [String]) -> String {
            let padded = (0..<count).map { column -> String in
                let text = cell(cells, column)
                let gap = String(repeating: " ", count: max(0, widths[column] - text.count))
                switch table.alignments[column] {
                case .right: return gap + text
                case .center:
                    let left = gap.count / 2
                    return String(repeating: " ", count: left) + text + String(repeating: " ", count: gap.count - left)
                default: return text + gap
                }
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }

        let delimiter = (0..<count).map { column -> String in
            let width = widths[column]
            switch table.alignments[column] {
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            case .none: return String(repeating: "-", count: width)
            }
        }
        return [line(table.header), "| " + delimiter.joined(separator: " | ") + " |"] + table.rows.map(line)
    }
}

nonisolated extension Block {
    /// A paragraph with nothing in it. In a file it is simply a blank line.
    var isEmptyParagraph: Bool {
        guard case .paragraph = kind else { return false }
        return runs.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
    }
}

nonisolated extension BlockKind {
    var isNumbered: Bool {
        if case .numbered = self { return true }
        return false
    }

    var isIndentedCode: Bool {
        if case .code(_, let fence) = self { return fence.isIndented }
        return false
    }
}

nonisolated extension MarkdownDocument {
    /// The readable text of the document without any syntax, for search, previews and word counts.
    var plainText: String {
        blocks.compactMap { block -> String? in
            switch block.kind {
            case .divider, .raw: return nil
            case .image(let image): return image.alt.isEmpty ? nil : image.alt
            case .table(let table): return ([table.header] + table.rows).map { $0.joined(separator: " ") }.joined(separator: "\n")
            default:
                let text = block.plainText
                return text.isEmpty ? nil : text
            }
        }.joined(separator: "\n")
    }
}
