//
//  main.swift
//  LPUpdateInstaller
//
//  LP's update helper: an XPC service inside LP.app, outside the sandbox, so it can put a new
//  version of LP in place of the one it lives in. It trusts nothing LP sends: it checks the
//  signed update.json itself, copies the zip before checking it, and checks the app inside it
//  (bundle ID, version, build, code signature) before swapping it in. Only LP can connect.
//

import Foundation
import Security

final class Installer: NSObject, UpdateInstallerProtocol {

    /// One install at a time.
    private static let queue = DispatchQueue(label: "LTF.Local-Productivity.UpdateInstaller.install")

    func install(zipPath: String, manifest: Data, signature: Data, testKeys: [String],
                 reply: @escaping @Sendable (String?) -> Void) {
        Self.queue.async {
            reply(Self.run(zipPath: zipPath, manifest: manifest, signature: signature, testKeys: testKeys))
        }
    }

    private struct Failure: Error { let message: String }

    private static func run(zipPath: String, manifest manifestData: Data, signature: Data, testKeys: [String]) -> String? {
        let fileManager = FileManager.default
        var staging: URL?
        defer { if let staging { try? fileManager.removeItem(at: staging) } }
        do {
            var keys = UpdateFeed.publicKeys
            #if DEBUG
            keys += testKeys
            #endif
            guard let manifest = UpdateSignature.verifiedManifest(manifestData, signature: signature, keys: keys) else {
                throw Failure(message: "The update isn't signed by LP's release key, so it wasn't installed.")
            }

            // The app to replace is the one this helper is inside: …/LP.app/Contents/XPCServices/<helper>.xpc
            let helper = Bundle.main.bundleURL.standardizedFileURL
            let services = helper.deletingLastPathComponent()
            let contents = services.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            // Read from disk every time — Bundle caches Info.plist, and an earlier install in this
            // same helper may have changed it.
            guard services.lastPathComponent == "XPCServices", contents.lastPathComponent == "Contents",
                  let installedInfo = infoPlist(of: app), installedInfo["CFBundleIdentifier"] as? String == UpdateFeed.bundleID,
                  let installedVersion = AppVersion(installedInfo["CFBundleShortVersionString"] as? String ?? "") else {
                throw Failure(message: InstallLocation.Problem.notAnApp.message)
            }
            // Never an older (or the same) release, even one signed by LP: a replayed old version could
            // bring back old bugs. And never one this Mac's macOS can't run.
            // A missing or damaged build number would count as 0 and let anything in: refuse instead.
            let installedBuild = BuildIdentity.buildNumber(installedInfo["CFBundleVersion"] as? String ?? "")
            guard installedBuild > 0 else {
                throw Failure(message: "LP couldn’t read its own version, so the update wasn’t installed. Download it from GitHub instead.")
            }
            let installed = BuildIdentity(version: installedVersion, build: installedBuild)
            guard UpdatePolicy.isNewer(manifest, than: installed) else {
                throw Failure(message: "This update isn't newer than the LP you have, so it wasn't installed.")
            }
            guard UpdatePolicy.runs(manifest, on: ProcessInfo.processInfo.operatingSystemVersion) else {
                throw Failure(message: "This update needs a newer version of macOS.")
            }
            let folder = app.deletingLastPathComponent()
            if let problem = InstallLocation.problem(appPath: app.path, folderIsWritable: fileManager.isWritableFile(atPath: folder.path)) {
                throw Failure(message: problem.message)
            }

            // A private copy of the download, on the same disk as the app, checked after copying.
            let workspace = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            staging = workspace
            // Read through one descriptor opened without following links, so the file can't be swapped
            // between the check and the copy; only the private copy is used from here on.
            let zip = workspace.appendingPathComponent("update.zip")
            guard copyRegularFile(atPath: zipPath, to: zip.path, limit: manifest.size) else {
                throw Failure(message: "The downloaded update couldn't be read.")
            }
            guard let digest = UpdateSignature.sha256(ofFileAt: zip), digest.size == manifest.size, digest.hex == manifest.sha256 else {
                throw Failure(message: "The downloaded update doesn't match what LP's release says, so it wasn't installed. Try again.")
            }

            // Unpack it: exactly one LP.app, a real folder.
            let unpacked = workspace.appendingPathComponent("unpacked")
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: false)
            guard runTool("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, unpacked.path]) else {
                throw Failure(message: "The update couldn't be unpacked.")
            }
            let items = try fileManager.contentsOfDirectory(atPath: unpacked.path).filter { $0 != "__MACOSX" }
            let newApp = unpacked.appendingPathComponent("LP.app")
            let newValues = try? newApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard items == ["LP.app"], newValues?.isDirectory == true, newValues?.isSymbolicLink != true else {
                throw Failure(message: "The update doesn't contain LP.")
            }

            // The app inside is LP, exactly the version and build that were signed, and intact.
            let info = infoPlist(of: newApp) ?? [:]
            guard info["CFBundleIdentifier"] as? String == UpdateFeed.bundleID,
                  info["CFBundleShortVersionString"] as? String == manifest.version,
                  info["CFBundleVersion"] as? String == manifest.build else {
                throw Failure(message: "The app in the update isn't the version LP's release says it is, so it wasn't installed.")
            }
            guard codeSignatureIsValid(newApp) else {
                throw Failure(message: "The app in the update failed macOS's signature check, so it wasn't installed.")
            }
            // Checked: macOS needn't ask about it again (the same thing Sparkle-style updaters do).
            _ = runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            // Swap it in, keeping the app's place and name.
            _ = try fileManager.replaceItemAt(app, withItemAt: newApp, backupItemName: nil, options: [])
            return nil
        } catch let failure as Failure {
            return failure.message
        } catch {
            return "The update couldn't be installed: \(error.localizedDescription)"
        }
    }

    /// An app's Info.plist, read from disk now (never a cached copy).
    private static func infoPlist(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist
    }

    /// Copies a regular file (never a link) into a new file only this helper created, at most
    /// `limit` bytes — more means it isn't the signed zip.
    private static func copyRegularFile(atPath source: String, to destination: String, limit: Int) -> Bool {
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { return false }
        defer { close(input) }
        var status = stat()
        guard fstat(input, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, Int(status.st_size) == limit else { return false }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return false }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 { return false }
            if count == 0 { break }
            total += count
            if total > limit { return false }
            var written = 0
            while written < count {
                let n = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                if n <= 0 { return false }
                written += n
            }
        }
        return total == limit
    }

    private static func codeSignatureIsValid(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"\(UpdateFeed.bundleID)\"" as CFString, [], &requirement) == errSecSuccess
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    private static func runTool(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only LP itself may ask for an install.
        connection.setCodeSigningRequirement("identifier \"\(UpdateFeed.bundleID)\"")
        connection.exportedInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
        connection.exportedObject = Installer()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
