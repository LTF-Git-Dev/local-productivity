//
//  EditorController.swift
//  Local Productivity
//
//  Hosts the editor for one page: the scroll view and text view, the header with the
//  page's icon and title, and the small floating pieces of interface that appear while
//  writing — the slash-command menu, the page-link menu and the formatting bar.
//

import AppKit
import SwiftUI

final class EditorController: NSViewController, NSTextViewDelegate, EditorTextViewHost {

    let session: PageSession
    private unowned let app: AppModel

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    private let documentUndoManager = UndoManager()
    private var headerController: NSHostingController<PageHeaderView>!

    private var readingWidth = Metrics.readingWidth
    private var isLayingOut = false

    // Inline menus (slash commands, page links)
    private var query: InlineQuery?
    private let menuModel = EditorMenuModel()
    private var menuHost: NSView?

    // Block handle (the "+" and grip beside the block under the pointer)
    private var handleHost: NSView?
    private var handleParagraph: Int?
    private var handleHideTask: Task<Void, Never>?

    // Formatting bar
    private let formatModel = FormatBarModel()
    private var formatHost: NSView?
    private var formatBarTask: Task<Void, Never>?
    private var linkPopover: NSPopover?

    init(session: PageSession, app: AppModel) {
        self.session = session
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorController is created in code")
    }

    // MARK: View

    override func loadView() {
        let root = NSView()

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true
        root.addSubview(scrollView)

        textView.host = self
        textView.delegate = self

        headerController = NSHostingController(rootView: PageHeaderView(
            session: session, app: app, onLayoutChange: { [weak self] in self?.setNeedsContentLayout() }
        ))
        headerController.sizingOptions = []
        addChild(headerController)
        textView.addSubview(headerController.view)

        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        view = root
        session.controller = self
        loadDocument()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutContent()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        session.flush()
        dismissMenu()
        hideFormatBar()
        hideHandle()
    }

    private func setNeedsContentLayout() {
        DispatchQueue.main.async { [weak self] in self?.layoutContent() }
    }

    /// Sizes the reading column, fits the header above the text and reserves room for it.
    private func layoutContent() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        let size = scrollView.contentSize
        guard size.width > 0 else { return }
        textView.minSize = NSSize(width: 0, height: size.height)
        if abs(textView.frame.width - size.width) > 0.5 {
            textView.setFrameSize(NSSize(width: size.width, height: textView.frame.height))
        }
        textView.layoutColumn(viewWidth: size.width, readingWidth: readingWidth)

        let headerTop: CGFloat = 44
        let column = textView.columnWidth
        let fitted = headerController.sizeThatFits(in: NSSize(width: column, height: 10_000))
        let headerHeight = ceil(fitted.height)
        headerController.view.frame = NSRect(x: textView.sideInset, y: headerTop, width: column, height: headerHeight)

        let topInset = headerTop + headerHeight + 16
        if abs(textView.topInset - topInset) > 0.5 {
            textView.topInset = topInset
            textView.layoutColumn(viewWidth: size.width, readingWidth: readingWidth)
            textView.needsDisplay = true
        }
        positionMenu()
    }

    // MARK: Settings

    func apply(_ settings: AppSettings) {
        let theme = settings.editorTheme
        if theme != textView.theme { textView.theme = theme }
        textView.isContinuousSpellCheckingEnabled = settings.checksSpelling

        let width = settings.pageWidth.columnWidth(for: settings.editorTextSize) ?? 10_000
        if width != readingWidth {
            readingWidth = width
            layoutContent()
        }
    }

    // MARK: Document

    private func loadDocument() {
        textView.converterContext = DocumentConverter.Context(theme: textView.theme) { [weak session] info in
            session?.resolveImage(info)
        }
        let document = session.readDocument()
        textView.setDocument(DocumentConverter.attributedString(for: document.blocks, context: textView.converterContext))
        // A page that couldn't be read stays read-only until it can be.
        textView.isEditable = session.readFailure == nil
        // Long pages only: for short ones a cold save is already instant. The parsed blocks carry
        // the same runs the editor will produce, so nothing has to be read back from the editor.
        if textView.storage.length > 20_000 { session.warmSaveCache(with: document.blocks) }
    }

    /// Shows a new version of the document that arrived from disk, keeping the reader's place.
    func reload(_ document: MarkdownDocument) {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        dismissMenu()
        hideFormatBar()
        textView.setDocument(DocumentConverter.attributedString(for: document.blocks, context: textView.converterContext))
        textView.isEditable = session.readFailure == nil
        let location = min(selection.location, max(0, textView.storage.length - 1))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func currentBlocks() -> [Block] {
        DocumentConverter.blocks(from: textView.storage)
    }

    func focusBody(atEnd: Bool = false) {
        guard let window = view.window else { return }
        window.makeFirstResponder(textView)
        if atEnd, textView.storage.length > 0 {
            textView.setSelectedRange(NSRange(location: textView.storage.length - 1, length: 0))
        }
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        documentUndoManager
    }

    func textDidChange(_ notification: Notification) {
        session.contentDidChange()
        hideHandle()
        updateQuery()
        if textView.selectedRange().length == 0 { hideFormatBar() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateQuery()
        scheduleFormatBar()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let storage = textView.textStorage, charIndex < storage.length else { return true }
        let attributes = storage.attributes(at: charIndex, effectiveRange: nil)
        if let wiki = attributes[.lpWiki] as? WikiAttribute {
            var target = wiki.info.target
            if !wiki.info.hasAlias {
                // Without an alias the visible text is the target, and it may have been edited.
                var range = NSRange()
                let paragraph = storage.paragraphRange(at: charIndex)
                _ = storage.attribute(.lpWiki, at: charIndex, longestEffectiveRange: &range, in: paragraph)
                target = (storage.string as NSString).substring(with: range)
            }
            app.openWikiLink(target, from: session.path)
        } else if let link = attributes[.lpLink] as? LinkAttribute {
            app.openLink(link.info.destination, from: session.path)
        }
        return true
    }

    /// Code, raw source and inline code are not prose; leave them out of spell checking.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0, let storage = textView.textStorage, affectedCharRange.location < storage.length else { return value }
        if storage.block(at: affectedCharRange.location).kind.isVerbatim { return 0 }
        let attributes = storage.attributes(at: affectedCharRange.location, effectiveRange: nil)
        return attributes[.lpCode] != nil || attributes[.lpRaw] != nil ? 0 : value
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        // The stock menu offers fonts, colours and text direction, none of which exist in Markdown.
        let unwanted: Set<String> = ["Font", "Layout Orientation", "Paragraph Direction", "Selection Direction", "Share…", "Share"]
        for item in menu.items where unwanted.contains(item.title) {
            menu.removeItem(item)
        }
        return menu
    }

    // MARK: EditorTextViewHost

    func editorShouldHandle(_ event: NSEvent) -> Bool {
        guard query != nil, menuHost != nil else { return false }
        switch event.keyCode {
        case 125:
            menuModel.move(by: 1)
        case 126:
            menuModel.move(by: -1)
        case 36, 76, 48:
            guard let item = menuModel.selectedItem else {
                dismissMenu()
                return false
            }
            commit(item)
        case 53:
            dismissMenu()
        default:
            return false
        }
        return true
    }

    func editorDidBeginQuery(_ kind: InlineQuery.Kind, at anchor: Int) {
        query = InlineQuery(kind: kind, anchor: anchor)
        menuModel.selection = 0
        hideFormatBar()
        updateQuery()
    }

    func editorWantsTitleFocus() {
        session.focusRequest = .title
    }

    func editorDidClickCalloutIcon(inParagraphAt location: Int, rect: NSRect) {
        let menu = NSMenu()
        for choice in CalloutStyle.choices {
            let item = NSMenuItem(title: choice.style.label, action: #selector(pickCalloutType(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [choice.type, location] as [Any]
            item.image = NSImage(systemSymbolName: choice.style.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 6), in: textView)
    }

    @objc private func pickCalloutType(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [Any], let type = payload.first as? String,
              let location = payload.last as? Int else { return }
        textView.setCalloutType(type, forParagraphAt: location)
    }

    private static let languages = [
        "", "bash", "c", "cpp", "css", "go", "html", "java", "javascript", "json", "kotlin", "markdown",
        "python", "ruby", "rust", "sql", "swift", "typescript", "yaml"
    ]

    func editorDidClickLanguage(inParagraphAt location: Int, rect: NSRect) {
        let menu = NSMenu()
        for language in Self.languages {
            let item = NSMenuItem(title: language.isEmpty ? "Plain Text" : language, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [language, location] as [Any]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 6), in: textView)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [Any], let language = payload.first as? String,
              let location = payload.last as? Int else { return }
        textView.setCodeLanguage(language, forParagraphAt: location)
    }

    func editorDidActivateTable(inParagraphAt location: Int) {
        guard case .table(let table) = textView.storage.block(at: location).kind else { return }
        session.tableEdit = PageSession.TableEdit(location: location, table: table)
    }

    func editorMouseMoved(to point: NSPoint?) {
        guard let point, query == nil, NSEvent.pressedMouseButtons == 0, let hit = textView.block(at: point) else {
            scheduleHandleHide()
            return
        }
        handleHideTask?.cancel()
        showHandle(forParagraphAt: hit.paragraph.location)
    }

    func editorImportImage(_ data: Data, fileExtension: String) -> ImageInfo? {
        session.importImage(data, fileExtension: fileExtension)
    }

    func editorImportFile(at url: URL) -> String? {
        session.importFile(at: url)
    }

    // MARK: Block handle

    private func showHandle(forParagraphAt location: Int) {
        if handleHost == nil {
            let host = PassiveHostingView(rootView: BlockHandleView(
                onAdd: { [weak self] in
                    guard let self, let location = self.handleParagraph else { return }
                    self.hideHandle()
                    self.textView.addBlock(below: location)
                },
                onMenu: { [weak self] in self?.showBlockMenu() }
            ))
            view.addSubview(host)
            handleHost = host
        }
        handleParagraph = location
        positionHandle()
    }

    private func positionHandle() {
        guard let handleHost, let location = handleParagraph, location < textView.storage.length else { return }
        let paragraph = textView.storage.paragraphRange(at: location)
        guard let frame = textView.editorLayoutManager.frame(ofParagraph: paragraph) else { return }
        let block = textView.storage.block(at: paragraph.location)
        let origin = textView.textContainerOrigin
        let size = BlockHandleView.size
        // Centred on the block's first line, just outside the left edge of the column.
        let line = NSRect(x: origin.x + textView.theme.boxOrigin(indent: block.indent) - size.width - 6,
                          y: origin.y + frame.firstLine.midY - size.height / 2, width: size.width, height: size.height)
        handleHost.frame = textView.convert(line, to: view)
    }

    private func scheduleHandleHide() {
        handleHideTask?.cancel()
        handleHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.hideHandle()
        }
    }

    private func hideHandle() {
        handleHideTask?.cancel()
        handleHost?.removeFromSuperview()
        handleHost = nil
        handleParagraph = nil
    }

    private func showBlockMenu() {
        guard let location = handleParagraph, let handleHost, location < textView.storage.length else { return }
        let kind = textView.storage.block(at: location).kind
        let menu = NSMenu()

        func add(_ title: String, _ symbol: String, to target: NSMenu = menu, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            target.addItem(item)
        }

        if !kind.isAttachment {
            let turnInto = NSMenu()
            let choices: [(String, String, BlockKind)] = [
                ("Text", "textformat", .paragraph), ("Heading 1", "1.square", .heading1), ("Heading 2", "2.square", .heading2),
                ("Heading 3", "3.square", .heading3), ("To-do List", "checkmark.square", .openTodo),
                ("Bulleted List", "list.bullet", .bulletItem), ("Numbered List", "list.number", .numberedItem),
                ("Quote", "text.quote", .quote), ("Callout", "lightbulb", .note),
                ("Code", "chevron.left.forwardslash.chevron.right", .codeBlock)
            ]
            for (title, symbol, target) in choices {
                add(title, symbol, to: turnInto) { [weak self] in
                    guard let self else { return }
                    self.textView.setSelectedRange(NSRange(location: location, length: 0))
                    if !self.textView.storage.block(at: location).kind.isSameCategory(as: target) {
                        self.textView.turnInto(target)
                    }
                }
            }
            let parent = NSMenuItem(title: "Turn Into", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            parent.submenu = turnInto
            menu.addItem(parent)
            menu.addItem(.separator())
        } else if case .table = kind {
            add("Edit Table…", "tablecells") { [weak self] in self?.editorDidActivateTable(inParagraphAt: location) }
            menu.addItem(.separator())
        }

        add("Duplicate", "plus.square.on.square") { [weak self] in self?.textView.duplicateBlock(at: location) }
        add("Move Up", "arrow.up") { [weak self] in self?.textView.moveBlock(at: location, up: true) }
        add("Move Down", "arrow.down") { [weak self] in self?.textView.moveBlock(at: location, up: false) }
        menu.addItem(.separator())
        add("Delete", "trash") { [weak self] in self?.textView.deleteBlock(at: location) }

        menu.popUp(positioning: nil, at: NSPoint(x: handleHost.frame.minX, y: handleHost.frame.minY - 4), in: view)
        hideHandle()
    }

    @objc private func scrollViewDidScroll() {
        positionMenu()
        positionHandle()
        // Hide while scrolling; the bar returns once the selection has come to rest.
        if formatHost != nil || textView.selectedRange().length > 0 { scheduleFormatBar(hidingFirst: true) }
    }

    // MARK: Inline menus

    /// Re-reads the text typed after the trigger and refreshes or closes the menu.
    private func updateQuery() {
        guard let query else { return }
        let storage = textView.storage
        let selection = textView.selectedRange()
        let start = query.anchor + query.kind.triggerLength
        guard selection.length == 0, selection.location >= start, start <= storage.length else {
            dismissMenu()
            return
        }
        let content = storage.contentRange(of: storage.paragraphRange(at: query.anchor))
        guard selection.location <= NSMaxRange(content) else {
            dismissMenu()
            return
        }
        let trigger = storage.mutableString.substring(with: NSRange(location: query.anchor, length: query.kind.triggerLength))
        let text = storage.mutableString.substring(with: NSRange(location: start, length: selection.location - start))
        guard trigger == (query.kind == .command ? "/" : "[["), text.count <= 48, !text.contains("\u{2028}"), !text.contains("]") else {
            dismissMenu()
            return
        }

        let items: [EditorMenuItem]
        switch query.kind {
        case .command:
            items = EditorMenuItem.commands(matching: text)
            menuModel.title = "Blocks"
            menuModel.emptyText = "No matching blocks"
        case .pageLink:
            items = pageItems(matching: text)
            menuModel.title = "Link to page"
            menuModel.emptyText = "Type a page name"
        }
        // Give up once the text clearly is not a search any more.
        if items.isEmpty, text.count > 12 || text.hasSuffix(" ") {
            dismissMenu()
            return
        }
        menuModel.items = items
        menuModel.selection = min(menuModel.selection, max(0, items.count - 1))
        showMenu()
    }

    private func pageItems(matching text: String) -> [EditorMenuItem] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        let workspace = session.workspace
        var candidates = workspace.pages.filter { $0.path != session.path }
        if needle.isEmpty {
            let recent = workspace.recents
            candidates.sort { (recent.firstIndex(of: $0.path) ?? .max, $0.name) < (recent.firstIndex(of: $1.path) ?? .max, $1.name) }
        } else {
            candidates = candidates.filter { $0.name.lowercased().contains(needle) }
            candidates.sort { ($0.name.lowercased().hasPrefix(needle) ? 0 : 1, $0.name.count) < ($1.name.lowercased().hasPrefix(needle) ? 0 : 1, $1.name.count) }
        }
        var items = candidates.prefix(8).map { page in
            EditorMenuItem(id: "page:" + page.path, title: page.name,
                           subtitle: page.parentPath.isEmpty ? nil : page.parentPath.replacingOccurrences(of: "/", with: " › "),
                           symbol: "doc.text", emoji: workspace.icon(of: page.path), action: .link(title: page.name))
        }
        let exact = candidates.contains { $0.name.lowercased() == needle }
        if !needle.isEmpty, !exact {
            let title = text.trimmingCharacters(in: .whitespaces)
            items.append(EditorMenuItem(id: "create", title: "Create “\(title)”", subtitle: "New page", symbol: "plus",
                                        emoji: nil, action: .createPage(title: title)))
        }
        return items
    }

    private func showMenu() {
        if menuHost == nil {
            menuModel.onPick = { [weak self] item in self?.commit(item) }
            let host = PassiveHostingView(rootView: EditorMenuView(model: menuModel))
            view.addSubview(host)
            menuHost = host
        }
        positionMenu()
    }

    private func positionMenu() {
        guard let menuHost, let query else { return }
        let size = menuHost.fittingSize
        let caret = textView.convert(textView.rect(forCharacterAt: query.anchor), to: view)
        let padding = EditorMenuView.shadowPadding
        var origin = NSPoint(x: caret.minX - padding - 4, y: caret.maxY + 4 - padding)
        // The root view is not flipped, so "below the caret" means a smaller y.
        if view.isFlipped == false {
            origin.y = caret.minY - 4 - size.height + padding
            if origin.y < -padding + 8 { origin.y = caret.maxY + 4 - padding }
        }
        origin.x = min(max(origin.x, 8 - padding), view.bounds.width - size.width + padding - 8)
        menuHost.frame = NSRect(origin: origin, size: size)
    }

    private func dismissMenu() {
        query = nil
        menuHost?.removeFromSuperview()
        menuHost = nil
    }

    private func commit(_ item: EditorMenuItem) {
        guard let query else { return }
        let caret = textView.selectedRange().location
        let typed = NSRange(location: query.anchor, length: max(0, caret - query.anchor))
        dismissMenu()

        textView.grouped("Insert") {
            guard textView.replace(typed, with: NSAttributedString()) else { return }
            textView.setSelectedRange(NSRange(location: query.anchor, length: 0))
            let info = textView.paragraphInfo(at: query.anchor)

            switch item.action {
            case .turnInto(let kind):
                if info.isEmpty {
                    textView.setBlock(info.block.with(kind: kind), forParagraphAt: info.range.location)
                } else {
                    let location = textView.insertBlock(BlockAttribute(kind: kind, indent: info.block.indent), after: info.range)
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                }
            case .divider:
                textView.insertAttachment(.divider, kind: .rule)
            case .table:
                let table = TableInfo(alignments: [.none, .none, .none], header: ["Column 1", "Column 2", "Column 3"],
                                      rows: [["", "", ""], ["", "", ""]])
                textView.insertAttachment(.table(table), kind: .table(table))
            case .link(let title):
                insertWikiLink(to: title, at: query.anchor, block: info.block)
            case .createPage(let title):
                if let path = try? session.workspace.createPage(in: session.folder, title: title) {
                    insertWikiLink(to: FileNode.title(of: path), at: query.anchor, block: info.block)
                }
            }
        }

        if case .table = item.action, let paragraph = previousTableParagraph() {
            editorDidActivateTable(inParagraphAt: paragraph)
        }
    }

    /// The table just inserted sits in the block before the caret.
    private func previousTableParagraph() -> Int? {
        let caret = textView.selectedRange().location
        guard caret > 0 else { return nil }
        let paragraph = textView.storage.paragraphRange(at: caret - 1)
        if case .table = textView.storage.block(at: paragraph.location).kind { return paragraph.location }
        return nil
    }

    private func insertWikiLink(to title: String, at location: Int, block: BlockAttribute) {
        let link = NSAttributedString(string: title, attributes: [
            .lpWiki: WikiAttribute(WikiLinkInfo(target: title, hasAlias: false)),
            .lpBlock: block
        ])
        guard textView.replace(NSRange(location: location, length: 0), with: link) else { return }
        let end = location + link.length
        textView.plainTypingLocation = end
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }

    // MARK: Formatting bar

    private func scheduleFormatBar(hidingFirst: Bool = false) {
        formatBarTask?.cancel()
        if hidingFirst {
            formatHost?.removeFromSuperview()
            formatHost = nil
        }
        let selection = textView.selectedRange()
        guard selection.length > 0, query == nil, textView.selectedAttachmentParagraph == nil,
              !textView.styleableRanges(in: selection).isEmpty, view.window?.firstResponder === textView else {
            hideFormatBar()
            return
        }
        formatBarTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            // Wait for the drag to finish; the bar would otherwise chase the pointer.
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleFormatBar()
                return
            }
            self.showFormatBar()
        }
    }

    private func showFormatBar() {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        formatModel.active = Set(EditorTextView.InlineFormat.allCases.filter { textView.isActive($0) })
        formatModel.hasLink = textView.link(at: selection.location) != nil
        formatModel.onToggle = { [weak self] format in
            guard let self else { return }
            self.textView.toggle(format)
            self.formatModel.active = Set(EditorTextView.InlineFormat.allCases.filter { self.textView.isActive($0) })
        }
        formatModel.onLink = { [weak self] in self?.editLink() }

        if formatHost == nil {
            let host = PassiveHostingView(rootView: FormatBarView(model: formatModel))
            view.addSubview(host)
            formatHost = host
        }
        guard let formatHost else { return }

        // Sit just above the first line of the selection.
        let firstLine = textView.rect(forCharacterAt: selection.location)
        let bounds = textView.rect(forRange: selection)
        var anchor = textView.convert(NSRect(x: bounds.minX, y: firstLine.minY, width: bounds.width, height: firstLine.height), to: view)
        anchor = anchor.intersection(view.bounds.insetBy(dx: 0, dy: -200))
        let size = formatHost.fittingSize
        let padding = FormatBarView.shadowPadding
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8 - padding)
        if origin.y + size.height - padding > view.bounds.height - 8 {
            origin.y = anchor.minY - 8 - size.height + padding
        }
        origin.x = min(max(origin.x, 8 - padding), view.bounds.width - size.width + padding - 8)
        formatHost.frame = NSRect(origin: origin, size: size)
    }

    private func hideFormatBar() {
        formatBarTask?.cancel()
        formatHost?.removeFromSuperview()
        formatHost = nil
    }

    /// Opens a small popover for adding, changing or removing the link on the selection.
    func editLink() {
        var range = textView.selectedRange()
        var existing = ""
        if let link = textView.link(at: range.location) {
            existing = link.destination
            if range.length == 0 { range = link.range }
        }
        guard range.length > 0 else { return }
        hideFormatBar()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: LinkEditorView(
            destination: existing,
            onCommit: { [weak self, weak popover] destination in
                popover?.close()
                self?.textView.setLink(destination, in: range)
                self?.focusBody()
            },
            onRemove: existing.isEmpty ? nil : { [weak self, weak popover] in
                popover?.close()
                self?.textView.setLink(nil, in: range)
                self?.focusBody()
            }
        ))
        popover.show(relativeTo: textView.rect(forRange: range), of: textView, preferredEdge: .maxY)
        linkPopover = popover
    }

    // MARK: Commands from menus and the sidebar

    func perform(_ command: EditorCommand) {
        switch command {
        case .format(let format): textView.toggle(format)
        case .turnInto(let kind): textView.turnInto(kind)
        case .link: editLink()
        case .divider: textView.insertAttachment(.divider, kind: .rule)
        }
    }

    func commitTableEdit(_ edit: PageSession.TableEdit) {
        textView.updateTable(edit.table, forParagraphAt: edit.location)
        focusBody()
    }
}

/// Things the menu bar can ask the focused editor to do.
enum EditorCommand {
    case format(EditorTextView.InlineFormat)
    case turnInto(BlockKind)
    case link
    case divider
}

/// A menu item that runs a closure, for menus assembled on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is created in code")
    }

    @objc private func run() {
        handler()
    }
}

/// A hosting view for floating controls that must not take keyboard focus away from the text.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
