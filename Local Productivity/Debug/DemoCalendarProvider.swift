//
//  DemoCalendarProvider.swift
//  LP
//
//  An in-memory calendar account for UI snapshots and end-to-end checks of the sync
//  store, so calendar features can be exercised without a real account. Debug only.
//

#if DEBUG
import Foundation

final class DemoCalendarProvider: CalendarProvider {

    /// Named like a real Google account ("google:<address>"), which sharing to Drive expects.
    static let accountID = "google:demo@example.com"
    let account = CalendarAccount(id: DemoCalendarProvider.accountID, kind: .google, name: "demo@example.com")
    var onExternalChange: (() -> Void)?

    private let all: [SyncCalendar]
    private var stored: [SyncEvent] = []
    /// How many times events were fetched (all demo accounts), for `calendar-state`.
    static var fetches = 0
    private var hasLimited = false
    private static let pauseKey = "calendar.demo"

    var pausedUntil: Date? { ServicePause.until(Self.pauseKey) }

    init() {
        func calendar(_ id: String, _ title: String, _ color: String, writable: Bool = true) -> SyncCalendar {
            SyncCalendar(accountID: DemoCalendarProvider.accountID, remoteID: id, title: title, colorHex: color, isWritable: writable, sourceTitle: "demo@example.com")
        }
        let work = calendar("work", "Work", "#3B82F6")
        let personal = calendar("personal", "Personal", "#22A06B")
        let holidays = calendar("holidays", "Holidays", "#E5484D", writable: false)
        all = [work, personal, holidays]

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today)!
        }
        func add(_ calendar: SyncCalendar, _ title: String, _ start: Date, _ end: Date, allDay: Bool = false,
                 location: String = "", series: String? = nil) {
            stored.append(SyncEvent(accountID: DemoCalendarProvider.accountID, calendarID: calendar.id, remoteID: UUID().uuidString, seriesID: series,
                                    title: title, start: start, end: end, isAllDay: allDay, location: location))
        }

        // A weekday standup that repeats across the whole window.
        for offset in -45...75 {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            let weekday = cal.component(.weekday, from: day)
            guard weekday != 1, weekday != 7 else { continue }
            add(work, "Standup", at(offset, 9, 30), at(offset, 9, 45), location: "Zoom", series: "standup")
        }
        add(work, "Design review", at(0, 14), at(0, 15), location: "Room 4")
        add(personal, "Lunch with Sam", at(1, 12, 30), at(1, 13, 30), location: "Café Leon")
        add(personal, "Dentist", at(2, 10), at(2, 11))
        add(work, "Team offsite", at(5, 0), at(8, 0), allDay: true, location: "Lisbon")
        add(work, "Quarterly planning", at(3, 13), at(3, 16))
        add(personal, "Flight to Kyoto", at(9, 22), at(10, 6))
        add(holidays, "Public holiday", at(-3, 0), at(-2, 0), allDay: true)
        add(personal, "Yoga", at(-1, 18), at(-1, 19))
    }

    func calendars() async throws -> [SyncCalendar] {
        all
    }

    func events(in interval: DateInterval, calendars: [SyncCalendar]) async throws -> [SyncEvent] {
        // Like the real clients: nothing goes out while the service asked LP to wait.
        if let until = pausedUntil { throw CalendarSyncError.rateLimited(until) }
        Self.fetches += 1
        // LP_DEMO_CALENDAR_LIMIT=<seconds>[@<n>]: the first (or n-th) fetch answers "too many
        // requests — wait that long", to check that LP waits as asked.
        let limit = (ProcessInfo.processInfo.environment["LP_DEMO_CALENDAR_LIMIT"] ?? "").split(separator: "@").map(String.init)
        if !hasLimited, let wait = limit.first.flatMap(Double.init), wait > 0,
           Self.fetches >= (limit.count > 1 ? Int(limit[1]) ?? 1 : 1) {
            hasLimited = true
            throw CalendarSyncError.rateLimited(ServicePause.record(Self.pauseKey, until: Date().addingTimeInterval(wait)))
        }
        let wanted = Set(calendars.map(\.id))
        let answer = stored.filter { wanted.contains($0.calendarID) && $0.end > interval.start && $0.start < interval.end }
        // LP_DEMO_CALENDAR_DELAY=<seconds>: a slow service, answering with what it had when asked —
        // to check that a late, out-of-date answer can't undo a change made meanwhile.
        if let delay = Double(ProcessInfo.processInfo.environment["LP_DEMO_CALENDAR_DELAY"] ?? ""), delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        return answer
    }

    /// LP_DEMO_CALENDAR_WRITE_DELAY=<seconds>: changes take this long to be confirmed.
    private func slowWrite() async throws {
        if let until = pausedUntil { throw CalendarSyncError.rateLimited(until) }
        if let delay = Double(ProcessInfo.processInfo.environment["LP_DEMO_CALENDAR_WRITE_DELAY"] ?? ""), delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent {
        guard calendar.isWritable else { throw CalendarSyncError.readOnlyCalendar }
        try await slowWrite()
        let event = SyncEvent(accountID: DemoCalendarProvider.accountID, calendarID: calendar.id, remoteID: UUID().uuidString, title: draft.title,
                              start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location, notes: draft.notes)
        stored.append(event)
        return event
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
        try await slowWrite()
        let shift = draft.start.timeIntervalSince(event.start)
        let length = draft.end.timeIntervalSince(draft.start)
        for index in stored.indices {
            let matches = span == .allEvents && event.seriesID != nil
                ? stored[index].seriesID == event.seriesID
                : stored[index].remoteID == event.remoteID
            guard matches else { continue }
            stored[index].title = draft.title
            stored[index].location = draft.location
            stored[index].notes = draft.notes
            stored[index].isAllDay = draft.isAllDay
            stored[index].start = stored[index].start.addingTimeInterval(shift)
            stored[index].end = stored[index].start.addingTimeInterval(length)
        }
    }

    func delete(_ event: SyncEvent, span: EditSpan) async throws {
        try await slowWrite()
        if span == .allEvents, let series = event.seriesID {
            stored.removeAll { $0.seriesID == series }
        } else {
            stored.removeAll { $0.remoteID == event.remoteID }
        }
    }

    func disconnect() {}
}
#endif

#if DEBUG
/// The demo calendar account's Drive, kept in memory, for checking Drive sharing in the harness:
/// `demo-drive` turns it on (as if Drive were allowed); its options (comma-separated) make the next
/// n deletions fail as if offline (`fail-deletes=<n>`), the next n "let anyone view it" fail with
/// "slow down" (`fail-publishes=<n>`), or uploads and updates take that many seconds (`slow=<seconds>`).
@MainActor
final class DemoDriveBackend: DriveBackend {
    static let shared = DemoDriveBackend()
    static var isOn = false

    struct Page {
        var name: String
        var html: String
        var isPublic = false
    }

    private(set) var pages: [String: Page] = [:]
    var failingDeletes = 0
    var failingPublishes = 0
    var delay: Double = 0

    func upload(name: String, html: String) async throws -> String {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        let id = "demo" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        pages[id] = Page(name: name, html: html)
        return id
    }

    func makePublic(fileID: String) async throws {
        if failingPublishes > 0 {
            failingPublishes -= 1
            throw DriveSharingError.rateLimited(Date().addingTimeInterval(60))
        }
        guard pages[fileID] != nil else { throw CalendarSyncError.notFound }
        pages[fileID]?.isPublic = true
    }

    func update(fileID: String, name: String, html: String) async throws {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        guard pages[fileID] != nil else { throw CalendarSyncError.notFound }
        pages[fileID]?.name = name
        pages[fileID]?.html = html
    }

    func delete(fileID: String) async throws {
        if failingDeletes > 0 {
            failingDeletes -= 1
            // Worded the way a real one is.
            throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        }
        pages[fileID] = nil
    }

    var pausedUntil: Date? { nil }
}

extension DemoCalendarProvider {
    var driveBackend: DriveBackend? { DemoDriveBackend.isOn ? DemoDriveBackend.shared : nil }
}
#endif
