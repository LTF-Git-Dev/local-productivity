//
//  CardDetailView.swift
//  LP
//
//  Everything about one card: its title, list, due date, tags and notes, and what has
//  happened to it. Saving applies the whole edit at once, so one ⌘Z undoes it.
//

import SwiftUI

struct CardDetailView: View {

    let store: BoardStore
    let cardID: String
    /// The board's undo manager. A sheet has its own, which would be gone once it closes.
    let undoManager: UndoManager?
    @Environment(\.dismiss) private var dismiss

    // Filled in by `init`, from the card as it was when the sheet opened.
    @State private var title: String
    @State private var laneID: String
    @State private var isDone: Bool
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var tags: String
    @State private var notes: String

    private let original: BoardCard?
    private let originalLaneID: String

    init(store: BoardStore, cardID: String, undoManager: UndoManager?) {
        self.store = store
        self.cardID = cardID
        self.undoManager = undoManager
        let card = store.board.allCards.first { $0.id == cardID }
        let lane = store.board.lane(containing: cardID)
        original = card
        originalLaneID = lane?.id ?? ""
        _title = State(initialValue: card?.title ?? "")
        _laneID = State(initialValue: lane?.id ?? "")
        _isDone = State(initialValue: card.map { $0.isDone || lane?.marksComplete == true } ?? false)
        _hasDue = State(initialValue: card?.due != nil)
        _due = State(initialValue: card?.due?.date() ?? Day.today.adding(days: 1).date())
        let dueTime = card.flatMap { CardText.dueTime(in: $0.text) }
        _hasTime = State(initialValue: dueTime != nil)
        _time = State(initialValue: (dueTime ?? TimeOfDay(hour: 9, minute: 0)).date(on: .today))
        _tags = State(initialValue: card?.tags.joined(separator: ", ") ?? "")
        _notes = State(initialValue: card?.body ?? "")
    }

    private var lane: BoardLane? { store.lane(withID: laneID) }

    /// In a list whose cards count as done, being done is the list's doing.
    private var isDoneLocked: Bool { lane?.marksComplete == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                isDone.toggle()
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.lp(size: 20))
                    .foregroundStyle(isDone ? BoardPalette.complete : Color.lpInkTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDoneLocked)
            .help(isDoneLocked ? "Cards in “\(lane?.title ?? "")” count as done" : (isDone ? "Mark as not done" : "Mark as done"))
            .accessibilityLabel(isDone ? "Done" : "Not done")
            .accessibilityAddTraits(.isToggle)

            TextField("Card title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.lp(size: 18, weight: .semibold))
                .lineLimit(1...4)
                .onSubmit(save)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var form: some View {
        Form {
            Picker("List", selection: $laneID) {
                ForEach(store.board.lanes) { lane in
                    Text(lane.title).tag(lane.id)
                }
            }
            .onChange(of: laneID) { _, _ in
                if isDoneLocked { isDone = true } else if store.lane(withID: originalLaneID)?.marksComplete == true { isDone = false }
            }

            Toggle("Due date", isOn: $hasDue)
            if hasDue {
                DatePicker("Due", selection: $due, displayedComponents: .date)
                Toggle("Remind at a time", isOn: $hasTime)
                if hasTime {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
            }

            TextField("Tags", text: $tags, prompt: Text("design, launch"))

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                TextEditor(text: $notes)
                    .font(.lp(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 88, maxHeight: 180)
                    .padding(6)
                    .background(Color.lpCanvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.lpHairline))
                Text("Markdown works here. A “- [ ]” line becomes a checklist item, counted on the card.")
                    .font(.lp(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !history.isEmpty {
                Section("Activity") {
                    ForEach(history) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: event.symbol)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(event.sentence)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(event.at.compactRelative)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.lp(size: 12))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 520)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Archive", systemImage: "archivebox") {
                    store.archive(cardID, undoManager: undoManager)
                    dismiss()
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    store.delete(cardID, undoManager: undoManager)
                    dismiss()
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")

            if let added = store.log.firstSeen[cardID] {
                Text("Added \(added.inlineRelative)")
                    .font(.lp(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Done", action: save)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Behaviour

    private var history: [BoardEvent] {
        Array(store.log.events(for: cardID).suffix(12).reversed())
    }

    private var parsedTags: [String] {
        tags.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "#" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        guard let original else {
            dismiss()
            return
        }
        // Only the parts that were changed are rewritten, so links and other syntax survive.
        var text = original.text
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if newTitle != original.title, !newTitle.isEmpty {
            text = CardText.settingTitle(newTitle, in: text)
        }
        if parsedTags != original.tags {
            text = CardText.settingTags(parsedTags, in: text)
        }
        let newDue = hasDue ? Day(due) : nil
        if newDue != original.due {
            text = CardText.settingDue(newDue, in: text)
        }
        let newTime = hasDue && hasTime ? TimeOfDay(time) : nil
        if newTime != CardText.dueTime(in: text) {
            text = CardText.settingDueTime(newTime, in: text)
        }
        let body = notes.trimmingCharacters(in: .newlines)
        let wasDone = original.isDone || store.lane(withID: originalLaneID)?.marksComplete == true
        if text != original.text || body != original.body || isDone != wasDone || laneID != originalLaneID {
            store.editCard(cardID, text: text, body: body, isDone: isDone, laneID: laneID, undoManager: undoManager)
        }
        dismiss()
    }
}
