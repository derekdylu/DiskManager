import Darwin
import Foundation

/// Thread-safe cancellation flag
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        flag = false
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

public struct SyncProgress: Sendable {
    public var totalBytes: Int64
    public var copiedBytes: Int64
    public var totalItems: Int
    public var completedItems: Int
    public var currentPath: String

    public init(totalBytes: Int64, copiedBytes: Int64, totalItems: Int, completedItems: Int, currentPath: String) {
        self.totalBytes = totalBytes
        self.copiedBytes = copiedBytes
        self.totalItems = totalItems
        self.completedItems = completedItems
        self.currentPath = currentPath
    }
}

public struct ItemFailure: Identifiable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let message: String
}

public struct SyncResult: Sendable {
    public var copied = 0
    public var updated = 0
    public var dirsCreated = 0
    public var orphansHandled = 0
    public var bytesCopied: Int64 = 0
    public var failures: [ItemFailure] = []
    public var wasCancelled = false
    /// The archive folder actually used by this sync (relative to the B root); nil if nothing was archived
    public var archiveFolder: String? = nil

    public init() {}
}

public enum SyncEngine {
    public static let archiveRootName = "_DiskManager_Archive"

    /// Executes a sync plan. This is a synchronous function; call it on a background thread. progress is invoked on that same thread.
    /// archiveReplaced: before overwriting an existing file, move the old version to the archive folder (used by union mode).
    public static func execute(
        plan: SyncPlan,
        sourceRoot: URL,
        destRoot: URL,
        orphanPolicy: OrphanPolicy,
        archiveReplaced: Bool = false,
        cancel: CancelFlag,
        progress: @escaping @Sendable (SyncProgress) -> Void
    ) -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()
        var prog = SyncProgress(
            totalBytes: plan.bytesToCopy, copiedBytes: 0,
            totalItems: plan.totalOperations, completedItems: 0, currentPath: "")
        var lastEmit = Date.distantPast

        func emit(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
            lastEmit = now
            progress(prog)
        }

        func recordFailure(_ rel: String, _ message: String) {
            result.failures.append(ItemFailure(id: UUID(), relativePath: rel, message: message))
        }

        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()
        let archiveBase = destRoot
            .appendingPathComponent(archiveRootName)
            .appendingPathComponent(stamp)

        func archive(_ destRel: String) throws {
            let from = destRoot.appendingPathComponent(destRel)
            var to = archiveBase.appendingPathComponent(destRel)
            // On an archive path collision, append a sequence number; never overwrite already-archived content
            if fm.fileExists(atPath: to.path) {
                let parent = to.deletingLastPathComponent()
                let name = to.lastPathComponent
                var index = 2
                while fm.fileExists(atPath: parent.appendingPathComponent("\(name)-\(index)").path) {
                    index += 1
                }
                to = parent.appendingPathComponent("\(name)-\(index)")
            }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let originalFlags = try clearRenameBlockingFlags(atPath: from.path)
            do {
                try fm.moveItem(at: from, to: to)
            } catch {
                restoreFileFlags(originalFlags, atPath: from.path)
                throw error
            }
            restoreFileFlags(originalFlags, atPath: to.path)
            result.archiveFolder = "\(archiveRootName)/\(stamp)"
        }

        func process(_ item: PlanItem) throws {
            let srcURL = sourceRoot.appendingPathComponent(item.relativePath)
            let destRel = item.destRelativePath ?? item.relativePath
            let destURL = destRoot.appendingPathComponent(destRel)
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            switch item.kind {
            case .directory:
                // Only happens on a type conflict: B has a file with the same name, so archive it first, then create the directory
                try archive(destRel)
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

            case .symlink(let target):
                if item.reason == .typeConflict {
                    try archive(destRel)
                } else if item.reason != .new {
                    let originalFlags = try clearRenameBlockingFlags(atPath: destURL.path)
                    do {
                        try fm.removeItem(at: destURL)
                    } catch {
                        restoreFileFlags(originalFlags, atPath: destURL.path)
                        throw error
                    }
                }
                try fm.createSymbolicLink(atPath: destURL.path, withDestinationPath: target)

            case .file:
                if item.reason == .typeConflict {
                    try archive(destRel)
                } else if archiveReplaced, item.reason != .new,
                          fm.fileExists(atPath: destURL.path) {
                    try archive(destRel)
                }
                let tmpURL = destURL.deletingLastPathComponent()
                    .appendingPathComponent(".dmtmp-\(UUID().uuidString.prefix(8))")
                let base = prog.copiedBytes
                do {
                    let copiedMetadata = try copyFilePreservingMetadata(
                        from: srcURL.path, to: tmpURL.path,
                        onBytes: { n in
                            prog.copiedBytes = base + min(n, item.size)
                            emit()
                        },
                        isCancelled: { cancel.isCancelled })
                    // Copy to a temporary file first, then replace atomically, so an interruption never leaves a half-written file
                    let replacedFlags = try clearRenameBlockingFlags(atPath: destURL.path)
                    if rename(tmpURL.path, destURL.path) != 0 {
                        let code = errno
                        restoreFileFlags(replacedFlags, atPath: destURL.path)
                        removeCopyTemporaryItem(atPath: tmpURL.path)
                        throw CopyFailure(path: destRel, code: code)
                    }
                    restoreFileFlags(copiedMetadata.flags, atPath: destURL.path)
                } catch {
                    removeCopyTemporaryItem(atPath: tmpURL.path)
                    throw error
                }
                prog.copiedBytes = base + item.size
                result.bytesCopied += item.size
            }
        }

        // 1) Handle extra items on B (clear the way first, so leftovers from type conflicts can be moved)
        if orphanPolicy == .keep {
            prog.completedItems += plan.orphans.count
        } else {
            for item in plan.orphans {
                if cancel.isCancelled { result.wasCancelled = true; break }
                prog.currentPath = item.relativePath
                autoreleasepool {
                    do {
                        switch orphanPolicy {
                        case .keep:
                            break
                        case .archive:
                            try archive(item.relativePath)
                            result.orphansHandled += 1
                        case .trash:
                            try fm.trashItem(
                                at: destRoot.appendingPathComponent(item.relativePath),
                                resultingItemURL: nil)
                            result.orphansHandled += 1
                        }
                    } catch {
                        recordFailure(item.relativePath, error.localizedDescription)
                    }
                }
                prog.completedItems += 1
                emit()
            }
        }

        // 2) Updates (including type conflicts: the old item in the way must be moved aside before creating directories)
        if !result.wasCancelled {
            for item in plan.updates {
                if cancel.isCancelled { result.wasCancelled = true; break }
                prog.currentPath = item.relativePath
                emit()
                var cancelled = false
                autoreleasepool {
                    do {
                        try process(item)
                        result.updated += 1
                    } catch is CancellationError {
                        cancelled = true
                    } catch {
                        recordFailure(item.relativePath, error.localizedDescription)
                    }
                }
                prog.completedItems += 1
                if cancelled { result.wasCancelled = true; break }
            }
        }

        // 3) Create directories missing on B
        if !result.wasCancelled {
            for rel in plan.dirCreates {
                if cancel.isCancelled { result.wasCancelled = true; break }
                autoreleasepool {
                    do {
                        try fm.createDirectory(
                            at: destRoot.appendingPathComponent(rel),
                            withIntermediateDirectories: true)
                        result.dirsCreated += 1
                    } catch {
                        recordFailure(rel, error.localizedDescription)
                    }
                }
                prog.completedItems += 1
                emit()
            }
        }

        // 4) Copy new files
        if !result.wasCancelled {
            for item in plan.copies {
                if cancel.isCancelled { result.wasCancelled = true; break }
                prog.currentPath = item.relativePath
                emit()
                var cancelled = false
                autoreleasepool {
                    do {
                        try process(item)
                        result.copied += 1
                    } catch is CancellationError {
                        cancelled = true
                    } catch {
                        recordFailure(item.relativePath, error.localizedDescription)
                    }
                }
                prog.completedItems += 1
                if cancelled { result.wasCancelled = true; break }
            }
        }

        prog.currentPath = ""
        emit(force: true)
        return result
    }
}
