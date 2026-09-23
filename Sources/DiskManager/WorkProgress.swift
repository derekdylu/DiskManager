import DiskManagerCore
import SwiftUI

/// Progress of one long-running job, with enough information to show a bar, a rate and an ETA.
struct WorkProgress {
    enum Unit {
        case items
        case bytes
    }

    var completed: Int64
    /// nil = unknown (indeterminate bar, no ETA)
    var total: Int64?
    /// true when `total` is a guess (e.g. last scan's count) rather than a known figure
    var totalIsEstimate = false
    var unit: Unit
    /// Units per second, measured over a recent window (0 = not measurable yet)
    var rate: Double
    var updatedAt: Date
    /// Extra line, e.g. the path currently being processed
    var detail = ""

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    /// Remaining time, counting down between updates so the display keeps moving
    func eta(at now: Date) -> TimeInterval? {
        guard let total, rate > 0 else { return nil }
        let remaining = Double(max(0, total - completed)) / rate - now.timeIntervalSince(updatedAt)
        return max(0, remaining)
    }

    func formatted(_ value: Int64) -> String {
        switch unit {
        case .items: return value.formatted()
        case .bytes: return formatBytes(value)
        }
    }
}

/// Builds `WorkProgress` values for one job on the main actor: keeps the meter and the (possibly estimated) total.
@MainActor
final class ProgressTracker {
    private var meter = RateMeter()
    private(set) var total: Int64?
    private(set) var totalIsEstimate = false
    let unit: WorkProgress.Unit

    init(unit: WorkProgress.Unit) {
        self.unit = unit
    }

    func start(total: Int64?, isEstimate: Bool = false) -> WorkProgress {
        meter.reset()
        self.total = total
        totalIsEstimate = isEstimate
        return WorkProgress(completed: 0, total: total, totalIsEstimate: isEstimate,
                            unit: unit, rate: 0, updatedAt: Date())
    }

    func update(completed: Int64, total newTotal: Int64? = nil, detail: String = "") -> WorkProgress {
        if let newTotal {
            total = newTotal
            totalIsEstimate = false
        }
        let now = Date()
        let rate = meter.record(completed, at: now)
        // A guessed total that turns out too small must not show a full bar with 0 remaining
        if totalIsEstimate, let total, completed >= total {
            self.total = nil
        }
        return WorkProgress(completed: completed, total: total, totalIsEstimate: totalIsEstimate,
                            unit: unit, rate: rate, updatedAt: now, detail: detail)
    }
}

/// Remembers how many items a path had last time so the next scan of it can show an estimated ETA
enum ScanHistory {
    static func lastCount(for url: URL, kind: String) -> Int64? {
        let value = UserDefaults.standard.integer(forKey: key(url, kind))
        return value > 0 ? Int64(value) : nil
    }

    static func record(_ count: Int, for url: URL, kind: String) {
        UserDefaults.standard.set(count, forKey: key(url, kind))
    }

    private static func key(_ url: URL, _ kind: String) -> String {
        "lastCount:\(kind):\(url.standardizedFileURL.path)"
    }
}

/// Bar + "done / total · rate · ETA" line, shared by every loading state in the app
struct ProgressPanel: View {
    @EnvironmentObject var l10n: L10n
    let title: String
    let progress: WorkProgress?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                Text(title)
                    .font(.callout.bold())
                if let progress, let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(statusLine(at: context.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                if let detail = progress?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 520)
        }
    }

    private func statusLine(at now: Date) -> String {
        guard let progress else { return tr("等待中…", "Waiting…") }
        var parts: [String] = []
        if let total = progress.total {
            let approx = progress.totalIsEstimate ? "≈" : ""
            parts.append("\(progress.formatted(progress.completed)) / \(approx)\(progress.formatted(total))")
        } else {
            parts.append(progress.formatted(progress.completed))
        }
        parts.append(rateText(progress))
        parts.append(etaText(progress, at: now))
        return parts.joined(separator: " · ")
    }

    private func rateText(_ progress: WorkProgress) -> String {
        guard progress.rate > 0 else { return tr("計算速度中…", "Measuring speed…") }
        switch progress.unit {
        case .items:
            return tr("\(Int(progress.rate.rounded()).formatted()) 項/秒", "\(Int(progress.rate.rounded()).formatted()) items/s")
        case .bytes:
            return tr("\(formatBytes(Int64(progress.rate)))/秒", "\(formatBytes(Int64(progress.rate)))/s")
        }
    }

    private func etaText(_ progress: WorkProgress, at now: Date) -> String {
        guard progress.total != nil else {
            return tr("總量未知，無法預估剩餘時間", "Total unknown — no ETA")
        }
        guard let eta = progress.eta(at: now) else { return tr("預估中…", "Estimating…") }
        let base = tr("剩餘約 \(formatDuration(eta))", "about \(formatDuration(eta)) left")
        return progress.totalIsEstimate
            ? base + tr("（依上次結果推估）", " (based on last run)")
            : base
    }
}
