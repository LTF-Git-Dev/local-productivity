//
//  Reminder tests.
//
//  Run with `Scripts/test.sh`. Covers reading times written in notes and planning which
//  notifications to keep waiting with the system.
//

import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("✗ line \(line): \(message())")
    }
}

// MARK: - Times written in notes

func time(_ text: String) -> Int? { TimeOfDay.leading(in: text)?.time.minutes }

check(time("14:00") == 840, "24-hour time")
check(time("9:05") == 545, "single-digit hour")
check(time(" 2:30pm") == 870, "pm, after a space")
check(time("2:30 PM") == 870, "PM after a space")
check(time("9am") == 540, "an hour with am")
check(time("9 am") == 540, "an hour, a space and am")
check(time("12am") == 0, "midnight")
check(time("12:15pm") == 735, "just after noon")
check(time("0:00") == 0, "midnight on the 24-hour clock")
check(time("23:59") == 1439, "the last minute")
check(time("24:00") == nil, "24:00 is not a time of day")
check(time("13pm") == nil, "13pm is not a time")
check(time("9") == nil, "a bare number is not a time")
check(time("14:5") == nil, "minutes need two digits")
check(time("14:60") == nil, "no 60th minute")
check(time("14:005") == nil, "a time ends at a word boundary")
check(time("9amx") == nil, "am must stand alone")
check(time("2026") == nil, "a year is not a time")
check(time("") == nil, "nothing")
check(TimeOfDay.leading(in: "14:00 call back")?.rest == " call back", "the rest of the text is returned")
check(TimeOfDay.leading(in: "9:30-10:00")?.time.minutes == 570, "a range starts with a time")

// MARK: - Planning

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
calendar.locale = Locale(identifier: "en_GB")

func at(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = calendar.timeZone
    return formatter.date(from: text)!
}

let now = at("2026-11-18T08:00:00Z")
let today = Day(year: 2026, month: 11, day: 18)
let tasks = [
    ReminderTask(path: "Projects/Site.md", text: "Send the invoice", source: "Site", due: today),
    ReminderTask(path: "Projects/Site.md", text: "Early call", source: "Site", due: today, time: TimeOfDay(hour: 7, minute: 0)),
    ReminderTask(path: "Notes.md", text: "Call Mina", source: "Notes", due: Day(year: 2026, month: 11, day: 20), time: TimeOfDay(hour: 14, minute: 0)),
    ReminderTask(path: "Notes.md", text: "Far away", source: "Notes", due: Day(year: 2026, month: 11, day: 30)),
    ReminderTask(path: "Notes.md", text: "Late already", source: "Notes", due: Day(year: 2026, month: 11, day: 10)),
    ReminderTask(path: "Board.md", text: "Ship it", source: "Launch Board", due: Day(year: 2026, month: 11, day: 19), isCard: true, cardID: "c1",
                 boardID: "blaunch1"),
]
let events = [
    ReminderEvent(id: "e1", title: "Standup", start: at("2026-11-18T10:00:00Z"), end: at("2026-11-18T10:15:00Z"), isAllDay: false, location: "Room 2"),
    ReminderEvent(id: "e2", title: "Offsite", start: at("2026-11-18T00:00:00Z"), end: at("2026-11-19T00:00:00Z"), isAllDay: true),
    ReminderEvent(id: "e3", title: "Dentist", start: at("2026-11-18T12:00:00Z"), end: at("2026-11-18T13:00:00Z"), isAllDay: false, isFromAppleCalendar: true),
    ReminderEvent(id: "e4", title: "Too soon", start: at("2026-11-18T08:05:00Z"), end: at("2026-11-18T08:30:00Z"), isAllDay: false),
]
let settings = ReminderSettings()
let plan = ReminderPlanner.plan(tasks: tasks, events: events, settings: settings, now: now, calendar: calendar)
func planned(_ title: String) -> PlannedReminder? { plan.first { $0.title == title } }

check(planned("Send the invoice")?.date == at("2026-11-18T09:00:00Z"), "a task without a time is reminded at the usual time")
check(planned("Send the invoice")?.subtitle == "Due today", "and says it is due today")
check(planned("Early call") == nil, "a time that has passed is not reminded")
check(planned("Call Mina")?.date == at("2026-11-20T14:00:00Z"), "a task with its own time is reminded then")
check(planned("Call Mina")?.subtitle == "Due at 14:00", "and says when: \(planned("Call Mina")?.subtitle ?? "-")")
check(planned("Far away") == nil, "nothing beyond a week")
check(planned("Late already") == nil, "overdue tasks are not reminded one by one")
check(planned("Ship it")?.info[ReminderInfo.cardID] == "c1" && planned("Ship it")?.body == "Launch Board", "a card remembers its board and ID")
check(planned("Ship it")?.info[ReminderInfo.board] == "blaunch1", "and the board's own ID, so another board in its file isn't changed")
check(planned("Send the invoice")?.info[ReminderInfo.board] == nil, "a page task names no board")
do {
    // A card's reminder changes when its board gets an ID, so the one waiting is replaced by one
    // that carries it.
    var card = ReminderTask(path: "Board.md", text: "Ship it", source: "Launch Board", due: Day(year: 2026, month: 11, day: 19), isCard: true, cardID: "c1")
    let before = ReminderPlanner.plan(tasks: [card], events: [], settings: settings, now: now, calendar: calendar).first { $0.title == "Ship it" }?.id
    card.boardID = "blaunch1"
    let after = ReminderPlanner.plan(tasks: [card], events: [], settings: settings, now: now, calendar: calendar).first { $0.title == "Ship it" }?.id
    check(before != nil && after != nil && before != after, "a card's reminder is new once its board has an ID")
}
check(ReminderPlanner.plan(tasks: tasks, events: events, settings: ReminderSettings(isEnabled: false), now: now, calendar: calendar).isEmpty,
      "with Notifications switched off nothing is planned")
check(planned("Standup")?.date == at("2026-11-18T09:50:00Z"), "an event is alerted ten minutes before")
check(planned("Standup")?.subtitle == "10:00 – 10:15" && planned("Standup")?.body == "Room 2", "with its times and place")
check(planned("Offsite") == nil, "all-day events have no alert")
check(planned("Dentist") == nil, "Apple Calendar events are left to Apple Calendar")
check(planned("Too soon") == nil, "an alert time that has passed is skipped")
check(plan.map(\.date) == plan.map(\.date).sorted(), "reminders are in time order")

let summary = plan.first { $0.kind == .summary && $0.info[ReminderInfo.day] == today.iso }
check(summary?.date == at("2026-11-18T08:30:00Z"), "today's summary comes at the usual time")
check(summary?.subtitle == "2 due · 1 overdue · 4 events", "the summary counts what matters: \(summary?.subtitle ?? "-")")
check(summary?.body.contains("Due: Early call and Send the invoice") == true, "it names what is due: \(summary?.body ?? "-")")
check(summary?.body.contains("Overdue: Late already") == true, "and what is overdue")
check(summary?.body.contains("Calendar: Offsite, 8:05 Too soon, 10:00 Standup and 1 more") == true, "and the calendar: \(summary?.body ?? "-")")
let quietDay = Day(year: 2026, month: 11, day: 22)
let quiet = ReminderPlanner.plan(tasks: [], events: [], settings: settings, now: now, calendar: calendar)
check(quiet.isEmpty, "nothing to say means no summary at all")
check(!plan.contains { $0.kind == .summary && $0.info[ReminderInfo.day] == quietDay.iso && $0.subtitle.isEmpty }, "no empty summaries")

// MARK: - Workspaces

do {
    let first = ReminderPlanner.plan(tasks: tasks, events: events, settings: settings, now: now, workspace: "W1", calendar: calendar)
    let again = ReminderPlanner.plan(tasks: tasks, events: events, settings: settings, now: now, workspace: "W1", calendar: calendar)
    let other = ReminderPlanner.plan(tasks: tasks, events: events, settings: settings, now: now, workspace: "W2", calendar: calendar)
    check(first.allSatisfy { $0.info[ReminderInfo.workspace] == "W1" }, "every reminder carries its workspace")
    check(first.map(\.id) == again.map(\.id), "its identifiers stay the same between launches")
    check(Set(first.map(\.id)).isDisjoint(with: Set(other.map(\.id))), "the same task in another workspace is another reminder")
    check(Set(first.map(\.id)).isDisjoint(with: Set(plan.map(\.id))), "reminders planned before workspaces were stamped are replaced")
    check(first.allSatisfy { $0.id.hasPrefix("lp.\($0.kind.rawValue).") }, "and keep the form that finds stale ones")
}

do {
    var withApple = settings
    withApple.includesAppleCalendarEvents = true
    withApple.eventLeadMinutes = 0
    let alerts = ReminderPlanner.plan(tasks: [], events: events, settings: withApple, now: now, calendar: calendar).filter { $0.kind == .event }
    check(alerts.contains { $0.title == "Dentist" && $0.date == at("2026-11-18T12:00:00Z") }, "Apple Calendar events when asked, at the start time")
}
do {
    var off = settings
    off.remindsDueItems = false
    off.eventLeadMinutes = nil
    off.sendsDailySummary = false
    check(ReminderPlanner.plan(tasks: tasks, events: events, settings: off, now: now, calendar: calendar).isEmpty, "everything off plans nothing")
}
do {
    // Stable identity: planning again changes nothing; editing a task changes its reminder.
    let again = ReminderPlanner.plan(tasks: tasks, events: events, settings: settings, now: now, calendar: calendar)
    check(again.map(\.id) == plan.map(\.id), "the same state gives the same identifiers")
    var edited = tasks
    edited[0].text = "Send the final invoice"
    let changed = ReminderPlanner.plan(tasks: edited, events: events, settings: settings, now: now, calendar: calendar)
    check(Set(changed.map(\.id)) != Set(plan.map(\.id)), "an edited task gets a new identifier")
    check(changed.allSatisfy { $0.id.hasPrefix("lp.") }, "identifiers carry LP's prefix")
}
do {
    // The same task written twice is reminded once; the system's limit is respected.
    let twice = ReminderPlanner.plan(tasks: [tasks[0], tasks[0]], events: [], settings: settings, now: now, calendar: calendar)
    check(twice.filter { $0.kind == .task }.count == 1, "a duplicate task is reminded once")
    let many = (0..<100).map { ReminderTask(path: "Many.md", text: "Task \($0)", source: "Many", due: today.adding(days: 1 + $0 % 5, calendar: calendar)) }
    let capped = ReminderPlanner.plan(tasks: many, events: [], settings: settings, now: now, calendar: calendar)
    check(capped.count == ReminderPlanner.systemLimit, "never more than the system keeps (\(capped.count))")
    check(capped.first?.kind == .summary, "the soonest are kept")
}

// MARK: - Wording

check(ReminderPlanner.listed(["A"]) == "A", "one item")
check(ReminderPlanner.listed(["A", "B"]) == "A and B", "two items")
check(ReminderPlanner.listed(["A", "B", "C"]) == "A, B and C", "three items")
check(ReminderPlanner.listed(["A", "B", "C", "D", "E"]) == "A, B, C and 2 more", "more than three")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
