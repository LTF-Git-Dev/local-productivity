//
//  WidgetPublisher.swift
//  LP
//
//  Keeps the widgets' snapshot current: what is due, what is on the calendar and how the
//  boards are doing. Writes only when something the widgets show has changed.
//

import Foundation
import WidgetKit

final class WidgetPublisher {

    /// The last snapshot handed over, without its time stamp.
    private var published: Data?

    func publish(_ snapshot: WidgetSnapshot) {
        var comparable = snapshot
        comparable.generated = .distantPast
        guard let key = WidgetStore.encode(comparable), key != published,
              let data = WidgetStore.encode(snapshot) else { return }
        published = key
        #if DEBUG
        // Lets UI snapshots check what the widgets would be given.
        if let path = ProcessInfo.processInfo.environment["LP_WIDGET_SNAPSHOT"] {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
        guard let url = WidgetStore.fileURL else { return }
        do {
            try data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Tried again on the next change.
            published = nil
        }
    }
}

extension AppModel {

    /// Everything the widgets need, from the open workspace and the visible calendars.
    func widgetSnapshot(for workspace: Workspace, now: Date = Date()) -> WidgetSnapshot {
        let today = Day(now)
        let horizon = today.adding(days: 14)
        var upcoming: [WidgetSnapshot.Item] = []
        var overdue: [WidgetSnapshot.Item] = []
        var boards: [WidgetSnapshot.Board] = []

        for meta in workspace.meta.values {
            for task in meta.tasks where !task.isDone {
                guard let due = task.due, due <= horizon else { continue }
                let item = WidgetSnapshot.Item(title: task.text, source: meta.displayTitle, path: task.path, due: due.iso,
                                               time: task.dueTime?.minutes, isCard: task.isBoardCard)
                if due < today { overdue.append(item) } else { upcoming.append(item) }
            }
            if let summary = meta.board {
                boards.append(WidgetSnapshot.Board(
                    path: meta.path, title: meta.title, icon: meta.icon, total: summary.total, done: summary.done,
                    lists: summary.lists.map { WidgetSnapshot.List(title: $0.title, count: $0.count, marksComplete: $0.marksComplete) },
                    openDue: summary.openDue.map(\.iso), modified: meta.modified))
            }
        }
        // Kept small: what is coming first, then the most recent of what is overdue.
        let order: (WidgetSnapshot.Item, WidgetSnapshot.Item) -> Bool = {
            ($0.due, $0.time ?? 24 * 60, $0.title, $0.path) < ($1.due, $1.time ?? 24 * 60, $1.title, $1.path)
        }
        let items = Array(overdue.sorted(by: order).suffix(100)) + Array(upcoming.sorted(by: order).prefix(200))

        let start = Calendar.current.startOfDay(for: now)
        let end = start.addingTimeInterval(15 * 86_400)
        let colors = Dictionary(calendarSync.calendars.map { ($0.id, $0.colorHex) }, uniquingKeysWith: { first, _ in first })
        let events = calendarSync.events
            .filter { !calendarSync.hiddenCalendarIDs.contains($0.calendarID) && $0.end > start && $0.start < end }
            .sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
            .prefix(150)
            .map { WidgetSnapshot.Event(title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay,
                                        location: $0.location, color: colors[$0.calendarID]) }

        return WidgetSnapshot(generated: now, workspace: workspace.name, items: items, events: Array(events),
                              boards: Array(boards.sorted { ($0.modified, $0.path) > ($1.modified, $1.path) }.prefix(24)))
    }
}
