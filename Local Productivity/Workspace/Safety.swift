//
//  Safety.swift
//  LP
//
//  Rules that keep content from a note — which may come from anyone — from reaching outside
//  the workspace or running code. Pure and Foundation-only, so they are covered by tests.
//

import Foundation
import UniformTypeIdentifiers

/// Workspace-relative paths that cannot climb out of the workspace.
nonisolated enum PathSafety {

    /// `path` with empty and `.` parts removed, or nil if it would leave the workspace (a `..`
    /// part or an absolute path).
    static func contained(_ path: String) -> String? {
        if path.hasPrefix("/") || path.hasPrefix("~") { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// Whether `url` is `root` or inside it, after resolving `..` and symbolic links.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Whether something written at `url` — which need not exist yet — lands inside `root`. The
    /// nearest part of the path that exists is resolved, so a folder inside the workspace that
    /// is a link to somewhere else can't carry a new file out of it.
    static func resolvesInside(_ url: URL, root: URL) -> Bool {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        return isInside(existing, root: root)
    }
}

/// What to do with a link the user clicked in a note.
nonisolated enum LinkSafety {

    enum Action: Equatable {
        /// Web pages and e-mail: open straight away.
        case open
        /// Opens another app (zoommtg:, slack:, x-apple…): ask first.
        case confirm
        /// A file on disk: handled by `canOpenFile`.
        case file
    }

    static func action(for url: URL) -> Action {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return .open
        case "file": return .file
        default: return .confirm
        }
    }

    /// Documents (images, PDFs, text, office files, media, archives) open in their app. Anything
    /// that can run — apps, scripts, installers, terminal commands, shortcuts to other files or
    /// URLs — and anything unrecognised is only shown in Finder.
    static func canOpenFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if blockedExtensions.contains(ext) { return false }
        guard let type = UTType(filenameExtension: ext) else { return false }
        let runnable: [UTType] = [.executable, .application, .applicationBundle, .script, .shellScript,
                                  .appleScript, .osaScript, .unixExecutable, .bundle, .systemPreferencesPane]
        if runnable.contains(where: { type.conforms(to: $0) }) { return false }
        let documents: [UTType] = [.image, .pdf, .audiovisualContent, .plainText, .rtf, .rtfd, .html,
                                   .spreadsheet, .presentation, .archive, .compositeContent, .commaSeparatedText, .json]
        return documents.contains { type.conforms(to: $0) }
    }

    /// Types that run or redirect even when the system classifies them as data.
    private static let blockedExtensions: Set<String> = [
        "command", "tool", "terminal", "workflow", "action", "app", "pkg", "mpkg", "dmg", "scpt", "scptd",
        "applescript", "sh", "zsh", "bash", "csh", "ksh", "fish", "py", "rb", "pl", "php", "js", "jar",
        "webloc", "inetloc", "fileloc", "mobileconfig", "plugin", "kext", "prefpane", "saver", "osax",
        "service", "shortcut", "definition", "qlgenerator", "xpc", "systemextension", "appex", "url", "lnk"
    ]
}

/// Board identifiers name the board's history file, so they must be plain.
nonisolated enum BoardIDSafety {
    static func isValid(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// The key of a sharing grant: the board file's path, its board ID and the gist ID, joined by
/// U+001F. Board and gist IDs can't contain that character (`BoardIDSafety`, gist IDs are letters
/// and digits), so a key is read from the right, and a path that contains it is kept whole.
nonisolated enum ShareGrantKey {
    static let separator: Character = "\u{1F}"

    static func make(path: String, board: String, page: String) -> String {
        [path, board, page].joined(separator: String(separator))
    }

    static func parts(of key: String) -> (path: String, board: String, page: String)? {
        guard let last = key.lastIndex(of: separator) else { return nil }
        let head = key[..<last]
        guard let middle = head.lastIndex(of: separator) else { return nil }
        return (String(head[..<middle]), String(head[head.index(after: middle)...]), String(key[key.index(after: last)...]))
    }
}

/// Writes a file's new contents safely (moved here from PageSession so the MCP server shares it).
nonisolated enum SafeFileWriter {

    /// Replaces a file's contents without ever leaving it half written, and without losing the
    /// original's creation date, tags or other metadata.
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        do {
            let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            let temporary = directory.appendingPathComponent(url.lastPathComponent)
            defer { try? manager.removeItem(at: directory) }
            try data.write(to: temporary)
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try data.write(to: url, options: .atomic)
        }
    }
}

/// How LP names a new page or folder file (shared by the app and the MCP server).
nonisolated enum PageNaming {
    static func sanitized(_ title: String) -> String? {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 { name = String(name.prefix(200)) }
        return name.isEmpty ? nil : name
    }

    /// "Untitled", then "Untitled 2", "Untitled 3"… whichever is free in `directory`.
    static func availableName(_ base: String, extension ext: String?, in directory: URL) -> String {
        func fileName(_ stem: String) -> String { ext.map { "\(stem).\($0)" } ?? stem }
        var candidate = fileName(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = fileName("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }
}

/// The Terminal steps that connect Claude Code to a workspace through the `lp-mcp` helper inside
/// LP.app (Settings → General → LP with Claude): one short command per step. Paths are quoted for
/// the shell, so a folder name can never run as a command.
nonisolated enum ClaudeSetup {
    /// `text` in single quotes for zsh/bash; a single quote inside becomes '\''.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Step 1: lets the helper run — macOS blocks programs that arrived in a download until this flag is gone.
    static func allowHelper(_ helper: String) -> String {
        "xattr -d com.apple.quarantine \(shellQuoted(helper))"
    }

    /// Step 2: connects Claude Code (every project) to this workspace.
    static func connect(helper: String, workspace: String) -> String {
        "claude mcp add --scope user lp -- \(shellQuoted(helper)) --workspace \(shellQuoted(workspace))"
    }

    /// Step 3: shows whether it's connected.
    static let check = "claude mcp get lp"

    /// When LP is already connected and should be connected to another workspace instead.
    static let remove = "claude mcp remove lp --scope user"

}
