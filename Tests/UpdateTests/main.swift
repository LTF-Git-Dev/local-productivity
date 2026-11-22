//
//  Update tests.
//
//  Run with `Scripts/test.sh`. Covers UpdateCore: version and tag order, which releases are offered
//  (betas only when asked for), the signed update.json (only LP's key, exact bytes, consistent
//  fields), the zip's checksum, and where LP can update itself.
//

import CryptoKit
import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("✗ line \(line): \(message())")
    }
}

// MARK: Versions and tags

check(AppVersion("1.0.1")! < AppVersion("1.0.2")!, "patch order")
check(AppVersion("1.0.10")! > AppVersion("1.0.9")!, "numbers, not text")
check(AppVersion("1.1")! == AppVersion("1.1.0")!, "missing parts are zero")
check(AppVersion("1.0.0-beta.1") == nil && AppVersion("") == nil && AppVersion("1..2") == nil && AppVersion("a.b.c") == nil,
      "not versions")
check(AppVersion("1.0.1234567") == nil, "absurdly long parts are refused")

let v101 = AppVersion("1.0.1")!
check(BuildIdentity(version: v101, build: 5) < BuildIdentity(version: v101, build: 6), "same version: higher build is newer")
check(BuildIdentity(version: v101, build: 999) < BuildIdentity(version: AppVersion("1.0.2")!, build: 1), "version beats build")
check(BuildIdentity.buildNumber("202611211530") == 202611211530, "a timestamp build")
check(BuildIdentity.buildNumber("3a") == 0 && BuildIdentity.buildNumber("") == 0, "odd builds count as 0")

check(ReleaseTag("v1.0.1-beta.1")! < ReleaseTag("v1.0.1-beta.2")!, "beta order")
check(ReleaseTag("v1.0.1-beta.9")! < ReleaseTag("v1.0.1")!, "official after its betas")
check(ReleaseTag("v1.0.1")! < ReleaseTag("v1.0.2-beta.1")!, "a newer version's beta after an older official")
check(ReleaseTag("1.0.1") == nil && ReleaseTag("v1.0") == nil && ReleaseTag("v1.0.1-rc.1") == nil
      && ReleaseTag("v1.0.1-beta.0") == nil && ReleaseTag("v1.0.1-beta.x") == nil, "not LP tags")

// MARK: Signed manifests

let key = Curve25519.Signing.PrivateKey()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
let otherKey = Curve25519.Signing.PrivateKey()

func manifest(tag: String = "v1.0.2-beta.1", version: String = "1.0.2", build: String = "202611211530",
              prerelease: Bool = true, zip: String? = nil, size: Int = 6_000_000,
              sha: String = String(repeating: "ab", count: 32), bundle: String = "LTF.Local-Productivity",
              system: String = "15.0") -> UpdateManifest {
    UpdateManifest(schema: 1, bundleID: bundle, tag: tag, version: version, build: build, prerelease: prerelease,
                   zip: zip ?? "LP-\(tag.dropFirst()).zip", size: size, sha256: sha, minimumSystem: system)
}

func signed(_ m: UpdateManifest, with signer: Curve25519.Signing.PrivateKey = key) -> (Data, Data) {
    let data = try! JSONEncoder().encode(m)
    let signature = try! signer.signature(for: data).base64EncodedString() + "\n"
    return (data, Data(signature.utf8))
}

let good = manifest()
let (goodData, goodSignature) = signed(good)
check(UpdateSignature.verifiedManifest(goodData, signature: goodSignature, keys: [publicKey]) == good, "a signed manifest is read")
check(UpdateSignature.verifiedManifest(goodData, signature: goodSignature, keys: ["junk", publicKey]) == good, "a bad key in the list doesn't stop a good one")

let (_, foreignSignature) = signed(good, with: otherKey)
check(UpdateSignature.verifiedManifest(goodData, signature: foreignSignature, keys: [publicKey]) == nil, "another key's signature is refused")
check(UpdateSignature.verifiedManifest(goodData, signature: goodSignature, keys: []) == nil, "no keys, no update")

var tampered = goodData
tampered[tampered.index(tampered.startIndex, offsetBy: 20)] ^= 0x01
check(UpdateSignature.verifiedManifest(tampered, signature: goodSignature, keys: [publicKey]) == nil, "one changed byte is refused")
let reEncoded = try! JSONSerialization.data(withJSONObject: try! JSONSerialization.jsonObject(with: goodData), options: [.prettyPrinted])
check(UpdateSignature.verifiedManifest(reEncoded, signature: goodSignature, keys: [publicKey]) == nil, "the exact bytes are what's signed")
check(UpdateSignature.verifiedManifest(goodData, signature: Data("not base64".utf8), keys: [publicKey]) == nil, "a garbled signature is refused")

// Signed, but inconsistent: refused anyway.
let inconsistent: [(UpdateManifest, String)] = [
    (manifest(bundle: "com.example.Other"), "another app's bundle ID"),
    (manifest(version: "1.0.3"), "a version that isn't the tag's"),
    (manifest(prerelease: false), "a beta tag marked official"),
    (manifest(tag: "v1.0.2", prerelease: true), "an official tag marked beta"),
    (manifest(zip: "Evil.zip"), "a zip not named after the tag"),
    (manifest(size: 0), "an empty zip"),
    (manifest(size: 600 * 1024 * 1024), "a zip too big to be LP"),
    (manifest(sha: "xyz"), "a checksum that isn't SHA-256 hex"),
    (manifest(sha: String(repeating: "AB", count: 32)), "upper-case hex (deploy writes lower)"),
    (manifest(build: "abc"), "a build that isn't a number"),
    (manifest(tag: "1.0.2"), "a tag without the v"),
    (manifest(system: "fifteen"), "a minimum macOS that isn't a version"),
]
for (bad, why) in inconsistent {
    let (data, signature) = signed(bad)
    check(UpdateSignature.verifiedManifest(data, signature: signature, keys: [publicKey]) == nil, "refused: \(why)")
}

// MARK: Newer, and runs here

let running = BuildIdentity(version: v101, build: 202611200000)
check(UpdatePolicy.isNewer(manifest(), than: running), "1.0.2 beta over 1.0.1")
check(!UpdatePolicy.isNewer(manifest(tag: "v1.0.1", version: "1.0.1", build: "202611200000", prerelease: false), than: running),
      "the official release of the beta you have (same app) isn't offered")
check(UpdatePolicy.isNewer(manifest(tag: "v1.0.1-beta.2", version: "1.0.1", build: "202611210000"), than: running),
      "a newer beta of the same version is")
check(!UpdatePolicy.isNewer(manifest(tag: "v1.0.0", version: "1.0.0", prerelease: false), than: running), "never an older version")
check(UpdatePolicy.runs(manifest(system: "15.0"), on: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "15.0 on 15.0")
check(!UpdatePolicy.runs(manifest(system: "27.1"), on: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 3)), "27.1 not on 27.0.3")

// MARK: Which releases are looked at

func release(_ tag: String, prerelease: Bool? = nil, draft: Bool = false, files: [String]? = nil, url: String = "https://github.com/x") -> GitHubRelease {
    let names = files ?? ["LP-\(tag.dropFirst()).zip", "update.json", "update.json.sig"]
    let assets = names.map { "{\"name\":\"\($0)\",\"browser_download_url\":\"\(url)/\($0)\",\"size\":10,\"state\":\"uploaded\"}" }
    let json = "{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease ?? tag.contains("-beta.")),\"body\":\"Notes\",\"html_url\":\"https://github.com/x\",\"assets\":[\(assets.joined(separator: ","))]}"
    return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
}

let feed = [release("v1.0.1"), release("v1.0.2-beta.1"), release("v1.0.0"), release("v1.0.2-beta.2", draft: true)]
check(UpdatePolicy.candidates(feed, includeBetas: false).map(\.tagName) == ["v1.0.1", "v1.0.0"], "official only, newest first")
check(UpdatePolicy.candidates(feed, includeBetas: true).map(\.tagName) == ["v1.0.2-beta.1", "v1.0.1", "v1.0.0"], "betas when asked; drafts never")
check(UpdatePolicy.candidates([release("v1.0.3", prerelease: true)], includeBetas: true).isEmpty, "a pre-release with an official tag is skipped")
check(UpdatePolicy.candidates([release("v1.0.3-beta.1", prerelease: false)], includeBetas: true).isEmpty, "a beta tag published as Latest is skipped")
check(UpdatePolicy.candidates([release("v1.0.3", files: ["LP-1.0.3.zip", "update.json"])], includeBetas: false).isEmpty, "no signature, not a candidate")
check(UpdatePolicy.candidates([release("v1.0.3", files: ["LP-other.zip", "update.json", "update.json.sig"])], includeBetas: false).isEmpty, "no app zip, not a candidate")
check(UpdatePolicy.candidates([release("v1.0.3", url: "http://github.com/x")], includeBetas: false).isEmpty, "plain-http files are never used")
check(UpdatePolicy.candidates([release("latest")], includeBetas: true).isEmpty, "odd tags are ignored")

// MARK: When to check

let now = Date()
check(UpdatePolicy.checkIsDue(lastCheck: nil, now: now), "never checked: due")
check(!UpdatePolicy.checkIsDue(lastCheck: now.addingTimeInterval(-3600), now: now), "an hour ago: not due")
check(UpdatePolicy.checkIsDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now), "a day ago: due")
check(UpdatePolicy.checkIsDue(lastCheck: now.addingTimeInterval(3 * 86400), now: now), "a clock set back: due")

// MARK: The zip's checksum

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lp-update-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let file = folder.appendingPathComponent("LP.zip")
try! Data("hello".utf8).write(to: file)
let digest = UpdateSignature.sha256(ofFileAt: file)
check(digest?.hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" && digest?.size == 5, "SHA-256 of a file: \(String(describing: digest))")
check(UpdateSignature.sha256(ofFileAt: folder.appendingPathComponent("missing")) == nil, "a missing file has no checksum")
try? FileManager.default.removeItem(at: folder)

// MARK: Where LP can update itself

check(InstallLocation.problem(appPath: "/Applications/LP.app", folderIsWritable: true) == nil, "Applications, writable")
check(InstallLocation.problem(appPath: "/Applications/LP.app", folderIsWritable: false) == .notWritable, "a folder this user can't change")
check(InstallLocation.problem(appPath: "/private/var/folders/x/AppTranslocation/ABC/d/LP.app", folderIsWritable: true) == .translocated,
      "a translocated copy can't be updated")
check(InstallLocation.problem(appPath: "/Users/me/build/LP", folderIsWritable: true) == .notAnApp, "not an app bundle")

// MARK: The shipped key

check(UpdateFeed.publicKeys.allSatisfy { Data(base64Encoded: $0)?.count == 32 } && !UpdateFeed.publicKeys.isEmpty,
      "every shipped key is a 32-byte Ed25519 public key")
check(UpdateFeed.releasePage(tag: "v1.0.2-beta.1").absoluteString == "https://github.com/LTF-Git-Dev/local-productivity/releases/tag/v1.0.2-beta.1",
      "a release's page comes from its verified tag")
check(UpdateFeed.releasePage(tag: "javascript:alert(1)") == UpdateFeed.releasesPage && UpdateFeed.releasePage(tag: "v1.0.2/../../x") == UpdateFeed.releasesPage,
      "anything that isn't a tag falls back to the releases list")
check(UpdateFeed.releasesURL.absoluteString.hasPrefix("https://api.github.com/repos/LTF-Git-Dev/local-productivity/releases"), "LP's own releases")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
