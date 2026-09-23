import AppKit
import DiskManagerCore
import SwiftUI

struct JunkView: View {
    private enum DuplicatePane: Hashable {
        case files
        case folders
    }

    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n
    @State private var duplicatePane: DuplicatePane = .files

    private let subRowCap = 200
    private let groupCap = 100

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
                .disabled(state.isBusy)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(tr("一鍵清除快取", "Quick cache clean"),
               isPresented: quickCleanBinding) {
            Button(tr("丟到垃圾桶", "Move to Trash")) { state.resolveQuickClean(confirmed: true) }
            Button(tr("取消", "Cancel"), role: .cancel) { state.resolveQuickClean(confirmed: false) }
        } message: {
            Text(quickCleanMessage)
        }
        .alert(tr("直接刪除", "Delete permanently"),
               isPresented: directDeleteBinding) {
            Button(tr("刪除", "Delete"), role: .destructive) { state.resolveDirectDelete(confirmed: true) }
            Button(tr("取消", "Cancel"), role: .cancel) { state.resolveDirectDelete(confirmed: false) }
        } message: {
            Text(tr("將永久刪除 \(state.directDeletePending ?? 0) 個項目，無法復原。確定嗎？（比較保險的做法是先丟垃圾桶）",
                    "This permanently deletes \(state.directDeletePending ?? 0) items — no undo. Continue? (Moving to Trash is the safer option.)"))
        }
    }

    private var quickCleanBinding: Binding<Bool> {
        Binding(
            get: { state.quickCleanPending != nil },
            set: { if !$0 && state.quickCleanPending != nil { state.resolveQuickClean(confirmed: false) } })
    }

    private var directDeleteBinding: Binding<Bool> {
        Binding(
            get: { state.directDeletePending != nil },
            set: { if !$0 && state.directDeletePending != nil { state.resolveDirectDelete(confirmed: false) } })
    }

    private var quickCleanMessage: String {
        guard let report = state.quickCleanPending else { return "" }
        let count = JunkCategory.allCases.reduce(0) { $0 + report.items(for: $1).count }
        let bytes = JunkCategory.allCases.reduce(Int64(0)) { $0 + report.totalBytes(for: $1) }
        return tr("找到 \(count) 個快取雜物（.DS_Store、縮圖、媒體快取等），共 \(formatBytes(bytes))。全部丟到垃圾桶？",
                  "Found \(count) cache files (.DS_Store, thumbnails, media caches…), \(formatBytes(bytes)) total. Move them all to Trash?")
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            FolderPickerRow(
                title: tr("清理目標", "Cleanup target"),
                subtitle: tr("要掃描垃圾檔的儲存空間或資料夾", "Storage space or folder to scan for junk"),
                url: $state.junkTargetURL)
            Divider()
            categoryPicker
            HStack {
                Button {
                    state.startJunkScan()
                } label: {
                    Label(tr("掃描垃圾檔", "Scan for Junk"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.junkTargetURL == nil || state.junkCategories.isEmpty)

                Spacer()
                if let summary = state.junkSummary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    /// Which items to check: junk categories are fast; duplicate comparison reads files to compute fingerprints, which is much slower, and can be left unticked.
    /// The header row's checkbox toggles everything; each row's leading checkbox toggles that row.
    private var categoryPicker: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: groupBinding(JunkCategory.allCases)) {
                Text(tr("檢查項目", "Check for")).font(.headline)
            }
            .toggleStyle(.checkbox)
            .help(tr("全選／全部取消", "Select all / none"))
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                categoryToggles(junkCategories, label: tr("垃圾檔", "Junk"))
                categoryToggles(duplicateCategories,
                                label: tr("重複比對（要讀檔算指紋，較慢）", "Duplicate content (reads files, slower)"))
            }
            Spacer()
        }
    }

    private let junkCategories: [JunkCategory] = [.fcpCache, .thumbnailCache, .systemCruft, .diskImages]
    private let duplicateCategories: [JunkCategory] = [.duplicates, .similarFolders]

    private func categoryToggles(_ categories: [JunkCategory], label: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle(isOn: groupBinding(categories)) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .help(tr("整列全選／取消", "Select / clear this row"))
            .frame(width: 230, alignment: .leading)
            // Items wrap as whole units (checkbox + icon + text); the text itself never breaks
            FlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(categories) { category in
                    Toggle(isOn: Binding(
                        get: { state.junkCategories.contains(category) },
                        set: { on in
                            if on { state.junkCategories.insert(category) } else { state.junkCategories.remove(category) }
                        })) {
                        Label(category.localizedTitle, systemImage: icon(for: category))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .toggleStyle(.checkbox)
                    .help(category.localizedHint)
                }
            }
        }
    }

    /// Checked when every category in the group is selected; setting it selects or clears the whole group
    private func groupBinding(_ categories: [JunkCategory]) -> Binding<Bool> {
        Binding(
            get: { categories.allSatisfy { state.junkCategories.contains($0) } },
            set: { on in
                if on { state.junkCategories.formUnion(categories) } else { state.junkCategories.subtract(categories) }
            })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.junkPhase {
        case .idle:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "trash.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(tr("掃出儲存空間裡可以清掉的東西", "Find what can be cleaned off your storage"))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(JunkCategory.allCases) { category in
                        Label {
                            Text(category.localizedTitle).bold()
                            + Text("　" + category.localizedHint).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: icon(for: category))
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                Text(tr("上方可勾選這次要檢查的項目。掃描只讀不寫；找到的東西全部先列清單，勾選後才刪，預設丟垃圾桶。",
                        "Pick which item types to check above. Scanning is read-only. Everything found is listed first; nothing is deleted until you select and confirm. Default is Trash."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

        case .scanning(let label, let progress):
            VStack(spacing: 14) {
                Spacer()
                ProgressPanel(title: label, progress: progress)
                Button(tr("取消", "Cancel")) { state.cancelWork() }
                Spacer()
            }

        case .deleting(let progress):
            VStack(spacing: 14) {
                Spacer()
                ProgressPanel(title: tr("清除中…", "Removing…"), progress: progress)
                Button(tr("取消", "Cancel")) { state.cancelWork() }
                Spacer()
            }

        case .report(let report):
            reportView(report)
        }
    }

    private func icon(for category: JunkCategory) -> String {
        switch category {
        case .fcpCache: return "film.stack"
        case .diskImages: return "opticaldiscdrive"
        case .systemCruft: return "gearshape.2"
        case .thumbnailCache: return "photo.on.rectangle.angled"
        case .duplicates: return "doc.on.doc"
        case .similarFolders: return "folder.badge.questionmark"
        }
    }

    // MARK: - Scan report

    private func reportView(_ report: JunkReport) -> some View {
        VStack(spacing: 0) {
            List {
                ForEach(junkCategories) { category in
                    if let subgroups = state.junkSubgroups[category], !subgroups.isEmpty {
                        categorySection(category, subgroups: subgroups)
                    }
                }
                if scannedDuplicates {
                    duplicateResultsSection(report)
                }
                if allEmpty(report) {
                    Text(tr("🎉 沒有找到可清理的垃圾檔。", "🎉 No junk found."))
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
            .listStyle(.inset)
            Divider()
            footer(report)
                .padding(10)
        }
    }

    private var scannedDuplicates: Bool {
        !state.scannedJunkCategories.isDisjoint(with: duplicateCategories)
    }

    private func allEmpty(_ report: JunkReport) -> Bool {
        report.duplicateGroups.isEmpty && report.similarFolderGroups.isEmpty
            && JunkCategory.allCases.allSatisfy { report.items(for: $0).isEmpty }
    }

    @ViewBuilder
    private func categorySection(_ category: JunkCategory, subgroups: [JunkSubgroup]) -> some View {
        let totalCount = subgroups.reduce(0) { $0 + $1.items.count }
        let totalBytes = subgroups.reduce(Int64(0)) { $0 + $1.totalBytes }
        Section {
            ForEach(subgroups) { subgroup in
                subgroupView(subgroup)
            }
        } header: {
            HStack {
                Toggle(isOn: selectAllBinding(paths: state.junkCategoryPaths[category] ?? [])) {
                    Text("\(category.localizedTitle)（\(totalCount)・\(formatBytes(totalBytes))）")
                        .font(.headline)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .help(category.localizedHint)
        }
    }

    /// Subcategory: whole-group checkbox + count + size; individual files are visible only when expanded
    private func subgroupView(_ subgroup: JunkSubgroup) -> some View {
        DisclosureGroup {
            ForEach(subgroup.items.prefix(subRowCap)) { item in
                itemRow(item)
            }
            if subgroup.items.count > subRowCap {
                Text(tr("…僅顯示前 \(subRowCap) 筆，共 \(subgroup.items.count) 筆（勾選子類別仍會涵蓋全部）。",
                        "…showing first \(subRowCap) of \(subgroup.items.count) (checking the subcategory still covers everything)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Toggle(isOn: selectAllBinding(paths: subgroup.paths)) {
                HStack(spacing: 8) {
                    Text(junkSubcategoryLabel(subgroup.key))
                        .lineLimit(1)
                    Text(tr("\(subgroup.items.count) 項・\(formatBytes(subgroup.totalBytes))",
                            "\(subgroup.items.count) items · \(formatBytes(subgroup.totalBytes))"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private func duplicateResultsSection(_ report: JunkReport) -> some View {
        Section {
            Picker(tr("重複掃描分區", "Duplicate scan view"), selection: $duplicatePane) {
                Text(tr("單一檔案群組（\(report.duplicateGroups.count)）",
                        "File groups (\(report.duplicateGroups.count))"))
                    .tag(DuplicatePane.files)
                Text(tr("資料夾群組 80%+（\(report.similarFolderGroups.count)）",
                        "Folder groups 80%+ (\(report.similarFolderGroups.count))"))
                    .tag(DuplicatePane.folders)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch duplicatePane {
            case .files:
                if state.scannedJunkCategories.contains(.duplicates) {
                    duplicateFileRows(report.duplicateGroups)
                } else {
                    emptyDuplicateMessage(tr("這次沒有勾選「重複檔案」。", "\"Duplicates\" was not checked in this scan."))
                }
            case .folders:
                if state.scannedJunkCategories.contains(.similarFolders) {
                    duplicateFolderRows(report.similarFolderGroups)
                } else {
                    emptyDuplicateMessage(tr("這次沒有勾選「相似資料夾」。", "\"Similar folders\" was not checked in this scan."))
                }
            }
        } header: {
            HStack {
                Label(tr("重複內容掃描", "Duplicate content scan"), systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Menu {
                    Button(tr("整份掃描報告 JSON（適合交給 AI 或程式分析）",
                              "Whole scan report as JSON (for AI or scripts)")) {
                        exportReportJSON(report)
                    }
                    Button(tr("重複內容 TSV（Numbers／Excel）", "Duplicate content TSV (Numbers / Excel)")) {
                        exportDuplicateResults(report)
                    }
                    .disabled(report.duplicateGroups.isEmpty && report.similarFolderGroups.isEmpty)
                } label: {
                    Label(tr("匯出完整結果…", "Export full results…"),
                          systemImage: "square.and.arrow.up")
                }
                .font(.caption)
                .fixedSize()
                .disabled(allEmpty(report))
            }
        }
    }

    @ViewBuilder
    private func duplicateFileRows(_ groups: [DuplicateGroup]) -> some View {
        if groups.isEmpty {
            emptyDuplicateMessage(tr("沒有找到符合大小門檻的重複檔案。",
                                     "No duplicate files matching the size threshold were found."))
        } else {
            HStack {
                Text(tr("共 \(groups.count) 組，預計可省 \(formatBytes(groups.reduce(0) { $0 + $1.wastedBytes }))",
                        "\(groups.count) groups, \(formatBytes(groups.reduce(0) { $0 + $1.wastedBytes })) reclaimable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("每組保留最新的一份", "Keep newest of each group")) {
                    for group in groups {
                        for file in group.files.dropFirst() {
                            state.junkSelection.insert(file.relativePath)
                        }
                    }
                }
                .font(.caption)
            }
            ForEach(groups.prefix(groupCap)) { group in
                DisclosureGroup {
                    ForEach(group.files) { file in
                        itemRow(file, note: file.relativePath == group.files.first?.relativePath
                            ? tr("最新", "newest") : nil)
                    }
                } label: {
                    Text(tr("\(group.files.count) 份 × \(formatBytes(group.fileSize))　可省 \(formatBytes(group.wastedBytes))",
                            "\(group.files.count) copies × \(formatBytes(group.fileSize)) — save \(formatBytes(group.wastedBytes))"))
                        .font(.callout)
                }
            }
            if groups.count > groupCap {
                Text(tr("…介面僅顯示前 \(groupCap) 組，匯出檔會包含全部 \(groups.count) 組。",
                        "…showing the first \(groupCap) groups here; the export contains all \(groups.count)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func duplicateFolderRows(_ groups: [SimilarFolderGroup]) -> some View {
        Text(tr("以資料夾為群組，比較遞迴檔案的內容指紋；每夾至少 5 檔、重疊比例達 80% 才列入，父子資料夾不互相比對。",
                "Groups folders by recursive file-content fingerprints. Each folder needs at least 5 files and 80% overlap; parent and child folders are never paired."))
            .font(.caption)
            .foregroundStyle(.secondary)
        if groups.isEmpty {
            emptyDuplicateMessage(tr("這次沒有找到 80% 以上的相似資料夾。此分區仍會保留，表示掃描已執行。",
                                     "No folder pairs reached 80% similarity. This pane remains visible to confirm the scan ran."))
        } else {
            ForEach(groups.prefix(groupCap)) { group in
                similarFolderGroupRow(group)
            }
            if groups.count > groupCap {
                Text(tr("…介面僅顯示前 \(groupCap) 組，匯出檔會包含全部 \(groups.count) 組。",
                        "…showing the first \(groupCap) groups here; the export contains all \(groups.count)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyDuplicateMessage(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    private func similarFolderGroupRow(_ group: SimilarFolderGroup) -> some View {
        DisclosureGroup {
            Text(tr("兩邊共有 \(group.matchingFiles) 個內容相同的檔案（\(formatBytes(group.matchingBytes))）。請先確認其餘差異，最多勾選一個資料夾。",
                    "The folders share \(group.matchingFiles) content-matching files (\(formatBytes(group.matchingBytes))). Review the remaining differences and select at most one folder."))
                .font(.caption)
                .foregroundStyle(.secondary)
            similarFolderChoice(group.first, otherPath: group.second.relativePath,
                                fileCount: group.firstFileCount)
            similarFolderChoice(group.second, otherPath: group.first.relativePath,
                                fileCount: group.secondFileCount)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("相似度 \(group.similarity.formatted(.percent.precision(.fractionLength(0))))",
                        "\(group.similarity.formatted(.percent.precision(.fractionLength(0)))) similar"))
                    .font(.callout.bold())
                Text("\(group.first.relativePath)  ↔  \(group.second.relativePath)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func exportReportJSON(_ report: JunkReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("DiskManager-清理掃描結果.json", "DiskManager-junk-scan.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportJSONExporter.junkJSON(report: report, rootPath: state.junkTargetURL?.path ?? "")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.alertMessage = tr("匯出失敗：", "Export failed: ") + error.localizedDescription
        }
    }

    /// Export is not subject to the UI's 100-group display cap; both single-file duplicates and folder groups are written to the TSV in full.
    private func exportDuplicateResults(_ report: JunkReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("DiskManager-重複掃描結果.tsv",
                                        "DiskManager-duplicate-scan.tsv")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let contents = JunkReportExporter.duplicateTSV(
                report: report, rootPath: state.junkTargetURL?.path ?? "")
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.alertMessage = tr("匯出失敗：", "Export failed: ") + error.localizedDescription
        }
    }

    private func similarFolderChoice(
        _ folder: JunkItem,
        otherPath: String,
        fileCount: Int
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { state.junkSelection.contains(folder.relativePath) },
                set: { on in
                    if on {
                        if case .report(let report) = state.junkPhase {
                            for group in report.similarFolderGroups {
                                if group.first.relativePath == folder.relativePath {
                                    state.junkSelection.remove(group.second.relativePath)
                                } else if group.second.relativePath == folder.relativePath {
                                    state.junkSelection.remove(group.first.relativePath)
                                }
                            }
                        } else {
                            state.junkSelection.remove(otherPath)
                        }
                        state.junkSelection.insert(folder.relativePath)
                    } else {
                        state.junkSelection.remove(folder.relativePath)
                    }
                })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(folder.relativePath)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(tr("\(fileCount) 檔・\(formatBytes(folder.size))",
                    "\(fileCount) files · \(formatBytes(folder.size))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func itemRow(_ item: JunkItem, note: String? = nil) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: selectionBinding(item.relativePath)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(item.relativePath)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Spacer()
            Text(formatBytes(item.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func selectionBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { state.junkSelection.contains(path) },
            set: { on in
                if on { state.junkSelection.insert(path) } else { state.junkSelection.remove(path) }
            })
    }

    private func selectAllBinding(paths: [String]) -> Binding<Bool> {
        Binding(
            get: { !paths.isEmpty && paths.allSatisfy { state.junkSelection.contains($0) } },
            set: { on in
                if on {
                    state.junkSelection.formUnion(paths)
                } else {
                    state.junkSelection.subtract(paths)
                }
            })
    }

    private var selectedBytes: Int64 {
        state.effectiveJunkSelection.reduce(Int64(0)) { $0 + (state.junkSizeMap[$1] ?? 0) }
    }

    /// Action area shown after the scan completes: both one-click cache cleanup and "delete selected" are post-scan actions
    private func footer(_ report: JunkReport) -> some View {
        let cacheCount = AppState.quickCleanCategories.reduce(0) { $0 + report.items(for: $1).count }
        let cacheBytes = AppState.quickCleanCategories.reduce(Int64(0)) { $0 + report.totalBytes(for: $1) }
        return HStack {
            Button {
                state.startQuickClean()
            } label: {
                Label(cacheCount > 0
                      ? tr("一鍵清除快取（\(cacheCount) 項・\(formatBytes(cacheBytes))）",
                           "Quick Cache Clean (\(cacheCount) · \(formatBytes(cacheBytes)))")
                      : tr("一鍵清除快取", "Quick Cache Clean"),
                      systemImage: "sparkles")
            }
            .disabled(cacheCount == 0)
            .help(tr("不必逐項勾選：把這次掃到的系統雜物與縮圖快取（.DS_Store、._ 檔、縮圖、媒體快取）確認後全部丟垃圾桶。",
                     "No ticking needed: trashes all system cruft and thumbnail/media caches found by this scan, after one confirmation."))
            Divider().frame(height: 16)
            Text(tr("已選 \(state.effectiveJunkSelection.count) 項，共 \(formatBytes(selectedBytes))",
                    "\(state.effectiveJunkSelection.count) selected, \(formatBytes(selectedBytes))"))
                .font(.callout)
            Spacer()
            Button(tr("清除選取", "Clear selection")) { state.junkSelection = [] }
                .disabled(state.junkSelection.isEmpty)
            Button {
                state.requestDeleteSelected(method: .trash)
            } label: {
                Label(tr("丟到垃圾桶", "Move to Trash"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.junkSelection.isEmpty)
            Button(role: .destructive) {
                state.requestDeleteSelected(method: .delete)
            } label: {
                Text(tr("直接刪除…", "Delete permanently…"))
            }
            .disabled(state.junkSelection.isEmpty)
        }
    }
}
