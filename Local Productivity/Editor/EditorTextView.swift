//
//  EditorTextView.swift
//  Local Productivity
//
//  The writing surface. It is a TextKit 1 text view whose storage holds the rendered
//  document: no Markdown syntax, one paragraph per block. This file sets the view up
//  and handles selection, the caret, drawing and the mouse; editing behaviour lives in
//  the `+Editing` and `+Input` extensions.
//

import AppKit

/// What the text view needs from whoever owns it.
protocol EditorTextViewHost: AnyObject {
    /// Called for key presses before the text view acts on them. Return true to consume the event.
    func editorShouldHandle(_ event: NSEvent) -> Bool
    /// The user typed a character that starts an inline menu (`/` for commands, `[[` for page links).
    func editorDidBeginQuery(_ kind: InlineQuery.Kind, at anchor: Int)
    /// Up arrow on the first line, or Delete at the very start: focus should move to the title.
    func editorWantsTitleFocus()
    func editorDidClickCalloutIcon(inParagraphAt location: Int, rect: NSRect)
    func editorDidClickLanguage(inParagraphAt location: Int, rect: NSRect)
    func editorDidActivateTable(inParagraphAt location: Int)
    func editorMouseMoved(to point: NSPoint?)
    /// Stores pasted image data with the workspace and returns how the page should refer to it.
    func editorImportImage(_ data: Data, fileExtension: String) -> ImageInfo?
    /// Brings a dropped file into the workspace and returns the path the page should use for it.
    func editorImportFile(at url: URL) -> String?
}

/// Text being typed after a trigger character, used to filter an inline menu.
struct InlineQuery {
    enum Kind {
        case command
        case pageLink

        var triggerLength: Int { self == .command ? 1 : 2 }
    }

    var kind: Kind
    /// Location of the first trigger character.
    var anchor: Int
}

final class EditorTextView: NSTextView {

    // The text system is built by hand so that it is TextKit 1 with our own layout classes.
    let storage = NSTextStorage()
    let editorLayoutManager = EditorLayoutManager()
    let editorContainer = EditorTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    private let normalizer = StorageNormalizer()

    weak var host: EditorTextViewHost?
    var converterContext = DocumentConverter.Context(theme: EditorTheme(), resolveImage: { _ in nil })

    var theme = EditorTheme() {
        didSet {
            guard theme != oldValue else { return }
            applyTheme()
        }
    }

    var styler: EditorStyler { EditorStyler(theme: theme) }

    /// Room above the text for the page header.
    var topInset: CGFloat = 0
    /// Room below the text so the last line can be scrolled up to a comfortable height.
    var bottomInset: CGFloat = 180
    private(set) var sideInset: CGFloat = 0

    /// True while the whole document is being swapped out, which lifts the usual edit guards.
    var isReplacingDocument = false
    /// Non-zero between `shouldChangeText` and `didChangeText`. AppKit moves the selection through
    /// intermediate positions while it edits; those must not be mistaken for the caret landing somewhere.
    var pendingEdits = 0
    /// Set after an inline shortcut converts text, so the next characters typed are plain again.
    var plainTypingLocation: Int?

    private var placeholderLocation: Int?
    private var selectedAttachment: BlockAttachment?
    private var hoverTrackingArea: NSTrackingArea?

    init() {
        editorContainer.lineFragmentPadding = 0
        editorContainer.widthTracksTextView = false
        editorLayoutManager.addTextContainer(editorContainer)
        storage.addLayoutManager(editorLayoutManager)
        storage.delegate = normalizer
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: editorContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorTextView is created in code")
    }

    private func configure() {
        isRichText = true
        isEditable = true
        isSelectable = true
        allowsUndo = true
        drawsBackground = false
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        isAutomaticDashSubstitutionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false

        insertionPointColor = .controlAccentColor
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        applyTheme()
    }

    private func applyTheme() {
        editorContainer.theme = theme
        editorLayoutManager.theme = theme
        normalizer.styler = styler
        converterContext.theme = theme
        guard storage.length > 0 else { return }

        let everything = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: everything, options: []) { value, _, _ in
            (value as? BlockAttachment)?.theme = theme
        }
        storage.beginEditing()
        styler.normalize(storage, in: everything)
        storage.endEditing()
        refreshTypingAttributes()
        needsDisplay = true
    }

    // MARK: Document

    /// Replaces the whole document. Undo history is discarded.
    func setDocument(_ content: NSAttributedString) {
        isReplacingDocument = true
        undoManager?.removeAllActions()
        storage.setAttributedString(content)
        isReplacingDocument = false
        plainTypingLocation = nil
        setSelectedRange(NSRange(location: 0, length: 0))
        refreshTypingAttributes()
        needsDisplay = true
    }

    // MARK: Column layout

    /// Centres a column of at most `readingWidth` in the view and reserves the insets around it.
    func layoutColumn(viewWidth: CGFloat, readingWidth: CGFloat) {
        let margin = max(48, min(96, viewWidth * 0.07))
        let column = max(260, min(readingWidth, viewWidth - margin * 2)).rounded(.down)
        sideInset = max(0, ((viewWidth - column) / 2).rounded(.down))
        if abs(editorContainer.size.width - column) > 0.5 {
            editorContainer.size = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
        }
        textContainerInset = NSSize(width: sideInset, height: (topInset + bottomInset) / 2)
        invalidateTextContainerOrigin()
    }

    var columnWidth: CGFloat { editorContainer.size.width }

    /// The text container's inset is symmetric; overriding the origin lets the top and bottom differ.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: sideInset, y: topInset)
    }

    // MARK: Selection

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let length = storage.length
        var adjusted = ranges
        if length > 0 {
            // The final newline only terminates the last block. It can be neither selected nor passed.
            let limit = length - 1
            adjusted = ranges.map { value in
                let range = value.rangeValue
                let start = min(range.location, limit)
                let end = min(NSMaxRange(range), limit)
                return NSValue(range: NSRange(location: start, length: max(0, end - start)))
            }
            // A caret cannot sit inside a divider, image or table; the block is selected instead.
            if !stillSelecting, pendingEdits == 0, adjusted.count == 1, adjusted[0].rangeValue.length == 0 {
                let paragraph = storage.paragraphRange(at: adjusted[0].rangeValue.location)
                if storage.block(at: paragraph.location).kind.isAttachment, paragraph.length >= 2 {
                    adjusted = [NSValue(range: NSRange(location: paragraph.location, length: 1))]
                }
            }
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { selectionDidSettle() }
    }

    private func selectionDidSettle() {
        if let location = plainTypingLocation, location != selectedRange().location { plainTypingLocation = nil }
        refreshTypingAttributes()

        // Let the selected block attachment draw its selection ring.
        let attachment = selectedAttachmentParagraph.flatMap {
            storage.attribute(.attachment, at: $0.location, effectiveRange: nil) as? BlockAttachment
        }
        if attachment !== selectedAttachment {
            selectedAttachment?.isSelected = false
            attachment?.isSelected = true
            selectedAttachment = attachment
            needsDisplay = true
        }

        // The placeholder follows the caret between empty blocks.
        let placeholder = placeholderTarget()?.paragraph.location
        if placeholder != placeholderLocation {
            placeholderLocation = placeholder
            needsDisplay = true
        }
    }

    /// The paragraph of the divider, image or table that is currently selected as a block.
    var selectedAttachmentParagraph: NSRange? {
        let selection = selectedRange()
        guard selection.length == 1, selection.location < storage.length,
              storage.attribute(.attachment, at: selection.location, effectiveRange: nil) is BlockAttachment else { return nil }
        let paragraph = storage.paragraphRange(at: selection.location)
        return storage.block(at: paragraph.location).kind.isAttachment ? paragraph : nil
    }

    var isCaretOnFirstLine: Bool {
        let selection = selectedRange()
        guard selection.length == 0, storage.length > 0 else { return false }
        let glyph = editorLayoutManager.glyphIndexForCharacter(at: min(selection.location, storage.length - 1))
        var lineRange = NSRange()
        editorLayoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        return lineRange.location == 0
    }

    var isCaretOnLastLine: Bool {
        let selection = selectedRange()
        guard selection.length == 0, storage.length > 0 else { return false }
        let glyph = editorLayoutManager.glyphIndexForCharacter(at: min(selection.location, storage.length - 1))
        var lineRange = NSRange()
        editorLayoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        return NSMaxRange(lineRange) >= editorLayoutManager.numberOfGlyphs
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    // MARK: Geometry for overlays

    /// The rectangle of the caret or selection start, in this view's coordinates.
    func rect(forCharacterAt location: Int) -> NSRect {
        guard storage.length > 0 else { return NSRect(origin: textContainerOrigin, size: NSSize(width: 1, height: 20)) }
        let clamped = min(max(location, 0), storage.length - 1)
        let glyph = editorLayoutManager.glyphIndexForCharacter(at: clamped)
        let line = editorLayoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let point = editorLayoutManager.location(forGlyphAt: glyph)
        let origin = textContainerOrigin
        return NSRect(x: origin.x + line.minX + point.x, y: origin.y + line.minY, width: 1, height: line.height)
    }

    /// The bounding rectangle of a character range, in this view's coordinates.
    func rect(forRange range: NSRange) -> NSRect {
        let glyphs = editorLayoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = editorLayoutManager.boundingRect(forGlyphRange: glyphs, in: editorContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The paragraph under a point in view coordinates, with its frame in view coordinates.
    func block(at point: NSPoint) -> (paragraph: NSRange, block: BlockAttribute, frame: NSRect)? {
        guard storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = editorLayoutManager.glyphIndex(for: local, in: editorContainer, fractionOfDistanceThroughGlyph: nil)
        let character = min(editorLayoutManager.characterIndexForGlyph(at: glyph), storage.length - 1)
        let paragraph = storage.paragraphRange(at: character)
        let block = storage.block(at: paragraph.location)
        guard let frame = editorLayoutManager.frame(ofParagraph: paragraph) else { return nil }
        let box = editorLayoutManager.boxRect(for: block, frame: frame).offsetBy(dx: origin.x, dy: origin.y)
        return (paragraph, block, box)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholder()
    }

    private func placeholderTarget() -> (paragraph: NSRange, block: BlockAttribute, text: String)? {
        let selection = selectedRange()
        guard selection.length == 0, storage.length > 0 else { return nil }
        let paragraph = storage.paragraphRange(at: selection.location)
        guard storage.contentRange(of: paragraph).length == 0 else { return nil }

        let block = storage.block(at: paragraph.location)
        let isOnlyBlock = storage.length == 1
        let isFocused = window?.firstResponder === self
        guard isFocused || isOnlyBlock else { return nil }

        let text: String
        switch block.kind {
        case .paragraph:
            if block.indent > 0 { return nil }
            text = isOnlyBlock ? "Start writing, or press / for commands" : "Type / for commands"
        case .heading(let level, _): text = "Heading \(level)"
        case .bullet, .numbered: text = "List"
        case .todo: text = "To-do"
        case .quote: text = "Quote"
        case .callout: text = "Type something"
        case .code: text = "Code"
        default: return nil
        }
        return (paragraph, block, text)
    }

    private func drawPlaceholder() {
        guard !hasMarkedText(), let target = placeholderTarget(),
              let frame = editorLayoutManager.frame(ofParagraph: target.paragraph) else { return }
        let font = theme.baseFont(for: target.block.kind)
        let origin = textContainerOrigin
        let point = NSPoint(x: origin.x + theme.leadingInset(for: target.block.kind, indent: target.block.indent),
                            y: origin.y + frame.baseline - font.ascender)
        NSAttributedString(string: target.text, attributes: [.font: font, .foregroundColor: NSColor.lpInkTertiary])
            .draw(at: point)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    /// The checkbox or callout icon under a point in view coordinates.
    private func control(at point: NSPoint) -> (paragraph: NSRange, block: BlockAttribute, rect: NSRect)? {
        guard storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard local.y >= 0 else { return nil }
        let glyph = editorLayoutManager.glyphIndex(for: local, in: editorContainer, fractionOfDistanceThroughGlyph: nil)
        let character = min(editorLayoutManager.characterIndexForGlyph(at: glyph), storage.length - 1)
        let paragraph = storage.paragraphRange(at: character)
        let block = storage.block(at: paragraph.location)
        guard let frame = editorLayoutManager.frame(ofParagraph: paragraph) else { return nil }

        if let rect = editorLayoutManager.controlRect(for: block, frame: frame), rect.insetBy(dx: -4, dy: -4).contains(local) {
            return (paragraph, block, rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        if let label = editorLayoutManager.languageLabel(for: block, paragraph: paragraph, frame: frame),
           label.rect.insetBy(dx: -6, dy: -5).contains(local) {
            return (paragraph, block, label.rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        host?.editorMouseMoved(to: point)
        if control(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        host?.editorMouseMoved(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let hit = control(at: point) {
            switch hit.block.kind {
            case .todo:
                toggleTodo(at: hit.paragraph.location)
            case .callout:
                host?.editorDidClickCalloutIcon(inParagraphAt: hit.paragraph.location, rect: hit.rect)
            case .code:
                host?.editorDidClickLanguage(inParagraphAt: hit.paragraph.location, rect: hit.rect)
            default:
                break
            }
            return
        }

        super.mouseDown(with: event)

        // Double-clicking a table opens its editor.
        if event.clickCount == 2, let paragraph = selectedAttachmentParagraph,
           case .table = storage.block(at: paragraph.location).kind {
            host?.editorDidActivateTable(inParagraphAt: paragraph.location)
            return
        }

        // Clicking in the empty space under the document starts a new paragraph there,
        // unless the document already ends in an empty one.
        guard event.clickCount == 1, storage.length > 0 else { return }
        let last = storage.paragraphRange(at: storage.length - 1)
        guard let frame = editorLayoutManager.frame(ofParagraph: last) else { return }
        let bottom = textContainerOrigin.y + frame.lines.maxY + theme.innerPadding(for: storage.block(at: last.location).kind)
        if point.y > bottom + 6 {
            let block = storage.block(at: last.location)
            let isEmptyParagraph = block.kind == .paragraph && storage.contentRange(of: last).length == 0
            if isEmptyParagraph {
                setSelectedRange(NSRange(location: last.location, length: 0))
            } else {
                appendParagraph()
            }
        }
    }
}

// MARK: - Storage delegate

/// Keeps the storage consistent after every edit: each paragraph is one block, styled from its meaning.
nonisolated final class StorageNormalizer: NSObject, NSTextStorageDelegate {

    var styler = EditorStyler(theme: EditorTheme())

    // Styling happens in *did* process editing. Attribute changes made there are reported to the layout
    // manager as invalidated layout, not as edited text, so the selection is left where the edit put it.
    // (Doing this in "will process editing" makes the whole restyled range count as edited, and AppKit
    // then moves the caret to the end of it.)
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard textStorage.length > 0 else { return }
        var range = (textStorage.string as NSString).paragraphRange(
            for: NSRange(location: min(editedRange.location, textStorage.length), length: min(editedRange.length, textStorage.length - min(editedRange.location, textStorage.length)))
        )
        // The space above the following block depends on this one, so lay it out again too.
        if NSMaxRange(range) < textStorage.length {
            range = NSUnionRange(range, textStorage.paragraphRange(at: NSMaxRange(range)))
        }
        let styled = styler.normalize(textStorage, in: range)
        // Fonts were just assigned, after the storage's own fixing pass: substitute fallback fonts for
        // emoji and scripts the chosen typeface does not cover.
        textStorage.fixFontAttribute(in: styled)
    }
}
