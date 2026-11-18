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
}

nonisolated struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    func isFresh(at now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) > 60
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
    /// previous one is kept.
    static func tokens(from data: Data, previousRefreshToken: String?, now: Date = Date()) throws -> OAuthTokens {
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
        return OAuthTokens(accessToken: access,
                           refreshToken: json["refresh_token"] as? String ?? previousRefreshToken,
                           expiresAt: now.addingTimeInterval(lifetime))
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
