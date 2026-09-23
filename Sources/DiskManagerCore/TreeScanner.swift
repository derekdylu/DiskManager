import Foundation

/// Walks an entire directory tree, collecting every file, directory, and symlink
public enum TreeScanner {
    /// System noise and this tool's own archive folder, always skipped during scanning
    public static let excludedNames: Set<String> = [
        ".DS_Store",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".PKInstallSandboxManager",
        ".apdisk",
        ".VolumeIcon.icns",
        ".com.apple.timemachine.donotpresent",
        "System Volume Information",
        "$RECYCLE.BIN",
        SyncEngine.archiveRootName,
    ]

    static func isDiskManagerTemporaryName(_ name: String) -> Bool {
        let prefix = ".dmtmp-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit }
    }

    private static func isExcludedName(_ name: String) -> Bool {
        // SyncEngine's atomic-copy temporary files. Older versions could fail to delete them when hitting a locked file;
        // they must not be treated as user files and synced to the other disk.
        excludedNames.contains(name) || isDiskManagerTemporaryName(name)
    }

    public static func scan(
        root: URL,
        isCancelled: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> ScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError(message: "Folder not found: \(root.path)")
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        var enumeratorErrors: [String] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.producesRelativePathURLs],
            errorHandler: { url, error in
                enumeratorErrors.append("\(url.path)：\(error.localizedDescription)")
                return true
            }
        ) else {
            throw ScanError(message: "Cannot enumerate folder: \(root.path)")
        }

        let volumeValues = try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        var result = ScanResult(
            caseSensitiveNames: volumeValues?.volumeSupportsCaseSensitiveNames ?? true)
        var seen = 0
        let keySet = Set(keys)
        // Wrap each item in an autoreleasepool: Foundation enumeration creates many autoreleased objects,
        // and a background thread has no drain point, so memory grows without bound when scanning a large disk
        while true {
            let hasMore = try autoreleasepool { () -> Bool in
                guard let item = enumerator.nextObject() as? URL else { return false }
                if let isCancelled, isCancelled() { throw CancellationError() }
                seen += 1
                if seen % 250 == 0 { progress?(seen) }

                let rv = try? item.resourceValues(forKeys: keySet)
                let isSymlink = rv?.isSymbolicLink ?? false
                let isDirectory = (rv?.isDirectory ?? false) && !isSymlink

                if isExcludedName(item.lastPathComponent) {
                    if isDirectory { enumerator.skipDescendants() }
                    return true
                }

                let rel = relativePath(of: item, root: root)
                if rel.isEmpty { return true }

                let entry: FileEntry
                if isSymlink {
                    let target = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                    entry = FileEntry(relativePath: rel, kind: .symlink(target: target), size: 0, modified: .distantPast)
                } else if isDirectory {
                    entry = FileEntry(
                        relativePath: rel, kind: .directory, size: 0,
                        modified: rv?.contentModificationDate ?? .distantPast)
                } else {
                    entry = FileEntry(
                        relativePath: rel, kind: .file,
                        size: Int64(rv?.fileSize ?? 0),
                        modified: rv?.contentModificationDate ?? .distantPast)
                }
                result.add(entry)
                return true
            }
            if !hasMore { break }
        }
        result.failures.append(contentsOf: enumeratorErrors)
        progress?(seen)
        return result
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let rp = url.relativePath
        if !rp.hasPrefix("/") && !rp.isEmpty { return rp }
        // Fallback: strip the root prefix manually
        let rootPath = root.standardizedFileURL.path
        var p = url.standardizedFileURL.path
        guard p.hasPrefix(rootPath) else { return rp }
        p.removeFirst(rootPath.count)
        if p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
