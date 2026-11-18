//
//  ReminderPlanner.swift
//  LP
//
//  Decides which notifications LP keeps waiting with the system: a reminder on the day each
//  open task or card is due, an alert before calendar events, and a short summary of the day
//  each morning. Pure and Foundation-only, so it is covered by tests; `ReminderCenter` hands
//  the result to the system.
//

import Foundation

/// What the person asked to be reminded about (Settings → Notifications).
nonisolated struct ReminderSettings: Hashable, Sendable {
    /// A reminder on the day a task or card is due.
    var remindsDueItems = true
    /// When items that name no time of their own are reminded about.
    var dueTime = TimeOfDay(hour: 9, minute: 0)
    /// A summary of the day: what is due, what is overdue, what is on the calendar.
    var sendsDailySummary = true
    var summaryTime = TimeOfDay(hour: 8, minute: 30)
    /// Minutes before a timed event to alert; nil turns event alerts off.
    var eventLeadMinutes: Int? = 10
    /// Apple Calendar shows its own alerts for its events, so LP leaves them out unless asked.
    var includesAppleCalendarEvents = false

    static let leadChoices = [0, 5, 10, 15, 30, 60]
}

/// An open task or card with a due date.
nonisolated struct ReminderTask: Hashable, Sendable {
    var path: String
    var text: String
    /// The page or board it is on.
    var source: String
    var due: Day
    var time: TimeOfDay? = nil
    var isCard = false
    var cardID: String? = nil
}

nonisolated struct ReminderEvent: Hashable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String = ""
    var isFromAppleCalendar = false
}

/// One notification to have waiting with the system.
nonisolated struct PlannedReminder: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case task, event, summary }

    /// The system identifier. It changes whenever anything shown changes, so an edited task
    /// replaces its old reminder rather than sitting next to it.
    var id: String
    var kind: Kind
    var date: Date
    var title: String
    var subtitle: String
    var body: String
    /// What tapping it opens and what its buttons act on. Strings only, so it can travel with
    /// the notification.
    var info: [String: String]
}

/// Keys of `PlannedReminder.info`.
nonisolated enum ReminderInfo {
    static let kind = "kind"
    static let path = "path"
    static let text = "text"
    static let cardID = "cardID"
    static let day = "day"
    static let time = "time"
}

nonisolated enum ReminderPlanner {

    /// macOS keeps at most 64 waiting notifications for an app; the soonest are kept.
    static let systemLimit = 64
    /// How far ahead reminders are planned. LP plans again whenever it runs.
    static let horizonDays = 7

    /// `tasks` are the open tasks and cards that have a due date; `events` are those of the
    /// visible calendars.
    static func plan(tasks: [ReminderTask], events: [ReminderEvent], settings: ReminderSettings, now: Date,
                     calendar: Calendar = .current, limit: Int = systemLimit) -> [PlannedReminder] {
        let horizon = now.addingTimeInterval(Double(horizonDays) * 86_400)
        var planned: [PlannedReminder] = []

        if settings.remindsDueItems {
            for task in tasks {
                let time = task.time ?? settings.dueTime
                let date = time.date(on: task.due, calendar: calendar)
                guard date > now, date <= horizon else { continue }
                planned.append(reminder(for: task, at: date, hasOwnTime: task.time != nil, calendar: calendar))
            }
        }

        if let lead = settings.eventLeadMinutes {
            for event in events where !event.isAllDay && (settings.includesAppleCalendarEvents || !event.isFromAppleCalendar) {
                let date = event.start.addingTimeInterval(-Double(lead) * 60)
                guard date > now, date <= horizon else { continue }
                planned.append(alert(for: event, at: date, calendar: calendar))
            }
        }

        if settings.sendsDailySummary {
            let today = Day(now, calendar: calendar)
            for offset in 0...horizonDays {
                let day = today.adding(days: offset, calendar: calendar)
                let date = settings.summaryTime.date(on: day, calendar: calendar)
                guard date > now, date <= horizon else { continue }
                if let summary = summary(of: day, at: date, tasks: tasks, events: events, calendar: calendar) {
                    planned.append(summary)
                }
            }
        }

        // The same task written twice plans the same reminder twice; the system would show one.
        var seen = Set<String>()
        return planned
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: Reminders

    private static func reminder(for task: ReminderTask, at date: Date, hasOwnTime: Bool, calendar: Calendar) -> PlannedReminder {
        let subtitle = hasOwnTime ? "Due at \(timeText(date, calendar: calendar))" : "Due today"
        var info = [ReminderInfo.kind: PlannedReminder.Kind.task.rawValue, ReminderInfo.path: task.path,
                    ReminderInfo.text: task.text, ReminderInfo.day: task.due.iso]
        if let time = task.time { info[ReminderInfo.time] = String(time.minutes) }
        if let cardID = task.cardID { info[ReminderInfo.cardID] = cardID }
        return PlannedReminder(id: identifier(.task, date, [task.path, task.text, task.source, subtitle]),
                               kind: .task, date: date, title: task.text, subtitle: subtitle, body: task.source, info: info)
    }

    private static func alert(for event: ReminderEvent, at date: Date, calendar: Calendar) -> PlannedReminder {
        let title = event.title.isEmpty ? "Untitled event" : event.title
        let subtitle = "\(timeText(event.start, calendar: calendar)) – \(timeText(event.end, calendar: calendar))"
        let info = [ReminderInfo.kind: PlannedReminder.Kind.event.rawValue, ReminderInfo.day: Day(event.start, calendar: calendar).iso]
        return PlannedReminder(id: identifier(.event, date, [event.id, title, subtitle, event.location]),
                               kind: .event, date: date, title: title, subtitle: subtitle, body: event.location, info: info)
    }

    /// Nil on a day with nothing due, nothing overdue and nothing on the calendar.
    private static func summary(of day: Day, at date: Date, tasks: [ReminderTask], events: [ReminderEvent],
                                calendar: Calendar) -> PlannedReminder? {
        // Items with a time first, in time order; the rest after them.
        let untimed = TimeOfDay(minutes: 24 * 60 - 1)
        let due = tasks.filter { $0.due == day }.sorted { ($0.time ?? untimed, $0.text) < ($1.time ?? untimed, $1.text) }
        let overdue = tasks.filter { $0.due < day }
        let dayStart = calendar.startOfDay(for: day.date(in: calendar))
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let onDay = events
            .filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        guard !due.isEmpty || !overdue.isEmpty || !onDay.isEmpty else { return nil }

        var counts: [String] = []
        if !due.isEmpty { counts.append("\(due.count) due") }
        if !overdue.isEmpty { counts.append("\(overdue.count) overdue") }
        if !onDay.isEmpty { counts.append(onDay.count == 1 ? "1 event" : "\(onDay.count) events") }

        var lines: [String] = []
        if !due.isEmpty { lines.append("Due: " + listed(due.map(\.text))) }
        if !overdue.isEmpty { lines.append("Overdue: " + listed(overdue.sorted { ($0.due, $0.text) < ($1.due, $1.text) }.map(\.text))) }
        if !onDay.isEmpty {
            lines.append("Calendar: " + listed(onDay.map { event in
                let title = event.title.isEmpty ? "Untitled event" : event.title
                return event.isAllDay || event.start < dayStart ? title : "\(timeText(event.start, calendar: calendar)) \(title)"
            }))
        }
        let subtitle = counts.joined(separator: " · ")
        let body = lines.joined(separator: "\n")
        let info = [ReminderInfo.kind: PlannedReminder.Kind.summary.rawValue, ReminderInfo.day: day.iso]
        return PlannedReminder(id: identifier(.summary, date, [day.iso, subtitle, body]),
                               kind: .summary, date: date, title: "Your day", subtitle: subtitle, body: body, info: info)
    }

    // MARK: Helpers

    /// "A, B and 2 more".
    static func listed(_ items: [String], showing count: Int = 3) -> String {
        let shown = Array(items.prefix(count))
        let rest = items.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        guard shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
    }

    private static func timeText(_ date: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style)
    }

    /// Identifiers are stable across launches (unlike `Hasher`), so a reminder that is
    /// already waiting is recognised and left alone.
    private static func identifier(_ kind: PlannedReminder.Kind, _ date: Date, _ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (parts + [String(Int(date.timeIntervalSince1970))]).joined(separator: "\u{1F}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return "lp.\(kind.rawValue).\(String(hash, radix: 36))"
    }
}
