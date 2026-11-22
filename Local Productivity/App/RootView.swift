//
//  RootView.swift
//  Local Productivity
//
//  The window's content: the welcome screen until a workspace is open, then the
//  sidebar-and-page layout for that workspace.
//

import AppKit
import SwiftUI

struct RootView: View {

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        @Bindable var app = app
        ZStack {
            if let workspace = app.workspace {
                WorkspaceView(workspace: workspace)
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .animation(.lpSmooth, value: app.workspace?.record.id)
        .frame(minWidth: 780, minHeight: 500)
        .preferredColorScheme(app.settings.appearance.colorScheme)
        .confirmationDialog("Open this link in another app?",
                            isPresented: Binding(get: { app.pendingExternalLink != nil }, set: { if !$0 { app.pendingExternalLink = nil } })) {
            Button("Open Link") { app.openPendingExternalLink() }
            Button("Cancel", role: .cancel) { app.pendingExternalLink = nil }
        } message: {
            Text("“\(app.pendingExternalLink?.absoluteString ?? "")” opens with another app on your Mac. Only open links you trust.")
        }
        .alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            if let file = app.alert?.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alert?.message ?? "")
        }
        // Widgets open LP at a page, a day or Home.
        .onOpenURL { url in app.handle(url) }
        // An update was found, or the person asked to check: show the Software Update window.
        .onChange(of: app.updater.presentRequests) { openWindow(id: "update") }
        .task {
            #if DEBUG
            if SnapshotHarness.isActive {
                SnapshotHarness.openSettings = { openSettings() }
                await SnapshotHarness.run(app)
                return
            }
            if DriveSelfTest.isRequested {
                await DriveSelfTest.run(app)
                return
            }
            #endif
            app.restoreLastWorkspace()
        }
    }
}

/// The main layout: sidebar on the left, the current destination on the right.
struct WorkspaceView: View {

    let workspace: Workspace
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 216, ideal: 256, max: 380)
        } detail: {
            destination
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.lpCanvas)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") { app.goBack() }
                            .disabled(!app.canGoBack)
                            .help("Back")
                            .accessibilityLabel("Back")
                        Button("Forward", systemImage: "chevron.right") { app.goForward() }
                            .disabled(!app.canGoForward)
                            .help("Forward")
                            .accessibilityLabel("Forward")
                    }
                }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .overlay {
            if app.isPaletteVisible {
                CommandPalette(workspace: workspace)
                    .transition(.opacity)
            }
        }
        .animation(.lpQuick, value: app.isPaletteVisible)
        .sheet(item: $app.newBoardRequest) { request in
            NewBoardSheet(request: request, workspace: workspace)
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch app.route {
        case .home:
            HomeView(workspace: workspace)
        case .calendar:
            CalendarView(workspace: workspace)
        case .boards:
            BoardsView(workspace: workspace)
        case .folder(let path):
            FolderView(workspace: workspace, path: path)
                .id(path)
        case .page:
            if let session = app.session {
                PageView(session: session)
                    .id(session.id)
            }
        case .board:
            if let store = app.boardStore {
                BoardScreen(store: store)
                    .id(ObjectIdentifier(store))
            }
        }
    }
}
