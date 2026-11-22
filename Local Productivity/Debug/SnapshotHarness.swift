//
//  SnapshotHarness.swift
//  Local Productivity
//
//  Debug-only tooling that drives the app through a scripted scenario and renders the
//  window to PNG files, so the interface can be reviewed (and regressions spotted)
//  without Screen Recording permission. It is never compiled into Release builds.
//  See Scripts/snapshot.sh.
//
//  Environment variables:
//    LP_SNAPSHOT_DIR       Directory to write PNG files into. Setting it enables the harness.
//    LP_WORKSPACE          Folder to open as the workspace.
//    LP_SNAPSHOT_SCENARIO  Steps separated by " ;; ", for example
//                          "open:Welcome.md ;; type:Hello ;; shot:typed". See `perform`.
//    LP_SNAPSHOT_SIZE      Window size in points, e.g. "1280x800".
//    LP_SNAPSHOT_SCREEN    "retina" places the window on the highest-density screen.
//    LP_SNAPSHOT_ACTIVATE  "1" brings the app to the front so the active appearance is captured.
//    LP_APPEARANCE         "light" or "dark".
//

#if DEBUG
import AppKit

extension Notification.Name {
    /// Drives the open card sheet from the `card-sheet:` step.
    static let lpHarnessCardSheet = Notification.Name("LPHarnessCardSheet")
}

enum SnapshotHarness {

    private static let environment = ProcessInfo.processInfo.environment

    static var outputDirectory: URL? {
        guard let path = environment["LP_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var isActive: Bool { outputDirectory != nil }

    /// Set by the root view, which is where SwiftUI hands out the action that opens Settings.
    static var openSettings: (() -> Void)?
    /// A reminder kept by `reminder-keep:`, as if its notification had already been delivered.
    private static var keptReminder: PlannedReminder?
    /// A Share Progress started by `share-start`, for `share-wait`.
    @MainActor private static var sharing: Task<Void, Never>?

    private static var requestedSize: NSSize {
        let parts = (environment["LP_SNAPSHOT_SIZE"] ?? "1280x800").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return NSSize(width: 1280, height: 800) }
        return NSSize(width: parts[0], height: parts[1])
    }

    // MARK: Running a scenario

    static func run(_ app: AppModel) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) ?? NSApp.windows.first else {
            NSApp.terminate(nil)
            return
        }
        setAppearance(environment["LP_APPEARANCE"] ?? "", app: app)
        prepare(window)

        if let path = environment["LP_WORKSPACE"], !path.isEmpty {
            let start = ProcessInfo.processInfo.systemUptime
            app.openWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
            // Wait for the first scan and the index (up to a minute for very large workspaces).
            for _ in 0..<6000 {
                try? await Task.sleep(for: .milliseconds(10))
                guard let workspace = app.workspace, workspace.hasLoaded else { continue }
                if loadTimings.scan == nil { loadTimings.scan = ProcessInfo.processInfo.systemUptime - start }
                if workspace.pages.isEmpty || workspace.meta.count >= workspace.pages.count {
                    loadTimings.index = ProcessInfo.processInfo.systemUptime - start
                    break
                }
            }
        }
        await settle()

        let scenario = environment["LP_SNAPSHOT_SCENARIO"] ?? "shot:window"
        for step in scenario.components(separatedBy: ";;") {
            await perform(step.trimmingCharacters(in: .whitespacesAndNewlines), app: app, window: window)
        }
        // An open sheet holds up quitting, so close everything first, and make sure the run
        // ends even if something still refuses.
        app.eventEditor = nil
        app.boardStore?.openedCard = nil
        app.isPaletteVisible = false
        app.session?.tableEdit = nil
        await settle(300)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        NSApp.terminate(nil)
    }

    @MainActor private static var loadTimings: (scan: Double?, index: Double?) = (nil, nil)

    private static func milliseconds(since start: Double) -> String {
        String(format: "%.0f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// Waits until `condition` holds, checking every few milliseconds, for up to `limit` seconds.
    private static func wait(upTo limit: Double = 20, until condition: () -> Bool) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    /// The app's memory footprint, as Activity Monitor reports it.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Undo groups close when an event finishes, as they would after a real click or key press.
    /// Scripted steps produce no events, so one is posted to end the step's group.
    private static func endEvent(in window: NSWindow) async {
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        await settle(250)
    }

    private static func settle(_ milliseconds: Int = 450) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private static func setAppearance(_ name: String, app: AppModel) {
        switch name {
        case "dark": app.settings.appearance = .dark
        case "light": app.settings.appearance = .light
        default: break
        }
    }

    /// Runs one step of a scenario. Steps are written `name:argument`.
    private static func perform(_ step: String, app: AppModel, window: NSWindow) async {
        guard !step.isEmpty else { return }
        let parts = step.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let editor = app.session?.controller
        let textView = editor?.textView

        switch name {
        case "shot":
            await settle()
            write(argument.isEmpty ? "window" : argument, window: window)
        case "shot1x":
            // Renders the view hierarchy at 1x to judge how text and hairlines hold up on a
            // non-Retina display. Materials (the sidebar) are not drawn by this path.
            await settle()
            writeViewHierarchy(argument.isEmpty ? "window-1x" : argument, window: window)
        case "wait":
            await settle(Int(argument) ?? 300)
        case "open":
            app.openPage(argument)
            await settle()
        case "new":
            app.newPage(in: argument)
            await settle()
        case "title":
            guard let session = app.session else { return }
            session.title = argument
            app.rename(session.path, to: argument)
            await settle(200)
        case "toggle":
            // Ticks the to-do whose text contains the argument.
            guard let textView else { return }
            let range = (textView.storage.string as NSString).range(of: argument)
            if range.location != NSNotFound { textView.toggleTodo(at: range.location) }
        case "back":
            app.goBack()
            await settle(400)
        case "forward":
            app.goForward()
            await settle(400)
        case "toggle-task":
            // Ticks a task off the way Home does: from what the index knows about it.
            guard let workspace = app.workspace,
                  let task = workspace.meta.values.flatMap(\.tasks).first(where: { $0.text == argument }) else {
                print("toggle-task: no task"); return
            }
            app.toggleTask(task, in: workspace)
            await settle(300)
        case "write":
            // Changes a file behind the app's back, the way another editor or a sync service would.
            guard let workspace = app.workspace, let split = argument.firstIndex(of: "=") else { return }
            let path = String(argument[..<split])
            let text = argument[argument.index(after: split)...].replacingOccurrences(of: "\\n", with: "\n")
            let url = workspace.url(for: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url, options: .atomic)
        case "remove":
            guard let workspace = app.workspace else { return }
            try? FileManager.default.removeItem(at: workspace.url(for: argument))
        case "state":
            print("route=\(app.route) board=\(app.boardStore?.path ?? "nil") session=\(app.session?.path ?? "nil") pages=\(app.workspace?.pages.count ?? 0) status=\(String(describing: app.session?.status))")
            if let store = app.boardStore {
                print("share=\(store.share == nil ? "none" : store.shareIsTrusted ? "trusted" : "set up elsewhere") boardID=\(store.log.boardID)")
                if store.openedCard != nil || store.saveError != nil {
                    print("card-sheet=\(store.openedCard == nil ? "closed" : "open") saveError=\(store.saveError ?? "-")")
                }
                if let problem = store.shareError { print("shareError=\(problem)") }
                if let page = store.shareErrorPage { print("shareErrorPage=\(page.absoluteString)") }
            }
            if let alert = app.alert {
                print("alert=\(alert.title) | \(alert.message) | file=\(alert.file?.lastPathComponent ?? "-")")
            }
        case "cat":
            // Prints the file of the open page or board as it is on disk.
            guard let workspace = app.workspace, let path = app.session?.path ?? app.boardStore?.path else { return }
            print("--- file \(path) ---")
            print((try? String(contentsOf: workspace.url(for: path), encoding: .utf8)) ?? "<unreadable>", terminator: "")
            print("--- end ---")
        case "link":
            // Follows a link as if clicked in the open page, printing what would happen.
            app.linkHook = { action, url in print("link → \(action) \(url.isFileURL ? url.lastPathComponent : url.absoluteString)") }
            app.openLink(argument, from: app.session?.path ?? "")
            if let pending = app.pendingExternalLink { print("link → confirm \(pending.absoluteString)") }
            app.pendingExternalLink = nil
            await settle(200)
        case "wiki":
            app.openWikiLink(argument, from: app.session?.path ?? "")
            await settle(400)
        case "perf-load":
            let pages = app.workspace?.pages.count ?? 0
            print(String(format: "perf load: %d pages · listed in %.0f ms · indexed in %.0f ms",
                         pages, (loadTimings.scan ?? -1) * 1000, (loadTimings.index ?? -1) * 1000))
        case "perf-open":
            let start = ProcessInfo.processInfo.systemUptime
            app.openPage(argument)
            let loaded = await wait { (app.session?.controller?.textView.storage.length ?? 0) > 1 || app.boardStore?.path == argument }
            if let textView = app.session?.controller?.textView {
                textView.layoutManager?.ensureLayout(forBoundingRect: textView.visibleRect, in: textView.textContainer!)
            }
            print("perf open \(argument): \(loaded ? milliseconds(since: start) : "timed out")")
        case "perf-type":
            // Types characters at the end of the first paragraph and reports the time per character.
            guard let textView = app.session?.controller?.textView else { return }
            let count = Int(argument) ?? 50
            let end = (textView.storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            textView.setSelectedRange(NSRange(location: max(0, NSMaxRange(end) - 1), length: 0))
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<count {
                textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                textView.displayIfNeeded()
            }
            let total = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print(String(format: "perf type: %d characters in %.0f ms (%.2f ms each)", count, total, total / Double(count)))
        case "perf-search":
            guard let workspace = app.workspace else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let hits = await workspace.search(argument)
            print("perf search “\(argument)”: \(hits.count) results in \(milliseconds(since: start))")
        case "perf-save":
            guard let session = app.session else { return }
            let start = ProcessInfo.processInfo.systemUptime
            session.flush()
            print("perf save \(session.path): \(milliseconds(since: start))")
        case "perf-phases":
            // Times the parts of a save on the open page.
            guard let controller = app.session?.controller else { return }
            var start = ProcessInfo.processInfo.systemUptime
            let blocks = controller.currentBlocks()
            print("perf phase blocks from editor: \(milliseconds(since: start)) (\(blocks.count) blocks)")
            start = ProcessInfo.processInfo.systemUptime
            let cache = SerializerCache()
            let text = MarkdownSerializer.serialize(MarkdownDocument(blocks: blocks), cache: cache)
            print("perf phase serialize, cold: \(milliseconds(since: start))")
            start = ProcessInfo.processInfo.systemUptime
            _ = MarkdownSerializer.serialize(MarkdownDocument(blocks: blocks), cache: cache)
            print("perf phase serialize, warm: \(milliseconds(since: start))")
            start = ProcessInfo.processInfo.systemUptime
            _ = text.data(using: .utf8)
            print("perf phase encode: \(milliseconds(since: start))")
        case "perf-runs-match":
            // Whether the editor's blocks carry exactly the runs the parser produced for the file.
            guard let session = app.session, let controller = session.controller,
                  let data = try? Data(contentsOf: session.url) else { return }
            let parsed = MarkdownParser.parse(String(decoding: data, as: UTF8.self)).blocks
            let edited = controller.currentBlocks()
            let same = parsed.count == edited.count && zip(parsed, edited).allSatisfy { $0.runs == $1.runs && $0.kind == $1.kind }
            let firstDifference = Array(zip(parsed, edited)).firstIndex { $0.runs != $1.runs }
            print("perf runs match: \(same) (\(parsed.count) vs \(edited.count) blocks\(firstDifference.map { ", first difference at \($0)" } ?? ""))")
        case "perf-memory":
            print(String(format: "perf memory: %.0f MB", footprintMB()))
        case "new-board":
            // Opens the new board sheet; create-board:<name>|<template>|<folder> makes one directly.
            app.newBoard(in: argument)
            await settle()
        case "create-board":
            let parts = argument.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let template = parts.count > 1 ? BoardTemplate(rawValue: parts[1]) ?? .simple : .simple
            app.createBoard(named: parts[0], template: template, in: parts.count > 2 ? parts[2] : "")
            await settle(800)
        case "board-progress":
            app.showsBoardProgress = argument != "off"
            await settle(400)
        case "board-add":
            // "List=Card text"
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard let store = app.boardStore, parts.count == 2,
                  let lane = store.board.lanes.first(where: { $0.title == parts[0] }) else { print("board-add: no list"); return }
            store.addCard(parts[1], toLane: lane.id, undoManager: window.undoManager)
            await endEvent(in: window)
        case "board-move":
            // "Card title=List[@Before card title]"
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard let store = app.boardStore, parts.count == 2,
                  let card = store.board.allCards.first(where: { $0.title == parts[0] }) else { print("board-move: no card"); return }
            let target = parts[1].split(separator: "@", maxSplits: 1).map(String.init)
            guard let lane = store.board.lanes.first(where: { $0.title == target[0] }) else { print("board-move: no list"); return }
            let before = target.count > 1 ? store.board.allCards.first(where: { $0.title == target[1] })?.id : nil
            store.move([card.id], toLane: lane.id, before: before, undoManager: window.undoManager)
            await endEvent(in: window)
        case "board-card":
            guard let store = app.boardStore, let card = store.board.allCards.first(where: { $0.title == argument }) else {
                print("board-card: no card"); return
            }
            store.openedCard = BoardStore.OpenedCard(id: card.id)
            await settle(600)
        case "card-sheet":
            // In the open card sheet: "notes=<text>" types the notes and presses Done; "done" presses
            // Done; "delete" picks Delete — through the sheet itself, so its checks run as they do
            // for a person. Anything else is ignored.
            guard argument.hasPrefix("notes=") || argument == "done" || argument == "delete" else {
                print("card-sheet: notes=<text> | done | delete"); return
            }
            let request = argument.hasPrefix("notes=")
                ? ["action": "notes", "text": String(argument.dropFirst(6)).replacingOccurrences(of: "\\n", with: "\n")]
                : ["action": argument]
            NotificationCenter.default.post(name: .lpHarnessCardSheet, object: request)
            await settle(600)
        case "board-close-card":
            app.boardStore?.openedCard = nil
            await settle(300)
        case "mouse-drag":
            // "x1,y1>x2,y2" in window points from the top left; "…!name" also captures the window as
            // "name" just before the mouse is released. Mouse events go through the app's own queue,
            // which needs no permission but cannot move the real pointer.
            let parts = argument.split(separator: "!", maxSplits: 1).map(String.init)
            let ends = parts[0].split(separator: ">").map { $0.split(separator: ",").compactMap { Double($0) } }
            guard ends.count == 2, ends[0].count == 2, ends[1].count == 2, let content = window.contentView else { return }
            func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: content.bounds.height - y) }
            func post(_ type: NSEvent.EventType, _ location: NSPoint) {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            let start = point(ends[0][0], ends[0][1])
            let end = point(ends[1][0], ends[1][1])
            post(.leftMouseDown, start)
            try? await Task.sleep(for: .milliseconds(120))
            for step in 1...24 {
                let t = Double(step) / 24
                post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(200))
            if parts.count > 1 { write(parts[1], window: window) }
            post(.leftMouseUp, end)
            await settle(600)
        case "scroll-at":
            // "x,y=dy": scrolls the scroll view under that point (window points from the top left) down
            // by dy points — for SwiftUI scroll views the editor's `scroll:` doesn't reach.
            let parts = argument.split(separator: "=").map(String.init)
            let xy = parts.first?.split(separator: ",").compactMap { Double($0) } ?? []
            guard parts.count == 2, xy.count == 2, let dy = Double(parts[1]), let content = window.contentView else { return }
            var view = content.hitTest(NSPoint(x: xy[0], y: content.bounds.height - xy[1]))
            while let candidate = view, !(candidate is NSScrollView) { view = candidate.superview }
            guard let scrollView = view as? NSScrollView else { print("scroll-at: no scroll view"); return }
            let clip = scrollView.contentView
            let limit = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let target = clip.isFlipped ? clip.bounds.origin.y + dy : clip.bounds.origin.y - dy
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, target), limit)))
            scrollView.reflectScrolledClipView(clip)
            await settle(400)
        case "rename":
            // "path=New title", the way renaming in the sidebar does it.
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            app.rename(parts[0], to: parts[1])
            await settle(600)
        case "open-markdown":
            // What a board's "Open as Markdown" does: the file in the page editor.
            app.show(.page(argument))
            await settle(900)
        case "ready-to-quit":
            // What quitting asks first, without quitting: prints whether LP may go and what it says.
            let (ready, notice) = app.readyToQuit()
            print("ready-to-quit=\(ready) notice=\(notice.map { "\($0.title) | \($0.file?.lastPathComponent ?? "-")" } ?? "-")")
        case "reminder-keep":
            // Keeps a planned reminder as it is now, like a notification already on screen.
            app.updateReminders()
            keptReminder = app.reminders.plan.first { $0.title == argument }
            print(keptReminder == nil ? "reminder-keep: nothing planned called “\(argument)”" : "reminder-keep: \(argument)")
        case "reminder-kept":
            // Acts on the reminder kept by reminder-keep: — what tapping an old notification does.
            let actions: [String: ReminderResponse.Action] = ["open": .open, "done": .complete, "hour": .snoozeHour, "tomorrow": .snoozeTomorrow]
            guard let planned = keptReminder, let action = actions[argument] else { print("reminder-kept: nothing kept"); return }
            app.handleReminder(ReminderResponse(action: action, kind: planned.kind, title: planned.title,
                                                subtitle: planned.subtitle, body: planned.body, info: planned.info))
            await settle(1500)
        case "move-race":
            // "path=text": the next move appends text to that file between its checks and its writes,
            // as another app (Obsidian, sync) could.
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let workspace = app.workspace else { return }
            let target = workspace.url(for: parts[0])
            let addition = parts[1].replacingOccurrences(of: "\\n", with: "\n")
            Workspace.betweenMoveChecksAndWrites = {
                Workspace.betweenMoveChecksAndWrites = nil
                if let handle = try? FileHandle(forWritingTo: target) {
                    handle.seekToEndOfFile()
                    handle.write(Data(addition.utf8))
                    try? handle.close()
                }
            }
        case "calendar-state":
            // Each account's sync state, and how often the demo calendar was asked for events.
            for account in app.calendarSync.accounts {
                print("account \(account.name): \(app.calendarSync.state(of: account)) · demo fetches: \(DemoCalendarProvider.fetches)")
            }
        case "calendar-sync":
            // What the calendar's Sync button does.
            app.calendarSync.syncNow()
            await settle(300)
        case "move-file":
            // "path=folder" moves a page, board or folder into a folder, the way dragging in the sidebar does.
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            do {
                print("move-file → \(try app.workspace?.move(parts[0], into: parts[1]) ?? "nil")")
            } catch {
                print("move-file failed: \(error.localizedDescription)")
            }
            await settle(600)
        case "duplicate-file":
            // Duplicates a page, board or folder the way the sidebar's Duplicate does.
            do {
                let copy = try app.workspace?.duplicate(argument)
                print("duplicate-file → \(copy ?? "nil")")
            } catch {
                print("duplicate-file failed: \(error.localizedDescription)")
            }
            await settle(600)
        case "share-trust":
            // What "Keep It Updated From Here" does, without needing a GitHub token.
            app.boardStore?.trustShare()
            await settle(400)
        case "share-forget":
            app.boardStore?.forgetShare()
            await settle(400)
        case "demo-drive":
            // "demo-drive" lets LP use the demo account's Drive (kept in memory); options, comma-
            // separated: "fail-deletes=<n>" (the next n deletions fail, as if offline),
            // "fail-publishes=<n>" (letting the next n pages be seen fails with "slow down"),
            // "slow=<seconds>" (uploads and updates take that long).
            DemoDriveBackend.isOn = true
            for option in argument.split(separator: ",") {
                let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, let value = Double(pair[1]) else { continue }
                switch pair[0] {
                case "fail-deletes": DemoDriveBackend.shared.failingDeletes = Int(value)
                case "fail-publishes": DemoDriveBackend.shared.failingPublishes = Int(value)
                case "slow": DemoDriveBackend.shared.delay = value
                default: print("demo-drive: unknown option \(pair[0])")
                }
            }
            await settle(200)
        case "share-to":
            // What the panel's Share Progress does: "share-to:gist" or "share-to:drive" (the demo account's Drive).
            await app.boardStore?.publish(to: argument == "drive" ? .googleDrive(account: DemoCalendarProvider.accountID) : .gist)
            await settle(300)
        case "share-start":
            // Share Progress without waiting for it ("share-wait" waits), to do something meanwhile.
            let store = app.boardStore
            let destination: ShareDestination = argument == "drive" ? .googleDrive(account: DemoCalendarProvider.accountID) : .gist
            sharing = Task { await store?.publish(to: destination) }
            await settle(100)
        case "share-update-start":
            // Update Now without waiting for it ("share-wait" waits).
            let store = app.boardStore
            sharing = Task { await store?.updateSharedPage() }
            await settle(100)
        case "share-wait":
            await sharing?.value
            sharing = nil
            await settle(300)
        case "share-elsewhere":
            // As if the board's page had been set up on another Mac: this Mac has neither the
            // permission for it nor the page on its list.
            guard let store = app.boardStore, let share = store.log.share else { print("share-elsewhere: not shared"); return }
            store.workspace.revokeShare(path: store.path, board: store.log.boardID, page: share.grantKey)
            SharingServices.unlist(share)
            await settle(300)
        case "drive-pages":
            // The demo Drive's pages (private ones marked), and how many LP keeps track of for the demo account.
            print("drive pages=\(DemoDriveBackend.shared.pages.count) tracked=\(SharingServices.drivePageCount(of: DemoCalendarProvider.accountID)) "
                  + DemoDriveBackend.shared.pages.values.map { $0.name + ($0.isPublic ? "" : " (private)") }.sorted().joined(separator: " | "))
            // "drive-pages:<text>": whether each page's content has that text (did an update reach it?).
            if !argument.isEmpty {
                print("drive pages containing \"\(argument)\": \(DemoDriveBackend.shared.pages.values.filter { $0.html.contains(argument) }.count)")
            }
        case "calendar-disconnect":
            // What Settings → Calendars → Disconnect does for the demo account: its Drive pages are
            // deleted first (after any still being made); "calendar-disconnect:anyway" is
            // "Disconnect Anyway", when some couldn't be.
            guard let account = app.calendarSync.accounts.first(where: { $0.id == DemoCalendarProvider.accountID }) else { print("no demo account"); return }
            let left = await SharingServices.disconnect(account, anyway: argument == "anyway")
            print("pages left=\(left)")
            if !app.calendarSync.accounts.contains(where: { $0.id == account.id }) { print("disconnected") }
            await settle(300)
        case "share-update":
            // What "Update Now" does. Harness runs have no GitHub token, so a request LP decides to
            // send stops at "Add a GitHub token" (shown by `state` as shareError).
            await app.boardStore?.updateSharedPage()
            await settle(200)
        case "share-stop":
            // What "Stop Sharing" does (same: no request can reach GitHub from the harness).
            await app.boardStore?.stopSharing()
            await settle(200)
        case "board-undo":
            window.undoManager?.undo()
            await endEvent(in: window)
        case "board-log":
            guard let store = app.boardStore else { return }
            let progress = store.progress
            print("--- board \(store.path): \(progress.done)/\(progress.total) done, \(progress.overdue) overdue, lists \(store.board.lanes.map { "\($0.title):\($0.cards.count)" }.joined(separator: " ")) ---")
            for event in store.log.events.suffix(Int(argument) ?? 6) { print("  \(event.sentence)") }
            print("  snapshots=\(store.log.snapshots.count)")
        case "route":
            if argument == "home" { app.show(.home) }
            if argument == "calendar" { app.show(.calendar) }
            if argument == "boards" { app.show(.boards) }
            if argument.hasPrefix("folder=") { app.show(.folder(String(argument.dropFirst(7)))) }
            await settle()
        case "expand":
            app.workspace?.expanded.insert(argument)
        case "favorite":
            app.workspace?.toggleFavorite(argument)
        case "rename-row":
            app.workspace?.expand(to: argument)
            app.renamingPath = argument
            await settle(200)
        case "edit-table":
            // Opens the editor for the first table on the page.
            guard let editor, let textView else { return }
            var found: Int? = nil
            textView.storage.enumerateParagraphs(in: NSRange(location: 0, length: textView.storage.length)) { paragraph in
                if found == nil, case .table = textView.storage.block(at: paragraph.location).kind { found = paragraph.location }
            }
            if let found { editor.editorDidActivateTable(inParagraphAt: found) }
            await settle(500)
        case "find-bar":
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView?.performFindPanelAction(item)
            await settle(300)
        case "reminders":
            // Prints what LP would keep waiting with the system (snapshots never schedule).
            app.updateReminders()
            let stamp = ISO8601DateFormatter()
            stamp.timeZone = .current
            stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
            for reminder in app.reminders.plan {
                print("reminder \(reminder.kind.rawValue) \(stamp.string(from: reminder.date)) | \(reminder.title) | \(reminder.subtitle) | \(reminder.body.replacingOccurrences(of: "\n", with: " / "))")
            }
            print("reminders: \(app.reminders.plan.count) planned")
        case "reminder":
            // reminder:<open|done|hour|tomorrow>=<title> acts on a planned reminder as if tapped.
            let pieces = argument.split(separator: "=", maxSplits: 1).map(String.init)
            app.updateReminders()
            guard pieces.count == 2, let planned = app.reminders.plan.first(where: { $0.title == pieces[1] }) else {
                print("reminder: nothing planned called “\(pieces.last ?? "")”")
                return
            }
            let actions: [String: ReminderResponse.Action] = ["open": .open, "done": .complete, "hour": .snoozeHour, "tomorrow": .snoozeTomorrow]
            guard let action = actions[pieces[0]] else { print("reminder: unknown action \(pieces[0])"); return }
            app.handleReminder(ReminderResponse(action: action, kind: planned.kind, title: planned.title,
                                                subtitle: planned.subtitle, body: planned.body, info: planned.info))
            await settle(1500)
            print("reminder \(pieces[0]): \(planned.title) → \(app.route)")
        case "url":
            // url:<link> opens a localproductivity:// link, as a widget would.
            if let url = URL(string: argument) { app.handle(url) }
            await settle(1200)
            print("url \(argument) → \(app.route)")
        case "reminder-permission":
            let states: [String: ReminderCenter.Permission] = ["allowed": .allowed, "denied": .denied, "ask": .notAsked]
            if let state = states[argument] { app.reminders.showPermissionForSnapshots(state) }
        case "settings":
            if let tab = SettingsView.Tab(rawValue: argument) { SettingsView.select(tab) }
            openSettings?()
            await settle(900)
        case "update-demo":
            // The Software Update window in a state: available (default), checking, uptodate,
            // downloading, installed, failed — then shot-other captures it.
            app.updater.showDemo(argument)
            await settle(900)
        case "shot-other":
            // Captures the sheet attached to the main window, or else another visible window (Settings).
            await settle()
            let other = window.attachedSheet ?? NSApp.windows.first { $0 !== window && $0.isVisible && $0.frame.width > 200 }
            if let other { write(argument.isEmpty ? "other" : argument, window: other) } else { print("shot-other: no other window") }
        case "scroll-other":
            // Scrolls the other window (Settings) down by that many points, to capture what's below.
            let other = NSApp.windows.first { $0 !== window && $0.isVisible && $0.frame.width > 200 }
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
            }
            guard let content = other?.contentView, let dy = Double(argument),
                  let scrollView = scrollViews(in: content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
            else { print("scroll-other: nothing to scroll"); return }
            let clip = scrollView.contentView
            let limit = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let target = clip.isFlipped ? clip.bounds.origin.y + dy : clip.bounds.origin.y - dy
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, target), limit)))
            scrollView.reflectScrolledClipView(clip)
            await settle(400)
        case "palette":
            app.paletteSeed = argument
            app.isPaletteVisible = true
            await settle()
        case "close-palette":
            app.isPaletteVisible = false
        case "appearance":
            setAppearance(argument, app: app)
            await settle()
        case "setting":
            // setting:size=17, setting:spacing=relaxed, setting:width=wide, setting:font=serif
            // (or a family name), setting:interface=small.
            let pair = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let value = pair.count == 2 ? pair[1] : ""
            switch pair[0] {
            case "size": if let size = Double(value) { app.settings.editorTextSize = CGFloat(size) }
            case "spacing": if let spacing = AppSettings.LineSpacing(rawValue: value) { app.settings.lineSpacing = spacing }
            case "width": if let width = AppSettings.PageWidth(rawValue: value) { app.settings.pageWidth = width }
            case "interface": if let size = AppSettings.InterfaceSize(rawValue: value) { app.settings.interfaceSize = size }
            case "font":
                if let font = AppSettings.EditorFont(rawValue: value) {
                    app.settings.editorFont = font
                } else {
                    app.settings.editorFontFamily = value
                    app.settings.editorFont = .custom
                }
            default: print("unknown setting \(argument)")
            }
            await settle(250)
        case "focus":
            if argument == "title" { app.session?.focusRequest = .title } else { editor?.focusBody() }
            await settle(150)
        case "caret":
            guard let textView else { return }
            let location = argument == "end" ? textView.storage.length - 1 : (Int(argument) ?? 0)
            textView.setSelectedRange(NSRange(location: max(0, location), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        case "find":
            // Puts the caret at the end of the first occurrence of some text.
            guard let textView else { return }
            let range = (textView.storage.string as NSString).range(of: argument)
            if range.location != NSNotFound {
                textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
                textView.scrollRangeToVisible(range)
            } else {
                print("find: not found: \(argument)")
            }
        case "select":
            // Selects the first occurrence of some text.
            guard let textView else { return }
            let range = (textView.storage.string as NSString).range(of: argument)
            if range.location != NSNotFound {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            } else {
                print("select: not found: \(argument)")
            }
        case "keys":
            // Real key events through the application's event queue. Needs LP_SNAPSHOT_ACTIVATE=1, and is
            // the only way to exercise per-keystroke undo grouping.
            let text = argument.replacingOccurrences(of: "\\n", with: "\r").replacingOccurrences(of: "\\t", with: "\t")
            for character in text {
                let code: UInt16 = character == "\r" ? 36 : (character == "\t" ? 48 : 0)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: String(character),
                                                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        case "shortcut":
            // shortcut:cmd =, shortcut:cmd shift =, shortcut:cmd -, shortcut:cmd 0 — a real key event
            // with modifiers, which the menu bar handles. Needs LP_SNAPSHOT_ACTIVATE=1. As with a real
            // keyboard, Shift changes the characters even when other modifiers are ignored.
            let words = argument.split(separator: " ").map(String.init)
            guard let keyName = words.last else { return }
            let keys: [String: (code: UInt16, plain: String, shifted: String)] = [
                "=": (24, "=", "+"), "-": (27, "-", "_"), "0": (29, "0", ")"), "k": (40, "k", "K"), "p": (35, "p", "P")
            ]
            guard let key = keys[keyName] else { print("shortcut: unknown key \(keyName)"); return }
            var flags: NSEvent.ModifierFlags = []
            if words.contains("cmd") { flags.insert(.command) }
            if words.contains("shift") { flags.insert(.shift) }
            if words.contains("option") { flags.insert(.option) }
            let characters = flags.contains(.shift) ? key.shifted : key.plain
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key.code) {
                NSApp.postEvent(event, atStart: false)
            }
            await settle(300)
        case "text-size":
            print("text size \(Int(app.settings.editorTextSize)) pt")
        case "type":
            guard let textView else { return }
            let text = argument.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            for character in text {
                if character == "\n" {
                    key("return", editor: editor)
                } else if character == "\t" {
                    key("tab", editor: editor)
                } else {
                    textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
        case "key":
            key(argument, editor: editor)
        case "format":
            let formats: [String: EditorTextView.InlineFormat] = [
                "bold": .bold, "italic": .italic, "strike": .strikethrough, "code": .code, "highlight": .highlight
            ]
            if let format = formats[argument] { editor?.perform(.format(format)) }
        case "turn":
            let kinds: [String: BlockKind] = [
                "text": .paragraph, "h1": .heading1, "h2": .heading2, "h3": .heading3, "todo": .openTodo,
                "bullet": .bulletItem, "number": .numberedItem, "quote": .quote, "code": .codeBlock, "callout": .note
            ]
            if let kind = kinds[argument] { editor?.perform(.turnInto(kind)) }
        case "scroll":
            guard let editor else { return }
            let clip = editor.scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(Double(argument) ?? 0)))
            editor.scrollView.reflectScrolledClipView(clip)
        case "undo":
            if argument == "debug", let manager = textView?.undoManager {
                print("undo manager: level=\(manager.groupingLevel) canUndo=\(manager.canUndo) byEvent=\(manager.groupsByEvent) name=\(manager.undoActionName)")
            }
            textView?.undoManager?.undo()
            await settle(30)
        case "redo":
            textView?.undoManager?.redo()
            await settle(30)
        case "copy-paste":
            // Copies the selection and pastes it at the end, exercising the Markdown clipboard path.
            guard let textView else { return }
            let markdown = DocumentConverter.markdown(for: textView.storage, in: textView.selectedRange())
            textView.setSelectedRange(NSRange(location: textView.storage.length - 1, length: 0))
            textView.insertMarkdown(markdown)
        case "paste":
            textView?.insertMarkdown(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "demo-calendar":
            // Connects an in-memory calendar account with sample events.
            app.calendarSync.add(DemoCalendarProvider())
            await app.calendarSync.refresh()
            await settle(200)
        case "select-day":
            app.calendarSelection = Day.today.adding(days: Int(argument) ?? 0)
            app.calendarMonth = app.calendarSelection.startOfMonth
            await settle(200)
        case "event-editor":
            if argument == "new" {
                app.eventEditor = EventEditorRequest(mode: .new(app.calendarSelection))
            } else if let event = app.calendarSync.events.first(where: { $0.title == argument }) {
                app.eventEditor = EventEditorRequest(mode: .edit(event))
            } else {
                print("event-editor: no event titled \(argument)")
            }
            await settle(600)
        case "close-editor":
            app.eventEditor = nil
            await settle(300)
        case "event-create":
            // "Title@dayOffset@hour" in the default calendar.
            let parts = argument.split(separator: "@").map(String.init)
            guard parts.count == 3, let offset = Int(parts[1]), let hour = Int(parts[2]),
                  let calendar = app.calendarSync.defaultCalendar else { print("event-create: bad argument"); return }
            let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Day.today.adding(days: offset).date())!
            do {
                try await app.calendarSync.create(EventDraft(title: parts[0], start: start, end: start.addingTimeInterval(3600), isAllDay: false), in: calendar)
            } catch {
                print("event-create failed: \(error.localizedDescription)")
            }
            await app.calendarSync.refresh()
        case "event-update":
            // "Old title=New title" moves the event one day later too; "Series title=New title=all" changes the series.
            let parts = argument.split(separator: "=").map(String.init)
            guard parts.count >= 2, let event = app.calendarSync.events.first(where: { $0.title == parts[0] }) else {
                print("event-update: no event"); return
            }
            var draft = EventDraft(event)
            draft.title = parts[1]
            if parts.count < 3 { draft = draft.moved(to: event.start.addingTimeInterval(86_400)) }
            do {
                try await app.calendarSync.update(event, with: draft, span: parts.count >= 3 ? .allEvents : .thisEvent)
            } catch {
                print("event-update failed: \(error.localizedDescription)")
            }
            await app.calendarSync.refresh()
        case "event-delete":
            // "Title" deletes one occurrence; "Title=all" deletes the series.
            let parts = argument.split(separator: "=").map(String.init)
            guard let event = app.calendarSync.events.first(where: { $0.title == parts[0] }) else { print("event-delete: no event"); return }
            do {
                try await app.calendarSync.delete(event, span: parts.count > 1 ? .allEvents : .thisEvent)
            } catch {
                print("event-delete failed: \(error.localizedDescription)")
            }
            await app.calendarSync.refresh()
        case "events":
            // Prints events whose title contains the argument (all events when empty).
            let matching = app.calendarSync.events
                .filter { argument.isEmpty || $0.title.contains(argument) }
                .sorted { $0.start < $1.start }
            print("--- events (\(matching.count)) ---")
            for event in matching.prefix(12) {
                let day = Day(event.start).iso
                let time = event.isAllDay ? "all-day" : event.start.formatted(date: .omitted, time: .shortened)
                print("  \(day) \(time)  \(event.title)  [\(app.calendarSync.calendar(withID: event.calendarID)?.title ?? "?")]")
            }
        case "drop":
            // Drops a file (absolute path) at the caret through the pasteboard path.
            guard let textView else { return }
            let board = NSPasteboard(name: NSPasteboard.Name("LPHarness"))
            board.clearContents()
            board.writeObjects([URL(fileURLWithPath: argument) as NSURL])
            _ = textView.readSelection(from: board, type: .fileURL)
        case "paste-image":
            // Pastes PNG data read from a file, as if a screenshot were on the clipboard.
            guard let textView, let data = try? Data(contentsOf: URL(fileURLWithPath: argument)) else { return }
            let board = NSPasteboard(name: NSPasteboard.Name("LPHarness"))
            board.clearContents()
            board.setData(data, forType: .png)
            _ = textView.readSelection(from: board, type: .png)
        case "hover":
            // Moves the pointer (as far as the editor knows) over the block containing some text.
            guard let editor, let textView else { return }
            let range = (textView.storage.string as NSString).range(of: argument)
            if range.location != NSNotFound {
                let rect = textView.rect(forCharacterAt: range.location)
                editor.editorMouseMoved(to: NSPoint(x: rect.minX + 20, y: rect.midY))
            }
        case "block":
            // duplicate / up / down / delete / add, applied to the block containing the caret.
            guard let textView else { return }
            let location = textView.selectedRange().location
            switch argument {
            case "duplicate": textView.duplicateBlock(at: location)
            case "up": textView.moveBlock(at: location, up: true)
            case "down": textView.moveBlock(at: location, up: false)
            case "delete": textView.deleteBlock(at: location)
            case "add": textView.addBlock(below: location)
            default: print("unknown block action \(argument)")
            }
        case "layout":
            // Prints where every block sits, to check vertical rhythm numerically.
            guard let textView else { return }
            let manager = textView.editorLayoutManager
            var previousBottom: CGFloat? = nil
            textView.storage.enumerateParagraphs(in: NSRange(location: 0, length: textView.storage.length)) { paragraph in
                guard let frame = manager.frame(ofParagraph: paragraph) else { return }
                let block = textView.storage.block(at: paragraph.location)
                let box = manager.boxRect(for: block, frame: frame)
                let gap = previousBottom.map { box.minY - $0 } ?? 0
                let kind = "\(block.kind)".split(separator: "(").first.map(String.init) ?? ""
                let text = (textView.storage.string as NSString).substring(with: textView.storage.contentRange(of: paragraph))
                print("  gap=\(Int(gap.rounded()))  top=\(Int(box.minY))  height=\(Int(box.height))  \(kind)  \(text.prefix(24).debugDescription)")
                previousBottom = box.maxY
            }
        case "sel":
            if let textView { print("selection: \(textView.selectedRange()) of \(textView.storage.length)") }
        case "save":
            app.session?.flush()
        case "dump":
            guard let editor else { return }
            if argument == "blocks" {
                for block in editor.currentBlocks() {
                    print("  \(block.kind) indent=\(block.indent) blank=\(String(describing: block.blankLinesBefore)) source=\(String(describing: block.sourceIndent)) text=\(block.plainText.prefix(24).debugDescription)")
                }
            }
            print("--- markdown ---")
            print(MarkdownSerializer.serialize(MarkdownDocument(blocks: editor.currentBlocks())), terminator: "")
            print("--- end ---")
        default:
            print("unknown step: \(step)")
        }
    }

    /// Sends a named key to the editor: first to any open menu, then as the matching text command.
    private static func key(_ name: String, editor: EditorController?) {
        guard let editor else { return }
        let codes: [String: UInt16] = ["return": 36, "tab": 48, "escape": 53, "down": 125, "up": 126, "left": 123, "right": 124, "delete": 51]
        if let code = codes[name],
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: editor.view.window?.windowNumber ?? 0, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code),
           editor.editorShouldHandle(event) {
            return
        }
        let textView = editor.textView
        switch name {
        case "return": textView.insertNewline(nil)
        case "shift-return": textView.insertLineBreak(nil)
        case "cmd-return": textView.commandReturn()
        case "tab": textView.insertTab(nil)
        case "backtab": textView.insertBacktab(nil)
        case "delete": textView.deleteBackward(nil)
        case "forward-delete": textView.deleteForward(nil)
        case "up": textView.moveUp(nil)
        case "down": textView.moveDown(nil)
        case "left": textView.moveLeft(nil)
        case "right": textView.moveRight(nil)
        case "escape": textView.cancelOperation(nil)
        case "select-all": textView.selectAll(nil)
        default: print("unknown key: \(name)")
        }
    }

    // MARK: Capturing

    /// Sizes and positions the window for a capture and optionally activates the app.
    static func prepare(_ window: NSWindow) {
        let wantsRetina = environment["LP_SNAPSHOT_SCREEN"] == "retina"
        let screen = wantsRetina
            ? NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor })
            : (window.screen ?? NSScreen.main)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(requestedSize.width, visible.width), height: min(requestedSize.height, visible.height))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        if environment["LP_SNAPSHOT_ACTIVATE"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Captures `window` the way the window server composites it (materials and glass included).
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias CaptureFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        let includingWindow: UInt32 = 1 << 3      // kCGWindowListOptionIncludingWindow
        let boundsIgnoreFraming: UInt32 = 1 << 0  // kCGWindowImageBoundsIgnoreFraming
        let bestResolution: UInt32 = 1 << 3       // kCGWindowImageBestResolution
        return capture(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue()
    }

    private static func writeViewHierarchy(_ name: String, window: NSWindow) {
        guard let directory = outputDirectory, let view = window.contentView else { return }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    @discardableResult
    private static func write(_ name: String, window: NSWindow) -> Bool {
        window.displayIfNeeded()
        guard let directory = outputDirectory, let image = windowServerImage(of: window) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: directory.appendingPathComponent("\(name).png"))) != nil
    }
}
#endif
