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
        // A disconnect just before mustn't end this sign-in when its revocation arrives.
        await OAuthRevocations.settle(for: config)
        let revocationsBefore = OAuthRevocations.count(for: config)
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
            // Ask for a private sign-in: with Safari as the default browser it shares no cookies and
            // keeps none (another default browser may not honour it).
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: CalendarSyncError.cancelled)
            }
        }
        session = nil

        let code = try OAuthRequests.code(from: callback, expectedState: state)
        let (data, _) = try await URLSession.shared.data(for: OAuthRequests.codeExchange(config, code: code, verifier: verifier))
        let tokens = try OAuthRequests.tokens(from: data, previousRefreshToken: nil, clientID: config.clientID)
        try await OAuthRevocations.ensureNone(since: revocationsBefore, for: config)
        return tokens
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
    /// Counts `forget()` calls, so a refresh that finishes after one doesn't bring tokens back.
    private var generation = 0

    static let keychainService = "LTF.Local-Productivity.calendar"

    /// Who a "wait until" is kept for: the account — or, for a sign-in still finding out which
    /// account it is, that sign-in's own credential (one person's wait mustn't hold up another's).
    private let pauseIdentity: String

    /// Where this account's "wait until" is kept (`ServicePause`).
    var pauseKey: String { "calendar." + pauseIdentity }

    init(config: OAuthConfiguration, keychainAccount: String, tokens: OAuthTokens? = nil, pauseIdentity: String? = nil) {
        self.config = config
        self.keychainAccount = keychainAccount
        self.pauseIdentity = pauseIdentity ?? keychainAccount
        if let tokens {
            self.tokens = tokens
            save(tokens)
        } else if let data = Keychain.data(service: Self.keychainService, account: keychainAccount) {
            let loaded = try? JSONDecoder().decode(OAuthTokens.self, from: data)
            self.tokens = loaded
            // Tokens saved before LP noted their registration belong to the one in use when they
            // are first loaded by this version (the client ID they were made with): noted at once,
            // before a setting can change.
            if let loaded, loaded.clientID == nil {
                let pinned = loaded.pinned(to: config.clientID)
                self.tokens = pinned
                save(pinned)
            }
        }
    }

    var hasTokens: Bool { tokens != nil }

    /// The app registration these tokens belong to.
    var clientID: String { config.clientID }

    /// The registration that issued an account's saved tokens, when they say (tokens saved by LP
    /// 1.0.0 don't): reconnecting at launch must use that one, whatever the settings say now.
    static func storedClientID(keychainAccount: String) -> String? {
        Keychain.data(service: keychainService, account: keychainAccount)
            .flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }?.clientID
    }

    /// The permissions the person granted with these tokens (empty when unknown).
    var grantedScopes: [String] { tokens?.scopes ?? [] }

    /// A valid access token, refreshing first if the current one is about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw CalendarSyncError.signInRequired }
        if current.isFresh(), !forceRefresh { return current.accessToken }
        if let refreshTask {
            let started = generation
            let fresh = try await refreshTask.value
            // Disconnected while waiting for it.
            guard generation == started else { throw CalendarSyncError.signInRequired }
            return fresh.accessToken
        }
        guard let refreshToken = current.refreshToken else { throw CalendarSyncError.signInRequired }
        // The sign-in service is no exception to "wait until": nothing goes to it before then.
        if let until = ServicePause.until(pauseKey) { throw CalendarSyncError.rateLimited(until) }

        let config = config
        let pauseKey = pauseKey
        let task = Task<OAuthTokens, Error> {
            // Again when the refresh really starts (a task may start later): a reply to another
            // request may have asked LP to wait meanwhile.
            if let until = ServicePause.until(pauseKey) { throw CalendarSyncError.rateLimited(until) }
            let (data, response) = try await URLSession.shared.data(for: OAuthRequests.refresh(config, refreshToken: refreshToken))
            if let http = response as? HTTPURLResponse,
               let until = RateLimit.retryDate(status: http.statusCode, header: { http.value(forHTTPHeaderField: $0) }, body: data) {
                throw CalendarSyncError.rateLimited(ServicePause.record(pauseKey, until: until))
            }
            if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 401 {
                throw CalendarSyncError.signInRequired
            }
            return try OAuthRequests.tokens(from: data, previousRefreshToken: refreshToken, previousScopes: current.scopes,
                                            clientID: config.clientID)
        }
        refreshTask = task
        let started = generation
        defer { if generation == started { refreshTask = nil } }
        let fresh = try await task.value
        // The account was disconnected while the refresh was under way.
        guard generation == started else { throw CalendarSyncError.signInRequired }
        tokens = fresh
        save(fresh)
        return fresh.accessToken
    }

    /// Forgets the tokens on this Mac (and stops any refresh). Used when tokens move to another
    /// store, too — so it never ends the access at the service; `disconnect()` does that.
    func forget() {
        retire()
        Keychain.delete(service: Self.keychainService, account: keychainAccount)
    }

    /// The account is disconnected: forget the tokens and ask the service to end LP's access,
    /// where it can be asked (Google; best effort).
    func disconnect() {
        let token = tokens?.refreshToken ?? tokens?.accessToken
        forget()
        if let token, let request = OAuthRequests.revocation(config, token: token) {
            OAuthRevocations.send(request)
        }
    }

    /// Removes an account's tokens when no connection is attached to it (its client ID was
    /// cleared, say) — and still asks for its access to end where the service allows it.
    static func removeStored(keychainAccount: String, revocationURL: URL?) {
        let stored = Keychain.data(service: keychainService, account: keychainAccount)
            .flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
        Keychain.delete(service: keychainService, account: keychainAccount)
        if let token = stored?.refreshToken ?? stored?.accessToken, let revocationURL {
            OAuthRevocations.send(OAuthRequests.revocation(at: revocationURL, token: token))
        }
    }

    /// Stops this store for good without touching the Keychain: a newer connection to the same
    /// account uses that entry now, and a refresh still on its way here must not write over it —
    /// or bring it back after that connection is disconnected.
    func retire() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
    }

    private func save(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? Keychain.set(data, service: Self.keychainService, account: keychainAccount)
    }
}

/// Revocations on their way, by service (its revocation address) rather than app registration:
/// Google ends grants across a project's registrations, so a sign-in to that service waits for
/// them — a revocation arriving late would otherwise end the new sign-in too.
enum OAuthRevocations {
    private static var pending: [String: Task<Void, Never>] = [:]
    private static var sent: [String: Int] = [:]

    static func send(_ request: URLRequest) {
        guard let key = request.url?.absoluteString else { return }
        var request = request
        request.timeoutInterval = 15
        let earlier = pending[key]
        sent[key, default: 0] += 1
        pending[key] = Task {
            await earlier?.value
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// How many revocations have been sent to this service (a sign-in compares it before and after).
    static func count(for config: OAuthConfiguration) -> Int {
        config.revocationURL.map { sent[$0.absoluteString, default: 0] } ?? 0
    }

    /// Throws `signInInterrupted`, once they have finished, when a revocation to this service was
    /// sent since `count`: it may end a grant just made (Google ends grants across a project), so
    /// rather than keep tokens that may stop working, the connection is asked for again. Checked
    /// at the end of a sign-in and again just before its tokens are kept.
    static func ensureNone(since count: Int, for config: OAuthConfiguration) async throws {
        guard self.count(for: config) != count else { return }
        await settle(for: config)
        throw CalendarSyncError.signInInterrupted
    }

    /// Waits until no revocation to this service is on its way — including ones sent meanwhile.
    static func settle(for config: OAuthConfiguration) async {
        guard let key = config.revocationURL?.absoluteString else { return }
        while let task = pending[key] {
            await task.value
            if pending[key] == task { pending[key] = nil }
        }
    }
}

// MARK: - Authorised requests

/// Sends API requests with the account's access token, refreshing and retrying once if the
/// service says the token has expired, and turns error responses into `CalendarSyncError`s.
struct AuthorizedClient {

    let tokens: OAuthTokenStore

    func send(_ request: URLRequest) async throws -> Data {
        var attempt = request
        // The service asked LP to wait: nothing for this account goes out before then — not the
        // next page of a sync under way, not a change. Checked right before every call, since
        // another request may have been told to wait while this one waited for a token.
        try checkPause()
        attempt.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        try checkPause()
        var (data, response) = try await URLSession.shared.data(for: attempt)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try checkPause()
            attempt.setValue("Bearer \(try await tokens.accessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            try checkPause()
            (data, response) = try await URLSession.shared.data(for: attempt)
        }
        guard let http = response as? HTTPURLResponse else { throw CalendarSyncError.invalidResponse }
        // "Too many requests": said as such, and every request for this account waits as long as asked.
        if let until = RateLimit.retryDate(status: http.statusCode, header: { http.value(forHTTPHeaderField: $0) }, body: data) {
            throw CalendarSyncError.rateLimited(ServicePause.record(tokens.pauseKey, until: until))
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw CalendarSyncError.signInRequired
        case 403:
            // The API isn't turned on in the person's Google Cloud project: say exactly that.
            if let service = GoogleAPIProblem.disabledService(in: data) { throw CalendarSyncError.serviceDisabled(service) }
            throw CalendarSyncError.accessDenied
        case 404, 410:
            throw CalendarSyncError.notFound
        case 409, 412:
            throw CalendarSyncError.conflict
        default:
            throw CalendarSyncError.server(http.statusCode, Self.message(in: data))
        }
    }

    private func checkPause() throws {
        if let until = ServicePause.until(tokens.pauseKey) { throw CalendarSyncError.rateLimited(until) }
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
