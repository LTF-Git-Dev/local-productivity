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

    var errorDescription: String? {
        switch self {
        case .nameTaken(let name): return "“\(name)” already exists in this folder."
        case .invalidName: return "That name can’t be used."
        case .missing: return "The item could not be found. It may have been moved or deleted."
        case .outsideWorkspace: return "LP only creates and moves files inside the workspace folder."
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
        let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var visited = 0
        while let file = enumerator?.nextObject() as? URL, visited < 60_000 {
            visited += 1
            let ext = file.pathExtension.lowercased()
            guard !ext.isEmpty, !WorkspaceScanner.pageExtensions.contains(ext) else { continue }
            let key = file.lastPathComponent.lowercased()
            if found[key] == nil { found[key] = file }
        }
        attachmentsByName = found
        return found
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
        try FileManager.default.moveItem(at: source, to: destination)
        let newPath = FileNode.join(FileNode.parent(of: path), fileName)
        pathChanged(from: path, to: newPath)
        return newPath
    }

    @discardableResult
    func move(_ path: String, into folder: String) throws -> String {
        guard let folder = PathSafety.contained(folder), PathSafety.contained(path) != nil else { throw WorkspaceError.outsideWorkspace }
        guard path != folder, !folder.hasPrefix(path + "/"), FileNode.parent(of: path) != folder else { return path }
        let source = url(for: path)
        let directory = url(for: folder)
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let fileName = Self.availableName(name, extension: ext.isEmpty ? nil : ext, in: directory)
        try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent(fileName))
        let newPath = FileNode.join(folder, fileName)
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
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(fileName))
        rebuild()
        return FileNode.join(FileNode.parent(of: path), fileName)
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
    func toggleTask(_ task: TaskItem) {
        let fileURL = url(for: task.path)
        // Only files that are valid UTF-8 are rewritten here; anything else is left for the editor,
        // which knows how to keep a file's encoding.
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return }
        if task.isBoardCard {
            toggleCard(task, in: text, at: fileURL)
            return
        }
        var document = MarkdownParser.parse(text)
        var seen = 0
        for index in document.blocks.indices {
            guard case .todo(let status, let marker) = document.blocks[index].kind else { continue }
            // Mirrors the index, which does not count tasks without any text.
            if document.blocks[index].plainText.trimmingWhitespace.isEmpty { continue }
            if seen == task.ordinal {
                document.blocks[index].kind = .todo(status: status == " " ? "x" : " ", marker: marker)
                try? SafeFileWriter.write(Data(MarkdownSerializer.serialize(document).utf8), to: fileURL)
                break
            }
            seen += 1
        }
        if let position = meta[task.path]?.tasks.firstIndex(where: { $0.ordinal == task.ordinal }) {
            meta[task.path]?.tasks[position].isDone.toggle()
        }
    }

    /// Ticks a board card off, or reopens it. A card reopened from a list whose cards count as
    /// done moves back to the first list that does not.
    private func toggleCard(_ task: TaskItem, in text: String, at fileURL: URL) {
        var board = BoardParser.parse(text)
        var located: (lane: Int, card: Int)?
        var ordinal = 0
        search: for laneIndex in board.lanes.indices {
            for cardIndex in board.lanes[laneIndex].cards.indices {
                let card = board.lanes[laneIndex].cards[cardIndex]
                let matches = task.cardID.map { card.hasStoredID && card.id == $0 } ?? (ordinal == task.ordinal)
                if matches {
                    located = (laneIndex, cardIndex)
                    break search
                }
                ordinal += 1
            }
        }
        guard let (laneIndex, cardIndex) = located else { return }
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
        try? SafeFileWriter.write(Data(BoardParser.serialize(board).utf8), to: fileURL)
        if let position = meta[task.path]?.tasks.firstIndex(where: { $0.ordinal == task.ordinal }) {
            meta[task.path]?.tasks[position].isDone.toggle()
        }
    }

    // MARK: Boards

    /// Whether the file at `path` is a board. Read from the file itself, which is quick and
    /// always current, rather than from the index.
    func isBoard(_ path: String) -> Bool {
        guard path.lowercased().hasSuffix(".md"),
              let handle = try? FileHandle(forReadingFrom: url(for: path)) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return BoardParser.isBoard(String(decoding: head, as: UTF8.self))
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
    static func sanitized(_ title: String) -> String? {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 { name = String(name.prefix(200)) }
        return name.isEmpty ? nil : name
    }

    /// "Untitled", then "Untitled 2", "Untitled 3"… whichever is free in `directory`.
    static func availableName(_ base: String, extension ext: String?, in directory: URL) -> String {
        func fileName(_ stem: String) -> String { ext.map { "\(stem).\($0)" } ?? stem }
        var candidate = fileName(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = fileName("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }
}
