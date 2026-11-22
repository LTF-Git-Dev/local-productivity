//
//  BuiltInRegistration.swift
//  LP
//
//  LP's own app registrations with Google and Microsoft, so people connect with one click instead
//  of registering an app themselves. A desktop app's client ID is a public identifier, not a
//  secret — anyone can read it in the app — which is why every sign-in uses PKCE (it proves the
//  sign-in was started here) and there is no client secret anywhere. Someone who prefers their own
//  registration (a fork, an organisation, or simply by choice) sets their own client ID under
//  Advanced in Settings → Calendars; tokens remember which registration issued them.
//  Nil until LP is registered: then only your own client ID can be used.
//

import Foundation

nonisolated enum BuiltInRegistration {
    /// LP's Google client ID: an "iOS" OAuth client for bundle ID LTF.Local-Productivity.
    static let shippedGoogleClientID: String? = "11527194109-7ldm5pdjlii56tg31pbaaarpvglmofcb.apps.googleusercontent.com"
    /// LP's Microsoft Entra application (client) ID: personal and work accounts, the "iOS / macOS"
    /// platform for bundle ID LTF.Local-Productivity.
    static let shippedMicrosoftClientID: String? = nil

    /// True while Google reviews LP. Until then LP doesn't use its Google registration: Google would
    /// warn "unverified app" and cap it at 100 people ever. Set false in the first build after
    /// Google approves.
    static let googleAwaitingReview = true

    static var googleClientID: String? {
        demo("000000000000-lpdemo.apps.googleusercontent.com") ?? (googleAwaitingReview ? nil : shippedGoogleClientID)
    }
    static var microsoftClientID: String? { demo("00000000-0000-0000-0000-000000000001") ?? shippedMicrosoftClientID }

    /// Debug builds only: `LP_DEMO_REGISTRATION=1` shows LP as if it were registered (for snapshots
    /// of the one-click screens; a sign-in with these IDs would fail).
    private static func demo(_ clientID: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LP_DEMO_REGISTRATION"] == "1" ? clientID : nil
        #else
        return nil
        #endif
    }
}
