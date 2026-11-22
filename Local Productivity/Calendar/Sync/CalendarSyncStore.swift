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
            // A calendar shown (or hidden) again: its account is synced in full — retried until it works.
            let changed = hiddenCalendarIDs.symmetricDifference(oldValue)
            requestFullSync(for: Set(calendars.filter { changed.contains($0.id) }.map(\.accountID)))
        }
    }
    /// The person's own Google / Microsoft client IDs (Settings → Calendars → Advanced); empty means
    /// LP's own registration (`BuiltInRegistration`).
    var googleClientID: String { didSet { defaults?.set(googleClientID, forKey: Keys.googleClientID) } }
    var microsoftClientID: String { didSet { defaults?.set(microsoftClientID, forKey: Keys.microsoftClientID) } }

    /// The registration a new Google sign-in goes to: the person's own, or LP's.
    /// While Google reviews LP, not LP's registration even when pasted in as one's own.
    var effectiveGoogleClientID: String? {
        let id = AppRegistration.clientID(own: googleClientID, builtIn: BuiltInRegistration.googleClientID)
        return BuiltInRegistration.googleAwaitingReview && id == BuiltInRegistration.shippedGoogleClientID ? nil : id
    }
    var effectiveMicrosoftClientID: String? { AppRegistration.clientID(own: microsoftClientID, builtIn: BuiltInRegistration.microsoftClientID) }

    /// Whether Google / Microsoft can be connected right now (a usable registration exists).
    var canConnectGoogle: Bool { effectiveGoogleClientID.flatMap { GoogleCalendarMapping.configuration(clientID: $0) } != nil }
    var canConnectMicrosoft: Bool {
        effectiveMicrosoftClientID.flatMap { MicrosoftGraphMapping.configuration(clientID: $0, bundleID: MicrosoftCalendarProvider.bundleID) } != nil
    }
    /// The calendar new events go into unless another is picked.
    var defaultCalendarID: String? { didSet { defaults?.set(defaultCalendarID, forKey: Keys.defaultCalendar) } }
    /// Called after the visible events change.
    @ObservationIgnored var onEventsChanged: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var providers: [String: any CalendarProvider] = [:]
    @ObservationIgnored private var loaded: DateInterval
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherRefresh = false
    /// When each account last had a full sync (none: never, or one was asked for).
    @ObservationIgnored private var lastFullSync: [String: Date] = [:]
    /// Counts each account's requests for a full sync: what a pass that started before the latest
    /// one fetched is out of date (a series changed, a calendar was shown) and is dropped — the
    /// pass that follows fetches it again.
    @ObservationIgnored private var fullSyncRequests: [String: Int] = [:]
    /// Changes on their way, by connection: until they finish, what a sync pass brings back through
    /// that connection may not have them yet, so it isn't used. (By connection, not account: a
    /// connection made again meanwhile isn't held up by the old one's changes.)
    @ObservationIgnored private var pendingWrites: [ObjectIdentifier: Int] = [:]

    private func beginWrite(_ provider: any CalendarProvider) {
        pendingWrites[ObjectIdentifier(provider), default: 0] += 1
    }

    /// A change finished, however it went: the account's connection — even one made again meanwhile,
    /// whose first sync may predate it — syncs it fresh.
    private func endWrite(_ provider: any CalendarProvider, account: String) {
        let key = ObjectIdentifier(provider)
        pendingWrites[key, default: 0] -= 1
        if pendingWrites[key] ?? 0 <= 0 { pendingWrites[key] = nil }
        if providers[account] != nil { requestFullSync(for: [account], after: 0.3) }
    }
    /// Disconnects so far, and when each account was last disconnected — so a connection that was
    /// being made meanwhile doesn't bring a disconnected account back.
    @ObservationIgnored private var disconnects = 0
    @ObservationIgnored private var disconnectedAt: [String: Int] = [:]
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
                guard let self else { return }
                // In front, the months shown stay current; behind other apps, LP still makes the
                // full sync when it is due, so the copy on the Mac stays fresh.
                guard NSApp.isActive || self.isFullSyncDue else { return }
                self.scheduleRefresh()
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
        // A pass under way fetches the range it started with: the new one needs another.
        if refreshTask != nil { needsAnotherRefresh = true }
        scheduleRefresh()
    }

    // MARK: Connecting

    /// Asks macOS for calendar access and adds every calendar on this Mac.
    func connectApple() async throws {
        let provider = EventKitCalendarProvider()
        try await provider.requestAccess()
        add(provider)
    }

    /// Lets LP use this Google account's Drive for sharing boards: Google's page asks for the one
    /// extra permission (only files LP creates), for this account. Signing in as another account
    /// changes nothing — not even for another account LP has (its connection, and the registration
    /// its Drive pages belong to, stay as they are).
    func allowGoogleDrive(for account: CalendarAccount) async throws {
        let mark = disconnects
        let email = String(account.id.dropFirst("google:".count))
        // The registration the account is connected through — Drive pages belong to it — or, for an
        // account not attached right now, the one a new sign-in uses.
        let clientID = (providers[account.id] as? GoogleCalendarProvider)?.clientID ?? effectiveGoogleClientID ?? ""
        // An account connected through LP's registration by an earlier build: no new grant (Google's
        // unverified-app page) until Google approves LP. Its existing sign-in keeps working.
        if BuiltInRegistration.googleAwaitingReview, clientID == BuiltInRegistration.shippedGoogleClientID {
            throw DriveSharingError.awaitingGoogleReview
        }
        let provider = try await GoogleCalendarProvider.connect(clientID: clientID, includeDrive: true, loginHint: email) { chosen in
            let live = (self.providers[account.id] as? GoogleCalendarProvider)?.clientID
            switch ConnectionReplacement.allowingDrive(chosen: chosen.id, expected: account.id, liveClientID: live, requested: clientID,
                                                       driveWorkRunning: SharingServices.isDriveWorkRunning(of: account.id)) {
            case .replace: return .keep
            case .otherAccount: return .refuse(DriveSharingError.otherAccount(chosen.name, expected: account.name))
            case .superseded, .registrationInUse: return .refuse(DriveSharingError.connectionChanged)
            case .busy: return .refuse(CalendarSyncError.sharingInProgress(account.name))
            }
        }
        // Its new sign-in replaces the old one (calendar included), also when Drive was unticked.
        try add(provider, unlessDisconnectedSince: mark)
        guard provider.canUseDrive else { throw DriveSharingError.notAllowed }
    }

    /// Whether LP may use this Google account's Drive.
    func canUseDrive(_ account: CalendarAccount) -> Bool {
        providers[account.id]?.driveBackend != nil
    }

    /// Where this account's shared pages go (nil when it isn't connected, or Drive isn't allowed).
    func driveBackend(for accountID: String) -> DriveBackend? {
        providers[accountID]?.driveBackend
    }

    /// Requests to this account's Drive (nil when it isn't connected, or Drive isn't allowed).
    func driveClient(for accountID: String) -> AuthorizedClient? {
        (providers[accountID] as? GoogleCalendarProvider)?.driveClient
    }

    func connectGoogle() async throws {
        let mark = disconnects
        let clientID = effectiveGoogleClientID ?? ""
        let provider = try await GoogleCalendarProvider.connect(clientID: clientID) { chosen in
            // An account working through another registration keeps it while board pages shared
            // through that one — or one still being made — need it: no other registration can reach them.
            let live = (self.providers[chosen.id] as? GoogleCalendarProvider)?.clientID
            switch ConnectionReplacement.connecting(liveClientID: live, requested: clientID,
                                                    hasDriveWork: SharingServices.hasDriveWork(of: chosen.id),
                                                    driveWorkRunning: SharingServices.isDriveWorkRunning(of: chosen.id)) {
            case .replace: return .keep
            case .busy: return .refuse(CalendarSyncError.sharingInProgress(chosen.name))
            case .registrationInUse, .otherAccount, .superseded: return .refuse(CalendarSyncError.registrationInUse(chosen.name))
            }
        }
        try add(provider, unlessDisconnectedSince: mark)
    }

    func connectMicrosoft() async throws {
        let mark = disconnects
        try add(try await MicrosoftCalendarProvider.connect(clientID: effectiveMicrosoftClientID ?? ""), unlessDisconnectedSince: mark)
    }

    /// Adds a connection that took a while to make — unless its account was disconnected meanwhile:
    /// that was the person's last word, so the new connection's tokens go and it isn't added.
    private func add(_ provider: any CalendarProvider, unlessDisconnectedSince mark: Int) throws {
        if let at = disconnectedAt[provider.account.id], at > mark {
            provider.retire()
            OAuthTokenStore.removeStored(keychainAccount: provider.account.id, revocationURL: nil)
            throw CalendarSyncError.signInInterrupted
        }
        add(provider)
    }

    func disconnect(_ account: CalendarAccount) {
        disconnects += 1
        disconnectedAt[account.id] = disconnects
        lastFullSync[account.id] = nil
        if let provider = providers[account.id] {
            provider.disconnect()
        } else if account.kind == .google || account.kind == .microsoft {
            // Not attached (its client ID was cleared, say): its tokens are removed all the same.
            OAuthTokenStore.removeStored(keychainAccount: account.id,
                                         revocationURL: account.kind == .google ? GoogleCalendarMapping.revocationURL : nil)
        }
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
            // The registration that issued its tokens (they stay valid only there), else today's.
            let clientID = OAuthTokenStore.storedClientID(keychainAccount: account.id) ?? effectiveGoogleClientID ?? ""
            guard let config = GoogleCalendarMapping.configuration(clientID: clientID) else {
                states[account.id] = .needsSignIn
                return
            }
            let provider = GoogleCalendarProvider(account: account, config: config)
            if provider.hasCredentials { install(provider) } else { states[account.id] = .needsSignIn }
        case .microsoft:
            let clientID = OAuthTokenStore.storedClientID(keychainAccount: account.id) ?? effectiveMicrosoftClientID ?? ""
            guard let config = MicrosoftGraphMapping.configuration(clientID: clientID, bundleID: MicrosoftCalendarProvider.bundleID) else {
                states[account.id] = .needsSignIn
                return
            }
            let provider = MicrosoftCalendarProvider(account: account, config: config)
            if provider.hasCredentials { install(provider) } else { states[account.id] = .needsSignIn }
        }
    }

    private func install(_ provider: any CalendarProvider) {
        // A connection being replaced stops for good, so nothing it was doing can write over (or
        // bring back) the credentials of the new one.
        if let earlier = providers[provider.account.id], earlier !== provider { earlier.retire() }
        // A new connection gets a full sync straight away.
        lastFullSync[provider.account.id] = nil
        if refreshTask != nil { needsAnotherRefresh = true }
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
        // Again while a connection was added or replaced during a pass, so it is fetched too.
        repeat {
            needsAnotherRefresh = false
            let task = Task { await performRefresh() }
            refreshTask = task
            await task.value
            refreshTask = nil
        } while needsAnotherRefresh
    }

    /// Syncs every connected calendar in full now (the calendar's Sync button).
    func syncNow() {
        requestFullSync(for: nil, after: 0)
    }

    /// Asks for a full sync of these accounts (all, when nil): their marks go, so the next pass syncs
    /// them in full — and keeps doing so until it succeeds. A pass already under way is followed by
    /// another, rather than this waiting for the next timer.
    private func requestFullSync(for accountIDs: Set<String>?, after delay: TimeInterval = 0.3) {
        let ids = accountIDs ?? Set(accounts.map(\.id))
        for id in ids {
            lastFullSync[id] = nil
            fullSyncRequests[id, default: 0] += 1
        }
        if refreshTask != nil { needsAnotherRefresh = true }
        scheduleRefresh(after: delay)
    }

    /// Whether a Google or Outlook account is due a full sync.
    private var isFullSyncDue: Bool {
        accounts.contains { $0.kind != .apple && providers[$0.id] != nil
            && CalendarSyncRange.needsFullSync(lastFullSync: lastFullSync[$0.id], now: Date()) }
    }

    private func performRefresh() async {
        let now = Date()
        lastRefresh = now
        let requestsAtStart = fullSyncRequests
        // The months shown, and the weeks around today (reminders and widgets need them even while
        // the calendar shows a month far away).
        let current = Self.window(around: Day.today)
        let shown = loaded.start <= current.start && loaded.end >= current.end ? [loaded] : [loaded, current]
        let full = CalendarSyncRange.full(around: now)
        for account in accounts {
            guard let provider = providers[account.id] else { continue }
            // Its service asked LP to wait: nothing is sent to it until then (its client sees to
            // every request). A pass after that — the timer's, or one the person starts — syncs it
            // (in full, if that is still due).
            if let until = provider.pausedUntil {
                states[account.id] = .failed(CalendarSyncError.rateLimited(until).localizedDescription)
                continue
            }
            // A full sync — a year back to two years ahead, plus the months shown — when a Google or
            // Outlook account has none that is fresh; in between, the months shown keep it current.
            // (Apple Calendar is read from macOS, on this Mac, as it's needed: no full sync.)
            let isFull = account.kind != .apple && CalendarSyncRange.needsFullSync(lastFullSync: lastFullSync[account.id], now: now)
            let intervals = isFull ? [full] + shown.filter { $0.start < full.start || $0.end > full.end } : shown
            states[account.id] = .syncing
            do {
                let fetchedCalendars = try await provider.calendars()
                let visible = fetchedCalendars.filter { !hiddenCalendarIDs.contains($0.id) }
                var fetchedEvents: [SyncEvent] = []
                var known = Set<String>()
                for interval in intervals {
                    let batch = try await provider.events(in: interval, calendars: visible).filter { !known.contains($0.id) }
                    known.formUnion(batch.map(\.id))
                    fetchedEvents += batch
                }
                // Disconnected while this was on its way: its data must not come back.
                guard providers[account.id] === provider else { continue }
                // A full sync was asked for while this was on its way: what came back may be out of
                // date, so it isn't used — the pass that follows (already queued) fetches it again.
                guard fullSyncRequests[account.id, default: 0] == requestsAtStart[account.id, default: 0],
                      pendingWrites[ObjectIdentifier(provider)] == nil else { continue }
                calendars = calendars.filter { $0.accountID != account.id } + fetchedCalendars
                // What was fetched replaces those times; what LP already had outside them stays.
                events = SyncEvent.merging(fetchedEvents, over: intervals, calendars: Set(visible.map(\.id)),
                                           into: events, account: account.id)
                if isFull { lastFullSync[account.id] = now }
                states[account.id] = .synced(Date())
            } catch CalendarSyncError.signInRequired {
                // Only for the connection that was asked: a replaced one's failure isn't the new one's.
                if providers[account.id] === provider { states[account.id] = .needsSignIn }
            } catch {
                if providers[account.id] === provider { states[account.id] = .failed(error.localizedDescription) }
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
        beginWrite(provider)
        defer { endWrite(provider, account: calendar.accountID) }
        let created: SyncEvent
        do {
            created = try await provider.create(draft, in: calendar)
        } catch {
            requestFullSync(for: [calendar.accountID], after: 0)
            throw error
        }
        // Disconnected (or connected again) meanwhile: its events aren't shown from this one.
        guard providers[calendar.accountID] === provider else { return created }
        events.append(created)
        defaultCalendarID = calendar.id
        // A new event may repeat: its account is synced in full, so every occurrence is kept.
        requestFullSync(for: [calendar.accountID], after: 1)
        return created
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
        let provider = try provider(for: event)
        let original = events.first { $0.id == event.id }
        // Show the change at once; the refresh that follows brings in the source's version.
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index].title = draft.title
            events[index].start = draft.start
            events[index].end = draft.end
            events[index].isAllDay = draft.isAllDay
            events[index].location = draft.location
            events[index].notes = draft.notes
        }
        beginWrite(provider)
        defer { endWrite(provider, account: event.accountID) }
        do {
            try await provider.update(event, with: draft, span: span)
            // Disconnected (or connected again) meanwhile: the new connection's events are its own.
            guard providers[event.accountID] === provider else { return }
            if span == .allEvents, let series = event.seriesID {
                // A whole series changed: its other occurrences are synced again in full, and copies
                // kept beyond the full range (months opened further away) go until they're opened again.
                let full = CalendarSyncRange.full(around: Date())
                // A series is one calendar's: event IDs are only unique within a calendar.
                events.removeAll { $0.calendarID == event.calendarID && $0.seriesID == series && ($0.end <= full.start || $0.start >= full.end) }
                requestFullSync(for: [event.accountID], after: 0.5)
            } else {
                // Passes under way fetched the event as it was: they're dropped, and it's synced again.
                requestFullSync(for: [event.accountID], after: 0.5)
            }
        } catch {
            // Only that event goes back, and only while its account is still connected the same
            // way — a disconnected account's events must not return.
            if providers[event.accountID] === provider, let original, let index = events.firstIndex(where: { $0.id == event.id }) {
                events[index] = original
            }
            requestFullSync(for: [event.accountID], after: 0)
            throw error
        }
    }

    func delete(_ event: SyncEvent, span: EditSpan) async throws {
        let provider = try provider(for: event)
        let removing: (SyncEvent) -> Bool = span == .allEvents && event.seriesID != nil
            ? { $0.calendarID == event.calendarID && $0.seriesID == event.seriesID }
            : { $0.id == event.id }
        let removed = events.filter(removing)
        events.removeAll(where: removing)
        beginWrite(provider)
        defer { endWrite(provider, account: event.accountID) }
        do {
            try await provider.delete(event, span: span)
            // Gone at the source: gone here too (nothing may have brought it back meanwhile), and a
            // pass under way that still has it is dropped.
            if providers[event.accountID] === provider { events.removeAll(where: removing) }
            requestFullSync(for: [event.accountID], after: 0.5)
        } catch {
            // Only those events come back, and only while their account is still connected the
            // same way.
            if providers[event.accountID] === provider {
                let present = Set(events.map(\.id))
                events += removed.filter { !present.contains($0.id) }
            }
            requestFullSync(for: [event.accountID], after: 0)
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
        calendars = cache.calendars.filter { known.contains($0.accountID) && $0.accountID != EventKitCalendarProvider.accountID }
        events = cache.events.filter { known.contains($0.accountID) && $0.accountID != EventKitCalendarProvider.accountID }
    }

    private func saveCache() {
        // Only what LP fetched from Google or Microsoft: Apple Calendar's events are on this Mac
        // already (macOS keeps them), so LP doesn't keep a second copy.
        let apple = EventKitCalendarProvider.accountID
        let kept = Cache(calendars: calendars.filter { $0.accountID != apple }, events: events.filter { $0.accountID != apple })
        guard let url = cacheURL, let data = try? JSONEncoder().encode(kept) else { return }
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
