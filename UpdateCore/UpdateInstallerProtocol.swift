//
//  UpdateInstallerProtocol.swift
//  Local Productivity
//
//  How LP talks to its LPUpdateInstaller helper (an XPC service inside LP.app). LP itself runs in
//  Apple's sandbox and can't replace its own app; the helper can, and does so only for an update
//  it has checked itself: signed by LP's release key, the zip matching byte for byte, the app inside
//  it LP's own, of exactly that version and build, with a valid code signature.
//

import Foundation

nonisolated enum UpdateInstallerService {
    static let name = "LTF.Local-Productivity.UpdateInstaller"
}

@objc nonisolated protocol UpdateInstallerProtocol {
    /// Replaces the LP.app the helper is inside with the app in `zipPath`.
    /// - Parameters:
    ///   - zipPath: the downloaded `LP-<version>.zip` (the helper copies it before checking it).
    ///   - manifest: update.json's bytes, exactly as downloaded.
    ///   - signature: update.json.sig's bytes.
    ///   - testKeys: extra public keys, honoured only by Debug builds (end-to-end tests).
    ///   - reply: nil when the new app is in place, else what went wrong, in a sentence for people.
    func install(zipPath: String, manifest: Data, signature: Data, testKeys: [String],
                 reply: @escaping @Sendable (String?) -> Void)
}
