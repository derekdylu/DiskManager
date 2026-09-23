import Foundation

public enum JunkDeletionMethod: Sendable {
    case trash
    case delete
}

public struct JunkDeletionResult: Sendable {
    public var deletedCount = 0
    public var freedBytes: Int64 = 0
    public var deletedPaths: [String] = []
    public var failures: [ItemFailure] = []
    public var wasCancelled = false

    public init() {}
}

public enum JunkEngine {
    public static func remove(
        paths: [(relativePath: String, size: Int64)],
        root: URL,
        method: JunkDeletionMethod,
        cancel: CancelFlag,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> JunkDeletionResult {
        let fm = FileManager.default
        var result = JunkDeletionResult()

        // If a folder and files inside it are both selected, handle only the topmost folder,
        // to avoid trashing twice, double-counting sizes, or the parent failing later because it is already incomplete.
        let unique = Dictionary(grouping: paths, by: \.relativePath).values.compactMap { entries in
            entries.max { $0.size < $1.size }
        }
        let shallowFirst = unique.sorted {
            let lhsDepth = $0.relativePath.split(separator: "/").count
            let rhsDepth = $1.relativePath.split(separator: "/").count
            return lhsDepth != rhsDepth ? lhsDepth < rhsDepth : $0.relativePath < $1.relativePath
        }
        var normalized: [(relativePath: String, size: Int64)] = []
        for entry in shallowFirst {
            let covered = normalized.contains {
                entry.relativePath.hasPrefix($0.relativePath + "/")
            }
            if !covered { normalized.append(entry) }
        }

        let ordered = normalized.sorted {
            $0.relativePath.components(separatedBy: "/").count
                > $1.relativePath.components(separatedBy: "/").count
        }

        for (index, entry) in ordered.enumerated() {
            if cancel.isCancelled {
                result.wasCancelled = true
                break
            }
            if index % 10 == 0 { progress?(index, ordered.count) }
            autoreleasepool {
                let url = root.appendingPathComponent(entry.relativePath)
                let isInternalTemporaryFile = TreeScanner.isDiskManagerTemporaryName(
                    url.lastPathComponent)
                let originalFlags = isInternalTemporaryFile
                    ? try? clearRenameBlockingFlags(atPath: url.path)
                    : nil
                do {
                    switch method {
                    case .trash:
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    case .delete:
                        try fm.removeItem(at: url)
                    }
                    result.deletedCount += 1
                    result.freedBytes += entry.size
                    result.deletedPaths.append(entry.relativePath)
                } catch {
                    if let originalFlags {
                        restoreFileFlags(originalFlags, atPath: url.path)
                    }
                    // If the parent directory was already moved away, the child naturally no longer exists; not an error
                    if !fm.fileExists(atPath: url.path) {
                        result.deletedPaths.append(entry.relativePath)
                    } else {
                        result.failures.append(ItemFailure(
                            id: UUID(), relativePath: entry.relativePath,
                            message: error.localizedDescription))
                    }
                }
            }
        }
        progress?(ordered.count, ordered.count)
        return result
    }
}
