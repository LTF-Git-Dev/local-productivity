//
//  Widget tests.
//
//  Run with `Scripts/test.sh`. Covers what the widgets read out of the snapshot the app
//  writes, and the links they open LP with.
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

// MARK: - Reading the snapshot for a day

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

let snapshot = WidgetSnapshot(
    generated: at("2026-11-18T08:00:00Z"), workspace: "Notes",
    items: [
        .init(title: "Late", source: "Notes", path: "Notes.md", due: "2026-11-16", time: nil, isCard: false),
        .init(title: "Plan", source: "Notes", path: "Notes.md", due: "2026-11-18", time: nil, isCard: false),
        .init(title: "Call", source: "Notes", path: "Notes.md", due: "2026-11-18", time: 9 * 60, isCard: false),
        .init(title: "Ship", source: "Board", path: "Board.md", due: "2026-11-19", time: nil, isCard: true),
    ],
    events: [
        .init(title: "Done already", start: at("2026-11-18T07:00:00Z"), end: at("2026-11-18T07:30:00Z"), isAllDay: false, location: "", color: nil),
        .init(title: "Review", start: at("2026-11-18T14:00:00Z"), end: at("2026-11-18T15:00:00Z"), isAllDay: false, location: "", color: "#1A63CC"),
        .init(title: "Offsite", start: at("2026-11-18T00:00:00Z"), end: at("2026-11-19T00:00:00Z"), isAllDay: true, location: "", color: nil),
        .init(title: "Tomorrow", start: at("2026-11-19T10:00:00Z"), end: at("2026-11-19T11:00:00Z"), isAllDay: false, location: "", color: nil),
    ],
    boards: [
        .init(path: "Board.md", title: "Board", icon: nil, total: 4, done: 1, lists: [], openDue: ["2026-11-16", "2026-11-19"], modified: at("2026-11-18T08:00:00Z")),
    ])

check(WidgetSnapshot.dayKey(at("2026-11-18T23:30:00Z"), calendar: calendar) == "2026-11-18", "a day key in the given time zone")
check(snapshot.due(on: "2026-11-18").map(\.title) == ["Call", "Plan"], "due today, timed first")
check(snapshot.overdue(on: "2026-11-18").map(\.title) == ["Late"], "overdue before today")
check(snapshot.overdue(on: "2026-11-20").map(\.title) == ["Late", "Call", "Plan", "Ship"], "everything earlier is overdue later, oldest first")
let now = at("2026-11-18T10:00:00Z")
check(snapshot.events(on: now, calendar: calendar).map(\.title) == ["Offsite", "Review"], "events left today, all-day first: \(snapshot.events(on: now, calendar: calendar).map(\.title))")
check(snapshot.boards[0].percent == 25 && snapshot.boards[0].overdue(on: "2026-11-18") == 1, "board progress and overdue count")
check(snapshot.boards[0].overdue(on: "2026-11-20") == 2, "a board's overdue count grows with the days")

// The app and the widget agree on the format.
let encoded = WidgetStore.encode(snapshot)
let file = FileManager.default.temporaryDirectory.appendingPathComponent("lp-widget-test-\(UUID().uuidString).json")
try? encoded?.write(to: file)
check(WidgetStore.load(from: file) == snapshot, "a snapshot reads back as written")
try? FileManager.default.removeItem(at: file)
check(WidgetStore.load(from: file) == nil, "a missing file reads as nothing")

// MARK: - Links

check(LPLink.destination(of: LPLink.home) == .home, "home")
check(LPLink.destination(of: LPLink.boards) == .boards, "boards")
check(LPLink.destination(of: LPLink.calendar(day: "2026-11-18")) == .calendar(day: "2026-11-18"), "a calendar day")
let path = "Projects/Q4 Planning & Notes/Café #2.md"
check(LPLink.destination(of: LPLink.open(path)) == .page(path: path), "a path with spaces, & and # survives: \(LPLink.open(path))")
check(LPLink.destination(of: URL(string: "LocalProductivity://HOME")!) == .home, "scheme and host are case-insensitive")
check(LPLink.destination(of: URL(string: "https://example.com/open?path=x")!) == nil, "other schemes are ignored")
check(LPLink.destination(of: URL(string: "localproductivity://delete?path=x")!) == nil, "unknown actions are ignored")
check(LPLink.destination(of: URL(string: "localproductivity://open")!) == nil, "open needs a path")
// The app refuses to leave the workspace (PathSafety); the link carries the path as given.
check(LPLink.destination(of: LPLink.open("../Secrets.md")) == .page(path: "../Secrets.md"), "paths are passed on for the app to check")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
