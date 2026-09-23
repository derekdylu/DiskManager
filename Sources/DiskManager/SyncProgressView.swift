import AppKit
import DiskManagerCore
import SwiftUI

struct SyncProgressView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(state.syncMode.isDifferenceCleanup
                 ? tr("處理差集項目中…", "Cleaning difference items…")
                 : tr("同步中…", "Syncing…"))
                .font(.title2.bold())
            ProgressPanel(
                title: state.progress.map {
                    tr("項目 \($0.completedItems) / \($0.totalItems)", "Items \($0.completedItems) / \($0.totalItems)")
                } ?? "",
                progress: state.syncWork)
            Button(tr("取消", "Cancel")) { state.cancelWork() }
            Text(state.syncMode.isDifferenceCleanup
                 ? tr("取消後會停在當前進度；已封存或移到垃圾桶的項目不會自動搬回。",
                      "Cancelling stops at the current point; items already archived or moved to Trash are not automatically restored.")
                 : tr("取消不會留下半套檔案：正在複製中的檔案會整個放棄，已完成的保持原樣。",
                      "Cancelling never leaves half-written files: the file in flight is abandoned whole, finished ones stay."))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding()
    }

}

struct ResultView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n
    let outcomes: [SyncOutcome]

    private var anyCancelled: Bool { outcomes.contains { $0.result.wasCancelled } }
    private var allFailures: [ItemFailure] { outcomes.flatMap { $0.result.failures } }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: anyCancelled
                ? "exclamationmark.circle.fill"
                : (allFailures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 48))
                .foregroundStyle(anyCancelled ? .orange : (allFailures.isEmpty ? .green : .orange))
            Text(anyCancelled
                 ? tr("已取消（部分完成）", "Cancelled (partially done)")
                 : (state.syncMode.isDifferenceCleanup
                    ? tr("差集清理完成", "Difference cleanup complete")
                    : tr("同步完成", "Sync complete")))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                ForEach(outcomes) { outcome in
                    outcomeSummary(outcome)
                }
                if let elapsed = state.syncElapsed {
                    Text(tr("總耗時 \(formatDuration(elapsed))", "Total time \(formatDuration(elapsed))"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if !allFailures.isEmpty {
                DisclosureGroup(tr("有 \(allFailures.count) 個項目失敗", "\(allFailures.count) items failed")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allFailures.prefix(200)) { failure in
                                Text("\(failure.relativePath) — \(failure.message)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .frame(maxWidth: 560)
                Button(tr("匯出錯誤清單…", "Export error list…")) { exportFailures() }
            }

            HStack {
                if anyCancelled || !allFailures.isEmpty {
                    Button(tr("重新掃描比對", "Rescan & compare")) { state.startScan() }
                }
                Button(tr("回到開始", "Back to start")) { state.backToStart() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func outcomeSummary(_ outcome: SyncOutcome) -> some View {
        let sideName = outcome.direction == .toB ? "B" : "A"
        let r = outcome.result
        VStack(alignment: .leading, spacing: 2) {
            Text(tr("→ \(sideName)：新增 \(r.copied)、覆蓋 \(r.updated)、新資料夾 \(r.dirsCreated)、處理多出 \(r.orphansHandled)、複製 \(formatBytes(r.bytesCopied))",
                    "→ \(sideName): \(r.copied) new, \(r.updated) overwritten, \(r.dirsCreated) folders, \(r.orphansHandled) extras handled, \(formatBytes(r.bytesCopied)) copied"))
            if let archive = r.archiveFolder {
                Text(tr("被移開的舊檔案都在 \(sideName) 的「\(archive)」裡，確認沒問題後可自行刪除。",
                        "Displaced files are in \"\(archive)\" on \(sideName) — delete them once you've verified."))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func exportFailures() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("DiskManager-錯誤清單.txt", "DiskManager-errors.txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = allFailures.map { "\($0.relativePath)\t\($0.message)" }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.alertMessage = tr("匯出失敗：", "Export failed: ") + error.localizedDescription
        }
    }
}
