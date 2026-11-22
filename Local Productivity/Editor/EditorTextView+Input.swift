//
//  EditorTextView+Input.swift
//  Local Productivity
//
//  Typing and the clipboard. Markdown still works as a way of *writing* — "# " makes
//  a heading, "**bold**" makes bold — but the syntax is consumed the moment it is
//  complete, so it never stays on screen. Copy puts Markdown on the pasteboard and
//  paste reads Markdown back, which makes moving text between notes and other apps
//  lossless.
//

import AppKit

extension EditorTextView {

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""

        if replacementRange.location == NSNotFound, !hasMarkedText(), let attachment = selectedAttachmentParagraph {
            // Typing with a divider, image or table selected starts a paragraph below it
            // rather than replacing it.
            let location = insertBlock(.paragraph, after: attachment)
            setSelectedRange(NSRange(location: location, length: 0))
        }

        super.insertText(string, replacementRange: replacementRange)

        guard !hasMarkedText(), text.count == 1, let character = text.first, storage.length > 0 else { return }
        applyShortcuts(afterTyping: character)
    }

    private func applyShortcuts(afterTyping character: Character) {
        let caret = selectedRange().location
        let info = paragraphInfo(at: caret)
        let kind = info.block.kind
        guard !kind.isVerbatim, !kind.isAttachment, caret > info.content.location else { return }

        let typed = NSRange(location: info.content.location, length: caret - info.content.location)
        let prefix = storage.mutableString.substring(with: typed)

        if character == " ", let target = Self.blockShortcut(for: String(prefix.dropLast()), in: kind) {
            grouped("Format") {
                replace(typed, with: NSAttributedString())
                if target != kind { setBlock(info.block.with(kind: target), forParagraphAt: info.range.location) }
                setSelectedRange(NSRange(location: info.range.location, length: 0))
            }
            return
        }

        if character == "-", prefix == "---", info.content.length == 3, kind == .paragraph {
            grouped("Divider") {
                let piece = NSMutableAttributedString(attributedString: attachmentParagraph(.divider, kind: .rule))
                piece.append(NSAttributedString(string: "\n", attributes: [.lpBlock: BlockAttribute.paragraph]))
                replace(info.range, with: piece)
                setSelectedRange(NSRange(location: info.range.location + 2, length: 0))
            }
            return
        }

        if character == "/" {
            let before = prefix.dropLast().last
            if before == nil || before?.isWhitespace == true {
                host?.editorDidBeginQuery(.command, at: caret - 1)
            }
            return
        }
        if character == "[", prefix.hasSuffix("[[") {
            host?.editorDidBeginQuery(.pageLink, at: caret - 2)
            return
        }

        if "*_`~=)]".contains(character) {
            applyInlineShortcut(in: info, caret: caret)
        } else if character == " " {
            linkBareURL(endingAt: caret - 1, in: info)
        }
    }

    /// The block a paragraph turns into when `marker` followed by a space is typed at its start.
    private static func blockShortcut(for marker: String, in kind: BlockKind) -> BlockKind? {
        switch kind {
        case .paragraph:
            if !marker.isEmpty, marker.count <= 6, marker.allSatisfy({ $0 == "#" }) {
                return .heading(level: marker.count, style: .atx)
            }
            switch marker {
            case "-", "*", "+": return .bullet(marker: Character(marker))
            case "[]", "[ ]": return .openTodo
            case "[x]", "[X]": return .todo(status: "x", marker: "-")
            case ">": return .quote
            default: break
            }
            if let delimiter = marker.last, delimiter == "." || delimiter == ")" {
                let digits = marker.dropLast()
                if !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) {
                    return .numbered(number: number, delimiter: delimiter)
                }
            }
            return nil
        case .bullet(let bullet):
            switch marker {
            case "[]", "[ ]": return .todo(status: " ", marker: String(bullet))
            case "[x]", "[X]": return .todo(status: "x", marker: String(bullet))
            // Lists continue on their own. A marker typed out of habit is simply absorbed.
            case "-", "*", "+": return kind
            default: return nil
            }
        case .todo:
            switch marker {
            case "[]", "[ ]", "-", "*", "+": return kind
            default: return nil
            }
        case .numbered:
            if let delimiter = marker.last, delimiter == "." || delimiter == ")", marker.count > 1,
               marker.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) {
                return kind
            }
            return nil
        default:
            return nil
        }
    }

    /// When the character just typed closes an inline construct — the second `**`, the `)` of a
    /// link — replaces the literal text with the styled result.
    private func applyInlineShortcut(in info: ParagraphInfo, caret: Int) {
        let openers: Set<unichar> = [0x2A, 0x5F, 0x60, 0x7E, 0x3D, 0x5B]   // * _ ` ~ = [
        let text = storage.mutableString
        let lowerBound = max(info.content.location, caret - 400)
        var position = caret - 2

        while position >= lowerBound {
            let unit = text.character(at: position)
            if unit == 0x2028 { break }
            let startsRun = position == lowerBound || text.character(at: position - 1) != unit || hasInlineMeaning(at: position - 1)
            if openers.contains(unit), startsRun, !hasInlineMeaning(at: position) {
                let range = NSRange(location: position, length: caret - position)
                let existing = DocumentConverter.blocks(from: storage, in: range).first?.runs ?? []
                let parsed = InlineParser.parse(InlineSerializer.serializeLiterally(existing))
                if Self.isCompletedConstruct(parsed, replacing: existing) {
                    let replacement = DocumentConverter.inlineString(for: parsed)
                    replacement.addAttribute(.lpBlock, value: info.block, range: NSRange(location: 0, length: replacement.length))
                    grouped("Format") {
                        guard replace(range, with: replacement) else { return }
                        let end = range.location + replacement.length
                        plainTypingLocation = end
                        setSelectedRange(NSRange(location: end, length: 0))
                    }
                    return
                }
            }
            position -= 1
        }
    }

    private static func isCompletedConstruct(_ parsed: [InlineRun], replacing existing: [InlineRun]) -> Bool {
        guard !parsed.isEmpty else { return false }
        let oldLength = existing.reduce(0) { $0 + $1.text.count }
        let newLength = parsed.reduce(0) { $0 + $1.text.count }
        guard newLength < oldLength else { return false }
        return parsed.allSatisfy { run in
            let style = run.style
            guard !style.raw else { return false }
            return style.bold != nil || style.italic != nil || style.strikethrough || style.highlight
                || style.code || style.link != nil || style.wikiLink != nil
        }
    }

    /// Makes a web address clickable as soon as the space after it is typed.
    private func linkBareURL(endingAt end: Int, in info: ParagraphInfo) {
        let text = storage.mutableString
        var start = end
        while start > info.content.location {
            let unit = text.character(at: start - 1)
            if unit == 0x20 || unit == 0x09 || unit == 0x2028 { break }
            start -= 1
        }
        let range = NSRange(location: start, length: end - start)
        guard range.length > 8 else { return }
        let word = text.substring(with: range)
        guard word.lowercased().hasPrefix("http://") || word.lowercased().hasPrefix("https://") else { return }
        for location in range.location..<NSMaxRange(range) where hasInlineMeaning(at: location) { return }

        let parsed = InlineParser.parse(word)
        guard parsed.contains(where: { $0.style.link != nil }) else { return }
        let replacement = DocumentConverter.inlineString(for: parsed)
        replacement.addAttribute(.lpBlock, value: info.block, range: NSRange(location: 0, length: replacement.length))
        let selection = selectedRange()
        replace(range, with: replacement)
        setSelectedRange(selection)
    }

    // MARK: Copy

    static let markdownPasteboardType = NSPasteboard.PasteboardType("com.localproductivity.markdown")

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownPasteboardType, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.markdownPasteboardType || type == .string else { return false }
        return pboard.setString(DocumentConverter.markdown(for: storage, in: selectedRange()), forType: type)
    }

    // MARK: Paste

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownPasteboardType, .fileURL, .png, .tiff, .string]
    }

    /// Chooses what to take from a pasteboard that offers several representations.
    override func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType],
                                          restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
        let available = Set(availableTypes)
        func allowed(_ type: NSPasteboard.PasteboardType) -> Bool {
            available.contains(type) && (allowedTypes?.contains(type) ?? true)
        }
        if allowed(Self.markdownPasteboardType) { return Self.markdownPasteboardType }
        if allowed(.fileURL) { return .fileURL }
        // Spreadsheets and presentations put a picture of the selection beside its text.
        // When formatted text is on offer, the text is what was meant.
        let offersFormattedText = available.contains(.string) && (available.contains(.rtf) || available.contains(.html))
        if !offersFormattedText {
            if allowed(.png) { return .png }
            if allowed(.tiff) { return .tiff }
        }
        return allowed(.string) ? .string : nil
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .fileURL:
            let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            insertFiles(urls)
            return true
        case .png, .tiff:
            guard let data = pboard.data(forType: type) else { return false }
            return insertImage(data, isPNG: type == .png)
        default:
            guard let text = pboard.string(forType: type) else { return false }
            insertMarkdown(text)
            return true
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "avif"]

    /// Embeds dropped or pasted files: images as image blocks, anything else as a link.
    private func insertFiles(_ urls: [URL]) {
        var links: [String] = []
        for url in urls {
            guard let reference = host?.editorImportFile(at: url) else { continue }
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                let info = ImageInfo(source: reference)
                insertAttachment(.image(info), kind: .image(info))
            } else {
                let destination = reference.contains(" ") ? "<\(reference)>" : reference
                links.append("[\(url.lastPathComponent)](\(destination))")
            }
        }
        if !links.isEmpty { insertMarkdown(links.joined(separator: " ")) }
    }

    private func insertImage(_ data: Data, isPNG: Bool) -> Bool {
        // Pasted pictures are stored as PNG whatever form they arrived in.
        var png = data
        if !isPNG {
            guard let bitmap = NSBitmapImageRep(data: data), let converted = bitmap.representation(using: .png, properties: [:]) else {
                return false
            }
            png = converted
        }
        guard let info = host?.editorImportImage(png, fileExtension: "png") else { return false }
        insertAttachment(.image(info), kind: .image(info))
        return true
    }

    /// Pastes exactly the characters on the pasteboard, without reading them as Markdown.
    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let literal = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: NSAttributedString.softBreak)
        insertText(literal, replacementRange: selectedRange())
    }

    /// Inserts Markdown at the selection. A single line joins the current block; anything
    /// more arrives as blocks of its own.
    func insertMarkdown(_ markdown: String) {
        guard storage.length > 0 else { return }
        let selection = selectedRange()
        let target = paragraphInfo(at: selection.location)

        if target.block.kind.isVerbatim {
            let literal = markdown.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: NSAttributedString.softBreak)
            insertText(literal, replacementRange: selection)
            return
        }

        let pasted = MarkdownParser.parse(markdown)
        var blocks = pasted.blocks.map { block -> Block in
            var copy = block
            copy.blankLinesBefore = nil
            copy.sourceIndent = nil
            return copy
        }
        // Pasted front matter can't become this page's (it has its own), so it arrives as a YAML
        // code block rather than vanishing.
        if let frontMatter = pasted.frontMatter, !frontMatter.isEmpty {
            blocks.insert(Block(kind: .code(info: "yaml", fence: .standard), runs: [.plain(frontMatter)]), at: 0)
        }
        while blocks.first?.isEmptyParagraph == true { blocks.removeFirst() }
        while blocks.last?.isEmptyParagraph == true { blocks.removeLast() }
        guard !blocks.isEmpty else { return }

        if blocks.count == 1, blocks[0].kind == .paragraph, selectedAttachmentParagraph == nil {
            let inline = DocumentConverter.inlineString(for: blocks[0].runs)
            inline.addAttribute(.lpBlock, value: target.block, range: NSRange(location: 0, length: inline.length))
            grouped("Paste") {
                guard replace(selection, with: inline) else { return }
                setSelectedRange(NSRange(location: selection.location + inline.length, length: 0))
            }
            scrollRangeToVisible(selectedRange())
            return
        }

        grouped("Paste") {
            if let attachment = selectedAttachmentParagraph {
                let location = insertBlock(.paragraph, after: attachment)
                setSelectedRange(NSRange(location: location, length: 0))
            } else if selection.length > 0 {
                guard replace(selection, with: NSAttributedString()) else { return }
            }
            let caret = selectedRange().location
            let info = paragraphInfo(at: caret)
            let body = DocumentConverter.attributedString(for: blocks, context: converterContext)

            let insertedAt: Int
            if info.isEmpty {
                insertedAt = info.range.location
                replace(info.range, with: body)
            } else if caret == info.content.location {
                insertedAt = caret
                replace(NSRange(location: caret, length: 0), with: body)
            } else if caret == NSMaxRange(info.content) {
                insertedAt = NSMaxRange(info.range)
                replace(NSRange(location: insertedAt, length: 0), with: body)
            } else {
                // Pasting into the middle of a block splits it around what was pasted.
                let piece = NSMutableAttributedString(string: "\n", attributes: [.lpBlock: info.block])
                piece.append(body)
                insertedAt = caret + 1
                replace(NSRange(location: caret, length: 0), with: piece)
            }
            setSelectedRange(NSRange(location: insertedAt + body.length - 1, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }
}
