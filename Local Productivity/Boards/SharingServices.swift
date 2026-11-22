//
//  SharingServices.swift
//  LP
//
//  Where a board's progress page can go, and the one way BoardStore reaches either — always the
//  person's own accounts: GitHub with their own token (a secret gist), or the Drive of a Google
//  account they connected and allowed (a Google Doc only LP's own files permission can touch).
//  Also keeps, on this Mac, which Drive pages LP made (or keeps up to date) for which account, so
//  disconnecting an account deletes them first — after any page still being made.
//

import Foundation

enum ShareDestination: Hashable {
    case gist
    case googleDrive(account: String)
}

@MainActor
enum SharingServices {

    /// Set by AppModel: the connected calendar accounts (and their Drives).
    weak static var calendar: CalendarSyncStore?
    /// Set by AppModel: where the list of Drive pages is kept (nil: only in memory, for snapshots).
    static var defaults: UserDefaults?

    // MARK: Destinations

    /// Where a board can be shared right now.
    static var destinations: [ShareDestination] {
        var all: [ShareDestination] = []
        if SharingAccount.shared.hasToken { all.append(.gist) }
        for account in calendar?.accounts ?? [] where account.kind == .google && calendar?.canUseDrive(account) == true {
            all.append(.googleDrive(account: account.id))
        }
        return all
    }

    static func title(of destination: ShareDestination) -> String {
        switch destination {
        case .gist: return "On GitHub"
        case .googleDrive(let account): return "In Google Drive (\(accountName(account)))"
        }
    }

    /// Where a shared page lives, said for its panel.
    static func whereItLives(_ share: BoardShare) -> String {
        switch share.service {
        case .gist: return "A secret gist on your GitHub"
        case .googleDrive: return "A Google Doc in \(accountName(share.account ?? ""))’s Drive"
        }
    }

    static func accountName(_ account: String) -> String {
        calendar?.accounts.first { $0.id == account }?.name ?? String(account.dropFirst("google:".count))
    }

    /// Whether a page can be updated or deleted from here right now.
    static func isReady(_ share: BoardShare) -> Bool {
        switch share.service {
        case .gist: return GistPublisher.hasToken
        case .googleDrive: return share.account.flatMap { calendar?.driveBackend(for: $0) } != nil
        }
    }

    /// Until when the page's service asked LP to slow down.
    static func pausedUntil(_ share: BoardShare) -> Date? {
        switch share.service {
        case .gist: return GistPublisher.pausedUntil
        case .googleDrive: return share.account.flatMap { calendar?.driveBackend(for: $0) }?.pausedUntil
        }
    }

    static func isRateLimited(_ error: any Error) -> Bool {
        if case SharingError.rateLimited = error { return true }
        if case DriveSharingError.rateLimited = error { return true }
        return false
    }

    // MARK: Pages

    /// Publishes a new page for `input` at `destination`.
    static func create(_ destination: ShareDestination, title: String, input: BoardReport.Input) async throws -> BoardShare {
        switch destination {
        case .gist:
            return try await GistPublisher.create(fileName: gistFileName(title), content: BoardReport.markdown(input),
                                                  description: gistDescription(title))
        case .googleDrive(let account):
            guard work.begin(account) else { throw DriveSharingError.disconnecting }
            defer { work.end(account) }
            guard let backend = calendar?.driveBackend(for: account) else { throw DriveSharingError.notConnected }
            let name = documentName(title)
            let id = try await backend.upload(name: name, html: BoardReport.documentHTML(input))
            // On the list from the moment it exists, before anyone else can see it: whatever happens
            // next, disconnecting the account deletes it.
            registry.add(id, account: account)
            do {
                try await backend.makePublic(fileID: id)
            } catch {
                // Nothing half-shared stays: it is deleted again — and stays on the list if that fails.
                if (try? await backend.delete(fileID: id)) != nil { registry.remove(id, account: account) }
                throw error
            }
            return BoardShare(driveFileID: id, account: account, fileName: name, lastPublished: Date())
        }
    }

    /// Replaces a page's content (renaming it with the board), keeping its address.
    static func update(_ share: BoardShare, title: String, input: BoardReport.Input) async throws -> BoardShare {
        switch share.service {
        case .gist:
            return try await GistPublisher.update(share, fileName: gistFileName(title), content: BoardReport.markdown(input),
                                                  description: gistDescription(title))
        case .googleDrive:
            guard share.isWellFormed, let account = share.account else { throw CalendarSyncError.notFound }
            guard work.begin(account) else { throw DriveSharingError.disconnecting }
            defer { work.end(account) }
            guard let backend = calendar?.driveBackend(for: account) else { throw DriveSharingError.notConnected }
            // A page this Mac keeps up to date is on its list — before anything is sent, so a
            // disconnect that waits for this update deletes the page afterwards (one set up
            // elsewhere, say, or one let go of when the account was disconnected before).
            registry.add(share.pageID, account: account)
            let name = documentName(title)
            do {
                try await backend.update(fileID: share.pageID, name: name, html: BoardReport.documentHTML(input))
            } catch CalendarSyncError.notFound {
                // Deleted in Drive: nothing left to keep track of.
                registry.remove(share.pageID, account: account)
                throw CalendarSyncError.notFound
            }
            var updated = share
            updated.fileName = name
            updated.lastPublished = Date()
            return updated
        }
    }

    /// Deletes a page.
    static func delete(_ share: BoardShare) async throws {
        switch share.service {
        case .gist:
            try await GistPublisher.delete(share)
        case .googleDrive:
            guard share.isWellFormed, let account = share.account else { throw CalendarSyncError.notFound }
            guard let backend = calendar?.driveBackend(for: account) else { throw DriveSharingError.notConnected }
            try await backend.delete(fileID: share.pageID)
            registry.remove(share.pageID, account: account)
        }
    }

    /// "Keep It Updated From Here" for a page set up elsewhere: it goes on this Mac's list, so
    /// disconnecting the account here deletes it like the pages made here.
    static func adopt(_ share: BoardShare) {
        guard share.service == .googleDrive, share.isWellFormed, let account = share.account else { return }
        registry.add(share.pageID, account: account)
    }

    // MARK: Disconnecting

    /// How many pages in this account's Drive this Mac made or keeps up to date (and hasn't deleted).
    static func drivePageCount(of account: String) -> Int {
        registry.pages(of: account).count
    }

    /// Whether disconnecting the account has pages to delete first, or one still being made.
    static func hasDriveWork(of account: String) -> Bool {
        drivePageCount(of: account) > 0 || work.isRunning(account)
    }

    /// Whether a Drive page is being made or updated through the account's connection right now.
    static func isDriveWorkRunning(of account: String) -> Bool {
        work.isRunning(account)
    }

    /// Settings → Calendars → Disconnect: first deletes the pages in the account's Drive — after
    /// waiting for any still being made, while nothing new starts — then disconnects it. Returns
    /// how many pages couldn't be deleted (offline, say); then the account stays connected,
    /// unless `anyway`: then LP forgets those pages (they stay in the Drive) and disconnects.
    @discardableResult
    static func disconnect(_ account: CalendarAccount, anyway: Bool = false) async -> Int {
        let id = account.id
        work.startDisconnecting(id)
        defer { work.endDisconnecting(id) }
        // A page still on its way has to be on the list before the list is worked through.
        let deadline = Date().addingTimeInterval(90)
        while work.isRunning(id), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let backend = calendar?.driveBackend(for: id) {
            for page in registry.pages(of: id) {
                do {
                    try await backend.delete(fileID: page)
                    registry.remove(page, account: id)
                } catch {
                    // Kept on the list: it is still in the Drive.
                }
            }
        }
        let left = drivePageCount(of: id) + (work.isRunning(id) ? 1 : 0)
        guard left == 0 || anyway else { return left }
        for page in registry.pages(of: id) { registry.remove(page, account: id) }
        calendar?.disconnect(account)
        return left
    }

    // MARK: Names and the list

    static func gistFileName(_ title: String) -> String { (Workspace.sanitized(title) ?? "Board") + " — Progress.md" }
    static func gistDescription(_ title: String) -> String { "\(title) — progress shared from LP" }
    static func documentName(_ title: String) -> String { "\(title) — Progress" }

    #if DEBUG
    /// For the harness: as if this Mac had never had the page on its list (set up on another Mac).
    static func unlist(_ share: BoardShare) {
        guard let account = share.account else { return }
        registry.remove(share.pageID, account: account)
    }
    #endif

    private static let registryKey = "sharing.drivePages"
    private static var memory = DrivePageRegistry()
    private static var work = DriveWork()

    private static var registry: DrivePageRegistry {
        get {
            guard let defaults else { return memory }
            return defaults.data(forKey: registryKey).flatMap { try? JSONDecoder().decode(DrivePageRegistry.self, from: $0) } ?? DrivePageRegistry()
        }
        set {
            guard let defaults else { memory = newValue; return }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: registryKey)
        }
    }
}
