import Foundation

/// Exports a comparison plan or junk scan result as JSON for human or AI analysis.
///
/// When `itemLimit` is nil the full list is exported (for saving to disk). When handing the result to an AI the list may
/// run to hundreds of thousands of entries, so pass a limit: only the N largest items are kept, and the JSON marks `truncated` and the original count;
/// per-folder and per-category totals are always complete and unaffected by the limit.
public enum ReportJSONExporter {
    // MARK: - Sync plan

    public struct PlanInput: Sendable {
        public var mode: String
        public var aPath: String
        public var bPath: String
        public var toB: SyncPlan
        public var toA: SyncPlan?
        public var unresolved: [UnresolvedConflict]

        public init(mode: String, aPath: String, bPath: String,
                    toB: SyncPlan, toA: SyncPlan? = nil, unresolved: [UnresolvedConflict] = []) {
            self.mode = mode
            self.aPath = aPath
            self.bPath = bPath
            self.toB = toB
            self.toA = toA
            self.unresolved = unresolved
        }
    }

    private struct PlanDocument: Encodable {
        struct Space: Encodable {
            let path: String
            let role: String
        }
        struct Operation: Encodable {
            let direction: String
            let action: String
            let reason: String?
            let kind: String
            let path: String
            let size_bytes: Int64
        }
        struct Totals: Encodable {
            var copy = 0
            var update = 0
            var create_dir = 0
            var extra = 0
            var bytes_to_copy: Int64 = 0
            var extra_bytes: Int64 = 0
        }
        struct FolderTotal: Encodable {
            let direction: String
            let action: String
            let top_level_folder: String
            let items: Int
            let size_bytes: Int64
        }
        struct Conflict: Encodable {
            let path: String
            let kind: String
            let a_size_bytes: Int64
            let a_modified: String
            let b_size_bytes: Int64
            let b_modified: String
        }

        let tool = "DiskManager"
        let kind = "sync_plan"
        let exported_at: String
        let mode: String
        let a: Space
        let b: Space
        let totals: [String: Totals]
        let folder_totals: [FolderTotal]
        let operations_total: Int
        let operations_listed: Int
        let truncated: Bool
        let operations: [Operation]
        let unresolved: [Conflict]
        let scan_failures: [String]
    }

    public static func planJSON(
        _ input: PlanInput,
        itemLimit: Int? = nil,
        pretty: Bool = true,
        exportedAt: Date = Date()
    ) throws -> String {
        let dates = ISO8601DateFormatter()
        var operations: [PlanDocument.Operation] = []
        var totals: [String: PlanDocument.Totals] = [:]

        func collect(_ plan: SyncPlan, direction: String) {
            var total = PlanDocument.Totals()
            total.copy = plan.copies.count
            total.update = plan.updates.count
            total.create_dir = plan.dirCreates.count
            total.extra = plan.orphans.count
            total.bytes_to_copy = plan.bytesToCopy
            total.extra_bytes = plan.orphanBytes
            totals[direction] = total

            for (action, items) in [("copy", plan.copies), ("update", plan.updates), ("extra", plan.orphans)] {
                for item in items {
                    operations.append(.init(
                        direction: direction, action: action, reason: item.reason.exportName,
                        kind: item.kind.exportName, path: item.relativePath, size_bytes: item.size))
                }
            }
            for path in plan.dirCreates {
                operations.append(.init(
                    direction: direction, action: "create_dir", reason: nil,
                    kind: "directory", path: path, size_bytes: 0))
            }
        }
        collect(input.toB, direction: "to_b")
        if let toA = input.toA { collect(toA, direction: "to_a") }

        struct FolderKey: Hashable {
            let direction: String
            let action: String
            let folder: String
        }
        var folders: [FolderKey: (items: Int, bytes: Int64)] = [:]
        for operation in operations {
            let top = operation.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? operation.path
            let key = FolderKey(direction: operation.direction, action: operation.action, folder: top)
            let current = folders[key] ?? (0, 0)
            folders[key] = (current.items + 1, current.bytes + operation.size_bytes)
        }
        let folderTotals = folders
            .map { PlanDocument.FolderTotal(
                direction: $0.key.direction, action: $0.key.action, top_level_folder: $0.key.folder,
                items: $0.value.items, size_bytes: $0.value.bytes) }
            .sorted { ($0.size_bytes, $1.top_level_folder) > ($1.size_bytes, $0.top_level_folder) }

        let listed = limited(operations, itemLimit) { $0.size_bytes }
        var failures = input.toB.scanFailures
        if failures.isEmpty, let toA = input.toA { failures = toA.scanFailures }

        let document = PlanDocument(
            exported_at: dates.string(from: exportedAt),
            mode: input.mode,
            a: .init(path: input.aPath, role: input.toA == nil ? "target_reference_unchanged" : "union_member"),
            b: .init(path: input.bPath, role: input.toA == nil ? "working_space_modified" : "union_member"),
            totals: totals,
            folder_totals: folderTotals,
            operations_total: operations.count,
            operations_listed: listed.count,
            truncated: listed.count < operations.count,
            operations: listed,
            unresolved: input.unresolved.map {
                .init(path: $0.relativePath, kind: $0.kind.exportName,
                      a_size_bytes: $0.aSize, a_modified: dates.string(from: $0.aModified),
                      b_size_bytes: $0.bSize, b_modified: dates.string(from: $0.bModified))
            },
            scan_failures: failures)
        return try encode(document, pretty: pretty)
    }

    // MARK: - Junk scan

    private struct JunkDocument: Encodable {
        struct Item: Encodable {
            let category: String
            let subcategory: String
            let path: String
            let size_bytes: Int64
            let is_directory: Bool
            let modified: String
        }
        struct SubcategoryTotal: Encodable {
            let category: String
            let subcategory: String
            let items: Int
            let size_bytes: Int64
        }
        struct DuplicateFile: Encodable {
            let path: String
            let modified: String
        }
        struct Duplicate: Encodable {
            let fingerprint: String
            let file_size_bytes: Int64
            let wasted_bytes: Int64
            let files: [DuplicateFile]
        }
        struct Folder: Encodable {
            let path: String
            let size_bytes: Int64
            let files: Int
        }
        struct SimilarFolders: Encodable {
            let similarity: Double
            let matching_files: Int
            let matching_bytes: Int64
            let first: Folder
            let second: Folder
        }
        struct Listing: Encodable {
            let total: Int
            let listed: Int
            let truncated: Bool
        }

        let tool = "DiskManager"
        let kind = "junk_scan"
        let exported_at: String
        let root: String
        let scanned_files: Int
        let subcategory_totals: [SubcategoryTotal]
        let listing: [String: Listing]
        let items: [Item]
        let duplicate_groups: [Duplicate]
        let similar_folder_groups: [SimilarFolders]
        let scan_failures: [String]
    }

    public static func junkJSON(
        report: JunkReport,
        rootPath: String,
        itemLimit: Int? = nil,
        pretty: Bool = true,
        exportedAt: Date = Date()
    ) throws -> String {
        let dates = ISO8601DateFormatter()
        var items: [JunkDocument.Item] = []
        var subtotals: [JunkDocument.SubcategoryTotal] = []
        for category in JunkCategory.allCases where category != .duplicates && category != .similarFolders {
            let found = report.items(for: category)
            for item in found {
                items.append(.init(
                    category: category.rawValue, subcategory: item.detail, path: item.relativePath,
                    size_bytes: item.size, is_directory: item.isDirectory,
                    modified: dates.string(from: item.modified)))
            }
            for (detail, group) in Dictionary(grouping: found, by: \.detail) {
                subtotals.append(.init(
                    category: category.rawValue, subcategory: detail, items: group.count,
                    size_bytes: group.reduce(0) { $0 + $1.size }))
            }
        }
        subtotals.sort { ($0.size_bytes, $1.subcategory) > ($1.size_bytes, $0.subcategory) }

        let duplicates = report.duplicateGroups.map { group in
            JunkDocument.Duplicate(
                fingerprint: group.fingerprint, file_size_bytes: group.fileSize,
                wasted_bytes: group.wastedBytes,
                files: group.files.map { .init(path: $0.relativePath, modified: dates.string(from: $0.modified)) })
        }
        let similar = report.similarFolderGroups.map { group in
            JunkDocument.SimilarFolders(
                similarity: group.similarity, matching_files: group.matchingFiles,
                matching_bytes: group.matchingBytes,
                first: .init(path: group.first.relativePath, size_bytes: group.first.size,
                             files: group.firstFileCount),
                second: .init(path: group.second.relativePath, size_bytes: group.second.size,
                              files: group.secondFileCount))
        }

        let listedItems = limited(items, itemLimit) { $0.size_bytes }
        let listedDuplicates = limited(duplicates, itemLimit) { $0.wasted_bytes }
        let listedSimilar = limited(similar, itemLimit) { $0.matching_bytes }
        func listing(_ total: Int, _ listed: Int) -> JunkDocument.Listing {
            .init(total: total, listed: listed, truncated: listed < total)
        }

        let document = JunkDocument(
            exported_at: dates.string(from: exportedAt),
            root: rootPath,
            scanned_files: report.scannedFiles,
            subcategory_totals: subtotals,
            listing: [
                "items": listing(items.count, listedItems.count),
                "duplicate_groups": listing(duplicates.count, listedDuplicates.count),
                "similar_folder_groups": listing(similar.count, listedSimilar.count),
            ],
            items: listedItems,
            duplicate_groups: listedDuplicates,
            similar_folder_groups: listedSimilar,
            scan_failures: report.failures)
        return try encode(document, pretty: pretty)
    }

    // MARK: - Shared

    /// When over the limit, keep only the N largest items; otherwise preserve the original order
    private static func limited<T>(_ values: [T], _ limit: Int?, by size: (T) -> Int64) -> [T] {
        guard let limit, values.count > limit else { return values }
        return Array(values.sorted { size($0) > size($1) }.prefix(limit))
    }

    private static func encode<T: Encodable>(_ value: T, pretty: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private extension PlanItem.Reason {
    var exportName: String {
        switch self {
        case .new: return "new"
        case .sizeChanged: return "size_changed"
        case .timeChanged: return "time_changed"
        case .linkChanged: return "link_changed"
        case .typeConflict: return "type_conflict"
        case .extraneous: return "extraneous"
        }
    }
}

private extension EntryKind {
    var exportName: String {
        switch self {
        case .file: return "file"
        case .directory: return "directory"
        case .symlink: return "symlink"
        }
    }
}

private extension UnresolvedConflict.Kind {
    var exportName: String {
        switch self {
        case .typeMismatch: return "type_mismatch"
        case .ambiguous: return "ambiguous"
        case .linkMismatch: return "link_mismatch"
        }
    }
}
