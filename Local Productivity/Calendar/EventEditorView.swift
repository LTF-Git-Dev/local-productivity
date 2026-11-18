//
//  EventEditorView.swift
//  LP
//
//  Creating and changing calendar events. Saving writes to the event's own calendar —
//  Apple, Google or Microsoft — so the change appears there too.
//

import SwiftUI

struct EventEditorView: View {

    let request: EventEditorRequest
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    // Filled in by `init`, before the date pickers first draw. If they appeared with placeholder
    // values, the end picker would clamp the real end time to the placeholder start.
    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var notes: String
    @State private var calendarID: String
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingSpanAction: SpanAction?
    @FocusState private var isTitleFocused: Bool

    private enum SpanAction: Identifiable {
        case save, delete
        var id: Int { self == .save ? 0 : 1 }
    }

    private var sync: CalendarSyncStore { app.calendarSync }

    init(request: EventEditorRequest) {
        self.request = request
        switch request.mode {
        case .new(let day):
            let calendar = Calendar.current
            var hour = 9
            if day == Day.today {
                hour = min(22, calendar.component(.hour, from: Date()) + 1)
            }
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day.date()) ?? day.date()
            _title = State(initialValue: "")
            _isAllDay = State(initialValue: false)
            _start = State(initialValue: start)
            _end = State(initialValue: start.addingTimeInterval(3600))
            _location = State(initialValue: "")
            _notes = State(initialValue: "")
            _calendarID = State(initialValue: "")
        case .edit(let event):
            _title = State(initialValue: event.title == "(No title)" ? "" : event.title)
            _isAllDay = State(initialValue: event.isAllDay)
            _start = State(initialValue: event.start)
            _end = State(initialValue: event.end)
            _location = State(initialValue: event.location)
            _notes = State(initialValue: event.notes)
            _calendarID = State(initialValue: event.calendarID)
        }
    }

    private var existing: SyncEvent? {
        if case .edit(let event) = request.mode { return event }
        return nil
    }

    private var calendar: SyncCalendar? {
        sync.calendar(withID: calendarID)
    }

    private var isReadOnly: Bool {
        existing != nil && calendar?.isWritable == false
    }

    // These bindings apply rules only to the person's own edits, not to filling in the form.

    /// Moving the start keeps the event's length, as in Calendar.
    private var startBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { newStart in
                if isAllDay {
                    start = CalendarDates.startOfDay(newStart)
                    if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start }
                } else {
                    end = end.addingTimeInterval(newStart.timeIntervalSince(start))
                    start = newStart
                }
            }
        )
    }

    private var allDayBinding: Binding<Bool> {
        Binding(
            get: { isAllDay },
            set: { allDay in
                isAllDay = allDay
                convertTimes(toAllDay: allDay)
            }
        )
    }

    /// For all-day events the editor shows the last day; LP stores the midnight after it.
    private var lastDay: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end },
            set: { end = Calendar.current.date(byAdding: .day, value: 1, to: CalendarDates.startOfDay($0)) ?? $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear(perform: load)
        .confirmationDialog("This is a repeating event.", isPresented: Binding(
            get: { pendingSpanAction != nil },
            set: { if !$0 { pendingSpanAction = nil } }
        ), presenting: pendingSpanAction) { action in
            Button(action == .save ? "Save for This Event Only" : "Delete This Event Only") {
                perform(action, span: .thisEvent)
            }
            Button(action == .save ? "Save for All Events" : "Delete All Events", role: action == .delete ? .destructive : nil) {
                perform(action, span: .allEvents)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .save ? "Change only this occurrence, or every event in the series?"
                                 : "Delete only this occurrence, or every event in the series?")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: calendar?.colorHex ?? "#8E8E93"))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            TextField(existing == nil ? "New Event" : "Title", text: $title)
                .textFieldStyle(.plain)
                .font(.lp(size: 18, weight: .semibold))
                .focused($isTitleFocused)
                .disabled(isReadOnly)
                .onSubmit(save)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var form: some View {
        Form {
            Toggle("All-day", isOn: allDayBinding)

            if isAllDay {
                DatePicker("Starts", selection: startBinding, displayedComponents: .date)
                DatePicker("Ends", selection: lastDay, in: start..., displayedComponents: .date)
            } else {
                DatePicker("Starts", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
            }

            if existing == nil {
                Picker("Calendar", selection: $calendarID) {
                    ForEach(sync.writableCalendars) { calendar in
                        Label {
                            Text("\(calendar.title)  \(Text(calendar.sourceTitle).foregroundStyle(.secondary))")
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: calendar.colorHex))
                        }
                        .tag(calendar.id)
                    }
                }
            } else if let calendar {
                LabeledContent("Calendar") {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: calendar.colorHex)).frame(width: 8, height: 8)
                        Text(calendar.title)
                        if !calendar.isWritable {
                            Text("Read-only").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            TextField("Location", text: $location, prompt: Text("Add location"))
            TextField("Notes", text: $notes, prompt: Text("Add notes"), axis: .vertical)
                .lineLimit(3...8)

            if let url = existing?.url {
                LabeledContent("Link") {
                    Link("Open in \(sourceName)", destination: url)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isReadOnly || isWorking)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.lp(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if existing != nil, !isReadOnly {
                    Button("Delete", role: .destructive, action: delete)
                        .disabled(isWorking)
                }
                if isWorking {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
                Button(isReadOnly ? "Close" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !isReadOnly {
                    Button(existing == nil ? "Add Event" : "Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || calendar == nil)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sourceName: String {
        switch sync.accounts.first(where: { $0.id == calendar?.accountID })?.kind {
        case .google: return "Google Calendar"
        case .microsoft: return "Outlook"
        default: return "Calendar"
        }
    }

    // MARK: Behaviour

    /// The default calendar comes from the sync store, which is only reachable once the view is live.
    private func load() {
        guard existing == nil else { return }
        calendarID = sync.defaultCalendar?.id ?? ""
        isTitleFocused = true
    }

    private func convertTimes(toAllDay allDay: Bool) {
        let calendar = Calendar.current
        if allDay {
            start = CalendarDates.startOfDay(start)
            end = max(calendar.date(byAdding: .day, value: 1, to: start) ?? start, CalendarDates.startOfDay(end))
        } else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
            end = start.addingTimeInterval(3600)
        }
    }

    private var draft: EventDraft {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventDraft(title: trimmed.isEmpty ? "New Event" : trimmed, start: start, end: max(end, start),
                          isAllDay: isAllDay, location: location, notes: notes)
    }

    private func save() {
        guard !isReadOnly else { return }
        if existing?.isRecurring == true {
            pendingSpanAction = .save
        } else {
            perform(.save, span: .thisEvent)
        }
    }

    private func delete() {
        if existing?.isRecurring == true {
            pendingSpanAction = .delete
        } else {
            perform(.delete, span: .thisEvent)
        }
    }

    private func perform(_ action: SpanAction, span: EditSpan) {
        let draft = draft
        isWorking = true
        errorMessage = nil
        Task {
            do {
                switch (action, existing) {
                case (.save, nil):
                    guard let calendar else { throw CalendarSyncError.notConnected }
                    try await sync.create(draft, in: calendar)
                case (.save, let event?):
                    try await sync.update(event, with: draft, span: span)
                case (.delete, let event?):
                    try await sync.delete(event, span: span)
                case (.delete, nil):
                    break
                }
                isWorking = false
                dismiss()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
