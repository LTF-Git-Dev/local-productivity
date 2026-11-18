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
}

@Observable
final class AppModel {

    let settings: AppSettings
    let library: WorkspaceLibrary
    /// Connected calendar accounts. Calendars belong to the app, not to a workspace.
    let calendarSync: CalendarSyncStore
    /// Reminders for due tasks, upcoming events and the day ahead.
    let reminders: ReminderCenter

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
        library = WorkspaceLibrary(defaults: defaults)
        calendarSync = CalendarSyncStore(defaults: defaults)
        // Snapshots and previews plan reminders but never hand them to the system.
        reminders = ReminderCenter(dryRun: defaults == nil)

        settings.onRemindersChanged = { [weak self] in self?.scheduleGlanceUpdate() }
        calendarSync.onEventsChanged = { [weak self] in self?.scheduleGlanceUpdate() }
        reminders.onResponse = { [weak self] response in self?.handleReminder(response) }

        let center = NotificationCenter.default
        terminationObserver = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.flush() }
        }
        deactivationObserver = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.flush() }
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
        closeWorkspace()
        library.markOpened(record)
        library.setLastOpen(record)

        let opened = Workspace(record: record, rootURL: url, defaults: defaults)
        opened.onMetaChanged = { [weak self] in self?.scheduleGlanceUpdate() }
        opened.onPathChanged = { [weak self] old, new in self?.pathChanged(from: old, to: new) }
        opened.onTreeChanged = { [weak self] in self?.validateRoute() }
        opened.onPagesChangedOnDisk = { [weak self] paths in
            if let session = self?.session, paths.contains(session.path) { session.fileChangedOnDisk() }
            if let board = self?.boardStore, paths.contains(board.path) { board.reloadFromDisk() }
        }
        workspace = opened
        backStack = []
        forwardStack = []
        pendingRoute = savedRoute(for: record)
        setRoute(.home)
        opened.start()
    }

    func closeWorkspace() {
        guard let current = workspace else { return }
        session?.flush()
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
        // Until the pages have been read there is nothing to go on; planning now would only
        // take back reminders that are still right.
        guard let workspace, workspace.hasIndexed else { return }
        reminders.update(with: reminderPlan(for: workspace))
    }

    func updateWidgets() {
        guard let workspace, workspace.hasIndexed else { return }
        widgets.publish(widgetSnapshot(for: workspace))
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
                                          time: task.dueTime, isCard: task.isBoardCard, cardID: task.cardID))
            }
        }
        let appleAccounts = Set(calendarSync.accounts.filter { $0.kind == .apple }.map(\.id))
        let events = calendarSync.events
            .filter { !calendarSync.hiddenCalendarIDs.contains($0.calendarID) }
            .map { ReminderEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay,
                                 location: $0.location, isFromAppleCalendar: appleAccounts.contains($0.accountID)) }
        return ReminderPlanner.plan(tasks: tasks, events: events, settings: settings.reminders, now: now)
    }

    /// Acts on a tapped reminder or one of its buttons. LP may have just been launched by it,
    /// so this waits for the workspace to be read first.
    func handleReminder(_ response: ReminderResponse) {
        switch response.action {
        case .open:
            NSApp.activate()
            whenWorkspaceReady { [weak self] workspace in
                guard let self else { return }
                if let path = response.info[ReminderInfo.path], workspace.meta[path] != nil {
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
                self?.completeTask(path: response.info[ReminderInfo.path], text: response.info[ReminderInfo.text],
                                   cardID: response.info[ReminderInfo.cardID], in: workspace)
            }
        case .snoozeHour:
            reminders.snooze(response, until: Date().addingTimeInterval(3600))
        case .snoozeTomorrow:
            let time = response.info[ReminderInfo.time].flatMap(Int.init).map(TimeOfDay.init(minutes:)) ?? settings.dueReminderTime
            reminders.snooze(response, until: time.date(on: Day.today.adding(days: 1)))
        }
    }

    /// Ticks off the open task a reminder was about. Nothing happens when it was already done
    /// or no longer exists.
    func completeTask(path: String?, text: String?, cardID: String?, in workspace: Workspace) {
        guard let path, let text,
              let task = workspace.meta[path]?.tasks.first(where: { candidate in
                  !candidate.isDone && (cardID.map { candidate.cardID == $0 } ?? (candidate.text == text))
              }) else { return }
        // Edits waiting in the editor are written first, so ticking the box cannot undo them.
        if session?.path == path { session?.flush() }
        workspace.toggleTask(task)
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
        guard destination != route else { return }
        session?.flush()
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
        session?.flush()
        while let previous = backStack.popLast() {
            guard isValid(previous) else { continue }
            forwardStack.append(route)
            setRoute(previous)
            return
        }
    }

    func goForward() {
        session?.flush()
        while let next = forwardStack.popLast() {
            guard isValid(next) else { continue }
            backStack.append(route)
            setRoute(next)
            return
        }
    }

    private func setRoute(_ destination: Route) {
        route = destination
        if case .page(let path) = destination, let workspace {
            if session?.path != path { session = PageSession(path: path, workspace: workspace) }
            workspace.noteOpened(path)
            workspace.expand(to: path)
        } else {
            session = nil
        }
        if case .board(let path) = destination, let workspace {
            if boardStore?.path != path {
                let text = (try? Data(contentsOf: workspace.url(for: path))).map { String(decoding: $0, as: UTF8.self) } ?? ""
                boardStore = BoardStore(path: path, workspace: workspace, text: text)
            }
            workspace.noteOpened(path)
            workspace.expand(to: path)
        } else {
            boardStore = nil
        }
        if let workspace { saveRoute(destination, for: workspace.record) }
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
                session?.flush()
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
