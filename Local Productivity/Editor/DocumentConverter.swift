//
//  DocumentConverter.swift
//  Local Productivity
//
//  Translates between the Markdown block model and the editor's text storage.
//  One block is always exactly one paragraph: line breaks inside a block (a multi-line
//  quote, the lines of a code block) are stored as line separators, so a real newline
//  only ever means "next block".
//

import AppKit

nonisolated enum DocumentConverter {

    struct Context {
        var theme: EditorTheme
        /// Finds the file an image refers to. Returns nil when it cannot be located.
        var resolveImage: (ImageInfo) -> URL?
    }

    // MARK: Blocks → text

    /// Text carrying semantic attributes only. Run it through `EditorStyler` before showing it.
    @MainActor
    static func attributedString(for blocks: [Block], context: Context) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks.isEmpty ? [Block(kind: .paragraph)] : blocks {
            result.append(paragraph(for: block, context: context))
        }
        return result
    }

    @MainActor
    static func paragraph(for block: Block, context: Context) -> NSAttributedString {
        let piece: NSMutableAttributedString
        switch block.kind {
        case .divider:
            piece = attachmentString(.divider, context: context)
        case .image(let info):
            piece = attachmentString(.image(info), context: context)
        case .table(let info):
            piece = attachmentString(.table(info), context: context)
        default:
            piece = inlineString(for: block.runs, verbatim: block.kind.isVerbatim)
        }
        piece.append(NSAttributedString(string: "\n"))
        piece.addAttribute(.lpBlock, value: BlockAttribute(block), range: NSRange(location: 0, length: piece.length))
        return piece
    }

    static func inlineString(for runs: [InlineRun], verbatim: Bool = false) -> NSMutableAttributedString {
        let piece = NSMutableAttributedString()
        for run in runs {
            let text = run.text.replacingOccurrences(of: "\n", with: NSAttributedString.softBreak)
            piece.append(NSAttributedString(string: text, attributes: verbatim ? [:] : InlineAttributes.attributes(for: run.style)))
        }
        return piece
    }

    @MainActor
    static func makeAttachment(_ content: BlockAttachment.Content, context: Context) -> BlockAttachment {
        var url: URL? = nil
        if case .image(let info) = content { url = context.resolveImage(info) }
        let attachment = BlockAttachment(content: content, theme: context.theme, imageURL: url)
        attachment.attachmentCell = BlockAttachmentCell()
        return attachment
    }

    @MainActor
    private static func attachmentString(_ content: BlockAttachment.Content, context: Context) -> NSMutableAttributedString {
        NSMutableAttributedString(attachment: makeAttachment(content, context: context))
    }

    // MARK: Text → blocks

    /// Reads blocks back out of editor text. With a `range`, paragraphs are clipped to it, which is
    /// what copying a selection needs.
    static func blocks(from text: NSAttributedString, in range: NSRange? = nil) -> [Block] {
        let scope = range ?? NSRange(location: 0, length: text.length)
        var blocks: [Block] = []
        let string = text.string as NSString

        text.enumerateParagraphs(in: scope) { paragraph in
            let attribute = text.block(at: paragraph.location)
            var block = Block(kind: attribute.kind, indent: attribute.indent,
                              blankLinesBefore: attribute.blankLinesBefore, sourceIndent: attribute.sourceIndent)
            let content = NSIntersectionRange(text.contentRange(of: paragraph), scope)

            if !attribute.kind.isAttachment, content.length > 0 {
                let isVerbatim = attribute.kind.isVerbatim
                text.enumerateAttributes(in: content, options: []) { attributes, runRange, _ in
                    var characters = string.substring(with: runRange)
                    characters.makeContiguousUTF8()
                    if let attachment = attributes[.attachment] {
                        // An attachment that ended up inside running text is written out in line.
                        if let image = attachment as? BlockAttachment, case .image(let info) = image.content {
                            block.runs.append(InlineRun(text: MarkdownSerializer.imageMarkdown(info), style: InlineStyle(raw: true)))
                        }
                        characters = characters.replacingOccurrences(of: NSAttributedString.attachmentCharacter, with: "")
                        if characters.isEmpty { return }
                    }
                    characters = characters.replacingOccurrences(of: NSAttributedString.softBreak, with: "\n")
                    block.runs.append(InlineRun(text: characters, style: isVerbatim ? .plain : InlineAttributes.style(from: attributes)))
                }
                block.runs = InlineParser.merged(block.runs)
            }
            blocks.append(block)
        }
        return blocks
    }

    /// The Markdown for a selection: inline syntax only when it stays inside one block, whole
    /// blocks when it spans several.
    static func markdown(for text: NSAttributedString, in range: NSRange) -> String {
        let blocks = blocks(from: text, in: range)
        guard blocks.count > 1 || blocks.first?.kind.isAttachment == true else {
            guard let only = blocks.first else { return "" }
            return only.kind.isVerbatim ? only.plainText : InlineSerializer.serialize(only.runs)
        }
        var text = MarkdownSerializer.serialize(MarkdownDocument(blocks: blocks.map { block in
            var copy = block
            copy.blankLinesBefore = nil
            copy.sourceIndent = nil
            return copy
        }))
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
