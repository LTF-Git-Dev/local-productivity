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
        Keychain.data(service: keychainService, account: keychainAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setToken(_ token: String?) throws {
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
        let data = try await send(request)
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
        let data = try await send(try request("POST", "gists", body: body))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, let link = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw CalendarSyncError.invalidResponse
        }
        return BoardShare(gistID: id, url: link, fileName: fileName, lastPublished: Date())
    }

    /// Replaces the page's content, renaming the file if the board was renamed.
    static func update(_ share: BoardShare, fileName: String, content: String, description: String) async throws -> BoardShare {
        var file: [String: Any] = ["content": content]
        if fileName != share.fileName { file["filename"] = fileName }
        let body: [String: Any] = ["description": description, "files": [share.fileName: file]]
        _ = try await send(try request("PATCH", "gists/\(share.gistID)", body: body))
        var updated = share
        updated.fileName = fileName
        updated.lastPublished = Date()
        return updated
    }

    static func delete(_ share: BoardShare) async throws {
        do {
            _ = try await send(try request("DELETE", "gists/\(share.gistID)"))
        } catch CalendarSyncError.notFound {
            // Already gone.
        }
    }

    // MARK: Requests

    private static func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let token else { throw SharingError.noToken }
        var request = URLRequest(url: api.appendingPathComponent(path))
        request.httpMethod = method
        authorize(&request, token: token)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarSyncError.invalidResponse }
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

    var errorDescription: String? {
        switch self {
        case .noToken: return "Add a GitHub token in Settings → Sharing to share progress."
        case .tokenRejected: return "GitHub didn’t accept the token. Create a new one in Settings → Sharing."
        case .notPermitted: return "The GitHub token can’t create gists. Give it the “gist” permission."
        }
    }
}
