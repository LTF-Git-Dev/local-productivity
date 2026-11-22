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
    /// Why the board couldn't be read, when it couldn't. Such a board is never changed or
    /// saved, so an empty board can't replace a file LP failed to open.
    private(set) var readFailure: String?
    var shareError: String?
    /// A page the share error is about — one LP made but couldn't remove again — to open and
    /// delete by hand.
    var shareErrorPage: URL?
    /// Set when a change couldn't be written; the board on screen stays as it is on disk.
    var saveError: String?
    /// The card whose details are open.
    var openedCard: OpenedCard?
    /// Set for a board that was just created, so its name can be typed straight away.
    @ObservationIgnored var focusTitleOnAppear = false

    struct OpenedCard: Identifiable {
        let id: String
    }

    @ObservationIgnored private var lastWrittenText: String
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    /// Automatic tries since the last change after GitHub asked LP to slow down — a few, each
    /// waiting longer; then the next change (or Update Now) brings the page up to date.
    @ObservationIgnored private var shareRetries = 0
    private static let maxShareRetries = 3
    /// Set while the shared page is being deleted: nothing more is sent to it meanwhile.
    @ObservationIgnored private var isStoppingShare = false
    /// The window's undo manager, so undo can be cleared when the file changes elsewhere.
    @ObservationIgnored private weak var undoManager: UndoManager?

    /// `text` is nil when the file couldn't be read: the board then stays empty and unchangeable
    /// until `retryRead` succeeds.
    init(path: String, workspace: Workspace, text: String?) {
        self.path = path
        self.workspace = workspace
        lastWrittenText = text ?? ""
        guard let text else {
            board = BoardParser.parse("")
            log = BoardActivityLog(boardID: BoardStore.derivedID(for: path))
            readFailure = "LP couldn’t read this board’s file as text."
            return
        }
        var parsed = BoardParser.parse(text)
        let (opened, saved) = BoardStore.openHistory(of: &parsed, at: path, in: workspace)
        board = parsed
        log = opened
        // Opening a board writes nothing unless there is something new to remember.
        if opened != saved { saveLog() }
    }

    /// The history of the board in `parsed`, the file at `path`, brought up to date with it — and
    /// the history as it was saved, if there was one.
    private static func openHistory(of parsed: inout Board, at path: String, in workspace: Workspace)
        -> (history: BoardActivityLog, saved: BoardActivityLog?) {
        // The ID names the history file, so one that isn't plain is ignored rather than trusted.
        let stored = validID(parsed.boardID)
        let id = historyID(for: path, storedID: stored, in: workspace)
        // A copy's own history, never another file's.
        let saved = loadLog(id: id, root: workspace.rootURL).flatMap { log in
            id == stored || log.path == nil || log.path == path ? log : nil
        }
        var opened = saved ?? BoardActivityLog(boardID: id)
        // The history file is found by the checked ID; the one written inside it isn't trusted,
        // since it decides where the history is saved. It also records which file it belongs to.
        opened.boardID = id
        opened.path = path
        if let seen = opened.lastSeen {
            // Record what changed while the board was closed: in another app, or from Home.
            parsed.adoptIDs(from: seen)
            opened.record(BoardDiff.events(from: seen, to: parsed))
        }
        opened.lastSeen = parsed
        opened.noteCards(of: parsed)
        opened.snapshot(BoardProgress(board: parsed))
        return (opened, saved)
    }

    private static func validID(_ id: String?) -> String? {
        id.flatMap { BoardIDSafety.isValid($0) ? $0 : nil }
    }

    /// Reads a board that couldn't be read again. The caller replaces the store when it can.
    /// Board files are read as UTF-8 only: one in another encoding is left alone rather than
    /// written back with its special characters damaged.
    static func readText(at url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Reading

    var title: String { FileNode.title(of: path) }

    var icon: String? { FrontMatter.value(for: "icon", in: board.frontMatter) }

    var progress: BoardProgress { BoardProgress(board: board) }

    var share: BoardShare? { log.share }

    /// Whether this Mac may update or delete the board's shared page: it was published here, or
    /// the person allowed it (`trustShare`). A record found in the folder alone is not enough —
    /// it could point anywhere, including at another of the person's gists.
    var shareIsTrusted: Bool {
        ShareTrust.isTrusted(log.share, boardIDInFile: board.boardID, historyBoardID: log.boardID,
                             path: path, grants: workspace.authorizedShares)
    }

    /// The person allows this Mac to keep a shared page set up elsewhere up to date.
    func trustShare() {
        guard let share = log.share, share.isWellFormed else { return }
        let intended = log.boardID
        // The permission goes with the board's identity, so that has to be a lasting one, in its file.
        guard persistIdentity() else {
            // Said once, as a sharing problem.
            shareError = saveError ?? "The board couldn’t be saved, so this Mac can’t keep its page up to date."
            saveError = nil
            return
        }
        // Taking in the file can show it now holds another board: the permission was for this one.
        guard log.boardID == intended, log.share?.grantKey == share.grantKey else {
            shareError = Self.replacedWhileSharing
            return
        }
        workspace.authorizeShare(path: path, board: intended, page: share.grantKey)
        // This Mac now looks after the page: disconnecting its Google account here deletes it too.
        SharingServices.adopt(share)
        scheduleShareUpdate()
    }

    /// Writes the board's ID into its file if it isn't there yet (an imported board, or a copy
    /// made outside LP), so what is tied to it — a shared page — stays with this file. False when
    /// that can't be done.
    private func persistIdentity() -> Bool {
        guard readFailure == nil, catchUpWithDisk() != .unreadable else { return false }
        guard board.boardID == log.boardID || commit(board, from: board) else { return false }
        // ...and its history must say so on disk: one still recording "no ID in its file" would let
        // another board created at this path later take it over, with this page's permission.
        guard saveLog() else {
            saveError = "LP couldn’t save this board’s history in the workspace’s hidden .lp folder."
            return false
        }
        return true
    }

    /// Forgets a shared page this Mac didn't set up, without touching the page itself.
    func forgetShare() {
        guard !shareIsTrusted else { return }
        log.share = nil
        saveLog()
    }

    func lane(withID id: String) -> BoardLane? {
        board.lanes.first { $0.id == id }
    }

    func isDone(_ card: BoardCard) -> Bool {
        card.isDone || board.lane(containing: card.id)?.marksComplete == true
    }

    // MARK: Changing the board

    /// Applies a change, saves it, records what happened and registers undo. Returns false when
    /// the change couldn't be made (`saveError` says why), true when it was made or changed nothing.
    @discardableResult
    func perform(_ actionName: String, undoManager: UndoManager?, change: (inout Board) -> Void) -> Bool {
        guard readFailure == nil else { return false }
        if let undoManager { self.undoManager = undoManager }
        // A change another app made that hasn't arrived yet is read first, so this edit lands on
        // top of it instead of writing over it — and nothing is written over a file LP can't read.
        guard catchUpWithDisk() != .unreadable else {
            saveError = "The board’s file couldn’t be read to check for changes made elsewhere, so nothing was changed."
            return false
        }
        let before = board
        var after = board
        change(&after)
        guard after != before else { return true }
        guard commit(after, from: before) else { return false }
        undoManager?.registerUndo(withTarget: self) { store in
            store.restore(before, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        return true
    }

    private func restore(_ snapshot: Board, undoManager: UndoManager?, actionName: String) {
        // Putting back a whole earlier board would drop changes made elsewhere since.
        guard catchUpWithDisk() == .unchanged else { return }
        perform(actionName, undoManager: undoManager) { $0 = snapshot }
    }

    /// Moves cards to a list, before a given card or at the end (see `Board.moveCards`).
    func move(_ cardIDs: [String], toLane laneID: String, before targetID: String?, undoManager: UndoManager?) {
        perform(cardIDs.count == 1 ? "Move Card" : "Move Cards", undoManager: undoManager) { board in
            board.moveCards(cardIDs, toLane: laneID, before: targetID)
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
        // Nil when it wasn't added (the list is gone, or the board couldn't be saved).
        return board.allCards.contains { $0.id == id } ? id : nil
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

    /// Applies what the card sheet changed as a single undoable edit, on top of the card as it is
    /// at that moment. Returns false when it couldn't be saved.
    @discardableResult
    /// Whether the board is still the one `identity` names, after taking in changes made
    /// elsewhere. A card sheet checks this before it changes anything: the file can be replaced by
    /// another board while the sheet is open, and what the sheet holds was meant for this one.
    func isStill(_ identity: String) -> Bool {
        _ = catchUpWithDisk()
        guard log.boardID == identity else {
            saveError = "Another board replaced this one’s file in another app, so this card wasn’t changed."
            return false
        }
        return true
    }

    func editCard(_ cardID: String, _ edit: CardEdit, undoManager: UndoManager?) -> Bool {
        var found = false
        let made = perform("Edit Card", undoManager: undoManager) { board in
            guard let from = board.lanes.firstIndex(where: { $0.cards.contains { $0.id == cardID } }),
                  let index = board.lanes[from].cards.firstIndex(where: { $0.id == cardID }) else { return }
            found = true
            var card = edit.applied(to: board.lanes[from].cards[index])
            guard let laneID = edit.laneID, let to = board.lanes.firstIndex(where: { $0.id == laneID }), to != from else {
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
        guard made else { return false }
        guard found else {
            saveError = "This card was archived or deleted in another app, so these changes couldn’t be saved."
            return false
        }
        return true
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

    /// False when it couldn't be written (`saveError` says why).
    @discardableResult
    func archive(_ cardID: String, undoManager: UndoManager?) -> Bool {
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

    /// False when it couldn't be written (`saveError` says why).
    @discardableResult
    func delete(_ cardID: String, undoManager: UndoManager?) -> Bool {
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

    /// Writes the changed board. Only once it is on disk does it become the board on screen,
    /// with its history and shared page updated; a change that couldn't be written leaves all
    /// of them as they were.
    private func commit(_ after: Board, from before: Board) -> Bool {
        var updated = after
        // Give the board a lasting identity the first time LP saves it — or its own, when the file
        // carried another board's (a copy made outside LP).
        if updated.boardID != log.boardID {
            updated.frontMatter = BoardParser.frontMatter(updated.frontMatter, setting: "lp-board", to: log.boardID)
            // Only if it will read back that way: otherwise the history and sharing tied to it
            // would belong to no file.
            guard updated.boardID == log.boardID else {
                saveError = "LP couldn’t record this board’s identity in its file, so the change wasn’t made."
                return false
            }
        }
        let text = BoardParser.serialize(updated)
        // Written, it must still be a board: a longer front matter line can push the plugin's
        // marker out of the part LP looks at, and the file would open as a page from then on.
        guard BoardParser.isBoard(text) else {
            saveError = "This change would stop LP recognising the file as a board, so it wasn’t made."
            return false
        }
        do {
            try SafeFileWriter.write(Data(text.utf8), to: workspace.url(for: path))
        } catch {
            saveError = "The change couldn’t be written to the board’s file, so it wasn’t made. \(error.localizedDescription)"
            return false
        }
        saveError = nil
        lastWrittenText = text
        board = updated
        record(BoardDiff.events(from: before, to: updated))
        return true
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
        _ = catchUpWithDisk()
    }

    private enum DiskCheck {
        case unchanged, changed, unreadable
    }

    /// Takes in changes made to the file elsewhere. Undo is cleared then, since undoing would put
    /// back a board without those changes.
    private func catchUpWithDisk() -> DiskCheck {
        guard readFailure == nil, let text = Self.readText(at: workspace.url(for: path)) else { return .unreadable }
        guard text != lastWrittenText else { return .unchanged }
        lastWrittenText = text
        var fresh = BoardParser.parse(text)
        let before = board
        let freshID = Self.validID(fresh.boardID)
        if freshID != Self.validID(before.boardID),
           Self.historyID(for: path, storedID: freshID, in: workspace) != log.boardID {
            // The file now holds another board (it was replaced in another app): from here on it is
            // that board, with that board's history and sharing. This board's stay with its history,
            // and the next save doesn't write this board's ID over the newcomer's — so nothing on
            // either can reach the other's shared page.
            let (opened, saved) = Self.openHistory(of: &fresh, at: path, in: workspace)
            board = fresh
            log = opened
            if opened != saved { saveLog() }
        } else {
            fresh.adoptIDs(from: board)
            board = fresh
            record(BoardDiff.events(from: before, to: fresh))
        }
        if let undoManager {
            if undoManager.isUndoing || undoManager.isRedoing {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    undoManager.removeAllActions(withTarget: self)
                }
            } else {
                undoManager.removeAllActions(withTarget: self)
            }
        }
        return .changed
    }

    func pathDidChange(to newPath: String) {
        // Before moving it, the workspace wrote the board's identity into its file and moved its
        // sharing permission: take the file in, and record where the history belongs now.
        path = newPath
        _ = catchUpWithDisk()
        saveLog()
        scheduleShareUpdate()
    }

    // MARK: Activity log

    static func logURL(id: String, root: URL) -> URL {
        root.appendingPathComponent(".lp/boards", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private static func loadLog(id: String, root: URL) -> BoardActivityLog? {
        guard let data = try? Data(contentsOf: logURL(id: id, root: root)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BoardActivityLog.self, from: data)
    }

    @discardableResult
    private func saveLog() -> Bool {
        guard readFailure == nil, BoardIDSafety.isValid(log.boardID) else { return false }
        // A history is written under an ID only once the board can be found by it again: the one
        // in its file, or — for a board LP hasn't saved — the one made from its path. A copy made
        // outside LP, or another board now at the path a board was moved from, goes by an ID of
        // its own that is written into its file the first time LP saves it (or shares or moves
        // it); until then nothing is written, so that ID stays one no history uses.
        let inFile = board.boardID.flatMap { BoardIDSafety.isValid($0) ? $0 : nil }
        guard inFile == log.boardID || (inFile == nil && log.boardID == Self.derivedID(for: path)) else { return false }
        log.fileHasID = inFile != nil
        let url = Self.logURL(id: log.boardID, root: workspace.rootURL)
        // `.lp` could be a link to somewhere else; history is only written inside the workspace.
        guard PathSafety.resolvesInside(url, root: workspace.rootURL) else { return false }
        log.path = path
        return Self.write(log, to: url)
    }

    private static func write(_ log: BoardActivityLog, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(log) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// The ID a board's history goes by. Usually the one stored in its file — but a copy of
    /// another board made outside LP carries that board's ID, and gets one of its own (written
    /// into it the next time LP saves it), so nothing on the copy reaches the other board's
    /// history or shared page. A file is a copy when the history belongs to another board file
    /// with the same ID, or — when the history doesn't say (or there is none yet) — when an older
    /// board file has that ID. A board with no stored ID goes by one made from its path.
    static func historyID(for path: String, storedID: String?, in workspace: Workspace) -> String {
        let root = workspace.rootURL
        guard let stored = storedID else {
            // A board LP hasn't saved goes by an ID made from its path — unless the history under
            // that ID is another file's: one written while its file carried the ID (this file
            // doesn't, so it is another board now at that path), or one recorded for another path.
            // A history from before histories recorded their file is another's when another board
            // file carries the ID.
            let derived = derivedID(for: path)
            // A board this Mac shares had that ID written into its file first: this file, without
            // it, is another one — whatever an older LP left in the history.
            if workspace.hasShareGrant(board: derived) { return ownID(for: path, avoiding: derived, root: root) }
            guard let log = loadLog(id: derived, root: root) else { return derived }
            let isMine = log.path.map { $0 == path && log.fileHasID != true }
                ?? (workspace.otherBoard(withID: derived, than: path) == nil)
            return isMine ? derived : ownID(for: path, avoiding: derived, root: root)
        }
        let owner = loadLog(id: stored, root: root)?.path
        // The owner's path can be another spelling of this very file (a case-only rename in Finder
        // on a case-insensitive volume): that isn't a copy.
        let isCopy = owner.map { !workspace.isSameFile($0, path) && workspace.boardID(at: $0) == stored }
            ?? (workspace.olderBoard(withID: stored, than: path) != nil)
        return isCopy ? ownID(for: path, avoiding: stored, root: root) : stored
    }

    /// An ID of its own for a board that can't go by the one it would otherwise have, and that
    /// nothing has used: a history under a candidate belongs to some earlier file — even one that
    /// was at this path and has been moved away — so it is never taken over. (Its history is only
    /// written once the ID is in its file; see `saveLog`.)
    private static func ownID(for path: String, avoiding taken: String, root: URL) -> String {
        for attempt in 0..<8 {
            let candidate = derivedID(for: path + "\u{0}copy" + (attempt == 0 ? "" : String(attempt)))
            guard candidate != taken, !FileManager.default.fileExists(atPath: logURL(id: candidate, root: root).path) else { continue }
            return candidate
        }
        return BoardIDs.newBoardID()
    }

    /// The file board `id`'s history records it belongs to, as written — nil when there is no
    /// history LP can read.
    static func historyOwner(id: String, root: URL) -> (path: String?, fileHasID: Bool?)? {
        guard BoardIDSafety.isValid(id), let log = loadLog(id: id, root: root) else { return nil }
        return (log.path, log.fileHasID)
    }

    /// Records the file board `id`'s history belongs to (LP moving the board, or putting that back).
    /// False when it can't be written — then the move doesn't happen.
    static func setHistoryOwner(id: String, root: URL, path: String?, fileHasID: Bool?) -> Bool {
        let url = logURL(id: id, root: root)
        guard BoardIDSafety.isValid(id), PathSafety.resolvesInside(url, root: root),
              var log = loadLog(id: id, root: root) else { return false }
        log.boardID = id
        log.path = path
        log.fileHasID = fileHasID
        return write(log, to: url)
    }

    /// A stable identity for a board that does not have one in its front matter yet.
    static func derivedID(for path: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "b" + String(hash, radix: 36)
    }

    // MARK: Sharing

    /// What a shared page shows (GitHub gets it as Markdown, Google Drive as a document).
    private var reportInput: BoardReport.Input {
        BoardReport.Input(title: title, icon: icon, board: board, log: log)
    }

    private static let replacedWhileSharing =
        "Another board replaced this one’s file in another app, so nothing was shared. Look at the board again first."

    /// Publishes the progress page for the first time, at `destination`.
    func publish(to destination: ShareDestination) async {
        let intended = log.boardID
        // A shared page is tied to the board's identity, so a board without a lasting one in its
        // file (an imported board, or a copy made outside LP) gets it first.
        guard persistIdentity() else {
            // Said once, as a sharing problem.
            shareError = saveError ?? "The board couldn’t be saved, so it wasn’t shared."
            saveError = nil
            return
        }
        // Taking in the file can show it now holds another board: what was asked for was this one.
        guard log.boardID == intended else {
            shareError = Self.replacedWhileSharing
            return
        }
        isPublishing = true
        shareError = nil
        shareErrorPage = nil
        defer { isPublishing = false }
        let identity = log.boardID
        do {
            let share = try await SharingServices.create(destination, title: title, input: reportInput)
            // The file was replaced by another board meanwhile: the new page isn't tied to that one,
            // so it doesn't stay online either.
            guard log.boardID == identity else {
                do {
                    try await SharingServices.delete(share)
                    shareError = "The board’s file was replaced by another board while it was being shared, so the new page was removed again."
                } catch {
                    // Said as it is: the page is still online, and the alert opens it.
                    shareErrorPage = share.pageURL
                    var reason = error.localizedDescription
                    if !reason.hasSuffix(".") { reason += "." }
                    let place = share.service == .gist
                        ? "The page is still on GitHub: open it to delete it there."
                        : "The page is still in your Google Drive: open it to delete it there, or disconnect that Google account, which deletes it too."
                    shareError = "The board’s file was replaced by another board while it was being shared, and LP couldn’t remove the new page again. \(reason) \(place)"
                }
                return
            }
            workspace.authorizeShare(path: path, board: identity, page: share.grantKey)
            log.share = share
            // The link lives only in the board's history: if that can't be written, the page would
            // stay online with nothing in LP pointing at it — so it comes down again.
            guard saveLog() else {
                log.share = nil
                workspace.revokeShare(path: path, board: identity, page: share.grantKey)
                do {
                    try await SharingServices.delete(share)
                    shareError = "LP couldn’t save the shared page’s link with the board (its .lp folder can’t be written), so the page was removed again."
                } catch {
                    shareErrorPage = share.pageURL
                    var reason = error.localizedDescription
                    if !reason.hasSuffix(".") { reason += "." }
                    let place = share.service == .gist
                        ? "The page is still on GitHub: open it to delete it there."
                        : "The page is still in your Google Drive: open it to delete it there, or disconnect that Google account, which deletes it too."
                    shareError = "LP couldn’t save the shared page’s link with the board (its .lp folder can’t be written), and couldn’t remove the page again. \(reason) \(place)"
                }
                return
            }
        } catch {
            shareError = error.localizedDescription
        }
    }

    func updateSharedPage() async {
        guard let share = log.share, shareIsTrusted, !isStoppingShare else { return }
        isPublishing = true
        shareError = nil
        shareErrorPage = nil
        defer { isPublishing = false }
        do {
            var updated = try await SharingServices.update(share, title: title, input: reportInput)
            // Sharing stopped, or its settings changed, while this was on its way: those win.
            guard let current = log.share, current.grantKey == share.grantKey else { return }
            updated.updatesAutomatically = current.updatesAutomatically
            log.share = updated
            saveLog()
            shareRetries = 0
        } catch CalendarSyncError.notFound {
            // The page was deleted on GitHub or in Drive.
            if log.share?.grantKey == share.grantKey {
                workspace.revokeShare(path: path, board: log.boardID, page: share.grantKey)
                log.share = nil
                saveLog()
            }
        } catch {
            shareError = error.localizedDescription
            // The service asked LP to wait: the page is brought up to date once it may be — a few
            // times at most, then with the next change.
            if SharingServices.isRateLimited(error) {
                if shareRetries < Self.maxShareRetries {
                    shareRetries += 1
                    scheduleShareUpdate(retrying: true)
                    if log.share?.updatesAutomatically == true {
                        shareError = error.localizedDescription + " LP brings the page up to date by itself then."
                    }
                } else {
                    let service = share.service == .gist ? "GitHub" : "Google"
                    shareError = "\(service) keeps asking LP to slow down, so automatic updates are paused. Your next change — or Update Now — brings the page up to date."
                }
            }
        }
    }

    func stopSharing() async {
        guard let share = log.share, shareIsTrusted, !isStoppingShare else { return }
        shareTask?.cancel()
        shareTask = nil
        // Nothing more goes to the page while it is deleted — and if that fails, automatic updates
        // stay off, as the person asked for the sharing to stop.
        isStoppingShare = true
        log.share?.updatesAutomatically = false
        saveLog()
        isPublishing = true
        defer {
            isPublishing = false
            isStoppingShare = false
        }
        let identity = log.boardID
        do {
            try await SharingServices.delete(share)
            forgetStoppedShare(share, identity: identity)
        } catch DriveSharingError.notConnected {
            // Its Google account was disconnected (its pages are removed then, unless that wasn't
            // possible): LP lets go of the page and says where it may still be.
            forgetStoppedShare(share, identity: identity)
            shareError = "LP has let go of this page. Its Google account isn’t connected any more, so if the page wasn’t removed then, it is still in that account’s Google Drive — delete it there."
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func forgetStoppedShare(_ share: BoardShare, identity: String) {
        workspace.revokeShare(path: path, board: identity, page: share.grantKey)
        // Only if it is still this board's page (the file can be replaced meanwhile).
        if log.boardID == identity, log.share?.grantKey == share.grantKey {
            log.share = nil
            saveLog()
        }
    }

    func setUpdatesAutomatically(_ value: Bool) {
        log.share?.updatesAutomatically = value
        saveLog()
        if value {
            scheduleShareUpdate()
        } else {
            // A queued update would publish changes made after this.
            shareTask?.cancel()
            shareTask = nil
        }
    }

    /// Keeps the shared page current, waiting for a pause so a burst of changes is one update.
    private func scheduleShareUpdate(retrying: Bool = false) {
        guard let share = log.share, share.updatesAutomatically, shareIsTrusted, !isStoppingShare, SharingServices.isReady(share) else { return }
        if !retrying { shareRetries = 0 }
        shareTask?.cancel()
        // After a "slow down" each try waits longer (8, 16, 32 s) — and never goes before the
        // service said it may.
        let backoff = retrying ? 4 * pow(2, Double(shareRetries)) : 4
        let delay = max(backoff, (SharingServices.pausedUntil(share)?.timeIntervalSinceNow ?? 0) + 1)
        // The store is held weakly on purpose: a store kept alive after the board was left (and
        // perhaps reopened as a new store) could send an old copy and overwrite newer settings.
        shareTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // Automatic updates may have been turned off, or sharing stopped, while it waited.
            guard !Task.isCancelled, let self, self.log.share?.updatesAutomatically == true, self.shareIsTrusted,
                  !self.isStoppingShare else { return }
            await self.updateSharedPage()
        }
    }

    // MARK: Export

    func exportHTML(to url: URL) throws {
        let html = BoardReport.html(BoardReport.Input(title: title, icon: icon, board: board, log: log))
        try Data(html.utf8).write(to: url, options: .atomic)
    }
}
