//
//  Updater.swift
//  Local Productivity
//
//  Finds, downloads and installs new versions of LP from its GitHub Releases (see UpdateCore).
//  Checks once a day while LP runs (if allowed) and whenever the person asks; nothing is installed
//  without their click. What goes over the network: a request to GitHub's public API with LP's
//  version in the User-Agent — no account, no identifier — and, for an update, its files.
//

import AppKit
import Foundation

@Observable
final class Updater {

    struct Offer: Equatable {
        let manifest: UpdateManifest
        let notes: String
        let page: URL
        let zipURL: URL
        let manifestData: Data
        let signatureData: Data
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Offer)
        case downloading(Offer, fraction: Double)
        case installing(Offer)
        /// Installed, but LP couldn't restart by itself (a page couldn't be closed): reopen to finish.
        case installed(Offer)
        case failed(String, page: URL?)
    }

    private(set) var phase: Phase = .idle
    /// Bumped when the update window should come forward (an automatic check found something, or
    /// the person chose Check for Updates…). RootView opens the window when it changes.
    private(set) var presentRequests = 0

    var checksAutomatically: Bool { didSet { defaults?.set(checksAutomatically, forKey: Keys.automatic) } }
    var includesBetas: Bool { didSet { defaults?.set(includesBetas, forKey: Keys.betas) } }
    private(set) var lastCheck: Date?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var work: Task<Void, Never>?

    private enum Keys {
        static let automatic = "updates.automatic"
        static let betas = "updates.betas"
        static let lastCheck = "updates.lastCheck"
        static let lastAttempt = "updates.lastAttempt"
        static let pausedUntil = "updates.pausedUntil"
        static let skipped = "updates.skippedTag"
    }

    /// `defaults` nil (snapshots, tests): never checks by itself.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        checksAutomatically = defaults?.object(forKey: Keys.automatic) as? Bool ?? true
        includesBetas = defaults?.bool(forKey: Keys.betas) ?? false
        lastCheck = defaults?.object(forKey: Keys.lastCheck) as? Date
        guard defaults != nil else { return }
        // A little after launch, then hourly: a check happens when the last one is a day old.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LP_UPDATE_AUTOINSTALL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.autoInstallForTesting() }
        }
        #endif
    }

    // MARK: What is running

    static var current: BuildIdentity {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = AppVersion(info["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0.0.0")!
        return BuildIdentity(version: version, build: BuildIdentity.buildNumber(info["CFBundleVersion"] as? String ?? ""))
    }

    static var currentDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "LP \(version) (\(build))"
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: Checking

    private func checkIfDue() {
        // Failed attempts count too: an automatic check happens at most once a day either way.
        let lastAttempt = defaults?.object(forKey: Keys.lastAttempt) as? Date
        guard checksAutomatically, !isBusy, UpdatePolicy.checkIsDue(lastCheck: lastAttempt ?? lastCheck, now: Date()) else { return }
        if case .available = phase { return }
        if case .installed = phase { return }
        work = Task { await check(userInitiated: false) }
    }

    /// LP → Check for Updates…, or Check Now in Settings.
    func checkNow() {
        presentRequests += 1
        guard !isBusy else { return }
        work = Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        // GitHub asked LP to wait: nothing is sent before then.
        if let until = pausedUntil {
            phase = userInitiated
                ? .failed("GitHub asked LP to wait before checking again. Try again after \(until.formatted(date: .omitted, time: .shortened)).", page: UpdateFeed.releasesPage)
                : .idle
            return
        }
        phase = .checking
        defaults?.set(Date(), forKey: Keys.lastAttempt)
        do {
            let offer = try await findOffer()
            lastCheck = Date()
            defaults?.set(lastCheck, forKey: Keys.lastCheck)
            guard let offer else {
                phase = userInitiated ? .upToDate : .idle
                return
            }
            // A version the person skipped is offered again only when they ask.
            if !userInitiated, defaults?.string(forKey: Keys.skipped) == offer.manifest.tag {
                phase = .idle
                return
            }
            phase = .available(offer)
            if !userInitiated { presentRequests += 1 }
        } catch {
            // Automatic checks fail quietly and try again later; asked-for ones say why.
            phase = userInitiated ? .failed((error as? UpdateError)?.message ?? error.localizedDescription, page: UpdateFeed.releasesPage) : .idle
        }
    }

    private func findOffer() async throws -> Offer? {
        let releases: [GitHubRelease]
        do {
            releases = try JSONDecoder().decode([GitHubRelease].self, from: try await fetch(Self.feedURL, limit: 4 * 1024 * 1024, api: true))
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError(message: "LP couldn’t read GitHub’s list of releases. Try again later.")
        }
        let current = Self.current
        var unverified = false
        // Newest first. A release LP can't verify (signed with a key this version doesn't know yet,
        // or not at all) is passed over, so an older release that is signed — the one that adds a
        // new key, say — can still be found; one this Mac's macOS can't run, too. The first newer
        // release that passes wins; the first verified one that isn't newer ends the search.
        for release in UpdatePolicy.candidates(releases, includeBetas: includesBetas) {
            guard let manifestFile = release.asset(named: UpdateFeed.manifestName),
                  let signatureFile = release.asset(named: UpdateFeed.signatureName),
                  let zip = release.asset(named: release.zipName) else { continue }
            let manifestData = try await fetch(manifestFile.url, limit: 16 * 1024)
            let signatureData = try await fetch(signatureFile.url, limit: 1024)
            guard let manifest = UpdateSignature.verifiedManifest(manifestData, signature: signatureData, keys: Self.keys),
                  manifest.tag == release.tagName, manifest.size == zip.size else {
                unverified = true
                continue
            }
            guard UpdatePolicy.isNewer(manifest, than: current) else { break }
            guard UpdatePolicy.runs(manifest, on: ProcessInfo.processInfo.operatingSystemVersion) else { continue }
            return Offer(manifest: manifest, notes: release.body ?? "", page: UpdateFeed.releasePage(tag: manifest.tag),
                         zipURL: zip.url, manifestData: manifestData, signatureData: signatureData)
        }
        if unverified {
            throw UpdateError(message: "A newer release on GitHub isn’t signed by LP’s release key, so LP won’t install it.")
        }
        return nil
    }

    private static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "LP/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"]
        return URLSession(configuration: configuration)
    }

    /// Reads at most `limit` bytes; anything longer isn't what LP expects and is abandoned early.
    private func fetch(_ url: URL, limit: Int, api: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        if api { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, received) = try await Self.session.bytes(for: request)
            response = received
            if received.expectedContentLength > Int64(limit) { throw UpdateError(message: "GitHub sent more than LP expected. Try again later.") }
            var chunk = [UInt8]()
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 * 1024 { data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
                if data.count + chunk.count > limit { throw UpdateError(message: "GitHub sent more than LP expected. Try again later.") }
            }
            data.append(contentsOf: chunk)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError(message: "LP couldn’t reach GitHub to check for updates. Check your internet connection and try again.")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 403, 429:
            throw pause(after: http)
        case 404: throw UpdateError(message: "LP’s releases can’t be found on GitHub right now.")
        default: throw UpdateError(message: "GitHub answered with an error (\(status)). Try again later.")
        }
    }

    /// GitHub asked LP to slow down: nothing goes to it before its time (Retry-After, or when the
    /// hourly allowance resets; else an hour — between a minute and a day).
    private func pause(after response: HTTPURLResponse?) -> UpdateError {
        let now = Date()
        var until = now.addingTimeInterval(3600)
        if let seconds = response?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
            until = now.addingTimeInterval(seconds)
        } else if let reset = response?.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) {
            until = Date(timeIntervalSince1970: reset)
        }
        until = min(max(until, now.addingTimeInterval(60)), now.addingTimeInterval(24 * 3600))
        defaults?.set(until, forKey: Keys.pausedUntil)
        return UpdateError(message: "GitHub asked LP to wait. Try again after \(until.formatted(date: .omitted, time: .shortened)).")
    }

    private var pausedUntil: Date? {
        (defaults?.object(forKey: Keys.pausedUntil) as? Date).flatMap { $0 > Date() ? $0 : nil }
    }

    // MARK: Choosing

    func skip() {
        if case .available(let offer) = phase { defaults?.set(offer.manifest.tag, forKey: Keys.skipped) }
        phase = .idle
    }

    func later() {
        if case .available = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
        if case .upToDate = phase { phase = .idle }
    }

    // MARK: Installing

    /// Downloads the offer, has the helper check and install it, then restarts LP (quitting the
    /// usual way, which saves everything first).
    func install() {
        guard case .available(let offer) = phase else { return }
        // The sandbox can't see whether LP's folder is writable; the helper checks that itself.
        if let problem = InstallLocation.problem(appPath: Bundle.main.bundleURL.path, folderIsWritable: true) {
            phase = .failed(problem.message, page: offer.page)
            return
        }
        work = Task { await download(offer) }
    }

    private func download(_ offer: Offer) async {
        if let until = pausedUntil {
            phase = .failed("GitHub asked LP to wait. Try again after \(until.formatted(date: .omitted, time: .shortened)).", page: offer.page)
            return
        }
        phase = .downloading(offer, fraction: 0)
        // Kept in LP's own temporary folder until the helper has copied it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LP Update", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let zip = folder.appendingPathComponent(offer.manifest.zip)
        let transfer = BoundedDownload(url: offer.zipURL, to: zip, limit: offer.manifest.size)
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(offer, fraction: transfer.fraction)
            }
        }
        let outcome = await transfer.run()
        poll.cancel()
        switch outcome {
        case .finished:
            break
        case .slowDown(let response):
            phase = .failed(pause(after: response).message, page: offer.page)
            try? FileManager.default.removeItem(at: folder)
            return
        case .failed(let message):
            phase = .failed(message, page: offer.page)
            try? FileManager.default.removeItem(at: folder)
            return
        }
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        guard let digest = UpdateSignature.sha256(ofFileAt: zip), digest.hex == offer.manifest.sha256, digest.size == offer.manifest.size else {
            phase = .failed("The download doesn’t match LP’s signed release, so it wasn’t installed. Try again.", page: offer.page)
            return
        }

        phase = .installing(offer)
        if let problem = await Self.installWithHelper(zip: zip, offer: offer) {
            #if DEBUG
            Self.testLog("helper: \(problem)")
            #endif
            phase = .failed(problem, page: offer.page)
            return
        }
        #if DEBUG
        Self.testLog("installed, relaunching")
        #endif
        relaunch(offer)
    }

    private static func installWithHelper(zip: URL, offer: Offer) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once(continuation)
            let connection = NSXPCConnection(serviceName: UpdateInstallerService.name)
            connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.finish("LP’s update helper couldn’t be started: \(error.localizedDescription)")
                connection.invalidate()
            } as? UpdateInstallerProtocol
            guard let proxy else {
                once.finish("LP’s update helper couldn’t be started.")
                connection.invalidate()
                return
            }
            proxy.install(zipPath: zip.path, manifest: offer.manifestData, signature: offer.signatureData, testKeys: testKeys) { problem in
                once.finish(problem)
                connection.invalidate()
            }
        }
    }

    /// The new LP is in place: start it (it waits for this one to end, and gives up if this one
    /// stays), then quit the usual way — which saves everything and may still be cancelled (a page
    /// that can't be saved or kept stays open). Then LP simply keeps running, and the new version
    /// starts next time.
    private func relaunch(_ offer: Offer) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [UpdateRelaunch.argument, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                self.phase = .installed(offer)
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Test switches (Debug builds only)

    private static var feedURL: URL {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["LP_UPDATE_FEED"], let url = URL(string: feed) { return url }
        #endif
        return UpdateFeed.releasesURL
    }

    private static var testKeys: [String] {
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["LP_UPDATE_TEST_KEY"] { return [key] }
        #endif
        return []
    }

    private static var keys: [String] { UpdateFeed.publicKeys + testKeys }

    #if DEBUG
    /// The harness's `update-demo:<state>`: the window in that state, with a sample release.
    func showDemo(_ state: String) {
        let manifest = UpdateManifest(schema: 1, bundleID: UpdateFeed.bundleID, tag: "v1.0.2-beta.1", version: "1.0.2", build: "202612011200",
                                      prerelease: true, zip: "LP-1.0.2-beta.1.zip", size: 6_100_000, sha256: String(repeating: "0", count: 64), minimumSystem: "15.0")
        let notes = "**New:** update LP from inside the app — LP → Check for Updates…\n\n- Boards: faster with hundreds of cards\n- Calendar: week view\n- Fixes: a shared page could miss a change made just before leaving a board"
        let offer = Offer(manifest: manifest, notes: notes, page: UpdateFeed.releasesPage, zipURL: UpdateFeed.releasesPage, manifestData: Data(), signatureData: Data())
        switch state {
        case "checking": phase = .checking
        case "uptodate": phase = .upToDate
        case "downloading": phase = .downloading(offer, fraction: 0.42)
        case "installed": phase = .installed(offer)
        case "failed": phase = .failed("LP couldn’t reach GitHub to check for updates. Check your internet connection and try again.", page: UpdateFeed.releasesPage)
        default: phase = .available(offer)
        }
        presentRequests += 1
    }

    /// End-to-end tests read what happened from LP's temporary folder.
    static func testLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["LP_UPDATE_AUTOINSTALL"] == "1" else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LP-update-test.log")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// LP_UPDATE_AUTOINSTALL=1: check, and install whatever is found without asking (end-to-end tests).
    private func autoInstallForTesting() {
        work = Task {
            await check(userInitiated: true)
            Self.testLog("after check: \(phase)")
            guard case .available = phase else { return }
            install()
        }
    }
    #endif
}

struct UpdateError: Error { let message: String }

/// Downloads into a file on URLSession's own queue, stopping the moment it passes `limit` bytes
/// (the signed size) — whatever the main thread is doing.
private final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome { case finished, slowDown(HTTPURLResponse), failed(String) }

    private let url: URL
    private let destination: URL
    private let limit: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var received = 0
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(url: URL, to destination: URL, limit: Int) {
        self.url = url
        self.destination = destination
        self.limit = limit
    }

    var fraction: Double {
        lock.lock(); defer { lock.unlock() }
        return limit > 0 ? min(1, Double(received) / Double(limit)) : 0
    }

    func run() async -> Outcome {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { return .failed("The download couldn’t be saved.") }
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            return .failed("The download couldn’t be saved.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "LP/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            session.dataTask(with: url).resume()
        }
    }

    /// Records the first outcome; the task finishing then hands it back.
    private func settle(_ value: Outcome) {
        lock.lock(); if outcome == nil { outcome = value }; lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            if response.expectedContentLength > Int64(limit) {
                settle(.failed("The download is bigger than LP’s signed release, so it was stopped."))
                return .cancel
            }
            return .allow
        case 403, 429:
            if let http { settle(.slowDown(http)) }
            return .cancel
        default:
            settle(.failed("The download failed (\(http?.statusCode ?? 0)). Try again later."))
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received += data.count
        let tooBig = received > limit
        lock.unlock()
        if tooBig {
            settle(.failed("The download is bigger than LP’s signed release, so it was stopped."))
            dataTask.cancel()
            return
        }
        do { try handle?.write(contentsOf: data) } catch {
            settle(.failed("The download couldn’t be saved."))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        if error != nil { settle(.failed("The download failed. Check your internet connection and try again.")) }
        settle(.finished)
        lock.lock()
        let result = outcome ?? .finished
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: result)
    }
}

/// Resumes a continuation once, whichever of the helper's answers comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func finish(_ value: String?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

/// A new LP started by an update waits for the old one to quit before opening anything.
enum UpdateRelaunch {
    static let argument = "-LPRelaunchAfter"

    static func waitForPreviousInstance() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count,
              let pid = pid_t(arguments[index + 1]), pid != ProcessInfo.processInfo.processIdentifier else { return }
        // Up to two minutes (quitting may ask about a page first). If the old LP is still running
        // then, its quit was cancelled: this copy leaves before opening anything, so two LPs never
        // work on the same workspace.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard let old = NSRunningApplication(processIdentifier: pid), !old.isTerminated else { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        exit(0)
    }
}
