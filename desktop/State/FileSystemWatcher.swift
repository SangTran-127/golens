import Foundation
import CoreServices

struct FileSystemChange {
    var paths: Set<String> = []
    var directoryPaths: Set<String> = []
    var needsFullReload = false

    static let fullReload = FileSystemChange(needsFullReload: true)

    mutating func merge(_ other: FileSystemChange) {
        paths.formUnion(other.paths)
        directoryPaths.formUnion(other.directoryPaths)
        needsFullReload = needsFullReload || other.needsFullReload
    }
}

class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let callback: (FileSystemChange) -> Void
    private let onFilesChanged: (Set<String>) -> Void
    private let onGitChanged: () -> Void
    private var workItem: DispatchWorkItem?
    private var gitWorkItem: DispatchWorkItem?
    private var changedFiles: Set<String> = []
    private var filesWorkItem: DispatchWorkItem?
    private var pendingChange = FileSystemChange()

    init(
        path: String,
        debounceInterval: TimeInterval = 0.3,
        callback: @escaping (FileSystemChange) -> Void,
        onFilesChanged: @escaping (Set<String>) -> Void = { _ in },
        onGitChanged: @escaping () -> Void = {}
    ) {
        self.path = path
        self.callback = callback
        self.onFilesChanged = onFilesChanged
        self.onGitChanged = onGitChanged
    }

    func start() {
        guard stream == nil else { return }

        let pathsToWatch = [path] as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let streamCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(clientCallBackInfo!).takeUnretainedValue()

            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            let structuralChangeMask: UInt32 = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            let contentChangeMask = structuralChangeMask | UInt32(kFSEventStreamEventFlagItemModified)
            let rescanMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)

            var hasStructuralChange = false
            var change = FileSystemChange()
            var hasGitChange = false
            var indexPaths: Set<String> = []
            var files: Set<String> = []
            for (index, path) in paths.enumerated() {
                if path.contains("/.build/") || path.hasSuffix(".lock") || path.contains("/golens-diff-") {
                    continue
                }
                if path.contains("/.git/") || path.hasSuffix("/.git") {
                    guard flags[index] & contentChangeMask != 0 else { continue }
                    if path.hasSuffix("/.git/index") {
                        indexPaths.insert(path)
                    } else if path.hasSuffix("/.git") ||
                        path.hasSuffix("/.git/HEAD") ||
                        path.hasSuffix("/.git/packed-refs") ||
                        path.hasSuffix("/.git/MERGE_HEAD") ||
                        path.contains("/.git/refs/") {
                        hasGitChange = true
                    }
                    continue
                }
                if flags[index] & rescanMask != 0 {
                    hasStructuralChange = true
                    change.needsFullReload = true
                }
                if flags[index] & structuralChangeMask != 0 {
                    hasStructuralChange = true
                    change.paths.insert(path)
                    if flags[index] & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                        change.directoryPaths.insert(path)
                    }
                }
                if flags[index] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, flags[index] & contentChangeMask != 0 {
                    files.insert(path)
                }
            }
            if !hasGitChange && !indexPaths.isEmpty {
                hasGitChange = indexPaths.contains { GitIndexWatch.shared.shouldRefresh(forIndexAt: $0) }
            }
            if hasStructuralChange {
                watcher.handleEvents(change)
            } else if hasGitChange {
                watcher.handleGitEvents()
            }
            if !files.isEmpty {
                watcher.handleFileChanges(files)
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            streamCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
            FSEventStreamStart(stream)
        }
    }

    func triggerReload(_ change: FileSystemChange = .fullReload) {
        DispatchQueue.main.async { [weak self] in
            self?.callback(change)
        }
    }

    private func handleEvents(_ change: FileSystemChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingChange.merge(change)
            workItem?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let change = pendingChange
                pendingChange = FileSystemChange()
                callback(change)
            }
            workItem = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        }
    }

    private func handleGitEvents() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            gitWorkItem?.cancel()
            let task = DispatchWorkItem { [weak self] in
                self?.onGitChanged()
            }
            gitWorkItem = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        }
    }

    private func handleFileChanges(_ files: Set<String>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            changedFiles.formUnion(files)
            filesWorkItem?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let files = changedFiles
                changedFiles = []
                onFilesChanged(files)
            }
            filesWorkItem = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
        }
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    
    deinit {
        stop()
    }
}
