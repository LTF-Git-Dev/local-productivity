//
//  BoardsView.swift
//  LP
//
//  Every board in the workspace, one card each, showing how far along it is. A board per
//  project is made here, from a template. The grid reflows with the window.
//

import SwiftUI

struct BoardsView: View {
    let workspace: Workspace

    @Environment(AppModel.self) private var app
    @State private var order = Order.recent
    @State private var renaming: PageMeta?
    @State private var newName = ""

    enum Order: String, CaseIterable, Identifiable {
        case recent, name, progress

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recent: return "Recently Edited"
            case .name: return "Name"
            case .progress: return "Progress"
            }
        }
    }

    private struct Entry: Identifiable {
        let meta: PageMeta
        let summary: BoardSummary
        var id: String { meta.path }
    }

    private var boards: [Entry] {
        let entries = workspace.meta.values.compactMap { meta in meta.board.map { Entry(meta: meta, summary: $0) } }
        switch order {
        case .recent:
            return entries.sorted { ($0.meta.modified, $0.meta.path) > ($1.meta.modified, $1.meta.path) }
        case .name:
            return entries.sorted { $0.meta.title.localizedStandardCompare($1.meta.title) == .orderedAscending }
        case .progress:
            return entries.sorted { ($0.summary.fraction, $0.meta.title) < ($1.summary.fraction, $1.meta.title) }
        }
    }

    var body: some View {
        let boards = boards
        GeometryReader { proxy in
            // Tighter margins when the window is narrow.
            let margin: CGFloat = proxy.size.width < 700 ? 24 : 48
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(boards)
                    if boards.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 268, maximum: 440), spacing: 16)], spacing: 16) {
                            ForEach(boards) { entry in
                                BoardOverviewCard(meta: entry.meta, summary: entry.summary) { app.openPage(entry.meta.path) }
                                    .contextMenu { menu(for: entry.meta) }
                            }
                        }
                    }
                }
                .padding(.horizontal, margin)
                .padding(.top, 40)
                .padding(.bottom, 48)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.lpCanvas)
        .alert("Rename Board", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { _ = app.rename(renaming.path, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func header(_ boards: [Entry]) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Boards")
                    .font(.lp(size: 28, weight: .bold))
                    .foregroundStyle(Color.lpInk)
                Text(summaryLine(boards))
                    .font(.lp(size: 14))
                    .foregroundStyle(Color.lpInkSecondary)
            }
            Spacer(minLength: 12)
            if boards.count > 1 {
                Picker("Sort by", selection: $order) {
                    ForEach(Order.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Sort boards")
            }
            Button {
                app.newBoard(in: "")
            } label: {
                Label("New Board", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Make a board for a project")
        }
    }

    private func summaryLine(_ boards: [Entry]) -> String {
        guard !boards.isEmpty else { return "One board for each project, from to-do to done." }
        let open = boards.reduce(0) { $0 + $1.summary.total - $1.summary.done }
        let overdue = boards.reduce(0) { $0 + $1.summary.overdue() }
        var parts = [boards.count == 1 ? "1 board" : "\(boards.count) boards", open == 1 ? "1 open card" : "\(open) open cards"]
        if overdue > 0 { parts.append("\(overdue) overdue") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.lp(size: 28))
                .foregroundStyle(Color.lpInkTertiary)
            Text("No boards yet")
                .font(.lp(size: 16, weight: .semibold))
                .foregroundStyle(Color.lpInk)
            Text("Make a board for each project and follow its cards from to-do to done.")
                .font(.lp(size: 13))
                .foregroundStyle(Color.lpInkSecondary)
                .multilineTextAlignment(.center)
            Button("New Board") { app.newBoard(in: "") }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func menu(for meta: PageMeta) -> some View {
        Button("Open") { app.openPage(meta.path) }
        Button("Rename…") {
            newName = meta.title
            renaming = meta
        }
        Button("Reveal in Finder") { workspace.revealInFinder(meta.path) }
        Divider()
        Button("Move to Trash", role: .destructive) { app.trash(meta.path) }
    }
}

// MARK: - Card

/// A board at a glance: its progress, how its cards sit across its lists, and what is late.
struct BoardOverviewCard: View {
    let meta: PageMeta
    let summary: BoardSummary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let overdue = summary.overdue()
        let dueSoon = summary.dueSoon()
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    PageIcon(emoji: meta.icon, size: 30, isBoard: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.title)
                            .font(.lp(size: 14, weight: .semibold))
                            .foregroundStyle(Color.lpInk)
                            .lineLimit(1)
                        Text(FileNode.parent(of: meta.path).isEmpty ? "Workspace" : FileNode.parent(of: meta.path))
                            .font(.lp(size: 11.5))
                            .foregroundStyle(Color.lpInkTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    if overdue > 0 {
                        Label("\(overdue) overdue", systemImage: "exclamationmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.lp(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.lpCritical)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(summary.percent)%")
                        .font(.lp(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.lpInk)
                    Text(summary.total == 0 ? "No cards yet" : "\(summary.done) of \(summary.total) done")
                        .font(.lp(size: 12))
                        .foregroundStyle(Color.lpInkSecondary)
                    Spacer(minLength: 0)
                }
                ListsBar(summary: summary)
                    .frame(height: 6)
                    .padding(.top, 8)
                Text(listsLine)
                    .font(.lp(size: 11.5))
                    .foregroundStyle(Color.lpInkTertiary)
                    .lineLimit(1)
                    .padding(.top, 8)
                HStack(spacing: 5) {
                    if dueSoon > 0 {
                        Text("\(dueSoon) due soon")
                            .foregroundStyle(Color.lpWarning)
                        Text("·")
                    }
                    Text("Edited \(meta.modified.inlineRelative)")
                }
                .font(.lp(size: 11.5))
                .foregroundStyle(Color.lpInkTertiary)
                .lineLimit(1)
                .padding(.top, 10)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
            .cardSurface(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(overdue: overdue))
        .accessibilityAddTraits(.isButton)
    }

    /// "Backlog 3 · In progress 2 · Done 4".
    private var listsLine: String {
        summary.lists.isEmpty ? "No lists" : summary.lists.map { "\($0.title) \($0.count)" }.joined(separator: " · ")
    }

    private func accessibilityText(overdue: Int) -> String {
        var text = "\(meta.title), \(summary.percent) percent done, \(summary.done) of \(summary.total) cards"
        if overdue > 0 { text += ", \(overdue) overdue" }
        return text
    }
}

/// How a board's cards are spread across its lists, coloured by stage as on the board itself.
private struct ListsBar: View {
    let summary: BoardSummary
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let filled = summary.lists.enumerated().filter { $0.element.count > 0 }
            let available = proxy.size.width - gap * CGFloat(max(filled.count - 1, 0))
            HStack(spacing: gap) {
                if summary.total == 0 {
                    Capsule().fill(Color.lpFillSelected)
                } else {
                    ForEach(filled, id: \.offset) { index, list in
                        Rectangle()
                            .fill(BoardPalette.lane(index, of: summary.lists.count))
                            .frame(width: max(2, available * CGFloat(list.count) / CGFloat(summary.total)))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

// MARK: - New board

/// Names a new board, picks its template and where it lives.
struct NewBoardSheet: View {
    let workspace: Workspace

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var template: BoardTemplate
    @State private var folder: String
    @FocusState private var isNameFocused: Bool

    init(request: NewBoardRequest, workspace: Workspace) {
        self.workspace = workspace
        _name = State(initialValue: "")
        _template = State(initialValue: .simple)
        // A folder that has gone away falls back to the top of the workspace.
        _folder = State(initialValue: workspace.folderPaths.contains(request.folder) ? request.folder : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Board")
                .font(.lp(size: 17, weight: .semibold))

            TextField("Name", text: $name, prompt: Text("For example, Website launch"))
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)

            VStack(alignment: .leading, spacing: 8) {
                Text("Template")
                    .font(.lp(size: 12, weight: .semibold))
                    .foregroundStyle(Color.lpInkSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(BoardTemplate.allCases) { item in
                        TemplateTile(template: item, isSelected: item == template) { template = item }
                    }
                }
            }

            Picker("Folder", selection: $folder) {
                ForEach(workspace.folderPaths, id: \.self) { path in
                    Text(path.isEmpty ? "\(workspace.name) (top level)" : path).tag(path)
                }
            }

            HStack {
                Text("Lists can be renamed, added and reordered later.")
                    .font(.lp(size: 11.5))
                    .foregroundStyle(Color.lpInkTertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Board", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear { isNameFocused = true }
    }

    private func create() {
        app.createBoard(named: name, template: template, in: folder)
        dismiss()
    }
}

private struct TemplateTile: View {
    let template: BoardTemplate
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Label(template.title, systemImage: template.symbol)
                    .font(.lp(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
                Text(template.summary)
                    .font(.lp(size: 11.5))
                    .foregroundStyle(Color.lpInkSecondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : (isHovering ? Color.lpFillHover : Color.lpFillSubtle), in: shape)
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(template.summary)
    }
}
