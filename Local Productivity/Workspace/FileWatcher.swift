//
//  FileWatcher.swift
//  Local Productivity
//
//  Watches the workspace folder with FSEvents so the sidebar and the open page stay
//  in step when files are changed by another app, a sync service or a script.
//

import CoreServices
import Foundation

nonisolated final class FileWatcher: @unchecked Sendable {

    private let url: URL
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "LocalProductivity.FileWatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    /// `onChange` receives the absolute paths that changed. It is called on a background queue.
    init(url: URL, onChange: @escaping @Sendable ([String]) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(paths)
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(flags)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
