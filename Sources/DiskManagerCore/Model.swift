import Foundation

/// The kind of a filesystem entry
public enum EntryKind: Equatable, Sendable {
    case file
    case directory
    case symlink(target: String)

    public var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }
}

/// A single scanned entry
public struct FileEntry: Equatable, Sendable {
    /// The actual relative path on disk (original Unicode form preserved)
    public let relativePath: String
    public let kind: EntryKind
    public let size: Int64
    public let modified: Date

    public init(relativePath: String, kind: EntryKind, size: Int64, modified: Date) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// The scan result for one directory tree
public struct ScanResult: Sendable {
    /// Keys are NFC-normalized relative paths, so differing Unicode forms on A and B are not misjudged as different files
    public var entries: [String: FileEntry] = [:]
    /// Whether the filesystem holding the scan root treats filenames as case-sensitive.
    /// When comparing two sides, if either is case-insensitive, case-insensitive keys must be used;
    /// otherwise "Foo" and "foo" are mistaken for two paths that can coexist.
    public var caseSensitiveNames: Bool
    public var fileCount = 0
    public var dirCount = 0
    public var totalBytes: Int64 = 0
    public var failures: [String] = []

    public init(caseSensitiveNames: Bool = true) {
        self.caseSensitiveNames = caseSensitiveNames
    }

    public static func normalizedKey(_ path: String, caseSensitive: Bool = true) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return normalized }
        return normalized
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    public mutating func add(_ entry: FileEntry) {
        let key = Self.normalizedKey(entry.relativePath)
        if entries[key] != nil {
            failures.append("Duplicate name after Unicode normalization, skipped: \(entry.relativePath)")
            return
        }
        entries[key] = entry
        switch entry.kind {
        case .directory:
            dirCount += 1
        case .file:
            fileCount += 1
            totalBytes += entry.size
        case .symlink:
            fileCount += 1
        }
    }
}

public struct ScanError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
