//
//  FileNode.swift
//  Local Productivity
//
//  The workspace as a tree of folders and Markdown pages, plus the scanner that
//  builds it from disk. Paths are relative to the workspace root and use "/" as the
//  separator; the root itself is the empty string.
//

import Foundation

nonisolated struct FileNode: Identifiable, Hashable, Sendable {

    var path: String
    /// What the user sees: the folder name, or the file name without its extension.
    var name: String
    var isFolder: Bool
    var modified: Date
    var created: Date?
    var children: [FileNode] = []

    var id: String { path }

    var parentPath: String { FileNode.parent(of: path) }

    /// Number of pages in this folder and everything below it.
    var pageCount: Int {
        isFolder ? children.reduce(0) { $0 + $1.pageCount } : 1
    }

    /// Every page beneath this node, depth first.
    var pages: [FileNode] {
        guard isFolder else { return [self] }
        return children.flatMap(\.pages)
    }

    func node(at target: String) -> FileNode? {
        if target == path { return self }
        guard isFolder, path.isEmpty || target.hasPrefix(path + "/") else { return nil }
        for child in children {
            if let found = child.node(at: target) { return found }
        }
        return nil
    }

    // MARK: Path helpers

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    static func fileName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The display title for a page path: its file name without the Markdown extension.
    static func title(of path: String) -> String {
        let file = fileName(of: path)
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex,
              WorkspaceScanner.pageExtensions.contains(file[file.index(after: dot)...].lowercased()) else { return file }
        return String(file[..<dot])
    }

    /// The chain of folders leading to `path`, outermost first.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = parent(of: path)
        while !current.isEmpty {
            result.insert(current, at: 0)
            current = parent(of: current)
        }
        return result
    }

    /// Rewrites `path` when `old` (a page or folder) has been renamed or moved to `new`.
    static func rebased(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
        return nil
    }
}

// MARK: - Scanning

nonisolated enum WorkspaceScanner {

    static let pageExtensions: Set<String> = ["md", "markdown"]

    /// Folders that are never part of a knowledge base and can be enormous.
    private static let ignoredFolders: Set<String> = ["node_modules"]

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey, .creationDateKey
    ]

    static func scan(_ root: URL) -> FileNode {
        FileNode(path: "", name: root.lastPathComponent, isFolder: true, modified: Date(),
                 children: contents(of: root, path: "", depth: 0).nodes)
    }

    /// The folders and pages inside `directory`, plus whether it holds files of any other kind.
    private static func contents(of directory: URL, path: String, depth: Int) -> (nodes: [FileNode], hasOtherFiles: Bool) {
        guard depth < 32, let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return ([], false) }

        var folders: [FileNode] = []
        var pages: [FileNode] = []
        var hasOtherFiles = false
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            let fileName = url.lastPathComponent
            let childPath = FileNode.join(path, fileName)
            let modified = values.contentModificationDate ?? .distantPast

            if values.isDirectory == true, values.isPackage != true {
                guard !ignoredFolders.contains(fileName) else { continue }
                let inside = contents(of: url, path: childPath, depth: depth + 1)
                // A folder that only holds images and other attachments is not a place for pages.
                // An empty folder is still shown, so a newly made one can be filled.
                if inside.nodes.isEmpty, inside.hasOtherFiles {
                    hasOtherFiles = true
                    continue
                }
                folders.append(FileNode(path: childPath, name: fileName, isFolder: true, modified: modified,
                                        created: values.creationDate, children: inside.nodes))
            } else if pageExtensions.contains(url.pathExtension.lowercased()) {
                pages.append(FileNode(path: childPath, name: url.deletingPathExtension().lastPathComponent,
                                      isFolder: false, modified: modified, created: values.creationDate))
            } else {
                hasOtherFiles = true
            }
        }

        let byName: (FileNode, FileNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (folders.sorted(by: byName) + pages.sorted(by: byName), hasOtherFiles)
    }
}
