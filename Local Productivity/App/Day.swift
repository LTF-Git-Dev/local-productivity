//
//  Day.swift
//  Local Productivity
//
//  A calendar day with no time and no time zone attached. Daily notes are named after
//  days and tasks are due on days, so comparing them as plain year-month-day values
//  avoids every "why did my note move to yesterday" time-zone surprise.
//

import Foundation

nonisolated struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {

    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Parses `2026-11-16`. Anything after the date (a time, for instance) is ignored.
    init?(iso text: String) {
        let head = text.prefix(10)
        let parts = head.split(separator: "-", omittingEmptySubsequences: false)
        guard head.count == 10, parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    static var today: Day { Day(Date()) }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    var description: String { iso }

    func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    func adding(days: Int, calendar: Calendar = .current) -> Day {
        Day(calendar.date(byAdding: .day, value: days, to: date(in: calendar)) ?? date(in: calendar), calendar: calendar)
    }

    func adding(months: Int, calendar: Calendar = .current) -> Day {
        Day(calendar.date(byAdding: .month, value: months, to: date(in: calendar)) ?? date(in: calendar), calendar: calendar)
    }

    var startOfMonth: Day { Day(year: year, month: month, day: 1) }

    /// 1 for Sunday through 7 for Saturday.
    func weekday(in calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date(in: calendar))
    }

    static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Finds the first ISO date written anywhere in `text`.
    static func first(in text: String) -> Day? {
        let characters = Array(text)
        guard characters.count >= 10 else { return nil }
        for start in 0...(characters.count - 10) where characters[start].isNumber {
            if start > 0, characters[start - 1].isNumber { continue }
            if let day = Day(iso: String(characters[start..<(start + 10)])) {
                if start + 10 < characters.count, characters[start + 10].isNumber { continue }
                return day
            }
        }
        return nil
    }
}

// MARK: - Times of day

/// A time of day written in a note, such as `14:00`, `9:30` or `2:30 pm`. A task or card that
/// names one is reminded about at that time on the day it is due.
nonisolated struct TimeOfDay: Hashable, Comparable, Sendable, Codable {

    /// Minutes after midnight, 0 to 1439.
    var minutes: Int

    init(minutes: Int) {
        self.minutes = min(max(minutes, 0), 24 * 60 - 1)
    }

    init(hour: Int, minute: Int) {
        self.init(minutes: hour * 60 + minute)
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }

    /// The moment this time falls on `day`.
    func date(on day: Day, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))
            ?? day.date(in: calendar)
    }

    /// "14:00" or "2:00 PM", as the reader's settings write times.
    var title: String {
        date(on: .today).formatted(date: .omitted, time: .shortened)
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutes < rhs.minutes }

    /// A time at the start of `text` (after any spaces) and the text that follows it. Accepts
    /// `14:00`, `9:05`, `2:30pm` and `2:30 PM`; an hour on its own needs am or pm (`9am`).
    static func leading<Text: StringProtocol>(in text: Text) -> (time: TimeOfDay, rest: Text.SubSequence)? {
        var index = text.startIndex
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }

        func digits(max count: Int) -> Int? {
            var value = 0
            var read = 0
            while read < count, index < text.endIndex, let digit = text[index].wholeNumberValue, text[index].isASCII {
                value = value * 10 + digit
                read += 1
                index = text.index(after: index)
            }
            return read == 0 ? nil : value
        }

        guard let hour = digits(max: 2) else { return nil }
        var minute = 0
        var hasMinutes = false
        if index < text.endIndex, text[index] == ":" {
            index = text.index(after: index)
            let start = index
            guard let value = digits(max: 2), text.distance(from: start, to: index) == 2 else { return nil }
            minute = value
            hasMinutes = true
        }

        // An optional am/pm, possibly after one space.
        var meridiem: String? = nil
        var probe = index
        if probe < text.endIndex, text[probe] == " " { probe = text.index(after: probe) }
        let letters = text[probe...].prefix(2).lowercased()
        if letters == "am" || letters == "pm" {
            meridiem = letters
            index = text.index(probe, offsetBy: 2)
        }

        // The time must end at a word boundary: "14:005" and "9amx" are not times.
        if index < text.endIndex, text[index].isLetter || text[index].isNumber { return nil }
        guard minute < 60 else { return nil }
        let hour24: Int
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour24 = (hour % 12) + (meridiem == "pm" ? 12 : 0)
        } else {
            guard hasMinutes, hour < 24 else { return nil }
            hour24 = hour
        }
        return (TimeOfDay(hour: hour24, minute: minute), text[index...])
    }
}

// MARK: - Formatting

nonisolated extension Day {
    /// "Monday, November 16"
    var longTitle: String {
        date().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// "Nov 16" or, in another year, "Nov 16, 2025".
    var shortTitle: String {
        year == Day.today.year
            ? date().formatted(.dateTime.month(.abbreviated).day())
            : date().formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Today", "Yesterday", "Tomorrow", or the short title.
    var relativeTitle: String {
        let today = Day.today
        if self == today { return "Today" }
        if self == today.adding(days: -1) { return "Yesterday" }
        if self == today.adding(days: 1) { return "Tomorrow" }
        return shortTitle
    }
}

nonisolated extension Date {
    /// The compact form for use inside a sentence: "Edited yesterday", "Edited Friday",
    /// "Edited 3 Nov". Only the relative words are lowercased; days and months keep capitals.
    var inlineRelative: String {
        let text = compactRelative
        return text == "Just now" || text == "Yesterday" ? text.lowercased() : text
    }

    /// "Just now", "5 min ago", "Yesterday", "Nov 3" — compact enough for list rows.
    var compactRelative: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let day = Day(self)
        let today = Day.today
        if day == today { return "\(Int(seconds / 3600))h ago" }
        if day == today.adding(days: -1) { return "Yesterday" }
        if seconds < 7 * 86_400 { return formatted(.dateTime.weekday(.wide)) }
        return day.shortTitle
    }
}
