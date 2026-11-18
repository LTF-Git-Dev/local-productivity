//
//  BoardModel.swift
//  LP
//
//  A Trello-style board stored as a Markdown file in the vault. The format is the one
//  Obsidian's Kanban plugin uses, so the same board opens in either app:
//
//      ---
//
//      kanban-plugin: basic
//
//      ---
//
//      ## To do
//
//      - [ ] Draft the brief #design @{2026-11-20} ^c7k2m9q
//          Notes about the card, indented under it.
//
//      ## Done
//
//      **Complete**
//      - [x] Kick-off ^c1a2b3c
//
//  `^c…` is an Obsidian block ID. LP adds one to each card so it can follow a card as
//  it moves between lists and keep its history.
//

import Foundation

nonisolated struct Board: Codable, Hashable, Sendable {
    /// YAML between the fences, exactly as found.
    var frontMatter: String
    var lanes: [BoardLane]
    /// Cards put away under "## Archive" after a `***` line.
    var archive: [BoardCard] = []
    /// The trailing `%% kanban:settings … %%` block, kept verbatim.
    var settingsBlock: String? = nil
    /// Anything before the first list that LP does not interpret, kept verbatim.
    var preamble: String = ""
    /// Lines under "## Archive" that are not cards, kept verbatim.
    var archiveLines: [String] = []

    var allCards: [BoardCard] { lanes.flatMap(\.cards) }

    func lane(containing cardID: String) -> BoardLane? {
        lanes.first { lane in lane.cards.contains { $0.id == cardID } }
    }

    func card(withID id: String) -> BoardCard? {
        allCards.first { $0.id == id } ?? archive.first { $0.id == id }
    }

    /// The board's identity for its activity log, stored in front matter as `lp-board`.
    var boardID: String? {
        FrontMatter.value(for: "lp-board", in: frontMatter)
    }

    /// Cards written without IDs get new random ones on every read. Matching them to the cards
    /// of `old` by text keeps their history from looking like deletions and re-creations.
    mutating func adoptIDs(from old: Board) {
        // Never hand out an ID a card in the file already has (a copied card keeps its text).
        let taken = Set((allCards + archive).filter(\.hasStoredID).map(\.id))
        var available = Dictionary(grouping: old.allCards.filter { !taken.contains($0.id) }, by: \.text)
        for laneIndex in lanes.indices {
            for cardIndex in lanes[laneIndex].cards.indices where !lanes[laneIndex].cards[cardIndex].hasStoredID {
                let text = lanes[laneIndex].cards[cardIndex].text
                if var matches = available[text], !matches.isEmpty {
                    lanes[laneIndex].cards[cardIndex].id = matches.removeFirst().id
                    available[text] = matches
                }
            }
        }
    }
}

nonisolated struct BoardLane: Codable, Hashable, Identifiable, Sendable {
    /// Lanes have no identifier in the file; this one lives only as long as the loaded board.
    var id: String
    var title: String
    /// A "**Complete**" list: cards moved here are marked done.
    var marksComplete: Bool
    var cards: [BoardCard]
    /// Lines in the list above its first card that are not cards (a note about the list), kept
    /// verbatim and in place.
    var leadingLines: [String] = []
    /// Other lines in the list that are not cards, kept verbatim after the cards.
    var extraLines: [String] = []
}

nonisolated struct BoardCard: Codable, Hashable, Identifiable, Sendable {
    var id: String
    /// The first line as written, without the checkbox or block ID. Holds the title and any
    /// tags and dates.
    var text: String
    /// Lines under the card, without their indentation.
    var body: String
    var isDone: Bool
    /// False for a card that had no block ID in the file; LP writes one the next time it saves.
    var hasStoredID: Bool = true

    // MARK: Reading the text

    /// The title without tags, dates or links syntax that is shown separately.
    var title: String {
        CardText.title(of: text)
    }

    var tags: [String] {
        CardText.tags(in: text)
    }

    var due: Day? {
        CardText.due(in: text)
    }

    /// Checklist progress in the card's notes, e.g. 2 of 5.
    var checklist: (done: Int, total: Int)? {
        var done = 0
        var total = 0
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") || trimmed == "- [ ]" {
                total += 1
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                total += 1
                done += 1
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Rebuilds the first line from edited parts, keeping the date style the card used.
    static func text(title: String, tags: [String], due: Day?, previous: String) -> String {
        var parts = [title.trimmingCharacters(in: .whitespacesAndNewlines)]
        parts += tags.map { "#" + $0 }
        if let due {
            parts.append(previous.contains("📅") ? "📅 \(due.iso)" : "@{\(due.iso)}")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Card text

/// Understands the bits of syntax that can appear in a card's first line.
nonisolated enum CardText {

    /// `@{2026-11-20}` (Obsidian Kanban) or `📅 2026-11-20` (Obsidian Tasks).
    static func due(in text: String) -> Day? {
        var searchStart = text.startIndex
        while let range = text.range(of: "@{", range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            // "@@{14:00}" is the Kanban plugin's time, not a date.
            if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)] == "@" { continue }
            if let close = text[range.upperBound...].firstIndex(of: "}"), let day = Day(iso: String(text[range.upperBound..<close])) {
                return day
            }
        }
        if let range = text.range(of: "📅") {
            let after = text[range.upperBound...].drop(while: { $0 == " " || $0 == "\u{FE0F}" })
            return Day(iso: String(after.prefix(10)))
        }
        return nil
    }

    /// The time a card is due: `@@{14:00}` (Obsidian Kanban) or a time right after a `📅` date.
    static func dueTime(in text: String) -> TimeOfDay? {
        if let range = text.range(of: "@@{"), let close = text[range.upperBound...].firstIndex(of: "}"),
           let found = TimeOfDay.leading(in: text[range.upperBound..<close]),
           found.rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return found.time
        }
        if let range = text.range(of: "📅") {
            let after = text[range.upperBound...].drop(while: { $0 == " " || $0 == "\u{FE0F}" })
            if Day(iso: String(after.prefix(10))) != nil, let found = TimeOfDay.leading(in: after.dropFirst(10)) {
                return found.time
            }
        }
        return nil
    }

    static func tags(in text: String) -> [String] {
        var tags: [String] = []
        var previous: Character = " "
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "#", previous == " " || previous == "\t" {
                let start = text.index(after: index)
                let end = text[start...].firstIndex(where: { !isTagCharacter($0) }) ?? text.endIndex
                let tag = String(text[start..<end])
                if !tag.isEmpty, tag.contains(where: { !$0.isNumber }) {
                    tags.append(tag)
                }
                index = end
                previous = "x"
                continue
            }
            previous = character
            index = text.index(after: index)
        }
        return tags
    }

    static func title(of text: String) -> String {
        var result = text
        // Times first: "@{" also matches inside "@@{14:00}" and would leave a stray "@".
        while let range = result.range(of: "@@{"), let close = result[range.upperBound...].firstIndex(of: "}") {
            result.removeSubrange(range.lowerBound...close)
        }
        while let range = result.range(of: "@{"), let close = result[range.upperBound...].firstIndex(of: "}") {
            result.removeSubrange(range.lowerBound...close)
        }
        if let range = result.range(of: "📅") {
            let tail = result[range.upperBound...].drop(while: { $0 == " " || $0 == "\u{FE0F}" })
            var end = tail.index(tail.startIndex, offsetBy: min(10, tail.count))
            // A time written after the date goes with it.
            if Day(iso: String(tail.prefix(10))) != nil, let found = TimeOfDay.leading(in: result[end...]) {
                end = found.rest.startIndex
            }
            result.removeSubrange(range.lowerBound..<end)
        }
        // Tags.
        for tag in tags(in: result) {
            result = result.replacingOccurrences(of: "#" + tag, with: "")
        }
        // Wiki links read as their text.
        while let open = result.range(of: "[["), let close = result.range(of: "]]", range: open.upperBound..<result.endIndex) {
            var inner = String(result[open.upperBound..<close.lowerBound])
            if let pipe = inner.firstIndex(of: "|") { inner = String(inner[inner.index(after: pipe)...]) }
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: inner)
        }
        return result.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func isTagCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "/"
    }

    // MARK: Editing parts of the text
    //
    // Each edit changes only what it is about, so links and other syntax elsewhere in the
    // line survive.

    /// The text with its due date set: changed where it is written, added when missing,
    /// removed when `due` is nil.
    static func settingDue(_ due: Day?, in text: String) -> String {
        var result = text
        if let token = dueTokenRange(in: result) {
            if let due {
                let replacement = result[token].hasPrefix("@{") ? "@{\(due.iso)}" : "📅 \(due.iso)"
                result.replaceSubrange(token, with: replacement)
                return result
            }
            // A time means nothing without its date; it goes too.
            if let time = dueTimeRange(in: result) {
                let ranges = [token, time].sorted { $0.lowerBound > $1.lowerBound }
                for range in ranges { result.removeSubrange(range) }
            } else {
                result.removeSubrange(token)
            }
            return tidy(result)
        }
        guard let due else { return text }
        return tidy(result) + " @{\(due.iso)}"
    }

    /// The text with its tags replaced by `tags`, placed after the title and before any date.
    static func settingTags(_ tags: [String], in text: String) -> String {
        var stripped = ""
        var previous: Character = " "
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "#", previous == " " || previous == "\t" {
                let start = text.index(after: index)
                let end = text[start...].firstIndex(where: { !isTagCharacter($0) }) ?? text.endIndex
                let tag = text[start..<end]
                if !tag.isEmpty, tag.contains(where: { !$0.isNumber }) {
                    index = end
                    previous = " "
                    continue
                }
            }
            stripped.append(character)
            previous = character
            index = text.index(after: index)
        }
        var base = tidy(stripped)
        let tagText = tags.map { "#" + $0 }.joined(separator: " ")
        guard !tagText.isEmpty else { return base }
        if let token = dueTokenRange(in: base) {
            base.insert(contentsOf: tagText + " ", at: token.lowerBound)
            return tidy(base)
        }
        return base.isEmpty ? tagText : base + " " + tagText
    }

    /// The text with a new title, keeping its tags and date.
    static func settingTitle(_ title: String, in text: String) -> String {
        var result = BoardCard.text(title: title, tags: tags(in: text), due: due(in: text), previous: text)
        // The rebuilt line ends with the date; a time written with it goes back after it.
        if let time = dueTimeRange(in: text) {
            let token = text[time].trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("@@{") || due(in: text) != nil { result += " " + token }
        }
        return result
    }

    /// The text with its due time set (written `@@{14:30}`, or after a `📅` date) or removed.
    /// A time needs a date: without one the text is left as it is.
    static func settingDueTime(_ time: TimeOfDay?, in text: String) -> String {
        var result = text
        let written = time.map { String(format: "%02d:%02d", $0.hour, $0.minute) }
        if let range = dueTimeRange(in: result) {
            guard let written else {
                result.removeSubrange(range)
                return tidy(result)
            }
            let isKanban = result[range].trimmingCharacters(in: .whitespaces).hasPrefix("@@{")
            result.replaceSubrange(range, with: isKanban ? "@@{\(written)}" : " \(written)")
            return result
        }
        guard let written, let date = dueTokenRange(in: result) else { return text }
        result.insert(contentsOf: result[date].hasPrefix("📅") ? " \(written)" : " @@{\(written)}", at: date.upperBound)
        return result
    }

    /// Where the due date is written: `@{2026-11-20}`, or `📅 2026-11-20` with its date.
    private static func dueTokenRange(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let open = text.range(of: "@{", range: searchStart..<text.endIndex) {
            searchStart = open.upperBound
            // "@@{14:00}" is a time, not a date.
            if open.lowerBound > text.startIndex, text[text.index(before: open.lowerBound)] == "@" { continue }
            if let close = text[open.upperBound...].firstIndex(of: "}"), Day(iso: String(text[open.upperBound..<close])) != nil {
                return open.lowerBound..<text.index(after: close)
            }
        }
        if let emoji = text.range(of: "📅") {
            var end = emoji.upperBound
            while end < text.endIndex, text[end] == " " || text[end] == "\u{FE0F}" { end = text.index(after: end) }
            guard let dateEnd = text.index(end, offsetBy: 10, limitedBy: text.endIndex),
                  Day(iso: String(text[end..<dateEnd])) != nil else { return nil }
            return emoji.lowerBound..<dateEnd
        }
        return nil
    }

    /// Where the due time is written: `@@{14:00}`, or the time right after a `📅` date
    /// (including the space before it).
    private static func dueTimeRange(in text: String) -> Range<String.Index>? {
        if let open = text.range(of: "@@{"), let close = text[open.upperBound...].firstIndex(of: "}") {
            return open.lowerBound..<text.index(after: close)
        }
        if let date = dueTokenRange(in: text), text[date].hasPrefix("📅"),
           let found = TimeOfDay.leading(in: text[date.upperBound...]), found.rest.startIndex > date.upperBound {
            return date.upperBound..<found.rest.startIndex
        }
        return nil
    }

    /// Collapses the double spaces an edit can leave behind.
    private static func tidy(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

// MARK: - Identifiers

nonisolated enum BoardIDs {

    private static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

    static func make(prefix: String, length: Int = 7) -> String {
        var generator = SystemRandomNumberGenerator()
        return prefix + String((0..<length).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] })
    }

    static func newCardID() -> String { make(prefix: "c") }
    static func newBoardID() -> String { make(prefix: "b", length: 8) }
}

// MARK: - Templates

/// Ready-made sets of lists for a new board.
nonisolated enum BoardTemplate: String, CaseIterable, Identifiable, Sendable {
    case simple, project, weekly, content, bugs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "Simple"
        case .project: return "Project"
        case .weekly: return "Weekly"
        case .content: return "Content"
        case .bugs: return "Bugs"
        }
    }

    /// The lists, in order. The last one counts its cards as done.
    var lists: [String] {
        switch self {
        case .simple: return ["To do", "In progress", "Done"]
        case .project: return ["Backlog", "Next", "In progress", "Review", "Done"]
        case .weekly: return ["This week", "Today", "Waiting", "Done"]
        case .content: return ["Ideas", "Drafting", "Editing", "Scheduled", "Published"]
        case .bugs: return ["Reported", "Confirmed", "Fixing", "Fixed"]
        }
    }

    var symbol: String {
        switch self {
        case .simple: return "checklist"
        case .project: return "folder"
        case .weekly: return "calendar"
        case .content: return "pencil.line"
        case .bugs: return "ladybug"
        }
    }

    /// "To do · In progress · Done", breaking only after a separator.
    var summary: String {
        lists.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "\u{00A0}· ")
    }

    /// A fresh board, laid out exactly as the Obsidian Kanban plugin writes one.
    func markdown(boardID: String = BoardIDs.newBoardID()) -> String {
        var text = "---\n\nkanban-plugin: basic\nlp-board: \(boardID)\n\n---\n\n"
        for (index, list) in lists.enumerated() {
            text += "## \(list)\n\n"
            if index == lists.count - 1 { text += "**Complete**\n" }
            text += "\n\n"
        }
        return text + "%% kanban:settings\n```\n{\"kanban-plugin\":\"basic\"}\n```\n%%\n"
    }

    /// The simple board that earlier versions created.
    static func markdown(boardID: String = BoardIDs.newBoardID()) -> String {
        BoardTemplate.simple.markdown(boardID: boardID)
    }
}

// MARK: - Summary

/// What overviews and widgets show about a board without loading it: its size, progress, lists
/// and the due dates still open (so overdue counts stay right on later days).
nonisolated struct BoardSummary: Hashable, Sendable {

    struct List: Hashable, Sendable {
        var title: String
        var count: Int
        var marksComplete: Bool
    }

    var total: Int
    var done: Int
    var lists: [List]
    var openDue: [Day]

    init(board: Board) {
        var total = 0
        var done = 0
        var openDue: [Day] = []
        for lane in board.lanes {
            for card in lane.cards {
                total += 1
                if card.isDone || lane.marksComplete {
                    done += 1
                } else if let due = card.due {
                    openDue.append(due)
                }
            }
        }
        self.total = total
        self.done = done
        self.lists = board.lanes.map { List(title: $0.title, count: $0.cards.count, marksComplete: $0.marksComplete) }
        self.openDue = openDue.sorted()
    }

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var percent: Int { Int((fraction * 100).rounded()) }

    func overdue(on day: Day = .today) -> Int {
        openDue.filter { $0 < day }.count
    }

    /// Due today or within the next `days` days.
    func dueSoon(on day: Day = .today, within days: Int = 3) -> Int {
        let last = day.adding(days: days)
        return openDue.filter { $0 >= day && $0 <= last }.count
    }
}

// MARK: - Progress

nonisolated struct BoardProgress: Hashable, Sendable {
    var total: Int
    var done: Int
    var overdue: Int
    var dueSoon: Int
    var perLane: [(title: String, count: Int, marksComplete: Bool)]

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var percent: Int { Int((fraction * 100).rounded()) }

    init(board: Board, today: Day = .today) {
        var total = 0
        var done = 0
        var overdue = 0
        var dueSoon = 0
        var perLane: [(String, Int, Bool)] = []
        let soon = today.adding(days: 3)
        for lane in board.lanes {
            perLane.append((lane.title, lane.cards.count, lane.marksComplete))
            for card in lane.cards {
                total += 1
                let isDone = card.isDone || lane.marksComplete
                if isDone {
                    done += 1
                } else if let due = card.due {
                    if due < today { overdue += 1 } else if due <= soon { dueSoon += 1 }
                }
            }
        }
        self.total = total
        self.done = done
        self.overdue = overdue
        self.dueSoon = dueSoon
        self.perLane = perLane
    }

    static func == (lhs: BoardProgress, rhs: BoardProgress) -> Bool {
        lhs.total == rhs.total && lhs.done == rhs.done && lhs.overdue == rhs.overdue && lhs.dueSoon == rhs.dueSoon
            && lhs.perLane.map(\.title) == rhs.perLane.map(\.title) && lhs.perLane.map(\.count) == rhs.perLane.map(\.count)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(total)
        hasher.combine(done)
    }
}
