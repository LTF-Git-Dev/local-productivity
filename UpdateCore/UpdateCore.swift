//
//  UpdateCore.swift
//  Local Productivity
//
//  What LP's updates are and how one is trusted — shared by the app (which finds and downloads an
//  update) and the LPUpdateInstaller helper (which checks it again and puts it in place).
//  Foundation and CryptoKit only, so the `updates` test suite can compile it.
//
//  Where updates come from: the GitHub Releases of LP's own repository. Every release made with
//  `Scripts/deploy.sh` carries three files: the app (`LP-<version>.zip`), `update.json` (its version,
//  build, size and SHA-256) and `update.json.sig` (an Ed25519 signature of update.json, made with
//  the release key kept in the owner's Keychain). An update is used only when its update.json is
//  signed by one of `UpdateFeed.publicKeys` and the zip matches it byte for byte — so neither
//  GitHub nor anything between it and the Mac can hand LP an app the owner didn't release.
//

import CryptoKit
import Foundation

nonisolated enum UpdateFeed {
    static let owner = "LTF-Git-Dev"
    static let repository = "local-productivity"
    static let bundleID = "LTF.Local-Productivity"

    /// The newest releases first (GitHub's order), drafts left out for anyone without access.
    static var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=30")!
    }
    static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    /// A release's page, built from its (verified) tag — never from what the feed says.
    static func releasePage(tag: String) -> URL {
        guard ReleaseTag(tag) != nil else { return releasesPage }
        return URL(string: "https://github.com/\(owner)/\(repository)/releases/tag/\(tag)")!
    }

    static let manifestName = "update.json"
    static let signatureName = "update.json.sig"

    /// The release key's public half (Ed25519, raw 32 bytes, base64). More than one may be listed
    /// so a key can be replaced: a new key is added in one version and the old one removed later.
    static let publicKeys: [String] = [
        "vm52euJoANfmMf3PXggjTxFP0Td1OYs4kb8mwDi1KZ4=",
    ]

    /// The longest an app zip may be; anything bigger isn't LP.
    static let maximumSize = 500 * 1024 * 1024
}

// MARK: - Versions

/// A version like 1.0.1 — the app's CFBundleShortVersionString.
nonisolated struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard (1...6).contains(piece.count), piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else { return nil }
            parts.append(value)
        }
        while parts.count < 3 { parts.append(0) }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for index in 0..<count {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// What an app build is: its version and its build number (CFBundleVersion). A beta and the
/// official release made from it are the same app, so they share both; a newer beta of the same
/// version has a higher build.
nonisolated struct BuildIdentity: Comparable, Sendable {
    let version: AppVersion
    let build: Int

    /// The build number: digits only (anything else counts as 0, older than any release).
    static func buildNumber(_ text: String) -> Int {
        guard (1...18).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return 0 }
        return Int(text) ?? 0
    }

    static func < (a: BuildIdentity, b: BuildIdentity) -> Bool {
        a.version != b.version ? a.version < b.version : a.build < b.build
    }
}

/// A release tag: v1.0.1 or v1.0.1-beta.2.
nonisolated struct ReleaseTag: Comparable, Sendable {
    let version: AppVersion
    /// The beta's number, or nil for an official release.
    let beta: Int?

    init?(_ tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        let body = tag.dropFirst()
        let halves = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let version = AppVersion(String(halves[0])), halves[0].split(separator: ".").count == 3 else { return nil }
        self.version = version
        if halves.count == 2 {
            let suffix = halves[1]
            guard suffix.hasPrefix("beta."), let n = Int(suffix.dropFirst(5)), n > 0,
                  suffix.dropFirst(5).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            beta = n
        } else {
            beta = nil
        }
    }

    var isBeta: Bool { beta != nil }

    /// An official release comes after every beta of its version.
    static func < (a: ReleaseTag, b: ReleaseTag) -> Bool {
        if a.version != b.version { return a.version < b.version }
        return (a.beta ?? Int.max) < (b.beta ?? Int.max)
    }
}

// MARK: - The release feed

/// One release as GitHub's API lists it (only the fields LP uses).
nonisolated struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: String
        let size: Int
        let state: String

        enum CodingKeys: String, CodingKey {
            case name, size, state
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let htmlURL: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    /// An uploaded file of this release, by name, with an https address.
    func asset(named name: String) -> (url: URL, size: Int)? {
        guard let asset = assets.first(where: { $0.name == name && $0.state == "uploaded" }),
              let url = URL(string: asset.browserDownloadURL), url.host != nil
        else { return nil }
        #if DEBUG
        // End-to-end tests serve a release from this Mac (LP_UPDATE_FEED).
        let local = url.scheme == "http" && url.host == "127.0.0.1"
        #else
        let local = false
        #endif
        guard url.scheme == "https" || local else { return nil }
        return (url, asset.size)
    }

    var zipName: String { "LP-\(tagName.dropFirst()).zip" }
}

nonisolated enum UpdatePolicy {

    /// The releases worth looking at, newest first: published, tagged like LP's releases, with
    /// all three update files, and betas only for someone who asked for them.
    static func candidates(_ releases: [GitHubRelease], includeBetas: Bool) -> [GitHubRelease] {
        releases
            .compactMap { release -> (GitHubRelease, ReleaseTag)? in
                guard !release.draft, let tag = ReleaseTag(release.tagName) else { return nil }
                // A release's own "pre-release" mark and its tag must agree.
                guard tag.isBeta == release.prerelease, includeBetas || !tag.isBeta else { return nil }
                guard release.asset(named: UpdateFeed.manifestName) != nil,
                      release.asset(named: UpdateFeed.signatureName) != nil,
                      release.asset(named: release.zipName) != nil else { return nil }
                return (release, tag)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Whether the signed update is newer than the running app.
    static func isNewer(_ manifest: UpdateManifest, than current: BuildIdentity) -> Bool {
        guard let identity = manifest.identity else { return false }
        return current < identity
    }

    /// Whether this Mac's macOS is new enough for it.
    static func runs(_ manifest: UpdateManifest, on system: OperatingSystemVersion) -> Bool {
        guard let needed = AppVersion(manifest.minimumSystem) else { return false }
        let have = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")!
        return !(have < needed)
    }

    /// Automatic checks happen at most once a day.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    static func checkIsDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back makes "last check" lie in the future: check rather than wait for it.
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }
}

// MARK: - The signed manifest

/// update.json: exactly which app a release is.
nonisolated struct UpdateManifest: Codable, Equatable, Sendable {
    var schema: Int
    var bundleID: String
    var tag: String
    var version: String
    var build: String
    var prerelease: Bool
    var zip: String
    var size: Int
    var sha256: String
    var minimumSystem: String

    var identity: BuildIdentity? {
        guard let version = AppVersion(version) else { return nil }
        let build = BuildIdentity.buildNumber(build)
        return build > 0 ? BuildIdentity(version: version, build: build) : nil
    }

    /// Everything in it is consistent: LP's bundle, a tag of LP's form whose version and beta mark
    /// match, the zip named after the tag, a real size and a SHA-256 in hex.
    var isWellFormed: Bool {
        guard schema == 1, bundleID == UpdateFeed.bundleID, let tag = ReleaseTag(tag), identity != nil,
              AppVersion(version) == tag.version, tag.isBeta == prerelease,
              zip == "LP-\(self.tag.dropFirst()).zip",
              (1...UpdateFeed.maximumSize).contains(size),
              sha256.count == 64, sha256.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }),
              AppVersion(minimumSystem) != nil
        else { return false }
        return true
    }
}

nonisolated enum UpdateSignature {

    /// The manifest, only if `signature` (base64 text) is a valid signature of exactly `manifest`'s
    /// bytes by one of `keys`, and what it says is well formed.
    static func verifiedManifest(_ manifest: Data, signature: Data, keys: [String]) -> UpdateManifest? {
        guard manifest.count <= 16 * 1024,
              let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text), raw.count == 64 else { return nil }
        let signed = keys.contains { key in
            guard let keyData = Data(base64Encoded: key), keyData.count == 32,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
            return publicKey.isValidSignature(raw, for: manifest)
        }
        guard signed, let decoded = try? JSONDecoder().decode(UpdateManifest.self, from: manifest),
              decoded.isWellFormed else { return nil }
        return decoded
    }

    /// The SHA-256 of a file, read in pieces, in lowercase hex — nil if it can't be read.
    static func sha256(ofFileAt url: URL) -> (hex: String, size: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            // nil (or empty) is the end of the file.
            guard let chunk, !chunk.isEmpty else { break }
            size += chunk.count
            if size > UpdateFeed.maximumSize { return nil }
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

// MARK: - Where LP is installed

nonisolated enum InstallLocation {

    enum Problem: Equatable, Sendable {
        /// macOS runs LP from a hidden read-only copy (it was opened straight from Downloads).
        case translocated
        /// Not an app bundle (a build folder, say).
        case notAnApp
        /// The folder LP is in can't be changed by this user.
        case notWritable

        var message: String {
            switch self {
            case .translocated:
                return "macOS is running LP from a temporary copy. Move LP into your Applications folder, open it from there, then check for updates again."
            case .notAnApp:
                return "LP isn't running from an app it can update."
            case .notWritable:
                return "Your Mac user can't change the folder LP is in. Download the update from GitHub instead, or ask an administrator."
            }
        }
    }

    static func problem(appPath: String, folderIsWritable: Bool) -> Problem? {
        if appPath.contains("/AppTranslocation/") { return .translocated }
        guard appPath.hasSuffix(".app") else { return .notAnApp }
        return folderIsWritable ? nil : .notWritable
    }
}
