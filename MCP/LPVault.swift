//
//  LPVault.swift
//  lp-mcp
//
//  Everything the MCP server can do with an LP workspace — read, write and update pages, tasks
//  and boards — on the folder itself, with LP's own parser, task and board code, so files stay
//  exactly as LP and Obsidian write them. Rules, the same as the app's:
//  - only `.md`/`.markdown` files inside the workspace, never in hidden folders (`.lp`, `.obsidian`,
//    `.git`), never through a link that leads outside it;
//  - nothing is ever deleted, and a new page never replaces an existing file;
//  - a file that isn't valid UTF-8 is never rewritten; boards are only changed card by card;
//  - every write checks the file didn't change since it was read (LP may be editing it too).
//

import CryptoKit
import Foundation

nonisolated struct VaultError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ description: String) { self.description = description }
}

nonisolated final class LPVault {

    let root: URL
    /// Larger files aren't read: no note is this big, and the answer would flood the conversation.
    static let maxFileSize = 4 * 1024 * 1024
    /// How many pages a scan looks at, so a huge folder (or the wrong one) can't stall the server.
    static let maxPages = 20_000
    /// The files LP shows as pages (the same as `WorkspaceScanner.pageExtensions`).
    static let pageExtensions: Set<String> = ["md", "markdown"]

    init(root: URL) throws {
        var isFolder: ObjCBool = false
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw VaultError("The workspace folder \(root.path) doesn't exist.")
        }
        self.root = resolved
    }

    // MARK: - Paths

    /// A page inside the workspace: a Markdown file, not hidden, not reached through a link
    /// leading outside. `mustExist` asks for a file that is there now.
    func page(_ raw: String, mustExist: Bool = true) throws -> (path: String, url: URL) {
        // Used exactly as given: " Note.md" and "Note.md" are different pages.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let path = PathSafety.contained(raw), !path.isEmpty else {
            throw VaultError("“\(raw)” isn’t a path inside the workspace. Use a path relative to it, like Projects/Plan.md.")
        }
        guard Self.pageExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            throw VaultError("“\(path)” isn’t a page: only .md and .markdown files can be used.")
        }
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw VaultError("“\(path)” is in a hidden folder, which LP doesn’t use for pages.")
        }
        let url = root.appendingPathComponent(path)
        try refuseLinks(path)
        if mustExist {
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw VaultError(type == nil ? "There’s no page at “\(path)”. Use lp_list_pages or lp_search to find it."
                                             : "“\(path)” isn’t a regular file, so it isn’t used.")
            }
            guard PathSafety.isInside(url, root: root) else { throw VaultError("“\(path)” leads outside the workspace.") }
        } else {
            guard PathSafety.resolvesInside(url, root: root) else { throw VaultError("“\(path)” leads outside the workspace.") }
        }
        return (path, url)
    }

    /// A folder inside the workspace ("" is the workspace itself).
    func folder(_ raw: String) throws -> (path: String, url: URL) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        guard let path = PathSafety.contained(trimmed) else { throw VaultError("“\(raw)” isn’t a folder inside the workspace.") }
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw VaultError("“\(path)” is a hidden folder, which LP doesn’t use for pages.")
        }
        let url = path.isEmpty ? root : root.appendingPathComponent(path)
        try refuseLinks(path)
        guard PathSafety.resolvesInside(url, root: root) else { throw VaultError("“\(path)” leads outside the workspace.") }
        return (path, url)
    }

    /// No part of the path may be a link (symbolic link or alias file), even one leading back
    /// inside: a link could name a hidden folder, or be pointed elsewhere later. LP's sidebar
    /// doesn't follow links either.
    func refuseLinks(_ path: String) throws {
        var current = root
        for part in path.split(separator: "/") {
            current.appendPathComponent(String(part))
            guard let type = (try? FileManager.default.attributesOfItem(atPath: current.path))?[.type] as? FileAttributeType else { return }
            if type == .typeSymbolicLink { throw VaultError("“\(path)” goes through a link, which LP’s tools don’t follow.") }
        }
    }

    // MARK: - Reading

    /// A file's text: refused when it's too big or isn't valid UTF-8 (LP leaves those to the editor).
    func readText(at url: URL) throws -> (text: String, data: Data) {
        // Only regular files (a pipe named like a page would block the server), and never more
        // than the limit, even if the file grows while it's read.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: url.path) else { throw VaultError("This page can’t be read.") }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxFileSize + 1) ?? Data()
        guard data.count <= Self.maxFileSize else { throw VaultError("This page is larger than 4 MB, so it isn’t read here.") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VaultError("This file isn’t UTF-8 text, so it isn’t read or changed here.")
        }
        return (text, data)
    }

    /// A short fingerprint of a file's contents: an update must name the one it read.
    static func revision(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    struct PageInfo: Equatable {
        var path: String
        var title: String
        var isBoard: Bool
        var modified: Date
    }

    /// Every page in `folder` and below, by path. Hidden folders, packages and `node_modules`
    /// are skipped, as in LP's sidebar.
    /// Whether the last scan stopped at `maxPages` (results are then incomplete).
    private(set) var lastScanTruncated = false

    func pages(in folderPath: String = "") throws -> [PageInfo] {
        let base = try folder(folderPath)
        lastScanTruncated = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: base.url, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw VaultError("The folder “\(base.path.isEmpty ? "workspace" : base.path)” can’t be read.")
        }
        var found: [PageInfo] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == "node_modules" { walker.skipDescendants() }
                continue
            }
            // Regular files only: links, pipes and the like are never pages.
            guard values?.isRegularFile == true,
                  Self.pageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = Self.relativePath(of: url, under: base.url, prefix: base.path)
            found.append(PageInfo(path: path, title: Self.title(of: path), isBoard: isBoard(url),
                                  modified: values?.contentModificationDate ?? .distantPast))
            if found.count >= Self.maxPages { lastScanTruncated = true; break }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func relativePath(of url: URL, under base: URL, prefix: String) -> String {
        let full = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        let tail = full.hasPrefix(basePath + "/") ? String(full.dropFirst(basePath.count + 1)) : url.lastPathComponent
        return prefix.isEmpty ? tail : prefix + "/" + tail
    }

    /// A page's title is its file name, as in LP's sidebar.
    static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    func isBoard(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return BoardParser.isBoard(head: (try? handle.read(upToCount: BoardParser.boardMarkerWindow)) ?? Data())
    }

    struct PageText {
        var path: String
        var text: String
        var revision: String
        var isBoard: Bool
    }

    func readPage(_ raw: String) throws -> PageText {
        let target = try page(raw)
        let (text, data) = try readText(at: target.url)
        return PageText(path: target.path, text: text, revision: Self.revision(of: data), isBoard: BoardParser.isBoard(text))
    }

    // MARK: Search

    struct Hit: Equatable {
        var path: String
        var title: String
        var snippet: String
    }

    /// Pages whose name or text contains every word of `query` (case and accents ignored); name
    /// matches first, as in LP's ⌘K.
    func search(_ query: String, limit: Int = 20) throws -> [Hit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        guard !terms.isEmpty else { throw VaultError("Give a word or two to search for.") }
        var scored: [(score: Int, hit: Hit)] = []
        for info in try pages() {
            guard let text = try? readText(at: root.appendingPathComponent(info.path)).text else { continue }
            let title = Self.fold(info.title), body = Self.fold(text)
            var score = 0
            var firstBodyTerm: String?
            var matchedAll = true
            for term in terms {
                let inTitle = title.contains(term), inBody = body.contains(term)
                guard inTitle || inBody else { matchedAll = false; break }
                if inTitle { score += title.hasPrefix(term) ? 14 : 9 }
                if inBody { score += 2; if firstBodyTerm == nil { firstBodyTerm = term } }
            }
            guard matchedAll else { continue }
            scored.append((score, Hit(path: info.path, title: info.title, snippet: Self.snippet(of: text, around: firstBodyTerm))))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.hit.path < $1.hit.path }
            .prefix(max(1, min(limit, 100))).map(\.hit)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// About 160 characters of one line around the first match, or the page's first words.
    static func snippet(of text: String, around term: String?) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        guard let term, let range = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(160)).trimmingCharacters(in: .whitespaces)
        }
        let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 100, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces)
            + (end < flat.endIndex ? "…" : "")
    }

    // MARK: Tasks

    struct TaskInfo: Equatable {
        var path: String
        var text: String
        var isDone: Bool
        var due: Day?
        var time: TimeOfDay?
        /// Its place among the page's tasks (pages only).
        var ordinal: Int?
        /// For a board card: its list and, when the file stores one, its ID.
        var list: String?
        var cardID: String?
    }

    enum TaskFilter: String { case open, done, all }

    /// To-dos with some wording from every page, and every card on every board — what LP's Home
    /// lists — open ones by default, those due soonest first.
    func tasks(_ filter: TaskFilter = .open, dueBy: Day? = nil, in folderPath: String = "") throws -> [TaskInfo] {
        var found: [TaskInfo] = []
        for info in try pages(in: folderPath) {
            guard let text = try? readText(at: root.appendingPathComponent(info.path)).text else { continue }
            if BoardParser.isBoard(text) {
                let board = BoardParser.parse(text)
                for lane in board.lanes {
                    for card in lane.cards {
                        found.append(TaskInfo(path: info.path, text: card.title.isEmpty ? "Untitled card" : card.title,
                                              isDone: card.isDone || lane.marksComplete, due: card.due,
                                              time: CardText.dueTime(in: card.text), ordinal: nil, list: lane.title,
                                              cardID: card.hasStoredID ? card.id : nil))
                    }
                }
            } else {
                for (ordinal, task) in PageTasks.tasks(in: MarkdownParser.parse(text)).enumerated() {
                    found.append(TaskInfo(path: info.path, text: task.text, isDone: task.isDone, due: task.due,
                                          time: task.time, ordinal: ordinal))
                }
            }
        }
        return found.filter { task in
            switch filter {
            case .open: guard !task.isDone else { return false }
            case .done: guard task.isDone else { return false }
            case .all: break
            }
            if let dueBy { guard let due = task.due, due <= dueBy else { return false } }
            return true
        }.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.path != b.path ? a.path < b.path : (a.ordinal ?? 0) < (b.ordinal ?? 0)
            }
        }
    }

    // MARK: Boards

    struct BoardInfo {
        var path: String
        var title: String
        var summary: BoardSummary
    }

    func boards(in folderPath: String = "") throws -> [BoardInfo] {
        try pages(in: folderPath).filter(\.isBoard).compactMap { info in
            guard let text = try? readText(at: root.appendingPathComponent(info.path)).text else { return nil }
            return BoardInfo(path: info.path, title: info.title, summary: BoardSummary(board: BoardParser.parse(text)))
        }
    }

    func readBoard(_ raw: String) throws -> (path: String, board: Board) {
        let target = try page(raw)
        let (text, _) = try readText(at: target.url)
        guard BoardParser.isBoard(text) else { throw VaultError("“\(target.path)” is a page, not a board. Use lp_read_page.") }
        return (target.path, BoardParser.parse(text))
    }

    // MARK: - Writing

    /// Reads a file, lets `change` make its new text, and writes it — unless the file changed in
    /// the meantime (LP or another app wrote it), in which case it is read again, at most twice.
    @discardableResult
    private func modify(_ url: URL, _ change: (String) throws -> String) throws -> String {
        for _ in 0..<3 {
            let (text, data) = try readText(at: url)
            let updated = try change(text)
            guard updated != text else { return text }
            try Self.refuseTooBig(updated)
            // shortcut: the check-then-write window is microseconds; a file lock isn't worth it for notes.
            guard (try? Data(contentsOf: url)) == data else { continue }
            try SafeFileWriter.write(Data(updated.utf8), to: url)
            return updated
        }
        throw VaultError("This file keeps changing (LP or another app is writing it). Try again in a moment.")
    }

    /// A new page; never replaces a file ("Plan 2.md" when "Plan.md" exists, as in LP).
    func createPage(title: String, in folderPath: String = "", content: String = "") throws -> String {
        let target = try folder(folderPath)
        guard let base = PageNaming.sanitized(title) else { throw VaultError("Give the page a title.") }
        try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
        guard PathSafety.isInside(target.url, root: root) else { throw VaultError("That folder leads outside the workspace.") }
        let name = PageNaming.availableName(base, extension: "md", in: target.url)
        let body = content.isEmpty || content.hasSuffix("\n") ? content : content + "\n"
        try Self.refuseTooBig(body)
        try refuseLinks(target.path)
        try Data(body.utf8).write(to: target.url.appendingPathComponent(name), options: .withoutOverwriting)
        return target.path.isEmpty ? name : target.path + "/" + name
    }

    /// Adds Markdown at the end of a page, after a blank line.
    func append(to raw: String, markdown: String) throws -> String {
        let addition = markdown.trimmingCharacters(in: .newlines)
        guard !addition.trimmingCharacters(in: .whitespaces).isEmpty else { throw VaultError("There’s nothing to add.") }
        let target = try page(raw)
        try modify(target.url) { text in
            try Self.refuseBoard(text, target.path)
            let separator = text.isEmpty ? "" : text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
            return text + separator + addition + "\n"
        }
        return target.path
    }

    /// Replaces a whole page — only the version that was read (`revision` from lp_read_page).
    func replacePage(_ raw: String, content: String, revision: String) throws -> String {
        let target = try page(raw)
        var stale = false
        try modify(target.url) { text in
            try Self.refuseBoard(text, target.path)
            guard Self.revision(of: Data(text.utf8)) == revision else { stale = true; return text }
            return content.isEmpty || content.hasSuffix("\n") ? content : content + "\n"
        }
        if stale { throw VaultError("“\(target.path)” changed since it was read. Read it again and redo the change.") }
        return target.path
    }

    /// Replaces one exact passage of a page; it must appear exactly once.
    func replaceText(in raw: String, find: String, with replacement: String) throws -> String {
        guard !find.isEmpty else { throw VaultError("Say which text to replace.") }
        let target = try page(raw)
        try modify(target.url) { text in
            try Self.refuseBoard(text, target.path)
            let count = text.components(separatedBy: find).count - 1
            guard count == 1 else {
                throw VaultError(count == 0 ? "That text isn’t on “\(target.path)” (it must match exactly, including spaces)."
                                            : "That text appears \(count) times on “\(target.path)”. Include more of it so it’s unique.")
            }
            return text.replacingOccurrences(of: find, with: replacement)
        }
        return target.path
    }

    /// Nothing is written that the server couldn't read back.
    static func refuseTooBig(_ text: String) throws {
        if text.utf8.count > maxFileSize { throw VaultError("That would make the page larger than 4 MB, so it wasn’t written.") }
    }

    static func refuseBoard(_ text: String, _ path: String) throws {
        if BoardParser.isBoard(text) {
            throw VaultError("“\(path)” is a board. Change it card by card with lp_add_card and lp_update_card, so it stays a valid board.")
        }
    }

    /// The note for `day` (named like 2026-11-24): found anywhere in the workspace, or created in
    /// `folder` — by default "Daily Notes" when that folder exists, else the workspace's top.
    func dailyNote(for day: Day, folder folderPath: String? = nil) throws -> (path: String, created: Bool) {
        if let existing = try pages().filter({ !$0.isBoard && $0.title == day.iso }).min(by: { $0.path.count < $1.path.count }) {
            return (existing.path, false)
        }
        guard !lastScanTruncated else {
            throw VaultError("This workspace has more than \(Self.maxPages) pages, so its daily note may exist beyond what was scanned. Pass its path to lp_read_page instead.")
        }
        var isFolder: ObjCBool = false
        let fallback = FileManager.default.fileExists(atPath: root.appendingPathComponent("Daily Notes").path, isDirectory: &isFolder)
            && isFolder.boolValue ? "Daily Notes" : ""
        return (try createPage(title: day.iso, in: folderPath ?? fallback), true)
    }

    /// Ticks a task off or reopens it. On a page the task is found by its wording (and its place,
    /// `ordinal`, when two read the same); on a board, `text` is the card (ID or title).
    func setTaskDone(in raw: String, text: String, ordinal: Int? = nil, due: Day? = nil, done: Bool) throws -> String {
        let target = try page(raw)
        if BoardParser.isBoard(try readText(at: target.url).text) {
            return try updateCard(on: raw, card: text, CardChange(done: done))
        }
        var result = ""
        try modify(target.url) { source in
            try Self.refuseBoard(source, target.path)
            var document = MarkdownParser.parse(source)
            let tasks = PageTasks.tasks(in: document)
            let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Same wording (and the same due date, when given); the ordinal only chooses among those,
            // so a page reordered since it was listed can't make it tick a different task.
            let matches = tasks.indices.filter { tasks[$0].text == wanted && (due == nil || tasks[$0].due == due) }
            let index: Int
            if let ordinal, matches.contains(ordinal) {
                index = ordinal
            } else {
                guard !matches.isEmpty else {
                    throw VaultError("There’s no task “\(wanted)”\(due.map { " due \($0.iso)" } ?? "") on “\(target.path)”. Use lp_list_tasks to see its tasks as written.")
                }
                guard matches.count == 1 else {
                    throw VaultError("\(matches.count) tasks on “\(target.path)” read “\(wanted)”. Pass its ordinal (and due date) from lp_list_tasks.")
                }
                index = matches[0]
            }
            guard tasks[index].isDone != done else { result = done ? "It was already done." : "It was already open."; return source }
            guard case .todo(let status, let marker) = document.blocks[tasks[index].block].kind else { return source }
            document.blocks[tasks[index].block].kind = .todo(status: status == " " ? "x" : " ", marker: marker)
            result = done ? "Ticked off." : "Reopened."
            return MarkdownSerializer.serialize(document)
        }
        return result
    }

    // MARK: Board changes

    /// A new board from one of LP's templates (simple, project, weekly, content, bugs).
    func createBoard(title: String, in folderPath: String = "", template: String = "simple") throws -> String {
        guard let kind = BoardTemplate(rawValue: template.lowercased()) else {
            throw VaultError("There’s no “\(template)” template. Use simple, project, weekly, content or bugs.")
        }
        return try createPage(title: title, in: folderPath, content: kind.markdown())
    }

    /// The list called `title` (case ignored); lists have no IDs in the file.
    static func lane(_ title: String, in board: Board) throws -> Int {
        let wanted = fold(title.trimmingCharacters(in: .whitespaces))
        let matches = board.lanes.indices.filter { fold(board.lanes[$0].title) == wanted }
        guard matches.count == 1 else {
            let names = board.lanes.map { "“\($0.title)”" }.joined(separator: ", ")
            throw VaultError(matches.isEmpty ? "This board has no list “\(title)”. Its lists: \(names)."
                                             : "This board has \(matches.count) lists called “\(title)”, so it can’t tell which.")
        }
        return matches[0]
    }

    /// The card with this stored ID, or else the one card with this exact title (case ignored).
    static func card(_ reference: String, in board: Board) throws -> (lane: Int, card: Int) {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        var byTitle: [(Int, Int)] = []
        for laneIndex in board.lanes.indices {
            for cardIndex in board.lanes[laneIndex].cards.indices {
                let card = board.lanes[laneIndex].cards[cardIndex]
                if card.hasStoredID, card.id == wanted { return (laneIndex, cardIndex) }
                if fold(card.title) == fold(wanted) { byTitle.append((laneIndex, cardIndex)) }
            }
        }
        guard byTitle.count == 1 else {
            throw VaultError(byTitle.isEmpty ? "There’s no card “\(wanted)” on this board. Use lp_read_board to see its cards."
                                             : "\(byTitle.count) cards are called “\(wanted)”. Use the card’s id from lp_read_board.")
        }
        return byTitle[0]
    }

    /// A card title on one line: line breaks and other control characters become spaces, so
    /// nothing typed can start a new card or list in the file.
    static func oneLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tags as Obsidian writes them: letters, digits, _, - and /, without the #.
    static func cleanTags(_ tags: [String]) throws -> [String] {
        try tags.map { tag in
            let bare = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-/"))
            guard !bare.isEmpty, bare.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw VaultError("“\(tag)” isn’t a tag: use letters, digits, _, - or / (no spaces).")
            }
            return bare
        }
    }

    /// Notes keep their lines; Windows and old Mac line endings become plain ones.
    static func cleanNotes(_ notes: String) -> String {
        notes.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    func addCard(to raw: String, list: String, title: String, due: Day? = nil, time: TimeOfDay? = nil,
                 tags: [String] = [], notes: String = "") throws -> String {
        let cleanTitle = Self.oneLine(title)
        guard !cleanTitle.isEmpty else { throw VaultError("Give the card a title.") }
        let tags = try Self.cleanTags(tags)
        let notes = Self.cleanNotes(notes)
        if time != nil, due == nil { throw VaultError("A due time needs a due date too.") }
        let target = try page(raw)
        let id = BoardIDs.newCardID()
        try modify(target.url) { text in
            guard BoardParser.isBoard(text) else { throw VaultError("“\(target.path)” is a page, not a board.") }
            var board = BoardParser.parse(text)
            let laneIndex = try Self.lane(list, in: board)
            var card = BoardCard(id: id, text: cleanTitle, body: "", isDone: board.lanes[laneIndex].marksComplete)
            card = CardEdit(tags: tags.isEmpty ? nil : tags, changesDue: due != nil, due: due, changesTime: time != nil, time: time,
                            body: notes.isEmpty ? nil : notes).applied(to: card)
            board.lanes[laneIndex].cards.append(card)
            return BoardParser.serialize(board)
        }
        return id
    }

    struct CardChange {
        var title: String? = nil
        var tags: [String]? = nil
        var changesDue = false
        var due: Day? = nil
        var changesTime = false
        var time: TimeOfDay? = nil
        var notes: String? = nil
        var done: Bool? = nil
        var moveTo: String? = nil
        var before: String? = nil
    }

    /// Edits a card and, if asked, moves it to another list (before a given card, or at the end).
    /// Moving into a list whose cards count as done marks it done, and out of one marks it open —
    /// the same rules as dragging in LP and Obsidian. Reopening a card that sits in such a list
    /// moves it back to the first list that isn't.
    @discardableResult
    func updateCard(on raw: String, card reference: String, _ change: CardChange) throws -> String {
        let target = try page(raw)
        var summary = ""
        try modify(target.url) { text in
            guard BoardParser.isBoard(text) else { throw VaultError("“\(target.path)” is a page, not a board.") }
            var board = BoardParser.parse(text)
            let (laneIndex, cardIndex) = try Self.card(reference, in: board)
            let id = board.lanes[laneIndex].cards[cardIndex].id
            let title = change.title.map(Self.oneLine)
            if let title, title.isEmpty { throw VaultError("A card needs a title.") }
            let edit = CardEdit(title: title, tags: try change.tags.map(Self.cleanTags),
                                changesDue: change.changesDue, due: change.due, changesTime: change.changesTime, time: change.time,
                                body: change.notes.map(Self.cleanNotes), isDone: change.done)
            let editedCard = edit.applied(to: board.lanes[laneIndex].cards[cardIndex])
            if change.changesTime, change.time != nil, editedCard.due == nil { throw VaultError("A due time needs a due date too.") }
            board.lanes[laneIndex].cards[cardIndex] = editedCard
            var destination: Int? = try change.moveTo.map { try Self.lane($0, in: board) }
            if let destination, change.done == false, board.lanes[destination].marksComplete {
                throw VaultError("“\(board.lanes[destination].title)” counts its cards as done, so a card there can’t be open.")
            }
            if destination == nil, change.done == false, board.lanes[laneIndex].marksComplete {
                destination = board.lanes.firstIndex { !$0.marksComplete }
                if destination == nil { throw VaultError("Every list on this board counts its cards as done, so this card can’t be reopened.") }
            }
            if change.before != nil, change.moveTo == nil { throw VaultError("before_card only works with move_to_list.") }
            if let destination, destination != laneIndex || change.before != nil {
                let beforeID = try change.before.map { try Self.card($0, in: board) }.map { place -> String in
                    guard place.lane == destination else {
                        throw VaultError("“\(change.before!)” isn’t in “\(board.lanes[destination].title)”, so the card can’t go before it.")
                    }
                    return board.lanes[place.lane].cards[place.card].id
                }
                board.moveCards([id], toLane: board.lanes[destination].id, before: beforeID)
                // An explicit done/open wins over the list's rule.
                if let done = change.done, let moved = board.lanes[destination].cards.firstIndex(where: { $0.id == id }),
                   !board.lanes[destination].marksComplete {
                    board.lanes[destination].cards[moved].isDone = done
                }
                summary = "Moved to “\(board.lanes[destination].title)”."
            }
            return BoardParser.serialize(board)
        }
        return summary.isEmpty ? "Updated." : "Updated. " + summary
    }
}
