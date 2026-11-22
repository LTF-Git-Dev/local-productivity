//
//  DriveSharingTest.swift
//  LP
//
//  Debug builds only: checks Google Drive sharing with a real account, one step at a time, so the
//  owner can look at each result — create a test page, open its link the way a viewer would (no
//  cookies, no sign-in), update it, delete it. Shown under an account in Settings → Sharing once
//  Drive is allowed for it.
//

#if DEBUG
import SwiftUI

struct DriveSharingTestView: View {

    @Environment(AppModel.self) private var app
    let account: CalendarAccount

    @State private var fileID: String?
    @State private var log: [String] = []
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test Drive Sharing (Debug builds only)")
                .font(.lp(size: 12, weight: .semibold))
                .foregroundStyle(Color.lpInkSecondary)
            HStack(spacing: 8) {
                Button("1. Create Test Page") { run(create) }
                    .disabled(isBusy || fileID != nil)
                Button("2. Update It") { run(update) }
                    .disabled(isBusy || fileID == nil)
                Button("3. Delete It") { run(delete) }
                    .disabled(isBusy || fileID == nil)
                if isBusy { ProgressView().controlSize(.small) }
            }
            if let fileID, let url = GoogleDriveMapping.pageURL(fileID: fileID) {
                Link("Open the Test Page", destination: url)
            }
            if !log.isEmpty {
                Text(log.joined(separator: "\n"))
                    .font(.lp(size: 11, design: .monospaced))
                    .foregroundStyle(Color.lpInkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var client: AuthorizedClient? { app.calendarSync.driveClient(for: account.id) }

    private func run(_ step: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await step()
            } catch {
                note("✗ \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    private func note(_ line: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
    }

    private func create() async throws {
        guard let client else { throw DriveSharingError.notAllowed }
        let id = try await GoogleDrivePublisher.upload(name: "LP Drive test", html: sample(updated: false), client: client)
        do {
            try await GoogleDrivePublisher.makePublic(fileID: id, client: client)
        } catch {
            try? await GoogleDrivePublisher.delete(fileID: id, client: client)
            throw error
        }
        fileID = id
        note("✓ Created the page and let anyone with the link view it. Open it and look.")
        await checkLink(id, expectingPage: true)
    }

    private func update() async throws {
        guard let client, let id = fileID else { return }
        try await GoogleDrivePublisher.update(fileID: id, name: "LP Drive test (updated)", html: sample(updated: true), client: client)
        note("✓ Updated. Reload the page: its title should say “updated” and a third card appears.")
        await checkLink(id, expectingPage: true)
    }

    private func delete() async throws {
        guard let client, let id = fileID else { return }
        try await GoogleDrivePublisher.delete(fileID: id, client: client)
        fileID = nil
        note("✓ Deleted.")
        await checkLink(id, expectingPage: false)
    }

    /// Opens the link the way a viewer would: a fresh session without cookies or a Google sign-in.
    private func checkLink(_ id: String, expectingPage: Bool) async {
        guard let url = GoogleDriveMapping.pageURL(fileID: id) else { return }
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let host = response.url?.host ?? "?"
            let opens = status == 200 && host == "docs.google.com"
            if expectingPage {
                note(opens ? "✓ The link opens for a viewer without signing in."
                           : "✗ The link didn’t open for a viewer (status \(status), ended at \(host)).")
            } else {
                note(opens ? "✗ The link still opens after deleting." : "✓ The link no longer opens (status \(status)).")
            }
        } catch {
            note("✗ Couldn’t open the link: \(error.localizedDescription)")
        }
    }

    private func sample(updated: Bool) -> String {
        let text = """
        ---
        kanban-plugin: basic
        ---

        ## To do

        - [ ] Write the plan @{2026-11-25} #planning
        - [ ] Review the draft
        \(updated ? "- [ ] A card added by the update\n" : "")

        ## Done

        **Complete**
        - [x] Kick-off meeting


        """
        let title = updated ? "LP Drive test — updated \(Date().formatted(date: .omitted, time: .standard))" : "LP Drive test"
        return BoardReport.documentHTML(BoardReport.Input(title: title, icon: "🧪", board: BoardParser.parse(text), log: nil))
    }
}
#endif

#if DEBUG
import AppKit

/// `LP_DRIVE_SELFTEST=1`: the whole Drive sharing check, on its own, with the first Google account
/// that allows Drive — create a page, check how it is shared and what it says, open it as a viewer
/// would, update it, delete it — printing a report, then quitting. Debug builds only.
@MainActor
enum DriveSelfTest {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["LP_DRIVE_SELFTEST"] != nil }

    private static var passed = 0
    private static var failed = 0

    private static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1 }
        say("  \(ok ? "✓" : "✗") \(what)")
    }

    static func run(_ app: AppModel) async {
        say("Drive sharing self-test")
        // The saved accounts are connected as LP starts.
        var found: CalendarAccount?
        for _ in 0..<60 {
            found = app.calendarSync.accounts.first { $0.kind == .google && app.calendarSync.canUseDrive($0) }
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let account = found, let client = app.calendarSync.driveClient(for: account.id) else {
            check(false, "a Google account with Drive allowed (Settings → Sharing)")
            return finish()
        }
        say("Account: \(masked(account.name))")

        // 1. Create.
        // The way sharing does it: upload, then let anyone with the link view it.
        let id: String
        do {
            id = try await GoogleDrivePublisher.upload(name: "LP Drive self-test (deleted at the end)", html: page(updated: false), client: client)
        } catch {
            check(false, "create the page: \(error.localizedDescription)")
            return finish()
        }
        do {
            try await GoogleDrivePublisher.makePublic(fileID: id, client: client)
            check(true, "created the page in your Drive")
        } catch {
            try? await GoogleDrivePublisher.delete(fileID: id, client: client)
            check(false, "let anyone with the link view the page: \(error.localizedDescription)")
            return finish()
        }

        // 2. How it is shared, and what it is.
        let meta = await json(client, "https://www.googleapis.com/drive/v3/files/\(id)?fields=mimeType,name,owners(displayName,emailAddress)")
        check(meta?["mimeType"] as? String == GoogleDriveMapping.documentType, "Google turned it into a Google Doc")
        let owners = (meta?["owners"] as? [[String: Any]]) ?? []
        let ownerName = owners.first?["displayName"] as? String
        let ownerEmail = owners.first?["emailAddress"] as? String
        let permissions = (await json(client, "https://www.googleapis.com/drive/v3/files/\(id)/permissions?fields=permissions(type,role,allowFileDiscovery)"))?["permissions"] as? [[String: Any]] ?? []
        let anyone = permissions.first { $0["type"] as? String == "anyone" }
        check(anyone?["role"] as? String == "reader", "anyone with the link can view it — and only view")
        check((anyone?["allowFileDiscovery"] as? Bool) != true, "it isn't searchable")
        check(permissions.allSatisfy { ["anyone", "user"].contains($0["type"] as? String ?? "") }, "no one else was given access (only you, and the link)")

        // 3. What it says.
        let first = await text(client, id)
        check(first.contains("LP Drive test") && first.contains("Write the plan") && first.contains("Kick-off meeting"),
              "the page shows the board (title, lists, cards)")
        check(!first.contains("<h1>") && !first.contains("<li>"), "as a document, not as code")
        check(!first.contains("Private note"), "without card notes")

        // 4. As a viewer: no cookies, no sign-in.
        guard let url = GoogleDriveMapping.pageURL(fileID: id) else { return finish() }
        let (status, host, html) = await anonymous(url)
        check(status == 200 && host == "docs.google.com" && html.contains("LP Drive"),
              "the link opens the page for anyone, without signing in (\(status), \(host))")
        if let ownerEmail { check(!html.contains(ownerEmail), "your email address isn't on the public page") }
        if let ownerName, !ownerName.isEmpty {
            say("  ℹ︎ your Google name (\(masked(ownerName))) \(html.contains(ownerName) ? "IS" : "is not") in the public page's HTML")
        }

        // 5. Update in place.
        do {
            try await GoogleDrivePublisher.update(fileID: id, name: "LP Drive self-test (updated)", html: page(updated: true), client: client)
            check(true, "updated the page")
        } catch {
            check(false, "update the page: \(error.localizedDescription)")
        }
        let second = await text(client, id)
        check(second.contains("updated") && second.contains("A card added by the update"), "the update shows on the page")
        let stillOpen = (await anonymous(url)).0 == 200
        check(GoogleDriveMapping.pageURL(fileID: id) == url && stillOpen, "with the same link, still open to viewers")
        let renamed = await json(client, "https://www.googleapis.com/drive/v3/files/\(id)?fields=name,mimeType")
        check(renamed?["name"] as? String == "LP Drive self-test (updated)" && renamed?["mimeType"] as? String == GoogleDriveMapping.documentType,
              "renamed too, and still a Google Doc")

        // 6. Delete.
        do {
            try await GoogleDrivePublisher.delete(fileID: id, client: client)
            check(true, "deleted the page")
        } catch {
            check(false, "delete the page: \(error.localizedDescription)")
        }
        let gone = await json(client, "https://www.googleapis.com/drive/v3/files/\(id)?fields=id")
        check(gone == nil, "it is gone from your Drive")
        // Google may keep serving the page for a little while after the file is gone.
        let deletedAt = Date()
        var stillShows = true
        var last = (0, "?")
        while stillShows, Date().timeIntervalSince(deletedAt) < 180 {
            let after = await anonymous(url)
            last = (after.0, after.1)
            stillShows = after.0 == 200 && after.1 == "docs.google.com" && after.2.contains("LP Drive")
            if stillShows { try? await Task.sleep(for: .seconds(10)) }
        }
        check(!stillShows, "and the link no longer shows it — after \(Int(Date().timeIntervalSince(deletedAt))) s (\(last.0), \(last.1))")
        finish()
    }

    private static func finish() {
        say("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    private static func json(_ client: AuthorizedClient, _ address: String) async -> [String: Any]? {
        guard let url = URL(string: address), let data = try? await client.send(AuthorizedClient.jsonRequest("GET", url)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The Doc as plain text, the way Google exports it.
    private static func text(_ client: AuthorizedClient, _ id: String) async -> String {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/export?mimeType=text/plain"),
              let data = try? await client.send(URLRequest(url: url)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Opens the link the way a viewer would: a fresh session without cookies or a Google sign-in.
    private static func anonymous(_ url: URL) async -> (Int, String, String) {
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(from: url) else { return (0, "?", "") }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, response.url?.host ?? "?", String(data: data, encoding: .utf8) ?? "")
    }

    private static func masked(_ text: String) -> String {
        guard let first = text.first else { return "" }
        if let at = text.firstIndex(of: "@") { return "\(first)***\(text[at...])" }
        return "\(first)***"
    }

    private static func page(updated: Bool) -> String {
        let text = """
        ---
        kanban-plugin: basic
        ---

        ## To do

        - [ ] Write the plan @{2026-11-25} #planning
        \tPrivate note: this must never be shared
        - [ ] Review the draft
        \(updated ? "- [ ] A card added by the update\n" : "")

        ## Done

        **Complete**
        - [x] Kick-off meeting


        """
        let title = updated ? "LP Drive test — updated" : "LP Drive test"
        return BoardReport.documentHTML(BoardReport.Input(title: title, icon: "🧪", board: BoardParser.parse(text), log: nil))
    }
}
#endif
