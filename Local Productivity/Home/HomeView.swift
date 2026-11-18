//
//  HomeView.swift
//  Local Productivity
//
//  The landing page for a workspace: a greeting, the things you most often want to
//  do next, the pages you were last in, and any tasks still open.
//

import SwiftUI

struct HomeView: View {

    let workspace: Workspace
    @Environment(AppModel.self) private var app

    private var recentPages: [FileNode] {
        var seen = Set<String>()
        var result: [FileNode] = []
        for path in workspace.recents {
            guard let node = workspace.node(at: path), !node.isFolder, seen.insert(path).inserted else { continue }
            result.append(node)
        }
        // Top up with whatever was edited most recently, so a new workspace is not empty.
        for node in workspace.pages.sorted(by: { $0.modified > $1.modified }) where result.count < 8 {
            if seen.insert(node.path).inserted { result.append(node) }
        }
        return Array(result.prefix(8))
    }

    private var openTasks: [TaskItem] {
        workspace.meta.values
            .flatMap(\.tasks)
            .filter { !$0.isDone }
            .sorted { lhs, rhs in
                switch (lhs.due, rhs.due) {
                case let (left?, right?): return left != right ? left < right : lhs.id < rhs.id
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.id < rhs.id
                }
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header

                if workspace.hasLoaded, workspace.pages.isEmpty {
                    EmptyWorkspaceView(workspace: workspace)
                } else {
                    quickActions

                    if !recentPages.isEmpty {
                        HomeSection(title: "Jump back in") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 320), spacing: 14)], spacing: 14) {
                                ForEach(recentPages) { node in
                                    PageCard(node: node, meta: workspace.meta[node.path]) {
                                        app.openPage(node.path)
                                    }
                                }
                            }
                        }
                    }

                    if !openTasks.isEmpty {
                        HomeSection(title: "Open tasks", detail: "\(openTasks.count)") {
                            TaskList(tasks: Array(openTasks.prefix(8)), workspace: workspace)
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, Metrics.pageMargin)
            .padding(.top, 52)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .lpSoftScrollEdge()
        .background(Color.lpCanvas)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ToolbarTitle(title: "Home", symbol: "house")
            }
            .lpWithoutSharedBackground()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.greeting)
                .font(.lp(size: 28, weight: .bold))
                .foregroundStyle(Color.lpInk)
            Text(Day.today.longTitle)
                .font(.lp(size: 14))
                .foregroundStyle(Color.lpInkSecondary)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickAction(title: "New page", hint: "⌘N", symbol: "square.and.pencil", tint: .blue) {
                app.newPage(in: "")
            }
            QuickAction(title: "Today’s note", hint: "⌘T", symbol: "sun.max", tint: .orange) {
                app.openDailyNote()
            }
            QuickAction(title: "New board", hint: "⌥⌘N", symbol: "rectangle.split.3x1", tint: .teal) {
                app.newBoard(in: "")
            }
            QuickAction(title: "Search", hint: "⌘K", symbol: "magnifyingglass", tint: .purple) {
                app.isPaletteVisible = true
            }
        }
    }

    private static var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

// MARK: - Pieces

/// The label shown in the toolbar for destinations that are not pages.
struct ToolbarTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.lp(size: 12))
                .foregroundStyle(Color.lpInkSecondary)
            Text(title)
                .font(.lp(size: 13, weight: .medium))
                .foregroundStyle(Color.lpInk)
        }
        .padding(.horizontal, 6)
    }
}

struct HomeSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.lp(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lpInkSecondary)
                if let detail {
                    Text(detail)
                        .font(.lp(size: 12, weight: .medium))
                        .foregroundStyle(Color.lpInkTertiary)
                }
            }
            content
        }
    }
}

private struct QuickAction: View {
    let title: String
    let hint: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.lp(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.lp(size: 13, weight: .medium))
                    .foregroundStyle(Color.lpInk)
                Spacer(minLength: 4)
                Text(hint)
                    .font(.lp(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.lpInkTertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .cardSurface(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A page shown as a card: icon, title, the start of its text, and when it was last edited.
struct PageCard: View {
    let node: FileNode
    let meta: PageMeta?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                PageIcon(emoji: meta?.icon, size: 34, isDailyNote: meta?.isDailyNote ?? false, isBoard: meta?.isBoard ?? false)
                Text(meta?.displayTitle ?? node.name)
                    .font(.lp(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                    .padding(.top, 12)
                Text(meta?.snippet.isEmpty == false ? meta?.snippet ?? "" : "Empty page")
                    .font(.lp(size: 12.5))
                    .foregroundStyle(meta?.snippet.isEmpty == false ? Color.lpInkSecondary : Color.lpInkTertiary)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if !node.parentPath.isEmpty {
                        Text(FileNode.fileName(of: node.parentPath))
                            .lineLimit(1)
                        Text("·")
                    }
                    Text(node.modified.compactRelative)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.lp(size: 11.5))
                .foregroundStyle(Color.lpInkTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 152, maxHeight: 152, alignment: .topLeading)
            .cardSurface(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A page's emoji, or a neutral document glyph when it has none, on a soft tile.
struct PageIcon: View {
    let emoji: String?
    var size: CGFloat = 30
    var isFolder = false
    var isDailyNote = false
    var isBoard = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(emoji == nil && isDailyNote ? Color.accentColor.opacity(0.13) : Color.lpFillSubtle)
            if let emoji {
                Text(emoji).font(.system(size: size * 0.56))
            } else if isDailyNote {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: isFolder ? "folder" : (isBoard ? "rectangle.split.3x1" : "doc.text"))
                    .font(.system(size: size * 0.44))
                    .foregroundStyle(Color.lpInkSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

extension View {
    /// The raised surface used for cards: a faint border, and a little more depth on hover.
    func cardSurface(isHovering: Bool, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.lpSurface, in: shape)
            .overlay(shape.strokeBorder(Color.lpHairline.opacity(isHovering ? 1.6 : 1), lineWidth: 1))
            .shadow(color: .black.opacity(isHovering ? 0.10 : 0.035), radius: isHovering ? 14 : 3, x: 0, y: isHovering ? 6 : 1)
            .contentShape(shape)
            .animation(.lpQuick, value: isHovering)
    }
}

/// Tasks gathered from across the workspace. Ticking one updates the page it lives in.
struct TaskList: View {
    let tasks: [TaskItem]
    let workspace: Workspace
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                TaskRow(task: task, workspace: workspace)
                if index < tasks.count - 1 {
                    Rectangle()
                        .fill(Color.lpHairline)
                        .frame(height: 1)
                        .padding(.leading, 42)
                }
            }
        }
        .padding(.vertical, 4)
        .cardSurface(isHovering: false)
    }
}

struct TaskRow: View {
    let task: TaskItem
    let workspace: Workspace
    @Environment(AppModel.self) private var app
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                workspace.toggleTask(task)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.lp(size: 16))
                    .foregroundStyle(task.isDone ? Color.accentColor : Color.lpInkTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.isDone ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(task.isDone ? "Mark as not done" : "Mark as done")

            Button {
                app.openPage(task.path)
            } label: {
                HStack(spacing: 8) {
                    Text(task.text)
                        .font(.lp(size: 13))
                        .foregroundStyle(task.isDone ? Color.lpInkTertiary : Color.lpInk)
                        .strikethrough(task.isDone, color: Color.lpInkFaint)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let due = task.due {
                        Text(task.dueTime.map { "\(due.relativeTitle) \($0.title)" } ?? due.relativeTitle)
                            .font(.lp(size: 11.5, weight: .medium))
                            .foregroundStyle(due < Day.today && !task.isDone ? Color.lpCritical : Color.lpInkSecondary)
                    }
                    Text(FileNode.title(of: task.path))
                        .font(.lp(size: 11.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(isHovering ? Color.lpFillHover : .clear)
        .onHover { isHovering = $0 }
    }
}

/// Shown when the chosen folder has no pages in it yet.
struct EmptyWorkspaceView: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkles")
                .font(.lp(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("A fresh start")
                .font(.lp(size: 20, weight: .semibold))
                .foregroundStyle(Color.lpInk)
                .padding(.top, 18)
            Text("This folder has no pages yet. Create your first one, or add a short guide that shows what a page can do.")
                .font(.lp(size: 14))
                .foregroundStyle(Color.lpInkSecondary)
                .lineSpacing(3)
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Button {
                    app.newPage(in: "")
                } label: {
                    Label("New Page", systemImage: "square.and.pencil")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Add a Starter Guide") {
                    if let path = SampleContent.installStarterGuide(in: workspace) {
                        app.openPage(path)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 22)
        }
        .padding(28)
        .frame(maxWidth: 560, alignment: .leading)
        .cardSurface(isHovering: false, cornerRadius: 18)
    }
}

/// A quieter companion to `PrimaryButtonStyle`.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration)
    }

    private struct Appearance: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.lp(size: 14, weight: .medium))
                .foregroundStyle(Color.lpInk)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(configuration.isPressed ? Color.lpFillSelected : (isHovering ? Color.lpFillSelected : Color.lpFillHover),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onHover { isHovering = $0 }
        }
    }
}
