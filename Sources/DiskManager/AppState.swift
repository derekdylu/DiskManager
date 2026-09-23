import DiskManagerCore
import Foundation
import SwiftUI

/// A subcategory under a top-level category in the junk report (e.g. .DS_Store / AppleDouble / Spotlight index under system cruft)
struct JunkSubgroup: Identifiable, Sendable {
    let category: JunkCategory
    let key: String           // Normalized subcategory key (JunkItem.detail)
    let items: [JunkItem]
    let paths: [String]
    let totalBytes: Int64

    var id: String { category.rawValue + "|" + key }
}

/// Groups the report by "category → subcategory"; may process hundreds of thousands of items, so call on a background thread
func groupJunkReport(_ report: JunkReport) -> [JunkCategory: [JunkSubgroup]] {
    var result: [JunkCategory: [JunkSubgroup]] = [:]
    for category in JunkCategory.allCases
        where category != .duplicates && category != .similarFolders {
        let items = report.items(for: category)
        guard !items.isEmpty else { continue }
        result[category] = Dictionary(grouping: items, by: \.detail)
            .map { key, groupItems in
                let sorted = groupItems.sorted { $0.size > $1.size }
                return JunkSubgroup(
                    category: category, key: key, items: sorted,
                    paths: sorted.map(\.relativePath),
                    totalBytes: sorted.reduce(0) { $0 + $1.size })
            }
            .sorted { $0.totalBytes > $1.totalBytes }
    }
    return result
}

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case idle
        case scanning
        case plan(PlanBundle)
        case syncing
        case finished([SyncOutcome])
    }

    enum Tab: Hashable {
        case sync
        case cleanup
    }

    enum JunkPhase {
        case idle
        case scanning(label: String, progress: WorkProgress?)
        case report(JunkReport)
        case deleting(WorkProgress)
    }

    /// Which scan is waiting for the user's answer to the Full Disk Access prompt
    enum PendingScan {
        case sync
        case junk
    }

    // MARK: Permissions

    @Published var fullDiskAccessGranted = FullDiskAccess.isGranted
    @Published var fullDiskAccessPrompt: PendingScan?
    /// "Continue without it" was chosen once — don't nag again until the next launch
    private var skipFullDiskAccessPrompt = false

    // MARK: Sync

    @Published var tab: Tab = .sync
    @Published var phase: Phase = .idle
    @Published var syncMode: SyncMode {
        didSet {
            UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode")
            if syncMode.isDifferenceCleanup && orphanPolicy == .keep {
                orphanPolicy = .archive
            }
            rebuildPlanIfPossible()
        }
    }
    @Published var sourceURL: URL? {   // A: target space (the reference; never modified)
        didSet { savePath("sourcePath", sourceURL); spaceDidChange() }
    }
    @Published var destURL: URL? {     // B: operated space
        didSet { savePath("destPath", destURL); spaceDidChange() }
    }
    @Published var orphanPolicy: OrphanPolicy = .archive
    /// Scan progress for A and B; nil while that side has not started (B waits for A)
    @Published var scanProgressA: WorkProgress?
    @Published var scanProgressB: WorkProgress?
    /// True while the plan is being recomputed from cached scans (no per-item progress available)
    @Published var isRebuildingPlan = false
    @Published var progress: SyncProgress?
    /// Bytes-based view of `progress` with rate and ETA
    @Published var syncWork: WorkProgress?
    @Published var alertMessage: String?
    @Published var syncStarted: Date?
    @Published var syncElapsed: TimeInterval?

    // MARK: Cleanup

    @Published var junkTargetURL: URL? {
        didSet { savePath("junkTargetPath", junkTargetURL) }
    }
    @Published var junkPhase: JunkPhase = .idle
    /// Categories to check in this scan (duplicate comparison is slow; you can tick only the junk categories)
    @Published var junkCategories: Set<JunkCategory> {
        didSet {
            UserDefaults.standard.set(junkCategories.map(\.rawValue).sorted(), forKey: "junkCategories")
        }
    }
    /// Categories actually checked by the last scan; the report should only show these
    @Published private(set) var scannedJunkCategories: Set<JunkCategory> = []
    @Published var junkSelection: Set<String> = []
    @Published var junkSummary: String?
    @Published var quickCleanPending: JunkReport?
    @Published var directDeletePending: Int?    // Number of items awaiting confirmation for direct deletion
    @Published var junkSubgroups: [JunkCategory: [JunkSubgroup]] = [:]
    var junkCategoryPaths: [JunkCategory: [String]] = [:]
    var junkSizeMap: [String: Int64] = [:]

    /// When a folder and files inside it are both selected, only the topmost folder actually needs processing.
    var effectiveJunkSelection: [String] {
        let shallowFirst = junkSelection.sorted {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            return lhsDepth != rhsDepth ? lhsDepth < rhsDepth : $0 < $1
        }
        var result: [String] = []
        for path in shallowFirst where !result.contains(where: { path.hasPrefix($0 + "/") }) {
            result.append(path)
        }
        return result
    }

    // MARK: Power

    @Published var keepDisplayAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayAwake, forKey: "keepDisplayAwake")
            applyDisplayAssertion()
        }
    }

    private let displayAssertion = PowerAssertion()
    private let busyAssertion = PowerAssertion()
    private let cancelFlag = CancelFlag()
    private let scanTrackerA = ProgressTracker(unit: .items)
    private let scanTrackerB = ProgressTracker(unit: .items)
    private var syncTracker = ProgressTracker(unit: .bytes)
    private let junkTracker = ProgressTracker(unit: .items)
    private var worker: Task<Void, Never>?
    private var cachedScans: (a: ScanResult, b: ScanResult)?
    private var isSwappingSpaces = false

    init() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.string(forKey: "syncMode")
        var swapSavedPaths = false
        if let mode = savedMode.flatMap(SyncMode.init(rawValue:)) {
            syncMode = mode
        } else if let legacy = savedMode.flatMap(SyncMode.migrate(legacy:)) {
            // v0.2's B→A / A−B become "swap A/B + the same mode"
            syncMode = legacy.mode
            swapSavedPaths = legacy.swap
            defaults.set(legacy.mode.rawValue, forKey: "syncMode")
        } else {
            syncMode = .mirror
        }
        if swapSavedPaths {
            let oldSource = defaults.string(forKey: "sourcePath")
            defaults.set(defaults.string(forKey: "destPath"), forKey: "sourcePath")
            defaults.set(oldSource, forKey: "destPath")
        }
        keepDisplayAwake = defaults.bool(forKey: "keepDisplayAwake")
        if let saved = defaults.stringArray(forKey: "junkCategories") {
            junkCategories = Set(saved.compactMap(JunkCategory.init(rawValue:)))
        } else {
            junkCategories = Set(JunkCategory.allCases)
        }
        sourceURL = restorePath("sourcePath")
        destURL = restorePath("destPath")
        junkTargetURL = restorePath("junkTargetPath")
        cachedScans = nil
        applyDisplayAssertion()
        // Coming back from System Settings: refresh the status so the indicator and the scan buttons follow
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullDiskAccess() }
        }
    }

    func refreshFullDiskAccess() {
        fullDiskAccessGranted = FullDiskAccess.isGranted
    }

    /// Returns true when the scan may start now; otherwise the prompt is shown and the caller must return
    private func ensureFullDiskAccess(for scan: PendingScan) -> Bool {
        refreshFullDiskAccess()
        if fullDiskAccessGranted || skipFullDiskAccessPrompt { return true }
        fullDiskAccessPrompt = scan
        return false
    }

    enum FullDiskAccessChoice {
        case openSettings
        case continueWithout
        case cancel
    }

    func resolveFullDiskAccessPrompt(_ choice: FullDiskAccessChoice) {
        guard let pending = fullDiskAccessPrompt else { return }
        fullDiskAccessPrompt = nil
        switch choice {
        case .openSettings:
            FullDiskAccess.openSystemSettings()
        case .continueWithout:
            skipFullDiskAccessPrompt = true
            switch pending {
            case .sync: startScan()
            case .junk: startJunkScan()
            }
        case .cancel:
            break
        }
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .syncing: return true
        default: break
        }
        switch junkPhase {
        case .scanning, .deleting: return true
        default: break
        }
        return false
    }

    var canScan: Bool { sourceURL != nil && destURL != nil }

    // MARK: - Scanning and comparison

    private func validate() -> String? {
        guard let a = sourceURL, let b = destURL else {
            return tr("請先選擇 A 與 B 兩邊的資料夾。", "Choose folders for both A and B first.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: a.path, isDirectory: &isDir), isDir.boolValue else {
            return tr("A 的資料夾不存在：\(a.path)\n（如果在外接裝置上，接上了嗎？）",
                      "Folder for A not found: \(a.path)\n(If it lives on an external device, is it connected?)")
        }
        guard FileManager.default.fileExists(atPath: b.path, isDirectory: &isDir), isDir.boolValue else {
            return tr("B 的資料夾不存在：\(b.path)\n（如果在外接裝置上，接上了嗎？）",
                      "Folder for B not found: \(b.path)\n(If it lives on an external device, is it connected?)")
        }
        let ap = a.standardizedFileURL.path
        let bp = b.standardizedFileURL.path
        if ap == bp {
            return tr("A 與 B 不能是同一個資料夾。", "A and B cannot be the same folder.")
        }
        if (ap + "/").hasPrefix(bp + "/") || (bp + "/").hasPrefix(ap + "/") {
            return tr("A 與 B 不能互相包含。", "A and B cannot contain each other.")
        }
        return nil
    }

    func startScan() {
        if let message = validate() {
            alertMessage = message
            return
        }
        guard let a = sourceURL, let b = destURL else { return }
        guard ensureFullDiskAccess(for: .sync) else { return }
        cancelFlag.reset()
        phase = .scanning
        isRebuildingPlan = false
        // The total is unknown while walking a tree; a previous scan of the same folder (or the cached one
        // when rescanning) gives an estimate that at least yields a rough ETA.
        scanProgressA = scanTrackerA.start(
            total: cachedScans.map { Int64($0.a.entries.count) } ?? ScanHistory.lastCount(for: a, kind: "tree"),
            isEstimate: true)
        scanProgressB = nil
        syncBusyAssertion()
        let flag = cancelFlag
        let mode = syncMode
        let estimatedB = cachedScans.map { Int64($0.b.entries.count) } ?? ScanHistory.lastCount(for: b, kind: "tree")

        worker = Task.detached(priority: .userInitiated) {
            do {
                let aScan = try TreeScanner.scan(
                    root: a,
                    isCancelled: { flag.isCancelled },
                    progress: { count in
                        Task { @MainActor in
                            self.scanProgressA = self.scanTrackerA.update(completed: Int64(count))
                        }
                    })
                await MainActor.run {
                    ScanHistory.record(aScan.entries.count, for: a, kind: "tree")
                    self.scanProgressA = self.scanTrackerA.update(
                        completed: Int64(aScan.entries.count), total: Int64(aScan.entries.count))
                    self.scanProgressB = self.scanTrackerB.start(total: estimatedB, isEstimate: true)
                }
                let bScan = try TreeScanner.scan(
                    root: b,
                    isCancelled: { flag.isCancelled },
                    progress: { count in
                        Task { @MainActor in
                            self.scanProgressB = self.scanTrackerB.update(completed: Int64(count))
                        }
                    })
                await MainActor.run {
                    ScanHistory.record(bScan.entries.count, for: b, kind: "tree")
                    self.scanProgressB = self.scanTrackerB.update(
                        completed: Int64(bScan.entries.count), total: Int64(bScan.entries.count))
                    self.isRebuildingPlan = true
                }
                let bundle = makePlanBundle(mode: mode, a: aScan, b: bScan, aURL: a, bURL: b)
                await MainActor.run {
                    self.isRebuildingPlan = false
                    self.cachedScans = (aScan, bScan)
                    self.phase = .plan(bundle)
                    self.syncBusyAssertion()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.phase = .idle
                    self.syncBusyAssertion()
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = tr("掃描失敗：", "Scan failed: ") + error.localizedDescription
                    self.phase = .idle
                    self.syncBusyAssertion()
                }
            }
        }
    }

    /// Either A or B path was replaced: the old scan and the on-screen plan no longer match and must be invalidated,
    /// otherwise the old plan would be executed against the new folders.
    private func spaceDidChange() {
        guard !isSwappingSpaces else { return }
        cachedScans = nil
        if case .plan = phase { phase = .idle }
    }

    /// Swaps the target space and the operated space; scan results are swapped along with them, no rescan needed
    func swapSpaces() {
        isSwappingSpaces = true
        (sourceURL, destURL) = (destURL, sourceURL)
        isSwappingSpaces = false
        if let scans = cachedScans {
            cachedScans = (scans.b, scans.a)
            rebuildPlanIfPossible()
        } else if case .plan = phase {
            phase = .idle
        }
    }

    /// When the sync mode changes, immediately recompute the plan from the cached scan results instead of rescanning
    private func rebuildPlanIfPossible() {
        guard case .plan = phase, let scans = cachedScans,
              let a = sourceURL, let b = destURL else { return }
        let mode = syncMode
        phase = .scanning
        scanProgressA = nil
        scanProgressB = nil
        isRebuildingPlan = true
        worker = Task.detached(priority: .userInitiated) {
            let bundle = makePlanBundle(mode: mode, a: scans.a, b: scans.b, aURL: a, bURL: b)
            await MainActor.run {
                self.isRebuildingPlan = false
                self.phase = .plan(bundle)
            }
        }
    }

    // MARK: - Sync execution

    func startSync(with bundle: PlanBundle) {
        guard let a = sourceURL, let b = destURL else { return }
        cancelFlag.reset()
        syncStarted = Date()
        syncElapsed = nil
        progress = SyncProgress(
            totalBytes: bundle.totalBytes, copiedBytes: 0,
            totalItems: bundle.totalOperations, completedItems: 0, currentPath: "")
        // Difference cleanup copies nothing, so its progress is item-based; everything else is byte-based
        let byBytes = bundle.totalBytes > 0
        syncTracker = ProgressTracker(unit: byBytes ? .bytes : .items)
        syncWork = syncTracker.start(total: byBytes ? bundle.totalBytes : Int64(bundle.totalOperations))
        phase = .syncing
        syncBusyAssertion()

        let flag = cancelFlag
        let policy = orphanPolicy
        let mode = bundle.mode
        let combinedBytes = bundle.totalBytes
        let combinedItems = bundle.totalOperations

        worker = Task.detached(priority: .userInitiated) {
            var outcomes: [SyncOutcome] = []

            let firstResult = SyncEngine.execute(
                plan: bundle.forward,
                sourceRoot: a, destRoot: b,
                orphanPolicy: mode.isUnion ? .keep : policy,
                archiveReplaced: mode.isUnion,
                cancel: flag,
                progress: { p in
                    var q = p
                    q.totalBytes = combinedBytes
                    q.totalItems = combinedItems
                    Task { @MainActor in self.publishSyncProgress(q) }
                })
            outcomes.append(SyncOutcome(direction: .toB, result: firstResult))

            if mode.isUnion, let reversePlan = bundle.reverse, !firstResult.wasCancelled {
                let bytesBase = bundle.forward.bytesToCopy
                let itemsBase = bundle.forward.totalOperations
                let secondResult = SyncEngine.execute(
                    plan: reversePlan,
                    sourceRoot: b, destRoot: a,
                    orphanPolicy: .keep,
                    archiveReplaced: true,
                    cancel: flag,
                    progress: { p in
                        var q = p
                        q.totalBytes = combinedBytes
                        q.copiedBytes += bytesBase
                        q.totalItems = combinedItems
                        q.completedItems += itemsBase
                        Task { @MainActor in self.publishSyncProgress(q) }
                    })
                outcomes.append(SyncOutcome(direction: .toA, result: secondResult))
            }

            let finalOutcomes = outcomes
            await MainActor.run {
                self.syncElapsed = self.syncStarted.map { Date().timeIntervalSince($0) }
                self.cachedScans = nil   // Files have changed; the old scan is invalid
                self.phase = .finished(finalOutcomes)
                self.syncBusyAssertion()
            }
        }
    }

    private func publishSyncProgress(_ p: SyncProgress) {
        progress = p
        syncWork = syncTracker.update(
            completed: syncTracker.unit == .bytes ? p.copiedBytes : Int64(p.completedItems),
            detail: p.currentPath)
    }

    func cancelWork() {
        cancelFlag.cancel()
    }

    func backToStart() {
        phase = .idle
        progress = nil
        syncWork = nil
        syncStarted = nil
        syncElapsed = nil
        syncBusyAssertion()
    }

    // MARK: - Junk scanning and cleanup

    func startJunkScan() {
        guard let target = junkTargetURL else {
            alertMessage = tr("請先選擇要掃描的資料夾。", "Choose a folder to scan first.")
            return
        }
        guard !junkCategories.isEmpty else {
            alertMessage = tr("請至少勾選一種要檢查的項目。", "Select at least one item type to check.")
            return
        }
        guard ensureFullDiskAccess(for: .junk) else { return }
        cancelFlag.reset()
        junkSelection = []
        junkSummary = nil
        let walkLabel = tr("掃描檔案清單…", "Walking the file tree…")
        junkPhase = .scanning(
            label: walkLabel,
            progress: junkTracker.start(total: ScanHistory.lastCount(for: target, kind: "junk"), isEstimate: true))
        scannedJunkCategories = junkCategories
        syncBusyAssertion()
        let flag = cancelFlag
        var options = JunkScanOptions()
        options.categories = junkCategories
        let hashLabel = tr("比對重複內容（讀檔計算指紋）…", "Comparing duplicate content (fingerprinting files)…")

        worker = Task.detached(priority: .userInitiated) {
            do {
                let report = try JunkScanner.scan(
                    root: target, options: options,
                    isCancelled: { flag.isCancelled },
                    progress: { phase in
                        Task { @MainActor in
                            switch phase {
                            case .walking(let seen):
                                self.junkPhase = .scanning(
                                    label: walkLabel,
                                    progress: self.junkTracker.update(completed: Int64(seen)))
                            case .hashing(let done, let total):
                                // First hashing callback: the walk is over, restart the meter with the real total
                                if self.junkTracker.total == nil || self.junkTracker.totalIsEstimate {
                                    _ = self.junkTracker.start(total: Int64(total))
                                }
                                self.junkPhase = .scanning(
                                    label: hashLabel,
                                    progress: self.junkTracker.update(completed: Int64(done), total: Int64(total)))
                            }
                        }
                    })
                await MainActor.run {
                    ScanHistory.record(report.enumeratedEntries, for: target, kind: "junk")
                    self.junkPhase = .scanning(label: tr("整理報告…", "Building the report…"), progress: nil)
                }
                let groups = groupJunkReport(report)
                await MainActor.run {
                    self.presentJunkReport(report, groups)
                    self.syncBusyAssertion()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.junkPhase = .idle
                    self.syncBusyAssertion()
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = tr("掃描失敗：", "Scan failed: ") + error.localizedDescription
                    self.junkPhase = .idle
                    self.syncBusyAssertion()
                }
            }
        }
    }

    private func presentJunkReport(_ report: JunkReport, _ groups: [JunkCategory: [JunkSubgroup]]) {
        junkSizeMap = [:]
        for items in report.categorized.values {
            for item in items { junkSizeMap[item.relativePath] = item.size }
        }
        for group in report.duplicateGroups {
            for file in group.files { junkSizeMap[file.relativePath] = file.size }
        }
        for group in report.similarFolderGroups {
            junkSizeMap[group.first.relativePath] = group.first.size
            junkSizeMap[group.second.relativePath] = group.second.size
        }
        junkSubgroups = groups
        junkCategoryPaths = groups.mapValues { $0.flatMap(\.paths) }
        junkPhase = .report(report)
    }

    /// Categories covered by one-click cache cleanup (all regenerable, so deleting is harmless)
    static let quickCleanCategories: [JunkCategory] = [.systemCruft, .thumbnailCache]

    /// One-click cache cleanup: picks system cruft and thumbnail caches out of the completed scan report and, after confirmation, moves them all to the Trash.
    /// It is a post-scan action, so it does not run a separate scan.
    func startQuickClean() {
        guard case .report(let report) = junkPhase else { return }
        var cacheOnly = JunkReport()
        for category in Self.quickCleanCategories {
            cacheOnly.categorized[category] = report.items(for: category)
        }
        if Self.quickCleanCategories.allSatisfy({ cacheOnly.items(for: $0).isEmpty }) {
            alertMessage = tr("沒有找到快取雜物，這裡很乾淨。", "No cache junk found — all clean here.")
        } else {
            quickCleanPending = cacheOnly
        }
    }

    func resolveQuickClean(confirmed: Bool) {
        guard let report = quickCleanPending else { return }
        quickCleanPending = nil
        guard confirmed else { return }
        var paths: [(relativePath: String, size: Int64)] = []
        for category in JunkCategory.allCases {
            for item in report.items(for: category) {
                paths.append((item.relativePath, item.size))
            }
        }
        runJunkDeletion(paths: paths, method: .trash)
    }

    func requestDeleteSelected(method: JunkDeletionMethod) {
        let effectiveSelection = effectiveJunkSelection
        guard !effectiveSelection.isEmpty else { return }
        if method == .delete {
            directDeletePending = effectiveSelection.count
            return
        }
        deleteSelectedNow(method: .trash)
    }

    func resolveDirectDelete(confirmed: Bool) {
        directDeletePending = nil
        if confirmed { deleteSelectedNow(method: .delete) }
    }

    private func deleteSelectedNow(method: JunkDeletionMethod) {
        let paths = effectiveJunkSelection.map { (relativePath: $0, size: junkSizeMap[$0] ?? 0) }
        runJunkDeletion(paths: paths, method: method)
    }

    private func runJunkDeletion(paths: [(relativePath: String, size: Int64)], method: JunkDeletionMethod) {
        guard let target = junkTargetURL, !paths.isEmpty else { return }
        cancelFlag.reset()
        let baseReport: JunkReport? = {
            if case .report(let report) = junkPhase { return report }
            return nil
        }()
        junkPhase = .deleting(junkTracker.start(total: Int64(paths.count)))
        syncBusyAssertion()
        let flag = cancelFlag

        worker = Task.detached(priority: .userInitiated) {
            let result = JunkEngine.remove(
                paths: paths, root: target, method: method, cancel: flag,
                progress: { done, total in
                    Task { @MainActor in
                        self.junkPhase = .deleting(
                            self.junkTracker.update(completed: Int64(done), total: Int64(total)))
                    }
                })
            // Filtering and regrouping may process a large number of items; finish them in the background before returning to the main thread
            let removed = Set(result.deletedPaths)
            let newReport = baseReport?.removingPaths(removed)
            let newGroups = newReport.map { groupJunkReport($0) }
            await MainActor.run {
                self.junkSelection = Set(self.junkSelection.filter { selected in
                    !removed.contains { deleted in
                        selected == deleted || selected.hasPrefix(deleted + "/")
                    }
                })
                if let newReport, let newGroups {
                    self.junkSubgroups = newGroups
                    self.junkCategoryPaths = newGroups.mapValues { $0.flatMap(\.paths) }
                    self.junkPhase = .report(newReport)
                } else {
                    self.junkSubgroups = [:]
                    self.junkCategoryPaths = [:]
                    self.junkPhase = .idle
                }
                var summary = tr("已清除 \(result.deletedCount) 個項目，釋放 \(formatBytes(result.freedBytes))",
                                 "Removed \(result.deletedCount) items, freed \(formatBytes(result.freedBytes))")
                if method == .trash {
                    summary += tr("（在垃圾桶，清空後才真正釋放空間）",
                                  " (in Trash — space frees up after emptying)")
                }
                if !result.failures.isEmpty {
                    summary += tr("；\(result.failures.count) 個失敗", "; \(result.failures.count) failed")
                }
                self.junkSummary = summary
                self.syncBusyAssertion()
            }
        }
    }

    // MARK: - Power assertions

    private func applyDisplayAssertion() {
        if keepDisplayAwake {
            displayAssertion.activate(reason: "DiskManager keep display awake", keepDisplayOn: true)
        } else {
            displayAssertion.release()
        }
    }

    /// Prevents system sleep while a scan / sync / cleanup is in progress (a disk falling asleep mid-work causes trouble)
    private func syncBusyAssertion() {
        if isBusy {
            busyAssertion.activate(reason: "DiskManager working", keepDisplayOn: false)
        } else {
            busyAssertion.release()
        }
    }

    // MARK: - Path persistence

    private func savePath(_ key: String, _ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: key)
    }

    private func restorePath(_ key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

@MainActor
func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return tr("\(s) 秒", "\(s)s") }
    if s < 3600 { return tr("\(s / 60) 分 \(s % 60) 秒", "\(s / 60)m \(s % 60)s") }
    return tr("\(s / 3600) 小時 \((s % 3600) / 60) 分", "\(s / 3600)h \((s % 3600) / 60)m")
}
