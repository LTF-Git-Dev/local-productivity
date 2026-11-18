//
//  CalendarSyncModels.swift
//  LP
//
//  The shapes calendar sync works with, shared by every provider. Events are plain
//  values; each provider maps them to and from its own service's format, so the rest
//  of the app never needs to know where an event came from.
//
//  Time conventions:
//  - Timed events carry absolute instants (`start`, `end`).
//  - All-day events are "floating": `start` is local midnight of the first day and
//    `end` is local midnight of the day after the last day, whatever time zone the
//    source stored them in.
//

import Foundation

nonisolated enum CalendarProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case apple, google, microsoft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Calendar"
        case .google: return "Google Calendar"
        case .microsoft: return "Microsoft Outlook"
        }
    }
}

/// A connected calendar service. Credentials live in the Keychain, never here.
nonisolated struct CalendarAccount: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier, e.g. "apple" or "google:name@example.com".
    var id: String
    var kind: CalendarProviderKind
    /// The signed-in address, or a description such as "Calendars on this Mac".
    var name: String
}

nonisolated struct SyncCalendar: Codable, Hashable, Identifiable, Sendable {
    var accountID: String
    /// The provider's identifier for the calendar.
    var remoteID: String
    var title: String
    /// "#RRGGBB"
    var colorHex: String
    var isWritable: Bool
    /// Group label shown in pickers, e.g. "iCloud" or the account address.
    var sourceTitle: String

    /// Unique across accounts.
    var id: String { accountID + "|" + remoteID }
}

nonisolated struct SyncEvent: Codable, Hashable, Identifiable, Sendable {
    var accountID: String
    /// `SyncCalendar.id` of the calendar the event belongs to.
    var calendarID: String
    /// The provider's identifier for this occurrence.
    var remoteID: String
    /// For an occurrence of a repeating event, the provider's identifier for the whole series.
    var seriesID: String?
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String = ""
    var notes: String = ""
    var url: URL? = nil
    /// Version tag used to notice edits made elsewhere (Google etag, Microsoft changeKey).
    var version: String? = nil

    /// Unique across accounts.
    var id: String { calendarID + "|" + remoteID }

    var isRecurring: Bool { seriesID != nil }

    /// The days the event appears on, in the current calendar.
    func days(calendar: Calendar = .current) -> [Day] {
        let first = Day(start, calendar: calendar)
        // The end is exclusive: an event ending at midnight does not touch the next day.
        let lastInstant = end > start ? end.addingTimeInterval(-1) : start
        let last = Day(lastInstant, calendar: calendar)
        guard first < last else { return [first] }
        var days: [Day] = []
        var day = first
        while day <= last, days.count < 62 {
            days.append(day)
            day = day.adding(days: 1, calendar: calendar)
        }
        return days
    }
}

/// What the event editor produces, and what providers turn into a create or update request.
nonisolated struct EventDraft: Hashable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String = ""
    var notes: String = ""

    init(title: String, start: Date, end: Date, isAllDay: Bool, location: String = "", notes: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }

    init(_ event: SyncEvent) {
        self.init(title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                  location: event.location, notes: event.notes)
    }

    /// The draft with its dates moved so that it starts at `newStart`, keeping its length.
    func moved(to newStart: Date) -> EventDraft {
        var copy = self
        copy.end = newStart.addingTimeInterval(end.timeIntervalSince(start))
        copy.start = newStart
        return copy
    }
}

/// Which occurrences a change to a repeating event applies to.
nonisolated enum EditSpan: Sendable {
    case thisEvent
    case allEvents
}

nonisolated enum CalendarSyncError: LocalizedError, Equatable {
    case notConnected
    case missingClientID(CalendarProviderKind)
    case accessDenied
    case signInRequired
    case conflict
    case notFound
    case readOnlyCalendar
    case cancelled
    case invalidResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "This calendar account isn’t connected."
        case .missingClientID(let kind):
            return "Add a client ID for \(kind.title) in Settings → Calendars first."
        case .accessDenied:
            return "LP doesn’t have permission to use this calendar."
        case .signInRequired:
            return "Your sign-in has expired. Reconnect the account in Settings → Calendars."
        case .conflict:
            return "The event was changed somewhere else at the same time. LP has refreshed it — please try again."
        case .notFound:
            return "The event no longer exists. It may have been deleted somewhere else."
        case .readOnlyCalendar:
            return "This calendar is read-only."
        case .cancelled:
            return "Sign-in was cancelled."
        case .invalidResponse:
            return "The calendar service sent a response LP couldn’t read."
        case .server(let status, let message):
            return message.isEmpty ? "The calendar service returned an error (\(status))." : message
        }
    }
}

// MARK: - Date helpers shared by the mappings

nonisolated enum CalendarDates {

    /// Local midnight at the start of the given date's day.
    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Parses "2026-11-17" as local midnight (all-day dates float).
    static func localDate(fromDayString text: String, calendar: Calendar = .current) -> Date? {
        guard let day = Day(iso: text) else { return nil }
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    /// "2026-11-17" for the local day the date falls on.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        Day(date, calendar: calendar).iso
    }

    /// RFC 3339 / ISO 8601 with or without fractional seconds.
    static func parseRFC3339(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
