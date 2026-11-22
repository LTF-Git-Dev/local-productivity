//
//  CalendarProviders.swift
//  LP
//
//  One provider per kind of calendar account. A provider reads calendars and events
//  and writes changes straight back to the source, so whatever is done in LP shows up
//  in Apple Calendar, Google Calendar or Outlook — and the other way round.
//

import AppKit
import EventKit
import Foundation

/// What every calendar source can do.
protocol CalendarProvider: AnyObject {
    var account: CalendarAccount { get }
    /// Called when the source reports a change made outside LP.
    var onExternalChange: (() -> Void)? { get set }

    func calendars() async throws -> [SyncCalendar]
    func events(in interval: DateInterval, calendars: [SyncCalendar]) async throws -> [SyncEvent]
    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent
    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws
    func delete(_ event: SyncEvent, span: EditSpan) async throws
    /// Forgets stored credentials.
    func disconnect()
    /// Replaced by a newer connection to the same account: stops without touching its credentials.
    func retire()
    /// Until when the service asked LP to slow down (nil: it didn't, or that's over).
    var pausedUntil: Date? { get }
    /// Where this account's shared board pages go, when the person let LP use its Drive.
    var driveBackend: DriveBackend? { get }
}

extension CalendarProvider {
    func retire() {}
    var pausedUntil: Date? { nil }
    var driveBackend: DriveBackend? { nil }
}

// MARK: - Apple Calendar

/// Every calendar macOS knows about: iCloud, "On My Mac", and any Google, Exchange or
/// CalDAV account added in System Settings → Internet Accounts. macOS does the syncing
/// with those services; LP reads and writes through EventKit.
final class EventKitCalendarProvider: CalendarProvider {

    static let accountID = "apple"

    let account = CalendarAccount(id: EventKitCalendarProvider.accountID, kind: .apple, name: "Calendars on this Mac")
    var onExternalChange: (() -> Void)?

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    /// The occurrences returned by the last fetch, so edits act on exactly the occurrence shown.
    private var occurrences: [String: EKEvent] = [:]

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var wasDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Asks macOS for access. The system shows its own permission prompt the first time.
    func requestAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw CalendarSyncError.accessDenied }
        store.reset()
    }

    func calendars() async throws -> [SyncCalendar] {
        guard Self.isAuthorized else { throw CalendarSyncError.accessDenied }
        return store.calendars(for: .event).map { calendar in
            SyncCalendar(accountID: account.id, remoteID: calendar.calendarIdentifier, title: calendar.title,
                         colorHex: Self.hex(calendar.cgColor), isWritable: calendar.allowsContentModifications,
                         sourceTitle: calendar.source?.title ?? "On My Mac")
        }
    }

    func events(in interval: DateInterval, calendars: [SyncCalendar]) async throws -> [SyncEvent] {
        guard Self.isAuthorized else { throw CalendarSyncError.accessDenied }
        let wanted = Set(calendars.map(\.remoteID))
        let ekCalendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        guard !ekCalendars.isEmpty else { return [] }

        var fetched: [String: EKEvent] = [:]
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: ekCalendars)
        let events = store.events(matching: predicate).compactMap { event -> SyncEvent? in
            guard let calendar = event.calendar else { return nil }
            let remoteID = Self.occurrenceID(event)
            fetched[remoteID] = event
            return map(event, calendarID: account.id + "|" + calendar.calendarIdentifier, remoteID: remoteID)
        }
        occurrences = fetched
        return events
    }

    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent {
        guard let ekCalendar = store.calendar(withIdentifier: calendar.remoteID) else { throw CalendarSyncError.notFound }
        guard ekCalendar.allowsContentModifications else { throw CalendarSyncError.readOnlyCalendar }
        let event = EKEvent(eventStore: store)
        event.calendar = ekCalendar
        apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        let remoteID = Self.occurrenceID(event)
        occurrences[remoteID] = event
        return map(event, calendarID: calendar.id, remoteID: remoteID)
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
        let occurrence = try lookUp(event)
        if span == .allEvents, event.isRecurring, let series = store.event(withIdentifier: occurrence.eventIdentifier) {
            // Change the whole series from its first occurrence, moving it by the same amount
            // the shown occurrence moved.
            let shift = draft.start.timeIntervalSince(event.start)
            let length = draft.end.timeIntervalSince(draft.start)
            var seriesDraft = draft
            seriesDraft.start = series.startDate.addingTimeInterval(shift)
            seriesDraft.end = seriesDraft.start.addingTimeInterval(length)
            apply(seriesDraft, to: series)
            try store.save(series, span: .futureEvents, commit: true)
        } else {
            apply(draft, to: occurrence)
            try store.save(occurrence, span: .thisEvent, commit: true)
        }
    }

    func delete(_ event: SyncEvent, span: EditSpan) async throws {
        let occurrence = try lookUp(event)
        if span == .allEvents, event.isRecurring, let series = store.event(withIdentifier: occurrence.eventIdentifier) {
            try store.remove(series, span: .futureEvents, commit: true)
        } else {
            try store.remove(occurrence, span: .thisEvent, commit: true)
        }
        occurrences.removeValue(forKey: event.remoteID)
    }

    func disconnect() {
        // Access is granted to the app as a whole; it can only be withdrawn in System Settings.
        occurrences = [:]
    }

    // MARK: Mapping

    private func lookUp(_ event: SyncEvent) throws -> EKEvent {
        if let cached = occurrences[event.remoteID] { return cached }
        // Not in the last fetch: search around the event's own date.
        let window = DateInterval(start: event.start.addingTimeInterval(-86_400), end: event.end.addingTimeInterval(86_400))
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        if let match = store.events(matching: predicate).first(where: { Self.occurrenceID($0) == event.remoteID }) {
            return match
        }
        throw CalendarSyncError.notFound
    }

    /// Occurrences of a repeating event share an identifier, so the occurrence date is added.
    private static func occurrenceID(_ event: EKEvent) -> String {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        let occurrence = event.occurrenceDate ?? event.startDate ?? Date()
        return base + "|" + String(Int(occurrence.timeIntervalSince1970))
    }

    private func map(_ event: EKEvent, calendarID: String, remoteID: String) -> SyncEvent {
        var start = event.startDate ?? Date()
        var end = event.endDate ?? start
        if event.isAllDay {
            // EventKit ends all-day events at the last moment of the last day; LP uses the
            // midnight after it.
            start = CalendarDates.startOfDay(start)
            let endDay = CalendarDates.startOfDay(end)
            end = endDay == end ? endDay : Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start }
        }
        return SyncEvent(
            accountID: account.id,
            calendarID: calendarID,
            remoteID: remoteID,
            seriesID: event.hasRecurrenceRules ? event.eventIdentifier : nil,
            title: (event.title ?? "").isEmpty ? "(No title)" : event.title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: event.location ?? "",
            notes: event.notes ?? "",
            url: event.url,
            version: event.lastModifiedDate.map { String(Int($0.timeIntervalSince1970)) }
        )
    }

    private func apply(_ draft: EventDraft, to event: EKEvent) {
        event.title = draft.title
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        // An all-day event's end in EventKit is inclusive.
        event.endDate = draft.isAllDay ? draft.end.addingTimeInterval(-1) : draft.end
    }

    private static func hex(_ color: CGColor?) -> String {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#8E8E93" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

// MARK: - Google Calendar

final class GoogleCalendarProvider: CalendarProvider {

    let account: CalendarAccount
    var onExternalChange: (() -> Void)?

    private let tokens: OAuthTokenStore
    private var client: AuthorizedClient { AuthorizedClient(tokens: tokens) }

    init(account: CalendarAccount, config: OAuthConfiguration, tokens initial: OAuthTokens? = nil) {
        self.account = account
        tokens = OAuthTokenStore(config: config, keychainAccount: account.id, tokens: initial)
    }

    var hasCredentials: Bool { tokens.hasTokens }

    /// The app registration this connection signs in with.
    var clientID: String { tokens.clientID }

    /// Whether the person let LP use Google Drive (for sharing boards) with this account.
    var canUseDrive: Bool { tokens.grantedScopes.contains(GoogleCalendarMapping.driveFileScope) }

    /// Requests for the files LP shares in this account's Drive, on the account's own tokens (and
    /// its "slow down" waits).
    var driveClient: AuthorizedClient? { canUseDrive ? client : nil }

    var driveBackend: DriveBackend? { driveClient.map { GoogleDriveBackend(client: $0, pauseKey: tokens.pauseKey) } }

    /// What becomes of a sign-in once it's known whose it is.
    enum SignInDecision {
        case keep
        /// Nothing of it is kept, and an existing connection to that account stays as it was. Not
        /// revoked either: with LP's shared registration that could end the account's access on
        /// another Mac.
        case refuse(any Error)
    }

    /// Signs in through Google's page and returns the connected account. `includeDrive` also asks
    /// for the Drive permission (only files LP creates); `loginHint` suggests the account, but the
    /// person may choose another — `accept` decides about the one chosen before anything is kept.
    static func connect(clientID: String, includeDrive: Bool = false, loginHint: String? = nil,
                        accept: (CalendarAccount) -> SignInDecision = { _ in .keep }) async throws -> GoogleCalendarProvider {
        guard let config = GoogleCalendarMapping.configuration(clientID: clientID, includeDrive: includeDrive, loginHint: loginHint) else {
            throw CalendarSyncError.missingClientID(.google)
        }
        let fresh = try await OAuthSignIn().signIn(config)
        let revocations = OAuthRevocations.count(for: config)
        // The primary calendar's identifier is the account's email address.
        let probe = OAuthTokenStore(config: config, keychainAccount: "pending.google", tokens: fresh,
                                    pauseIdentity: "pending.google." + ServicePause.fingerprint(fresh.accessToken))
        defer { probe.forget() }
        let data = try await AuthorizedClient(tokens: probe).send(AuthorizedClient.jsonRequest("GET", GoogleCalendarMapping.primaryCalendarURL()))
        let email = try GoogleCalendarMapping.primaryCalendarID(from: data)
        let account = CalendarAccount(id: "google:" + email, kind: .google, name: email)
        // Nothing revoked while the account was looked up, before the new tokens are kept.
        try await OAuthRevocations.ensureNone(since: revocations, for: config)
        // Decided after the last wait — what's connected now counts — and before anything is
        // written for that account (making the provider saves its tokens).
        if case .refuse(let error) = accept(account) { throw error }
        return GoogleCalendarProvider(account: account, config: config, tokens: fresh)
    }

    func calendars() async throws -> [SyncCalendar] {
        var all: [SyncCalendar] = []
        var pageToken: String? = nil
        repeat {
            let data = try await client.send(AuthorizedClient.jsonRequest("GET", GoogleCalendarMapping.calendarListURL(pageToken: pageToken)))
            let page = try GoogleCalendarMapping.calendars(from: data, accountID: account.id, accountName: account.name)
            all += page.items
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    func events(in interval: DateInterval, calendars: [SyncCalendar]) async throws -> [SyncEvent] {
        var all: [SyncEvent] = []
        for calendar in calendars {
            var pageToken: String? = nil
            repeat {
                let url = GoogleCalendarMapping.eventsURL(calendarID: calendar.remoteID, interval: interval, pageToken: pageToken)
                let data = try await client.send(AuthorizedClient.jsonRequest("GET", url))
                let page = try GoogleCalendarMapping.events(from: data, calendar: calendar)
                all += page.items
                pageToken = page.nextPageToken
            } while pageToken != nil
        }
        return all
    }

    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent {
        guard calendar.isWritable else { throw CalendarSyncError.readOnlyCalendar }
        let request = AuthorizedClient.jsonRequest("POST", GoogleCalendarMapping.insertURL(calendarID: calendar.remoteID),
                                                   body: GoogleCalendarMapping.body(for: draft))
        return try GoogleCalendarMapping.event(from: try await client.send(request), calendar: calendar)
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
        let calendarID = Self.remoteCalendarID(event)
        if span == .allEvents, let seriesID = event.seriesID {
            // Move the series by the same amount the shown occurrence moved.
            let masterURL = GoogleCalendarMapping.eventURL(calendarID: calendarID, eventID: seriesID)
            let masterData = try await client.send(AuthorizedClient.jsonRequest("GET", masterURL))
            let probe = SyncCalendar(accountID: event.accountID, remoteID: calendarID, title: "", colorHex: "", isWritable: true, sourceTitle: "")
            let master = try GoogleCalendarMapping.event(from: masterData, calendar: probe)
            var seriesDraft = draft.moved(to: master.start.addingTimeInterval(draft.start.timeIntervalSince(event.start)))
            seriesDraft.isAllDay = draft.isAllDay
            let request = AuthorizedClient.jsonRequest("PATCH", masterURL, body: GoogleCalendarMapping.body(for: seriesDraft), ifMatch: master.version)
            _ = try await client.send(request)
        } else {
            let url = GoogleCalendarMapping.eventURL(calendarID: calendarID, eventID: event.remoteID)
            _ = try await client.send(AuthorizedClient.jsonRequest("PATCH", url, body: GoogleCalendarMapping.body(for: draft), ifMatch: event.version))
        }
    }

    func delete(_ event: SyncEvent, span: EditSpan) async throws {
        let target = span == .allEvents ? (event.seriesID ?? event.remoteID) : event.remoteID
        let url = GoogleCalendarMapping.deleteURL(calendarID: Self.remoteCalendarID(event), eventID: target)
        do {
            _ = try await client.send(AuthorizedClient.jsonRequest("DELETE", url))
        } catch CalendarSyncError.notFound {
            // Already gone.
        }
    }

    func disconnect() {
        tokens.disconnect()
    }

    func retire() {
        tokens.retire()
    }

    var pausedUntil: Date? { ServicePause.until(tokens.pauseKey) }

    private static func remoteCalendarID(_ event: SyncEvent) -> String {
        guard let separator = event.calendarID.firstIndex(of: "|") else { return event.calendarID }
        return String(event.calendarID[event.calendarID.index(after: separator)...])
    }
}

// MARK: - Microsoft Outlook

final class MicrosoftCalendarProvider: CalendarProvider {

    let account: CalendarAccount
    var onExternalChange: (() -> Void)?

    private let tokens: OAuthTokenStore
    private var client: AuthorizedClient { AuthorizedClient(tokens: tokens) }

    init(account: CalendarAccount, config: OAuthConfiguration, tokens initial: OAuthTokens? = nil) {
        self.account = account
        tokens = OAuthTokenStore(config: config, keychainAccount: account.id, tokens: initial)
    }

    var hasCredentials: Bool { tokens.hasTokens }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "LTF.Local-Productivity" }

    static func connect(clientID: String) async throws -> MicrosoftCalendarProvider {
        guard let config = MicrosoftGraphMapping.configuration(clientID: clientID, bundleID: bundleID) else {
            throw CalendarSyncError.missingClientID(.microsoft)
        }
        let fresh = try await OAuthSignIn().signIn(config)
        let revocations = OAuthRevocations.count(for: config)
        let probe = OAuthTokenStore(config: config, keychainAccount: "pending.microsoft", tokens: fresh,
                                    pauseIdentity: "pending.microsoft." + ServicePause.fingerprint(fresh.accessToken))
        defer { probe.forget() }
        let data = try await AuthorizedClient(tokens: probe).send(AuthorizedClient.jsonRequest("GET", MicrosoftGraphMapping.defaultCalendarURL()))
        let name = try MicrosoftGraphMapping.accountName(from: data)
        let account = CalendarAccount(id: "microsoft:" + name.lowercased(), kind: .microsoft, name: name)
        try await OAuthRevocations.ensureNone(since: revocations, for: config)
        return MicrosoftCalendarProvider(account: account, config: config, tokens: fresh)
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil, ifMatch: String? = nil) -> URLRequest {
        var request = AuthorizedClient.jsonRequest(method, url, body: body, ifMatch: ifMatch)
        MicrosoftGraphMapping.applyPreferences(to: &request)
        return request
    }

    func calendars() async throws -> [SyncCalendar] {
        var all: [SyncCalendar] = []
        var next: URL? = MicrosoftGraphMapping.calendarsURL()
        while let url = next {
            let page = try MicrosoftGraphMapping.calendars(from: try await client.send(request("GET", url)),
                                                           accountID: account.id, accountName: account.name)
            all += page.items
            next = page.nextLink
        }
        return all
    }

    func events(in interval: DateInterval, calendars: [SyncCalendar]) async throws -> [SyncEvent] {
        var all: [SyncEvent] = []
        for calendar in calendars {
            var next: URL? = MicrosoftGraphMapping.calendarViewURL(calendarID: calendar.remoteID, interval: interval)
            while let url = next {
                let page = try MicrosoftGraphMapping.events(from: try await client.send(request("GET", url)), calendar: calendar)
                all += page.items
                next = page.nextLink
            }
        }
        return all
    }

    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent {
        guard calendar.isWritable else { throw CalendarSyncError.readOnlyCalendar }
        let data = try await client.send(request("POST", MicrosoftGraphMapping.createURL(calendarID: calendar.remoteID),
                                                 body: MicrosoftGraphMapping.body(for: draft)))
        return try MicrosoftGraphMapping.event(from: data, calendar: calendar)
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
        if span == .allEvents, let seriesID = event.seriesID {
            let masterURL = MicrosoftGraphMapping.eventURL(eventID: seriesID)
            let probe = SyncCalendar(accountID: event.accountID, remoteID: "", title: "", colorHex: "", isWritable: true, sourceTitle: "")
            let master = try MicrosoftGraphMapping.event(from: try await client.send(request("GET", masterURL)), calendar: probe)
            var seriesDraft = draft.moved(to: master.start.addingTimeInterval(draft.start.timeIntervalSince(event.start)))
            seriesDraft.isAllDay = draft.isAllDay
            _ = try await client.send(request("PATCH", masterURL, body: MicrosoftGraphMapping.body(for: seriesDraft)))
        } else {
            _ = try await client.send(request("PATCH", MicrosoftGraphMapping.eventURL(eventID: event.remoteID),
                                              body: MicrosoftGraphMapping.body(for: draft)))
        }
    }

    func delete(_ event: SyncEvent, span: EditSpan) async throws {
        let target = span == .allEvents ? (event.seriesID ?? event.remoteID) : event.remoteID
        do {
            _ = try await client.send(request("DELETE", MicrosoftGraphMapping.eventURL(eventID: target)))
        } catch CalendarSyncError.notFound {
            // Already gone.
        }
    }

    func disconnect() {
        tokens.disconnect()
    }

    func retire() {
        tokens.retire()
    }

    var pausedUntil: Date? { ServicePause.until(tokens.pauseKey) }
}
