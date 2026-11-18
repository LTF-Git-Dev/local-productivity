//
//  EditorTextView+Editing.swift
//  Local Productivity
//
//  How the document responds to structural keys and commands: Return, Delete, Tab,
//  the arrow keys around non-text blocks, and turning one kind of block into another.
//  Every change goes through `replace` or `setBlock` so that it is undoable and the
//  storage is normalised afterwards.
//

import AppKit

extension EditorTextView {

    struct ParagraphInfo {
        /// The paragraph including its line ending.
        var range: NSRange
        /// The paragraph's text without the line ending.
        var content: NSRange
        var block: BlockAttribute

        var isEmpty: Bool { content.length == 0 }
    }

    func paragraphInfo(at location: Int) -> ParagraphInfo {
        let range = storage.paragraphRange(at: min(location, max(storage.length - 1, 0)))
        return ParagraphInfo(range: range, content: storage.contentRange(of: range), block: storage.block(at: range.location))
    }

    func selectedParagraphs() -> [ParagraphInfo] {
        var result: [ParagraphInfo] = []
        storage.enumerateParagraphs(in: selectedRange()) { range in
            result.append(ParagraphInfo(range: range, content: storage.contentRange(of: range), block: storage.block(at: range.location)))
        }
        return result
    }

    func hasInlineMeaning(at location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        let attributes = storage.attributes(at: location, effectiveRange: nil)
        return attributes[.attachment] != nil || NSAttributedString.Key.lpInlineKeys.contains { attributes[$0] != nil }
    }

    // MARK: Edit primitives

    /// The document always ends with the newline that terminates its last block. Any edit that
    /// would remove it is refused.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !isReplacingDocument, let replacementString, storage.length > 0, NSMaxRange(affectedCharRange) >= storage.length {
            let endsWithNewline: Bool
            if let last = replacementString.last {
                endsWithNewline = last == "\n"
            } else if affectedCharRange.location > 0 {
                endsWithNewline = storage.mutableString.character(at: affectedCharRange.location - 1) == 0x0A
            } else {
                endsWithNewline = false
            }
            if !endsWithNewline { return false }
        }
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        pendingEdits += 1
        // Should an edit ever be abandoned without `didChangeText`, do not stay "mid-edit" forever.
        DispatchQueue.main.async { [weak self] in self?.pendingEdits = 0 }
        return true
    }

    override func didChangeText() {
        pendingEdits = max(0, pendingEdits - 1)
        super.didChangeText()
        // List numbers further down can change without any of their text moving.
        setNeedsDisplay(visibleRect)
        if pendingEdits == 0, !isReplacingDocument {
            // Now that the edit is complete, let the selection rules see where the caret ended up.
            setSelectedRange(selectedRange())
        }
    }

    @discardableResult
    func replace(_ range: NSRange, with replacement: NSAttributedString) -> Bool {
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return false }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        return true
    }

    func setBlock(_ block: BlockAttribute, forParagraphAt location: Int) {
        let range = storage.paragraphRange(at: location)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.lpBlock, value: block, range: range)
        didChangeText()
    }

    /// Runs several edits as a single undo step.
    func grouped(_ actionName: String, _ body: () -> Void) {
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(actionName)
        refreshTypingAttributes()
    }

    /// Inserts an empty block after `paragraph` and returns where it starts.
    @discardableResult
    func insertBlock(_ block: BlockAttribute, after paragraph: NSRange) -> Int {
        let location = NSMaxRange(paragraph)
        replace(NSRange(location: location, length: 0), with: NSAttributedString(string: "\n", attributes: [.lpBlock: block]))
        return location
    }

    @discardableResult
    func insertBlock(_ block: BlockAttribute, before paragraph: NSRange) -> Int {
        replace(NSRange(location: paragraph.location, length: 0), with: NSAttributedString(string: "\n", attributes: [.lpBlock: block]))
        return paragraph.location
    }

    func attachmentParagraph(_ content: BlockAttachment.Content, kind: BlockKind) -> NSAttributedString {
        let piece = NSMutableAttributedString(attachment: DocumentConverter.makeAttachment(content, context: converterContext))
        piece.append(NSAttributedString(string: "\n"))
        piece.addAttribute(.lpBlock, value: BlockAttribute(kind: kind), range: NSRange(location: 0, length: piece.length))
        return piece
    }

    func appendParagraph() {
        guard storage.length > 0 else { return }
        grouped("New Paragraph") {
            let location = insertBlock(.paragraph, after: storage.paragraphRange(at: storage.length - 1))
            setSelectedRange(NSRange(location: location, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Typing attributes

    /// Text typed at the caret takes the block of its paragraph and the inline styles of the
    /// character before it. Links and raw source do not extend past their own end.
    func refreshTypingAttributes() {
        guard storage.length > 0, !hasMarkedText() else { return }
        let selection = selectedRange()
        let info = paragraphInfo(at: selection.location)
        var inline: [NSAttributedString.Key: Any] = [:]

        if selection.location > info.content.location, plainTypingLocation != selection.location {
            let before = storage.attributes(at: selection.location - 1, effectiveRange: nil)
            for key in NSAttributedString.Key.lpInlineKeys {
                if let value = before[key] { inline[key] = value }
            }
            let after = selection.location < NSMaxRange(info.content)
                ? storage.attributes(at: selection.location, effectiveRange: nil) : [:]
            for key in [NSAttributedString.Key.lpLink, .lpWiki] {
                if let value = inline[key] as? NSObject, !value.isEqual(after[key]) { inline.removeValue(forKey: key) }
            }
            if after[.lpRaw] == nil { inline.removeValue(forKey: .lpRaw) }
        }
        typingAttributes = styler.typingAttributes(for: info.block, inline: inline)
    }

    // MARK: Return

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), storage.length > 0 else {
            super.insertNewline(sender)
            return
        }

        if let attachment = selectedAttachmentParagraph {
            grouped("New Paragraph") {
                let location = insertBlock(.paragraph, after: attachment)
                setSelectedRange(NSRange(location: location, length: 0))
            }
            return
        }
        if selectedRange().length > 0, !replace(selectedRange(), with: NSAttributedString()) { return }

        let caret = selectedRange().location
        let info = paragraphInfo(at: caret)
        let kind = info.block.kind
        let atStart = caret == info.content.location
        let atEnd = caret == NSMaxRange(info.content)

        // "```swift" followed by Return opens a code block.
        if kind == .paragraph, atEnd, let language = fenceLanguage(in: info) {
            grouped("Code Block") {
                replace(info.content, with: NSAttributedString())
                setBlock(info.block.with(kind: .code(info: language, fence: .standard)), forParagraphAt: info.range.location)
                setSelectedRange(NSRange(location: info.range.location, length: 0))
            }
            return
        }

        if kind.keepsLineBreaksInside {
            if info.isEmpty {
                grouped("Plain Text") {
                    setBlock(info.block.with(kind: .paragraph), forParagraphAt: info.range.location)
                }
                return
            }
            // Return on an empty last line steps out of the block. Code keeps single blank lines,
            // so there it takes two of them.
            if atEnd, let trailing = trailingBlankLines(in: info), trailing.count >= (kind.isVerbatim ? 2 : 1) {
                grouped("New Paragraph") {
                    replace(trailing.range, with: NSAttributedString())
                    let location = insertBlock(BlockAttribute(kind: .paragraph, indent: info.block.indent),
                                               after: storage.paragraphRange(at: trailing.range.location))
                    setSelectedRange(NSRange(location: location, length: 0))
                }
                scrollRangeToVisible(selectedRange())
                return
            }
            insertSoftBreak(autoIndent: kind.isVerbatim)
            return
        }

        if kind.isListItem, info.isEmpty {
            // Return on an empty item steps out of the list, one level at a time.
            grouped("Outdent") {
                let next = info.block.indent > 0
                    ? info.block.with(indent: info.block.indent - 1)
                    : info.block.with(kind: .paragraph)
                setBlock(next, forParagraphAt: info.range.location)
            }
            return
        }

        grouped("New Paragraph") {
            guard replace(NSRange(location: caret, length: 0),
                          with: NSAttributedString(string: "\n", attributes: [.lpBlock: info.block])) else { return }
            let second = caret + 1
            let indent = info.block.indent

            switch kind {
            case .heading:
                if atStart, !info.isEmpty {
                    // The heading moves down; the new empty line above it is plain text.
                    setBlock(BlockAttribute(kind: .paragraph, indent: indent), forParagraphAt: info.range.location)
                } else {
                    setBlock(BlockAttribute(kind: .paragraph, indent: indent), forParagraphAt: second)
                }
            case .todo(_, let marker):
                setBlock(BlockAttribute(kind: .todo(status: " ", marker: marker), indent: indent), forParagraphAt: second)
            case .numbered(_, let delimiter):
                setBlock(BlockAttribute(kind: .numbered(number: 1, delimiter: delimiter), indent: indent), forParagraphAt: second)
            default:
                setBlock(BlockAttribute(kind: kind, indent: indent), forParagraphAt: second)
            }
            setSelectedRange(NSRange(location: second, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    /// The run of empty (or whitespace-only) lines at the end of a block: how many there are and the
    /// range they occupy, including the line break that starts the first of them.
    private func trailingBlankLines(in info: ParagraphInfo) -> (count: Int, range: NSRange)? {
        let text = storage.mutableString
        var count = 0
        var start = NSMaxRange(info.content)
        var cursor = start
        while cursor > info.content.location {
            let unit = text.character(at: cursor - 1)
            if unit == 0x2028 {
                count += 1
                start = cursor - 1
            } else if unit != 0x20 && unit != 0x09 {
                break
            }
            cursor -= 1
        }
        guard count > 0 else { return nil }
        return (count, NSRange(location: start, length: NSMaxRange(info.content) - start))
    }

    /// The language named after a code fence typed as text, e.g. "```swift".
    private func fenceLanguage(in info: ParagraphInfo) -> String? {
        let text = storage.mutableString.substring(with: info.content)
        for fence in ["```", "~~~"] where text.hasPrefix(fence) {
            let language = text.dropFirst(3)
            if !language.contains(where: { $0 == "`" || $0 == "~" || $0.isWhitespace }) { return String(language) }
        }
        return nil
    }

    private func insertSoftBreak(autoIndent: Bool) {
        var text = NSAttributedString.softBreak
        var target = selectedRange()
        if autoIndent {
            // Carry the current line's indentation onto the next one.
            let caret = target.location
            let info = paragraphInfo(at: caret)
            let string = storage.mutableString
            var lineStart = caret
            while lineStart > info.content.location, string.character(at: lineStart - 1) != 0x2028 { lineStart -= 1 }
            var end = lineStart
            while end < caret, string.character(at: end) == 0x20 || string.character(at: end) == 0x09 { end += 1 }
            let indentation = string.substring(with: NSRange(location: lineStart, length: end - lineStart))
            text += indentation
            if end == caret, target.length == 0 {
                // The line holds nothing but that indentation: leave it truly empty.
                target = NSRange(location: lineStart, length: caret - lineStart)
            }
        }
        insertText(text, replacementRange: target)
    }

    override func insertLineBreak(_ sender: Any?) {
        guard storage.length > 0 else { return }
        let kind = paragraphInfo(at: selectedRange().location).block.kind
        if kind.isHeading || kind.isAttachment {
            insertNewline(sender)
        } else {
            insertSoftBreak(autoIndent: kind.isVerbatim)
        }
    }

    /// ⌘Return: checks off a to-do, or starts a new paragraph below the current block.
    func commandReturn() {
        guard storage.length > 0 else { return }
        let info = paragraphInfo(at: selectedRange().location)
        if case .todo = info.block.kind {
            toggleTodo(at: info.range.location)
            return
        }
        grouped("New Paragraph") {
            let location = insertBlock(BlockAttribute(kind: .paragraph, indent: info.block.indent), after: info.range)
            setSelectedRange(NSRange(location: location, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Delete

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText(), storage.length > 0 else {
            super.deleteBackward(sender)
            return
        }
        let info = paragraphInfo(at: selection.location)
        guard selection.location == info.range.location else {
            super.deleteBackward(sender)
            return
        }

        // At the very start of a block, Delete first undoes the block's formatting…
        if info.block.kind != .paragraph {
            grouped("Plain Text") {
                setBlock(info.block.with(kind: .paragraph), forParagraphAt: info.range.location)
            }
            return
        }
        if info.block.indent > 0 {
            grouped("Outdent") {
                setBlock(info.block.with(indent: info.block.indent - 1), forParagraphAt: info.range.location)
            }
            return
        }
        // …and only then joins it to the block above.
        guard info.range.location > 0 else {
            host?.editorWantsTitleFocus()
            return
        }
        let previous = paragraphInfo(at: info.range.location - 1)
        if previous.block.kind.isAttachment, !info.isEmpty {
            setSelectedRange(NSRange(location: previous.range.location, length: 1))
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText(), storage.length > 0 else {
            super.deleteForward(sender)
            return
        }
        let info = paragraphInfo(at: selection.location)
        guard selection.location == NSMaxRange(info.content) else {
            super.deleteForward(sender)
            return
        }
        let next = NSMaxRange(info.range)
        guard next < storage.length else { return }
        let following = paragraphInfo(at: next)
        if following.block.kind.isAttachment {
            if info.isEmpty {
                replace(info.range, with: NSAttributedString())
                setSelectedRange(NSRange(location: info.range.location, length: 1))
            } else {
                setSelectedRange(NSRange(location: following.range.location, length: 1))
            }
            return
        }
        super.deleteForward(sender)
    }

    // MARK: Tab

    override func insertTab(_ sender: Any?) {
        let paragraphs = selectedParagraphs()
        if paragraphs.count == 1, paragraphs[0].block.kind.isVerbatim {
            insertText("\t", replacementRange: selectedRange())
        } else {
            changeIndent(by: 1)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        changeIndent(by: -1)
    }

    /// Nests the selected blocks one level deeper or shallower. A block can only sit one level
    /// below the list item above it.
    func changeIndent(by delta: Int) {
        let paragraphs = selectedParagraphs()
        guard !paragraphs.isEmpty else { return }
        grouped(delta > 0 ? "Indent" : "Outdent") {
            for info in paragraphs {
                let current = storage.block(at: info.range.location)
                var target = current.indent + delta
                if delta > 0 {
                    var limit = 0
                    if info.range.location > 0 {
                        let previous = storage.block(at: info.range.location - 1)
                        limit = previous.kind.isListItem ? previous.indent + 1 : previous.indent
                    }
                    target = min(target, limit)
                }
                target = max(0, target)
                if target != current.indent {
                    setBlock(current.with(indent: target), forParagraphAt: info.range.location)
                }
            }
        }
    }

    // MARK: Moving around non-text blocks

    override func moveUp(_ sender: Any?) {
        if let attachment = selectedAttachmentParagraph {
            leaveAttachment(attachment, forward: false)
        } else if isCaretOnFirstLine {
            host?.editorWantsTitleFocus()
        } else {
            super.moveUp(sender)
        }
    }

    override func moveLeft(_ sender: Any?) {
        if let attachment = selectedAttachmentParagraph {
            leaveAttachment(attachment, forward: false)
        } else {
            super.moveLeft(sender)
        }
    }

    override func moveDown(_ sender: Any?) {
        if let attachment = selectedAttachmentParagraph {
            leaveAttachment(attachment, forward: true)
        } else if isCaretOnLastLine, storage.block(at: storage.length - 1).kind.keepsLineBreaksInside {
            // Nothing lies below a quote, callout or code block that ends the page: make room.
            appendParagraph()
        } else {
            super.moveDown(sender)
        }
    }

    override func moveRight(_ sender: Any?) {
        if let attachment = selectedAttachmentParagraph {
            leaveAttachment(attachment, forward: true)
        } else {
            super.moveRight(sender)
        }
    }

    /// Moves the caret out of a selected divider, image or table, making room if it is at an edge.
    private func leaveAttachment(_ paragraph: NSRange, forward: Bool) {
        if forward {
            let next = NSMaxRange(paragraph)
            if next >= storage.length {
                grouped("New Paragraph") {
                    let location = insertBlock(.paragraph, after: paragraph)
                    setSelectedRange(NSRange(location: location, length: 0))
                }
            } else {
                setSelectedRange(NSRange(location: next, length: 0))
            }
        } else if paragraph.location == 0 {
            grouped("New Paragraph") {
                let location = insertBlock(.paragraph, before: paragraph)
                setSelectedRange(NSRange(location: location, length: 0))
            }
        } else {
            setSelectedRange(NSRange(location: paragraph.location - 1, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if host?.editorShouldHandle(event) == true { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            if flags.contains(.command) {
                commandReturn()
                return
            }
            if flags.contains(.shift) {
                insertLineBreak(nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Escape collapses the selection. (The default would open the spelling completion list.)
    override func cancelOperation(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, selectedAttachmentParagraph == nil {
            setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
        }
    }

    override func complete(_ sender: Any?) {}

    // MARK: Block commands

    /// Changes the selected blocks to `kind`. Applying a kind they already have turns them back
    /// into plain text.
    func turnInto(_ kind: BlockKind) {
        let paragraphs = selectedParagraphs().filter { !$0.block.kind.isAttachment }
        guard let first = paragraphs.first else { return }
        let target: BlockKind = paragraphs.allSatisfy({ $0.block.kind.isSameCategory(as: kind) }) ? .paragraph : kind
        let selection = selectedRange()

        grouped("Change Block") {
            if target.keepsLineBreaksInside, paragraphs.count > 1 {
                // Several lines become one block: the newlines between them turn into line breaks.
                for info in paragraphs.dropLast().reversed() {
                    replace(NSRange(location: NSMaxRange(info.range) - 1, length: 1),
                            with: NSAttributedString(string: NSAttributedString.softBreak, attributes: [.lpBlock: first.block]))
                }
                setBlock(first.block.with(kind: target), forParagraphAt: first.range.location)
            } else {
                for info in paragraphs.reversed() {
                    if info.block.kind.keepsLineBreaksInside, !target.keepsLineBreaksInside {
                        // One block becomes several: every line gets a paragraph of its own.
                        var starts = [info.range.location]
                        var position = info.content.location
                        while position < NSMaxRange(info.content) {
                            if storage.mutableString.character(at: position) == 0x2028 {
                                replace(NSRange(location: position, length: 1),
                                        with: NSAttributedString(string: "\n", attributes: [.lpBlock: info.block]))
                                starts.append(position + 1)
                            }
                            position += 1
                        }
                        for start in starts {
                            setBlock(BlockAttribute(kind: target, indent: info.block.indent), forParagraphAt: start)
                        }
                    } else {
                        setBlock(info.block.with(kind: target), forParagraphAt: info.range.location)
                    }
                }
            }
            setSelectedRange(selection)
        }
    }

    /// A fresh copy of the block at `location` as text ready to insert (attachments are rebuilt, not shared).
    private func copyOfBlock(at location: Int) -> NSAttributedString {
        let paragraph = storage.paragraphRange(at: location)
        let blocks = DocumentConverter.blocks(from: storage, in: paragraph).map { block -> Block in
            var copy = block
            copy.blankLinesBefore = nil
            copy.sourceIndent = nil
            return copy
        }
        return DocumentConverter.attributedString(for: blocks, context: converterContext)
    }

    func duplicateBlock(at location: Int) {
        guard storage.length > 0 else { return }
        let paragraph = storage.paragraphRange(at: location)
        let copy = copyOfBlock(at: location)
        grouped("Duplicate") {
            guard replace(NSRange(location: NSMaxRange(paragraph), length: 0), with: copy) else { return }
            setSelectedRange(NSRange(location: NSMaxRange(paragraph) + copy.length - 1, length: 0))
        }
    }

    /// Moves a block above the one before it, or below the one after it.
    func moveBlock(at location: Int, up: Bool) {
        guard storage.length > 0 else { return }
        let paragraph = storage.paragraphRange(at: location)
        if up, paragraph.location == 0 { return }
        if !up, NSMaxRange(paragraph) >= storage.length { return }
        let copy = copyOfBlock(at: location)

        grouped(up ? "Move Up" : "Move Down") {
            let destination: Int
            if up {
                destination = storage.paragraphRange(at: paragraph.location - 1).location
                guard replace(paragraph, with: NSAttributedString()),
                      replace(NSRange(location: destination, length: 0), with: copy) else { return }
            } else {
                let next = storage.paragraphRange(at: NSMaxRange(paragraph))
                destination = NSMaxRange(next) - paragraph.length
                guard replace(NSRange(location: NSMaxRange(next), length: 0), with: copy),
                      replace(paragraph, with: NSAttributedString()) else { return }
            }
            setSelectedRange(NSRange(location: destination + copy.length - 1, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    func deleteBlock(at location: Int) {
        guard storage.length > 0 else { return }
        let paragraph = storage.paragraphRange(at: location)
        grouped("Delete Block") {
            if paragraph.length == storage.length {
                // The last remaining block is emptied rather than removed.
                let empty = NSAttributedString(string: "\n", attributes: [.lpBlock: BlockAttribute.paragraph])
                guard replace(paragraph, with: empty) else { return }
                setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                guard replace(paragraph, with: NSAttributedString()) else { return }
                setSelectedRange(NSRange(location: min(paragraph.location, storage.length - 1), length: 0))
            }
        }
    }

    /// Starts a new paragraph under the block at `location` and opens the block menu in it.
    func addBlock(below location: Int) {
        guard storage.length > 0 else { return }
        let info = paragraphInfo(at: location)
        window?.makeFirstResponder(self)
        grouped("New Block") {
            let start = insertBlock(BlockAttribute(kind: .paragraph, indent: info.block.kind.isListItem ? info.block.indent : 0), after: info.range)
            setSelectedRange(NSRange(location: start, length: 0))
        }
        insertText("/", replacementRange: selectedRange())
        scrollRangeToVisible(selectedRange())
    }

    func toggleTodo(at location: Int) {
        let info = paragraphInfo(at: location)
        guard case .todo(let status, let marker) = info.block.kind else { return }
        let toggled = BlockAttribute(kind: .todo(status: status == " " ? "x" : " ", marker: marker), indent: info.block.indent,
                                     blankLinesBefore: info.block.blankLinesBefore, sourceIndent: info.block.sourceIndent)
        grouped("Toggle To-do") {
            setBlock(toggled, forParagraphAt: info.range.location)
        }
    }

    /// Replaces a block attribute while keeping the source details of the block.
    private func updateKind(_ kind: BlockKind, forParagraphAt location: Int, actionName: String) {
        let info = paragraphInfo(at: location)
        let updated = BlockAttribute(kind: kind, indent: info.block.indent,
                                     blankLinesBefore: info.block.blankLinesBefore, sourceIndent: info.block.sourceIndent)
        grouped(actionName) {
            setBlock(updated, forParagraphAt: info.range.location)
        }
    }

    func setCalloutType(_ type: String, forParagraphAt location: Int) {
        guard case .callout(_, let fold, let hasTitle) = paragraphInfo(at: location).block.kind else { return }
        updateKind(.callout(type: type, fold: fold, hasTitle: hasTitle), forParagraphAt: location, actionName: "Change Callout")
    }

    func setCodeLanguage(_ language: String, forParagraphAt location: Int) {
        guard case .code(_, let fence) = paragraphInfo(at: location).block.kind else { return }
        let standardFence = fence.isIndented ? CodeFence.standard : fence
        updateKind(.code(info: language, fence: standardFence), forParagraphAt: location, actionName: "Change Language")
    }

    /// Inserts a divider, image or table. An empty paragraph at the caret is replaced; otherwise
    /// the block goes below the current one. The caret ends up in a paragraph after it.
    func insertAttachment(_ content: BlockAttachment.Content, kind: BlockKind) {
        guard storage.length > 0 else { return }
        let info = paragraphInfo(at: selectedRange().location)
        grouped("Insert") {
            let piece = NSMutableAttributedString(attributedString: attachmentParagraph(content, kind: kind))
            let insertAt: Int
            if info.isEmpty, info.block.kind == .paragraph {
                insertAt = info.range.location
                let followedByEmptyParagraph = NSMaxRange(info.range) < storage.length
                    && paragraphInfo(at: NSMaxRange(info.range)).isEmpty
                if !followedByEmptyParagraph {
                    piece.append(NSAttributedString(string: "\n", attributes: [.lpBlock: BlockAttribute.paragraph]))
                }
                replace(info.range, with: piece)
            } else {
                insertAt = NSMaxRange(info.range)
                piece.append(NSAttributedString(string: "\n", attributes: [.lpBlock: BlockAttribute.paragraph]))
                replace(NSRange(location: insertAt, length: 0), with: piece)
            }
            setSelectedRange(NSRange(location: insertAt + 2, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    func updateTable(_ table: TableInfo, forParagraphAt location: Int) {
        let info = paragraphInfo(at: location)
        guard case .table = info.block.kind else { return }
        var edited = table
        edited.source = nil
        grouped("Edit Table") {
            replace(info.range, with: attachmentParagraph(.table(edited), kind: .table(edited)))
            setSelectedRange(NSRange(location: info.range.location, length: 1))
        }
    }

    // MARK: Inline formatting

    enum InlineFormat: CaseIterable {
        case bold, italic, strikethrough, code, highlight

        var key: NSAttributedString.Key {
            switch self {
            case .bold: return .lpBold
            case .italic: return .lpItalic
            case .strikethrough: return .lpStrike
            case .code: return .lpCode
            case .highlight: return .lpHighlight
            }
        }

        var value: Any {
            switch self {
            case .bold, .italic: return "*"
            default: return true
            }
        }

        var title: String {
            switch self {
            case .bold: return "Bold"
            case .italic: return "Italic"
            case .strikethrough: return "Strikethrough"
            case .code: return "Code"
            case .highlight: return "Highlight"
            }
        }
    }

    /// The parts of a selection that can carry inline formatting: text, but not code blocks,
    /// attachments or line endings.
    func styleableRanges(in selection: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        storage.enumerateParagraphs(in: selection) { paragraph in
            let kind = storage.block(at: paragraph.location).kind
            guard !kind.isVerbatim, !kind.isAttachment else { return }
            let range = NSIntersectionRange(storage.contentRange(of: paragraph), selection)
            if range.length > 0 { ranges.append(range) }
        }
        return ranges
    }

    func isActive(_ format: InlineFormat) -> Bool {
        let selection = selectedRange()
        if selection.length == 0 { return typingAttributes[format.key] != nil }
        let ranges = styleableRanges(in: selection)
        return !ranges.isEmpty && ranges.allSatisfy { covers($0, with: format.key) }
    }

    private func covers(_ range: NSRange, with key: NSAttributedString.Key) -> Bool {
        var effective = NSRange()
        guard storage.attribute(key, at: range.location, longestEffectiveRange: &effective, in: range) != nil else { return false }
        return NSMaxRange(effective) >= NSMaxRange(range)
    }

    func toggle(_ format: InlineFormat) {
        guard storage.length > 0 else { return }
        let selection = selectedRange()

        if selection.length == 0 {
            // Nothing selected: the format applies to what is typed next.
            var inline = typingAttributes
            if inline[format.key] != nil {
                inline.removeValue(forKey: format.key)
            } else {
                inline[format.key] = format.value
            }
            typingAttributes = styler.typingAttributes(for: paragraphInfo(at: selection.location).block, inline: inline)
            return
        }

        let ranges = styleableRanges(in: selection)
        guard !ranges.isEmpty else { return }
        let remove = ranges.allSatisfy { covers($0, with: format.key) }
        grouped(format.title) {
            guard shouldChangeText(in: selection, replacementString: nil) else { return }
            for range in ranges {
                if remove {
                    storage.removeAttribute(format.key, range: range)
                } else {
                    storage.addAttribute(format.key, value: format.value, range: range)
                }
            }
            didChangeText()
        }
    }

    /// The link under `location`, with the full range it covers.
    func link(at location: Int) -> (destination: String, range: NSRange)? {
        guard location >= 0, location < storage.length else { return nil }
        var range = NSRange()
        let paragraph = storage.contentRange(of: storage.paragraphRange(at: location))
        guard paragraph.length > 0, NSLocationInRange(location, paragraph),
              let link = storage.attribute(.lpLink, at: location, longestEffectiveRange: &range, in: paragraph) as? LinkAttribute
        else { return nil }
        return (link.info.destination, range)
    }

    /// Links `range` to `destination`, or removes the link when `destination` is nil or empty.
    func setLink(_ destination: String?, in range: NSRange) {
        let ranges = styleableRanges(in: range)
        guard !ranges.isEmpty else { return }
        grouped("Link") {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            for piece in ranges {
                storage.removeAttribute(.lpWiki, range: piece)
                if let destination, !destination.isEmpty {
                    storage.addAttribute(.lpLink, value: LinkAttribute(LinkInfo(destination: destination)), range: piece)
                } else {
                    storage.removeAttribute(.lpLink, range: piece)
                }
            }
            didChangeText()
        }
    }
}

nonisolated extension BlockKind {
    /// True when two kinds are the same sort of block, ignoring details like a to-do's state.
    func isSameCategory(as other: BlockKind) -> Bool {
        switch (self, other) {
        case (.paragraph, .paragraph), (.bullet, .bullet), (.numbered, .numbered), (.todo, .todo),
             (.quote, .quote), (.callout, .callout), (.code, .code), (.raw, .raw), (.divider, .divider):
            return true
        case (.heading(let lhs, _), .heading(let rhs, _)):
            return lhs == rhs
        default:
            return false
        }
    }
}
