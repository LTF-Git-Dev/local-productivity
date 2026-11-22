//
//  CalendarView.swift
//  Local Productivity
//
//  A month at a glance. Days show what belongs to them — events from connected
//  calendars, the daily note, pages dated that day, tasks due — and the panel on the
//  right goes into detail for the selected day. Double-clicking a day opens its daily
//  note, creating it if needed.
//

import SwiftUI

struct CalendarView: View {

    let workspace: Workspace
    @Environment(AppModel.self) private var app

    struct DayContent {
        var dailyNote: String?
        var pages: [PageMeta] = []
        var tasks: [TaskItem] = []
        var events: [SyncEvent] = []

        var isEmpty: Bool { dailyNote == nil && pages.isEmpty && tasks.isEmpty && events.isEmpty }
    }

    /// Everything that has a date — calendar events, and pages and tasks in the workspace —
    /// grouped by day.
    private var contentByDay: [Day: DayContent] {
        var result: [Day: DayContent] = [:]
        for (day, events) in app.calendarSync.eventsByDay {
            result[day, default: DayContent()].events = events
        }
        for meta in workspace.meta.values {
            if let day = meta.day {
                if meta.isDailyNote {
                    result[day, default: DayContent()].dailyNote = meta.path
                } else {
                    result[day, default: DayContent()].pages.append(meta)
                }
            }
            for task in meta.tasks {
                if let due = task.due { result[due, default: DayContent()].tasks.append(task) }
            }
        }
        return result
    }

    private var calendar: Calendar { .current }

    /// The weeks to draw: whole weeks covering the month, starting on the locale's first weekday.
    private var weeks: [[Day]] {
        let first = app.calendarMonth.startOfMonth
        let lead = (first.weekday(in: calendar) - calendar.firstWeekday + 7) % 7
        let start = first.adding(days: -lead, calendar: calendar)
        var weeks = (0..<6).map { week in
            (0..<7).map { start.adding(days: week * 7 + $0, calendar: calendar) }
        }
        if let last = weeks.last, last.allSatisfy({ $0.month != first.month }) { weeks.removeLast() }
        return weeks
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    var body: some View {
        @Bindable var app = app
        let content = contentByDay
        GeometryReader { proxy in
            // The day panel needs room of its own; in a narrow window the month gets all of it.
            let showsPanel = proxy.size.width >= 800
            let cellWidth = (proxy.size.width - (showsPanel ? 297 : 0)) / 7
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    monthHeader
                    weekdayHeader
                    grid(content, isCompact: cellWidth < 92)
                }
                if showsPanel {
                    Rectangle()
                        .fill(Color.lpHairline)
                        .frame(width: 1)
                    DayPanel(day: app.calendarSelection, content: content[app.calendarSelection] ?? DayContent(), workspace: workspace)
                        .frame(width: 296)
                }
            }
        }
        .background(Color.lpCanvas)
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ToolbarTitle(title: "Calendar", symbol: "calendar")
            }
            .lpWithoutSharedBackground()
        }
        .sheet(item: $app.eventEditor) { request in
            EventEditorView(request: request)
        }
        .onChange(of: app.calendarMonth, initial: true) { _, month in
            app.calendarSync.ensureLoaded(around: month)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -7) }
        .onKeyPress(.downArrow) { move(by: 7) }
        .onKeyPress(.return) {
            app.openDailyNote(for: app.calendarSelection)
            return .handled
        }
    }

    private func move(by days: Int) -> KeyPress.Result {
        select(app.calendarSelection.adding(days: days, calendar: calendar))
        return .handled
    }

    private func select(_ day: Day) {
        app.calendarSelection = day
        if day.month != app.calendarMonth.month || day.year != app.calendarMonth.year {
            app.calendarMonth = day.startOfMonth
        }
    }

    // MARK: Header

    private var monthHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The month never breaks mid-word in a narrow window: the title keeps its line, ahead of
            // the space beside it, and only a long month name shrinks a little.
            Text(app.calendarMonth.date().formatted(.dateTime.month(.wide)))
                .font(.lp(size: 24, weight: .bold))
                .foregroundStyle(Color.lpInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            Text(app.calendarMonth.date().formatted(.dateTime.year()))
                .font(.lp(size: 24, weight: .regular))
                .foregroundStyle(Color.lpInkTertiary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            HStack(spacing: 6) {
                syncStatus
                CalendarsMenu()
                    .padding(.trailing, 2)
                Button {
                    app.eventEditor = EventEditorRequest(mode: .new(app.calendarSelection))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(CalendarControlStyle(isIcon: true))
                .disabled(app.calendarSync.writableCalendars.isEmpty)
                .help(app.calendarSync.writableCalendars.isEmpty ? "Connect a calendar in Settings to add events" : "New event")
                .accessibilityLabel("New event")
                .padding(.trailing, 8)

                Button {
                    app.calendarMonth = Day.today.startOfMonth
                    app.calendarSelection = .today
                } label: {
                    Text("Today")
                }
                .buttonStyle(CalendarControlStyle())
                .fixedSize()
                .padding(.trailing, 2)

                Button {
                    app.calendarMonth = app.calendarMonth.adding(months: -1, calendar: calendar).startOfMonth
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(CalendarControlStyle(isIcon: true))
                .help("Previous month")
                .accessibilityLabel("Previous month")

                Button {
                    app.calendarMonth = app.calendarMonth.adding(months: 1, calendar: calendar).startOfMonth
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(CalendarControlStyle(isIcon: true))
                .help("Next month")
                .accessibilityLabel("Next month")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    /// A spinner while syncing; otherwise a button to sync now. Hidden with no accounts.
    @ViewBuilder
    private var syncStatus: some View {
        if !app.calendarSync.isEmpty {
            if app.calendarSync.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help("Syncing calendars…")
                    .accessibilityLabel("Syncing calendars…")
            } else {
                Button {
                    app.calendarSync.syncNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(CalendarControlStyle(isIcon: true, isQuiet: true))
                .help("Sync calendars now")
                .accessibilityLabel("Sync calendars now")
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.lp(size: 10.5, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(Color.lpInkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.lpHairline).frame(height: 1)
        }
    }

    private func grid(_ content: [Day: DayContent], isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        DayCell(day: day,
                                content: content[day] ?? DayContent(),
                                isInMonth: day.month == app.calendarMonth.month,
                                isSelected: day == app.calendarSelection,
                                isCompact: isCompact,
                                workspace: workspace)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .trailing) {
                                if day != week.last { Rectangle().fill(Color.lpHairline).frame(width: 1) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { app.openDailyNote(for: day) }
                            .simultaneousGesture(TapGesture().onEnded { select(day) })
                            .contextMenu {
                                Button("New Event", systemImage: "plus") {
                                    select(day)
                                    app.eventEditor = EventEditorRequest(mode: .new(day))
                                }
                                .disabled(app.calendarSync.writableCalendars.isEmpty)
                                Button("Open Daily Note", systemImage: "doc.text") { app.openDailyNote(for: day) }
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if week != weeks.last { Rectangle().fill(Color.lpHairline).frame(height: 1) }
                }
            }
        }
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let day: Day
    let content: CalendarView.DayContent
    let isInMonth: Bool
    let isSelected: Bool
    /// Narrow cells show what a day holds as small marks instead of labelled chips.
    let isCompact: Bool
    let workspace: Workspace
    @State private var isHovering = false

    private var isToday: Bool { day == Day.today }

    private var numberColor: Color {
        if isToday { return .white }
        if isSelected { return .accentColor }
        return isInMonth ? .lpInk : .lpInkFaint
    }

    private var numberFill: Color {
        if isToday { return .accentColor }
        return isSelected ? Color.accentColor.opacity(0.12) : .clear
    }

    /// The chips to show, most important first.
    private var chips: [Chip] {
        var chips: [Chip] = []
        if content.dailyNote != nil {
            chips.append(Chip(id: "note", symbol: "doc.text.fill", emoji: nil, title: "Daily note", style: .accent))
        }
        for event in content.events {
            let color = Color(hex: calendarColor(event))
            if event.isAllDay {
                chips.append(Chip(id: "event:" + event.id, symbol: "circle.fill", emoji: nil, title: event.title,
                                  style: .allDayEvent, color: color))
            } else {
                chips.append(Chip(id: "event:" + event.id, symbol: "circle.fill", emoji: nil, title: event.title,
                                  style: .event, color: color,
                                  detail: event.start.formatted(.dateTime.hour().minute())))
            }
        }
        for page in content.pages.sorted(by: { $0.title < $1.title }) {
            chips.append(Chip(id: "page:" + page.path, symbol: "doc.text", emoji: page.icon, title: page.title, style: .neutral))
        }
        for task in content.tasks {
            chips.append(Chip(id: "task:" + task.id, symbol: task.isDone ? "checkmark.circle.fill" : "circle", emoji: nil,
                              title: task.text, style: task.isDone ? .done : .neutral))
        }
        return chips
    }

    @Environment(AppModel.self) private var app

    private func calendarColor(_ event: SyncEvent) -> String {
        app.calendarSync.calendar(withID: event.calendarID)?.colorHex ?? "#8E8E93"
    }

    var body: some View {
        let chips = chips
        let visible = chips.count > 3 ? Array(chips.prefix(2)) : chips
        VStack(alignment: .leading, spacing: 3) {
            // Today's number sits in white on the accent, so it is large and bold enough to stay
            // readable on the lighter dark-mode accent.
            Text("\(day.day)")
                .font(.lp(size: isToday ? 14 : 12.5, weight: isToday || isSelected ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(numberColor)
                .frame(minWidth: 24, minHeight: 24)
                .background(numberFill, in: Circle())
                .padding(.bottom, 1)

            if isCompact {
                // Three marks fit a narrow cell; with more, two marks and a count.
                let marks = chips.count > 3 ? Array(chips.prefix(2)) : chips
                HStack(spacing: 3) {
                    ForEach(marks) { chip in
                        CompactMark(chip: chip)
                    }
                    if chips.count > marks.count {
                        Text("+\(chips.count - marks.count)")
                            .font(.lp(size: 10, weight: .semibold))
                            .foregroundStyle(Color.lpInkTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.leading, 2)
            } else {
                ForEach(visible) { chip in
                    ChipView(chip: chip)
                }
                if chips.count > visible.count {
                    Text("+\(chips.count - visible.count) more")
                        .font(.lp(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.lpInkTertiary)
                        .padding(.leading, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isInMonth ? 1 : 0.55)
        .background(isSelected ? Color.accentColor.opacity(0.05) : (isHovering ? Color.lpFillHover : .clear))
        .onHover { isHovering = $0 }
    }

    /// A day's item reduced to its icon, for narrow cells.
    private struct CompactMark: View {
        let chip: Chip

        var body: some View {
            Group {
                if let emoji = chip.emoji {
                    Text(emoji).font(.lp(size: 10))
                } else if let color = chip.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                } else {
                    Image(systemName: chip.symbol)
                        .font(.lp(size: 9, weight: .semibold))
                        .foregroundStyle(chip.style == .neutral ? Color.lpInkTertiary : Color.accentColor)
                }
            }
            .frame(width: 18, height: 18)
            .background(chip.style == .accent ? Color.accentColor.opacity(0.13) : Color.lpFillSubtle,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(chip.title)
        }
    }

    struct Chip: Identifiable {
        enum Style { case accent, neutral, done, event, allDayEvent }
        let id: String
        let symbol: String
        let emoji: String?
        let title: String
        let style: Style
        var color: Color? = nil
        /// Secondary text after the title, such as an event's start time.
        var detail: String? = nil
    }

    private struct ChipView: View {
        let chip: Chip

        var body: some View {
            switch chip.style {
            case .event: eventChip
            case .allDayEvent: allDayChip
            default: itemChip
            }
        }

        /// A timed event, drawn as Calendar does: a dot in the calendar's colour, the title,
        /// and the start time when there is room for both. The title always wins.
        private var eventChip: some View {
            ViewThatFits(in: .horizontal) {
                eventRow(showsTime: true)
                eventRow(showsTime: false)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
            .help(chip.detail.map { "\(chip.title), \($0)" } ?? chip.title)
        }

        private func eventRow(showsTime: Bool) -> some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(chip.color ?? .gray)
                    .frame(width: 6, height: 6)
                Text(chip.title)
                    .font(.lp(size: 11, weight: .medium))
                    .foregroundStyle(Color.lpInk.opacity(0.88))
                    .lineLimit(1)
                if showsTime, let detail = chip.detail {
                    Spacer(minLength: 4)
                    Text(detail)
                        .font(.lp(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Color.lpInkSecondary)
                        .lineLimit(1)
                }
            }
        }

        /// An all-day event: a bar filled with the calendar's colour.
        private var allDayChip: some View {
            Text(chip.title)
                .font(.lp(size: 11, weight: .semibold))
                .foregroundStyle(Color.lpInk)
                .lineLimit(1)
                .padding(.leading, 7)
                .padding(.trailing, 5)
                .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
                .background((chip.color ?? .gray).opacity(0.22), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(chip.color ?? .gray).frame(width: 3).padding(.vertical, 3).padding(.leading, 2)
                }
        }

        private var itemChip: some View {
            HStack(spacing: 4) {
                if let emoji = chip.emoji {
                    Text(emoji).font(.lp(size: 10))
                } else {
                    Image(systemName: chip.symbol)
                        .font(.lp(size: 9, weight: .medium))
                        .foregroundStyle(chip.style == .accent || chip.style == .done ? Color.accentColor : Color.lpInkTertiary)
                }
                Text(chip.title)
                    .font(.lp(size: 11, weight: .medium))
                    .foregroundStyle(chip.style == .accent ? Color.accentColor : (chip.style == .done ? Color.lpInkTertiary : Color.lpInk.opacity(0.85)))
                    .strikethrough(chip.style == .done, color: Color.lpInkFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
            .background(chip.style == .accent ? Color.accentColor.opacity(0.12) : Color.lpFillSubtle,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

// MARK: - Day panel

private struct DayPanel: View {
    let day: Day
    let content: CalendarView.DayContent
    let workspace: Workspace
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(day.relativeTitle == day.shortTitle ? day.date().formatted(.dateTime.weekday(.wide)) : day.relativeTitle)
                    .font(.lp(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(day.date().formatted(.dateTime.month(.wide).day()))
                    .font(.lp(size: 22, weight: .bold))
                    .foregroundStyle(Color.lpInk)
                    .padding(.top, 2)

                Button {
                    app.openDailyNote(for: day)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: content.dailyNote == nil ? "plus" : "doc.text")
                            .font(.lp(size: 12, weight: .semibold))
                        Text(content.dailyNote == nil ? "Start daily note" : "Open daily note")
                            .font(.lp(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.lp(size: 10.5, weight: .semibold))
                            .opacity(0.6)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 18)

                eventsSection

                if !content.pages.isEmpty {
                    PanelSection(title: "Pages") {
                        VStack(spacing: 1) {
                            ForEach(content.pages.sorted(by: { $0.title < $1.title }), id: \.path) { page in
                                PanelPageRow(page: page) { app.openPage(page.path) }
                            }
                        }
                    }
                }

                if !content.tasks.isEmpty {
                    PanelSection(title: "Due") {
                        VStack(spacing: 0) {
                            ForEach(content.tasks) { task in
                                PanelTaskRow(task: task, workspace: workspace)
                            }
                        }
                    }
                }

                if content.pages.isEmpty, content.tasks.isEmpty, !app.calendarSync.isEmpty {
                    Text("Nothing else is dated for this day.\n\nGive a page a `date:` in its front matter, or add “📅 \(day.iso)” to a task, and it will show up here.")
                        .font(.lp(size: 12.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineSpacing(3)
                        .padding(.top, 22)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lpSoftScrollEdge()
    }
}

private extension DayPanel {

    @ViewBuilder
    var eventsSection: some View {
        let sync = app.calendarSync
        if sync.isEmpty {
            ConnectCalendarsCard()
                .padding(.top, 24)
        } else {
            PanelSection(title: "Events") {
                Button {
                    app.eventEditor = EventEditorRequest(mode: .new(day))
                } label: {
                    Image(systemName: "plus")
                        .font(.lp(size: 11, weight: .semibold))
                        .foregroundStyle(Color.lpInkSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle())
                .disabled(sync.writableCalendars.isEmpty)
                .help("New event on this day")
                .accessibilityLabel("New event on this day")
            } content: {
                if content.events.isEmpty {
                    Text("No events")
                        .font(.lp(size: 12.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 2) {
                        ForEach(content.events) { event in
                            PanelEventRow(event: event, day: day,
                                          calendar: sync.calendar(withID: event.calendarID)) {
                                app.eventEditor = EventEditorRequest(mode: .edit(event))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Shown in the day panel until a calendar account is connected.
private struct ConnectCalendarsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bring in your calendars", systemImage: "calendar.badge.plus")
                .font(.lp(size: 13, weight: .semibold))
                .foregroundStyle(Color.lpInk)
            Text("Connect Apple, Google or Outlook calendars to see events here. Changes you make in LP are saved back to them.")
                .font(.lp(size: 12))
                .foregroundStyle(Color.lpInkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink {
                Text("Connect Calendars…")
                    .font(.lp(size: 12.5, weight: .medium))
            }
            .simultaneousGesture(TapGesture().onEnded { SettingsView.select(.calendars) })
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous))
    }
}

private struct PanelEventRow: View {
    let event: SyncEvent
    let day: Day
    let calendar: SyncCalendar?
    let action: () -> Void
    @State private var isHovering = false

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let startsToday = Day(event.start) == day
        let endsToday = Day(event.end.addingTimeInterval(-1)) == day
        let start = startsToday ? event.start.formatted(date: .omitted, time: .shortened) : "Until"
        let end = endsToday ? event.end.formatted(date: .omitted, time: .shortened) : "continues"
        return startsToday ? "\(start) – \(end)" : "\(start) \(end)"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: calendar?.colorHex ?? "#8E8E93"))
                    .frame(width: 3)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.lp(size: 13, weight: .medium))
                        .foregroundStyle(Color.lpInk)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(timeText)
                        if event.isRecurring {
                            Image(systemName: "repeat").font(.lp(size: 9.5, weight: .semibold))
                                .accessibilityLabel("Repeats")
                        }
                    }
                    .font(.lp(size: 11.5))
                    .foregroundStyle(Color.lpInkSecondary)
                    if !event.location.isEmpty {
                        Label(event.location, systemImage: "mappin.and.ellipse")
                            .font(.lp(size: 11.5))
                            .foregroundStyle(Color.lpInkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isHovering ? Color.lpFillHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { isHovering = $0 }
        .accessibilityHint("Opens the event to edit it")
    }
}

/// Shows or hides each connected calendar.
private struct CalendarsMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.calendarSync
        Menu {
            if sync.isEmpty {
                Text("No calendars connected")
            }
            ForEach(sync.accounts) { account in
                Section(account.name) {
                    ForEach(sync.calendars(for: account)) { calendar in
                        Toggle(isOn: Binding(
                            get: { !sync.hiddenCalendarIDs.contains(calendar.id) },
                            set: { visible in
                                if visible { sync.hiddenCalendarIDs.remove(calendar.id) } else { sync.hiddenCalendarIDs.insert(calendar.id) }
                            }
                        )) {
                            Text(calendar.title)
                        }
                    }
                }
            }
            Divider()
            SettingsLink {
                Text("Calendar Settings…")
            }
            .simultaneousGesture(TapGesture().onEnded { SettingsView.select(.calendars) })
        } label: {
            Text("Calendars")
        }
        .menuStyle(.button)
        .buttonStyle(CalendarControlStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.lp(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lpInkTertiary)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(.top, 24)
    }
}

private extension PanelSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

private struct PanelPageRow: View {
    let page: PageMeta
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PageIcon(emoji: page.icon, size: 26)
                Text(page.title)
                    .font(.lp(size: 13))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background(isHovering ? Color.lpFillHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { isHovering = $0 }
    }
}

private struct PanelTaskRow: View {
    let task: TaskItem
    let workspace: Workspace
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                app.toggleTask(task, in: workspace)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.lp(size: 15))
                    .foregroundStyle(task.isDone ? Color.accentColor : Color.lpInkTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.isDone ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(task.isDone ? "Mark as not done" : "Mark as done")

            Button {
                app.openPage(task.path)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.text)
                        .font(.lp(size: 13))
                        .foregroundStyle(task.isDone ? Color.lpInkTertiary : Color.lpInk)
                        .strikethrough(task.isDone, color: Color.lpInkFaint)
                        .multilineTextAlignment(.leading)
                    Text(FileNode.title(of: task.path))
                        .font(.lp(size: 11.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}

/// The small bordered controls in the calendar header.
private struct CalendarControlStyle: ButtonStyle {
    var isIcon = false
    /// Borderless, for secondary actions beside the main controls.
    var isQuiet = false

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, isIcon: isIcon, isQuiet: isQuiet)
    }

    private struct Appearance: View {
        let configuration: Configuration
        let isIcon: Bool
        let isQuiet: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.lp(size: isIcon ? 11 : 12.5, weight: isIcon ? .semibold : .medium))
                .foregroundStyle(isQuiet ? Color.lpInkSecondary : Color.lpInk.opacity(0.85))
                .padding(.horizontal, isIcon ? 0 : 12)
                .frame(width: isIcon ? 28 : nil, height: 28)
                .background(configuration.isPressed ? Color.lpFillSelected : (isHovering ? Color.lpFillHover : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    if !isQuiet {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.lpHairline, lineWidth: 1)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}
