//
//  AppModel.swift
//  Local Productivity
//
//  The root of the app's state: which workspace is open, what is on screen, and the
//  navigation history. Views read from it and call its methods; nothing else decides
//  where the app goes next.
//

import AppKit
import SwiftUI

/// A place the main area can show.
nonisolated enum Route: Hashable, Sendable {
    case home
    case calendar
    /// Every board in the workspace.
    case boards
    case page(String)
    case folder(String)
    case board(String)

    /// The workspace-relative path this route points at, if any.
    var path: String? {
        switch self {
        case .page(let path), .folder(let path), .board(let path): return path
        default: return nil
        }
    }

    func rebased(from old: String, to new: String) -> Route {
        switch self {
        case .page(let path): return .page(FileNode.rebased(path, from: old, to: new) ?? path)
        case .folder(let path): return .folder(FileNode.rebased(path, from: old, to: new) ?? path)
        case .board(let path): return .board(FileNode.rebased(path, from: old, to: new) ?? path)
        default: return self
        }
    }
}

/// Opens the event editor for a new event on a day, or for an existing event.
struct EventEditorRequest: Identifiable {
    enum Mode {
        case new(Day)
        case edit(SyncEvent)
    }

    let id = UUID()
    var mode: Mode
}

/// Opens the new board sheet, suggesting a folder.
struct NewBoardRequest: Identifiable {
    let id = UUID()
    var folder: String
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// A file the message is about, offered with Show in Finder.
    var file: URL? = nil
}

@Observable
final class AppModel {

    let settings: AppSettings
    let library: WorkspaceLibrary
    /// Connected calendar accounts. Calendars belong to the app, not to a workspace.
    let calendarSync: CalendarSyncStore
    /// Reminders for due tasks, upcoming events and the day ahead.
    let reminders: ReminderCenter
    /// New versions of LP from its GitHub Releases.
    let updater: Updater

    private(set) var workspace: Workspace?
    private(set) var route: Route = .home
    private(set) var session: PageSession?
    /// The open board, when the route is a board.
    private(set) var boardStore: BoardStore?
    /// Whether the open board shows its progress panel.
    var showsBoardProgress = false
    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []

    var isPaletteVisible = false
    /// Text the search palette should open with, consumed when it appears.
    var paletteSeed = ""
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var alert: AlertMessage?
    /// A link that would open another app, waiting for the user to confirm.
    var pendingExternalLink: URL?
    #if DEBUG
    /// Lets the snapshot harness see what a link would do without opening anything.
    @ObservationIgnored var linkHook: ((String, URL) -> Void)?
    #endif
    /// The sidebar row currently being renamed in place.
    var renamingPath: String?

    var calendarMonth = Day.today.startOfMonth
    var calendarSelection = Day.today
    /// The event being created or edited, when the event editor is open.
    var eventEditor: EventEditorRequest?
    /// The board being set up, when the new board sheet is open.
    var newBoardRequest: NewBoardRequest?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var deactivationObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var glanceUpdate: Task<Void, Never>?
    @ObservationIgnored private let widgets = WidgetPublisher()

    /// Pass `nil` to run without touching saved preferences (previews and UI snapshots).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        settings = AppSettings(defaults: defaults)
        updater = Updater(defaults: defaults)
        library = WorkspaceLibrary(defaults: defaults)
        calendarSync = CalendarSyncStore(defaults: defaults)
        // Sharing reaches Google Drive through the accounts connected for the calendar.
        SharingServices.calendar = calendarSync
        SharingServices.defaults = defaults
        // Snapshots and previews plan reminders but never hand them to the system.
        reminders = ReminderCenter(dryRun: defaults == nil)

        settings.onRemindersChanged = { [weak self] in
            guard let self else { return }
            // The switch acts at once — off must not wait for the debounce (LP may be quit in it).
            if reminders.isOn != settings.remindersEnabled { reminders.setOn(settings.remindersEnabled) }
            scheduleGlanceUpdate()
        }
        calendarSync.onEventsChanged = { [weak self] in self?.scheduleGlanceUpdate() }
        reminders.onResponse = { [weak self] response in self?.handleReminder(response) }

        let center = NotificationCenter.default
        terminationObserver = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.session?.closeSavingChanges() }
        }
        deactivationObserver = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.session?.flush() }
        }
        // Coming back after a while (a new day, edits made in another app) plans again.
        activationObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleGlanceUpdate() }
        }
    }

    // MARK: Workspaces

    /// Reopens the workspace from the previous launch, when it is still reachable.
    func restoreLastWorkspace() {
        guard workspace == nil, let record = library.lastOpenRecord, let url = library.resolve(record) else { return }
        open(record, at: url)
    }

    /// Lets the user pick any folder to use as a workspace.
    func chooseWorkspace(startingAt directory: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Workspace Folder"
        panel.message = "Pick the folder that holds your Markdown notes. An empty folder works too."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(at: url)
    }

    func openWorkspace(at url: URL) {
        let record = library.register(url)
        // Resolve through the bookmark when possible so access survives a relaunch.
        open(record, at: library.resolve(record) ?? url)
    }

    /// Opens a remembered workspace, asking for the folder again if access has lapsed.
    func openWorkspace(_ record: WorkspaceRecord) {
        if let url = library.resolve(record) {
            open(record, at: url)
        } else {
            chooseWorkspace(startingAt: URL(fileURLWithPath: record.path))
        }
    }

    private func open(_ record: WorkspaceRecord, at url: URL) {
        guard closeWorkspace() else { return }
        library.markOpened(record)
        library.setLastOpen(record)

        let opened = Workspace(record: record, rootURL: url, defaults: defaults)
        opened.onMetaChanged = { [weak self] in self?.scheduleGlanceUpdate() }
        opened.onPathChanged = { [weak self] old, new in self?.pathChanged(from: old, to: new) }
        opened.onWillMove = { [weak self] path in self?.prepareForMove(path) ?? true }
        opened.onTreeChanged = { [weak self] in self?.validateRoute() }
        opened.onKeptCopy = { [weak self] message in self?.alert = message }
        opened.onPagesChangedOnDisk = { [weak self] paths in
            if let session = self?.session, paths.contains(session.path) { session.fileChangedOnDisk() }
            if let board = self?.boardStore, paths.contains(board.path) {
                if board.readFailure != nil { self?.retryBoard() } else { board.reloadFromDisk() }
            }
        }
        workspace = opened
        backStack = []
        forwardStack = []
        pendingRoute = savedRoute(for: record)
        setRoute(.home)
        opened.start()
    }

    /// Returns false when the open page's edits could be neither saved nor kept, so it stays open.
    @discardableResult
    func closeWorkspace() -> Bool {
        guard let current = workspace else { return true }
        guard leavePage() else { return false }
        session = nil
        boardStore = nil
        current.stop()
        library.stopAccessing(current.record)
        library.setLastOpen(nil)
        workspace = nil
        route = .home
        backStack = []
        forwardStack = []
        isPaletteVisible = false
        // Reminders belong to the workspace they came from.
        glanceUpdate?.cancel()
        reminders.update(with: [])
        return true
    }

    /// Leaves the open page: its edits are saved or kept as a copy. When neither works the page
    /// stays open — returns false — and an alert says why.
    private func leavePage() -> Bool {
        guard let session, !session.closeSavingChanges() else { return true }
        alert = AlertMessage(title: "Couldn’t Save “\(session.title)”",
                             message: "Your changes couldn’t be written to the page or kept as a copy, so the page stays open. Copy them somewhere safe before closing it.")
        return false
    }

    /// Before the workspace moves `path`: the page open there saves its edits first (false if it
    /// can't), so a board ID written into its file before the move can't be undone by them.
    private func prepareForMove(_ path: String) -> Bool {
        guard let session, FileNode.rebased(session.path, from: path, to: path) != nil else { return true }
        return session.flush()
    }

    /// Called before LP quits; `ready` false keeps it running so unsaved edits aren't lost. When
    /// edits were kept as a copy on the way out, `notice` says where — the window's alert can't
    /// show any more.
    func readyToQuit() -> (ready: Bool, notice: AlertMessage?) {
        let earlier = alert?.id
        let ready = leavePage()
        return (ready, alert.flatMap { $0.id != earlier && $0.file != nil ? $0 : nil })
    }

    /// Ticks a task off (or reopens it) from Home, the calendar or a reminder, saying so when its
    /// file can't be written.
    func toggleTask(_ task: TaskItem, in workspace: Workspace) {
        do {
            try workspace.toggleTask(task)
        } catch {
            alert = AlertMessage(title: "Couldn’t Change “\(task.text)”",
                                 message: "Its file couldn’t be written, so it wasn’t changed. \(error.localizedDescription)")
        }
    }

    // MARK: Reminders and widgets

    /// Brings what LP shows outside its window, reminders and widgets, up to date shortly,
    /// once a burst of changes has settled.
    func scheduleGlanceUpdate() {
        glanceUpdate?.cancel()
        glanceUpdate = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.updateReminders()
            self?.updateWidgets()
        }
    }

    func updateReminders() {
        // Switched off: everything LP scheduled goes, workspace or not.
        if reminders.isOn != settings.remindersEnabled { reminders.setOn(settings.remindersEnabled) }
        guard settings.remindersEnabled else { return }
        // Until the pages have been read there is nothing to go on; planning now would only
        // take back reminders that are still right.
        guard let workspace, workspace.hasIndexed else { return }
        reminders.update(with: reminderPlan(for: workspace))
    }

    func updateWidgets() {
        if let workspace, workspace.hasIndexed {
            widgets.publish(widgetSnapshot(for: workspace))
        } else if workspace == nil, var snapshot = WidgetStore.load() {
            // No workspace open: the widgets keep its tasks, but their events follow the calendars
            // — a disconnected account's events don't stay behind.
            snapshot.events = widgetEvents()
            snapshot.generated = Date()
            widgets.publish(snapshot)
        }
    }

    /// Opens a `localproductivity://` link, from a widget for instance. Links only navigate.
    func handle(_ url: URL) {
        guard let destination = LPLink.destination(of: url) else { return }
        NSApp.activate()
        whenWorkspaceReady { [weak self] workspace in
            guard let self else { return }
            switch destination {
            case .home:
                show(.home)
            case .boards:
                show(.boards)
            case .calendar(let iso):
                if let day = Day(iso: iso) {
                    calendarSelection = day
                    calendarMonth = day.startOfMonth
                }
                show(.calendar)
            case .page(let path):
                if let path = PathSafety.contained(path), workspace.meta[path] != nil {
                    openPage(path)
                } else {
                    show(.home)
                }
            }
        }
    }

    func reminderPlan(for workspace: Workspace, now: Date = Date()) -> [PlannedReminder] {
        var tasks: [ReminderTask] = []
        for meta in workspace.meta.values {
            for task in meta.tasks where !task.isDone {
                guard let due = task.due else { continue }
                tasks.append(ReminderTask(path: task.path, text: task.text, source: meta.displayTitle, due: due,
                                          time: task.dueTime, isCard: task.isBoardCard, cardID: task.cardID,
                                          boardID: task.boardID))
            }
        }
        let appleAccounts = Set(calendarSync.accounts.filter { $0.kind == .apple }.map(\.id))
        let events = calendarSync.events
            .filter { !calendarSync.hiddenCalendarIDs.contains($0.calendarID) }
            .map { ReminderEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay,
                                 location: $0.location, isFromAppleCalendar: appleAccounts.contains($0.accountID)) }
        return ReminderPlanner.plan(tasks: tasks, events: events, settings: settings.reminders, now: now,
                                    workspace: workspace.record.id.uuidString)
    }

    /// Acts on a tapped reminder or one of its buttons. LP may have just been launched by it,
    /// so this waits for the workspace to be read first.
    func handleReminder(_ response: ReminderResponse) {
        switch response.action {
        case .open:
            NSApp.activate()
            whenWorkspaceReady { [weak self] workspace in
                guard let self else { return }
                if Self.reminder(response, belongsTo: workspace), let path = response.info[ReminderInfo.path], workspace.meta[path] != nil {
                    openPage(path)
                } else if response.kind == .event, let day = response.info[ReminderInfo.day].flatMap(Day.init(iso:)) {
                    calendarSelection = day
                    calendarMonth = day.startOfMonth
                    show(.calendar)
                } else {
                    show(.home)
                }
            }
        case .complete:
            whenWorkspaceReady { [weak self] workspace in
                // Only a reminder known to come from this workspace ticks a task off here; one from
                // another (or from before reminders carried it) could match the wrong task.
                guard response.info[ReminderInfo.workspace] == workspace.record.id.uuidString else { return }
                self?.completeTask(path: response.info[ReminderInfo.path], text: response.info[ReminderInfo.text],
                                   day: response.info[ReminderInfo.day], time: response.info[ReminderInfo.time],
                                   cardID: response.info[ReminderInfo.cardID], boardID: response.info[ReminderInfo.board],
                                   in: workspace)
            }
        case .snoozeHour:
            reminders.snooze(response, until: Date().addingTimeInterval(3600))
        case .snoozeTomorrow:
            let time = response.info[ReminderInfo.time].flatMap(Int.init).map(TimeOfDay.init(minutes:)) ?? settings.dueReminderTime
            reminders.snooze(response, until: time.date(on: Day.today.adding(days: 1)))
        }
    }

    /// For opening a page: reminders planned before they carried their workspace are taken as
    /// this one's (opening is harmless).
    private static func reminder(_ response: ReminderResponse, belongsTo workspace: Workspace) -> Bool {
        response.info[ReminderInfo.workspace].map { $0 == workspace.record.id.uuidString } ?? true
    }

    /// Ticks off the open task a reminder was about. Nothing happens when it was already done
    /// or no longer exists.
    func completeTask(path: String?, text: String?, day: String?, time: String?, cardID: String?, boardID: String? = nil,
                      in workspace: Workspace) {
        guard let path, let text, let tasks = workspace.meta[path]?.tasks else { return }
        let minutes = time.flatMap(Int.init)
        let matches = tasks.filter { candidate in
            !candidate.isDone && (cardID.map { candidate.cardID == $0 }
                ?? (candidate.text == text && candidate.due?.iso == day && candidate.dueTime?.minutes == minutes))
        }
        // Two open tasks that look the same: rather than guess, neither is ticked off.
        guard matches.count == 1, let task = matches.first else { return }
        // Edits waiting in the editor are written first, so ticking the box cannot undo them.
        if session?.path == path { session?.flush() }
        // A card: only on the board the reminder was about — another board can replace the file
        // and carry the same card IDs. One that names no board (planned before the board had an
        // ID) only acts on a board that still has none.
        if task.isBoardCard, workspace.boardID(at: path) != boardID { return }
        toggleTask(task, in: workspace)
        scheduleGlanceUpdate()
    }

    private func whenWorkspaceReady(attempt: Int = 0, _ action: @escaping (Workspace) -> Void) {
        if let workspace, workspace.hasIndexed {
            action(workspace)
        } else if attempt < 60 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.whenWorkspaceReady(attempt: attempt + 1, action)
            }
        }
    }

    // MARK: Navigation

    /// The route to return to once the first scan has finished and it can be validated.
    @ObservationIgnored private var pendingRoute: Route?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func show(_ destination: Route) {
        guard destination != route, leavePage() else { return }
        backStack.append(route)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
        setRoute(destination)
    }

    /// Opens a page, or the board view for a board.
    func openPage(_ path: String) {
        show(route(for: path))
    }

    /// The screen a file opens in: the board view for boards, the editor for everything else.
    func route(for path: String) -> Route {
        workspace?.isBoard(path) == true ? .board(path) : .page(path)
    }

    func goBack() {
        // Where to go is found first: with nowhere left to go, the open page stays as it is. An
        // entry for the page already open (left behind when another page was removed) is skipped.
        while let previous = backStack.last, !isValid(previous) || previous == route { backStack.removeLast() }
        guard let previous = backStack.last, leavePage() else { return }
        backStack.removeLast()
        forwardStack.append(route)
        setRoute(previous)
    }

    func goForward() {
        while let next = forwardStack.last, !isValid(next) || next == route { forwardStack.removeLast() }
        guard let next = forwardStack.last, leavePage() else { return }
        forwardStack.removeLast()
        backStack.append(route)
        setRoute(next)
    }

    private func setRoute(_ destination: Route) {
        route = destination
        if case .page(let path) = destination, let workspace {
            // A closed session writes nothing more, so it is never reused for the page.
            if session?.path != path || session?.isClosed == true { session = PageSession(path: path, workspace: workspace) }
            workspace.noteOpened(path)
            workspace.expand(to: path)
        } else {
            session = nil
        }
        if case .board(let path) = destination, let workspace {
            if boardStore?.path != path {
                boardStore = BoardStore(path: path, workspace: workspace, text: BoardStore.readText(at: workspace.url(for: path)))
            }
            workspace.noteOpened(path)
            workspace.expand(to: path)
        } else {
            boardStore = nil
        }
        if let workspace { saveRoute(destination, for: workspace.record) }
    }

    /// Opens the board again after it couldn't be read.
    func retryBoard() {
        guard let workspace, let store = boardStore, store.readFailure != nil,
              let text = BoardStore.readText(at: workspace.url(for: store.path)) else { return }
        boardStore = BoardStore(path: store.path, workspace: workspace, text: text)
    }

    private func isValid(_ candidate: Route) -> Bool {
        guard let workspace, let path = candidate.path else { return true }
        return workspace.exists(path)
    }

    /// Called whenever the tree has been rescanned.
    private func validateRoute() {
        guard let workspace, workspace.hasLoaded else { return }
        if let pending = pendingRoute {
            pendingRoute = nil
            if route == .home, pending != .home, isValid(pending) { setRoute(pending) }
            return
        }
        // The open page or folder was moved or deleted outside the app.
        if !isValid(route) {
            // Its edits not saved yet are kept as a copy; if even that fails, it stays open.
            if let session, !session.keepChangesAfterRemoval() {
                alert = AlertMessage(title: "“\(session.title)” Was Moved or Deleted",
                                     message: "Its changes that weren’t saved yet couldn’t be kept as a copy, so it stays open. Copy them somewhere safe before closing it.")
                return
            }
            session = nil
            boardStore = nil
            route = .home
        }
    }

    private func pathChanged(from old: String, to new: String) {
        backStack = backStack.map { $0.rebased(from: old, to: new) }
        forwardStack = forwardStack.map { $0.rebased(from: old, to: new) }
        let updated = route.rebased(from: old, to: new)
        if updated != route {
            route = updated
            if let session, let path = FileNode.rebased(session.path, from: old, to: new) {
                session.pathDidChange(to: path)
                // A board open as Markdown had its ID written into the file before the move.
                session.fileChangedOnDisk()
            }
            if let boardStore, let path = FileNode.rebased(boardStore.path, from: old, to: new) {
                boardStore.pathDidChange(to: path)
            }
            if let workspace { saveRoute(updated, for: workspace.record) }
        }
        if let renaming = renamingPath, let rebased = FileNode.rebased(renaming, from: old, to: new) {
            renamingPath = rebased
        }
    }

    private func routeKey(_ record: WorkspaceRecord) -> String { "workspace.route.\(record.id.uuidString)" }

    private func saveRoute(_ route: Route, for record: WorkspaceRecord) {
        let value: String
        switch route {
        case .home: value = "home"
        case .calendar: value = "calendar"
        case .boards: value = "boards"
        case .page(let path): value = "page:" + path
        case .folder(let path): value = "folder:" + path
        case .board(let path): value = "board:" + path
        }
        defaults?.set(value, forKey: routeKey(record))
    }

    private func savedRoute(for record: WorkspaceRecord) -> Route? {
        guard let value = defaults?.string(forKey: routeKey(record)) else { return nil }
        if value == "calendar" { return .calendar }
        if value == "boards" { return .boards }
        if value.hasPrefix("page:") { return .page(String(value.dropFirst(5))) }
        if value.hasPrefix("folder:") { return .folder(String(value.dropFirst(7))) }
        if value.hasPrefix("board:") { return .board(String(value.dropFirst(6))) }
        return .home
    }

    // MARK: Pages and folders

    /// The folder new items should go into, based on what is on screen.
    var currentFolder: String {
        switch route {
        case .page(let path), .board(let path): return FileNode.parent(of: path)
        case .folder(let path): return path
        default: return ""
        }
    }

    func newPage(in folder: String? = nil) {
        perform {
            guard let workspace else { return }
            let path = try workspace.createPage(in: folder ?? currentFolder)
            show(.page(path))
            session?.focusRequest = .title
        }
    }

    /// Asks for a name, template and folder, then creates the board (see `NewBoardSheet`).
    func newBoard(in folder: String? = nil) {
        guard workspace != nil else { return }
        newBoardRequest = NewBoardRequest(folder: folder ?? currentFolder)
    }

    func createBoard(named title: String, template: BoardTemplate, in folder: String) {
        perform {
            guard let workspace else { return }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = try workspace.createBoard(in: folder, title: name.isEmpty ? "Untitled Board" : name, template: template)
            show(.board(path))
        }
    }

    func newFolder(in folder: String? = nil) {
        perform {
            guard let workspace else { return }
            let path = try workspace.createFolder(in: folder ?? currentFolder)
            renamingPath = path
        }
    }

    /// Renames a page or folder. Returns false if the name could not be used.
    @discardableResult
    func rename(_ path: String, to title: String) -> Bool {
        guard let workspace else { return false }
        if session?.path == path { session?.flush() }
        do {
            try workspace.rename(path, to: title)
            return true
        } catch {
            alert = AlertMessage(title: "Couldn’t Rename", message: error.localizedDescription)
            return false
        }
    }

    func move(_ path: String, into folder: String) {
        perform {
            if session?.path == path { session?.flush() }
            try workspace?.move(path, into: folder)
        }
    }

    func duplicate(_ path: String) {
        perform {
            session?.flush()
            guard let copy = try workspace?.duplicate(path) else { return }
            if workspace?.node(at: copy)?.isFolder == false { show(route(for: copy)) }
        }
    }

    func trash(_ path: String) {
        perform {
            guard let workspace else { return }
            if let open = route.path, open == path || open.hasPrefix(path + "/") {
                guard leavePage() else { return }
                session = nil
                boardStore = nil
                route = .home
            }
            try workspace.trash(path)
        }
    }

    func openDailyNote(for day: Day = .today) {
        perform {
            guard let workspace else { return }
            let existed = workspace.dailyNote(for: day) != nil
            let path = try workspace.openDailyNote(for: day, folder: settings.dailyNotesFolder)
            show(.page(path))
            if !existed { session?.focusRequest = .body }
        }
    }

    /// Follows a `[[wiki link]]`. A link to a page that does not exist yet creates it.
    func openWikiLink(_ target: String, from source: String) {
        guard let workspace else { return }
        if let path = workspace.resolveLink(target, from: source) {
            openPage(path)
            return
        }
        perform {
            var name = target
            if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
            // A link that tries to climb out of the workspace creates the page next to the source instead.
            if name.contains("/"), PathSafety.contained(name) == nil { name = FileNode.fileName(of: name) }
            let folder = name.contains("/") ? FileNode.parent(of: name) : FileNode.parent(of: source)
            let path = try workspace.createPage(in: folder, title: FileNode.title(of: FileNode.fileName(of: name)))
            show(.page(path))
            session?.focusRequest = .body
        }
    }

    /// Opens a Markdown link: web addresses in the browser, relative links to other pages in the app.
    func openLink(_ destination: String, from source: String) {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.count > 1 {
            switch LinkSafety.action(for: url) {
            case .open: open(url)
            case .confirm: pendingExternalLink = url
            case .file: openFileSafely(url)
            }
            return
        }
        if trimmed.contains("@"), !trimmed.contains("/"), let mail = URL(string: "mailto:" + trimmed) {
            NSWorkspace.shared.open(mail)
            return
        }
        guard let workspace else { return }
        if let path = workspace.resolveLink(trimmed.removingPercentEncoding ?? trimmed, from: source) {
            openPage(path)
        } else if let file = workspace.resolveAttachment(trimmed, from: source) {
            openFileSafely(file)
        }
    }

    /// Opens a document in its app. Anything that could run — an app, a script, an installer —
    /// is shown in Finder instead, so clicking a link in a note never runs code.
    private func openFileSafely(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue, LinkSafety.canOpenFile(url) {
            open(url)
        } else if exists {
            #if DEBUG
            if let linkHook { return linkHook("reveal", url) }
            #endif
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func open(_ url: URL) {
        #if DEBUG
        if let linkHook { return linkHook("open", url) }
        #endif
        NSWorkspace.shared.open(url)
    }

    /// Opens a link the user confirmed.
    func openPendingExternalLink() {
        if let url = pendingExternalLink { NSWorkspace.shared.open(url) }
        pendingExternalLink = nil
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = AlertMessage(title: "Something Went Wrong", message: error.localizedDescription)
        }
    }
}
