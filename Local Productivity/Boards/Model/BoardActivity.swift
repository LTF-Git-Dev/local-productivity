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

/// A live, read-only progress page published for others — a secret gist on the person's GitHub,
/// or a Google Doc in their own Google Drive.
nonisolated struct BoardShare: Codable, Hashable, Sendable {

    enum Service: String, Codable, Sendable {
        case gist
        case googleDrive
    }

    var service: Service = .gist
    /// The page's ID at its service: a gist ID, or a Google Drive file ID. (Saved as "gistID", as
    /// before Drive, so a history written now still reads the same in older versions.)
    var pageID: String
    /// For a Drive page: the connected Google account whose Drive holds it ("google:<email>").
    var account: String?
    /// The address as it was published. Never used: links are built from the ID (`pageURL`).
    var url: URL
    var fileName: String
    var lastPublished: Date?
    var updatesAutomatically = true

    init(gistID: String, url: URL, fileName: String, lastPublished: Date?, updatesAutomatically: Bool = true) {
        self.pageID = gistID
        self.url = url
        self.fileName = fileName
        self.lastPublished = lastPublished
        self.updatesAutomatically = updatesAutomatically
    }

    init(driveFileID: String, account: String, fileName: String, lastPublished: Date?, updatesAutomatically: Bool = true) {
        service = .googleDrive
        pageID = driveFileID
        self.account = account
        url = GoogleDriveMapping.pageURL(fileID: driveFileID) ?? URL(string: "https://docs.google.com/")!
        self.fileName = fileName
        self.lastPublished = lastPublished
        self.updatesAutomatically = updatesAutomatically
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case pageID = "gistID"
        case account, url, fileName, lastPublished, updatesAutomatically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // No service: a gist, as every page was before Drive. One LP doesn't know (from a newer
        // version) fails to read, so the board shows no page rather than mistaking it for a gist.
        service = container.contains(.service) ? try container.decode(Service.self, forKey: .service) : .gist
        pageID = try container.decode(String.self, forKey: .pageID)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        url = try container.decode(URL.self, forKey: .url)
        fileName = try container.decode(String.self, forKey: .fileName)
        lastPublished = try container.decodeIfPresent(Date.self, forKey: .lastPublished)
        updatesAutomatically = try container.decodeIfPresent(Bool.self, forKey: .updatesAutomatically) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // A gist is written exactly as before Drive.
        if service != .gist { try container.encode(service, forKey: .service) }
        try container.encode(pageID, forKey: .pageID)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encode(url, forKey: .url)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(lastPublished, forKey: .lastPublished)
        try container.encode(updatesAutomatically, forKey: .updatesAutomatically)
    }

    /// A Google account as LP names it: "google:" and an address, nothing that could be read as
    /// anything else.
    static func isValidAccount(_ account: String) -> Bool {
        account.hasPrefix("google:") && (8...330).contains(account.count) && account.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F && scalar != "/" && scalar != "\\"
        }
    }

    /// Whether the record names a real page: an ID of its service's kind (and, for Drive, an account).
    var isWellFormed: Bool {
        switch service {
        case .gist: return Self.isValidGistID(pageID) && account == nil
        case .googleDrive: return GoogleDriveMapping.isValidFileID(pageID) && account.map(Self.isValidAccount) == true
        }
    }

    /// What this Mac's permission to change the page is kept under: a gist by its ID, as always
    /// (permissions given before stay valid); a Drive page by its account and file, so editing the
    /// record can't point the permission at another account, and a gist and a Drive file can never
    /// stand for each other.
    var grantKey: String {
        switch service {
        case .gist: return pageID
        case .googleDrive: return "gdrive:" + (account ?? "") + "/" + pageID
        }
    }

    /// Gist IDs are letters and digits; anything else (a path, a scheme) is not one.
    static func isValidGistID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }
    }

    /// The shared page's address, made from its ID rather than taken from the history file (which
    /// anyone with the folder can edit): always a page on GitHub or Google Docs, never a file or an app.
    var pageURL: URL? {
        guard isWellFormed else { return nil }
        switch service {
        case .gist: return URL(string: "https://gist.github.com/\(pageID)")
        case .googleDrive: return GoogleDriveMapping.pageURL(fileID: pageID)
        }
    }
}

/// The Drive pages LP made, by Google account — kept on this Mac (not in any workspace), so
/// disconnecting an account can delete that account's pages first.
nonisolated struct DrivePageRegistry: Codable, Equatable, Sendable {
    private(set) var pages: [String: [String]] = [:]

    mutating func add(_ fileID: String, account: String) {
        guard GoogleDriveMapping.isValidFileID(fileID), !(pages[account] ?? []).contains(fileID) else { return }
        pages[account, default: []].append(fileID)
    }

    mutating func remove(_ fileID: String, account: String) {
        pages[account]?.removeAll { $0 == fileID }
        if pages[account]?.isEmpty == true { pages[account] = nil }
    }

    func pages(of account: String) -> [String] { pages[account] ?? [] }
}

/// Drive work on its way, per Google account, and the accounts being disconnected. Disconnecting
/// waits until nothing is on its way (a page still being made must be on the list to be deleted
/// with the others), and no new work starts for that account meanwhile.
nonisolated struct DriveWork: Equatable, Sendable {
    private(set) var running: [String: Int] = [:]
    private(set) var disconnecting: Set<String> = []

    /// Starts work for the account — unless it is being disconnected.
    mutating func begin(_ account: String) -> Bool {
        guard !disconnecting.contains(account) else { return false }
        running[account, default: 0] += 1
        return true
    }

    mutating func end(_ account: String) {
        guard let count = running[account] else { return }
        running[account] = count > 1 ? count - 1 : nil
    }

    func isRunning(_ account: String) -> Bool { running[account] != nil }

    mutating func startDisconnecting(_ account: String) { disconnecting.insert(account) }
    mutating func endDisconnecting(_ account: String) { disconnecting.remove(account) }
    func isDisconnecting(_ account: String) -> Bool { disconnecting.contains(account) }
}

/// Where someone can end a GitHub token's access, by the kind of token it is.
nonisolated enum GitHubTokenPages {
    static func accessPage(forToken token: String) -> URL {
        if token.hasPrefix("github_pat_") { return URL(string: "https://github.com/settings/personal-access-tokens")! }
        if token.hasPrefix("gho_") { return URL(string: "https://github.com/settings/applications")! }
        if token.hasPrefix("ghu_") { return URL(string: "https://github.com/settings/apps/authorizations")! }
        return URL(string: "https://github.com/settings/tokens")!
    }
}

/// Whether this Mac may change a board's shared page — the one decision behind every update or
/// deletion LP sends to GitHub or Google Drive. The share record comes from the board's history in
/// the folder, which anyone who had the folder could have written (and which a copy carries along),
/// so it counts only with a grant this Mac keeps for exactly that file, board and page: one LP made
/// when it published the page here, or one the person gave ("Keep It Updated From Here").
nonisolated enum ShareTrust {
    static func isTrusted(_ share: BoardShare?, boardIDInFile: String?, historyBoardID: String,
                          path: String, grants: Set<String>) -> Bool {
        guard let share, share.isWellFormed, boardIDInFile == historyBoardID else { return false }
        return grants.contains(ShareGrantKey.make(path: path, board: historyBoardID, page: share.grantKey))
    }
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
    /// The board file this history belongs to, so a copy of it made outside LP — which carries
    /// the same board ID — doesn't take it over.
    var path: String? = nil
    /// Whether that file carried the board ID when the history was last written. If it did, a
    /// file at the same path without the ID is another board, and doesn't take the history over.
    var fileHasID: Bool? = nil

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
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        fileHasID = try? container.decodeIfPresent(Bool.self, forKey: .fileHasID)
    }
}

/// One element of a list that may fail to decode on its own.
private nonisolated struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
