import DiskManagerCore
import Foundation

/// The three operation modes. A = target space (the reference; never modified), B = operated space (gets modified);
/// the opposite direction is achieved with the UI's "swap", so there are no separate B→A / A−B modes anymore.
enum SyncMode: String, CaseIterable, Identifiable {
    case mirror
    case difference
    case union

    var id: String { rawValue }

    @MainActor var localizedTitle: String {
        switch self {
        case .mirror: return tr("鏡像", "Mirror")
        case .difference: return tr("差集", "Difference")
        case .union: return tr("聯集", "Union")
        }
    }

    @MainActor var localizedExplanation: String {
        switch self {
        case .mirror:
            return tr("讓被操作空間跟上目標空間的狀態（以目標空間為準的單向鏡像）；目標空間不會被更動。",
                      "Bring the working space up to the target space's state (one-way mirror, target wins). The target space is never changed.")
        case .difference:
            return tr("只列出被操作空間有、目標空間沒有的項目，確認後從被操作空間移除；不會複製或覆蓋任何檔案。",
                      "List only items that exist in the working space but not in the target space, then remove them from the working space after review. Nothing is copied or overwritten.")
        case .union:
            return tr("兩邊互補檔案；同檔不同內容時取修改時間較新者，被覆蓋的舊版會先封存。無法判斷的衝突不會被更動。",
                      "Fill both sides; when a file differs, the newer one wins and the replaced version is archived first. Undecidable conflicts are left untouched.")
        }
    }

    var isUnion: Bool { self == .union }
    var isDifferenceCleanup: Bool { self == .difference }

    /// Mapping from the legacy (v0.2) five modes; `swap` in the return value means the A/B paths need to be swapped
    static func migrate(legacy raw: String) -> (mode: SyncMode, swap: Bool)? {
        switch raw {
        case "aToB": return (.mirror, false)
        case "bToA": return (.mirror, true)
        case "aMinusB": return (.difference, true)
        case "bMinusA": return (.difference, false)
        default: return nil
        }
    }
}

struct BreakdownSlice: Identifiable {
    let name: String
    let bytes: Int64
    var id: String { name }
}

struct DriveUsageData {
    let role: String            // "A" / "B"
    let path: String
    let volumeName: String
    let total: Int64
    let free: Int64
    let breakdown: [BreakdownSlice]
    var incoming: Int64 = 0     // Amount expected to be written by this sync
}

/// The complete result of one scan-and-compare (depends on mode: one-way mirror or union)
struct PlanBundle {
    let mode: SyncMode
    let forward: SyncPlan           // Direction is always →B
    let reverse: SyncPlan?          // Union mode only: the →A half
    let unresolved: [UnresolvedConflict]
    let usageA: DriveUsageData
    let usageB: DriveUsageData

    var totalBytes: Int64 { forward.bytesToCopy + (reverse?.bytesToCopy ?? 0) }
    var totalOperations: Int { forward.totalOperations + (reverse?.totalOperations ?? 0) }
    var isEmpty: Bool { totalOperations == 0 && unresolved.isEmpty }
}

struct SyncOutcome: Identifiable {
    enum Direction { case toA, toB }
    let id = UUID()
    let direction: Direction
    let result: SyncResult
}

func topLevelBreakdown(of scan: ScanResult, cap: Int = 8) -> [BreakdownSlice] {
    var sums: [String: Int64] = [:]
    for entry in scan.entries.values {
        guard case .file = entry.kind else { continue }
        let top = entry.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? entry.relativePath
        sums[top, default: 0] += entry.size
    }
    let sorted = sums.sorted { $0.value > $1.value }
    var slices = sorted.prefix(cap).map { BreakdownSlice(name: $0.key, bytes: $0.value) }
    let rest = sorted.dropFirst(cap).reduce(Int64(0)) { $0 + $1.value }
    if rest > 0 { slices.append(BreakdownSlice(name: "__other__", bytes: rest)) }
    return slices
}

func makeDriveUsage(role: String, url: URL, scan: ScanResult) -> DriveUsageData {
    let values = try? url.resourceValues(forKeys: [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ])
    return DriveUsageData(
        role: role,
        path: url.path,
        volumeName: values?.volumeName ?? url.lastPathComponent,
        total: Int64(values?.volumeTotalCapacity ?? 0),
        free: values?.volumeAvailableCapacityForImportantUsage ?? 0,
        breakdown: topLevelBreakdown(of: scan))
}

func makePlanBundle(mode: SyncMode, a: ScanResult, b: ScanResult, aURL: URL, bURL: URL) -> PlanBundle {
    var usageA = makeDriveUsage(role: "A", url: aURL, scan: a)
    var usageB = makeDriveUsage(role: "B", url: bURL, scan: b)
    switch mode {
    case .mirror:
        let plan = Differ.diff(source: a, dest: b)
        usageB.incoming = plan.bytesToCopy
        return PlanBundle(mode: mode, forward: plan, reverse: nil, unresolved: [],
                          usageA: usageA, usageB: usageB)
    case .difference:
        // A is the reference and B the operated space; Differ's orphans are exactly B − A.
        let plan = Differ.differenceOnly(reference: a, target: b)
        return PlanBundle(mode: mode, forward: plan, reverse: nil, unresolved: [],
                          usageA: usageA, usageB: usageB)
    case .union:
        let union = Differ.unionDiff(a: a, b: b)
        usageB.incoming = union.aToB.bytesToCopy
        usageA.incoming = union.bToA.bytesToCopy
        return PlanBundle(mode: mode, forward: union.aToB, reverse: union.bToA,
                          unresolved: union.unresolved, usageA: usageA, usageB: usageB)
    }
}
