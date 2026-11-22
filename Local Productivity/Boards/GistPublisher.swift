//
//  GistPublisher.swift
//  LP
//
//  Publishes a board's progress page as a secret GitHub Gist: a web page anyone with the
//  link can open from anywhere, which LP keeps up to date as the board changes. Secret
//  gists are not listed or searchable. The GitHub token is kept in the Keychain.
//

import Foundation

enum GistPublisher {

    private static let keychainService = "LTF.Local-Productivity.github"
    private static let keychainAccount = "token"
    private static let api = URL(string: "https://api.github.com")!

    /// Where to create a token with just the permission sharing needs.
    static let newTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=gist&description=LP%20progress%20sharing")!

    // MARK: Token

    static var hasToken: Bool { token != nil }

    static var token: String? {
        #if DEBUG
        // Harness runs never read the real token, so nothing they do can reach GitHub.
        if SnapshotHarness.isActive { return nil }
        #endif
        return Keychain.data(service: keychainService, account: keychainAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Until when GitHub asked LP to slow down, for the saved token (every board).
    static var pausedUntil: Date? { token.flatMap { ServicePause.until(pauseKey(for: $0)) } }

    /// GitHub's "wait until" is kept per token — two tokens may be two accounts, each with its own
    /// allowance — under a hash of it.
    private static func pauseKey(for token: String) -> String {
        "github." + ServicePause.fingerprint(token)
    }

    static func setToken(_ token: String?) throws {
        #if DEBUG
        // Harness runs never change the real token either (they can't see it, see `token`).
        if SnapshotHarness.isActive { return }
        #endif
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Keychain.set(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                             service: keychainService, account: keychainAccount)
        } else {
            Keychain.delete(service: keychainService, account: keychainAccount)
        }
    }

    /// The GitHub user name the token belongs to, which also proves the token works.
    static func verify(_ token: String) async throws -> String {
        var request = URLRequest(url: api.appendingPathComponent("user"))
        authorize(&request, token: token)
        let data = try await send(request, token: token)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else { throw CalendarSyncError.invalidResponse }
        return login
    }

    // MARK: Gists

    /// Creates a secret gist with one Markdown file and returns its identity and address.
    static func create(fileName: String, content: String, description: String) async throws -> BoardShare {
        let body: [String: Any] = [
            "description": description,
            "public": false,
            "files": [fileName: ["content": content]]
        ]
        let data = try await call("POST", "gists", body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, let link = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw CalendarSyncError.invalidResponse
        }
        return BoardShare(gistID: id, url: link, fileName: fileName, lastPublished: Date())
    }

    /// Replaces the page's content, renaming the file if the board was renamed.
    static func update(_ share: BoardShare, fileName: String, content: String, description: String) async throws -> BoardShare {
        // The ID goes into the request's path, so only a real gist ID is sent.
        guard share.service == .gist, BoardShare.isValidGistID(share.pageID) else { throw CalendarSyncError.notFound }
        var file: [String: Any] = ["content": content]
        if fileName != share.fileName { file["filename"] = fileName }
        let body: [String: Any] = ["description": description, "files": [share.fileName: file]]
        _ = try await call("PATCH", "gists/\(share.pageID)", body: body)
        var updated = share
        updated.fileName = fileName
        updated.lastPublished = Date()
        return updated
    }

    static func delete(_ share: BoardShare) async throws {
        guard share.service == .gist, BoardShare.isValidGistID(share.pageID) else { throw CalendarSyncError.notFound }
        do {
            _ = try await call("DELETE", "gists/\(share.pageID)")
        } catch CalendarSyncError.notFound {
            // Already gone.
        }
    }

    // MARK: Requests

    /// Sends a request to GitHub with the saved token.
    private static func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let token else { throw SharingError.noToken }
        var request = URLRequest(url: api.appendingPathComponent(path))
        request.httpMethod = method
        authorize(&request, token: token)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request, token: token)
    }

    private static func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    private static func send(_ request: URLRequest, token: String) async throws -> Data {
        // GitHub asked LP to wait (for this token): nothing goes out with it before then.
        let key = pauseKey(for: token)
        if let until = ServicePause.until(key) { throw SharingError.rateLimited(until) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarSyncError.invalidResponse }
        // "Too many requests" (GitHub answers 403 or 429): not a permissions problem.
        if let until = RateLimit.retryDate(status: http.statusCode, header: { http.value(forHTTPHeaderField: $0) }, body: data) {
            throw SharingError.rateLimited(ServicePause.record(key, until: until))
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw SharingError.tokenRejected
        case 403: throw SharingError.notPermitted
        case 404: throw CalendarSyncError.notFound
        default: throw CalendarSyncError.server(http.statusCode, AuthorizedClient.message(in: data))
        }
    }
}

enum SharingError: LocalizedError {
    case noToken, tokenRejected, notPermitted
    /// GitHub asked LP to slow down until then.
    case rateLimited(Date)

    var errorDescription: String? {
        switch self {
        case .noToken: return "Add a GitHub token in Settings → Sharing to share progress."
        case .tokenRejected: return "GitHub didn’t accept the token. Create a new one in Settings → Sharing."
        case .notPermitted: return "The GitHub token can’t create gists. Give it the “gist” permission."
        case .rateLimited(let until):
            return "GitHub asked LP to slow down. Please wait until \(until.formatted(date: .omitted, time: .shortened)), then try again."
        }
    }
}
