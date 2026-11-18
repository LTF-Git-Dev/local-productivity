//
//  OAuth.swift
//  LP
//
//  Sign-in for Google and Microsoft calendars, using the OAuth 2.0 authorization-code
//  flow with PKCE, the method both recommend for apps that cannot keep a secret. The
//  sign-in page opens in the system's secure web sheet, so LP never sees a password;
//  it only receives tokens, which are kept in the Keychain.
//

import AuthenticationServices
import Foundation

// MARK: - Signing in

/// Runs the browser part of sign-in and exchanges the result for tokens.
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var session: ASWebAuthenticationSession?

    func signIn(_ config: OAuthConfiguration) async throws -> OAuthTokens {
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        guard let url = OAuthRequests.authorizeURL(config, state: state, challenge: PKCE.challenge(for: verifier)) else {
            throw CalendarSyncError.invalidResponse
        }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(config.callbackScheme)) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CalendarSyncError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? CalendarSyncError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: CalendarSyncError.cancelled)
            }
        }
        session = nil

        let code = try OAuthRequests.code(from: callback, expectedState: state)
        let (data, _) = try await URLSession.shared.data(for: OAuthRequests.codeExchange(config, code: code, verifier: verifier))
        return try OAuthRequests.tokens(from: data, previousRefreshToken: nil)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }
}

// MARK: - Keeping tokens fresh

/// Owns one account's tokens: loads them from the Keychain, refreshes them before they
/// expire, and saves every change back.
final class OAuthTokenStore {

    private let config: OAuthConfiguration
    private let keychainAccount: String
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, Error>?

    static let keychainService = "LTF.Local-Productivity.calendar"

    init(config: OAuthConfiguration, keychainAccount: String, tokens: OAuthTokens? = nil) {
        self.config = config
        self.keychainAccount = keychainAccount
        if let tokens {
            self.tokens = tokens
            save(tokens)
        } else if let data = Keychain.data(service: Self.keychainService, account: keychainAccount) {
            self.tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data)
        }
    }

    var hasTokens: Bool { tokens != nil }

    /// A valid access token, refreshing first if the current one is about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw CalendarSyncError.signInRequired }
        if current.isFresh(), !forceRefresh { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let refreshToken = current.refreshToken else { throw CalendarSyncError.signInRequired }

        let config = config
        let task = Task<OAuthTokens, Error> {
            let (data, response) = try await URLSession.shared.data(for: OAuthRequests.refresh(config, refreshToken: refreshToken))
            if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 401 {
                throw CalendarSyncError.signInRequired
            }
            return try OAuthRequests.tokens(from: data, previousRefreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh = try await task.value
        tokens = fresh
        save(fresh)
        return fresh.accessToken
    }

    func forget() {
        tokens = nil
        Keychain.delete(service: Self.keychainService, account: keychainAccount)
    }

    private func save(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? Keychain.set(data, service: Self.keychainService, account: keychainAccount)
    }
}

// MARK: - Authorised requests

/// Sends API requests with the account's access token, refreshing and retrying once if the
/// service says the token has expired, and turns error responses into `CalendarSyncError`s.
struct AuthorizedClient {

    let tokens: OAuthTokenStore

    func send(_ request: URLRequest) async throws -> Data {
        var attempt = request
        attempt.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: attempt)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            attempt.setValue("Bearer \(try await tokens.accessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: attempt)
        }
        guard let http = response as? HTTPURLResponse else { throw CalendarSyncError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw CalendarSyncError.signInRequired
        case 403:
            throw CalendarSyncError.accessDenied
        case 404, 410:
            throw CalendarSyncError.notFound
        case 409, 412:
            throw CalendarSyncError.conflict
        default:
            throw CalendarSyncError.server(http.statusCode, Self.message(in: data))
        }
    }

    /// The human-readable message in a Google or Microsoft error body.
    static func message(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? ""
        }
        return json["error_description"] as? String ?? ""
    }

    static func jsonRequest(_ method: String, _ url: URL, body: Data? = nil, ifMatch: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        return request
    }
}

// MARK: - Keychain

nonisolated enum Keychain {

    static func set(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CalendarSyncError.server(Int(status), "Couldn’t save the sign-in to the Keychain.")
        }
    }

    static func data(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
