import AppKit
import DiskManagerCore
import SwiftUI

struct PlanView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n
    let bundle: PlanBundle

    enum UnionSection: Hashable { case toB, toA, unresolved }
    @State private var unionSection: UnionSection = .toB
    @State private var showSpace = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryCards
            warnings
            DisclosureGroup(tr("儲存空間分佈", "Storage space overview"), isExpanded: $showSpace) {
                SpaceView(usages: [bundle.usageA, bundle.usageB])
                    .padding(.top, 6)
            }
            if bundle.isEmpty {
                VStack {
                    Spacer()
                    Text(tr("🎉 兩邊已經一致，不需要同步。", "🎉 Both sides are identical — nothing to sync."))
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                treeArea
            }
            Divider()
            footer
        }
        .padding()
    }

    // MARK: - Summary cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            if bundle.mode.isUnion {
                StatCard(title: tr("補到 B", "To B"),
                         value: "\(bundle.forward.copies.count + bundle.forward.updates.count)",
                         detail: formatBytes(bundle.forward.bytesToCopy), color: .green)
                StatCard(title: tr("補到 A", "To A"),
                         value: "\((bundle.reverse?.copies.count ?? 0) + (bundle.reverse?.updates.count ?? 0))",
                         detail: formatBytes(bundle.reverse?.bytesToCopy ?? 0), color: .teal)
                StatCard(title: tr("無法自動處理", "Unresolved"),
                         value: "\(bundle.unresolved.count)", detail: "", color: .red)
                StatCard(title: tr("需複製容量", "Total to copy"),
                         value: formatBytes(bundle.totalBytes), detail: "", color: .primary)
            } else if bundle.mode.isDifferenceCleanup {
                StatCard(title: tr("待處理的 \(destName) 獨有項目", "Unique items to handle on \(destName)"),
                         value: "\(bundle.forward.orphans.count)",
                         detail: formatBytes(bundle.forward.orphanBytes), color: .purple)
                StatCard(title: tr("執行動作", "Action"),
                         value: state.orphanPolicy.localizedTitle,
                         detail: tr("不會複製或覆蓋", "No copies or overwrites"), color: .orange)
            } else {
                StatCard(title: tr("新增到 \(destName)", "New on \(destName)"),
                         value: "\(bundle.forward.copies.count)",
                         detail: tr("個項目", "items"), color: .green)
                StatCard(title: tr("覆蓋更新", "Overwrite"),
                         value: "\(bundle.forward.updates.count)",
                         detail: tr("個項目", "items"), color: .orange)
                StatCard(title: tr("新資料夾", "New folders"),
                         value: "\(bundle.forward.dirCreates.count)",
                         detail: tr("個", "folders"), color: .blue)
                StatCard(title: tr("\(destName) 多出", "Extra on \(destName)"),
                         value: "\(bundle.forward.orphans.count)",
                         detail: formatBytes(bundle.forward.orphanBytes), color: .purple)
                StatCard(title: tr("需複製容量", "To copy"),
                         value: formatBytes(bundle.forward.bytesToCopy), detail: "", color: .primary)
            }
        }
    }

    // Non-union modes are always "A target space → B operated space"
    private var destName: String { "B" }
    private var sourceName: String { "A" }

    // MARK: - Warnings

    private var receivingUsages: [DriveUsageData] {
        [bundle.usageA, bundle.usageB].filter { $0.incoming > 0 }
    }

    private var insufficientSpace: Bool {
        receivingUsages.contains { $0.incoming > $0.free }
    }

    @ViewBuilder
    private var warnings: some View {
        if !bundle.mode.isUnion && bundle.forward.sourceFileCount == 0 {
            WarningBanner(
                text: tr("目標空間（\(sourceName)）裡沒有任何檔案——確定選對了嗎？繼續會把 \(destName) 上的所有檔案都視為「多出項目」處理。",
                         "The target space (\(sourceName)) contains no files — is this the right folder? Continuing would treat everything on \(destName) as extra."),
                isError: true)
        }
        ForEach(receivingUsages.filter { $0.incoming > $0.free }, id: \.role) { usage in
            WarningBanner(
                text: tr("\(usage.role) 的可用空間不足：需要 \(formatBytes(usage.incoming))，目前只有 \(formatBytes(usage.free))。",
                         "Not enough free space on \(usage.role): need \(formatBytes(usage.incoming)), only \(formatBytes(usage.free)) available."),
                isError: true)
        }
        if !bundle.forward.scanFailures.isEmpty {
            WarningBanner(
                text: tr("掃描時有 \(bundle.forward.scanFailures.count) 個項目無法讀取，已略過（匯出清單可看細節）。",
                         "\(bundle.forward.scanFailures.count) items could not be read and were skipped (see exported list)."),
                isError: false)
        }
        if !bundle.mode.isUnion && !bundle.forward.orphans.isEmpty && state.orphanPolicy != .keep {
            WarningBanner(
                text: tr("\(destName) 上多出的 \(bundle.forward.orphans.count) 個項目將「\(state.orphanPolicy.localizedTitle)」。如果那些是你刻意只留在 \(destName) 的檔案，請先改成「保留不動」。",
                         "\(bundle.forward.orphans.count) extra items on \(destName) will be handled as \"\(state.orphanPolicy.localizedTitle)\". If you intentionally keep them only on \(destName), switch to \"Keep\" first."),
                isError: false)
        }
        if bundle.mode.isUnion && !bundle.unresolved.isEmpty {
            WarningBanner(
                text: tr("有 \(bundle.unresolved.count) 個衝突無法自動判斷，這些項目（含其內容）不會被更動，請切到「無法處理」分頁查看。",
                         "\(bundle.unresolved.count) conflicts cannot be resolved automatically; they (and their contents) will be left untouched — see the \"Unresolved\" tab."),
                isError: false)
        }
    }

    // MARK: - Tree list

    @ViewBuilder
    private var treeArea: some View {
        if bundle.mode.isUnion {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $unionSection) {
                    Text(tr("→ B（\(bundle.forward.totalOperations)）", "→ B (\(bundle.forward.totalOperations))"))
                        .tag(UnionSection.toB)
                    Text(tr("→ A（\(bundle.reverse?.totalOperations ?? 0)）", "→ A (\(bundle.reverse?.totalOperations ?? 0))"))
                        .tag(UnionSection.toA)
                    Text(tr("無法處理（\(bundle.unresolved.count)）", "Unresolved (\(bundle.unresolved.count))"))
                        .tag(UnionSection.unresolved)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch unionSection {
                case .toB:
                    DiffTreeView(plan: bundle.forward, extraSideName: "B")
                case .toA:
                    DiffTreeView(plan: bundle.reverse ?? SyncPlan(), extraSideName: "A")
                case .unresolved:
                    unresolvedList
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            DiffTreeView(plan: bundle.forward, extraSideName: destName)
                .frame(maxHeight: .infinity)
        }
    }

    private var unresolvedList: some View {
        List(bundle.unresolved) { conflict in
            VStack(alignment: .leading, spacing: 2) {
                Text(conflict.relativePath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(conflict.localizedReason
                     + "　A: \(formatBytes(conflict.aSize))　B: \(formatBytes(conflict.bSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(tr("重新掃描", "Rescan")) { state.startScan() }
            Spacer()
            if !bundle.isEmpty {
                Menu(tr("匯出完整清單…", "Export full list…")) {
                    Button(tr("JSON（適合交給 AI 或程式分析）", "JSON (for AI or scripts)")) { exportPlanJSON() }
                    Button(tr("純文字 TXT", "Plain text TXT")) { exportPlan() }
                }
                .fixedSize()
                Button {
                    state.startSync(with: bundle)
                } label: {
                    Label(bundle.mode.isDifferenceCleanup
                          ? tr("執行差集清理", "Clean Difference")
                          : tr("開始同步", "Start Sync"),
                          systemImage: bundle.mode.isDifferenceCleanup ? "trash" : "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bundle.totalOperations == 0 || insufficientSpace)
            }
        }
    }

    private func exportPlanJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("DiskManager-同步計畫.json", "DiskManager-sync-plan.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let input = bundle.exportInput(
                aPath: state.sourceURL?.path ?? "", bPath: state.destURL?.path ?? "")
            try ReportJSONExporter.planJSON(input).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.alertMessage = tr("匯出失敗：", "Export failed: ") + error.localizedDescription
        }
    }

    private func exportPlan() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("DiskManager-同步計畫.txt", "DiskManager-sync-plan.txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = []
        lines.append("DiskManager")
        lines.append("A：\(state.sourceURL?.path ?? "")")
        lines.append("B：\(state.destURL?.path ?? "")")
        lines.append(tr("模式：", "Mode: ") + bundle.mode.localizedTitle)
        lines.append("")

        func dump(_ plan: SyncPlan, direction: String) {
            for item in plan.copies {
                lines.append("\(direction)\t\(item.reason.localizedLabel)\t\(item.relativePath)\t\(item.size)")
            }
            for item in plan.updates {
                lines.append("\(direction)\t\(item.reason.localizedLabel)\t\(item.relativePath)\t\(item.size)")
            }
            for path in plan.dirCreates {
                lines.append("\(direction)\t\(tr("新資料夾", "New folder"))\t\(path)")
            }
            for item in plan.orphans {
                lines.append("\(direction)\t\(tr("多出", "Extra"))\t\(item.relativePath)\t\(item.size)")
            }
        }
        dump(bundle.forward, direction: "→\(destName)")
        if let reverse = bundle.reverse { dump(reverse, direction: "→A") }
        if !bundle.unresolved.isEmpty {
            lines.append("")
            lines.append(tr("== 無法自動處理的衝突 ==", "== Unresolved conflicts =="))
            for conflict in bundle.unresolved {
                lines.append("\(conflict.relativePath)\t\(conflict.localizedReason)")
            }
        }
        if !bundle.forward.scanFailures.isEmpty {
            lines.append("")
            lines.append(tr("== 掃描時無法讀取的項目 ==", "== Unreadable items =="))
            lines.append(contentsOf: bundle.forward.scanFailures)
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.alertMessage = tr("匯出失敗：", "Export failed: ") + error.localizedDescription
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail.isEmpty ? " " : detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WarningBanner: View {
    let text: String
    let isError: Bool

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(isError ? Color.red : Color.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
