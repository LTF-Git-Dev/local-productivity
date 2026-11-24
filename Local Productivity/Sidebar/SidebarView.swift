//
//  SidebarView.swift
//  Local Productivity
//
//  The left-hand column: the workspace switcher, the fixed destinations (search, home,
//  calendar), favourites, and the tree of folders and pages. Rows are drawn by hand
//  rather than with List so that spacing, hover and selection look exactly as intended.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {

    let workspace: Workspace
    @Environment(AppModel.self) private var app
    @State private var isRootTargeted = false

    private struct TreeRow: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    /// The tree flattened to the rows that are currently visible.
    private var rows: [TreeRow] {
        var result: [TreeRow] = []
        func visit(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                result.append(TreeRow(node: node, depth: depth))
                if node.isFolder, workspace.expanded.contains(node.path) {
                    visit(node.children, depth: depth + 1)
                }
            }
        }
        visit(workspace.root.children, depth: 0)
        return result
    }

    /// Favourites get identities of their own. A page can appear both here and in the tree, and two
    /// rows with the same identity in one lazy stack would be treated as a single row that moved.
    private struct FavoriteRow: Identifiable {
        let node: FileNode
        var id: String { "favorite:" + node.path }
    }

    private var favorites: [FavoriteRow] {
        workspace.favorites.compactMap { workspace.node(at: $0) }.map(FavoriteRow.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSwitcher(workspace: workspace)
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    SidebarNavRow(title: "Search", symbol: "magnifyingglass", hint: "⌘K") {
                        app.isPaletteVisible = true
                    }
                    SidebarNavRow(title: "Home", symbol: "house", isSelected: app.route == .home) {
                        app.show(.home)
                    }
                    SidebarNavRow(title: "Calendar", symbol: "calendar", isSelected: app.route == .calendar) {
                        app.show(.calendar)
                    }
                    SidebarNavRow(title: "Boards", symbol: "rectangle.split.3x1", isSelected: app.route == .boards) {
                        app.show(.boards)
                    }

                    if !favorites.isEmpty {
                        SidebarSectionHeader(title: "Favorites")
                        ForEach(favorites) { favorite in
                            SidebarItemRow(node: favorite.node, depth: 0, workspace: workspace, showsDisclosure: false)
                        }
                    }

                    SidebarSectionHeader(title: "Pages", addsIn: "")
                    .background(isRootTargeted ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                    .onDrop(of: [UTType.plainText], isTargeted: $isRootTargeted) { providers in
                        SidebarDrop.handle(providers, into: "", app: app, workspace: workspace)
                    }

                    ForEach(rows) { row in
                        SidebarItemRow(node: row.node, depth: row.depth, workspace: workspace, showsDisclosure: true)
                    }

                    if workspace.hasLoaded, workspace.root.children.isEmpty {
                        Text("No pages yet")
                            .font(.lp(size: 12.5))
                            .foregroundStyle(Color.lpInkTertiary)
                            .padding(.leading, 8)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .animation(.lpSmooth, value: workspace.expanded)
            }
            .scrollIndicators(.never)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            // A click shows the choices (⌘N still makes a page straight away).
            Menu {
                NewItemButtons(folder: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.lp(size: 12, weight: .semibold))
                        .frame(width: 18)
                    Text("New")
                        .font(.lp(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.lpInkSecondary)
                .padding(.horizontal, 8)
                .frame(height: Metrics.sidebarRowHeight)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(SidebarButtonStyle())
            .menuIndicator(.hidden)
            .help("New page, board or folder")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.lp(size: 13))
                    .foregroundStyle(Color.lpInkSecondary)
                    .frame(width: Metrics.sidebarRowHeight, height: Metrics.sidebarRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.lpHairline).frame(height: 1)
        }
    }
}

// MARK: - Building blocks

/// Hover and press feedback shared by plain sidebar buttons.
struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration)
    }

    private struct SidebarButtonBody: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Color.lpFillSelected : (isHovering ? Color.lpFillHover : .clear),
                            in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                .onHover { isHovering = $0 }
        }
    }
}

private struct SidebarNavRow: View {
    let title: String
    let symbol: String
    var isSelected = false
    var hint: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.lp(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.lpInk : Color.lpInkSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.lp(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.lpInk : Color.lpInk.opacity(0.82))
                Spacer(minLength: 0)
                if let hint, isHovering {
                    Text(hint)
                        .font(.lp(size: 11, weight: .medium))
                        .foregroundStyle(Color.lpInkTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Metrics.sidebarRowHeight)
            .background(isSelected ? Color.lpFillSelected : (isHovering ? Color.lpFillHover : .clear),
                        in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    /// The folder its + offers a new page, board or folder in; nil shows no +.
    var addsIn: String? = nil
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.lp(size: 11, weight: .semibold))
                .foregroundStyle(Color.lpInkTertiary)
            Spacer(minLength: 0)
            if let addsIn {
                Menu {
                    NewItemButtons(folder: addsIn)
                } label: {
                    Image(systemName: "plus")
                        .font(.lp(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lpInkSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(SidebarButtonStyle())
                .menuIndicator(.hidden)
                .opacity(isHovering ? 1 : 0)
                .help("New page, board or folder")
                .accessibilityLabel("New page, board or folder")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .padding(.top, 14)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// New Page / New Board… / New Folder, in `folder` (nil: where LP usually puts new pages).
private struct NewItemButtons: View {
    let folder: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("New Page", systemImage: "square.and.pencil") { app.newPage(in: folder) }
        Button("New Board…", systemImage: "rectangle.split.3x1") { app.newBoard(in: folder) }
        Button("New Folder", systemImage: "folder.badge.plus") { app.newFolder(in: folder) }
    }
}

/// One folder or page in the tree.
private struct SidebarItemRow: View {

    let node: FileNode
    let depth: Int
    let workspace: Workspace
    let showsDisclosure: Bool

    @Environment(AppModel.self) private var app
    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var draft = ""
    @FocusState private var isRenameFocused: Bool

    private var isExpanded: Bool { workspace.expanded.contains(node.path) }

    private var isSelected: Bool {
        app.route == .page(node.path) || app.route == .folder(node.path) || app.route == .board(node.path)
    }

    private var isRenaming: Bool {
        showsDisclosure && app.renamingPath == node.path
    }

    var body: some View {
        HStack(spacing: 2) {
            disclosure
            icon
                .frame(width: 20)
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.lp(size: 13))
                    .focused($isRenameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { app.renamingPath = nil }
                    .padding(.leading, 4)
            } else {
                Text(node.name)
                    .font(.lp(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.lpInk : Color.lpInk.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
            if isHovering, !isRenaming {
                actions
            }
        }
        .padding(.leading, CGFloat(depth) * Metrics.sidebarIndent + 2)
        .padding(.trailing, 4)
        .frame(height: Metrics.sidebarRowHeight)
        .background(background, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .contextMenu { menuItems }
        .onDrag { NSItemProvider(object: node.path as NSString) }
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTargeted) { providers in
            guard node.isFolder else { return false }
            return SidebarDrop.handle(providers, into: node.path, app: app, workspace: workspace)
        }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = node.name
            isRenameFocused = true
        }
        .onChange(of: isRenameFocused) { _, focused in
            if !focused, isRenaming { commitRename() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if isDropTargeted, node.isFolder { return Color.accentColor.opacity(0.18) }
        if isSelected { return .lpFillSelected }
        return isHovering ? .lpFillHover : .clear
    }

    @ViewBuilder
    private var disclosure: some View {
        if node.isFolder, showsDisclosure {
            Button {
                workspace.toggleExpanded(node.path)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.lp(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.lpInkTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse" : "Expand")
            .accessibilityLabel(isExpanded ? "Collapse folder" : "Expand folder")
        } else {
            Color.clear.frame(width: 16, height: 20)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if node.isFolder {
            Image(systemName: isExpanded && showsDisclosure ? "folder.fill" : "folder")
                .font(.lp(size: 12.5))
                .foregroundStyle(Color.lpInkSecondary)
        } else if let emoji = workspace.icon(of: node.path) {
            Text(emoji)
                .font(.lp(size: 13.5))
        } else {
            Image(systemName: workspace.meta[node.path]?.isBoard == true ? "rectangle.split.3x1" : "doc.text")
                .font(.lp(size: 12.5))
                .foregroundStyle(Color.lpInkTertiary)
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.lp(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lpInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Rename, duplicate, delete and more")
            .accessibilityLabel("Rename, duplicate, delete and more")

            if node.isFolder {
                Menu {
                    NewItemButtons(folder: node.path)
                } label: {
                    Image(systemName: "plus")
                        .font(.lp(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lpInkSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("New page, board or folder inside")
                .accessibilityLabel("New page, board or folder inside")
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if node.isFolder {
            NewItemButtons(folder: node.path)
            Divider()
        } else {
            Button(workspace.isFavorite(node.path) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: workspace.isFavorite(node.path) ? "star.slash" : "star") {
                workspace.toggleFavorite(node.path)
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { app.duplicate(node.path) }
            Divider()
        }
        Button("Rename", systemImage: "pencil") {
            workspace.expand(to: node.path)
            app.renamingPath = node.path
        }
        Button("Reveal in Finder", systemImage: "folder") { workspace.revealInFinder(node.path) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { app.trash(node.path) }
    }

    private func open() {
        guard !isRenaming else { return }
        if node.isFolder {
            if showsDisclosure, !isExpanded { workspace.toggleExpanded(node.path) }
            app.show(.folder(node.path))
        } else {
            app.openPage(node.path)
        }
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = node.path
        app.renamingPath = nil
        guard !name.isEmpty, name != node.name else { return }
        app.rename(path, to: name)
    }
}

/// Moving rows by dragging them onto a folder, or onto the "Pages" header for the top level.
enum SidebarDrop {
    static func handle(_ providers: [NSItemProvider], into folder: String, app: AppModel, workspace: Workspace) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let path = object as? String else { return }
            Task { @MainActor in
                // Only rows dragged from this sidebar are paths inside the workspace.
                guard workspace.node(at: path) != nil, path != folder else { return }
                app.move(path, into: folder)
            }
        }
        return true
    }
}

// MARK: - Workspace switcher

private struct WorkspaceSwitcher: View {

    let workspace: Workspace
    @Environment(AppModel.self) private var app
    @State private var isHovering = false

    var body: some View {
        Menu {
            Section("Workspaces") {
                ForEach(app.library.records) { record in
                    Button {
                        if record.id != workspace.record.id { app.openWorkspace(record) }
                    } label: {
                        if record.id == workspace.record.id {
                            Label(record.name, systemImage: "checkmark")
                        } else {
                            Text(record.name)
                        }
                    }
                }
            }
            Divider()
            Button("Open Another Folder…", systemImage: "folder.badge.plus") { app.chooseWorkspace() }
            Button("Reveal in Finder", systemImage: "folder") { workspace.revealInFinder("") }
            Divider()
            Button("Close Workspace", systemImage: "xmark") { app.closeWorkspace() }
        } label: {
            HStack(spacing: 8) {
                WorkspaceBadge(name: workspace.name, size: 22)
                Text(workspace.name)
                    .font(.lp(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.lp(size: 9, weight: .semibold))
                    .foregroundStyle(Color.lpInkTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(isHovering ? Color.lpFillHover : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovering = $0 }
    }
}

/// A small coloured tile with the workspace's initial, standing in for a workspace icon.
struct WorkspaceBadge: View {
    let name: String
    var size: CGFloat = 22

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.36, green: 0.55, blue: 0.98), Color(red: 0.25, green: 0.38, blue: 0.92)),
        (Color(red: 0.98, green: 0.60, blue: 0.35), Color(red: 0.94, green: 0.40, blue: 0.33)),
        (Color(red: 0.40, green: 0.78, blue: 0.62), Color(red: 0.20, green: 0.62, blue: 0.56)),
        (Color(red: 0.74, green: 0.55, blue: 0.96), Color(red: 0.55, green: 0.40, blue: 0.90)),
        (Color(red: 0.96, green: 0.52, blue: 0.70), Color(red: 0.88, green: 0.36, blue: 0.56)),
        (Color(red: 0.50, green: 0.56, blue: 0.66), Color(red: 0.36, green: 0.41, blue: 0.51))
    ]

    var body: some View {
        // A stable hash, so a workspace keeps its colour between launches.
        let seed = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let colors = Self.palette[abs(seed) % Self.palette.count]
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.first ?? "W").uppercased())
                    .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}
