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

    let account = CalendarAccount(id: "demo", kind: .google, name: "demo@example.com")
    var onExternalChange: (() -> Void)?

    private let all: [SyncCalendar]
    private var stored: [SyncEvent] = []

    init() {
        func calendar(_ id: String, _ title: String, _ color: String, writable: Bool = true) -> SyncCalendar {
            SyncCalendar(accountID: "demo", remoteID: id, title: title, colorHex: color, isWritable: writable, sourceTitle: "demo@example.com")
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
            stored.append(SyncEvent(accountID: "demo", calendarID: calendar.id, remoteID: UUID().uuidString, seriesID: series,
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
        let wanted = Set(calendars.map(\.id))
        return stored.filter { wanted.contains($0.calendarID) && $0.end > interval.start && $0.start < interval.end }
    }

    func create(_ draft: EventDraft, in calendar: SyncCalendar) async throws -> SyncEvent {
        guard calendar.isWritable else { throw CalendarSyncError.readOnlyCalendar }
        let event = SyncEvent(accountID: "demo", calendarID: calendar.id, remoteID: UUID().uuidString, title: draft.title,
                              start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location, notes: draft.notes)
        stored.append(event)
        return event
    }

    func update(_ event: SyncEvent, with draft: EventDraft, span: EditSpan) async throws {
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
        if span == .allEvents, let series = event.seriesID {
            stored.removeAll { $0.seriesID == series }
        } else {
            stored.removeAll { $0.remoteID == event.remoteID }
        }
    }

    func disconnect() {}
}
#endif
