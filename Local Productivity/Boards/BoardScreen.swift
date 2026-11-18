//
//  BoardScreen.swift
//  LP
//
//  A board with its toolbar: where it lives, the progress panel switch, favourite, and
//  board options.
//

import SwiftUI

struct BoardScreen: View {

    let store: BoardStore
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        BoardView(store: store, showsProgress: app.showsBoardProgress)
            .navigationTitle(store.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Breadcrumb(path: store.path, icon: store.icon, symbol: "rectangle.split.3x1")
                }
                .lpWithoutSharedBackground()

                LPFlexibleToolbarSpace()

                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $app.showsBoardProgress) {
                        Label("Progress", systemImage: "chart.bar.xaxis")
                    }
                    .toggleStyle(.button)
                    .help(app.showsBoardProgress ? "Hide Progress" : "Show Progress")

                    Button {
                        store.workspace.toggleFavorite(store.path)
                    } label: {
                        Image(systemName: store.workspace.isFavorite(store.path) ? "star.fill" : "star")
                            .foregroundStyle(store.workspace.isFavorite(store.path) ? Color.yellow : Color.primary)
                    }
                    .help(store.workspace.isFavorite(store.path) ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(store.workspace.isFavorite(store.path) ? "Remove from Favorites" : "Add to Favorites")

                    BoardOptionsMenu(store: store)
                }
            }
    }
}

private struct BoardOptionsMenu: View {

    let store: BoardStore
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button("Share Progress…", systemImage: "person.2") {
                app.showsBoardProgress = true
            }
            Divider()
            Button("Open as Markdown", systemImage: "doc.plaintext") {
                app.show(.page(store.path))
            }
            Button("Reveal in Finder", systemImage: "folder") {
                store.workspace.revealInFinder(store.path)
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                app.duplicate(store.path)
            }
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                app.trash(store.path)
            }
            Divider()
            Text(summary)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Board Options")
        .accessibilityLabel("Board Options")
    }

    private var summary: String {
        let progress = store.progress
        let lists = store.board.lanes.count == 1 ? "1 list" : "\(store.board.lanes.count) lists"
        let cards = progress.total == 1 ? "1 card" : "\(progress.total) cards"
        return "\(lists) · \(cards) · \(progress.percent)% done"
    }
}
