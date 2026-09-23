import Foundation

public enum JunkReportExporter {
    /// Produces a complete duplicate-scan TSV that opens in Numbers, Excel, or any text editor.
    /// The content is not subject to the UI's group display limit.
    public static func duplicateTSV(
        report: JunkReport,
        rootPath: String,
        exportedAt: Date = Date()
    ) -> String {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }

        let dateFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# DiskManager duplicate scan")
        lines.append("# root\t\(clean(rootPath))")
        lines.append("# exported_at\t\(dateFormatter.string(from: exportedAt))")
        lines.append("type\tgroup\titem\trole\tsimilarity\tmatching_files\tmatching_bytes\ttotal_files\tsize_bytes\tmodified\tpath\tfingerprint")

        for (groupIndex, group) in report.duplicateGroups.enumerated() {
            for (fileIndex, file) in group.files.enumerated() {
                lines.append([
                    "duplicate_file", "\(groupIndex + 1)", "\(fileIndex + 1)",
                    fileIndex == 0 ? "newest" : "duplicate", "", "", "", "",
                    "\(file.size)", dateFormatter.string(from: file.modified),
                    clean(file.relativePath), group.fingerprint,
                ].joined(separator: "\t"))
            }
        }

        for (groupIndex, group) in report.similarFolderGroups.enumerated() {
            let sides = [
                (role: "first", item: group.first, fileCount: group.firstFileCount),
                (role: "second", item: group.second, fileCount: group.secondFileCount),
            ]
            for (itemIndex, side) in sides.enumerated() {
                lines.append([
                    "similar_folder", "\(groupIndex + 1)", "\(itemIndex + 1)", side.role,
                    String(format: "%.6f", group.similarity), "\(group.matchingFiles)",
                    "\(group.matchingBytes)", "\(side.fileCount)", "\(side.item.size)",
                    dateFormatter.string(from: side.item.modified), clean(side.item.relativePath), "",
                ].joined(separator: "\t"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
