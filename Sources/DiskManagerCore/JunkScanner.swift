import CryptoKit
import Darwin
import Foundation

public enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case fcpCache        // regenerable media in FCP / iMovie libraries (Render, Proxy, Optimized media, ...)
    case diskImages      // disk images (SD card backups: .img/.dmg/.iso, etc.)
    case systemCruft     // system cruft such as .DS_Store, AppleDouble files, Spotlight indexes
    case thumbnailCache  // thumbnail and video-editor caches
    case duplicates      // duplicate files
    case similarFolders  // folders whose contents overlap heavily; candidates for removal as a whole

    public var id: String { rawValue }
}

public struct JunkItem: Identifiable, Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let isDirectory: Bool
    public let modified: Date
    /// Subtype description, e.g. "Proxy Media", ".DS_Store", "Spotlight index"
    public let detail: String

    public var id: String { relativePath }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let fingerprint: String
    public let fileSize: Int64
    /// Sorted by modification time, newest first
    public let files: [JunkItem]

    public var id: String { fingerprint }
    public var wastedBytes: Int64 { fileSize * Int64(max(0, files.count - 1)) }
}

/// Two folders whose recursive file contents overlap heavily. Similarity is "matching file count / the larger of the two folders' file counts".
public struct SimilarFolderGroup: Identifiable, Sendable {
    public let first: JunkItem
    public let second: JunkItem
    public let matchingFiles: Int
    public let firstFileCount: Int
    public let secondFileCount: Int
    public let matchingBytes: Int64
    public let similarity: Double

    public var id: String { first.relativePath + "\u{0}" + second.relativePath }
    public var potentialBytes: Int64 { min(first.size, second.size) }
}

public struct JunkReport: Sendable {
    public var categorized: [JunkCategory: [JunkItem]] = [:]
    public var duplicateGroups: [DuplicateGroup] = []
    public var similarFolderGroups: [SimilarFolderGroup] = []
    public var scannedFiles = 0
    /// Every entry the walk visited (files, folders, skipped ones) — the same count the walking progress reports
    public var enumeratedEntries = 0
    public var failures: [String] = []

    public init() {}

    public func items(for category: JunkCategory) -> [JunkItem] {
        categorized[category] ?? []
    }

    public func totalBytes(for category: JunkCategory) -> Int64 {
        if category == .duplicates {
            return duplicateGroups.reduce(0) { $0 + $1.wastedBytes }
        }
        if category == .similarFolders {
            return similarFolderGroups.reduce(0) { $0 + $1.potentialBytes }
        }
        return items(for: category).reduce(0) { $0 + $1.size }
    }

    /// After some items are deleted, returns a new report with those paths filtered out
    public func removingPaths(_ removed: Set<String>) -> JunkReport {
        var report = self
        for (category, items) in report.categorized {
            report.categorized[category] = items.filter { !removed.contains($0.relativePath) }
        }
        report.duplicateGroups = report.duplicateGroups.compactMap { group in
            let remaining = group.files.filter { !removed.contains($0.relativePath) }
            guard remaining.count >= 2 else { return nil }
            return DuplicateGroup(fingerprint: group.fingerprint, fileSize: group.fileSize, files: remaining)
        }
        // Once a whole folder or individual files in a group are deleted, the old similarity is stale; drop the affected candidates from the report until a rescan lists them again.
        report.similarFolderGroups.removeAll { group in
            removed.contains { path in
                path == group.first.relativePath || path == group.second.relativePath
                    || path.hasPrefix(group.first.relativePath + "/")
                    || path.hasPrefix(group.second.relativePath + "/")
            }
        }
        return report
    }
}

public enum JunkScanPhase: Sendable {
    case walking(seen: Int)
    case hashing(done: Int, total: Int)
}

public struct JunkScanOptions: Sendable {
    public var categories: Set<JunkCategory> = Set(JunkCategory.allCases)
    /// Files smaller than this are excluded from duplicate comparison (default 10 MB)
    public var duplicateMinSize: Int64 = 10 * 1024 * 1024
    /// Minimum content overlap ratio for similar folders (0...1, default 80%)
    public var similarFolderThreshold: Double = 0.8
    /// A folder must contain at least this many files to be listed as similar, so two single-file folders do not create noise
    public var similarFolderMinFiles: Int = 5

    public init() {}
}

public enum JunkScanner {
    private struct FingerprintCandidate: Sendable {
        let relativePath: String
        let size: Int64
        let modified: Date
    }

    private struct FolderStats: Sendable {
        var fileCount = 0
        var bytes: Int64 = 0
        var modified = Date.distantPast
    }

    private struct FolderPair: Hashable {
        let first: String
        let second: String

        init(_ a: String, _ b: String) {
            if a < b {
                first = a
                second = b
            } else {
                first = b
                second = a
            }
        }
    }

    private struct FolderOverlap {
        var files = 0
        var bytes: Int64 = 0
    }

    /// Regenerable media folders inside FCP / iMovie libraries (never include Original Media!)
    static let fcpRegenerableDirNames: Set<String> = [
        "Render Files", "Proxy Media", "High Quality Media",
        "Peaks Data", "Analysis Files", "Thumbnail Media",
    ]
    static let libraryBundleSuffixes = [".fcpbundle", ".imovielibrary"]

    static let cruftFileNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini", ".apdisk"]
    static let cruftRootDirNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
    ]
    static let cacheDirNames: Set<String> = [
        ".thumbnails", "Media Cache", "Media Cache Files", "Peak Files",
    ]
    static let diskImageExtensions: Set<String> = ["dmg", "img", "iso", "sparseimage", "cdr", "toast"]

    /// Directories skipped entirely during scanning (leave the safety net and the trash alone)
    static let skipEntirely: Set<String> = [SyncEngine.archiveRootName, ".Trashes"]

    public static func scan(
        root: URL,
        options: JunkScanOptions = JunkScanOptions(),
        isCancelled: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (JunkScanPhase) -> Void)? = nil
    ) throws -> JunkReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError(message: "Folder not found: \(root.path)")
        }

        var report = JunkReport()
        var fingerprintCandidates: [FingerprintCandidate] = []
        var folderStats: [String: FolderStats] = [:]

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        var enumeratorErrors: [String] = []
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.producesRelativePathURLs],
            errorHandler: { url, error in
                enumeratorErrors.append("\(url.path)：\(error.localizedDescription)")
                return true
            })
        else {
            throw ScanError(message: "Cannot enumerate folder: \(root.path)")
        }

        func add(_ category: JunkCategory, _ item: JunkItem) {
            guard options.categories.contains(category) else { return }
            report.categorized[category, default: []].append(item)
        }

        // Foundation's enumerator hides AppleDouble (._) files, so they must be swept separately with readdir
        func sweepAppleDouble(dirURL: URL, dirRel: String) {
            guard options.categories.contains(.systemCruft) else { return }
            for entry in appleDoubleEntries(in: dirURL) {
                let rel = dirRel.isEmpty ? entry.name : dirRel + "/" + entry.name
                add(.systemCruft, JunkItem(
                    relativePath: rel, size: entry.size, isDirectory: false,
                    modified: entry.modified, detail: "AppleDouble"))
            }
        }
        sweepAppleDouble(dirURL: root, dirRel: "")

        var seen = 0
        let keySet = Set(keys)
        // autoreleasepool: same as TreeScanner, prevents memory from piling up during large enumerations
        while true {
            let hasMore = try autoreleasepool { () -> Bool in
                guard let url = enumerator.nextObject() as? URL else { return false }
                if let isCancelled, isCancelled() { throw CancellationError() }
                seen += 1
                if seen % 250 == 0 { progress?(.walking(seen: seen)) }

                let name = url.lastPathComponent
                let rel = TreeScanner.relativePath(of: url, root: root)
                if rel.isEmpty { return true }

                let rv = try? url.resourceValues(forKeys: keySet)
                let isSymlink = rv?.isSymbolicLink ?? false
                let isDirectory = (rv?.isDirectory ?? false) && !isSymlink
                let modified = rv?.contentModificationDate ?? .distantPast

                if isDirectory {
                    if skipEntirely.contains(name) {
                        enumerator.skipDescendants()
                        return true
                    }
                    if fcpRegenerableDirNames.contains(name), isInsideLibraryBundle(rel) {
                        let size = directorySize(url)
                        add(.fcpCache, JunkItem(
                            relativePath: rel, size: size, isDirectory: true,
                            modified: modified, detail: name))
                        enumerator.skipDescendants()
                        return true
                    }
                    if cruftRootDirNames.contains(name) {
                        let size = directorySize(url)
                        add(.systemCruft, JunkItem(
                            relativePath: rel, size: size, isDirectory: true,
                            modified: modified, detail: name))
                        enumerator.skipDescendants()
                        return true
                    }
                    if cacheDirNames.contains(name) || name.hasSuffix("Previews.lrdata") {
                        // Use a normalized subcategory key for detail so caches of the same kind group together
                        let detail: String
                        if cacheDirNames.contains(name) {
                            detail = name
                        } else if name.hasSuffix("Smart Previews.lrdata") {
                            detail = "Smart Previews.lrdata"
                        } else {
                            detail = "Previews.lrdata"
                        }
                        let size = directorySize(url)
                        add(.thumbnailCache, JunkItem(
                            relativePath: rel, size: size, isDirectory: true,
                            modified: modified, detail: detail))
                        enumerator.skipDescendants()
                        return true
                    }
                    if options.categories.contains(.similarFolders) {
                        folderStats[rel, default: FolderStats()].modified = modified
                    }
                    sweepAppleDouble(dirURL: url, dirRel: rel)
                    return true
                }

                if isSymlink { return true }

                let size = Int64(rv?.fileSize ?? 0)

                if name.hasPrefix("._") { return true }   // already handled by the readdir sweep; avoid double counting
                if TreeScanner.isDiskManagerTemporaryName(name) {
                    add(.systemCruft, JunkItem(
                        relativePath: rel, size: size, isDirectory: false,
                        modified: modified, detail: "DiskManager temporary file"))
                    return true
                }
                if cruftFileNames.contains(name) {
                    add(.systemCruft, JunkItem(
                        relativePath: rel, size: size, isDirectory: false,
                        modified: modified, detail: name))
                    return true
                }

                let ext = (name as NSString).pathExtension.lowercased()
                if diskImageExtensions.contains(ext) {
                    add(.diskImages, JunkItem(
                        relativePath: rel, size: size, isDirectory: false,
                        modified: modified, detail: ".\(ext)"))
                    // Disk images may still duplicate each other, so keep them in the duplicate comparison
                }

                report.scannedFiles += 1
                if options.categories.contains(.similarFolders) {
                    for folder in ancestorFolders(ofFile: rel) {
                        folderStats[folder, default: FolderStats()].fileCount += 1
                        folderStats[folder, default: FolderStats()].bytes += size
                    }
                }
                let neededForFileDuplicates = options.categories.contains(.duplicates)
                    && size >= options.duplicateMinSize
                let neededForFolderSimilarity = options.categories.contains(.similarFolders) && size > 0
                if neededForFileDuplicates || neededForFolderSimilarity {
                    fingerprintCandidates.append(FingerprintCandidate(
                        relativePath: rel, size: size, modified: modified))
                }
                return true
            }
            if !hasMore { break }
        }
        progress?(.walking(seen: seen))
        report.enumeratedEntries = seen

        // Duplicates and similar folders share fingerprints: narrow by size first, then SHA-256 of the first and last 1 MiB.
        if options.categories.contains(.duplicates) || options.categories.contains(.similarFolders) {
            var bySize: [Int64: [FingerprintCandidate]] = [:]
            for candidate in fingerprintCandidates {
                bySize[candidate.size, default: []].append(candidate)
            }
            let needHash = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
            var byFingerprint: [String: [FingerprintCandidate]] = [:]
            for (index, candidate) in needHash.enumerated() {
                if let isCancelled, isCancelled() { throw CancellationError() }
                if index % 20 == 0 { progress?(.hashing(done: index, total: needHash.count)) }
                // autoreleasepool is required: each file reads 2 MiB of Data, and without draining promptly
                // memory explodes when comparing tens of thousands of files
                autoreleasepool {
                    do {
                        let fp = try quickFingerprint(
                            url: root.appendingPathComponent(candidate.relativePath),
                            size: candidate.size)
                        byFingerprint[fp, default: []].append(candidate)
                    } catch {
                        enumeratorErrors.append("\(candidate.relativePath)：\(error.localizedDescription)")
                    }
                }
            }
            progress?(.hashing(done: needHash.count, total: needHash.count))

            if options.categories.contains(.duplicates) {
                report.duplicateGroups = byFingerprint
                    .filter { $0.value.count > 1 && ($0.value.first?.size ?? 0) >= options.duplicateMinSize }
                    .map { fingerprint, files in
                        DuplicateGroup(
                            fingerprint: fingerprint,
                            fileSize: files[0].size,
                            files: files
                                .sorted { $0.modified > $1.modified }
                                .map {
                                    JunkItem(
                                        relativePath: $0.relativePath, size: $0.size,
                                        isDirectory: false, modified: $0.modified, detail: "duplicate")
                                })
                    }
                    .sorted { $0.wastedBytes > $1.wastedBytes }
            }
            if options.categories.contains(.similarFolders) {
                report.similarFolderGroups = makeSimilarFolderGroups(
                    fingerprints: byFingerprint,
                    folderStats: folderStats,
                    threshold: options.similarFolderThreshold,
                    minFiles: options.similarFolderMinFiles)
            }
        }

        for category in JunkCategory.allCases {
            report.categorized[category]?.sort { $0.size > $1.size }
        }
        report.failures = enumeratorErrors
        return report
    }

    /// All folders containing the file (excluding the scan root), nearest first.
    private static func ancestorFolders(ofFile relativePath: String) -> [String] {
        var components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return [] }
        components.removeLast()
        var folders: [String] = []
        while !components.isEmpty {
            folders.append(components.joined(separator: "/"))
            components.removeLast()
        }
        return folders
    }

    private static func isAncestor(_ possibleAncestor: String, of path: String) -> Bool {
        possibleAncestor != path && path.hasPrefix(possibleAncestor + "/")
    }

    private static func covers(_ outer: SimilarFolderGroup, _ inner: SimilarFolderGroup) -> Bool {
        func ancestorOrEqual(_ a: String, _ b: String) -> Bool {
            a == b || isAncestor(a, of: b)
        }
        let sameOrientation = ancestorOrEqual(outer.first.relativePath, inner.first.relativePath)
            && ancestorOrEqual(outer.second.relativePath, inner.second.relativePath)
        let crossed = ancestorOrEqual(outer.first.relativePath, inner.second.relativePath)
            && ancestorOrEqual(outer.second.relativePath, inner.first.relativePath)
        return sameOrientation || crossed
    }

    /// Estimates folder similarity as "intersection of content-fingerprint multisets / the larger file count".
    /// Parent and child folders naturally contain the same files and are never paired as candidates.
    private static func makeSimilarFolderGroups(
        fingerprints: [String: [FingerprintCandidate]],
        folderStats: [String: FolderStats],
        threshold: Double,
        minFiles: Int
    ) -> [SimilarFolderGroup] {
        let requiredFiles = max(1, minFiles)
        let requiredSimilarity = min(1, max(0, threshold))
        let eligible = folderStats.filter { $0.value.fileCount >= requiredFiles }
        guard eligible.count > 1 else { return [] }

        var overlaps: [FolderPair: FolderOverlap] = [:]
        for files in fingerprints.values where files.count > 1 {
            var countsByFolder: [String: Int] = [:]
            for file in files {
                for folder in ancestorFolders(ofFile: file.relativePath) where eligible[folder] != nil {
                    countsByFolder[folder, default: 0] += 1
                }
            }
            let folders = countsByFolder.keys.sorted()
            guard folders.count > 1 else { continue }
            for firstIndex in 0..<(folders.count - 1) {
                let first = folders[firstIndex]
                for secondIndex in (firstIndex + 1)..<folders.count {
                    let second = folders[secondIndex]
                    if isAncestor(first, of: second) || isAncestor(second, of: first) { continue }
                    let matchingCopies = min(countsByFolder[first] ?? 0, countsByFolder[second] ?? 0)
                    guard matchingCopies > 0 else { continue }
                    let key = FolderPair(first, second)
                    overlaps[key, default: FolderOverlap()].files += matchingCopies
                    overlaps[key, default: FolderOverlap()].bytes += Int64(matchingCopies) * files[0].size
                }
            }
        }

        var candidates: [SimilarFolderGroup] = []
        for (pair, overlap) in overlaps {
            guard let firstStats = eligible[pair.first], let secondStats = eligible[pair.second] else { continue }
            let denominator = max(firstStats.fileCount, secondStats.fileCount)
            guard denominator > 0 else { continue }
            let similarity = Double(overlap.files) / Double(denominator)
            guard similarity + Double.ulpOfOne >= requiredSimilarity else { continue }
            candidates.append(SimilarFolderGroup(
                first: JunkItem(
                    relativePath: pair.first, size: firstStats.bytes, isDirectory: true,
                    modified: firstStats.modified, detail: "similar folder"),
                second: JunkItem(
                    relativePath: pair.second, size: secondStats.bytes, isDirectory: true,
                    modified: secondStats.modified, detail: "similar folder"),
                matchingFiles: overlap.files,
                firstFileCount: firstStats.fileCount,
                secondFileCount: secondStats.fileCount,
                matchingBytes: overlap.bytes,
                similarity: similarity))
        }

        // Once a pair of ancestor folders meets the threshold, do not emit a flood of nested duplicate candidates.
        candidates.sort {
            let lhsDepth = $0.first.relativePath.split(separator: "/").count
                + $0.second.relativePath.split(separator: "/").count
            let rhsDepth = $1.first.relativePath.split(separator: "/").count
                + $1.second.relativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.potentialBytes > $1.potentialBytes
        }
        var pruned: [SimilarFolderGroup] = []
        for candidate in candidates where !pruned.contains(where: { covers($0, candidate) }) {
            pruned.append(candidate)
        }
        return pruned.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.potentialBytes != $1.potentialBytes { return $0.potentialBytes > $1.potentialBytes }
            return $0.id < $1.id
        }
    }

    static func isInsideLibraryBundle(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { component in
            libraryBundleSuffixes.contains { component.hasSuffix($0) }
        }
    }

    /// Lists the AppleDouble (._) files in a directory via POSIX readdir; Foundation's APIs cannot see them
    static func appleDoubleEntries(in dirURL: URL) -> [(name: String, size: Int64, modified: Date)] {
        guard let dir = opendir(dirURL.path) else { return [] }
        defer { closedir(dir) }
        var results: [(name: String, size: Int64, modified: Date)] = []
        while let entry = readdir(dir) {
            var nameBuffer = entry.pointee.d_name
            let name = withUnsafeBytes(of: &nameBuffer) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            guard name.hasPrefix("._") else { continue }
            var status = stat()
            let fullPath = dirURL.appendingPathComponent(name).path
            guard lstat(fullPath, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { continue }
            results.append((
                name,
                Int64(status.st_size),
                Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))))
        }
        return results
    }

    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [], errorHandler: { _, _ in true })
        while true {
            let hasMore = autoreleasepool { () -> Bool in
                guard let item = enumerator?.nextObject() as? URL else { return false }
                let rv = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if rv?.isRegularFile == true { total += Int64(rv?.fileSize ?? 0) }
                return true
            }
            if !hasMore { break }
        }
        return total
    }

    /// Quick fingerprint: SHA-256 of the first and last 1 MiB (plus the file size).
    /// Not a full-file comparison, but same size plus matching head/tail hashes is almost certainly identical; the UI labels these "very likely duplicates".
    static func quickFingerprint(url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk = 1 << 20
        var hasher = SHA256()
        let head = try handle.read(upToCount: chunk) ?? Data()
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try handle.seek(toOffset: UInt64(size - Int64(chunk)))
            let tail = try handle.read(upToCount: chunk) ?? Data()
            hasher.update(data: tail)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined() + "-\(size)"
    }
}
