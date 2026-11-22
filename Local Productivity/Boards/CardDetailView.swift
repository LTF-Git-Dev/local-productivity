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

    // What the sheet was opened on. These are State, not plain properties: the board view builds
    // the sheet again whenever the board changes, and a plain property would take the card (and
    // board) as they are then — so "only what you changed" would compare against the wrong card.
    @State private var original: BoardCard?
    @State private var originalLaneID: String
    /// Whether the card was done when the sheet opened — itself, or by being in a list whose cards
    /// count as done (which another app can change meanwhile).
    @State private var originalIsDone: Bool
    /// The board the sheet was opened on: its file can be replaced by another board meanwhile.
    @State private var identity: String

    init(store: BoardStore, cardID: String, undoManager: UndoManager?) {
        self.store = store
        self.cardID = cardID
        self.undoManager = undoManager
        let card = store.board.allCards.first { $0.id == cardID }
        let lane = store.board.lane(containing: cardID)
        _original = State(initialValue: card)
        _originalLaneID = State(initialValue: lane?.id ?? "")
        _identity = State(initialValue: store.log.boardID)
        _title = State(initialValue: card?.title ?? "")
        _laneID = State(initialValue: lane?.id ?? "")
        let wasDone = card.map { $0.isDone || lane?.marksComplete == true } ?? false
        _isDone = State(initialValue: wasDone)
        _originalIsDone = State(initialValue: wasDone)
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
            // Why Done didn't close the sheet; what was typed is still here.
            if let problem = store.saveError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            footer
        }
        .frame(width: 520)
        #if DEBUG
        // The harness's `card-sheet:` step: type into the notes and press Done, press Done, or pick Delete.
        .onReceive(NotificationCenter.default.publisher(for: .lpHarnessCardSheet)) { note in
            guard let request = note.object as? [String: String] else { return }
            switch request["action"] {
            case "delete":
                guard store.isStill(identity), store.delete(cardID, undoManager: undoManager) else { return }
                dismiss()
            case "done":
                save()
            case "notes":
                notes = request["text"] ?? ""
                save()
            default:
                break
            }
        }
        #endif
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
                // If it can't be done the sheet stays open with what was typed, and says why.
                Button("Archive", systemImage: "archivebox") {
                    guard store.isStill(identity), store.archive(cardID, undoManager: undoManager) else { return }
                    dismiss()
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    guard store.isStill(identity), store.delete(cardID, undoManager: undoManager) else { return }
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
            Button("Cancel", role: .cancel) {
                store.saveError = nil
                dismiss()
            }
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
        // Only what was changed here is sent, and the store applies it to the card as it is when
        // the change is made, so changes made elsewhere while the sheet was open survive.
        var edit = CardEdit()
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if newTitle != original.title, !newTitle.isEmpty { edit.title = newTitle }
        if parsedTags != original.tags { edit.tags = parsedTags }
        let newDue = hasDue ? Day(due) : nil
        if newDue != original.due {
            edit.changesDue = true
            edit.due = newDue
        }
        let newTime = hasDue && hasTime ? TimeOfDay(time) : nil
        if newTime != CardText.dueTime(in: original.text) {
            edit.changesTime = true
            edit.time = newTime
        }
        let editedNotes = notes.trimmingCharacters(in: .newlines)
        if editedNotes != original.body.trimmingCharacters(in: .newlines) { edit.body = editedNotes }
        if isDone != originalIsDone { edit.isDone = isDone }
        if laneID != originalLaneID { edit.laneID = laneID }
        // If it couldn't be saved the sheet stays open, keeping what was typed; the reason shows.
        if edit.isEmpty || (store.isStill(identity) && store.editCard(cardID, edit, undoManager: undoManager)) {
            dismiss()
        }
    }
}
