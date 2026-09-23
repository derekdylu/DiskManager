import AppKit
import DiskManagerCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n
    @AppStorage("showChatPanel") private var showChat = false
    @AppStorage("chatPanelWidth") private var chatWidth: Double = 380
    @State private var chatDragStartWidth: Double?

    private let chatWidthRange: ClosedRange<Double> = 300...800

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch state.tab {
                    case .sync:
                        syncPane
                    case .cleanup:
                        JunkView()
                    }
                }
                .frame(minWidth: 860, maxWidth: .infinity)
                if showChat {
                    chatResizeHandle
                    ChatPanelView()
                        .frame(width: chatWidth)
                }
            }
        }
        .frame(minHeight: 640)
        .alert(tr("需要「完整磁碟取用權」", "Full Disk Access needed"),
               isPresented: fdaPromptBinding) {
            Button(tr("開啟系統設定…", "Open System Settings…")) {
                state.resolveFullDiskAccessPrompt(.openSettings)
            }
            Button(tr("這次先不授權，繼續掃描", "Continue without it this time")) {
                state.resolveFullDiskAccessPrompt(.continueWithout)
            }
            Button(tr("取消", "Cancel"), role: .cancel) { state.resolveFullDiskAccessPrompt(.cancel) }
        } message: {
            Text(tr("macOS 不允許 app 自己要求這個權限，必須由你在「系統設定 › 隱私權與安全性 › 完整磁碟取用權」把 DiskManager 打開。\n\n授權後掃描不會再對桌面、文件、下載、外接與網路磁碟區逐一跳出詢問，受保護的資料夾也才讀得到。授權完請重新啟動 DiskManager。",
                    "macOS does not let an app request this permission itself — you have to enable DiskManager under System Settings › Privacy & Security › Full Disk Access.\n\nOnce granted, scans stop asking separately for Desktop, Documents, Downloads, removable and network volumes, and protected folders become readable. Relaunch DiskManager after granting it."))
        }
        .alert(tr("提示", "Notice"), isPresented: alertBinding) {
            Button(tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    /// Divider that can be dragged to resize the chat panel; the width persists
    private var chatResizeHandle: some View {
        Divider()
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if chatDragStartWidth == nil { chatDragStartWidth = chatWidth }
                        chatWidth = min(max((chatDragStartWidth ?? chatWidth) - value.translation.width,
                                            chatWidthRange.lowerBound), chatWidthRange.upperBound)
                    }
                    .onEnded { _ in chatDragStartWidth = nil })
    }

    private var fdaPromptBinding: Binding<Bool> {
        Binding(
            get: { state.fullDiskAccessPrompt != nil },
            set: { if !$0 && state.fullDiskAccessPrompt != nil { state.resolveFullDiskAccessPrompt(.cancel) } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } })
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $state.tab) {
                Text(tr("同步", "Sync")).tag(AppState.Tab.sync)
                Text(tr("清理", "Cleanup")).tag(AppState.Tab.cleanup)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
            .disabled(state.isBusy)

            Spacer()

            Button {
                FullDiskAccess.openSystemSettings()
            } label: {
                Label(state.fullDiskAccessGranted
                      ? tr("完整磁碟取用權：已授權", "Full Disk Access: granted")
                      : tr("完整磁碟取用權：未授權", "Full Disk Access: not granted"),
                      systemImage: state.fullDiskAccessGranted ? "checkmark.shield.fill" : "exclamationmark.shield")
            }
            .tint(state.fullDiskAccessGranted ? .green : .orange)
            .help(state.fullDiskAccessGranted
                  ? tr("掃描不會再逐一詢問資料夾權限。", "Scans will not ask for folder permissions one by one.")
                  : tr("按一下開啟系統設定授權。未授權時掃描會對桌面／文件／下載／外接與網路磁碟區逐一跳出詢問，受保護的資料夾會被跳過。",
                       "Click to open System Settings. Without it, scans ask separately for Desktop / Documents / Downloads / removable and network volumes, and protected folders are skipped."))

            // Toggle with the button style: the on state is a filled (tinted) button, which reads clearly as "active"
            Toggle(isOn: $state.keepDisplayAwake) {
                Label(
                    tr("螢幕常亮", "Keep Awake"),
                    systemImage: state.keepDisplayAwake ? "sun.max.fill" : "sun.max")
            }
            .toggleStyle(.button)
            .tint(.orange)
            .help(tr("防止螢幕休眠。同步／掃描進行中系統本來就不會睡，這個開關是額外讓螢幕保持亮著。",
                     "Prevents the display from sleeping. The system already stays awake during sync/scan; this additionally keeps the screen on."))

            Button {
                l10n.toggle()
            } label: {
                Label(l10n.language == .zhHant ? "EN" : "中文", systemImage: "globe")
            }
            .help(tr("切換英文介面", "Switch to Chinese interface"))

            Toggle(isOn: $showChat) {
                Label(tr("AI 分析", "AI Analysis"), systemImage: "sparkles")
            }
            .toggleStyle(.button)
            .help(tr("開關右側的 AI 聊天室：放入自己的 API key，把結果交給 AI 分析。",
                     "Toggle the AI chat panel on the right: add your own API key and let the AI analyse results."))
        }
    }

    // MARK: - Sync tab

    private var syncPane: some View {
        VStack(spacing: 0) {
            header
                .padding()
                .disabled(state.isBusy)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Row 1: operation mode; row 2: target space (emphasized); row 3: operated space.
    /// In union mode both sides are equal, so no visual emphasis is applied.
    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("操作模式", "Operation mode"))
                        .font(.headline)
                    Text(state.syncMode.localizedExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: $state.syncMode) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .labelsHidden()
            }
            Divider()
            VStack(spacing: 4) {
                FolderPickerRow(
                    title: spaceTitle(for: .toA),
                    subtitle: roleSubtitle(for: .toA),
                    url: $state.sourceURL,
                    emphasis: state.syncMode.isUnion ? .operated : .target)
                if !state.syncMode.isUnion {
                    HStack(spacing: 6) {
                        Image(systemName: state.syncMode.isDifferenceCleanup ? "minus.circle" : "arrow.down")
                            .foregroundStyle(.secondary)
                        Button {
                            state.swapSpaces()
                        } label: {
                            Label(tr("對調", "Swap"), systemImage: "arrow.up.arrow.down")
                        }
                        .controlSize(.small)
                        .disabled(state.sourceURL == nil && state.destURL == nil)
                        .help(tr("對調目標空間與被操作空間（已掃描的結果會直接沿用，不必重掃）。",
                                 "Swap the target and working spaces (an existing scan is reused — no rescan needed)."))
                    }
                }
                FolderPickerRow(
                    title: spaceTitle(for: .toB),
                    subtitle: roleSubtitle(for: .toB),
                    url: $state.destURL,
                    emphasis: .operated)
            }
            if !state.syncMode.isUnion {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.syncMode.isDifferenceCleanup
                            ? tr("差集項目的處理方式", "How to handle difference items")
                            : tr("被操作空間上多出的檔案（目標空間已沒有的）",
                                 "Extra files in the working space (no longer in the target space)"))
                            .font(.headline)
                        Text(state.orphanPolicy.localizedExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("", selection: $state.orphanPolicy) {
                        ForEach(OrphanPolicy.allCases.filter {
                            !state.syncMode.isDifferenceCleanup || $0 != .keep
                        }) { policy in
                            Text(policy.localizedTitle).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .labelsHidden()
                }
            }
        }
    }

    private func spaceTitle(for side: SyncOutcome.Direction) -> String {
        switch (state.syncMode.isUnion, side) {
        case (true, .toA): return tr("儲存空間 A", "Storage A")
        case (true, .toB): return tr("儲存空間 B", "Storage B")
        case (false, .toA): return tr("目標空間 A", "Target space A")
        case (false, .toB): return tr("被操作空間 B", "Working space B")
        }
    }

    private func roleSubtitle(for side: SyncOutcome.Direction) -> String {
        switch (state.syncMode, side) {
        case (.mirror, .toA):
            return tr("以這裡的狀態為準，不會被更動", "The state to match — never changed")
        case (.mirror, .toB):
            return tr("會被更新成與 A 一致", "Will be updated to match A")
        case (.difference, .toA):
            return tr("比對基準，不會被更動", "Comparison baseline — never changed")
        case (.difference, .toB):
            return tr("A 沒有的項目會從這裡移除", "Items missing from A are removed from here")
        case (.union, _):
            return tr("聯集成員（互相補齊）", "Union member (fills the other)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            IdleView()
        case .scanning:
            ScanningView()
        case .plan(let bundle):
            PlanView(bundle: bundle)
        case .syncing:
            SyncProgressView()
        case .finished(let outcomes):
            ResultView(outcomes: outcomes)
        }
    }
}

struct IdleView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(state.syncMode.localizedExplanation)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text(tr("按下「掃描比對」只會讀取與比較，先顯示預覽，不會動任何檔案。",
                    "\"Scan & Compare\" only reads and compares — you'll see a preview before anything is touched."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                state.startScan()
            } label: {
                Label(tr("掃描比對", "Scan & Compare"), systemImage: "magnifyingglass")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!state.canScan)
            Spacer()
        }
        .padding()
    }
}

struct ScanningView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: L10n

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(state.isRebuildingPlan && state.scanProgressA == nil
                 ? tr("重新比對中…", "Re-comparing…")
                 : tr("正在掃描兩邊的檔案清單…", "Scanning both file trees…"))
                .font(.title3)
            if state.scanProgressA != nil || !state.isRebuildingPlan {
                ProgressPanel(title: tr("目標空間 A", "Target space A"), progress: state.scanProgressA)
                ProgressPanel(title: tr("被操作空間 B", "Working space B"), progress: state.scanProgressB)
            }
            if state.isRebuildingPlan {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("比對兩邊差異中（純記憶體運算，通常只需幾秒）…",
                            "Comparing both sides (in-memory, usually a few seconds)…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button(tr("取消", "Cancel")) { state.cancelWork() }
                .disabled(state.isRebuildingPlan && state.scanProgressA == nil)
            Spacer()
        }
        .padding()
    }
}

struct FolderPickerRow: View {
    /// Visual weight of the row: the target space must stand out at a glance; the operated space only carries a "will be modified" hint
    enum Emphasis {
        case plain
        case target
        case operated
    }

    let title: String
    let subtitle: String
    @Binding var url: URL?
    var emphasis: Emphasis = .plain
    @EnvironmentObject var l10n: L10n

    var body: some View {
        HStack(spacing: 12) {
            // Icon column only: the target gets a scope, anything that will be modified gets a pencil
            switch emphasis {
            case .plain:
                EmptyView()
            case .target:
                Image(systemName: "scope")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
            case .operated:
                Image(systemName: "pencil.line")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(emphasis == .target ? .title3.bold() : .headline)
                    .foregroundStyle(emphasis == .target ? Color.accentColor : Color.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: emphasis == .plain ? 170 : 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let url {
                    Text(url.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let info = volumeInfo(url) {
                        Text(info)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(tr("尚未選擇", "Not selected"))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                let volumes = externalVolumes()
                if volumes.isEmpty {
                    Text(tr("沒有偵測到外接磁碟區", "No external volumes detected"))
                } else {
                    ForEach(volumes, id: \.self) { volume in
                        Button(volume.lastPathComponent) { url = volume }
                    }
                }
            } label: {
                Label(tr("磁碟區", "Volumes"), systemImage: "externaldrive")
            }
            .fixedSize()

            Button(tr("選擇資料夾…", "Choose Folder…")) { pick() }

            Button {
                url = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(url == nil ? Color.clear : Color.secondary)
            .disabled(url == nil)
            .help(tr("清除選擇", "Clear selection"))
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = tr("選擇「\(title)」的資料夾", "Choose the folder for \(title)")
        panel.prompt = tr("選擇", "Choose")
        if let url { panel.directoryURL = url }
        if panel.runModal() == .OK, let picked = panel.url {
            url = picked
        }
    }

    private func externalVolumes() -> [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsInternalKey],
            options: [.skipHiddenVolumes]) ?? []
        return volumes.filter {
            (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false
        }
    }

    private func volumeInfo(_ url: URL) -> String? {
        guard let capacity = readVolumeCapacity(at: url) else { return nil }
        var parts: [String] = []
        if let name = capacity.name {
            parts.append(tr("磁碟區：", "Volume: ") + name)
        }
        if let total = capacity.total, let free = capacity.available {
            parts.append(tr("可用 \(formatBytes(free)) / 總容量 \(formatBytes(total))",
                            "\(formatBytes(free)) free of \(formatBytes(total))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "　")
    }
}
