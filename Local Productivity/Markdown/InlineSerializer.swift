//
//  InlineSerializer.swift
//  Local Productivity
//
//  Writes styled runs back out as Markdown. The interesting work is making sure the
//  result parses back to exactly the same runs: emphasis must hug its text, marks
//  must nest, and literal punctuation that would otherwise be read as syntax gets a
//  backslash.
//

import Foundation

nonisolated enum InlineSerializer {

    /// Writes `runs` as Markdown.
    ///
    /// Literal punctuation is only escaped when leaving it bare would change how the text reads
    /// back. That is settled by trying the plain spelling first and parsing it again, which keeps
    /// existing notes byte-for-byte stable while still protecting anything typed in the editor.
    static func serialize(_ runs: [InlineRun]) -> String {
        let merged = InlineParser.merged(runs)
        guard !merged.isEmpty else { return "" }
        let plain = write(merged, escapingLiterals: false)
        if isEquivalent(InlineParser.parse(plain), merged) { return plain }
        return write(merged, escapingLiterals: true)
    }

    /// Writes runs without escaping anything, so punctuation that was typed as text reads back as
    /// syntax. The editor uses this to turn `**bold**` into bold text as it is typed.
    static func serializeLiterally(_ runs: [InlineRun]) -> String {
        let merged = InlineParser.merged(runs)
        return merged.isEmpty ? "" : write(merged, escapingLiterals: false)
    }

    /// True when two run lists show the same text with the same styling. Styling on whitespace is
    /// ignored because Markdown cannot express it, and so is which delimiter character was used.
    static func isEquivalent(_ lhs: [InlineRun], _ rhs: [InlineRun]) -> Bool {
        // Walks both sides in step, without building per-character copies.
        var left = StyledScalars(lhs)
        var right = StyledScalars(rhs)
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil):
                return true
            case let (a?, b?):
                if a.scalar != b.scalar || a.style != b.style { return false }
            default:
                return false
            }
        }
    }

    /// The text of a run list one scalar at a time, each with its style as Markdown can express
    /// it: none on whitespace, and no distinction between `*` and `_` delimiters.
    private struct StyledScalars {
        private let runs: [InlineRun]
        private var runIndex = 0
        private var scalars: String.UnicodeScalarView.Iterator?
        private var style = InlineStyle.plain

        init(_ runs: [InlineRun]) { self.runs = runs }

        mutating func next() -> (scalar: Unicode.Scalar, style: InlineStyle?)? {
            while true {
                if scalars == nil {
                    guard runIndex < runs.count else { return nil }
                    var normalized = runs[runIndex].style
                    normalized.escaped = false
                    if normalized.bold != nil { normalized.bold = .asterisk }
                    if normalized.italic != nil { normalized.italic = .asterisk }
                    style = normalized
                    scalars = runs[runIndex].text.unicodeScalars.makeIterator()
                    runIndex += 1
                }
                if let scalar = scalars?.next() {
                    return (scalar, scalar.properties.isWhitespace ? nil : style)
                }
                scalars = nil
            }
        }
    }

    private static func write(_ merged: [InlineRun], escapingLiterals: Bool) -> String {
        var units = makeUnits(from: merged)
        collapseAutolinks(in: &units)

        var marks = collectMarks(in: units)
        tidy(&marks, units: units)
        nest(&marks)
        tidy(&marks, units: units)
        nest(&marks)

        var opening: [Int: [Mark]] = [:]
        for mark in marks { opening[mark.start, default: []].append(mark) }

        var output = ""
        var stack: [Mark] = []
        for index in 0...units.count {
            while let top = stack.last, top.end <= index {
                output += top.close
                stack.removeLast()
            }
            guard index < units.count else { break }
            if let starting = opening[index] {
                let ordered = starting.sorted {
                    $0.end != $1.end ? $0.end > $1.end : $0.kind.rawValue < $1.kind.rawValue
                }
                for mark in ordered {
                    output += mark.open
                    stack.append(mark)
                }
            }
            output += rendered(units, at: index, escapingLiterals: escapingLiterals)
        }
        return output
    }

    // MARK: Units

    /// One character of ordinary text, or one indivisible piece of syntax (code span, wiki link…).
    private struct Unit {
        var text: String
        var style: InlineStyle
        var isAtom: Bool

        var first: Character? { text.first }
        var last: Character? { text.last }
        var isWhitespace: Bool { !isAtom && (text.first?.isWhitespace ?? false) }
    }

    private static func makeUnits(from runs: [InlineRun]) -> [Unit] {
        var units: [Unit] = []
        for run in runs {
            if run.style.code {
                units.append(Unit(text: codeSpan(run.text), style: run.style, isAtom: true))
            } else if run.style.raw {
                units.append(Unit(text: run.text, style: run.style, isAtom: true))
            } else if let wiki = run.style.wikiLink {
                let visible = run.text.replacingOccurrences(of: "\n", with: " ")
                let literal = wiki.hasAlias ? "[[\(wiki.target)|\(visible)]]" : "[[\(visible)]]"
                units.append(Unit(text: literal, style: run.style, isAtom: true))
            } else {
                for character in run.text {
                    units.append(Unit(text: String(character), style: run.style, isAtom: false))
                }
            }
        }
        return units
    }

    private static func codeSpan(_ content: String) -> String {
        var longest = 0
        var current = 0
        for character in content {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let needsPadding = content.hasPrefix("`") || content.hasSuffix("`")
            || (content.hasPrefix(" ") && content.hasSuffix(" ") && content.contains(where: { $0 != " " }))
        return needsPadding ? "\(fence) \(content) \(fence)" : "\(fence)\(content)\(fence)"
    }

    /// Links that are just their own URL are written the way they were found: bare or in angle brackets.
    private static func collapseAutolinks(in units: inout [Unit]) {
        var index = 0
        while index < units.count {
            guard let link = units[index].style.link, link.form != .inline else {
                index += 1
                continue
            }
            var end = index
            var text = ""
            var simple = true
            while end < units.count, units[end].style.link == link {
                if units[end].isAtom { simple = false }
                text += units[end].text
                end += 1
            }
            if simple, text == link.destination, !text.isEmpty {
                var style = units[index].style
                style.link = nil
                let literal = link.form == .angleAutolink ? "<\(text)>" : text
                units.replaceSubrange(index..<end, with: [Unit(text: literal, style: style, isAtom: true)])
                index += 1
            } else {
                index = end
            }
        }
    }

    // MARK: Marks

    private enum MarkKind: Int {
        case link, bold, italic, strike, highlight
    }

    private struct Mark {
        var kind: MarkKind
        var start: Int
        var end: Int
        var open: String
        var close: String
        var marker: Character = "*"
    }

    private static func collectMarks(in units: [Unit]) -> [Mark] {
        var marks: [Mark] = []

        func scan(_ kind: MarkKind, _ isOn: (InlineStyle) -> Bool, _ sameSpan: (InlineStyle, InlineStyle) -> Bool) {
            var index = 0
            while index < units.count {
                guard isOn(units[index].style) else {
                    index += 1
                    continue
                }
                var end = index + 1
                while end < units.count, isOn(units[end].style), sameSpan(units[index].style, units[end].style) {
                    end += 1
                }
                marks.append(makeMark(kind, start: index, end: end, style: units[index].style))
                index = end
            }
        }

        scan(.link, { $0.link != nil }, { $0.link == $1.link })
        scan(.bold, { $0.bold != nil }, { _, _ in true })
        scan(.italic, { $0.italic != nil }, { _, _ in true })
        scan(.strike, { $0.strikethrough }, { _, _ in true })
        scan(.highlight, { $0.highlight }, { _, _ in true })
        return marks
    }

    private static func makeMark(_ kind: MarkKind, start: Int, end: Int, style: InlineStyle) -> Mark {
        switch kind {
        case .link:
            let link = style.link ?? LinkInfo(destination: "")
            return Mark(kind: kind, start: start, end: end, open: "[", close: "](\(linkTarget(link)))")
        case .bold:
            let marker = (style.bold ?? .asterisk).rawValue
            return Mark(kind: kind, start: start, end: end, open: "", close: "", marker: marker)
        case .italic:
            let marker = (style.italic ?? .asterisk).rawValue
            return Mark(kind: kind, start: start, end: end, open: "", close: "", marker: marker)
        case .strike:
            return Mark(kind: kind, start: start, end: end, open: "~~", close: "~~")
        case .highlight:
            return Mark(kind: kind, start: start, end: end, open: "==", close: "==")
        }
    }

    private static func linkTarget(_ link: LinkInfo) -> String {
        var destination = link.destination
        var depth = 0
        var balanced = true
        for character in destination {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth < 0 { balanced = false }
        }
        if destination.contains(where: \.isWhitespace) || !balanced || depth != 0 {
            destination = "<\(destination)>"
        }
        if let title = link.title {
            return "\(destination) \(quotedTitle(title))"
        }
        return destination
    }

    /// A link or image title in double quotes: its quotes, and any backslash that would read as
    /// an escape, are escaped once.
    static func quotedTitle(_ title: String) -> String {
        let characters = Array(title)
        var result = "\""
        for (index, character) in characters.enumerated() {
            if character == "\"" {
                result += "\\\""
            } else if character == "\\", index + 1 == characters.count || characters[index + 1].isASCIIPunctuation {
                result += "\\\\"
            } else {
                result.append(character)
            }
        }
        return result + "\""
    }

    /// Shrinks emphasis so its delimiters touch non-space text and are valid flanking runs, then
    /// settles which delimiter character each one uses.
    private static func tidy(_ marks: inout [Mark], units: [Unit]) {
        var result: [Mark] = []
        for var mark in marks {
            guard mark.kind != .link else {
                if mark.end > mark.start { result.append(mark) }
                continue
            }
            var settled = false
            while !settled, mark.start < mark.end {
                settled = true
                while mark.start < mark.end, units[mark.start].isWhitespace { mark.start += 1 }
                while mark.end > mark.start, units[mark.end - 1].isWhitespace { mark.end -= 1 }
                guard mark.start < mark.end else { break }

                let before: Character? = mark.start > 0 ? units[mark.start - 1].last : nil
                let after: Character? = mark.end < units.count ? units[mark.end].first : nil
                if let first = units[mark.start].first, first.isMarkdownPunctuation,
                   let before, !before.isWhitespace, !before.isMarkdownPunctuation {
                    mark.start += 1
                    settled = false
                    continue
                }
                if let last = units[mark.end - 1].last, last.isMarkdownPunctuation,
                   let after, !after.isWhitespace, !after.isMarkdownPunctuation {
                    mark.end -= 1
                    settled = false
                }
            }
            guard mark.start < mark.end else { continue }

            if mark.kind == .bold || mark.kind == .italic {
                var marker = mark.marker
                if marker == "_" {
                    let before: Character? = mark.start > 0 ? units[mark.start - 1].last : nil
                    let after: Character? = mark.end < units.count ? units[mark.end].first : nil
                    if (before?.isWordCharacter ?? false) || (after?.isWordCharacter ?? false) { marker = "*" }
                }
                let delimiter = String(repeating: String(marker), count: mark.kind == .bold ? 2 : 1)
                mark.marker = marker
                mark.open = delimiter
                mark.close = delimiter
            }
            result.append(mark)
        }
        marks = result
    }

    /// Splits marks that partially overlap so that every pair is either disjoint or nested.
    private static func nest(_ marks: inout [Mark]) {
        var changed = true
        var guardCounter = 0
        while changed, guardCounter < 500 {
            changed = false
            guardCounter += 1
            search: for a in marks.indices {
                for b in marks.indices where a != b {
                    let first = marks[a]
                    let second = marks[b]
                    guard first.start < second.start, second.start < first.end, first.end < second.end else { continue }
                    if second.kind == .link, first.kind != .link {
                        var tail = first
                        tail.start = second.start
                        marks[a].end = second.start
                        marks.append(tail)
                    } else {
                        var tail = second
                        tail.start = first.end
                        marks[b].end = first.end
                        marks.append(tail)
                    }
                    changed = true
                    break search
                }
            }
        }
    }

    // MARK: Escaping

    private static func rendered(_ units: [Unit], at index: Int, escapingLiterals: Bool) -> String {
        let unit = units[index]
        if unit.isAtom { return unit.text }
        guard let character = unit.text.first else { return "" }
        if unit.style.escaped, character.isASCIIPunctuation { return "\\\(character)" }
        guard escapingLiterals else { return String(character) }

        let before: Character? = index > 0 ? units[index - 1].last : nil
        let after: Character? = index + 1 < units.count ? units[index + 1].first : nil
        let spaceBefore = before?.isWhitespace ?? true
        let spaceAfter = after?.isWhitespace ?? true

        switch character {
        case "\\":
            return (after?.isASCIIPunctuation ?? false) ? "\\\\" : "\\"
        case "`":
            return "\\`"
        case "*":
            return spaceBefore && spaceAfter ? "*" : "\\*"
        case "_":
            if spaceBefore && spaceAfter { return "_" }
            if (before?.isWordCharacter ?? false) && (after?.isWordCharacter ?? false) { return "_" }
            return "\\_"
        case "[":
            return opensSyntax(units, at: index) ? "\\[" : "["
        case "~", "=":
            return isFlankingPair(units, at: index, of: character) ? "\\\(character)" : String(character)
        default:
            return String(character)
        }
    }

    /// True when a literal `[` would be read as the start of a link, wiki link or footnote.
    private static func opensSyntax(_ units: [Unit], at index: Int) -> Bool {
        guard index + 1 < units.count else { return false }
        if let next = units[index + 1].first, !units[index + 1].isAtom, next == "[" || next == "^" { return true }
        var depth = 0
        var cursor = index
        let limit = min(units.count, index + 2000)
        while cursor < limit {
            let unit = units[cursor]
            if !unit.isAtom, !unit.style.escaped, let character = unit.text.first {
                if character == "[" {
                    depth += 1
                } else if character == "]" {
                    depth -= 1
                    if depth == 0 {
                        guard cursor + 1 < units.count, !units[cursor + 1].isAtom else { return false }
                        return units[cursor + 1].text == "("
                    }
                }
            }
            cursor += 1
        }
        return false
    }

    /// True for a literal `~~` or `==` that sits against text and would open or close a span.
    private static func isFlankingPair(_ units: [Unit], at index: Int, of character: Character) -> Bool {
        func isSame(_ position: Int) -> Bool {
            position >= 0 && position < units.count && !units[position].isAtom
                && !units[position].style.escaped && units[position].text.first == character
        }
        var start = index
        while isSame(start - 1) { start -= 1 }
        var end = index
        while isSame(end + 1) { end += 1 }
        guard end - start + 1 == 2 else { return false }
        let before: Character? = start > 0 ? units[start - 1].last : nil
        let after: Character? = end + 1 < units.count ? units[end + 1].first : nil
        return !((before?.isWhitespace ?? true) && (after?.isWhitespace ?? true))
    }

    // MARK: Line starts

    /// Escapes a line of paragraph text that would otherwise be read as the start of another block.
    static func escapingBlockStart(_ line: String) -> String {
        let content = line.drop(while: { $0 == " " })
        guard let first = content.first else { return line }
        let leading = String(line.prefix(line.count - content.count))
        let rest = content.dropFirst()

        func escaped() -> String { "\(leading)\\\(content)" }
        func endsOrSpace(_ text: Substring) -> Bool { text.isEmpty || text.first == " " || text.first == "\t" }

        switch first {
        case "#":
            // "# Heading"
            let hashes = content.prefix(while: { $0 == "#" })
            if hashes.count <= 6, endsOrSpace(content.dropFirst(hashes.count)) { return escaped() }
        case ">":
            // "> quote"
            return escaped()
        case "-", "+", "*":
            // "- item", or a thematic break / setext underline such as "---" and "* * *"
            if endsOrSpace(rest) { return escaped() }
            if first != "+" {
                let compact = content.filter { $0 != " " && $0 != "\t" }
                if compact.allSatisfy({ $0 == first }), compact.count >= 3 || first == "-" { return escaped() }
            }
        case "_":
            let compact = content.filter { $0 != " " && $0 != "\t" }
            if compact.count >= 3, compact.allSatisfy({ $0 == "_" }) { return escaped() }
        case "=":
            // "===" under a line of text turns that line into a heading
            if content.trimmingTrailingWhitespace.allSatisfy({ $0 == "=" }) { return escaped() }
        case "~":
            if content.hasPrefix("~~~") { return escaped() }
        default:
            if first.isASCII, first.isNumber {
                let digits = content.prefix(while: { $0.isASCII && $0.isNumber })
                let afterDigits = content.dropFirst(digits.count)
                if digits.count <= 9, let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
                   endsOrSpace(afterDigits.dropFirst()) {
                    return "\(leading)\(digits)\\\(afterDigits)"
                }
            }
        }
        return line
    }
}
