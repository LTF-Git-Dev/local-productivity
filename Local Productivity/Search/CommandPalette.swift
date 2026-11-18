//
//  CommandPalette.swift
//  Local Productivity
//
//  ⌘K. One field that finds pages by name, searches inside them, and runs the handful
//  of actions you would otherwise reach for in a menu.
//

import SwiftUI

struct CommandPalette: View {

    let workspace: Workspace
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var selection = 0
    @State private var contentHits: [SearchHit] = []
    @FocusState private var isFocused: Bool

    private struct Item: Identifiable {
        let id: String
        var emoji: String? = nil
        var symbol: String
        var title: String
        var subtitle: String? = nil
        var section: String
        var run: () -> Void
    }

    private var terms: [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: Results

    private var items: [Item] {
        let terms = terms
        var items: [Item] = []

        if terms.isEmpty {
            for path in workspace.recents.prefix(6) {
                guard let node = workspace.node(at: path), !node.isFolder else { continue }
                items.append(pageItem(node, section: "Recent"))
            }
            items.append(contentsOf: actions)
            return items
        }

        // Pages whose name contains every search term, best matches first.
        let matches = workspace.pages
            .filter { page in terms.allSatisfy { page.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            .sorted { rank($0.name) != rank($1.name) ? rank($0.name) < rank($1.name) : $0.name.count < $1.name.count }
            .prefix(7)
        items.append(contentsOf: matches.map { pageItem($0, section: "Pages") })

        let shown = Set(matches.map(\.path))
        for hit in contentHits where !shown.contains(hit.path) && !hit.isTitleMatch {
            items.append(Item(id: "hit:" + hit.path, emoji: hit.icon, symbol: "text.magnifyingglass", title: hit.title,
                              subtitle: hit.snippet, section: "In pages") { open(hit.path) })
            if items.count > 14 { break }
        }

        items.append(contentsOf: actions.filter { action in
            terms.allSatisfy { action.title.range(of: $0, options: .caseInsensitive) != nil }
        })

        let title = query.trimmingCharacters(in: .whitespaces)
        if !workspace.pages.contains(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) {
            items.append(Item(id: "create", symbol: "plus", title: "Create “\(title)”", subtitle: nil, section: "New") {
                close()
                if let path = try? workspace.createPage(in: app.currentFolder, title: title) {
                    app.openPage(path)
                    app.session?.focusRequest = .body
                }
            })
        }
        return items
    }

    private var actions: [Item] {
        [
            Item(id: "action:new", symbol: "square.and.pencil", title: "New Page", subtitle: nil, section: "Actions") {
                close()
                app.newPage()
            },
            Item(id: "action:board", symbol: "rectangle.split.3x1", title: "New Board", subtitle: nil, section: "Actions") {
                close()
                app.newBoard()
            },
            Item(id: "action:today", symbol: "sun.max", title: "Open Today’s Note", subtitle: nil, section: "Actions") {
                close()
                app.openDailyNote()
            },
            Item(id: "action:home", symbol: "house", title: "Go to Home", subtitle: nil, section: "Actions") {
                close()
                app.show(.home)
            },
            Item(id: "action:calendar", symbol: "calendar", title: "Go to Calendar", subtitle: nil, section: "Actions") {
                close()
                app.show(.calendar)
            },
            Item(id: "action:workspace", symbol: "folder", title: "Open Another Workspace…", subtitle: nil, section: "Actions") {
                close()
                app.chooseWorkspace()
            }
        ]
    }

    private func pageItem(_ node: FileNode, section: String) -> Item {
        Item(id: "page:" + node.path, emoji: workspace.icon(of: node.path),
             symbol: workspace.meta[node.path]?.isBoard == true ? "rectangle.split.3x1" : "doc.text", title: node.name,
             subtitle: node.parentPath.isEmpty ? nil : node.parentPath.replacingOccurrences(of: "/", with: " › "),
             section: section) { open(node.path) }
    }

    /// Lower is better: names that start with the query beat names that merely contain it.
    private func rank(_ name: String) -> Int {
        guard let first = terms.first else { return 0 }
        let lowered = name.lowercased()
        let needle = first.lowercased()
        if lowered.hasPrefix(needle) { return 0 }
        if lowered.contains(" " + needle) { return 1 }
        return 2
    }

    private func open(_ path: String) {
        close()
        app.openPage(path)
    }

    private func close() {
        app.isPaletteVisible = false
    }

    // MARK: View

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            Color.black.opacity(colorScheme == .dark ? 0.32 : 0.14)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                field(items)
                if !items.isEmpty {
                    Rectangle().fill(Color.lpHairline).frame(height: 1)
                    results(items)
                }
                footer
            }
            .frame(width: 620)
            .floatingSurface(cornerRadius: 16)
            .padding(.top, 84)
        }
        .onAppear {
            query = app.paletteSeed
            app.paletteSeed = ""
            isFocused = true
        }
        .onChange(of: query) { selection = 0 }
        .task(id: query) {
            guard !terms.isEmpty else {
                contentHits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let hits = await workspace.search(query)
            guard !Task.isCancelled else { return }
            contentHits = hits
        }
    }

    private func field(_ items: [Item]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.lp(size: 17, weight: .medium))
                .foregroundStyle(Color.lpInkTertiary)
            TextField("Search pages, text and actions", text: $query)
                .textFieldStyle(.plain)
                .font(.lp(size: 18))
                .foregroundStyle(Color.lpInk)
                .focused($isFocused)
                .onSubmit {
                    if items.indices.contains(selection) { items[selection].run() }
                }
                .onKeyPress(.downArrow) {
                    if !items.isEmpty { selection = (selection + 1) % items.count }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if !items.isEmpty { selection = (selection - 1 + items.count) % items.count }
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func results(_ items: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].section != item.section {
                            Text(item.section)
                                .font(.lp(size: 11, weight: .semibold))
                                .foregroundStyle(Color.lpInkTertiary)
                                .padding(.leading, 10)
                                .padding(.top, index == 0 ? 6 : 12)
                                .padding(.bottom, 3)
                        }
                        row(item, isSelected: index == selection)
                            .id(item.id)
                            .onTapGesture { item.run() }
                            .onHover { if $0 { selection = index } }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 392)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, selection in
                if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) }
            }
        }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.lpFillSubtle)
                if let emoji = item.emoji {
                    Text(emoji).font(.lp(size: 14))
                } else {
                    Image(systemName: item.symbol)
                        .font(.lp(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.lpInkSecondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(Self.highlighted(item.title, terms: terms, emphasis: Color.lpInk, base: Color.lpInk.opacity(terms.isEmpty ? 1 : 0.72),
                                      emphasisFont: .system(size: 13.5, weight: .semibold)))
                    .font(.lp(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(Self.highlighted(subtitle, terms: terms, emphasis: Color.lpInk, base: Color.lpInkTertiary,
                                          emphasisFont: .system(size: 12, weight: .medium)))
                        .font(.lp(size: 12))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "return")
                    .font(.lp(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.lpInkTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: item.subtitle == nil ? 38 : 46)
        .background(isSelected ? Color.lpFillSelected : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Navigate")
            hint("↵", "Open")
            hint("esc", "Close")
            Spacer()
            Text(workspace.pages.count == 1 ? "1 page" : "\(workspace.pages.count.formatted()) pages")
                .font(.lp(size: 11))
                .foregroundStyle(Color.lpInkTertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.lpHairline).frame(height: 1)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.lp(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.lpInkSecondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(Color.lpFillHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.lp(size: 11))
                .foregroundStyle(Color.lpInkTertiary)
        }
    }

    /// Text with every occurrence of a search term picked out in the emphasis colour.
    static func highlighted(_ text: String, terms: [String], emphasis: Color, base: Color, emphasisFont: Font) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = base
        for term in terms where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let lower = AttributedString.Index(found.lowerBound, within: result),
                   let upper = AttributedString.Index(found.upperBound, within: result) {
                    result[lower..<upper].foregroundColor = emphasis
                    result[lower..<upper].font = emphasisFont
                }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return result
    }
}
