//
//  GoogleDrivePublisher.swift
//  LP
//
//  Shares a board's progress page through the person's own Google Drive — with the Google account
//  they connected for the calendar, its own registration and tokens (and its "slow down" waits).
//  The page is a Google Doc that anyone with its link can read; LP can only see and change the
//  files it created there (Google's `drive.file` permission).
//

import Foundation

enum DriveSharingError: LocalizedError, Equatable {
    case notConnected
    case disconnecting
    case connectionChanged
    case notAllowed
    case otherAccount(String, expected: String)
    case rateLimited(Date)
    case unreadable
    case conflict
    case server(Int, String)
    case awaitingGoogleReview

    var errorDescription: String? {
        switch self {
        case .awaitingGoogleReview:
            return "Sharing to Google Drive through LP’s own registration comes once Google finishes reviewing LP. Until then, connect Google with your own client ID (Settings → Calendars → Use Your Own Client ID)."
        case .notConnected:
            return "The Google account this page belongs to isn’t connected. Connect it in Settings → Calendars."
        case .connectionChanged:
            return "This Google account was connected again while Google’s page was open, so nothing was changed. Click “Allow Google Drive…” again."
        case .disconnecting:
            return "This Google account is being disconnected in Settings → Calendars, so nothing more goes to its Drive."
        case .notAllowed:
            return "LP isn’t allowed to use Google Drive for this account. Click “Allow Google Drive…” in Settings → Sharing and keep that permission ticked on Google’s page."
        case .otherAccount(let signedIn, let expected):
            return "You signed in as \(signedIn), not \(expected). Click “Allow Google Drive…” again and choose \(expected)."
        case .rateLimited(let until):
            return "Google asked LP to slow down. Please wait until \(until.formatted(date: .omitted, time: .shortened)), then try again."
        case .unreadable:
            return "Google Drive sent an answer LP couldn’t read. Please try again."
        case .conflict:
            return "Google Drive was changing this page at the same moment. Please try again."
        case .server(let status, let message):
            return message.isEmpty ? "Google Drive returned an error (\(status)). Please try again." : message
        }
    }
}

enum GoogleDrivePublisher {

    /// Puts the page in the Drive as a Google Doc that, so far, only its owner can open. Sharing
    /// lists it before letting anyone else see it (`makePublic`), so it can always be deleted again.
    static func upload(name: String, html: String, client: AuthorizedClient) async throws -> String {
        try await speakingOfDrive {
            let data = try await client.send(GoogleDriveMapping.createRequest(name: name, html: html, boundary: GoogleDriveMapping.boundary()))
            return try GoogleDriveMapping.fileID(from: data)
        }
    }

    /// Lets anyone with the link view the page.
    static func makePublic(fileID: String, client: AuthorizedClient) async throws {
        guard let request = GoogleDriveMapping.publishRequest(fileID: fileID) else { throw DriveSharingError.unreadable }
        _ = try await speakingOfDrive { try await client.send(request) }
    }

    /// Replaces the page's content (and name), keeping its address.
    static func update(fileID: String, name: String, html: String, client: AuthorizedClient) async throws {
        guard let request = GoogleDriveMapping.updateRequest(fileID: fileID, name: name, html: html,
                                                             boundary: GoogleDriveMapping.boundary()) else {
            throw CalendarSyncError.notFound
        }
        _ = try await speakingOfDrive { try await client.send(request) }
    }

    /// Deletes the page; one that is already gone counts as deleted.
    static func delete(fileID: String, client: AuthorizedClient) async throws {
        guard let request = GoogleDriveMapping.deleteRequest(fileID: fileID) else { return }
        do {
            _ = try await speakingOfDrive { try await client.send(request) }
        } catch CalendarSyncError.notFound {
            // Already gone.
        }
    }

    /// Says Google Drive's problems in sharing's words (the client speaks the calendar's). "Not
    /// found" stays as it is: sharing treats it as "the page is gone".
    private static func speakingOfDrive<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch CalendarSyncError.accessDenied {
            throw DriveSharingError.notAllowed
        } catch CalendarSyncError.rateLimited(let until) {
            throw DriveSharingError.rateLimited(until)
        } catch GoogleDriveMapping.Problem.unreadable, CalendarSyncError.invalidResponse {
            throw DriveSharingError.unreadable
        } catch CalendarSyncError.conflict {
            throw DriveSharingError.conflict
        } catch CalendarSyncError.server(let status, let message) {
            throw DriveSharingError.server(status, message)
        }
    }
}

// MARK: - Backends

/// Where one connected Google account's Drive pages go: its real Drive, or (in Debug builds) a
/// demo kept in memory.
@MainActor
protocol DriveBackend {
    /// A new page that only its owner can open so far; its ID.
    func upload(name: String, html: String) async throws -> String
    func makePublic(fileID: String) async throws
    func update(fileID: String, name: String, html: String) async throws
    func delete(fileID: String) async throws
    /// Until when Google asked LP to slow down for this account.
    var pausedUntil: Date? { get }
}

struct GoogleDriveBackend: DriveBackend {
    let client: AuthorizedClient
    let pauseKey: String

    func upload(name: String, html: String) async throws -> String {
        try await GoogleDrivePublisher.upload(name: name, html: html, client: client)
    }

    func makePublic(fileID: String) async throws {
        try await GoogleDrivePublisher.makePublic(fileID: fileID, client: client)
    }

    func update(fileID: String, name: String, html: String) async throws {
        try await GoogleDrivePublisher.update(fileID: fileID, name: name, html: html, client: client)
    }

    func delete(fileID: String) async throws {
        try await GoogleDrivePublisher.delete(fileID: fileID, client: client)
    }

    var pausedUntil: Date? { ServicePause.until(pauseKey) }
}
