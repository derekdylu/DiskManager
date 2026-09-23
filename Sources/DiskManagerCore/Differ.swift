import Foundation

/// What to do with items that exist on B but not on A
public enum OrphanPolicy: String, CaseIterable, Identifiable, Sendable {
    case keep
    case archive
    case trash

    public var id: String { rawValue }
}

/// A single action in a sync plan
public struct PlanItem: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case new            // exists on A, missing on B
        case sizeChanged    // sizes differ
        case timeChanged    // modification times differ
        case linkChanged    // symlink targets differ
        case typeConflict   // same name, but a file on one side and a directory on the other
        case extraneous     // exists on B, missing on A
    }

    /// Actual relative path on the A side (for extraneous, the B-side path)
    public let relativePath: String
    /// Actual relative path already present on the B side (its Unicode form may differ from A)
    public let destRelativePath: String?
    public let kind: EntryKind
    public let size: Int64
    public let reason: Reason

    public var id: String { relativePath }

    public init(relativePath: String, destRelativePath: String?, kind: EntryKind, size: Int64, reason: Reason) {
        self.relativePath = relativePath
        self.destRelativePath = destRelativePath
        self.kind = kind
        self.size = size
        self.reason = reason
    }
}

/// A conflict that union mode cannot resolve automatically (left untouched, only reported)
public struct UnresolvedConflict: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case typeMismatch    // a file on one side, a directory on the other
        case ambiguous       // sizes differ but modification times cannot tell which is newer
        case linkMismatch    // symlink targets differ
    }

    public let relativePath: String
    public let kind: Kind
    public let aKind: EntryKind
    public let aSize: Int64
    public let aModified: Date
    public let bKind: EntryKind
    public let bSize: Int64
    public let bModified: Date

    public var id: String { relativePath }
}

/// Result of a union-mode comparison: fill-in plans for both directions plus the conflicts that cannot be handled
public struct UnionPlan: Sendable {
    public var aToB = SyncPlan()
    public var bToA = SyncPlan()
    public var unresolved: [UnresolvedConflict] = []
    public init() {}
}

/// The sync plan produced by scanning and comparing (no files have been touched yet)
public struct SyncPlan: Sendable {
    public var copies: [PlanItem] = []       // new files, to be copied to B
    public var updates: [PlanItem] = []      // present on both sides but different; A overwrites B
    public var dirCreates: [String] = []     // directories missing on B
    public var orphans: [PlanItem] = []      // extra items on B (top level only)
    public var bytesToCopy: Int64 = 0
    public var orphanBytes: Int64 = 0
    public var sourceFileCount = 0
    public var destFileCount = 0
    public var scanFailures: [String] = []

    public init() {}

    public var totalOperations: Int {
        copies.count + updates.count + dirCreates.count + orphans.count
    }
    public var isEmpty: Bool { totalOperations == 0 }
}

public enum Differ {
    /// Filesystems such as exFAT store timestamps with only 2-second precision; allow a tolerance when comparing to avoid endlessly re-copying
    public static let mtimeTolerance: TimeInterval = 2.0

    private struct ComparisonIndex {
        var entries: [String: FileEntry] = [:]
        var collisionPaths: [String: [String]] = [:]
    }

    /// Converts one side's scan result into the keys needed for this A/B comparison.
    /// If either side's filesystem is case-insensitive, both sides must be case-folded;
    /// otherwise directories differing only in case are misreported as missing and collide on the actual write.
    private static func comparisonIndex(
        _ scan: ScanResult,
        caseSensitive: Bool
    ) -> ComparisonIndex {
        var result = ComparisonIndex()
        for entry in scan.entries.values {
            let key = ScanResult.normalizedKey(
                entry.relativePath, caseSensitive: caseSensitive)
            if let existing = result.entries.removeValue(forKey: key) {
                result.collisionPaths[key] = [existing.relativePath, entry.relativePath]
            } else if result.collisionPaths[key] != nil {
                result.collisionPaths[key]!.append(entry.relativePath)
            } else {
                result.entries[key] = entry
            }
        }
        return result
    }

    private static func comparisonData(
        _ first: ScanResult,
        _ second: ScanResult
    ) -> (
        first: [String: FileEntry],
        second: [String: FileEntry],
        caseSensitive: Bool,
        failures: [String]
    ) {
        let caseSensitive = first.caseSensitiveNames && second.caseSensitiveNames
        var a = comparisonIndex(first, caseSensitive: caseSensitive)
        var b = comparisonIndex(second, caseSensitive: caseSensitive)
        let collisionKeys = Set(a.collisionPaths.keys).union(b.collisionPaths.keys)

        // A case-insensitive destination cannot safely hold both Foo and foo. Leave them and all
        // their children untouched and report the collision as a scan failure, so neither side is silently overwritten or archived.
        if !collisionKeys.isEmpty {
            a.entries = a.entries.filter { key, _ in
                !collisionKeys.contains(key) && !hasAncestor(key, in: collisionKeys)
            }
            b.entries = b.entries.filter { key, _ in
                !collisionKeys.contains(key) && !hasAncestor(key, in: collisionKeys)
            }
        }

        var failures: [String] = []
        for key in collisionKeys.sorted() {
            let paths = (a.collisionPaths[key] ?? []) + (b.collisionPaths[key] ?? [])
            failures.append(
                "Case-insensitive name collision, skipped: " + paths.sorted().joined(separator: " / "))
        }
        return (a.entries, b.entries, caseSensitive, failures)
    }

    public static func diff(source: ScanResult, dest: ScanResult) -> SyncPlan {
        var plan = SyncPlan()
        plan.sourceFileCount = source.fileCount
        plan.destFileCount = dest.fileCount
        let comparison = comparisonData(source, dest)
        let sourceEntries = comparison.first
        let destEntries = comparison.second
        plan.scanFailures =
            source.failures.map { "A：\($0)" } + dest.failures.map { "B：\($0)" }
            + comparison.failures

        // Type conflict where the B side is a directory: the whole directory is archived at once,
        // so its children are not listed individually as "extra on B"
        var conflictDirKeys = Set<String>()

        for (key, s) in sourceEntries {
            guard let d = destEntries[key] else {
                switch s.kind {
                case .directory:
                    plan.dirCreates.append(s.relativePath)
                default:
                    plan.copies.append(PlanItem(
                        relativePath: s.relativePath, destRelativePath: nil,
                        kind: s.kind, size: s.size, reason: .new))
                    plan.bytesToCopy += s.size
                }
                continue
            }

            switch (s.kind, d.kind) {
            case (.directory, .directory):
                break
            case (.file, .file):
                if s.size != d.size {
                    plan.updates.append(PlanItem(
                        relativePath: s.relativePath, destRelativePath: d.relativePath,
                        kind: .file, size: s.size, reason: .sizeChanged))
                    plan.bytesToCopy += s.size
                } else if abs(s.modified.timeIntervalSince(d.modified)) > mtimeTolerance {
                    plan.updates.append(PlanItem(
                        relativePath: s.relativePath, destRelativePath: d.relativePath,
                        kind: .file, size: s.size, reason: .timeChanged))
                    plan.bytesToCopy += s.size
                }
            case (.symlink(let st), .symlink(let dt)):
                if st != dt {
                    plan.updates.append(PlanItem(
                        relativePath: s.relativePath, destRelativePath: d.relativePath,
                        kind: s.kind, size: 0, reason: .linkChanged))
                }
            default:
                let size: Int64 = {
                    if case .file = s.kind { return s.size }
                    return 0
                }()
                if case .directory = d.kind { conflictDirKeys.insert(key) }
                plan.updates.append(PlanItem(
                    relativePath: s.relativePath, destRelativePath: d.relativePath,
                    kind: s.kind, size: size, reason: .typeConflict))
                plan.bytesToCopy += size
            }
        }

        // Extra items on B: report only the top level (if a whole directory is extra, list just the directory itself)
        let destOnlyKeys = Set(destEntries.keys.filter { sourceEntries[$0] == nil })
        for key in destOnlyKeys {
            if hasAncestor(key, in: conflictDirKeys) { continue }
            let d = destEntries[key]!
            if case .file = d.kind { plan.orphanBytes += d.size }
            if hasAncestor(key, in: destOnlyKeys) { continue }
            plan.orphans.append(PlanItem(
                relativePath: d.relativePath, destRelativePath: d.relativePath,
                kind: d.kind, size: d.size, reason: .extraneous))
        }

        // Extra directories aggregate the size of every file beneath them, so the list shows how much they weigh
        var orphanDirIndex: [String: Int] = [:]
        for (index, orphan) in plan.orphans.enumerated() where orphan.kind.isDirectory {
            orphanDirIndex[ScanResult.normalizedKey(
                orphan.relativePath, caseSensitive: comparison.caseSensitive)] = index
        }
        if !orphanDirIndex.isEmpty {
            for key in destOnlyKeys {
                if hasAncestor(key, in: conflictDirKeys) { continue }
                guard let entry = destEntries[key], case .file = entry.kind else { continue }
                var searchStart = key.startIndex
                while let slash = key.range(of: "/", range: searchStart..<key.endIndex) {
                    if let index = orphanDirIndex[String(key[..<slash.lowerBound])] {
                        let old = plan.orphans[index]
                        plan.orphans[index] = PlanItem(
                            relativePath: old.relativePath, destRelativePath: old.destRelativePath,
                            kind: old.kind, size: old.size + entry.size, reason: old.reason)
                        break
                    }
                    searchStart = slash.upperBound
                }
            }
        }

        sortPlan(&plan)
        return plan
    }

    /// Produces a cleanup-only plan for items present on target but absent on reference.
    /// The returned plan never contains copy, overwrite, or directory-creation actions.
    public static func differenceOnly(reference: ScanResult, target: ScanResult) -> SyncPlan {
        var plan = diff(source: reference, dest: target)
        plan.copies = []
        plan.updates = []
        plan.dirCreates = []
        plan.bytesToCopy = 0
        return plan
    }

    /// Union comparison: each side fills in the other's missing files; when the same path differs, the newer modification time wins.
    /// Items whose age cannot be determined (time delta within tolerance but sizes differ) or with type conflicts go into unresolved and are left untouched.
    public static func unionDiff(a: ScanResult, b: ScanResult) -> UnionPlan {
        var union = UnionPlan()
        let comparison = comparisonData(a, b)
        let aEntries = comparison.first
        let bEntries = comparison.second
        union.aToB.sourceFileCount = a.fileCount
        union.aToB.destFileCount = b.fileCount
        union.bToA.sourceFileCount = b.fileCount
        union.bToA.destFileCount = a.fileCount
        union.aToB.scanFailures =
            a.failures.map { "A：\($0)" } + b.failures.map { "B：\($0)" }
            + comparison.failures
        union.bToA.scanFailures = union.aToB.scanFailures

        var unresolvedKeys = Set<String>()

        func recordUnresolved(_ key: String, _ kind: UnresolvedConflict.Kind, _ ae: FileEntry, _ be: FileEntry) {
            unresolvedKeys.insert(key)
            union.unresolved.append(UnresolvedConflict(
                relativePath: ae.relativePath, kind: kind,
                aKind: ae.kind, aSize: ae.size, aModified: ae.modified,
                bKind: be.kind, bSize: be.size, bModified: be.modified))
        }

        for (key, ae) in aEntries {
            guard let be = bEntries[key] else {
                appendMissing(ae, to: &union.aToB)
                continue
            }
            switch (ae.kind, be.kind) {
            case (.directory, .directory):
                break
            case (.file, .file):
                let delta = ae.modified.timeIntervalSince(be.modified)
                if ae.size == be.size && abs(delta) <= mtimeTolerance { break }
                if abs(delta) <= mtimeTolerance {
                    recordUnresolved(key, .ambiguous, ae, be)
                } else if delta > 0 {
                    union.aToB.updates.append(PlanItem(
                        relativePath: ae.relativePath, destRelativePath: be.relativePath,
                        kind: .file, size: ae.size,
                        reason: ae.size != be.size ? .sizeChanged : .timeChanged))
                    union.aToB.bytesToCopy += ae.size
                } else {
                    union.bToA.updates.append(PlanItem(
                        relativePath: be.relativePath, destRelativePath: ae.relativePath,
                        kind: .file, size: be.size,
                        reason: ae.size != be.size ? .sizeChanged : .timeChanged))
                    union.bToA.bytesToCopy += be.size
                }
            case (.symlink(let at), .symlink(let bt)):
                if at != bt { recordUnresolved(key, .linkMismatch, ae, be) }
            default:
                recordUnresolved(key, .typeMismatch, ae, be)
            }
        }

        for (key, be) in bEntries where aEntries[key] == nil {
            appendMissing(be, to: &union.bToA)
        }

        // Never touch anything beneath a conflicting item (e.g. when A has a directory and B a file of the same name, the directory contents are not copied)
        if !unresolvedKeys.isEmpty {
            func blocked(_ path: String) -> Bool {
                hasAncestor(
                    ScanResult.normalizedKey(
                        path, caseSensitive: comparison.caseSensitive),
                    in: unresolvedKeys)
            }
            for plan in [\UnionPlan.aToB, \UnionPlan.bToA] {
                union[keyPath: plan].copies.removeAll { blocked($0.relativePath) }
                union[keyPath: plan].updates.removeAll { blocked($0.relativePath) }
                union[keyPath: plan].dirCreates.removeAll { blocked($0) }
                union[keyPath: plan].bytesToCopy =
                    union[keyPath: plan].copies.reduce(0) { $0 + $1.size }
                    + union[keyPath: plan].updates.reduce(0) { $0 + $1.size }
            }
            union.unresolved.sort { $0.relativePath < $1.relativePath }
        }

        sortPlan(&union.aToB)
        sortPlan(&union.bToA)
        return union
    }

    private static func appendMissing(_ entry: FileEntry, to plan: inout SyncPlan) {
        switch entry.kind {
        case .directory:
            plan.dirCreates.append(entry.relativePath)
        default:
            plan.copies.append(PlanItem(
                relativePath: entry.relativePath, destRelativePath: nil,
                kind: entry.kind, size: entry.size, reason: .new))
            plan.bytesToCopy += entry.size
        }
    }

    private static func sortPlan(_ plan: inout SyncPlan) {
        plan.copies.sort { $0.relativePath < $1.relativePath }
        plan.updates.sort { $0.relativePath < $1.relativePath }
        plan.orphans.sort { $0.relativePath < $1.relativePath }
        plan.dirCreates.sort {
            let a = $0.components(separatedBy: "/").count
            let b = $1.components(separatedBy: "/").count
            return a != b ? a < b : $0 < $1
        }
    }

    private static func hasAncestor(_ key: String, in set: Set<String>) -> Bool {
        var searchStart = key.startIndex
        while let slash = key.range(of: "/", range: searchStart..<key.endIndex) {
            if set.contains(String(key[..<slash.lowerBound])) { return true }
            searchStart = slash.upperBound
        }
        return false
    }
}
