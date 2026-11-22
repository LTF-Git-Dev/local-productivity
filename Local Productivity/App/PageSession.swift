//
//  PageSession.swift
//  Local Productivity
//
//  The page that is currently open: where it lives, what it is called, and the job of
//  getting edits onto disk. The editor owns the text; the session owns the file.
//

import AppKit
import Foundation

@Observable
final class PageSession: Identifiable {

    enum Status: Equatable {
        case saved
        case edited
        case failed(String)
    }

    enum Focus {
        case title
        case body
    }

    struct TableEdit: Identifiable {
        let id = UUID()
        var location: Int
        var table: TableInfo
    }

    let id = UUID()
    let workspace: Workspace

    private(set) var path: String
    /// The page name as shown in the header. Editing it renames the file when committed.
    var title: String
    private(set) var icon: String?
    private(set) var status: Status = .saved
    /// Why the page couldn't be read, when it couldn't. Such a page is shown read-only and never
    /// saved, so an empty editor can't replace a file LP failed to open.
    private(set) var readFailure: String?
    private(set) var wordCount = 0
    private(set) var modified: Date?

    /// Set to move keyboard focus; whoever acts on it clears it.
    var focusRequest: Focus?
    /// Non-nil while the table editor is open.
    var tableEdit: TableEdit?

    @ObservationIgnored weak var controller: EditorController?
    @ObservationIgnored private var frontMatter: String?
    @ObservationIgnored private var usesCRLF = false
    @ObservationIgnored private var usesTabIndentation = false
    @ObservationIgnored private var savedText = ""
    /// What a save that failed tried to write, so it can still be kept (see `closeSavingChanges`).
    @ObservationIgnored private var unsavedText: String?
    /// Set once the page has been closed and its edits are safe; nothing more is written.
    @ObservationIgnored private(set) var isClosed = false
    /// What the last save wrote for each paragraph, so the next one only redoes changed ones.
    @ObservationIgnored private let serializerCache = SerializerCache()
    /// The encoding the file was read with, so it is written back the same way.
    @ObservationIgnored private var encoding = String.Encoding.utf8
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(path: String, workspace: Workspace) {
        self.path = path
        self.workspace = workspace
        title = FileNode.title(of: path)
        icon = workspace.icon(of: path)
    }

    var url: URL { workspace.url(for: path) }

    var folder: String { FileNode.parent(of: path) }

    // MARK: Reading

    func readDocument() -> MarkdownDocument {
        status = .saved
        do {
            let text = decode(try Data(contentsOf: url))
            savedText = text
            readFailure = nil
            return adopt(MarkdownParser.parse(text))
        } catch {
            readFailure = error.localizedDescription
            return .empty
        }
    }

    /// Reads a page that couldn't be read again, and shows it once it can be.
    func retryRead() {
        guard readFailure != nil else { return }
        controller?.reload(readDocument())
    }


    /// Reads file data as text. Notes are almost always UTF-8; the rare one that is not keeps its
    /// own encoding rather than being rewritten with its special characters destroyed.
    private func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            encoding = .utf8
            return text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            encoding = .utf16
            return text
        }
        encoding = .windowsCP1252
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private func adopt(_ document: MarkdownDocument) -> MarkdownDocument {
        frontMatter = document.frontMatter
        usesCRLF = document.usesCRLF
        usesTabIndentation = document.usesTabIndentation
        icon = FrontMatter.value(for: "icon", in: document.frontMatter)
        wordCount = Self.countWords(in: document)
        modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return document
    }

    /// Counts words without building a copy of the page's text: a word starts wherever a
    /// non-space character follows a space.
    private static func countWords(in document: MarkdownDocument) -> Int {
        var count = 0
        for block in document.blocks {
            var inWord = false
            for run in block.runs {
                for scalar in run.text.unicodeScalars {
                    if scalar.properties.isWhitespace {
                        inWord = false
                    } else if !inWord {
                        inWord = true
                        count += 1
                    }
                }
            }
        }
        return count
    }

    // MARK: Saving

    /// Prepares the paragraph cache in the background once the page is on screen, so even the
    /// first save of a long page is quick.
    func warmSaveCache(with blocks: [Block]) {
        let document = MarkdownDocument(frontMatter: frontMatter, blocks: blocks, usesCRLF: usesCRLF,
                                        usesTabIndentation: usesTabIndentation)
        let cache = serializerCache
        Task.detached(priority: .utility) {
            _ = MarkdownSerializer.serialize(document, cache: cache)
        }
    }

    /// Called by the editor after every change. Saving waits for a pause in typing.
    func contentDidChange() {
        status = .edited
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes pending changes immediately. Safe to call at any time. Returns false when they
    /// couldn't be written.
    @discardableResult
    func flush() -> Bool {
        guard status != .saved else { return true }
        save()
        return status == .saved
    }

    /// Gets the page ready to close: pending edits are written or, when that can't be done, kept
    /// as a copy in LP's Recovered folder. Returns false when they could be neither — then the
    /// page must stay open.
    func closeSavingChanges() -> Bool {
        if isClosed || flush() {
            isClosed = true
            return true
        }
        // What the editor holds now; the last failed save only when the editor is gone.
        guard let text = currentText() ?? unsavedText,
              workspace.keepCopy(text, name: title, note: "unsaved changes", alertTitle: "Couldn’t Save “\(title)”",
                                 message: "Your changes couldn’t be written to the page, so LP kept them in a copy.") else { return false }
        isClosed = true
        return true
    }

    /// The page's file went away — moved or deleted elsewhere. Edits not written yet are kept as a
    /// copy rather than written back where it was. Returns false when they couldn't be kept.
    func keepChangesAfterRemoval() -> Bool {
        guard !isClosed, status != .saved else {
            isClosed = true
            return true
        }
        guard let text = currentText() ?? unsavedText,
              workspace.keepCopy(text, name: title, note: "unsaved changes", alertTitle: "“\(title)” Was Moved or Deleted",
                                 message: "Another app moved or deleted this page while it had changes that weren’t saved yet. LP kept them in a copy.") else {
            return false
        }
        isClosed = true
        return true
    }

    private func currentDocument() -> MarkdownDocument? {
        guard let controller else { return nil }
        return MarkdownDocument(frontMatter: frontMatter, blocks: controller.currentBlocks(),
                                usesCRLF: usesCRLF, usesTabIndentation: usesTabIndentation)
    }

    private func currentText() -> String? {
        currentDocument().map { MarkdownSerializer.serialize($0, cache: serializerCache) }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        // A page that couldn't be read is never written: the editor holds nothing of it. A closed
        // one has nothing more to write.
        guard !isClosed, readFailure == nil, let document = currentDocument() else { return }

        let text = MarkdownSerializer.serialize(document, cache: serializerCache)
        wordCount = Self.countWords(in: document)
        guard text != savedText else {
            status = .saved
            unsavedText = nil
            return
        }
        if let problem = checkBeforeWriting() {
            unsavedText = text
            status = .failed(problem)
            return
        }
        do {
            try SafeFileWriter.write(text.data(using: encoding) ?? Data(text.utf8), to: url)
            savedText = text
            unsavedText = nil
            status = .saved
            modified = Date()
        } catch {
            unsavedText = text
            status = .failed(error.localizedDescription)
        }
    }

    /// Makes sure writing loses nothing that is in the file now, or says why it would. A version
    /// another app wrote since LP read the file is kept as a copy first; a file that is gone, or
    /// can't be read to check, isn't written.
    private func checkBeforeWriting() -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "The page’s file is gone — it was moved or deleted in another app."
        }
        guard let data = try? Data(contentsOf: url) else {
            return "LP couldn’t read the page’s file to check it hadn’t been changed elsewhere."
        }
        let previousEncoding = encoding
        let onDisk = decode(data)
        encoding = previousEncoding
        guard onDisk != savedText else { return nil }
        let kept = workspace.keepCopy(onDisk, name: title, note: "other version",
                                      alertTitle: "“\(title)” Was Also Changed Elsewhere",
                                      message: "Another app changed this page while you were editing it here. LP saved your edits and kept the other version as a copy.")
        return kept ? nil : "Another app changed this page and LP couldn’t keep that version as a copy, so your edits weren’t written over it."
    }

    /// The file was changed by something other than this session.
    func fileChangedOnDisk() {
        if readFailure != nil {
            retryRead()
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let previousEncoding = encoding
        let text = decode(data)
        guard text != savedText else {
            encoding = previousEncoding
            return
        }
        // Unsaved edits made here win; when they are written, this version is kept as a copy.
        guard status == .saved else {
            encoding = previousEncoding
            return
        }
        savedText = text
        controller?.reload(adopt(MarkdownParser.parse(text)))
    }

    // MARK: Identity

    func pathDidChange(to newPath: String) {
        path = newPath
        title = FileNode.title(of: newPath)
    }

    func setIcon(_ newIcon: String?) {
        guard newIcon != icon else { return }
        icon = newIcon
        frontMatter = FrontMatter.setting(newIcon, for: "icon", in: frontMatter)
        workspace.noteIconChanged(newIcon, for: path)
        status = .edited
        save()
    }

    func resolveImage(_ info: ImageInfo) -> URL? {
        workspace.resolveAttachment(info.source, from: path)
    }

    /// Stores pasted image data in the workspace and describes how this page refers to it.
    func importImage(_ data: Data, fileExtension: String) -> ImageInfo? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        guard let file = try? workspace.storeAttachment(data, name: "pasted-\(stamp)", fileExtension: fileExtension) else { return nil }
        return ImageInfo(source: workspace.reference(to: file, from: path))
    }

    /// Brings a dropped file into the workspace (unless it is already there) and returns its reference.
    func importFile(at url: URL) -> String? {
        guard let file = try? workspace.adoptAttachment(at: url) else { return nil }
        return workspace.reference(to: file, from: path)
    }
}

// MARK: - Writing files

/// Text LP couldn't put where it belonged — edits that couldn't be saved, or another app's
/// version of a page that LP's edits replaced — kept in LP's own folder instead of being lost.
/// The user's workspace is never touched; the folder is `Application Support/LP/Recovered`.
enum RecoveredCopies {

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LP/Recovered", isDirectory: true)
    }

    /// Writes `text` as "<name> — <note> <date and time>.md" and returns where it went.
    static func keep(_ text: String, name: String, note: String) -> URL? {
        guard let folder else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(Workspace.sanitized(name) ?? "Untitled") — \(note) \(formatter.string(from: Date()))"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(Workspace.availableName(base, extension: "md", in: folder))
            try Data(text.utf8).write(to: copy, options: .atomic)
            return copy
        } catch {
            return nil
        }
    }
}

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
