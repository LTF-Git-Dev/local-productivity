//
//  PageView.swift
//  Local Productivity
//
//  The screen for one page: the editor, its toolbar (where it lives in the workspace,
//  favourite, page options) and the sheet for editing a table.
//

import SwiftUI

struct PageView: View {

    @Bindable var session: PageSession
    @Environment(AppModel.self) private var app

    var body: some View {
        EditorHost(session: session, app: app)
            .overlay(alignment: .top) {
                // Text fades out as it scrolls up to the toolbar instead of being cut off.
                LinearGradient(colors: [Color.lpCanvas, Color.lpCanvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                    .allowsHitTesting(false)
            }
            .background(Color.lpCanvas)
            .navigationTitle(session.title.isEmpty ? "Untitled" : session.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Breadcrumb(path: session.path, icon: session.icon)
                }
                .lpWithoutSharedBackground()

                LPFlexibleToolbarSpace()

                ToolbarItemGroup(placement: .primaryAction) {
                    if case .failed(let reason) = session.status {
                        Label("Couldn’t save", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(reason)
                    }
                    Button {
                        session.workspace.toggleFavorite(session.path)
                    } label: {
                        Image(systemName: session.workspace.isFavorite(session.path) ? "star.fill" : "star")
                            .foregroundStyle(session.workspace.isFavorite(session.path) ? Color.yellow : Color.primary)
                    }
                    .help(session.workspace.isFavorite(session.path) ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(session.workspace.isFavorite(session.path) ? "Remove from Favorites" : "Add to Favorites")

                    PageOptionsMenu(session: session)
                }
            }
            .sheet(item: $session.tableEdit) { edit in
                TableEditorView(table: edit.table) { table in
                    var committed = edit
                    committed.table = table
                    session.tableEdit = nil
                    session.controller?.commitTableEdit(committed)
                } onCancel: {
                    session.tableEdit = nil
                }
            }
    }
}

/// Bridges the AppKit editor into SwiftUI.
private struct EditorHost: NSViewControllerRepresentable {

    let session: PageSession
    let app: AppModel

    func makeNSViewController(context: Context) -> EditorController {
        let controller = EditorController(session: session, app: app)
        controller.apply(app.settings)
        return controller
    }

    func updateNSViewController(_ controller: EditorController, context: Context) {
        // Reading the settings here re-runs this method whenever one of them changes.
        controller.apply(app.settings)
        if session.focusRequest == .body {
            DispatchQueue.main.async {
                guard session.focusRequest == .body else { return }
                session.focusRequest = nil
                controller.focusBody()
            }
        }
    }
}

// MARK: - Toolbar pieces

/// "Projects › Launch › Plan": the folders leading to the page, each one a way back up.
struct Breadcrumb: View {

    let path: String
    var icon: String? = nil
    var isFolder = false
    /// Shown when there is no emoji icon, such as the board symbol.
    var symbol: String? = nil
    @Environment(AppModel.self) private var app

    /// The nearest two folders. Anything further up is summarised as an ellipsis.
    private var folders: [String] {
        Array(FileNode.ancestors(of: path).suffix(2))
    }

    var body: some View {
        HStack(spacing: 5) {
            if FileNode.ancestors(of: path).count > folders.count {
                Text("…")
                    .foregroundStyle(Color.lpInkTertiary)
                Image(systemName: "chevron.right")
                    .font(.lp(size: 8, weight: .semibold))
                    .foregroundStyle(Color.lpInkFaint)
            }
            ForEach(folders, id: \.self) { folder in
                Button {
                    app.show(.folder(folder))
                } label: {
                    Text(FileNode.fileName(of: folder))
                        .foregroundStyle(Color.lpInkSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.lp(size: 8, weight: .semibold))
                    .foregroundStyle(Color.lpInkFaint)
            }
            if let icon {
                Text(icon).font(.lp(size: 13))
            } else if isFolder || symbol != nil {
                Image(systemName: symbol ?? "folder")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkSecondary)
            }
            Text(isFolder ? FileNode.fileName(of: path) : FileNode.title(of: path))
                .fontWeight(.medium)
                .foregroundStyle(Color.lpInk)
                .lineLimit(1)
                .frame(maxWidth: 280)
                .fixedSize()
        }
        .font(.lp(size: 13))
        .padding(.horizontal, 6)
    }
}

private struct PageOptionsMenu: View {

    let session: PageSession
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Menu {
            Picker("Font", selection: $settings.editorFont) {
                ForEach(AppSettings.EditorFont.allCases.filter { $0 != .custom || !settings.editorFontFamily.isEmpty }) { font in
                    Text(font == .custom ? settings.editorFontFamily : font.title).tag(font)
                }
            }
            Menu("Text Size") {
                Button("Bigger") { settings.makeTextBigger() }
                    .disabled(settings.editorTextSize >= EditorTheme.textSizes.upperBound)
                Button("Smaller") { settings.makeTextSmaller() }
                    .disabled(settings.editorTextSize <= EditorTheme.textSizes.lowerBound)
                Button("Default Size") { settings.resetTextSize() }
                    .disabled(settings.editorTextSize == EditorTheme.defaultTextSize)
                Divider()
                Text("\(Int(settings.editorTextSize)) pt")
            }
            Picker("Line Spacing", selection: $settings.lineSpacing) {
                ForEach(AppSettings.LineSpacing.allCases) { spacing in
                    Text(spacing.title).tag(spacing)
                }
            }
            Picker("Page Width", selection: $settings.pageWidth) {
                ForEach(AppSettings.PageWidth.allCases) { width in
                    Text(width.title).tag(width)
                }
            }

            Divider()
            Button("Reveal in Finder", systemImage: "folder") {
                session.workspace.revealInFinder(session.path)
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                app.duplicate(session.path)
            }
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                app.trash(session.path)
            }

            Divider()
            Text(summary)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Page Options")
        .accessibilityLabel("Page Options")
    }

    private var summary: String {
        let words = session.wordCount == 1 ? "1 word" : "\(session.wordCount.formatted()) words"
        guard let modified = session.modified else { return words }
        return "\(words) · Edited \(modified.inlineRelative)"
    }
}

// MARK: - Table editor

/// Edits a table as a grid of fields. Cells hold Markdown, so `**bold**` works inside them.
struct TableEditorView: View {

    @State var table: TableInfo
    var onCommit: (TableInfo) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Table")
                .font(.lp(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            columnControls(column)
                        }
                    }
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(text: headerBinding(column), prompt: "Header", isHeader: true)
                        }
                    }
                    ForEach(0..<table.rows.count, id: \.self) { row in
                        GridRow {
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                cell(text: cellBinding(row, column), prompt: "", isHeader: false)
                            }
                            Button {
                                table.rows.remove(at: row)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(Color.lpInkTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete row")
                            .accessibilityLabel("Delete row")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 160, maxHeight: 380)

            HStack(spacing: 8) {
                Button("Add Row", systemImage: "plus") {
                    table.rows.append(Array(repeating: "", count: table.columnCount))
                }
                Button("Add Column", systemImage: "plus") {
                    table.alignments.append(.none)
                    table.header.append("")
                    table.rows = table.rows.map { $0 + [""] }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onCommit(cleaned()) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 560, idealWidth: 680)
    }

    private func cell(text: Binding<String>, prompt: String, isHeader: Bool) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.lp(size: 13, weight: isHeader ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(width: 168, height: 30)
            .background(isHeader ? Color.lpFillSelected : Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func columnControls(_ column: Int) -> some View {
        HStack(spacing: 2) {
            Picker("Alignment", selection: alignmentBinding(column)) {
                Image(systemName: "text.alignleft").tag(TableInfo.Alignment.none)
                Image(systemName: "text.aligncenter").tag(TableInfo.Alignment.center)
                Image(systemName: "text.alignright").tag(TableInfo.Alignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)
            Spacer(minLength: 0)
            if table.columnCount > 1 {
                Button {
                    removeColumn(column)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Color.lpInkTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete column")
                .accessibilityLabel("Delete column")
            }
        }
        .frame(width: 168)
    }

    private func headerBinding(_ column: Int) -> Binding<String> {
        Binding(
            get: { column < table.header.count ? table.header[column] : "" },
            set: { if column < table.header.count { table.header[column] = $0 } }
        )
    }

    private func cellBinding(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(
            get: { row < table.rows.count && column < table.rows[row].count ? table.rows[row][column] : "" },
            set: { value in
                guard row < table.rows.count else { return }
                while table.rows[row].count <= column { table.rows[row].append("") }
                table.rows[row][column] = value
            }
        )
    }

    private func alignmentBinding(_ column: Int) -> Binding<TableInfo.Alignment> {
        Binding(
            get: {
                let alignment = column < table.alignments.count ? table.alignments[column] : .none
                return alignment == .left ? .none : alignment
            },
            set: { if column < table.alignments.count { table.alignments[column] = $0 } }
        )
    }

    private func removeColumn(_ column: Int) {
        guard table.columnCount > 1, column < table.columnCount else { return }
        table.alignments.remove(at: column)
        if column < table.header.count { table.header.remove(at: column) }
        table.rows = table.rows.map { row in
            var copy = row
            if column < copy.count { copy.remove(at: column) }
            return copy
        }
    }

    /// Makes cell text safe to sit between the pipes of a Markdown table row.
    private func cleaned() -> TableInfo {
        func clean(_ text: String) -> String {
            var result = ""
            var previous: Character? = nil
            for character in text.replacingOccurrences(of: "\n", with: "<br>") {
                if character == "|", previous != "\\" { result.append("\\") }
                result.append(character)
                previous = character
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        var result = table
        result.header = table.header.map(clean)
        result.rows = table.rows.map { $0.map(clean) }
        result.source = nil
        return result
    }
}
