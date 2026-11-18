//
//  TodayWidget.swift
//  LPWidgets
//
//  The day at a glance: what is due, what is overdue and what is still to come on the
//  calendar. Tapping opens LP; tapping an item opens its page.
//

import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var state: WidgetState

    var day: String { WidgetSnapshot.dayKey(date) }
    var due: [WidgetSnapshot.Item] { snapshot?.due(on: day) ?? [] }
    var overdue: [WidgetSnapshot.Item] { snapshot?.overdue(on: day) ?? [] }
    var events: [WidgetSnapshot.Event] { snapshot?.events(on: date) ?? [] }
}

struct TodayProvider: TimelineProvider {

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: .sample, state: .ready)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(entry(at: .now, showingSampleIfEmpty: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // An entry every 15 minutes for six hours, and one just after midnight, keep "today" and
        // the next event right between the app's updates.
        let now = Date()
        var dates = (0..<24).map { now.addingTimeInterval(Double($0) * 900) }
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
        if let last = dates.last, tomorrow < last {
            dates.append(tomorrow)
            dates.sort()
        }
        let first = entry(at: now, showingSampleIfEmpty: false)
        let entries = dates.map { TodayEntry(date: $0, snapshot: first.snapshot, state: first.state) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date, showingSampleIfEmpty: Bool) -> TodayEntry {
        if let snapshot = WidgetStore.load() { return TodayEntry(date: date, snapshot: snapshot, state: .ready) }
        // The widget gallery shows what the widget looks like with a day in it.
        if showingSampleIfEmpty { return TodayEntry(date: date, snapshot: .sample, state: .ready) }
        return TodayEntry(date: date, snapshot: nil, state: WidgetStore.isAvailable ? .waitingForApp : .needsSetup)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LPToday", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("What is due, what is overdue and what is still on your calendar today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct TodayWidgetView: View {
    let entry: TodayEntry
    /// Set when drawn outside a widget (snapshots); a widget reads its size from the environment.
    var size: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily

    var body: some View {
        if entry.state != .ready {
            WidgetMessage(state: entry.state, symbol: "checklist")
        } else {
            switch size ?? environmentFamily {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    // A date and the day's counts.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            DateHeader(date: entry.date)
            Spacer(minLength: 6)
            Counts(due: entry.due.count, overdue: entry.overdue.count)
            if let next = entry.events.first(where: { !$0.isAllDay }) ?? entry.events.first {
                EventLine(event: next, date: entry.date)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(LPLink.home)
    }

    // The date and counts beside the first few things to do and to go to.
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                DateHeader(date: entry.date)
                Spacer(minLength: 6)
                Counts(due: entry.due.count, overdue: entry.overdue.count)
            }
            .frame(width: 96, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            AgendaList(entry: entry, limit: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(LPLink.home)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                DateHeader(date: entry.date)
                Spacer()
                Counts(due: entry.due.count, overdue: entry.overdue.count, isCompact: true)
            }
            AgendaList(entry: entry, limit: 14, showsSections: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(LPLink.home)
    }
}

private struct DateHeader: View {
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Counts: View {
    let due: Int
    let overdue: Int
    var isCompact = false

    var body: some View {
        let layout = isCompact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            Text(due == 0 ? "Nothing due" : "\(due) due today")
                .foregroundStyle(due == 0 ? .secondary : .primary)
            if overdue > 0 {
                Label("\(overdue) overdue", systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.lpCritical)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }
}

/// Due items first, then what is left on the calendar, then what is overdue; tomorrow fills
/// any room that is left.
private struct AgendaList: View {
    let entry: TodayEntry
    /// Rows that fit, counting section titles.
    let limit: Int
    var showsSections = false

    private enum Row {
        case item(WidgetSnapshot.Item, isOverdue: Bool)
        case event(WidgetSnapshot.Event, day: Date)
    }

    private struct Group {
        var title: String?
        var rows: [Row]
    }

    var body: some View {
        let groups = plan()
        if groups.isEmpty {
            Text("Nothing due and nothing left on your calendar today.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: showsSections ? 10 : 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 5) {
                        if let title = group.title {
                            Text(title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            switch row {
                            case .item(let item, let isOverdue): ItemLine(item: item, date: entry.date, isOverdue: isOverdue)
                            case .event(let event, let day): EventLine(event: event, date: day)
                            }
                        }
                    }
                }
            }
        }
    }

    private func plan() -> [Group] {
        var room = limit
        var groups: [Group] = []
        func add(_ title: String?, _ rows: [Row]) {
            guard !rows.isEmpty else { return }
            groups.append(Group(title: title, rows: rows))
            room -= rows.count + (title == nil ? 0 : 1)
        }

        let due = entry.due.map { Row.item($0, isOverdue: false) }
        let events = entry.events.map { Row.event($0, day: entry.date) }
        if showsSections {
            add("Due today", Array(due.prefix(5)))
            add("Calendar", Array(events.prefix(min(4, max(0, room - 1)))))
            add("Overdue", Array(entry.overdue.prefix(max(0, min(3, room - 1))).map { Row.item($0, isOverdue: true) }))
        } else {
            add(nil, Array((due + events).prefix(room)))
        }

        // Tomorrow, when there is room for a title and at least one row.
        if room >= 2, let snapshot = entry.snapshot,
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date)) {
            let rows = snapshot.due(on: WidgetSnapshot.dayKey(tomorrow)).map { Row.item($0, isOverdue: false) }
                + snapshot.events(on: tomorrow).map { Row.event($0, day: tomorrow) }
            add("Tomorrow", Array(rows.prefix(room - 1)))
        }
        return groups
    }
}

private struct ItemLine: View {
    let item: WidgetSnapshot.Item
    let date: Date
    var isOverdue = false

    var body: some View {
        WidgetLink(destination: LPLink.open(item.path)) {
            HStack(spacing: 6) {
                Image(systemName: item.isCard ? "square" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isOverdue ? Color.lpCritical : .secondary)
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let minutes = item.time, !isOverdue {
                    Text(timeText(minutes: minutes, on: date))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption)
        }
    }
}

private struct EventLine: View {
    let event: WidgetSnapshot.Event
    let date: Date

    var body: some View {
        // In a small widget the whole widget is one link; elsewhere this opens the day.
        WidgetLink(destination: LPLink.calendar(day: WidgetSnapshot.dayKey(date))) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: event.color))
                    .frame(width: 3, height: 12)
                Text(event.isAllDay || event.start < Calendar.current.startOfDay(for: date) ? "All day" : timeText(event.start))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(event.title.isEmpty ? "Untitled event" : event.title)
                    .lineLimit(1)
            }
            .font(.caption)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    TodayWidget()
} timeline: {
    TodayEntry(date: .now, snapshot: .sample, state: .ready)
    TodayEntry(date: .now, snapshot: nil, state: .needsSetup)
}

#Preview("Medium", as: .systemMedium) {
    TodayWidget()
} timeline: {
    TodayEntry(date: .now, snapshot: .sample, state: .ready)
}

#Preview("Large", as: .systemLarge) {
    TodayWidget()
} timeline: {
    TodayEntry(date: .now, snapshot: .sample, state: .ready)
}
