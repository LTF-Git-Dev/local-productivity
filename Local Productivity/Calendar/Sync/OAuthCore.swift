//
//  OAuthCore.swift
//  LP
//
//  The parts of OAuth sign-in that are pure data: configuration, PKCE codes, and the
//  requests and responses of the token endpoint. Kept apart from the sign-in UI so they
//  can be tested on their own.
//

import CryptoKit
import Foundation

nonisolated struct OAuthConfiguration: Sendable {
    var authorizeURL: URL
    var tokenURL: URL
    var clientID: String
    var redirectURI: String
    /// The URL scheme of `redirectURI`, which the web sheet watches for.
    var callbackScheme: String
    var scopes: [String]
    var extraAuthorizeParameters: [String: String] = [:]
    /// Some services expect the scopes again when refreshing.
    var sendsScopeOnRefresh = false
    /// Where the service ends an app's access when asked (Google); nil when it can't be asked (Microsoft).
    var revocationURL: URL? = nil
}

nonisolated struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// The permissions the person actually granted (Google lets them untick some). Nil for tokens
    /// saved before LP kept track.
    var scopes: [String]? = nil
    /// The app registration (client ID) that issued these tokens — refreshes must use the same
    /// one, whatever the settings say later. Nil for tokens saved before LP kept track.
    var clientID: String? = nil

    func isFresh(at now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) > 60
    }

    /// These tokens, noting the registration that issued them if they don't say yet.
    func pinned(to clientID: String) -> OAuthTokens {
        guard self.clientID == nil else { return self }
        var copy = self
        copy.clientID = clientID
        return copy
    }
}

// MARK: - Which registration

/// Which app registration a new sign-in goes to: the person's own client ID when they set one
/// (Settings → Calendars → Advanced), otherwise the one built into LP — nil when there is neither.
nonisolated enum AppRegistration {
    static func clientID(own: String, builtIn: String?) -> String? {
        let mine = own.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { return mine }
        let shipped = (builtIn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return shipped.isEmpty ? nil : shipped
    }
}

// MARK: - Replacing a connection

/// Whether a new sign-in may replace an account's live connection — the rules behind "Allow Google
/// Drive…" and Connect, kept pure so they're tested. Board pages shared to Google Drive belong to
/// the registration that made them, so a connection only moves to another registration when the
/// person asked for exactly that and nothing of its Drive sharing depends on the old one.
nonisolated enum ConnectionReplacement {
    enum Verdict: Equatable {
        case replace
        /// Another account was chosen on the sign-in page.
        case otherAccount
        /// The account was connected again, through another registration, while this one waited.
        case superseded
        /// Its shared Drive pages (or one being made) need the registration it has.
        case registrationInUse
        /// A Drive page is being made or updated through the live connection right now — replacing
        /// it would end the sign-in that work is using. Fine again in a moment.
        case busy
    }

    /// "Allow Google Drive…" for `expected`, started through `requested`: the same account only, and
    /// never moving it to another registration (it only adds Drive to the connection it has).
    static func allowingDrive(chosen: String, expected: String, liveClientID: String?, requested: String,
                              driveWorkRunning: Bool) -> Verdict {
        guard chosen == expected else { return .otherAccount }
        if let live = liveClientID, live != requested { return .superseded }
        if liveClientID != nil, driveWorkRunning { return .busy }
        return .replace
    }

    /// Connect, through `requested`: an account already connected through another registration
    /// moves only while nothing of its Drive sharing — listed pages or one being made — needs it;
    /// and no live connection is replaced while Drive work runs through it.
    static func connecting(liveClientID: String?, requested: String, hasDriveWork: Bool, driveWorkRunning: Bool) -> Verdict {
        if let live = liveClientID, live != requested, hasDriveWork { return .registrationInUse }
        if liveClientID != nil, driveWorkRunning { return .busy }
        return .replace
    }
}

// MARK: - PKCE

nonisolated enum PKCE {

    private static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A random 64-character code verifier (RFC 7636 allows 43–128).
    static func makeVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in unreserved[Int(generator.next(upperBound: UInt(unreserved.count)))] })
    }

    /// The S256 code challenge for a verifier.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Requests

nonisolated enum OAuthRequests {

    static func authorizeURL(_ config: OAuthConfiguration, state: String, challenge: String) -> URL? {
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        for (name, value) in config.extraAuthorizeParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components?.queryItems = items
        return components?.url
    }

    static func codeExchange(_ config: OAuthConfiguration, code: String, verifier: String) -> URLRequest {
        form(config.tokenURL, [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI
        ])
    }

    static func refresh(_ config: OAuthConfiguration, refreshToken: String) -> URLRequest {
        var fields = [
            "client_id": config.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if config.sendsScopeOnRefresh { fields["scope"] = config.scopes.joined(separator: " ") }
        return form(config.tokenURL, fields)
    }

    /// Asks the service to end this app's access — sent when an account is disconnected, so
    /// LP's access is ended at the source, not only forgotten on this Mac.
    static func revocation(_ config: OAuthConfiguration, token: String) -> URLRequest? {
        config.revocationURL.map { revocation(at: $0, token: token) }
    }

    static func revocation(at url: URL, token: String) -> URLRequest {
        form(url, ["token": token])
    }

    private static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return request
    }

    /// Reads a token response. A refresh response may omit the refresh token, in which case the
    /// previous one is kept. `clientID` is the registration the request went to.
    static func tokens(from data: Data, previousRefreshToken: String?, previousScopes: [String]? = nil,
                       clientID: String? = nil, now: Date = Date()) throws -> OAuthTokens {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarSyncError.invalidResponse
        }
        if let error = json["error"] as? String {
            let description = json["error_description"] as? String ?? error
            if error == "invalid_grant" { throw CalendarSyncError.signInRequired }
            throw CalendarSyncError.server(400, description)
        }
        guard let access = json["access_token"] as? String else { throw CalendarSyncError.invalidResponse }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        // The granted permissions, when the service lists them (a refresh may not: then they stay).
        let scopes = (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previousScopes
        return OAuthTokens(accessToken: access,
                           refreshToken: json["refresh_token"] as? String ?? previousRefreshToken,
                           expiresAt: now.addingTimeInterval(lifetime),
                           scopes: scopes,
                           clientID: clientID)
    }

    /// Pulls the authorization code out of the redirect, checking the state matches.
    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw CalendarSyncError.cancelled }
            throw CalendarSyncError.server(400, value("error_description") ?? error)
        }
        guard value("state") == expectedState, let code = value("code"), !code.isEmpty else {
            throw CalendarSyncError.invalidResponse
        }
        return code
    }
}

// MARK: - A Google API that isn't turned on

nonisolated enum GoogleAPIProblem {
    /// The name of the Google API that isn't turned on in the person's Google Cloud project, when
    /// that is what a 403 says ("SERVICE_DISABLED" / "accessNotConfigured"); nil otherwise.
    static func disabledService(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        let details = error["details"] as? [[String: Any]] ?? []
        let reasons = (error["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
            + details.compactMap { $0["reason"] as? String }
        guard reasons.contains("SERVICE_DISABLED") || reasons.contains("accessNotConfigured") else { return nil }
        let title = details.compactMap { ($0["metadata"] as? [String: Any])?["serviceTitle"] as? String }.first
        return title ?? "The Google API LP needs"
    }
}

// MARK: - Slow down

/// A service saying "too many requests". Google, Microsoft and GitHub limit how often an app may
/// call them and say when it may call again; LP waits that long instead of trying sooner — at most
/// an hour, so a wrong header can't stop syncing for a day.
nonisolated enum RateLimit {
    /// How long to wait when a service asks LP to slow down without saying for how long.
    static let defaultWait: TimeInterval = 60
    static let longestWait: TimeInterval = 60 * 60

    /// When LP may call again, if this response asks it to slow down; nil if it doesn't. `header`
    /// looks a response header up by name, whatever its case.
    static func retryDate(status: Int, header: (String) -> String?, body: Data, now: Date = Date()) -> Date? {
        let retryAfter = header("Retry-After").flatMap { seconds(from: $0, now: now) }
        let allowanceUsed = header("X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespaces) == "0"
        let limited: Bool
        switch status {
        case 429:
            limited = true
        case 403:
            // GitHub sends Retry-After with its short-term limits and "remaining: 0" when the hour's
            // allowance is used up; Google names the limit in the error. Any other 403 is a real
            // "not allowed".
            limited = retryAfter != nil || allowanceUsed || isGoogleRateLimit(body) || isGitHubRateLimit(body)
        case 503:
            // Microsoft sometimes slows apps down with a 503 and Retry-After; without it, it's an outage.
            limited = retryAfter != nil
        default:
            limited = false
        }
        guard limited else { return nil }
        var wait = retryAfter ?? defaultWait
        if retryAfter == nil, allowanceUsed,
           let reset = header("X-RateLimit-Reset").flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) {
            wait = reset - now.timeIntervalSince1970
        }
        return now.addingTimeInterval(min(max(wait, 1), longestWait))
    }

    /// The seconds in a Retry-After value: a number of seconds, or an HTTP date.
    static func seconds(from value: String, now: Date) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return seconds.isFinite ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed).map { $0.timeIntervalSince(now) }
    }

    /// Google's way of saying "too many": a 403 whose reason is a rate limit.
    static func isGoogleRateLimit(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return false }
        if error["status"] as? String == "RESOURCE_EXHAUSTED" { return true }
        let reasons = (error["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        return reasons.contains { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" }
    }

    /// GitHub's way of saying "too many" without a time: a message naming a rate limit ("You have
    /// exceeded a secondary rate limit…", "API rate limit exceeded…"). GitHub asks for at least a
    /// minute's wait then.
    static func isGitHubRateLimit(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["message"] as? String else { return false }
        return message.range(of: "rate limit", options: .caseInsensitive) != nil
    }
}

/// "Wait until …", kept by who was asked — one calendar account, one GitHub token. Every request
/// for that key checks it first, so nothing at all is sent before then (not the next page of a sync
/// under way, not a change), and a later answer with a shorter wait never shortens it.
@MainActor
enum ServicePause {
    private static var waits: [String: Date] = [:]

    /// The wait for `key`, if it isn't over.
    static func until(_ key: String, now: Date = Date()) -> Date? {
        guard let date = waits[key], date > now else { return nil }
        return date
    }

    /// A short, stable name for a secret (a token), to keep waits apart per credential without
    /// keeping the secret itself: the first 8 bytes of its SHA-256, in hex.
    nonisolated static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Records a "wait until" for `key`, and returns the wait that applies (the later one).
    @discardableResult
    static func record(_ key: String, until date: Date, now: Date = Date()) -> Date {
        let kept = until(key, now: now).map { max($0, date) } ?? date
        waits[key] = kept
        return kept
    }
}
