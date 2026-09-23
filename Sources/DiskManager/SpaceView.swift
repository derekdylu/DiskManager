import SwiftUI

/// Visualization of the two storage spaces: volume usage bar + distribution of the largest folders within the scan range
struct SpaceView: View {
    let usages: [DriveUsageData]
    @EnvironmentObject var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(usages, id: \.role) { usage in
                DriveUsageRow(usage: usage)
            }
        }
    }
}

private let slicePalette: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .yellow, .brown,
]

struct DriveUsageRow: View {
    let usage: DriveUsageData
    @EnvironmentObject var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(usage.role) · \(usage.volumeName)")
                    .font(.headline)
                Text(usage.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(volumeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            volumeBar
            if !usage.breakdown.isEmpty {
                breakdownBar
                legend
            }
        }
    }

    private var volumeSummary: String {
        var text = tr("可用 \(formatBytes(usage.free)) / \(formatBytes(usage.total))",
                      "\(formatBytes(usage.free)) free of \(formatBytes(usage.total))")
        if usage.incoming > 0 {
            text += tr("　本次將寫入 \(formatBytes(usage.incoming))",
                       " · incoming \(formatBytes(usage.incoming))")
        }
        return text
    }

    /// Volume: used | to be written this sync | free
    private var volumeBar: some View {
        GeometryReader { geo in
            let total = max(1, Double(usage.total))
            let used = Double(max(0, usage.total - usage.free))
            let incoming = min(Double(usage.incoming), Double(usage.free))
            HStack(spacing: 1) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: geo.size.width * used / total)
                if incoming > 0 {
                    Rectangle()
                        .fill(incoming > Double(usage.free) * 0.95 ? Color.red : Color.orange)
                        .frame(width: max(2, geo.size.width * incoming / total))
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Size distribution of the top-level folders within the scan range
    private var breakdownBar: some View {
        GeometryReader { geo in
            let total = max(1, Double(usage.breakdown.reduce(Int64(0)) { $0 + $1.bytes }))
            HStack(spacing: 1) {
                ForEach(Array(usage.breakdown.enumerated()), id: \.element.id) { index, slice in
                    Rectangle()
                        .fill(sliceColor(index: index, slice: slice))
                        .frame(width: max(1, geo.size.width * Double(slice.bytes) / total))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], spacing: 3) {
            ForEach(Array(usage.breakdown.enumerated()), id: \.element.id) { index, slice in
                HStack(spacing: 5) {
                    Circle()
                        .fill(sliceColor(index: index, slice: slice))
                        .frame(width: 8, height: 8)
                    Text(sliceName(slice))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(formatBytes(slice.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func sliceColor(index: Int, slice: BreakdownSlice) -> Color {
        slice.name == "__other__" ? .gray : slicePalette[index % slicePalette.count]
    }

    private func sliceName(_ slice: BreakdownSlice) -> String {
        slice.name == "__other__" ? tr("其他", "Other") : slice.name
    }
}
