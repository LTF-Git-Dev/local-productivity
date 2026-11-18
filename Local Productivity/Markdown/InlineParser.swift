//
//  InlineParser.swift
//  Local Productivity
//
//  Turns the text of one block into styled runs. Emphasis follows the CommonMark
//  delimiter algorithm; on top of that it understands the Obsidian extensions people
//  actually write: [[wiki links]], ==highlights== and ~~strikethrough~~. Anything it
//  recognises but does not render (inline HTML, math, footnote references, comments)
//  becomes a `raw` run so it survives a round trip untouched.
//

import Foundation

nonisolated enum InlineParser {

    static func parse(_ source: String) -> [InlineRun] {
        guard !source.isEmpty else { return [] }
        let scanner = InlineScanner(characters: Array(source))
        let nodes = scanner.nodes(in: 0..<scanner.characters.count, insideLink: false)
        var runs: [InlineRun] = []
        flatten(nodes, style: .plain, into: &runs)
        return merged(runs)
    }

    /// Recognises text that is exactly one image, `![alt](source "title")`, and nothing else.
    static func standaloneImage(_ text: String) -> (alt: String, destination: String, title: String?)? {
        InlineScanner(characters: Array(text)).standaloneImage()
    }

    /// Joins neighbouring runs that share a style and drops empty ones.
    static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    private static func flatten(_ nodes: [InlineNode], style: InlineStyle, into runs: inout [InlineRun]) {
        for node in nodes {
            switch node {
            case .text(let text):
                runs.append(InlineRun(text: text, style: style))
            case .escaped(let character):
                var escaped = style
                escaped.escaped = true
                runs.append(InlineRun(text: String(character), style: escaped))
            case .code(let text):
                var code = style
                code.code = true
                runs.append(InlineRun(text: text, style: code))
            case .raw(let text):
                var raw = style
                raw.raw = true
                runs.append(InlineRun(text: text, style: raw))
            case .link(let children, let info):
                var linked = style
                linked.link = info
                flatten(children, style: linked, into: &runs)
            case .wiki(let text, let info):
                var linked = style
                linked.wikiLink = info
                runs.append(InlineRun(text: text, style: linked))
            case .emphasis(let kind, let marker, let children):
                var emphasized = style
                switch kind {
                case .italic: emphasized.italic = emphasized.italic ?? EmphasisMarker(rawValue: marker) ?? .asterisk
                case .bold: emphasized.bold = emphasized.bold ?? EmphasisMarker(rawValue: marker) ?? .asterisk
                case .strike: emphasized.strikethrough = true
                case .highlight: emphasized.highlight = true
                }
                flatten(children, style: emphasized, into: &runs)
            }
        }
    }
}

// MARK: - Node model

private nonisolated enum EmphasisKind {
    case italic, bold, strike, highlight
}

private nonisolated indirect enum InlineNode {
    case text(String)
    case escaped(Character)
    case code(String)
    case raw(String)
    case link([InlineNode], LinkInfo)
    case wiki(String, WikiLinkInfo)
    case emphasis(EmphasisKind, Character, [InlineNode])
}

private nonisolated struct DelimiterRun {
    var character: Character
    var count: Int
    let originalCount: Int
    let canOpen: Bool
    let canClose: Bool
}

private nonisolated enum InlineItem {
    case node(InlineNode)
    case delimiter(DelimiterRun)
}

// MARK: - Scanner

private nonisolated struct InlineScanner {

    let characters: [Character]

    func nodes(in range: Range<Int>, insideLink: Bool) -> [InlineNode] {
        var items: [InlineItem] = []
        var pending = ""
        var index = range.lowerBound
        let limit = range.upperBound

        func flush() {
            guard !pending.isEmpty else { return }
            items.append(.node(.text(pending)))
            pending = ""
        }
        func emit(_ node: InlineNode) {
            flush()
            items.append(.node(node))
        }

        while index < limit {
            let character = characters[index]
            switch character {
            case "\\":
                if index + 1 < limit, characters[index + 1].isASCIIPunctuation {
                    emit(.escaped(characters[index + 1]))
                    index += 2
                } else {
                    pending.append(character)
                    index += 1
                }

            case "`":
                let runEnd = endOfRun(of: "`", from: index, limit: limit)
                let length = runEnd - index
                if let close = closingBacktickRun(length: length, from: runEnd, limit: limit) {
                    emit(.code(Self.normalizedCodeSpan(String(characters[runEnd..<close]))))
                    index = close + length
                } else {
                    pending.append(String(repeating: "`", count: length))
                    index = runEnd
                }

            case "[":
                if let (node, next) = bracketConstruct(at: index, limit: limit, insideLink: insideLink) {
                    emit(node)
                    index = next
                } else {
                    pending.append(character)
                    index += 1
                }

            case "!":
                if index + 1 < limit, characters[index + 1] == "[", let next = imageEnd(at: index, limit: limit) {
                    emit(.raw(String(characters[index..<next])))
                    index = next
                } else {
                    pending.append(character)
                    index += 1
                }

            case "<":
                if let (node, next) = angleConstruct(at: index, limit: limit, insideLink: insideLink) {
                    emit(node)
                    index = next
                } else {
                    pending.append(character)
                    index += 1
                }

            case "$":
                if let next = mathEnd(at: index, limit: limit) {
                    emit(.raw(String(characters[index..<next])))
                    index = next
                } else {
                    pending.append(character)
                    index += 1
                }

            case "%":
                if index + 1 < limit, characters[index + 1] == "%",
                   let close = firstIndex(of: ["%", "%"], from: index + 2, limit: limit) {
                    emit(.raw(String(characters[index..<(close + 2)])))
                    index = close + 2
                } else {
                    pending.append(character)
                    index += 1
                }

            case "*", "_":
                let runEnd = endOfRun(of: character, from: index, limit: limit)
                flush()
                items.append(.delimiter(delimiterRun(character, from: index, to: runEnd)))
                index = runEnd

            case "~", "=":
                let runEnd = endOfRun(of: character, from: index, limit: limit)
                if runEnd - index == 2 {
                    flush()
                    items.append(.delimiter(delimiterRun(character, from: index, to: runEnd)))
                } else {
                    pending.append(String(repeating: String(character), count: runEnd - index))
                }
                index = runEnd

            case "h", "H":
                if !insideLink, let next = bareURLEnd(at: index, limit: limit) {
                    let url = String(characters[index..<next])
                    emit(.link([.text(url)], LinkInfo(destination: url, title: nil, form: .bareAutolink)))
                    index = next
                } else {
                    pending.append(character)
                    index += 1
                }

            default:
                pending.append(character)
                index += 1
            }
        }
        flush()
        return Self.resolveEmphasis(items)
    }

    // MARK: Runs and searching

    private func endOfRun(of character: Character, from start: Int, limit: Int) -> Int {
        var index = start
        while index < limit, characters[index] == character { index += 1 }
        return index
    }

    private func closingBacktickRun(length: Int, from start: Int, limit: Int) -> Int? {
        var index = start
        while index < limit {
            if characters[index] == "`" {
                let runEnd = endOfRun(of: "`", from: index, limit: limit)
                if runEnd - index == length { return index }
                index = runEnd
            } else {
                index += 1
            }
        }
        return nil
    }

    private func firstIndex(of pattern: [Character], from start: Int, limit: Int, stoppingAtNewline: Bool = false) -> Int? {
        guard !pattern.isEmpty, start <= limit - pattern.count else { return nil }
        var index = start
        while index <= limit - pattern.count {
            if stoppingAtNewline, characters[index] == "\n" { return nil }
            var matches = true
            for offset in 0..<pattern.count where characters[index + offset] != pattern[offset] {
                matches = false
                break
            }
            if matches { return index }
            index += 1
        }
        return nil
    }

    private static func normalizedCodeSpan(_ content: String) -> String {
        var text = content.replacingOccurrences(of: "\n", with: " ")
        if text.count >= 2, text.hasPrefix(" "), text.hasSuffix(" "), text.contains(where: { $0 != " " }) {
            text.removeFirst()
            text.removeLast()
        }
        return text
    }

    // MARK: Emphasis delimiters

    private func delimiterRun(_ character: Character, from start: Int, to end: Int) -> DelimiterRun {
        let before: Character? = start > 0 ? characters[start - 1] : nil
        let after: Character? = end < characters.count ? characters[end] : nil
        let beforeIsSpace = before?.isWhitespace ?? true
        let afterIsSpace = after?.isWhitespace ?? true
        let beforeIsPunctuation = before?.isMarkdownPunctuation ?? false
        let afterIsPunctuation = after?.isMarkdownPunctuation ?? false

        let leftFlanking = !afterIsSpace && (!afterIsPunctuation || beforeIsSpace || beforeIsPunctuation)
        let rightFlanking = !beforeIsSpace && (!beforeIsPunctuation || afterIsSpace || afterIsPunctuation)

        var canOpen = leftFlanking
        var canClose = rightFlanking
        if character == "_" {
            canOpen = leftFlanking && (!rightFlanking || beforeIsPunctuation)
            canClose = rightFlanking && (!leftFlanking || afterIsPunctuation)
        }
        return DelimiterRun(character: character, count: end - start, originalCount: end - start,
                            canOpen: canOpen, canClose: canClose)
    }

    private static func canPair(_ opener: DelimiterRun, _ closer: DelimiterRun) -> Bool {
        guard opener.character == closer.character, opener.canOpen else { return false }
        if opener.character == "*" || opener.character == "_" {
            if opener.canClose || closer.canOpen {
                let sum = opener.originalCount + closer.originalCount
                if sum % 3 == 0, !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0) {
                    return false
                }
            }
        }
        return true
    }

    private static func literal(_ item: InlineItem) -> InlineNode {
        switch item {
        case .node(let node): return node
        case .delimiter(let run): return .text(String(repeating: String(run.character), count: run.count))
        }
    }

    /// The CommonMark "process emphasis" pass over a flat list of nodes and delimiter runs.
    private static func resolveEmphasis(_ source: [InlineItem]) -> [InlineNode] {
        var items = source
        var closerIndex = 0
        while closerIndex < items.count {
            guard case .delimiter(var closer) = items[closerIndex], closer.canClose else {
                closerIndex += 1
                continue
            }
            var openerIndex = closerIndex - 1
            var match = -1
            while openerIndex >= 0 {
                if case .delimiter(let candidate) = items[openerIndex], canPair(candidate, closer) {
                    match = openerIndex
                    break
                }
                openerIndex -= 1
            }
            guard match >= 0, case .delimiter(var opener) = items[match] else {
                closerIndex += 1
                continue
            }

            let kind: EmphasisKind
            let used: Int
            switch closer.character {
            case "~":
                kind = .strike
                used = 2
            case "=":
                kind = .highlight
                used = 2
            default:
                let strong = opener.count >= 2 && closer.count >= 2
                kind = strong ? .bold : .italic
                used = strong ? 2 : 1
            }

            let children = items[(match + 1)..<closerIndex].map(literal)
            opener.count -= used
            closer.count -= used

            var replacement: [InlineItem] = []
            if opener.count > 0 { replacement.append(.delimiter(opener)) }
            replacement.append(.node(.emphasis(kind, closer.character, children)))
            let resumeOffset = replacement.count
            if closer.count > 0 { replacement.append(.delimiter(closer)) }
            items.replaceSubrange(match...closerIndex, with: replacement)
            closerIndex = match + resumeOffset
        }
        return items.map(literal)
    }

    // MARK: Brackets: wiki links, footnotes, links

    private func bracketConstruct(at start: Int, limit: Int, insideLink: Bool) -> (InlineNode, Int)? {
        // [[wiki link]] or [[target|alias]]
        if start + 1 < limit, characters[start + 1] == "[" {
            guard let close = firstIndex(of: ["]", "]"], from: start + 2, limit: limit, stoppingAtNewline: true) else {
                return nil
            }
            let inner = String(characters[(start + 2)..<close])
            guard !inner.trimmingWhitespace.isEmpty, !inner.contains("[") else { return nil }
            if let pipe = inner.firstIndex(of: "|") {
                let target = String(inner[..<pipe])
                let alias = String(inner[inner.index(after: pipe)...])
                if !alias.isEmpty, !target.isEmpty {
                    return (.wiki(alias, WikiLinkInfo(target: target, hasAlias: true)), close + 2)
                }
                return (.raw(String(characters[start..<(close + 2)])), close + 2)
            }
            return (.wiki(inner, WikiLinkInfo(target: inner, hasAlias: false)), close + 2)
        }

        // [^footnote]
        if start + 1 < limit, characters[start + 1] == "^" {
            var index = start + 2
            while index < limit, characters[index] != "]", !characters[index].isWhitespace, characters[index] != "[" {
                index += 1
            }
            if index < limit, characters[index] == "]", index > start + 2 {
                return (.raw(String(characters[start...index])), index + 1)
            }
            return nil
        }

        // [text](destination "title")
        guard !insideLink, let close = matchingBracket(from: start, limit: limit) else { return nil }
        guard close + 1 < limit, characters[close + 1] == "(",
              let (info, next) = linkDestination(from: close + 2, limit: limit) else { return nil }
        guard close > start + 1 else {
            return (.raw(String(characters[start..<next])), next)
        }
        let children = nodes(in: (start + 1)..<close, insideLink: true)
        return (.link(children, info), next)
    }

    /// Finds the `]` that closes the `[` at `start`, skipping escapes and code spans.
    private func matchingBracket(from start: Int, limit: Int) -> Int? {
        var depth = 0
        var index = start
        while index < limit {
            switch characters[index] {
            case "\\":
                index += 2
                continue
            case "`":
                let runEnd = endOfRun(of: "`", from: index, limit: limit)
                if let close = closingBacktickRun(length: runEnd - index, from: runEnd, limit: limit) {
                    index = close + (runEnd - index)
                } else {
                    index = runEnd
                }
                continue
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index += 1
        }
        return nil
    }

    private func skipSpaces(from start: Int, limit: Int) -> Int {
        var index = start
        while index < limit, characters[index].isWhitespace { index += 1 }
        return index
    }

    /// Parses `destination "title")` starting just after the opening parenthesis.
    private func linkDestination(from start: Int, limit: Int) -> (LinkInfo, Int)? {
        var index = skipSpaces(from: start, limit: limit)
        var destination = ""

        if index < limit, characters[index] == "<" {
            var end = index + 1
            while end < limit, characters[end] != ">", characters[end] != "\n", characters[end] != "<" { end += 1 }
            guard end < limit, characters[end] == ">" else { return nil }
            destination = String(characters[(index + 1)..<end])
            index = end + 1
        } else {
            var depth = 0
            let begin = index
            while index < limit {
                let character = characters[index]
                if character == "\\", index + 1 < limit {
                    index += 2
                    continue
                }
                if character.isWhitespace { break }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                index += 1
            }
            guard depth == 0 else { return nil }
            destination = String(characters[begin..<index])
        }

        index = skipSpaces(from: index, limit: limit)
        var title: String? = nil
        if index < limit, let closer = Self.titleCloser(for: characters[index]) {
            var end = index + 1
            while end < limit, characters[end] != closer {
                if characters[end] == "\\" { end += 1 }
                end += 1
            }
            guard end < limit else { return nil }
            title = String(characters[(index + 1)..<end])
            index = skipSpaces(from: end + 1, limit: limit)
        }

        guard index < limit, characters[index] == ")" else { return nil }
        return (LinkInfo(destination: destination, title: title, form: .inline), index + 1)
    }

    private static func titleCloser(for opener: Character) -> Character? {
        switch opener {
        case "\"": return "\""
        case "'": return "'"
        default: return nil
        }
    }

    func standaloneImage() -> (alt: String, destination: String, title: String?)? {
        let limit = characters.count
        guard limit >= 5, characters[0] == "!", characters[1] == "[",
              let close = matchingBracket(from: 1, limit: limit),
              close + 1 < limit, characters[close + 1] == "(",
              let (info, next) = linkDestination(from: close + 2, limit: limit), next == limit else { return nil }
        return (String(characters[2..<close]), info.destination, info.title)
    }

    /// Returns the index just past an inline image (`![alt](src)` or `![[embed]]`) starting at `start`.
    private func imageEnd(at start: Int, limit: Int) -> Int? {
        let bracket = start + 1
        if bracket + 1 < limit, characters[bracket + 1] == "[" {
            guard let close = firstIndex(of: ["]", "]"], from: bracket + 2, limit: limit, stoppingAtNewline: true) else {
                return nil
            }
            return close + 2
        }
        guard let close = matchingBracket(from: bracket, limit: limit),
              close + 1 < limit, characters[close + 1] == "(",
              let (_, next) = linkDestination(from: close + 2, limit: limit) else { return nil }
        return next
    }

    // MARK: Angle brackets: autolinks and inline HTML

    private func angleConstruct(at start: Int, limit: Int, insideLink: Bool) -> (InlineNode, Int)? {
        // <!-- comment -->
        if start + 3 < limit, characters[start + 1] == "!", characters[start + 2] == "-", characters[start + 3] == "-" {
            guard let close = firstIndex(of: ["-", "-", ">"], from: start + 4, limit: limit) else { return nil }
            return (.raw(String(characters[start..<(close + 3)])), close + 3)
        }

        var end = start + 1
        while end < limit, characters[end] != ">", characters[end] != "<", characters[end] != "\n" { end += 1 }
        guard end < limit, characters[end] == ">", end > start + 1 else { return nil }
        let inner = String(characters[(start + 1)..<end])

        if !insideLink, !inner.contains(where: \.isWhitespace) {
            if Self.isAbsoluteURI(inner) || Self.isEmailAddress(inner) {
                return (.link([.text(inner)], LinkInfo(destination: inner, title: nil, form: .angleAutolink)), end + 1)
            }
        }

        // <tag attr="value">, </tag>, <br/>
        var name = inner[...]
        if name.hasPrefix("/") { name = name.dropFirst() }
        guard let first = name.first, first.isASCII, first.isLetter else { return nil }
        let tagName = name.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        let rest = name.dropFirst(tagName.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "/" || rest.first == "\t" else { return nil }
        return (.raw(String(characters[start...end])), end + 1)
    }

    private static func isAbsoluteURI(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard scheme.count >= 2, scheme.count <= 32, let first = scheme.first, first.isASCII, first.isLetter else {
            return false
        }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-") }
    }

    private static func isEmailAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@.+-_".contains($0)) }
    }

    // MARK: Math and bare URLs

    /// `$inline math$` or `$$display math$$` written inside a paragraph.
    private func mathEnd(at start: Int, limit: Int) -> Int? {
        if start + 1 < limit, characters[start + 1] == "$" {
            guard let close = firstIndex(of: ["$", "$"], from: start + 2, limit: limit), close > start + 2 else {
                return nil
            }
            return close + 2
        }
        guard start + 1 < limit, !characters[start + 1].isWhitespace else { return nil }
        if start > 0, characters[start - 1].isWordCharacter { return nil }
        var index = start + 1
        while index < limit {
            let character = characters[index]
            if character == "\n" { return nil }
            if character == "\\" {
                index += 2
                continue
            }
            if character == "$", index > start + 1, !characters[index - 1].isWhitespace {
                if index + 1 < limit, characters[index + 1].isNumber { return nil }
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private func bareURLEnd(at start: Int, limit: Int) -> Int? {
        if start > 0, characters[start - 1].isWordCharacter { return nil }
        let schemes: [[Character]] = [Array("https://"), Array("http://")]
        var prefixLength = 0
        for scheme in schemes where start + scheme.count < limit {
            var matches = true
            for offset in 0..<scheme.count where String(characters[start + offset]).lowercased() != String(scheme[offset]) {
                matches = false
                break
            }
            if matches {
                prefixLength = scheme.count
                break
            }
        }
        guard prefixLength > 0 else { return nil }

        var end = start + prefixLength
        while end < limit, !characters[end].isWhitespace, characters[end] != "<" { end += 1 }

        while end > start + prefixLength {
            let last = characters[end - 1]
            if "?!.,:;*_~'\"".contains(last) {
                end -= 1
            } else if last == ")" {
                let body = characters[start..<end]
                let opens = body.reduce(0) { $0 + ($1 == "(" ? 1 : 0) }
                let closes = body.reduce(0) { $0 + ($1 == ")" ? 1 : 0) }
                if closes > opens { end -= 1 } else { break }
            } else {
                break
            }
        }
        return end > start + prefixLength ? end : nil
    }
}
