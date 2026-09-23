import DiskManagerCore
import SwiftUI

/// A node in the diff tree: children == nil means a file (leaf node)
final class DiffNode: Identifiable {
    let id: String
    let name: String
    var children: [DiffNode]?
    var childMap: [String: DiffNode] = [:]
    var item: PlanItem?
    var isNewFolder = false
    var bytes: Int64 = 0
    var addCount = 0
    var updateCount = 0
    var extraCount = 0
    let isFolder: Bool

    init(id: String, name: String, isFolder: Bool) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
    }
}

enum DiffFilter: String, CaseIterable, Identifiable {
    case all, added, updated, extra
    var id: String { rawValue }
}

enum DiffTreeBuilder {
    static func build(plan: SyncPlan, filter: DiffFilter) -> [DiffNode] {
        let root = DiffNode(id: "", name: "", isFolder: true)

        func folderNode(forParentOf components: [Substring]) -> DiffNode {
            var node = root
            var path = ""
            for component in components.dropLast() {
                path = path.isEmpty ? String(component) : path + "/" + String(component)
                if let existing = node.childMap[String(component)] {
                    node = existing
                } else {
                    let created = DiffNode(id: path, name: String(component), isFolder: true)
                    node.childMap[String(component)] = created
                    node = created
                }
            }
            return node
        }

        func bumpAggregates(components: [Substring], bytes: Int64, bucket: (DiffNode) -> Void) {
            var node = root
            bucket(node)
            node.bytes += bytes
            var path = ""
            for component in components.dropLast() {
                path = path.isEmpty ? String(component) : path + "/" + String(component)
                guard let next = node.childMap[String(component)] else { return }
                node = next
                bucket(node)
                node.bytes += bytes
            }
        }

        func insertLeaf(_ item: PlanItem, bucket: (DiffNode) -> Void) {
            let components = item.relativePath.split(separator: "/")
            guard let last = components.last else { return }
            let parent = folderNode(forParentOf: components)
            let leaf = DiffNode(id: item.relativePath, name: String(last), isFolder: item.kind.isDirectory)
            leaf.item = item
            leaf.bytes = item.size
            parent.childMap[String(last) + "\u{0}leaf"] = leaf
            bumpAggregates(components: components, bytes: item.size, bucket: bucket)
            bucket(leaf)
        }

        func markNewFolder(_ path: String) {
            let components = path.split(separator: "/")
            guard let last = components.last else { return }
            let parent = folderNode(forParentOf: components)
            let node: DiffNode
            if let existing = parent.childMap[String(last)] {
                node = existing
            } else {
                node = DiffNode(id: path, name: String(last), isFolder: true)
                parent.childMap[String(last)] = node
            }
            node.isNewFolder = true
            bumpAggregates(components: components, bytes: 0) { $0.addCount += 1 }
            node.addCount += 1
        }

        if filter == .all || filter == .added {
            for item in plan.copies { insertLeaf(item) { $0.addCount += 1 } }
            for path in plan.dirCreates { markNewFolder(path) }
        }
        if filter == .all || filter == .updated {
            for item in plan.updates { insertLeaf(item) { $0.updateCount += 1 } }
        }
        if filter == .all || filter == .extra {
            for item in plan.orphans { insertLeaf(item) { $0.extraCount += 1 } }
        }

        finalize(root)
        return root.children ?? []
    }

    private static func finalize(_ node: DiffNode) {
        guard !node.childMap.isEmpty else {
            // Extra folders (handled as a whole) and empty new folders stay displayed as leaf nodes
            if node.isFolder && node.item == nil && !node.isNewFolder {
                node.children = []
            }
            return
        }
        let sorted = node.childMap.values.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for child in sorted { finalize(child) }
        node.children = sorted
        node.childMap = [:]
    }
}

struct DiffTreeView: View {
    let plan: SyncPlan
    let extraSideName: String   // Name of the side holding the extra items ("B" or "A")
    @EnvironmentObject var l10n: L10n
    @State private var filter: DiffFilter = .all
    @State private var cache: [DiffFilter: [DiffNode]] = [:]
    @State private var builtForPlanID = ""

    private var planIdentity: String {
        "\(plan.copies.count)-\(plan.updates.count)-\(plan.orphans.count)-\(plan.dirCreates.count)-\(plan.bytesToCopy)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $filter) {
                Text(tr("全部", "All")).tag(DiffFilter.all)
                Text(tr("新增（\(plan.copies.count + plan.dirCreates.count)）",
                        "New (\(plan.copies.count + plan.dirCreates.count))")).tag(DiffFilter.added)
                Text(tr("覆蓋（\(plan.updates.count)）", "Overwrite (\(plan.updates.count))")).tag(DiffFilter.updated)
                Text(tr("\(extraSideName) 多出（\(plan.orphans.count)）",
                        "Extra on \(extraSideName) (\(plan.orphans.count))")).tag(DiffFilter.extra)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List {
                OutlineGroup(nodes, children: \.children) { node in
                    DiffNodeRow(node: node)
                }
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { rebuildIfNeeded() }
        .onChange(of: filter) { _, _ in rebuildIfNeeded() }
    }

    private var nodes: [DiffNode] {
        cache[filter] ?? []
    }

    private func rebuildIfNeeded() {
        if builtForPlanID != planIdentity {
            cache = [:]
            builtForPlanID = planIdentity
        }
        if cache[filter] == nil {
            cache[filter] = DiffTreeBuilder.build(plan: plan, filter: filter)
        }
    }
}

struct DiffNodeRow: View {
    let node: DiffNode
    @EnvironmentObject var l10n: L10n

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            badges
            Spacer()
            if node.bytes > 0 {
                Text(formatBytes(node.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var iconName: String {
        if !node.isFolder {
            if case .symlink = node.item?.kind { return "link" }
            return "doc"
        }
        return node.children == nil ? "folder.fill" : "folder"
    }

    @ViewBuilder
    private var badges: some View {
        if let item = node.item {
            chip(item.reason.localizedLabel, color: color(for: item.reason))
            if item.kind.isDirectory {
                chip(tr("整個資料夾", "Whole folder"), color: .secondary)
            }
        } else {
            if node.isNewFolder {
                chip(tr("新資料夾", "New folder"), color: .blue)
            }
            HStack(spacing: 4) {
                if node.addCount > 0 { countChip("+\(node.addCount)", .green) }
                if node.updateCount > 0 { countChip("~\(node.updateCount)", .orange) }
                if node.extraCount > 0 { countChip("!\(node.extraCount)", .purple) }
            }
        }
    }

    private func color(for reason: PlanItem.Reason) -> Color {
        switch reason {
        case .new: return .green
        case .sizeChanged, .timeChanged, .linkChanged: return .orange
        case .typeConflict: return .red
        case .extraneous: return .purple
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func countChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
    }
}
