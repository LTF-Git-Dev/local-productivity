//
//  EditorOverlays.swift
//  Local Productivity
//
//  The small pieces of interface that float over the page while writing: the menu
//  that opens for "/" and "[[", the formatting bar above a selection, and the link
//  field. They share one surface style so they read as a family.
//

import SwiftUI

// MARK: - Shared surface

/// The look of anything that floats above the page.
struct FloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.lpHairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func floatingSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius))
    }
}

// MARK: - Inline menu

enum EditorMenuAction {
    case turnInto(BlockKind)
    case divider
    case table
    case link(title: String)
    case createPage(title: String)
}

struct EditorMenuItem: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var symbol: String
    /// Shown instead of the symbol: a page's emoji, or a short label such as "H1".
    var emoji: String?
    var glyph: String? = nil
    var keywords: [String] = []
    var action: EditorMenuAction

    static let commands: [EditorMenuItem] = [
        EditorMenuItem(id: "text", title: "Text", subtitle: "Plain paragraph", symbol: "textformat",
                       keywords: ["paragraph", "plain", "body"], action: .turnInto(.paragraph)),
        EditorMenuItem(id: "h1", title: "Heading 1", subtitle: "Large section heading", symbol: "textformat.size",
                       glyph: "H1", keywords: ["h1", "title", "#"], action: .turnInto(.heading1)),
        EditorMenuItem(id: "h2", title: "Heading 2", subtitle: "Medium section heading", symbol: "textformat.size",
                       glyph: "H2", keywords: ["h2", "subtitle", "##"], action: .turnInto(.heading2)),
        EditorMenuItem(id: "h3", title: "Heading 3", subtitle: "Small section heading", symbol: "textformat.size",
                       glyph: "H3", keywords: ["h3", "###"], action: .turnInto(.heading3)),
        EditorMenuItem(id: "todo", title: "To-do list", subtitle: "Track tasks with checkboxes", symbol: "checkmark.square",
                       keywords: ["task", "checkbox", "check", "todo"], action: .turnInto(.openTodo)),
        EditorMenuItem(id: "bullet", title: "Bulleted list", subtitle: "A simple list", symbol: "list.bullet",
                       keywords: ["unordered", "ul", "bullets"], action: .turnInto(.bulletItem)),
        EditorMenuItem(id: "number", title: "Numbered list", subtitle: "A list with numbers", symbol: "list.number",
                       keywords: ["ordered", "ol", "1."], action: .turnInto(.numberedItem)),
        EditorMenuItem(id: "quote", title: "Quote", subtitle: "Capture a quotation", symbol: "text.quote",
                       keywords: ["blockquote", "citation"], action: .turnInto(.quote)),
        EditorMenuItem(id: "callout", title: "Callout", subtitle: "Make text stand out", symbol: "lightbulb",
                       keywords: ["note", "info", "tip", "warning", "admonition"], action: .turnInto(.note)),
        EditorMenuItem(id: "code", title: "Code", subtitle: "A block of code", symbol: "chevron.left.forwardslash.chevron.right",
                       keywords: ["snippet", "pre", "```"], action: .turnInto(.codeBlock)),
        EditorMenuItem(id: "divider", title: "Divider", subtitle: "Separate sections", symbol: "minus",
                       keywords: ["rule", "line", "hr", "separator", "---"], action: .divider),
        EditorMenuItem(id: "table", title: "Table", subtitle: "Rows and columns", symbol: "tablecells",
                       keywords: ["grid", "columns", "rows"], action: .table)
    ]

    static func commands(matching text: String) -> [EditorMenuItem] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return commands }
        let starts = commands.filter { $0.title.lowercased().hasPrefix(needle) || $0.keywords.contains { $0.hasPrefix(needle) } }
        let contains = commands.filter { item in
            !starts.contains { $0.id == item.id } && item.title.lowercased().contains(needle)
        }
        return starts + contains
    }
}

@Observable
final class EditorMenuModel {
    var title = ""
    var emptyText = ""
    var items: [EditorMenuItem] = []
    var selection = 0
    @ObservationIgnored var onPick: ((EditorMenuItem) -> Void)?

    var selectedItem: EditorMenuItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }
}

struct EditorMenuView: View {

    /// Transparent margin around the panel so its shadow is not clipped by the hosting view.
    static let shadowPadding: CGFloat = 28

    let model: EditorMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.lp(size: 11, weight: .semibold))
                .foregroundStyle(Color.lpInkTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if model.items.isEmpty {
                Text(model.emptyText)
                    .font(.lp(size: 13))
                    .foregroundStyle(Color.lpInkTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == model.selection)
                                    .id(item.id)
                                    .onTapGesture { model.onPick?(item) }
                                    // One button per choice for VoiceOver, as the keyboard already has.
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { model.onPick?(item) }
                                    .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(model.items.count) * 45 + 6, 322))
                    .onChange(of: model.selection) { _, selection in
                        if model.items.indices.contains(selection) { proxy.scrollTo(model.items[selection].id) }
                    }
                }
            }
        }
        .frame(width: 284, alignment: .leading)
        .floatingSurface()
        .padding(Self.shadowPadding)
    }

    private func row(_ item: EditorMenuItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.lpSurface.opacity(0.9))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.lpHairline, lineWidth: 1)
                if let emoji = item.emoji {
                    Text(emoji).font(.lp(size: 15))
                } else if let glyph = item.glyph {
                    Text(glyph)
                        .font(.lp(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.lpInkSecondary)
                } else {
                    Image(systemName: item.symbol)
                        .font(.lp(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.lpInkSecondary)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.lp(size: 13, weight: .medium))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.lp(size: 11))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(isSelected ? Color.lpFillSelected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Formatting bar

@Observable
final class FormatBarModel {
    var active: Set<EditorTextView.InlineFormat> = []
    var hasLink = false
    @ObservationIgnored var onToggle: ((EditorTextView.InlineFormat) -> Void)?
    @ObservationIgnored var onLink: (() -> Void)?
}

struct FormatBarView: View {

    static let shadowPadding: CGFloat = 24

    let model: FormatBarModel

    var body: some View {
        HStack(spacing: 2) {
            button("bold", "Bold", isOn: model.active.contains(.bold)) { model.onToggle?(.bold) }
            button("italic", "Italic", isOn: model.active.contains(.italic)) { model.onToggle?(.italic) }
            button("strikethrough", "Strikethrough", isOn: model.active.contains(.strikethrough)) { model.onToggle?(.strikethrough) }
            button("chevron.left.forwardslash.chevron.right", "Code", isOn: model.active.contains(.code)) { model.onToggle?(.code) }
            button("highlighter", "Highlight", isOn: model.active.contains(.highlight)) { model.onToggle?(.highlight) }
            Rectangle()
                .fill(Color.lpHairline)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 3)
            button("link", "Link", isOn: model.hasLink) { model.onLink?() }
        }
        .padding(4)
        .floatingSurface(cornerRadius: 10)
        .padding(Self.shadowPadding)
    }

    private func button(_ symbol: String, _ help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.lp(size: 12.5, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.lpInk.opacity(0.82))
                .frame(width: 30, height: 26)
                .background(isOn ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Link field

struct LinkEditorView: View {

    @State var destination: String
    var onCommit: (String) -> Void
    var onRemove: (() -> Void)?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.lp(size: 12, weight: .medium))
                .foregroundStyle(Color.lpInkTertiary)
            TextField("Paste or type a link", text: $destination)
                .textFieldStyle(.plain)
                .font(.lp(size: 13))
                .focused($isFocused)
                .onSubmit { onCommit(destination.trimmingCharacters(in: .whitespaces)) }
                .frame(width: 250)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.lp(size: 12))
                        .foregroundStyle(Color.lpInkSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove link")
                .accessibilityLabel("Remove link")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { isFocused = true }
    }
}

// MARK: - Block handle

/// The two small controls that appear in the margin beside the block under the pointer:
/// add a block below, and open the block's menu.
struct BlockHandleView: View {

    static let size = CGSize(width: 46, height: 24)

    var onAdd: () -> Void
    var onMenu: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            HandleButton(help: "Add a block below", action: onAdd) {
                Image(systemName: "plus")
                    .font(.lp(size: 11.5, weight: .semibold))
            }
            HandleButton(help: "Turn into, move, duplicate or delete", action: onMenu) {
                // A six-dot grip, drawn rather than borrowed from a symbol so it stays crisp at this size.
                VStack(spacing: 2.2) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 2.2) {
                            Circle().frame(width: 2.6, height: 2.6)
                            Circle().frame(width: 2.6, height: 2.6)
                        }
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private struct HandleButton<Label: View>: View {
        let help: String
        let action: () -> Void
        @ViewBuilder var label: Label
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                label
                    .foregroundStyle(isHovering ? Color.lpInkSecondary : Color.lpInkTertiary)
                    .frame(width: 22, height: 24)
                    .background(isHovering ? Color.lpFillSelected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
            .onHover { isHovering = $0 }
        }
    }
}
