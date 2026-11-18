//
//  SampleSnapshot.swift
//  LPWidgets
//
//  A believable day for the widget gallery and previews, shown before LP has written
//  anything of its own.
//

import Foundation

extension WidgetSnapshot {

    static var sample: WidgetSnapshot {
        let now = Date()
        let today = dayKey(now)
        let yesterday = dayKey(now.addingTimeInterval(-86_400))
        let start = Calendar.current.startOfDay(for: now)
        func at(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3600) }
        return WidgetSnapshot(
            generated: now,
            workspace: "Notes",
            items: [
                Item(title: "Fix sign-up on mobile", source: "Launch Board", path: "Launch Board.md", due: yesterday, time: nil, isCard: true),
                Item(title: "Draft the new navigation", source: "Website Redesign", path: "Website Redesign.md", due: today, time: nil, isCard: false),
                Item(title: "Call the printer about proofs", source: "Website Redesign", path: "Website Redesign.md", due: today, time: 14 * 60 + 30, isCard: false),
                Item(title: "Finish the pricing page", source: "Launch Board", path: "Launch Board.md", due: today, time: 16 * 60, isCard: true),
            ],
            events: [
                Event(title: "Standup", start: at(9.5), end: at(9.75), isAllDay: false, location: "Zoom", color: "#1A63CC"),
                Event(title: "Design review", start: at(14), end: at(15), isAllDay: false, location: "Room 4", color: "#8E44AD"),
                Event(title: "Lunch with Sam", start: at(12.5), end: at(13.5), isAllDay: false, location: "Café Leon", color: "#22A06B"),
            ],
            boards: [
                Board(path: "Launch Board.md", title: "Launch Board", icon: "📋", total: 10, done: 3,
                      lists: [List(title: "Backlog", count: 3, marksComplete: false), List(title: "In progress", count: 2, marksComplete: false),
                              List(title: "Review", count: 2, marksComplete: false), List(title: "Done", count: 3, marksComplete: true)],
                      openDue: [yesterday, today], modified: now),
            ])
    }
}
