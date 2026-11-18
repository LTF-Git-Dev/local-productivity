//
//  WorkspaceIndex.swift
//  Local Productivity
//
//  Reads every page once in the background and remembers what the rest of the app
//  needs to know about it: its icon, a preview, its date, its tasks and its text for
//  search. Only files whose modification date changed are read again.
//

import Foundation

nonisolated struct TaskItem: Identifiable, Hashable, Sendable {
    var path: String
    /// Position among the tasks of its page, used to find it again when it is toggled.
    var ordinal: Int
    var text: String
    var isDone: Bool
    var due: Day?
    /// The time it is due, when the task names one (`📅 2026-11-20 14:00`, `@@{14:00}`).
    var dueTime: TimeOfDay? = nil
    /// Set for a card on a board, whose position counts the board's cards rather than its to-dos.
    var isBoardCard = false
    /// The card's block ID, when the file has one.
    var cardID: String? = nil

    var id: String { "\(path)#\(ordinal)" }
}

nonisolated struct PageMeta: Hashable, Sendable {
    var path: String
    var title: String
    var icon: String?
    var modified: Date
    var created: Date?
    var snippet: String
    var wordCount: Int
    /// The day this page belongs to: a daily note's name, or the `date` in its front matter.
    var day: Day?
    var isDailyNote: Bool
    var tasks: [TaskItem]
    /// A Kanban board rather than a page of writing.
    var isBoard = false
    /// For a board: its size, progress and lists.
    var board: BoardSummary? = nil
}

nonisolated extension PageMeta {
    /// How the page is named in overviews: daily notes are shown as their date written out.
    var displayTitle: String {
        guard isDailyNote, let day else { return title }
        return day.date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    var path: String
    var title: String
    var icon: String?
    var snippet: String
    var isTitleMatch: Bool

    var id: String { path }
}

actor WorkspaceIndex {

    /// Immutable once made; the folded NSStrings are never mutated, so sharing them between the
    /// indexing tasks is safe.
    private struct Entry: @unchecked Sendable {
        var meta: PageMeta
        var body: String
        /// The title and body folded for matching (lower case, no accents), made once when the page
        /// is read so a search is a plain scan rather than a case-insensitive comparison.
        var foldedTitle: NSString
        var foldedBody: NSString

        init(meta: PageMeta, body: String) {
            self.meta = meta
            self.body = body
            foldedTitle = Self.fold(meta.title) as NSString
            foldedBody = Self.fold(body) as NSString
        }

        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    private var entries: [String: Entry] = [:]

    /// Brings the index in line with `pages` and returns the metadata for all of them. Changed
    /// pages are read in parallel, in batches, so a large workspace is indexed using every core.
    func update(root: URL, pages: [FileNode]) async -> [String: PageMeta] {
        var next: [String: Entry] = [:]
        next.reserveCapacity(pages.count)
        var toRead: [FileNode] = []
        for page in pages {
            if let existing = entries[page.path], existing.meta.modified == page.modified {
                next[page.path] = existing
            } else {
                toRead.append(page)
            }
        }
        let batchSize = 48
        let batches = stride(from: 0, to: toRead.count, by: batchSize).map { Array(toRead[$0..<min($0 + batchSize, toRead.count)]) }
        await withTaskGroup(of: [Entry].self) { group in
            for batch in batches {
                group.addTask { batch.map { Self.read($0, root: root) } }
            }
            for await entries in group {
                for entry in entries { next[entry.meta.path] = entry }
            }
        }
        entries = next
        return next.mapValues(\.meta)
    }

    func search(_ query: String, limit: Int = 40) -> [SearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { Entry.fold(String($0)) }
        guard !terms.isEmpty else { return [] }

        var scored: [(score: Double, entry: Entry, titleMatched: Bool, firstTerm: String?)] = []
        let now = Date()
        for entry in entries.values {
            var score = 0.0
            var titleMatched = false
            var firstBodyTerm: String? = nil
            var matchedAll = true

            for term in terms {
                let titleRange = entry.foldedTitle.range(of: term)
                let inBody = entry.foldedBody.range(of: term).location != NSNotFound
                if titleRange.location == NSNotFound, !inBody {
                    matchedAll = false
                    break
                }
                if titleRange.location != NSNotFound {
                    titleMatched = true
                    score += titleRange.location == 0 ? 14 : 9
                }
                if inBody {
                    score += 2
                    if firstBodyTerm == nil { firstBodyTerm = term }
                }
            }
            guard matchedAll else { continue }

            // Recently edited pages win ties.
            let ageInDays = now.timeIntervalSince(entry.meta.modified) / 86_400
            score += max(0, 3 - ageInDays / 20)
            scored.append((score, entry, titleMatched, firstBodyTerm))
        }

        // Excerpts are cut from the original text, and only for the results that are shown.
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.meta.title < $1.entry.meta.title }
            .prefix(limit)
            .map { result in
                let match = result.firstTerm.flatMap { result.entry.body.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
                let snippet = match.map { Self.excerpt(of: result.entry.body, around: $0) } ?? result.entry.meta.snippet
                return SearchHit(path: result.entry.meta.path, title: result.entry.meta.title, icon: result.entry.meta.icon,
                                 snippet: snippet, isTitleMatch: result.titleMatched)
            }
    }

    // MARK: Reading a page

    private nonisolated static func read(_ page: FileNode, root: URL) -> Entry {
        let url = root.appendingPathComponent(page.path)
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0.prefix(2_000_000), as: UTF8.self) } ?? ""
        if BoardParser.isBoard(text) { return readBoard(page, text: text) }
        let document = MarkdownParser.parse(text)
        let body = document.plainText

        var day = page.name.count == 10 ? Day(iso: page.name) : nil
        let isDailyNote = day != nil
        if day == nil {
            for key in ["date", "created", "due"] {
                if let value = FrontMatter.value(for: key, in: document.frontMatter), let parsed = Day(iso: value) {
                    day = parsed
                    break
                }
            }
        }

        var tasks: [TaskItem] = []
        for block in document.blocks {
            guard case .todo(let status, _) = block.kind else { continue }
            let (text, due, time) = taskText(block.plainText)
            guard !text.isEmpty else { continue }
            tasks.append(TaskItem(path: page.path, ordinal: tasks.count, text: text, isDone: status != " ", due: due,
                                  dueTime: due == nil ? nil : time))
        }

        let meta = PageMeta(
            path: page.path,
            title: page.name,
            icon: FrontMatter.value(for: "icon", in: document.frontMatter),
            modified: page.modified,
            created: page.created,
            snippet: snippet(of: document, title: page.name),
            wordCount: body.split(whereSeparator: \.isWhitespace).count,
            day: day,
            isDailyNote: isDailyNote,
            tasks: tasks
        )
        return Entry(meta: meta, body: body)
    }

    /// A board is summarised by its progress, and its cards with due dates count as tasks, so
    /// they appear on Home and in the calendar.
    private static func readBoard(_ page: FileNode, text: String) -> Entry {
        let board = BoardParser.parse(text)
        var tasks: [TaskItem] = []
        var ordinal = 0
        var body: [String] = []
        for lane in board.lanes {
            body.append(lane.title)
            for card in lane.cards {
                defer { ordinal += 1 }
                body.append(card.title)
                if !card.body.isEmpty { body.append(card.body) }
                guard let due = card.due else { continue }
                tasks.append(TaskItem(path: page.path, ordinal: ordinal, text: card.title.isEmpty ? "Untitled card" : card.title,
                                      isDone: card.isDone || lane.marksComplete, due: due, dueTime: CardText.dueTime(in: card.text),
                                      isBoardCard: true, cardID: card.hasStoredID ? card.id : nil))
            }
        }
        let progress = BoardProgress(board: board)
        let lists = board.lanes.count == 1 ? "1 list" : "\(board.lanes.count) lists"
        let cards = progress.total == 1 ? "1 card" : "\(progress.total) cards"
        let joined = body.joined(separator: "\n")
        let meta = PageMeta(
            path: page.path,
            title: page.name,
            icon: FrontMatter.value(for: "icon", in: board.frontMatter),
            modified: page.modified,
            created: page.created,
            snippet: "\(lists) · \(cards) · \(progress.percent)% done",
            wordCount: joined.split(whereSeparator: \.isWhitespace).count,
            day: nil,
            isDailyNote: false,
            tasks: tasks,
            isBoard: true,
            board: BoardSummary(board: board)
        )
        return Entry(meta: meta, body: joined)
    }

    /// Separates a task's wording from a due date written as `📅 2026-11-20` or `due: 2026-11-20`,
    /// and from a time written right after the date (`📅 2026-11-20 14:00`).
    static func taskText(_ raw: String) -> (text: String, due: Day?, time: TimeOfDay?) {
        let line = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        for marker in ["📅", "due:", "due::", "@due"] {
            guard let range = line.range(of: marker, options: .caseInsensitive) else { continue }
            let tail = String(line[range.upperBound...])
            guard let day = Day.first(in: String(tail.prefix(16))) else { continue }
            var text = String(line[..<range.lowerBound])
            var time: TimeOfDay? = nil
            if let dateRange = tail.range(of: day.iso) {
                var rest = tail[dateRange.upperBound...]
                if let found = TimeOfDay.leading(in: rest) {
                    time = found.time
                    rest = found.rest
                }
                text += rest.trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            }
            return (text.trimmingCharacters(in: .whitespaces), day, time)
        }
        return (line.trimmingCharacters(in: .whitespaces), nil, nil)
    }

    /// A couple of lines of readable text to preview the page with.
    private static func snippet(of document: MarkdownDocument, title: String) -> String {
        var pieces: [String] = []
        var length = 0
        for block in document.blocks {
            switch block.kind {
            case .divider, .raw, .image, .table, .code: continue
            default: break
            }
            let text = block.plainText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if pieces.isEmpty, block.kind.isHeading, text.caseInsensitiveCompare(title) == .orderedSame { continue }
            pieces.append(text)
            length += text.count
            if length > 220 { break }
        }
        return String(pieces.joined(separator: "  ·  ").prefix(240))
    }

    private static func excerpt(of body: String, around range: Range<String.Index>) -> String {
        let start = body.index(range.lowerBound, offsetBy: -48, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: 96, limitedBy: body.endIndex) ?? body.endIndex
        var excerpt = body[start..<end].replacingOccurrences(of: "\n", with: " ")
        if start > body.startIndex {
            // Begin on a word boundary so the excerpt does not open mid-word.
            if let space = excerpt.firstIndex(of: " "), excerpt.distance(from: excerpt.startIndex, to: space) < 16 {
                excerpt = String(excerpt[excerpt.index(after: space)...])
            }
            excerpt = "…" + excerpt
        }
        if end < body.endIndex { excerpt += "…" }
        return excerpt
    }
}
