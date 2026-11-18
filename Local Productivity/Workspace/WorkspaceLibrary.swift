//
//  WorkspaceLibrary.swift
//  Local Productivity
//
//  Remembers the folders that have been opened as workspaces. The app is sandboxed, so
//  a folder the user picked is only reachable after a relaunch through a security-scoped
//  bookmark; this is where those bookmarks are created, stored and resolved.
//

import Foundation

nonisolated struct WorkspaceRecord: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data?
    var lastOpened = Date()

    /// The path with the home folder abbreviated, for display.
    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

@Observable
final class WorkspaceLibrary {

    /// Most recently opened first.
    private(set) var records: [WorkspaceRecord] = []

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]

    private static let storageKey = "workspaces.v1"
    private static let lastOpenKey = "workspaces.lastOpen"

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([WorkspaceRecord].self, from: data) {
            records = decoded.sorted { $0.lastOpened > $1.lastOpened }
        }
    }

    /// The workspace that was open when the app last quit.
    var lastOpenRecord: WorkspaceRecord? {
        guard let text = defaults?.string(forKey: Self.lastOpenKey), let id = UUID(uuidString: text) else { return nil }
        return records.first { $0.id == id }
    }

    func setLastOpen(_ record: WorkspaceRecord?) {
        defaults?.set(record?.id.uuidString, forKey: Self.lastOpenKey)
    }

    /// Records a folder the user has just chosen. The URL must come straight from the open panel
    /// so that it still carries the access needed to create a bookmark.
    @discardableResult
    func register(_ url: URL) -> WorkspaceRecord {
        let standardized = url.standardizedFileURL
        let bookmark = try? standardized.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)

        var record = records.first { $0.path == standardized.path }
            ?? WorkspaceRecord(name: standardized.lastPathComponent, path: standardized.path)
        record.name = standardized.lastPathComponent
        record.bookmark = bookmark ?? record.bookmark
        record.lastOpened = Date()

        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        save()
        return record
    }

    /// Turns a stored record back into a folder the app may read and write.
    /// Returns nil when access has to be granted again through the open panel.
    func resolve(_ record: WorkspaceRecord) -> URL? {
        if let active = scopedURLs[record.id] { return active }

        var candidate = URL(fileURLWithPath: record.path, isDirectory: true)
        var startedScope = false
        if let bookmark = record.bookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                       relativeTo: nil, bookmarkDataIsStale: &isStale) {
                candidate = resolved
                startedScope = resolved.startAccessingSecurityScopedResource()
                if isStale { refreshBookmark(for: record, url: resolved) }
            }
        }

        guard Self.isReadableFolder(candidate) else {
            if startedScope { candidate.stopAccessingSecurityScopedResource() }
            return nil
        }
        if startedScope { scopedURLs[record.id] = candidate }
        return candidate
    }

    func stopAccessing(_ record: WorkspaceRecord) {
        scopedURLs.removeValue(forKey: record.id)?.stopAccessingSecurityScopedResource()
    }

    func markOpened(_ record: WorkspaceRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        var updated = records.remove(at: index)
        updated.lastOpened = Date()
        records.insert(updated, at: 0)
        save()
    }

    func forget(_ record: WorkspaceRecord) {
        stopAccessing(record)
        records.removeAll { $0.id == record.id }
        save()
    }

    private func refreshBookmark(for record: WorkspaceRecord, url: URL) {
        guard let index = records.firstIndex(where: { $0.id == record.id }),
              let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        records[index].bookmark = fresh
        records[index].path = url.path
        save()
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func isReadableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }
}
