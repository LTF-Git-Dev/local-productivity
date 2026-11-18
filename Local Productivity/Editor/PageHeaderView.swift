//
//  PageHeaderView.swift
//  Local Productivity
//
//  The top of a page: an optional emoji icon and the large title. The title is the
//  file's name, so committing an edit renames the file on disk.
//

import SwiftUI

struct PageHeaderView: View {

    @Bindable var session: PageSession
    let app: AppModel
    /// Called when the header's height may have changed so the editor can make room.
    var onLayoutChange: () -> Void

    @FocusState private var isTitleFocused: Bool
    @State private var isHovering = false
    @State private var showsIconPicker = false

    /// The page icon is sized with the title.
    private var iconSize: CGFloat { (app.settings.editorTheme.titleSize * 1.4).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let icon = session.icon {
                Button {
                    showsIconPicker = true
                } label: {
                    Text(icon)
                        .font(.system(size: iconSize))
                        .frame(height: iconSize + 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change icon")
                .accessibilityLabel("Change icon")
                .padding(.leading, -3)
                .padding(.bottom, 2)
            } else {
                Button {
                    session.setIcon(EmojiCatalog.suggestion())
                } label: {
                    Label("Add icon", systemImage: "face.smiling")
                        .font(.lp(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.lpInkTertiary)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background(Color.lpFillHover.opacity(isHovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .padding(.leading, -7)
                .animation(.lpQuick, value: isHovering)
            }

            TextField("Untitled", text: $session.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(app.settings.pageFont(size: app.settings.editorTheme.titleSize, weight: .bold))
                .foregroundStyle(Color.lpInk)
                .lineLimit(1...5)
                .focused($isTitleFocused)
                .onSubmit {
                    commitTitle()
                    session.focusRequest = .body
                }
                .onKeyPress(.downArrow) {
                    commitTitle()
                    session.focusRequest = .body
                    return .handled
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .popover(isPresented: $showsIconPicker, arrowEdge: .bottom) {
            EmojiPicker(current: session.icon) { choice in
                session.setIcon(choice)
                showsIconPicker = false
            }
        }
        .onChange(of: isTitleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onChange(of: session.focusRequest, initial: true) { _, request in
            guard request == .title else { return }
            isTitleFocused = true
            session.focusRequest = nil
        }
        .onChange(of: session.title) { onLayoutChange() }
        .onChange(of: session.icon) { onLayoutChange() }
        .onChange(of: app.settings.editorTextSize) { onLayoutChange() }
        .onChange(of: app.settings.editorFont) { onLayoutChange() }
        .onChange(of: app.settings.editorFontFamily) { onLayoutChange() }
    }

    /// Renames the file to match the title. An empty or unusable title snaps back.
    private func commitTitle() {
        let current = FileNode.title(of: session.path)
        let wanted = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted != current else {
            if session.title != current { session.title = current }
            return
        }
        if !app.rename(session.path, to: wanted) {
            session.title = current
        }
    }
}

// MARK: - Emoji picker

enum EmojiCatalog {

    static let groups: [(name: String, emoji: [String])] = [
        ("Notes", ["📄", "📝", "📒", "📓", "📔", "📕", "📗", "📘", "📙", "📚", "📖", "🔖", "🗂", "📁", "📂", "🗃", "📋", "📌", "📍", "📎", "✏️", "🖊", "🖋", "🖌"]),
        ("Work", ["💡", "🎯", "🚀", "🧭", "🗺", "🧩", "🔍", "🔑", "🔒", "📅", "🗓", "⏰", "⏳", "💼", "🛠", "⚙️", "🧪", "🔬", "💻", "📱", "📈", "📊", "💰", "🧾"]),
        ("Nature", ["🌱", "🌿", "🍀", "🌳", "🌵", "🌸", "🌻", "🍂", "🌍", "🌙", "⭐️", "✨", "⚡️", "🔥", "💧", "🌈", "☀️", "⛅️", "❄️", "🌊", "⛰", "🏝", "🦋", "🐝"]),
        ("Life", ["🏠", "🏢", "✈️", "🚗", "🚲", "🍎", "🍋", "🥑", "🍞", "🍜", "🍰", "☕️", "🍵", "🎵", "🎧", "🎬", "📷", "🎨", "🎮", "⚽️", "🏆", "🎁", "🎉", "🧘"]),
        ("Symbols", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "✅", "☑️", "❌", "⚠️", "❓", "❗️", "💬", "💭", "📣", "🔔", "💯", "🙌", "👍", "👀", "🧠", "🙂"])
    ]

    /// A friendly default for a page that has no icon yet.
    static func suggestion() -> String {
        ["📄", "📝", "📒", "💡", "🎯", "🚀", "🌱", "✨", "📚", "🧭", "🗂", "🔖"].randomElement() ?? "📄"
    }
}

struct EmojiPicker: View {

    var current: String?
    var onPick: (String?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 2), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Icon")
                    .font(.lp(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
                Spacer()
                if current != nil {
                    Button("Remove") { onPick(nil) }
                        .buttonStyle(.plain)
                        .font(.lp(size: 12, weight: .medium))
                        .foregroundStyle(Color.lpInkSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(EmojiCatalog.groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name)
                                .font(.lp(size: 11, weight: .semibold))
                                .foregroundStyle(Color.lpInkTertiary)
                                .padding(.leading, 4)
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(group.emoji, id: \.self) { emoji in
                                    EmojiCell(emoji: emoji, isCurrent: emoji == current) { onPick(emoji) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(height: 300)
        }
        .frame(width: 292)
    }
}

private struct EmojiCell: View {
    let emoji: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.lp(size: 19))
                .frame(width: 32, height: 32)
                .background(isCurrent ? Color.lpFillSelected : (isHovering ? Color.lpFillHover : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
