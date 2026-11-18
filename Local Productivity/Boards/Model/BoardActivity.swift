//
//  BoardActivity.swift
//  LP
//
//  What happened on a board and when: cards created, moved, completed, renamed and
//  deleted, plus a daily count of cards for the progress chart. Kept in the vault at
//  `.lp/boards/<board id>.json`, so it travels with the notes but stays out of sight in
//  Obsidian and in LP's sidebar.
//

import Foundation

nonisolated struct BoardEvent: Codable, Hashable, Identifiable, Sendable {

    enum Kind: String, Codable, Sendable {
        case created, moved, completed, reopened, renamed, dueChanged, archived, deleted
    }

    var id = UUID()
    var at: Date
    var kind: Kind
    var cardID: String
    var cardTitle: String
    var from: String? = nil
    var to: String? = nil

    /// "Moved “Design homepage” from To do to In progress".
    var sentence: String {
        let card = "“\(cardTitle)”"
        switch kind {
        case .created: return "Added \(card)" + (to.map { " to \($0)" } ?? "")
        case .moved: return "Moved \(card)" + (from.map { " from \($0)" } ?? "") + (to.map { " to \($0)" } ?? "")
        case .completed: return "Completed \(card)"
        case .reopened: return "Reopened \(card)"
        case .renamed: return "Renamed " + (from.map { "“\($0)”" } ?? "a card") + " to \(card)"
        case .dueChanged:
            return to.map { "Set \(card) due \(Day(iso: $0)?.shortTitle ?? $0)" } ?? "Removed the due date from \(card)"
        case .archived: return "Archived \(card)"
        case .deleted: return "Deleted \(card)"
        }
    }

    var symbol: String {
        switch kind {
        case .created: return "plus.circle"
        case .moved: return "arrow.right.circle"
        case .completed: return "checkmark.circle"
        case .reopened: return "arrow.uturn.backward.circle"
        case .renamed: return "pencil.circle"
        case .dueChanged: return "calendar.circle"
        case .archived: return "archivebox"
        case .deleted: return "trash.circle"
        }
    }
}

/// How the board stood at the end of a day.
nonisolated struct BoardSnapshot: Codable, Hashable, Sendable {
    var day: Day
    var total: Int
    var done: Int
}

/// A live, read-only progress page published for others.
nonisolated struct BoardShare: Codable, Hashable, Sendable {
    var gistID: String
    var url: URL
    var fileName: String
    var lastPublished: Date?
    var updatesAutomatically = true
}

nonisolated struct BoardActivityLog: Codable, Hashable, Sendable {

    static let eventLimit = 2000
    static let snapshotLimit = 400

    var boardID: String
    var events: [BoardEvent] = []
    var snapshots: [BoardSnapshot] = []
    /// When each card was first seen, for card age and time-to-done.
    var firstSeen: [String: Date] = [:]
    var share: BoardShare? = nil
    /// The board as LP last saw it. Comparing against it when the board is opened again
    /// records what changed in the meantime, in another app or from Home.
    var lastSeen: Board? = nil

    mutating func record(_ new: [BoardEvent]) {
        guard !new.isEmpty else { return }
        events.append(contentsOf: new)
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    /// Records today's totals, replacing an earlier entry for the same day.
    mutating func snapshot(_ progress: BoardProgress, on day: Day = .today) {
        let entry = BoardSnapshot(day: day, total: progress.total, done: progress.done)
        if let last = snapshots.last, last.day == day {
            snapshots[snapshots.count - 1] = entry
        } else {
            snapshots.append(entry)
        }
        if snapshots.count > Self.snapshotLimit { snapshots.removeFirst(snapshots.count - Self.snapshotLimit) }
    }

    func events(for cardID: String) -> [BoardEvent] {
        events.filter { $0.cardID == cardID }
    }

    /// Cards completed in the last `days` days.
    func completedCount(withinDays days: Int, now: Date = Date()) -> Int {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return Set(events.filter { $0.kind == .completed && $0.at >= since }.map(\.cardID)).count
    }

    /// Average days from a card first appearing to it being completed, over completed cards.
    func averageDaysToDone() -> Double? {
        var durations: [Double] = []
        var lastCompletion: [String: Date] = [:]
        for event in events where event.kind == .completed { lastCompletion[event.cardID] = event.at }
        for (card, done) in lastCompletion {
            guard let start = firstSeen[card], done > start else { continue }
            durations.append(done.timeIntervalSince(start) / 86_400)
        }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    /// Notes the first sighting of every card on the board.
    mutating func noteCards(of board: Board, at now: Date = Date()) {
        for card in board.allCards where firstSeen[card.id] == nil { firstSeen[card.id] = now }
    }
}

// MARK: - Working out what changed

nonisolated enum BoardDiff {

    /// The events that turn `old` into `new`, matched by card ID.
    static func events(from old: Board, to new: Board, at now: Date = Date()) -> [BoardEvent] {
        var oldLocation: [String: (lane: BoardLane, card: BoardCard)] = [:]
        for lane in old.lanes { for card in lane.cards { oldLocation[card.id] = (lane, card) } }
        let oldArchive = Set(old.archive.map(\.id))
        let newArchive = Dictionary(new.archive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var events: [BoardEvent] = []
        var seen = Set<String>()
        for lane in new.lanes {
            for card in lane.cards {
                seen.insert(card.id)
                let isDone = card.isDone || lane.marksComplete
                guard let before = oldLocation[card.id] else {
                    events.append(BoardEvent(at: now, kind: .created, cardID: card.id, cardTitle: card.title, to: lane.title))
                    if isDone { events.append(BoardEvent(at: now, kind: .completed, cardID: card.id, cardTitle: card.title)) }
                    continue
                }
                let wasDone = before.card.isDone || before.lane.marksComplete
                if before.lane.title != lane.title {
                    events.append(BoardEvent(at: now, kind: .moved, cardID: card.id, cardTitle: card.title,
                                             from: before.lane.title, to: lane.title))
                }
                if isDone != wasDone {
                    events.append(BoardEvent(at: now, kind: isDone ? .completed : .reopened, cardID: card.id, cardTitle: card.title))
                }
                if before.card.title != card.title, !card.title.isEmpty {
                    events.append(BoardEvent(at: now, kind: .renamed, cardID: card.id, cardTitle: card.title, from: before.card.title))
                }
                if before.card.due != card.due {
                    events.append(BoardEvent(at: now, kind: .dueChanged, cardID: card.id, cardTitle: card.title,
                                             from: before.card.due?.iso, to: card.due?.iso))
                }
            }
        }
        for (id, before) in oldLocation where !seen.contains(id) {
            if newArchive[id] != nil, !oldArchive.contains(id) {
                events.append(BoardEvent(at: now, kind: .archived, cardID: id, cardTitle: before.card.title, from: before.lane.title))
            } else {
                events.append(BoardEvent(at: now, kind: .deleted, cardID: id, cardTitle: before.card.title, from: before.lane.title))
            }
        }
        return events
    }
}

nonisolated extension BoardActivityLog {
    /// Reads a log leniently. A part written by another version of LP that cannot be read — a
    /// new kind of event, a changed board model — is skipped rather than costing the whole
    /// history and the share link with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boardID = try container.decode(String.self, forKey: .boardID)
        events = ((try? container.decodeIfPresent([Lenient<BoardEvent>].self, forKey: .events)) ?? []).compactMap(\.value)
        snapshots = ((try? container.decodeIfPresent([Lenient<BoardSnapshot>].self, forKey: .snapshots)) ?? []).compactMap(\.value)
        firstSeen = (try? container.decodeIfPresent([String: Date].self, forKey: .firstSeen)) ?? [:]
        share = try? container.decodeIfPresent(BoardShare.self, forKey: .share)
        lastSeen = try? container.decodeIfPresent(Board.self, forKey: .lastSeen)
    }
}

/// One element of a list that may fail to decode on its own.
private nonisolated struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
