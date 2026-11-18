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
        let text = (try? Data(contentsOf: url)).map(decode) ?? ""
        savedText = text
        status = .saved
        return adopt(MarkdownParser.parse(text))
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

    /// Writes pending changes immediately. Safe to call at any time.
    func flush() {
        guard status != .saved else { return }
        save()
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let controller else { return }

        let document = MarkdownDocument(frontMatter: frontMatter, blocks: controller.currentBlocks(),
                                        usesCRLF: usesCRLF, usesTabIndentation: usesTabIndentation)
        let text = MarkdownSerializer.serialize(document, cache: serializerCache)
        wordCount = Self.countWords(in: document)
        guard text != savedText else {
            status = .saved
            return
        }
        do {
            try SafeFileWriter.write(text.data(using: encoding) ?? Data(text.utf8), to: url)
            savedText = text
            status = .saved
            modified = Date()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The file was changed by something other than this session.
    func fileChangedOnDisk() {
        guard let data = try? Data(contentsOf: url) else { return }
        let previousEncoding = encoding
        let text = decode(data)
        guard text != savedText else {
            encoding = previousEncoding
            return
        }
        // Unsaved edits made here win; they are about to be written anyway.
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
