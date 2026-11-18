//
//  BoardStore.swift
//  LP
//
//  Owns one open board: reads the file, applies changes, saves straight away, and keeps
//  the board's activity log and shared progress page up to date. Changes made in another
//  app (Obsidian, a sync service) are picked up and recorded too.
//

import AppKit
import Foundation

@Observable
final class BoardStore {

    let workspace: Workspace
    private(set) var path: String
    private(set) var board: Board
    private(set) var log: BoardActivityLog
    private(set) var isPublishing = false
    var shareError: String?
    /// The card whose details are open.
    var openedCard: OpenedCard?
    /// Set for a board that was just created, so its name can be typed straight away.
    @ObservationIgnored var focusTitleOnAppear = false

    struct OpenedCard: Identifiable {
        let id: String
    }

    @ObservationIgnored private var lastWrittenText: String
    @ObservationIgnored private var shareTask: Task<Void, Never>?

    init(path: String, workspace: Workspace, text: String) {
        self.path = path
        self.workspace = workspace
        lastWrittenText = text
        var parsed = BoardParser.parse(text)
        // The ID names the history file, so one that isn't plain is ignored rather than trusted.
        let id = parsed.boardID.flatMap { BoardIDSafety.isValid($0) ? $0 : nil } ?? BoardStore.derivedID(for: path)
        let saved = BoardStore.loadLog(id: id, root: workspace.rootURL)
        var opened = saved ?? BoardActivityLog(boardID: id)
        if let seen = opened.lastSeen {
            // Record what changed while the board was closed: in another app, or from Home.
            parsed.adoptIDs(from: seen)
            opened.record(BoardDiff.events(from: seen, to: parsed))
        }
        opened.lastSeen = parsed
        opened.noteCards(of: parsed)
        opened.snapshot(BoardProgress(board: parsed))
        board = parsed
        log = opened
        // Opening a board writes nothing unless there is something new to remember.
        if opened != saved { saveLog() }
    }

    // MARK: Reading

    var title: String { FileNode.title(of: path) }

    var icon: String? { FrontMatter.value(for: "icon", in: board.frontMatter) }

    var progress: BoardProgress { BoardProgress(board: board) }

    var share: BoardShare? { log.share }

    func lane(withID id: String) -> BoardLane? {
        board.lanes.first { $0.id == id }
    }

    func isDone(_ card: BoardCard) -> Bool {
        card.isDone || board.lane(containing: card.id)?.marksComplete == true
    }

    // MARK: Changing the board

    /// Applies a change, saves it, records what happened and registers undo.
    func perform(_ actionName: String, undoManager: UndoManager?, change: (inout Board) -> Void) {
        let before = board
        var after = board
        change(&after)
        guard after != before else { return }
        commit(after, from: before)
        undoManager?.registerUndo(withTarget: self) { store in
            store.restore(before, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func restore(_ snapshot: Board, undoManager: UndoManager?, actionName: String) {
        perform(actionName, undoManager: undoManager) { $0 = snapshot }
    }

    /// Moves cards to a list, before a given card or at the end. Moving into a Complete list
    /// marks the cards done; moving out of one marks them not done, as in Obsidian.
    func move(_ cardIDs: [String], toLane laneID: String, before targetID: String?, undoManager: UndoManager?) {
        perform(cardIDs.count == 1 ? "Move Card" : "Move Cards", undoManager: undoManager) { board in
            var moving: [BoardCard] = []
            var origins: [String: Bool] = [:]
            for laneIndex in board.lanes.indices {
                let marksComplete = board.lanes[laneIndex].marksComplete
                board.lanes[laneIndex].cards.removeAll { card in
                    guard cardIDs.contains(card.id) else { return false }
                    moving.append(card)
                    origins[card.id] = marksComplete
                    return true
                }
            }
            // Keep the order the cards were asked for.
            moving.sort { (cardIDs.firstIndex(of: $0.id) ?? 0) < (cardIDs.firstIndex(of: $1.id) ?? 0) }
            guard let destination = board.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            let completes = board.lanes[destination].marksComplete
            for index in moving.indices {
                if completes {
                    moving[index].isDone = true
                } else if origins[moving[index].id] == true {
                    moving[index].isDone = false
                }
            }
            let insertAt = targetID.flatMap { id in board.lanes[destination].cards.firstIndex { $0.id == id } }
                ?? board.lanes[destination].cards.endIndex
            board.lanes[destination].cards.insert(contentsOf: moving, at: insertAt)
        }
    }

    /// Moves a card one list left (`-1`) or right (`+1`), for keyboard and VoiceOver users.
    func shift(_ cardID: String, by offset: Int, undoManager: UndoManager?) {
        guard let current = board.lanes.firstIndex(where: { $0.cards.contains { $0.id == cardID } }) else { return }
        let target = current + offset
        guard board.lanes.indices.contains(target) else { return }
        move([cardID], toLane: board.lanes[target].id, before: nil, undoManager: undoManager)
    }

    @discardableResult
    func addCard(_ text: String, toLane laneID: String, undoManager: UndoManager?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = BoardIDs.newCardID()
        perform("Add Card", undoManager: undoManager) { board in
            guard let index = board.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            board.lanes[index].cards.append(BoardCard(id: id, text: trimmed, body: "", isDone: board.lanes[index].marksComplete))
        }
        return id
    }

    func updateCard(_ cardID: String, text: String, body: String, undoManager: UndoManager?) {
        perform("Edit Card", undoManager: undoManager) { board in
            for laneIndex in board.lanes.indices {
                if let cardIndex = board.lanes[laneIndex].cards.firstIndex(where: { $0.id == cardID }) {
                    board.lanes[laneIndex].cards[cardIndex].text = text
                    board.lanes[laneIndex].cards[cardIndex].body = body
                }
            }
        }
    }

    /// Applies everything the card sheet changed as a single undoable edit.
    func editCard(_ cardID: String, text: String, body: String, isDone: Bool, laneID: String, undoManager: UndoManager?) {
        perform("Edit Card", undoManager: undoManager) { board in
            guard let from = board.lanes.firstIndex(where: { $0.cards.contains { $0.id == cardID } }),
                  let index = board.lanes[from].cards.firstIndex(where: { $0.id == cardID }) else { return }
            var card = board.lanes[from].cards[index]
            card.text = text
            card.body = body
            card.isDone = isDone
            guard let to = board.lanes.firstIndex(where: { $0.id == laneID }), to != from else {
                board.lanes[from].cards[index] = card
                return
            }
            // Moving between lists follows the same rule as dragging.
            board.lanes[from].cards.remove(at: index)
            if board.lanes[to].marksComplete {
                card.isDone = true
            } else if board.lanes[from].marksComplete {
                card.isDone = false
            }
            board.lanes[to].cards.append(card)
        }
    }

    func setDone(_ cardID: String, _ done: Bool, undoManager: UndoManager?) {
        perform(done ? "Mark Done" : "Mark Not Done", undoManager: undoManager) { board in
            for laneIndex in board.lanes.indices {
                if let cardIndex = board.lanes[laneIndex].cards.firstIndex(where: { $0.id == cardID }) {
                    board.lanes[laneIndex].cards[cardIndex].isDone = done
                }
            }
        }
    }

    func archive(_ cardID: String, undoManager: UndoManager?) {
        perform("Archive Card", undoManager: undoManager) { board in
            for laneIndex in board.lanes.indices {
                if let cardIndex = board.lanes[laneIndex].cards.firstIndex(where: { $0.id == cardID }) {
                    var card = board.lanes[laneIndex].cards.remove(at: cardIndex)
                    card.isDone = card.isDone || board.lanes[laneIndex].marksComplete
                    board.archive.append(card)
                }
            }
        }
    }

    func delete(_ cardID: String, undoManager: UndoManager?) {
        perform("Delete Card", undoManager: undoManager) { board in
            for laneIndex in board.lanes.indices { board.lanes[laneIndex].cards.removeAll { $0.id == cardID } }
            board.archive.removeAll { $0.id == cardID }
        }
    }

    func addLane(_ title: String, undoManager: UndoManager?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform("Add List", undoManager: undoManager) { board in
            board.lanes.append(BoardLane(id: "lane-new-\(UUID().uuidString.prefix(8))", title: trimmed, marksComplete: false, cards: []))
        }
    }

    func renameLane(_ laneID: String, to title: String, undoManager: UndoManager?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform("Rename List", undoManager: undoManager) { board in
            if let index = board.lanes.firstIndex(where: { $0.id == laneID }) { board.lanes[index].title = trimmed }
        }
    }

    func setMarksComplete(_ laneID: String, _ value: Bool, undoManager: UndoManager?) {
        perform(value ? "Mark List as Complete" : "Unmark List as Complete", undoManager: undoManager) { board in
            guard let index = board.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            board.lanes[index].marksComplete = value
            for card in board.lanes[index].cards.indices { board.lanes[index].cards[card].isDone = value }
        }
    }

    func moveLane(_ laneID: String, by offset: Int, undoManager: UndoManager?) {
        perform("Move List", undoManager: undoManager) { board in
            guard let index = board.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            let target = index + offset
            guard board.lanes.indices.contains(target) else { return }
            board.lanes.swapAt(index, target)
        }
    }

    /// Removes a list. Its cards are archived rather than lost.
    func deleteLane(_ laneID: String, undoManager: UndoManager?) {
        perform("Delete List", undoManager: undoManager) { board in
            guard let index = board.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            let lane = board.lanes.remove(at: index)
            board.archive.append(contentsOf: lane.cards.map { card in
                var archived = card
                archived.isDone = card.isDone || lane.marksComplete
                return archived
            })
        }
    }

    func setIcon(_ icon: String?) {
        perform("Change Icon", undoManager: nil) { board in
            board.frontMatter = FrontMatter.setting(icon, for: "icon", in: board.frontMatter) ?? ""
        }
        workspace.noteIconChanged(icon, for: path)
    }

    // MARK: Saving

    private func commit(_ after: Board, from before: Board) {
        var updated = after
        // Give the board a lasting identity the first time LP saves it.
        if updated.boardID.map(BoardIDSafety.isValid) != true {
            updated.frontMatter = BoardParser.frontMatter(updated.frontMatter, setting: "lp-board", to: log.boardID)
        }
        board = updated

        let text = BoardParser.serialize(updated)
        do {
            try SafeFileWriter.write(Data(text.utf8), to: workspace.url(for: path))
            lastWrittenText = text
        } catch {
            shareError = "Couldn’t save the board: \(error.localizedDescription)"
        }
        record(BoardDiff.events(from: before, to: updated))
    }

    private func record(_ events: [BoardEvent]) {
        log.record(events)
        log.lastSeen = board
        log.noteCards(of: board)
        log.snapshot(progress)
        saveLog()
        if !events.isEmpty { scheduleShareUpdate() }
    }

    /// The file changed outside LP: read it again and record what changed.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: workspace.url(for: path)) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard text != lastWrittenText else { return }
        lastWrittenText = text
        var fresh = BoardParser.parse(text)
        fresh.adoptIDs(from: board)
        let before = board
        board = fresh
        record(BoardDiff.events(from: before, to: fresh))
    }

    func pathDidChange(to newPath: String) {
        path = newPath
        // A board LP has never saved is known by its path. Carry its history to the new name.
        if board.boardID.map(BoardIDSafety.isValid) != true {
            let oldURL = Self.logURL(id: log.boardID, root: workspace.rootURL)
            log.boardID = Self.derivedID(for: newPath)
            try? FileManager.default.removeItem(at: oldURL)
            saveLog()
        }
        scheduleShareUpdate()
    }

    // MARK: Activity log

    private static func logURL(id: String, root: URL) -> URL {
        root.appendingPathComponent(".lp/boards", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private static func loadLog(id: String, root: URL) -> BoardActivityLog? {
        guard let data = try? Data(contentsOf: logURL(id: id, root: root)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BoardActivityLog.self, from: data)
    }

    private func saveLog() {
        let url = Self.logURL(id: log.boardID, root: workspace.rootURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// A stable identity for a board that does not have one in its front matter yet.
    private static func derivedID(for path: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "b" + String(hash, radix: 36)
    }

    // MARK: Sharing

    private var report: String {
        BoardReport.markdown(BoardReport.Input(title: title, icon: icon, board: board, log: log))
    }

    private var shareFileName: String {
        (Workspace.sanitized(title) ?? "Board") + " — Progress.md"
    }

    private var shareDescription: String {
        "\(title) — progress shared from LP"
    }

    /// Publishes the progress page for the first time.
    func publish() async {
        isPublishing = true
        shareError = nil
        defer { isPublishing = false }
        do {
            log.share = try await GistPublisher.create(fileName: shareFileName, content: report, description: shareDescription)
            saveLog()
        } catch {
            shareError = error.localizedDescription
        }
    }

    func updateSharedPage() async {
        guard let share = log.share else { return }
        isPublishing = true
        shareError = nil
        defer { isPublishing = false }
        do {
            var updated = try await GistPublisher.update(share, fileName: shareFileName, content: report, description: shareDescription)
            updated.updatesAutomatically = share.updatesAutomatically
            log.share = updated
            saveLog()
        } catch CalendarSyncError.notFound {
            // The gist was deleted on GitHub.
            log.share = nil
            saveLog()
        } catch {
            shareError = error.localizedDescription
        }
    }

    func stopSharing() async {
        guard let share = log.share else { return }
        isPublishing = true
        defer { isPublishing = false }
        do {
            try await GistPublisher.delete(share)
            log.share = nil
            saveLog()
        } catch {
            shareError = error.localizedDescription
        }
    }

    func setUpdatesAutomatically(_ value: Bool) {
        log.share?.updatesAutomatically = value
        saveLog()
        if value { scheduleShareUpdate() }
    }

    /// Keeps the shared page current, waiting for a pause so a burst of changes is one update.
    private func scheduleShareUpdate() {
        guard let share = log.share, share.updatesAutomatically, GistPublisher.hasToken else { return }
        shareTask?.cancel()
        shareTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.updateSharedPage()
        }
    }

    // MARK: Export

    func exportHTML(to url: URL) throws {
        let html = BoardReport.html(BoardReport.Input(title: title, icon: icon, board: board, log: log))
        try Data(html.utf8).write(to: url, options: .atomic)
    }
}
