//
//  LocalProductivityApp.swift
//  Local Productivity
//
//  A calm, native home for a folder of Markdown notes.
//

import SwiftUI

@main
struct LocalProductivityApp: App {

    @State private var app: AppModel

    init() {
        #if DEBUG
        // UI snapshots run against a throwaway model so they never touch real preferences.
        _app = State(initialValue: AppModel(defaults: SnapshotHarness.isActive ? nil : .standard))
        #else
        _app = State(initialValue: AppModel())
        #endif
    }

    var body: some Scene {
        Window("LP", id: "main") {
            RootView()
                .environment(app)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

// MARK: - Menu bar

struct AppCommands: Commands {

    let app: AppModel

    private var hasWorkspace: Bool { app.workspace != nil }
    private var editor: EditorController? { app.session?.controller }

    var body: some Commands {
        SidebarCommands()
        TextEditingCommands()
        // Pages are not printed from here, which leaves ⌘P free for Quick Open.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .newItem) {
            Button("New Page") { app.newPage() }
                .keyboardShortcut("n")
                .disabled(!hasWorkspace)
            Button("New Board…") { app.newBoard() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!hasWorkspace)
            Button("New Folder") { app.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!hasWorkspace)
            Divider()
            Button("Open Workspace…") { app.chooseWorkspace() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.library.records) { record in
                    Button(record.name) { app.openWorkspace(record) }
                }
            }
            .disabled(app.library.records.isEmpty)
            Button("Close Workspace") { app.closeWorkspace() }
                .disabled(!hasWorkspace)
        }

        CommandGroup(replacing: .textFormatting) {
            Button("Bold") { editor?.perform(.format(.bold)) }
                .keyboardShortcut("b")
            Button("Italic") { editor?.perform(.format(.italic)) }
                .keyboardShortcut("i")
            Button("Strikethrough") { editor?.perform(.format(.strikethrough)) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Code") { editor?.perform(.format(.code)) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Highlight") { editor?.perform(.format(.highlight)) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Link…") { linkOrSearch() }
                .keyboardShortcut("k")

            Divider()
            Button("Text") { editor?.perform(.turnInto(.paragraph)) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Heading 1") { editor?.perform(.turnInto(.heading1)) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Heading 2") { editor?.perform(.turnInto(.heading2)) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Heading 3") { editor?.perform(.turnInto(.heading3)) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("To-do List") { editor?.perform(.turnInto(.openTodo)) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Button("Bulleted List") { editor?.perform(.turnInto(.bulletItem)) }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Button("Numbered List") { editor?.perform(.turnInto(.numberedItem)) }
                .keyboardShortcut("6", modifiers: [.command, .option])
            Button("Quote") { editor?.perform(.turnInto(.quote)) }
                .keyboardShortcut("7", modifiers: [.command, .option])
            Button("Code Block") { editor?.perform(.turnInto(.codeBlock)) }
                .keyboardShortcut("8", modifiers: [.command, .option])
            Button("Callout") { editor?.perform(.turnInto(.note)) }
                .keyboardShortcut("9", modifiers: [.command, .option])
        }

        // Always enabled: menu commands are not redrawn as the size changes, and the size
        // stops at its limits by itself.
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") { app.settings.makeTextBigger() }
                .keyboardShortcut("+")
            Button("Make Text Smaller") { app.settings.makeTextSmaller() }
                .keyboardShortcut("-")
            Button("Default Text Size") { app.settings.resetTextSize() }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("Go") {
            Button("Quick Open…") { app.isPaletteVisible = true }
                .keyboardShortcut("p")
                .disabled(!hasWorkspace)
            Divider()
            Button("Back") { app.goBack() }
                .keyboardShortcut("[")
                .disabled(!app.canGoBack)
            Button("Forward") { app.goForward() }
                .keyboardShortcut("]")
                .disabled(!app.canGoForward)
            Divider()
            Button("Home") { app.show(.home) }
                .keyboardShortcut("1")
                .disabled(!hasWorkspace)
            Button("Calendar") { app.show(.calendar) }
                .keyboardShortcut("2")
                .disabled(!hasWorkspace)
            Button("Boards") { app.show(.boards) }
                .keyboardShortcut("3")
                .disabled(!hasWorkspace)
            Button("Today’s Note") { app.openDailyNote() }
                .keyboardShortcut("t")
                .disabled(!hasWorkspace)
        }
    }

    /// ⌘K links the selected text; with nothing selected it opens search, as in most writing tools.
    private func linkOrSearch() {
        if let editor, editor.view.window?.firstResponder === editor.textView, editor.textView.selectedRange().length > 0 {
            editor.perform(.link)
        } else if hasWorkspace {
            app.isPaletteVisible = true
        }
    }
}
