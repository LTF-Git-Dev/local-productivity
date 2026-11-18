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
