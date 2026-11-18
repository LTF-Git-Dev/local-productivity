//
//  CalendarSyncStore.swift
//  LP
//
//  Keeps LP's view of every connected calendar account up to date and sends edits back
//  to where each event lives. Reads are cached on disk so the calendar fills in at once
//  and still shows something offline; the providers remain the source of truth.
//
//  Sync happens when the app starts or becomes active, every few minutes while it is in
//  use, whenever Apple's calendar store reports a change, when the visible month moves
//  outside what has been loaded, and right after every edit.
//

import AppKit
import Foundation

@Observable
final class CalendarSyncStore {

    enum AccountState: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
        case needsSignIn
    }

    private(set) var accounts: [CalendarAccount] = []
    private(set) var calendars: [SyncCalendar] = []
    private(set) var events: [SyncEvent] = [] { didSet { reindex() } }
    private(set) var states: [String: AccountState] = [:]
    /// Events grouped by the days they appear on, visible calendars only.
    private(set) var eventsByDay: [Day: [SyncEvent]] = [:]

    var hiddenCalendarIDs: Set<String> = [] {
        didSet {
            guard hiddenCalendarIDs != oldValue else { return }
            defaults?.set(Array(hiddenCalendarIDs), forKey: Keys.hidden)
            reindex()
            scheduleRefresh()
        }
    }
    var googleClientID: String { didSet { defaults?.set(googleClientID, forKey: Keys.googleClientID) } }
    var microsoftClientID: String { didSet { defaults?.set(microsoftClientID, forKey: Keys.microsoftClientID) } }
    /// The calendar new events go into unless another is picked.
    var defaultCalendarID: String? { didSet { defaults?.set(defaultCalendarID, forKey: Keys.defaultCalendar) } }
    /// Called after the visible events change.
    @ObservationIgnored var onEventsChanged: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var providers: [String: any CalendarProvider] = [:]
    @ObservationIgnored private var loaded: DateInterval
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        googleClientID = defaults?.string(forKey: Keys.googleClientID) ?? ""
        microsoftClientID = defaults?.string(forKey: Keys.microsoftClientID) ?? ""
        defaultCalendarID = defaults?.string(forKey: Keys.defaultCalendar)
        hiddenCalendarIDs = Set(defaults?.stringArray(forKey: Keys.hidden) ?? [])
        loaded = Self.window(around: Day.today)

        if let data = defaults?.data(forKey: Keys.accounts), let saved = try? JSONDecoder().decode([CalendarAccount].self, from: data) {
            accounts = saved
        }
        restoreCache()
        for account in accounts { attachProvider(for: account) }

        guard defaults != nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastRefresh ?? .distantPast) > 60 else { return }
                self.scheduleRefresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.isActive else { return }
                self?.scheduleRefresh()
            }
        }
        scheduleRefresh(after: 0.5)
    }

    // MARK: Reading

    var isEmpty: Bool { accounts.isEmpty }

    func events(on day: Day) -> [SyncEvent] {
        eventsByDay[day] ?? []
    }

    func calendar(withID id: String) -> SyncCalendar? {
        calendars.first { $0.id == id }
    }

    func calendars(for account: CalendarAccount) -> [SyncCalendar] {
        calendars.filter { $0.accountID == account.id }
    }

    /// Calendars an event can be created in, grouped by account in a stable order.
    var writableCalendars: [SyncCalendar] {
        let order = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1.id, $0) })
        return calendars
            .filter { $0.isWritable && !hiddenCalendarIDs.contains($0.id) }
            .sorted { (order[$0.accountID] ?? 0, $0.sourceTitle, $0.title) < (order[$1.accountID] ?? 0, $1.sourceTitle, $1.title) }
    }

    var defaultCalendar: SyncCalendar? {
        if let id = defaultCalendarID, let calendar = writableCalendars.first(where: { $0.id == id }) { return calendar }
        return writableCalendars.first
    }

    func state(of account: CalendarAccount) -> AccountState {
        states[account.id] ?? .idle
    }

    var isSyncing: Bool {
        states.values.contains(.syncing)
    }

    /// Makes sure events around `month` are loaded, widening the window when it is not.
    func ensureLoaded(around month: Day) {
        let wanted = Self.window(around: month)
        guard !(loaded.start <= wanted.start && loaded.end >= wanted.end) else { return }
        loaded = DateInterval(start: min(loaded.start, wanted.start), end: max(loaded.end, wanted.end))
        // Keep the window from growing without bound while browsing far away.
        if loaded.duration > 400 * 86_400 { loaded = wanted }
        scheduleRefresh()
    }

    // MARK: Connecting

    /// Asks macOS for calendar access and adds every calendar on this Mac.
    func connectApple() async throws {
        let provider = EventKitCalendarProvider()
        try await provider.requestAccess()
        add(provider)
    }

    func connectGoogle() async throws {
        add(try await GoogleCalendarProvider.connect(clientID: googleClientID))
    }

    func connectMicrosoft() async throws {
        add(try await MicrosoftCalendarProvider.connect(clientID: microsoftClientID))
    }

    func disconnect(_ account: CalendarAccount) {
        providers[account.id]?.disconnect()
        providers.removeValue(forKey: account.id)
        accounts.removeAll { $0.id == account.id }
        calendars.removeAll { $0.accountID == account.id }
        events.removeAll { $0.accountID == account.id }
        states.removeValue(forKey: account.id)
        saveAccounts()
        saveCache()
    }

    /// Adds a connected provider, replacing an earlier connection to the same account.
    func add(_ provider: any CalendarProvider) {
        let account = provider.account
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        install(provider)
        saveAccounts()
        scheduleRefresh(after: 0)
    }

    private func attachProvider(for account: CalendarAccount) {
        switch account.kind {
        case .apple:
            if EventKitCalendarProvider.isAuthorized {
                install(EventKitCalendarProvider())
            } else {
                states[account.id] = .failed("LP no longer has access to your calendars. Allow it in System Settings → Privacy & Security → Calendars.")
            }
        case .google:
            guard let config = GoogleCalendarMapping.configuration(clientID: googleClientID) else {
                states[account.id] = .needsSignIn
                return
            }
            let provider = GoogleCalendarProvider(account: account, config: config)
            if provider.hasCredentials { install(provider) } else { states[account.id] = .needsSignIn }
        case .microsoft:
            guard let config = MicrosoftGraphMapping.configuration(clientID: microsoftClientID, bundleID: MicrosoftCalendarProvider.bundleID) else {
                states[account.id] = .needsSignIn
                return
            }
            let provider = MicrosoftCalendarProvider(account: account, config: config)
            if provider.hasCredentials { install(provider) } else { states[account.id] = .needsSignIn }
        }
    }

    private func install(_ provider: any CalendarProvider) {
        provider.onExternalChange = { [weak self] in self?.scheduleRefresh(after: 0.6) }
        providers[provider.account.id] = provider
        states[provider.account.id] = .idle
    }

    // MARK: Syncing

    /// Coalesces bursts of refresh requests into one.
    func scheduleRefresh(after delay: TimeInterval = 0.3) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        lastRefresh = Date()
        let interval = loaded
        for account in accounts {
            guard let provider = providers[account.id] else { continue }
            states[account.id] = .syncing
            do {
                let fetchedCalendars = try await provider.calendars()
                let visible = fetchedCalendars.filter { !hiddenCalendarIDs.contains($0.id) }
                let fetchedEvents = try await provider.events(in: interval, calendars: visible)
                calendars = calendars.filter { $0.accountID != account.id } + fetchedCalendars
                events = events.filter { $0.accountID != account.id } + fetchedEvents
                states[account.id] = .synced(Date())
            } catch CalendarSyncError.signInRequired {
                states[account.id] = .needsSignIn
            } catch {
                states[account.id] = .failed(error.localizedDescription)
            }
        }
        saveCache()
    }

    // MARK: Editing

    private func provider(for event: SyncEvent) throws -> any CalendarProvider {
        guard let provider = providers[event.accountID] else { throw CalendarSyncError.notConnected }
        return provider
    }

    /// Creates an event in `calendar` and shows it straight away.
    @discardableResult
    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent {
        guard let provider = providers[calendar.accountID] else { throw CalendarSyncError.notConnected }
        let created = try await provider.create(draft, in: calendar)
        events.append(created)
        defaultCalendarID = calendar.id
        scheduleRefresh(after: 1)
        return created
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
        let provider = try provider(for: event)
        let before = events
        // Show the change at once; the refresh that follows brings in the source's version.
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index].title = draft.title
            events[index].start = draft.start
            events[index].end = draft.end
            events[index].isAllDay = draft.isAllDay
            events[index].location = draft.location
            events[index].notes = draft.notes
        }
        do {
            try await provider.update(event, with: draft, span: span)
            scheduleRefresh(after: 0.5)
        } catch {
            events = before
            scheduleRefresh(after: 0)
            throw error
        }
    }

    func delete(_ event: SyncEvent, span: EditSpan) async throws {
        let provider = try provider(for: event)
        let before = events
        if span == .allEvents, let series = event.seriesID {
            events.removeAll { $0.accountID == event.accountID && $0.seriesID == series }
        } else {
            events.removeAll { $0.id == event.id }
        }
        do {
            try await provider.delete(event, span: span)
            scheduleRefresh(after: 0.5)
        } catch {
            events = before
            scheduleRefresh(after: 0)
            throw error
        }
    }

    // MARK: Index

    private func reindex() {
        var byDay: [Day: [SyncEvent]] = [:]
        for event in events where !hiddenCalendarIDs.contains(event.calendarID) {
            for day in event.days() { byDay[day, default: []].append(event) }
        }
        for day in byDay.keys {
            byDay[day]?.sort { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        eventsByDay = byDay
        onEventsChanged?()
    }

    /// From the start of the month before `month` to the end of the month after it.
    private static func window(around month: Day) -> DateInterval {
        let first = month.startOfMonth.adding(months: -1).date()
        let last = month.startOfMonth.adding(months: 2).date()
        return DateInterval(start: Calendar.current.startOfDay(for: first), end: Calendar.current.startOfDay(for: last))
    }

    // MARK: Saved state

    private struct Cache: Codable {
        var calendars: [SyncCalendar]
        var events: [SyncEvent]
    }

    private var cacheURL: URL? {
        guard defaults != nil, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("LP", isDirectory: true).appendingPathComponent("calendar-cache.json")
    }

    private func restoreCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        let known = Set(accounts.map(\.id))
        calendars = cache.calendars.filter { known.contains($0.accountID) }
        events = cache.events.filter { known.contains($0.accountID) }
    }

    private func saveCache() {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(Cache(calendars: calendars, events: events)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults?.set(data, forKey: Keys.accounts)
    }

    private enum Keys {
        static let accounts = "calendar.accounts"
        static let hidden = "calendar.hidden"
        static let googleClientID = "calendar.google.clientID"
        static let microsoftClientID = "calendar.microsoft.clientID"
        static let defaultCalendar = "calendar.defaultCalendar"
    }
}
