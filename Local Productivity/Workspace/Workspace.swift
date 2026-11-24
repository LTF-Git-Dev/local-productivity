//
//  Workspace.swift
//  Local Productivity
//
//  One open workspace: a folder on disk, the tree of pages inside it, and everything
//  the app remembers about it (which folders are open, favourites, recent pages).
//  All changes to files go through here so the tree, the index and the saved state
//  stay consistent.
//

import AppKit
import Foundation

enum WorkspaceError: LocalizedError {
    case nameTaken(String)
    case invalidName
    case missing
    case outsideWorkspace
    case boardIdentity(String)
    case unreadableBeforeMove(String)
    case folderUnreadableBeforeMove(String)
    case unsavedBeforeMove(String)
    case historyUnwritableBeforeMove(String)
    case changedBeforeMove(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let name): return "“\(name)” already exists in this folder."
        case .invalidName: return "That name can’t be used."
        case .missing: return "The item could not be found. It may have been moved or deleted."
        case .outsideWorkspace: return "LP only creates and moves files inside the workspace folder."
        case .boardIdentity(let name): return "LP couldn’t record which board “\(name)” is in its file before moving it, so nothing was moved."
        case .unreadableBeforeMove(let name): return "LP can’t read “\(name)” as text, so it couldn’t check it before moving it. Nothing was moved."
        case .folderUnreadableBeforeMove(let name): return "LP can’t look inside “\(name)”, so it couldn’t check the boards in it before moving it. Nothing was moved."
        case .unsavedBeforeMove(let name): return "LP couldn’t save the open page in “\(name)” before moving it, so nothing was moved."
        case .historyUnwritableBeforeMove(let name): return "LP can’t update the history of “\(name)” in the workspace’s hidden .lp folder, so nothing was moved."
        case .changedBeforeMove(let name): return "“\(name)” changed in another app while LP was getting it ready to move, so nothing was moved. Try again."
        }
    }
}

@Observable
final class Workspace {

    let record: WorkspaceRecord
    let rootURL: URL

    private(set) var root: FileNode
    /// Every page in the workspace, in sidebar order.
    private(set) var pages: [FileNode] = []
    private(set) var meta: [String: PageMeta] = [:] {
        didSet { onMetaChanged?() }
    }
    private(set) var hasLoaded = false
    /// Every page has been read once, so `meta` is complete.
    private(set) var hasIndexed = false

    var expanded: Set<String> = [] {
        didSet { if expanded != oldValue { persist() } }
    }
    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []

    /// Pages (workspace-relative paths) whose files changed on disk.
    @ObservationIgnored var onPagesChangedOnDisk: (([String]) -> Void)?
    /// A page or folder was renamed or moved from the first path to the second.
    @ObservationIgnored var onPathChanged: ((String, String) -> Void)?
    /// The tree was rebuilt; routes pointing at missing items should be dropped.
    @ObservationIgnored var onTreeChanged: (() -> Void)?
    /// What is known about the pages changed: their tasks, dates or titles.
    @ObservationIgnored var onMetaChanged: (() -> Void)?
    /// LP kept a copy of something it couldn't save where it belonged; tells the person where.
    @ObservationIgnored var onKeptCopy: ((AlertMessage) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let index = WorkspaceIndex()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var pagesByName: [String: [String]] = [:]
    @ObservationIgnored private var attachmentsByName: [String: URL]?

    var name: String { rootURL.lastPathComponent }

    init(record: WorkspaceRecord, rootURL: URL, defaults: UserDefaults?) {
        self.record = record
        self.rootURL = rootURL
        self.defaults = defaults
        root = FileNode(path: "", name: rootURL.lastPathComponent, isFolder: true, modified: Date())
        restore()
        authorizedShares = Set(defaults?.stringArray(forKey: sharesKey) ?? [])
    }

    // MARK: Lifecycle

    func start() {
        let watcher = FileWatcher(url: rootURL) { [weak self] paths in
            Task { @MainActor [weak self] in self?.handleFileEvents(paths) }
        }
        watcher.start()
        self.watcher = watcher
        Task { await refresh() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
        indexTask?.cancel()
    }

    /// Rescans the folder in the background.
    func refresh() async {
        let rootURL = rootURL
        let scanned = await Task.detached(priority: .userInitiated) { WorkspaceScanner.scan(rootURL) }.value
        apply(scanned)
    }

    /// Rescans immediately, for changes the app itself just made.
    private func rebuild() {
        apply(WorkspaceScanner.scan(rootURL))
    }

    private func apply(_ scanned: FileNode) {
        if scanned != root { root = scanned }
        let flattened = scanned.pages
        if flattened != pages { pages = flattened }
        var byName: [String: [String]] = [:]
        for page in flattened { byName[page.name.lowercased(), default: []].append(page.path) }
        pagesByName = byName
        attachmentsByName = nil
        hasLoaded = true
        onTreeChanged?()

        indexTask?.cancel()
        indexTask = Task { [index, rootURL] in
            let updated = await index.update(root: rootURL, pages: flattened)
            guard !Task.isCancelled else { return }
            if updated != self.meta { self.meta = updated }
            if !self.hasIndexed {
                self.hasIndexed = true
                self.onMetaChanged?()
            }
        }
    }

    private func handleFileEvents(_ paths: [String]) {
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var changedPages: [String] = []
        var relevant = false
        for path in paths {
            // FSEvents reports the real path, which can differ from the bookmark's (/private/var vs /var).
            let relative: String
            if path.hasPrefix(prefix) {
                relative = String(path.dropFirst(prefix.count))
            } else if let range = path.range(of: prefix) {
                relative = String(path[range.upperBound...])
            } else {
                relevant = true
                continue
            }
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            relevant = true
            if WorkspaceScanner.pageExtensions.contains((relative as NSString).pathExtension.lowercased()) {
                changedPages.append(relative)
            }
        }
        guard relevant else { return }
        if !changedPages.isEmpty { onPagesChangedOnDisk?(changedPages) }

        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    // MARK: Lookup

    func url(for path: String) -> URL {
        path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
    }

    func node(at path: String) -> FileNode? {
        root.node(at: path)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    func title(of path: String) -> String {
        FileNode.title(of: path)
    }

    func icon(of path: String) -> String? {
        meta[path]?.icon
    }

    /// Resolves a `[[wiki link]]` target to a page, the way Obsidian does: an exact path first,
    /// then any page with that name.
    func resolveLink(_ target: String, from source: String? = nil) -> String? {
        var name = target
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return source }

        for candidate in [name, name + ".md"] where node(at: candidate)?.isFolder == false { return candidate }
        if let source {
            let sibling = FileNode.join(FileNode.parent(of: source), name + ".md")
            if node(at: sibling) != nil { return sibling }
        }
        let leaf = FileNode.title(of: FileNode.fileName(of: name)).lowercased()
        guard let matches = pagesByName[leaf], !matches.isEmpty else { return nil }
        if name.contains("/") {
            let wanted = (name.hasSuffix(".md") ? name : name + ".md").lowercased()
            if let exact = matches.first(where: { $0.lowercased().hasSuffix(wanted) }) { return exact }
        }
        return matches.min { $0.count < $1.count }
    }

    /// Finds the file an image or attachment reference points at: relative to the page, then to
    /// the workspace root, then — as Obsidian does — anywhere in the workspace by file name.
    func resolveAttachment(_ reference: String, from pagePath: String) -> URL? {
        var reference = reference.trimmingCharacters(in: .whitespaces)
        if reference.hasPrefix("http://") || reference.hasPrefix("https://") { return URL(string: reference) }
        if let hash = reference.firstIndex(of: "#") { reference = String(reference[..<hash]) }
        if let decoded = reference.removingPercentEncoding { reference = decoded }
        guard !reference.isEmpty else { return nil }

        // Only files inside the workspace are used, so a note cannot point LP at files elsewhere.
        if reference.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: reference)
            return PathSafety.isInside(absolute, root: rootURL) && FileManager.default.fileExists(atPath: reference) ? absolute : nil
        }
        let nearby = [url(for: FileNode.parent(of: pagePath)), rootURL].map { $0.appendingPathComponent(reference) }
        for candidate in nearby where FileManager.default.fileExists(atPath: candidate.path) && PathSafety.isInside(candidate, root: rootURL) {
            return candidate.standardizedFileURL
        }
        return attachments()[(reference as NSString).lastPathComponent.lowercased()]
    }

    /// The folder pasted and dropped files are stored in: an existing attachments-style folder at
    /// the top of the workspace if there is one, otherwise a new "attachments" folder.
    private var attachmentsFolder: URL {
        for name in ["attachments", "Attachments", "assets", "Assets", "images", "Images"] {
            var isDirectory: ObjCBool = false
            let candidate = rootURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return rootURL.appendingPathComponent("attachments")
    }

    /// Saves pasted data as a file in the attachments folder.
    func storeAttachment(_ data: Data, name: String, fileExtension: String) throws -> URL {
        let folder = attachmentsFolder
        guard PathSafety.resolvesInside(folder, root: rootURL) else { throw WorkspaceError.outsideWorkspace }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = Self.availableName(Self.sanitized(name) ?? "attachment", extension: fileExtension, in: folder)
        let destination = folder.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        attachmentsByName = nil
        return destination
    }

    /// Makes a dropped file part of the workspace. Files already inside it are left where they are.
    func adoptAttachment(at source: URL) throws -> URL {
        let standardized = source.standardizedFileURL
        if standardized.path.hasPrefix(rootURL.standardizedFileURL.path + "/") { return standardized }
        let folder = attachmentsFolder
        guard PathSafety.resolvesInside(folder, root: rootURL) else { throw WorkspaceError.outsideWorkspace }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = standardized.pathExtension
        let fileName = Self.availableName(standardized.deletingPathExtension().lastPathComponent,
                                          extension: ext.isEmpty ? nil : ext, in: folder)
        let destination = folder.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: standardized, to: destination)
        attachmentsByName = nil
        return destination
    }

    /// The path to write in a page at `pagePath` so that it points at `file`.
    func reference(to file: URL, from pagePath: String) -> String {
        let target = file.standardizedFileURL.pathComponents
        let base = url(for: FileNode.parent(of: pagePath)).standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(target.count, base.count), target[shared] == base[shared] { shared += 1 }
        let up = Array(repeating: "..", count: base.count - shared)
        return (up + target[shared...]).joined(separator: "/")
    }

    /// Every non-Markdown file in the workspace by lower-cased name, built on first use after each scan.
    private func attachments() -> [String: URL] {
        if let attachmentsByName { return attachmentsByName }
        var found: [String: URL] = [:]
        let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var visited = 0
        while let file = enumerator?.nextObject() as? URL, visited < 60_000 {
            visited += 1
            let ext = file.pathExtension.lowercased()
            guard !ext.isEmpty, !WorkspaceScanner.pageExtensions.contains(ext) else { continue }
            // A link to a file elsewhere doesn't make that file part of the workspace.
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
               !PathSafety.isInside(file, root: rootURL) { continue }
            let key = file.lastPathComponent.lowercased()
            if found[key] == nil { found[key] = file }
        }
        attachmentsByName = found
        return found
    }

    /// Keeps `text` in LP's Recovered folder (see `RecoveredCopies`) and tells the person.
    /// Returns false when the copy couldn't be written; the caller must then not drop the text.
    func keepCopy(_ text: String, name: String, note: String, alertTitle: String, message: String) -> Bool {
        guard let copy = RecoveredCopies.keep(text, name: name, note: note) else { return false }
        onKeptCopy?(AlertMessage(title: alertTitle, message: message, file: copy))
        return true
    }

    /// The daily note for `day`, if one exists anywhere in the workspace.
    func dailyNote(for day: Day) -> String? {
        pagesByName[day.iso]?.min { $0.count < $1.count }
    }

    // MARK: Creating

    @discardableResult
    func createPage(in folder: String = "", title: String? = nil, contents: String = "") throws -> String {
        guard let folder = PathSafety.contained(folder) else { throw WorkspaceError.outsideWorkspace }
        let directory = url(for: folder)
        // A folder that is a link to somewhere else would carry the new page out of the workspace.
        guard PathSafety.resolvesInside(directory, root: rootURL) else { throw WorkspaceError.outsideWorkspace }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.sanitized(title ?? "Untitled") ?? "Untitled"
        let fileName = Self.availableName(base, extension: "md", in: directory)
        try Data(contents.utf8).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        expand(to: FileNode.join(folder, fileName))
        rebuild()
        return FileNode.join(folder, fileName)
    }

    @discardableResult
    func createFolder(in folder: String = "", name: String = "New Folder") throws -> String {
        guard let folder = PathSafety.contained(folder) else { throw WorkspaceError.outsideWorkspace }
        let directory = url(for: folder)
        guard PathSafety.resolvesInside(directory, root: rootURL) else { throw WorkspaceError.outsideWorkspace }
        let folderName = Self.availableName(Self.sanitized(name) ?? "New Folder", extension: nil, in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(folderName), withIntermediateDirectories: true)
        let path = FileNode.join(folder, folderName)
        expand(to: path)
        rebuild()
        return path
    }

    /// Opens today's (or any day's) note, creating it in `folder` when it does not exist yet.
    @discardableResult
    func openDailyNote(for day: Day, folder: String) throws -> String {
        if let existing = dailyNote(for: day) { return existing }
        return try createPage(in: folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), title: day.iso)
    }

    // MARK: Renaming, moving, deleting

    @discardableResult
    func rename(_ path: String, to newTitle: String) throws -> String {
        let source = url(for: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            throw WorkspaceError.missing
        }
        guard let clean = Self.sanitized(newTitle) else { throw WorkspaceError.invalidName }
        let fileName = isFolder.boolValue ? clean : clean + "." + source.pathExtension
        guard fileName != source.lastPathComponent else { return path }

        let destination = source.deletingLastPathComponent().appendingPathComponent(fileName)
        let isCaseChangeOnly = destination.path.lowercased() == source.path.lowercased()
        if FileManager.default.fileExists(atPath: destination.path), !isCaseChangeOnly {
            throw WorkspaceError.nameTaken(clean)
        }
        let newPath = FileNode.join(FileNode.parent(of: path), fileName)
        try moveWithBoards(path, to: newPath) { try FileManager.default.moveItem(at: source, to: destination) }
        pathChanged(from: path, to: newPath)
        return newPath
    }

    @discardableResult
    func move(_ path: String, into folder: String) throws -> String {
        guard let folder = PathSafety.contained(folder), PathSafety.contained(path) != nil else { throw WorkspaceError.outsideWorkspace }
        guard path != folder, !folder.hasPrefix(path + "/"), FileNode.parent(of: path) != folder else { return path }
        let source = url(for: path)
        let directory = url(for: folder)
        guard PathSafety.resolvesInside(directory, root: rootURL) else { throw WorkspaceError.outsideWorkspace }
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let fileName = Self.availableName(name, extension: ext.isEmpty ? nil : ext, in: directory)
        let newPath = FileNode.join(folder, fileName)
        try moveWithBoards(path, to: newPath) { try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent(fileName)) }
        expanded.insert(folder)
        pathChanged(from: path, to: newPath)
        return newPath
    }

    @discardableResult
    func duplicate(_ path: String) throws -> String {
        let source = url(for: path)
        let directory = source.deletingLastPathComponent()
        let ext = source.pathExtension
        let fileName = Self.availableName(source.deletingPathExtension().lastPathComponent + " copy",
                                          extension: ext.isEmpty ? nil : ext, in: directory)
        let copy = directory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: copy)
        do {
            try Self.giveBoardsNewIdentities(at: copy)
        } catch {
            // A copy that would still act as the original board isn't kept.
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
        rebuild()
        return FileNode.join(FileNode.parent(of: path), fileName)
    }

    /// A board's `lp-board` identity names its history and its shared page. Every board in a copy
    /// — a copied board, or the boards in a copied folder — gets a new random one, so it starts its
    /// own history and never publishes to another board's page (nor picks up history left at the
    /// same path by an earlier copy). Throws when a board's identity couldn't be replaced.
    private static func giveBoardsNewIdentities(at url: URL) throws {
        var files = [url]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            // Files only: a folder can be called "Research.md" too.
            files = (enumerator?.allObjects as? [URL] ?? []).filter { file in
                WorkspaceScanner.pageExtensions.contains(file.pathExtension.lowercased())
                    && (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
        }
        for file in files {
            let data = try Data(contentsOf: file)
            guard BoardParser.isBoard(head: data) else { continue }
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            var board = BoardParser.parse(text)
            let id = BoardIDs.newBoardID()
            board.frontMatter = BoardParser.frontMatter(board.frontMatter, setting: "lp-board", to: id)
            let written = BoardParser.serialize(board)
            guard board.boardID == id, BoardParser.isBoard(written) else { throw CocoaError(.fileWriteUnknown) }
            try SafeFileWriter.write(Data(written.utf8), to: file)
        }
    }

    /// Moves a page or folder to the Trash.
    func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: nil)
        favorites.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        recents.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        persist()
        rebuild()
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: path)])
    }

    private func pathChanged(from old: String, to new: String) {
        rebaseShares(from: old, to: new)
        favorites = favorites.map { FileNode.rebased($0, from: old, to: new) ?? $0 }
        recents = recents.map { FileNode.rebased($0, from: old, to: new) ?? $0 }
        expanded = Set(expanded.map { FileNode.rebased($0, from: old, to: new) ?? $0 })
        var moved = meta
        for (key, value) in meta {
            guard let rebased = FileNode.rebased(key, from: old, to: new) else { continue }
            moved.removeValue(forKey: key)
            var updated = value
            updated.path = rebased
            updated.title = FileNode.title(of: rebased)
            moved[rebased] = updated
        }
        meta = moved
        persist()
        // Tell the app first, so nothing still points at the old path when the tree is rebuilt.
        onPathChanged?(old, new)
        rebuild()
    }

    // MARK: Favourites and recents

    func isFavorite(_ path: String) -> Bool {
        favorites.contains(path)
    }

    func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) {
            favorites.remove(at: index)
        } else {
            favorites.append(path)
        }
        persist()
    }

    func noteOpened(_ path: String) {
        guard recents.first != path else { return }
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 40 { recents.removeLast(recents.count - 40) }
        persist()
    }

    /// Updates the cached icon right away; the file itself is written by the editor.
    func noteIconChanged(_ icon: String?, for path: String) {
        meta[path]?.icon = icon
    }

    func expand(to path: String) {
        let ancestors = FileNode.ancestors(of: path)
        if !ancestors.allSatisfy(expanded.contains) { expanded.formUnion(ancestors) }
    }

    func toggleExpanded(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    // MARK: Search

    func search(_ query: String) async -> [SearchHit] {
        await index.search(query)
    }

    // MARK: Tasks

    /// Flips a task's checkbox directly in its file. Used where tasks are listed outside the editor.
    /// Throws when the file can't be written; then nothing changes, there or in what LP lists.
    func toggleTask(_ task: TaskItem) throws {
        let fileURL = url(for: task.path)
        // Only files that are valid UTF-8 are rewritten here; anything else is left for the editor,
        // which knows how to keep a file's encoding.
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return }
        // Still what the task was listed from — another app can turn a board into a page or the
        // other way round before the index catches up — and, for a card, still the same board.
        guard BoardParser.isBoard(head: data) == task.isBoardCard else { return }
        if task.isBoardCard {
            // The board the task was listed from — one listed without an ID only while the file
            // still has none.
            let current = BoardParser.parse(text).boardID.flatMap { BoardIDSafety.isValid($0) ? $0 : nil }
            guard current == task.boardID else { return }
            try toggleCard(task, in: text, at: fileURL)
            return
        }
        var document = MarkdownParser.parse(text)
        // Found the way the index counted it, and checked by its wording, so a page edited since
        // it was read can't make LP tick a different box.
        guard let index = PageTasks.block(ofTask: task.ordinal, text: task.text, due: task.due, time: task.dueTime,
                                          isDone: task.isDone, in: document),
              case .todo(let status, let marker) = document.blocks[index].kind else { return }
        document.blocks[index].kind = .todo(status: status == " " ? "x" : " ", marker: marker)
        try SafeFileWriter.write(Data(MarkdownSerializer.serialize(document).utf8), to: fileURL)
        if let position = meta[task.path]?.tasks.firstIndex(where: { $0.ordinal == task.ordinal }) {
            meta[task.path]?.tasks[position].isDone.toggle()
        }
    }

    /// Ticks a board card off, or reopens it. A card reopened from a list whose cards count as
    /// done moves back to the first list that does not.
    private func toggleCard(_ task: TaskItem, in text: String, at fileURL: URL) throws {
        var board = BoardParser.parse(text)
        // Every card in order, as the index counted them.
        var places: [(lane: Int, card: Int)] = []
        var items: [(text: String, due: Day?, time: TimeOfDay?, isDone: Bool)] = []
        for laneIndex in board.lanes.indices {
            for cardIndex in board.lanes[laneIndex].cards.indices {
                let card = board.lanes[laneIndex].cards[cardIndex]
                places.append((laneIndex, cardIndex))
                items.append((card.title.isEmpty ? "Untitled card" : card.title, card.due, CardText.dueTime(in: card.text),
                              card.isDone || board.lanes[laneIndex].marksComplete))
            }
        }
        // A card is found by its ID; one without an ID the way page tasks are (`PageTasks.locate`),
        // so a card ticked off elsewhere isn't reopened and look-alike cards aren't confused.
        let found: Int?
        if let id = task.cardID {
            found = places.indices.first { index in
                let card = board.lanes[places[index].lane].cards[places[index].card]
                return card.hasStoredID && card.id == id
            }.flatMap { items[$0].isDone == task.isDone ? $0 : nil }
        } else {
            found = PageTasks.locate(task.ordinal, among: items, text: task.text, due: task.due, time: task.dueTime, isDone: task.isDone)
        }
        guard let found else { return }
        let (laneIndex, cardIndex) = places[found]
        let lane = board.lanes[laneIndex]
        if lane.cards[cardIndex].isDone || lane.marksComplete {
            board.lanes[laneIndex].cards[cardIndex].isDone = false
            if lane.marksComplete, let open = board.lanes.firstIndex(where: { !$0.marksComplete }) {
                let card = board.lanes[laneIndex].cards.remove(at: cardIndex)
                board.lanes[open].cards.append(card)
            }
        } else {
            board.lanes[laneIndex].cards[cardIndex].isDone = true
        }
        try SafeFileWriter.write(Data(BoardParser.serialize(board).utf8), to: fileURL)
        if let position = meta[task.path]?.tasks.firstIndex(where: { $0.ordinal == task.ordinal }) {
            meta[task.path]?.tasks[position].isDone.toggle()
        }
    }

    // MARK: Boards

    /// Whether the file at `path` is a board. Read from the file itself, which is quick and
    /// always current, rather than from the index.
    func isBoard(_ path: String) -> Bool {
        // The same files the scanner and the index take as pages (`.md` and `.markdown`).
        guard WorkspaceScanner.pageExtensions.contains((path as NSString).pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url(for: path)) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: BoardParser.boardMarkerWindow)) ?? Data()
        return BoardParser.isBoard(head: head)
    }

    func createBoard(in folder: String = "", title: String = "Untitled Board", template: BoardTemplate = .simple) throws -> String {
        try createPage(in: folder, title: title, contents: template.markdown())
    }

    /// Every folder, for choosing where something new goes; the root is "".
    var folderPaths: [String] {
        var paths = [""]
        func walk(_ node: FileNode) {
            for child in node.children where child.isFolder {
                paths.append(child.path)
                walk(child)
            }
        }
        walk(root)
        return paths
    }

    // MARK: Saved state

    private struct SavedState: Codable {
        var expanded: [String] = []
        var favorites: [String] = []
        var recents: [String] = []
    }

    private var stateKey: String { "workspace.state.\(record.id.uuidString)" }

    // MARK: Sharing

    /// The shared pages this Mac may update or delete: ones LP published here, or that the person
    /// allowed — each bound to the board's file, its board ID and its gist. The record of a share
    /// in a board's history lives in the folder, which whoever handed it over could have written,
    /// and a copy of the board made outside LP carries it along, so that record is not enough.
    private(set) var authorizedShares: Set<String> = []

    private var sharesKey: String { "workspace.shares.\(record.id.uuidString)" }

    private static func shareKey(path: String, board: String, page: String) -> String {
        ShareGrantKey.make(path: path, board: board, page: page)
    }

    func isShareAuthorized(path: String, board: String, page: String) -> Bool {
        authorizedShares.contains(Self.shareKey(path: path, board: board, page: page))
    }

    func authorizeShare(path: String, board: String, page: String) {
        authorizedShares.insert(Self.shareKey(path: path, board: board, page: page))
        defaults?.set(authorizedShares.sorted(), forKey: sharesKey)
    }

    /// Whether this Mac may update a shared page for board `id`, from any file. Sharing writes a
    /// board's ID into its file first, so a file without that ID is never that board.
    func hasShareGrant(board id: String) -> Bool {
        authorizedShares.contains { ShareGrantKey.parts(of: $0)?.board == id }
    }

    func revokeShare(path: String, board: String, page: String) {
        authorizedShares.remove(Self.shareKey(path: path, board: board, page: page))
        defaults?.set(authorizedShares.sorted(), forKey: sharesKey)
    }

    /// Another board file with the board ID `id` that was created before the one at `path`. Dates
    /// come from the files; before the first index is ready (a board reopened at launch) every
    /// page is looked at, so the answer doesn't depend on what has been indexed.
    func olderBoard(withID id: String, than path: String) -> String? {
        otherBoard(withID: id, than: path, olderOnly: true)
    }

    /// Another board file with the board ID `id` — with `olderOnly`, one created before the one at
    /// `path`.
    func otherBoard(withID id: String, than path: String, olderOnly: Bool = false) -> String? {
        func created(_ page: String) -> Date {
            (try? url(for: page).resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
        }
        let mine = olderOnly ? created(path) : .distantFuture
        let candidates = hasIndexed ? meta.values.filter(\.isBoard).map(\.path) : pages.map(\.path)
        return candidates.first { other in
            !isSameFile(other, path) && (!olderOnly || created(other) < mine) && boardID(at: other) == id
        }
    }

    /// Whether two workspace paths name the same file — on a case-insensitive volume
    /// "Launch.md" and "launch.md" do, as do two hard links. Compared by the file's identity.
    func isSameFile(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        func identity(_ path: String) -> (Int, Int)? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: path).path),
                  let file = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
                  let volume = (attributes[.systemNumber] as? NSNumber)?.intValue else { return nil }
            return (volume, file)
        }
        guard let first = identity(a), let second = identity(b) else { return false }
        return first == second
    }

    /// The board ID stored in the board file at `path`, if it is a board that has one.
    func boardID(at path: String) -> String? {
        let fileURL = url(for: path)
        // A quick look at the top first: most pages aren't boards.
        guard let head = Self.head(of: fileURL), BoardParser.isBoard(head: head),
              let text = BoardStore.readText(at: fileURL), BoardParser.isBoard(text) else { return nil }
        return BoardParser.parse(text).boardID.flatMap { BoardIDSafety.isValid($0) ? $0 : nil }
    }


    /// Before LP moves boards, the ID each one's history goes by is written into its file when it
    /// isn't there yet — a board known only by its path, or a copy made outside LP — so moving it
    /// doesn't change which board it is (its history and sharing permission go by that ID).
    /// Throws when it can't be written; then nothing is moved.
    /// Asked before LP renames or moves `path` (a file, or a folder and all in it): the open page
    /// there saves its edits first, so an edit waiting to be saved can't undo the board ID written
    /// next. False stops the move. (After it, the page reads its file again — `pathChanged`.)
    var onWillMove: ((String) -> Bool)?

    #if DEBUG
    /// Runs between a move's checks and its writes (the harness's `move-race:` step).
    static var betweenMoveChecksAndWrites: (() -> Void)?
    #endif

    /// A board's history that moves with it: the board file's path now, and after the move.
    private struct HistoryMove {
        let id: String
        let name: String
        let source: String
        let destination: String
    }

    /// Moves `path` to `newPath` with `move`, taking the boards in it along: the open page there
    /// saves first; each board gets its ID in its file; and each board's history is told its new
    /// place *before* the move — a history that can't be told stops the move instead of being left
    /// behind, where a copy later put at the old path could take it over. If the move fails, each
    /// history records its board where it still is — with its ID in its file, as it now has.
    private func moveWithBoards(_ path: String, to newPath: String, _ move: () throws -> Void) throws {
        guard onWillMove?(path) ?? true else { throw WorkspaceError.unsavedBeforeMove(FileNode.title(of: path)) }
        let histories = try persistBoardIdentities(at: path, movingTo: newPath)
        // If the move doesn't happen, every one of them records its board where it still is — with its
        // ID in its file, as it now has — including any not told yet.
        func putBack() {
            for history in histories {
                _ = BoardStore.setHistoryOwner(id: history.id, root: rootURL, path: history.source, fileHasID: true)
            }
        }
        for history in histories {
            guard BoardStore.setHistoryOwner(id: history.id, root: rootURL, path: history.destination, fileHasID: true) else {
                putBack()
                throw WorkspaceError.historyUnwritableBeforeMove(history.name)
            }
        }
        do {
            try move()
        } catch {
            putBack()
            throw error
        }
    }

    /// Before a move: every board at or under `path` gets its ID written into its file if it isn't
    /// there yet, and the histories that must move with them are returned. Everything is checked
    /// before anything is written, so a board that stops the move does so with nothing changed;
    /// if writing an ID then fails, the boards already given theirs have their histories say so.
    /// Throws, with nothing moved, when a board or its history can't be checked or written.
    private func persistBoardIdentities(at path: String, movingTo newPath: String) throws -> [HistoryMove] {
        struct Checked { let path: String; let name: String; let url: URL; let original: String; let id: String; let updated: String?; let hasHistory: Bool }
        var boards: [Checked] = []
        // 1. Check. The files as they are now, not the index (which may be behind, or not ready yet).
        for boardPath in try pageFiles(at: path) {
            let fileURL = url(for: boardPath)
            let name = FileNode.title(of: boardPath)
            // A quick look at its top: only a file that names the Kanban plugin can be a board. One
            // that can't be opened stops the move unless it is known not to be a board.
            guard let head = Self.head(of: fileURL) else {
                if meta[boardPath]?.isBoard ?? true { throw WorkspaceError.unreadableBeforeMove(name) }
                continue
            }
            guard BoardParser.isBoard(head: head) else { continue }
            // Read in full. One that can't be read as UTF-8 text stops the move, rather than being
            // skipped (losing its identity) or written back damaged.
            guard let text = BoardStore.readText(at: fileURL) else { throw WorkspaceError.unreadableBeforeMove(name) }
            // No longer a board: an ordinary note is never rewritten as one.
            guard BoardParser.isBoard(text) else { continue }
            let stored = BoardParser.parse(text).boardID.flatMap { BoardIDSafety.isValid($0) ? $0 : nil }
            let id = BoardStore.historyID(for: boardPath, storedID: stored, in: self)
            // The history it goes by (whatever spelling of this file it recorded) moves with it, so
            // one that exists must be one LP can read and update: inside the workspace, and writable.
            let history = BoardStore.logURL(id: id, root: rootURL)
            let hasHistory = FileManager.default.fileExists(atPath: history.path)
            if hasHistory {
                guard BoardStore.historyOwner(id: id, root: rootURL) != nil,
                      PathSafety.resolvesInside(history, root: rootURL),
                      FileManager.default.isWritableFile(atPath: history.path),
                      FileManager.default.isWritableFile(atPath: history.deletingLastPathComponent().path) else {
                    throw WorkspaceError.historyUnwritableBeforeMove(name)
                }
            }
            // Its ID, if it isn't in its file yet: only the front matter changes, the rest of the file
            // stays exactly as it is — and only if the file will read back with that ID, as a board.
            var updated: String?
            if id != stored {
                guard let text = BoardParser.settingFrontMatter("lp-board", to: id, in: text),
                      BoardParser.parse(text).boardID == id, BoardParser.isBoard(text) else {
                    throw WorkspaceError.boardIdentity(name)
                }
                updated = text
            }
            boards.append(Checked(path: boardPath, name: name, url: fileURL, original: text, id: id, updated: updated, hasHistory: hasHistory))
        }
        #if DEBUG
        // The harness's `move-race:` step changes a file here, as another app could.
        Self.betweenMoveChecksAndWrites?()
        #endif
        // 2. Write the IDs. One that can't be written stops the move; those already written stay (they
        //    are the boards' own IDs), and their histories are told so.
        var written: [Checked] = []
        func tellWritten() {
            for done in written where done.hasHistory {
                _ = BoardStore.setHistoryOwner(id: done.id, root: rootURL, path: done.path, fileHasID: true)
            }
        }
        for board in boards {
            guard let updated = board.updated else { continue }
            // Only over the file as it was checked: one changed since (in Obsidian, by sync) isn't
            // written over — the move stops, and can simply be tried again.
            guard BoardStore.readText(at: board.url) == board.original else {
                tellWritten()
                throw WorkspaceError.changedBeforeMove(board.name)
            }
            do {
                try SafeFileWriter.write(Data(updated.utf8), to: board.url)
            } catch {
                tellWritten()
                throw WorkspaceError.boardIdentity(board.name)
            }
            written.append(board)
        }
        return boards.filter(\.hasHistory).map { board in
            HistoryMove(id: board.id, name: board.name, source: board.path,
                        destination: newPath + String(board.path.dropFirst(path.count)))
        }
    }

    /// The Markdown files at `path` — the file itself, or every one in the folder. Throws when a
    /// folder in it can't be read, since what is in there can't be checked.
    private func pageFiles(at path: String) throws -> [String] {
        let base = url(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [path] }
        var unreadable: URL?
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in unreadable = url; return false }) else {
            throw WorkspaceError.folderUnreadableBeforeMove(FileNode.title(of: path))
        }
        let files = enumerator.allObjects as? [URL] ?? []
        if let unreadable {
            throw WorkspaceError.folderUnreadableBeforeMove(unreadable.lastPathComponent)
        }
        let prefix = base.standardizedFileURL.path + "/"
        return files.compactMap { file in
            guard WorkspaceScanner.pageExtensions.contains(file.pathExtension.lowercased()),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            let full = file.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { return nil }
            return FileNode.join(path, String(full.dropFirst(prefix.count)))
        }
    }

    /// The bytes `BoardParser.isBoard(head:)` looks at, or nil when the file can't be opened.
    private static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: BoardParser.boardMarkerWindow)) ?? Data()
    }

    /// Permissions follow boards that LP renames or moves, open or not.
    private func rebaseShares(from old: String, to new: String) {
        let rebased = Set(authorizedShares.map { key -> String in
            guard let parts = ShareGrantKey.parts(of: key), let path = FileNode.rebased(parts.path, from: old, to: new) else { return key }
            return Self.shareKey(path: path, board: parts.board, page: parts.page)
        })
        guard rebased != authorizedShares else { return }
        authorizedShares = rebased
        defaults?.set(authorizedShares.sorted(), forKey: sharesKey)
    }

    private func restore() {
        guard let data = defaults?.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        expanded = Set(state.expanded)
        favorites = state.favorites
        recents = state.recents
    }

    private func persist() {
        guard let defaults else { return }
        let state = SavedState(expanded: expanded.sorted(), favorites: favorites, recents: recents)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }

    // MARK: Names

    /// Makes a title safe to use as a file name. Returns nil when nothing usable is left.
    static func sanitized(_ title: String) -> String? { PageNaming.sanitized(title) }

    static func availableName(_ base: String, extension ext: String?, in directory: URL) -> String {
        PageNaming.availableName(base, extension: ext, in: directory)
    }
}
