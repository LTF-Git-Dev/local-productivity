//
//  AnchoredFiles.swift
//  lp-mcp
//
//  The only way lp-mcp touches files. Every path is walked from an open handle on the workspace
//  folder, one part at a time, never following a link — so a folder swapped for a link (by a sync
//  service, another person's Mac, or anything else) can't carry a read or write outside it.
//  Only regular files are read, never more than a limit. A file is replaced by writing the new
//  version beside it and swapping the two in one step, then checking what was swapped out: if
//  someone else had saved in between, their version is swapped back and nothing of theirs is
//  lost. Nothing here ever deletes a page.
//

import Darwin
import Foundation

nonisolated final class AnchoredFiles {

    private let rootFD: Int32

    init(root: URL) throws {
        rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw VaultError("The workspace folder \(root.path) can’t be opened.") }
    }

    deinit { close(rootFD) }

    /// Splits "a/b/c.md" into "a/b" and "c.md".
    static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// A handle on the folder at `path` (relative to the workspace), reached without following
    /// links; with `create`, missing folders are made. The caller closes it.
    func openFolder(_ path: String, create: Bool = false) throws -> Int32 {
        // A fresh handle, not dup(): a duplicate shares its read position, so a second listing
        // of the same folder would start at the end and find nothing.
        var fd = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VaultError("The workspace can’t be opened.") }
        for part in path.split(separator: "/").map(String.init) {
            if create, mkdirat(fd, part, 0o755) != 0, errno != EEXIST {
                let code = errno
                close(fd)
                throw VaultError("The folder “\(path)” can’t be made (\(String(cString: strerror(code)))).")
            }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else {
                switch code {
                case ELOOP, ENOTDIR: throw VaultError("“\(path)” goes through a link or a file, which LP’s tools don’t follow.")
                case ENOENT: throw VaultError("There’s no folder “\(path)”.")
                default: throw VaultError("The folder “\(path)” can’t be opened (\(String(cString: strerror(code)))).")
                }
            }
            var info = stat()
            if fstat(next, &info) != 0 || info.st_flags & UInt32(UF_HIDDEN) != 0 {
                close(next)
                throw VaultError("“\(path)” is in a hidden folder, which LP doesn’t use for pages.")
            }
            fd = next
        }
        return fd
    }

    /// Opens a regular file in `folderFD` without following a link or waiting on a pipe.
    private func openRegular(_ folderFD: Int32, _ name: String, path: String) throws -> (fd: Int32, info: stat) {
        let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: throw VaultError("There’s no page at “\(path)”. Use lp_list_pages or lp_search to find it.")
            case ELOOP: throw VaultError("“\(path)” is a link, which LP’s tools don’t follow.")
            default: throw VaultError("“\(path)” can’t be opened (\(String(cString: strerror(errno)))).")
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw VaultError("“\(path)” isn’t a regular file, so it isn’t used.")
        }
        guard info.st_flags & UInt32(UF_HIDDEN) == 0 else {
            close(fd)
            throw VaultError("“\(path)” is hidden, so it isn’t used.")
        }
        return (fd, info)
    }

    private static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, limit + 1 - data.count)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw VaultError("The page couldn’t be read (\(String(cString: strerror(errno)))).")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// A file's bytes: at most `limit` (one more means it's too big — the caller decides).
    func read(_ path: String, limit: Int) throws -> Data {
        let (folder, name) = Self.split(path)
        let folderFD = try openFolder(folder)
        defer { close(folderFD) }
        let (fd, _) = try openRegular(folderFD, name, path: path)
        defer { close(fd) }
        return try Self.readAll(fd, limit: limit)
    }

    /// Writes a new file; never replaces anything ("Plan 2.md" when "Plan.md" exists, as in LP).
    /// It's written and saved under a hidden name first, then given its name only if that name is
    /// free — so a failed write never leaves a half-written page. Returns the name it got.
    func create(in folder: String, base: String, extension ext: String, data: Data) throws -> String {
        let folderFD = try openFolder(folder, create: true)
        defer { close(folderFD) }
        let temporary = try writeTemporary(in: folderFD, data, mode: 0o644)
        defer { unlinkat(folderFD, temporary, 0) }   // harmless once it has been renamed
        for counter in 1...10_000 {
            let name = counter == 1 ? "\(base).\(ext)" : "\(base) \(counter).\(ext)"
            if renameatx_np(folderFD, temporary, folderFD, name, UInt32(RENAME_EXCL)) == 0 { return name }
            if errno != EEXIST { throw VaultError("The page couldn’t be created (\(String(cString: strerror(errno)))).") }
        }
        throw VaultError("There are too many pages called “\(base)” in that folder.")
    }

    /// A new hidden file in `folderFD` holding `data`, written and saved to disk; its name.
    private func writeTemporary(in folderFD: Int32, _ data: Data, mode: mode_t) throws -> String {
        let name = ".lp-mcp-\(UUID().uuidString).tmp"
        let fd = openat(folderFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw VaultError("The page couldn’t be written (\(String(cString: strerror(errno)))).") }
        defer { close(fd) }
        do { try Self.writeAll(fd, data) } catch { unlinkat(folderFD, name, 0); throw error }
        return name
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw VaultError("The page couldn’t be written (\(String(cString: strerror(errno)))).")
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw VaultError("The page couldn’t be saved to disk.") }
    }

    enum Replaced { case done, changedMeanwhile }

    /// Replaces the file with `data` — only if it still holds `expected`. The new version is
    /// written beside it and the two are swapped in one step; if what was swapped out isn't
    /// `expected` (someone saved in between), it is swapped back, so their save stands.
    func replace(_ path: String, with data: Data, expected: Data) throws -> Replaced {
        let (folder, name) = Self.split(path)
        let folderFD = try openFolder(folder)
        defer { close(folderFD) }
        let (originalFD, original) = try openRegular(folderFD, name, path: path)
        // A page that is read-only or locked (Finder's "Locked") stays as it is: replacing it with a
        // new file would get round that.
        guard faccessat(folderFD, name, W_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0,
              original.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else {
            close(originalFD)
            throw VaultError("“\(path)” is read-only or locked, so it wasn’t changed.")
        }
        let before = Self.metadata(originalFD)
        let temporary = ".lp-mcp-\(UUID().uuidString).tmp"
        let fd = openat(folderFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, original.st_mode & 0o777)
        guard fd >= 0 else {
            close(originalFD)
            throw VaultError("The page couldn’t be written (\(String(cString: strerror(errno)))).")
        }
        var swapped = false
        defer { if !swapped { Self.remove(temporary, in: folderFD) } }
        do {
            try Self.writeAll(fd, data)
            // Keep what the old file carried besides its text: Finder tags and other extended
            // attributes, permissions and its creation date.
            // Tags and permissions are required: without them the edit isn't made.
            guard fcopyfile(originalFD, fd, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0,
                  fchmod(fd, original.st_mode & 0o7777) == 0 else {
                throw VaultError("“\(path)” couldn’t keep its Finder tags or permissions, so it wasn’t changed.")
            }
            // Owner and group (so the same people can read it), and the file's flags.
            guard fchown(fd, original.st_uid, original.st_gid) == 0 else {
                throw VaultError("“\(path)” belongs to another user or group this Mac won’t give it to, so it wasn’t changed.")
            }
            let keptFlags = original.st_flags & UInt32(UF_SETTABLE) & ~UInt32(UF_COMPRESSED | UF_TRACKED)
            guard keptFlags == 0 || fchflags(fd, keptFlags) == 0 else {
                throw VaultError("“\(path)” couldn’t keep its file flags, so it wasn’t changed.")
            }
            // The creation date too, where the disk keeps one.
            var created = original.st_birthtimespec
            var attributes = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME),
                                      volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
            if fsetattrlist(fd, &attributes, &created, MemoryLayout<timespec>.size, 0) != 0, errno != ENOTSUP, errno != EINVAL {
                throw VaultError("“\(path)” couldn’t keep its creation date, so it wasn’t changed.")
            }
            close(fd)
            close(originalFD)
        } catch {
            close(fd)
            close(originalFD)
            throw error
        }

        guard renameatx_np(folderFD, temporary, folderFD, name, UInt32(RENAME_SWAP)) == 0 else {
            switch errno {
            case ENOENT: throw VaultError("“\(path)” was removed meanwhile, so it wasn’t written again.")
            case EACCES, EPERM: throw VaultError("“\(path)” is protected (its permissions don’t allow replacing it), so it wasn’t changed.")
            default: throw VaultError("The page couldn’t be replaced (\(String(cString: strerror(errno)))).")
            }
        }
        swapped = true
        // `temporary` now holds what was there a moment ago. Unless it is exactly what was read —
        // and could be read back to check — it is someone else's save.
        let hiddenPath = folder.isEmpty ? temporary : folder + "/" + temporary
        let limit = max(expected.count, data.count) + 1
        if let displaced = try? read(hiddenPath, limit: limit), displaced == expected,
           metadataUnchanged(folderFD, temporary, since: before) {
            Self.remove(temporary, in: folderFD)
            return .done
        }
        // Someone saved in between: put their version back.
        guard renameatx_np(folderFD, temporary, folderFD, name, UInt32(RENAME_SWAP)) == 0 else {
            throw VaultError("“\(path)” changed while it was being written. One version is in the page, the other kept, hidden, as “\(hiddenPath)”.")
        }
        if let returned = try? read(hiddenPath, limit: limit), returned == data {
            Self.remove(temporary, in: folderFD)
            return .changedMeanwhile
        }
        // Yet another save landed in between: keep it next to the page under a visible name —
        // or stop and say exactly where it is.
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let short = String(UUID().uuidString.prefix(8))
        let candidates = (1...20).map { $0 == 1 ? "\(stem) (conflict).\(ext)" : "\(stem) (conflict \($0)).\(ext)" } + ["conflict-\(short).\(ext)"]
        for copy in candidates where renameatx_np(folderFD, temporary, folderFD, copy, UInt32(RENAME_EXCL)) == 0 {
            throw VaultError("“\(path)” was saved by something else more than once while it was being changed. Both versions are kept: one in the page, one as “\(folder.isEmpty ? copy : folder + "/" + copy)”. Compare them, then read the page again and redo the change.")
        }
        throw VaultError("“\(path)” was saved by something else more than once while it was being changed. One version is in the page, the other kept, hidden, as “\(hiddenPath)”.")
    }

    /// What a file carries besides its text that an edit must keep: permissions, flags and
    /// extended attributes (Finder tags among them).
    struct Metadata: Equatable {
        var mode: mode_t
        var owner: uid_t
        var group: gid_t
        var flags: UInt32
        var acl: String?
        var attributes: [String: Data]
    }

    static func metadata(_ fd: Int32) -> Metadata? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        var attributes: [String: Data] = [:]
        let size = flistxattr(fd, nil, 0, 0)
        if size > 0 {
            var names = [CChar](repeating: 0, count: size)
            guard flistxattr(fd, &names, size, 0) == size else { return nil }
            for name in names.split(separator: 0).map({ String(cString: Array($0) + [0]) }) {
                let length = fgetxattr(fd, name, nil, 0, 0, 0)
                guard length >= 0 else { return nil }
                var value = [UInt8](repeating: 0, count: length)
                guard fgetxattr(fd, name, &value, length, 0, 0) == length else { return nil }
                attributes[name] = Data(value)
            }
        }
        var aclText: String?
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            if let text = acl_to_text(acl, nil) { aclText = String(cString: text); acl_free(UnsafeMutableRawPointer(text)) }
            acl_free(UnsafeMutableRawPointer(acl))
        }
        return Metadata(mode: info.st_mode & 0o7777, owner: info.st_uid, group: info.st_gid, flags: info.st_flags,
                        acl: aclText, attributes: attributes)
    }

    /// Whether the file swapped out still carries what the original had when it was read.
    private func metadataUnchanged(_ folderFD: Int32, _ name: String, since before: Metadata?) -> Bool {
        guard let before else { return false }
        let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return Self.metadata(fd) == before
    }

    /// Removes one of this server's own temporary files — after taking off the access list and
    /// flags it copied from the page, which could otherwise forbid removing it.
    private static func remove(_ name: String, in folderFD: Int32) {
        let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            if let empty = acl_init(0) { _ = acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED); acl_free(UnsafeMutableRawPointer(empty)) }
            _ = fchflags(fd, 0)
            close(fd)
        }
        unlinkat(folderFD, name, 0)
    }

    // MARK: - Listing

    /// Every regular file under `folder`, walked from the workspace folder itself: hidden names,
    /// links, packages and `node_modules` are skipped and never followed. `visit` gets each
    /// file's path and modification date and returns false to stop. Returns false when part of
    /// the folder couldn't be read (the listing is then incomplete).
    func walk(_ folder: String, visit: (_ path: String, _ modified: Date) -> Bool) throws -> Bool {
        let start = try openFolder(folder)
        var complete = true
        var stopped = false
        func visitFolder(_ fd: Int32, _ prefix: String, depth: Int) {
            guard depth < 64, let directory = fdopendir(fd) else { close(fd); complete = false; return }
            defer { closedir(directory) }
            var names: [String] = []
            var read = 0
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { complete = false }   // a read error, not the end of the folder
                    break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
                read += 1
                if !name.hasPrefix(".") { names.append(name) }
                // shortcut: a folder this large isn't a notes folder; list what was found and say it's incomplete.
                if read >= Self.maxEntriesPerFolder { complete = false; break }
            }
            for name in names.sorted() where !stopped {
                var info = stat()
                guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { complete = false; continue }
                if info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }   // hidden in Finder: skipped, like a dot name
                let path = prefix.isEmpty ? name : prefix + "/" + name
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                    if !visit(path, modified) { stopped = true }
                case S_IFDIR:
                    guard name != "node_modules", !Self.packageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                    let child = openat(dirfd(directory), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child < 0 { complete = false; continue }
                    visitFolder(child, path, depth: depth + 1)
                default:
                    continue   // links, pipes, devices: never pages, never followed
                }
            }
        }
        visitFolder(start, folder, depth: 0)
        return complete
    }

    /// The most entries read from one folder.
    static let maxEntriesPerFolder = 50_000

    /// Folders macOS shows as single files (apps, bundles, Pages documents…), skipped as LP does.
    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "pkg", "mpkg", "photoslibrary",
                                                 "xcodeproj", "xcworkspace", "playground", "rtfd", "pages", "numbers", "key",
                                                 "scriptd", "band", "logicx", "fcpbundle", "imovielibrary", "lpdf"]
}
