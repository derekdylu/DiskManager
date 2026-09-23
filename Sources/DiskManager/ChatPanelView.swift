import AppKit
import SwiftUI

/// Right-hand AI chat panel
struct ChatPanelView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var chat: ChatState
    @EnvironmentObject var l10n: L10n
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if chat.hasAPIKey {
                conversation
                Divider()
                composer
                    .padding(10)
            } else {
                keyPrompt
            }
        }
        .background(.background.secondary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label(tr("AI 分析", "AI Analysis"), systemImage: "sparkles")
                .font(.headline)
            if !chat.sessionUsage.isEmpty {
                Text(usageText(chat.sessionUsage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(tr("本次對話累計 token 用量（輸入／輸出；含快取讀取）",
                             "Tokens used in this conversation (input / output; cache reads included)"))
            }
            Spacer()
            Picker("", selection: $chat.selection) {
                ForEach(AIProvider.allCases) { provider in
                    Section(provider == .anthropic ? "Claude（Anthropic）" : "GPT（OpenAI）") {
                        ForEach(provider.presetModels, id: \.self) { model in
                            Text(model).tag(ModelSelection(provider: provider, model: model))
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(chat.isStreaming)
            .help(tr("使用的模型；選哪家的模型就用哪家的 API key", "Model to use; the matching provider's API key is used"))

            Button {
                chat.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(chat.messages.isEmpty)
            .help(tr("清空對話", "Clear conversation"))

            Button {
                showSettings = true
            } label: {
                Image(systemName: chat.hasAPIKey ? "key.fill" : "key")
            }
            .help(tr("設定 API key", "API key settings"))
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                APIKeySettingsView(isPresented: $showSettings)
                    .environmentObject(chat)
                    .environmentObject(l10n)
            }
        }
    }

    private var keyPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(tr("目前選的是 \(chat.model)，需要 \(chat.provider == .anthropic ? "Anthropic" : "OpenAI") 的 API key。放入自己的 key，就能把掃描／比對結果交給 AI 分析；也可以從上方下拉選單改選另一家的模型。",
                    "\(chat.model) is selected and needs an \(chat.provider == .anthropic ? "Anthropic" : "OpenAI") API key. Add your own key to have the AI analyse your scan and comparison results, or pick the other provider's model from the dropdown above."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(tr("設定 API key…", "Set API key…")) { showSettings = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(chat.messages) { message in
                        ChatBubble(message: message,
                                   isStreamingPlaceholder: chat.isStreaming && message.text.isEmpty)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.messages.last?.text) {
                if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("可以這樣用", "How to use this"))
                .font(.callout.bold())
            Text(tr("1. 掃描完成後按「附上目前結果」，或用迴紋針附加之前匯出的 JSON／XML／TSV／TXT。\n2. 問它：「哪些資料夾佔最多？」「這些多出的檔案刪掉安全嗎？」「重複檔該留哪一份？」",
                    "1. After a scan, press \"Attach current result\", or use the paperclip to attach a previously exported JSON / XML / TSV / TXT.\n2. Ask things like \"Which folders take the most space?\", \"Is it safe to remove these extra files?\", \"Which duplicate should I keep?\""))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(tr("附件內容（含檔案路徑）會送到 Anthropic API；AI 只提供建議，不會動任何檔案。",
                    "Attachment contents (including file paths) are sent to the Anthropic API. The AI only advises — it never touches files."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Input area

    private var hasCurrentResult: Bool {
        switch state.tab {
        case .sync:
            if case .plan = state.phase { return true }
        case .cleanup:
            if case .report = state.junkPhase { return true }
        }
        return false
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.pendingAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(chat.pendingAttachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            chat.pendingAttachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    if let problem = chat.pickFiles() { state.alertMessage = problem }
                } label: {
                    Image(systemName: "paperclip")
                }
                .help(tr("附加匯出的結果檔（JSON／XML／TSV／TXT）", "Attach an exported result file (JSON / XML / TSV / TXT)"))

                Button {
                    chat.attachCurrentResult(from: state)
                } label: {
                    Label(tr("附上目前結果", "Attach current result"), systemImage: "doc.badge.plus")
                }
                .disabled(!hasCurrentResult || chat.isPreparingAttachment)
                .help(hasCurrentResult
                      ? tr("把目前畫面上的比對計畫／清理報告轉成 JSON 附上。", "Attach the plan or cleanup report currently on screen as JSON.")
                      : tr("先完成一次掃描，這裡才有結果可以附上。", "Finish a scan first — then there is a result to attach."))
                if chat.isPreparingAttachment {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .controlSize(.small)
            .disabled(chat.isStreaming)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(tr("問 AI…（Enter 送出）", "Ask the AI… (Enter to send)"),
                          text: $chat.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { chat.send() }
                if chat.isStreaming {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .help(tr("停止", "Stop"))
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chat.canSend ? Color.accentColor : Color.secondary)
                    .disabled(!chat.canSend)
                    .help(tr("送出", "Send"))
                }
            }
        }
    }
}

/// "↑ 12.3k ↓ 850" with cache reads noted when present
@MainActor
func usageText(_ usage: ClaudeClient.TokenUsage) -> String {
    func short(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : n.formatted()
    }
    var text = "↑ \(short(usage.input + usage.cacheRead + usage.cacheWrite)) ↓ \(short(usage.output))"
    if usage.cacheRead > 0 {
        text += tr("（快取 \(short(usage.cacheRead))）", " (cached \(short(usage.cacheRead)))")
    }
    return text
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(attachment.name)・\(formatBytes(Int64(attachment.byteCount)))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = attachment.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let onRemove {
                Spacer(minLength: 4)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ChatBubble: View {
    @EnvironmentObject var l10n: L10n
    let message: ChatMessage
    let isStreamingPlaceholder: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(message.attachments) { AttachmentChip(attachment: $0) }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if isStreamingPlaceholder {
                    ProgressView().controlSize(.small)
                } else {
                    Text(rendered(message.text))
                        .textSelection(.enabled)
                }
                if let usage = message.usage {
                    Text([message.model, usageText(usage)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notice:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Applies only inline Markdown (bold, `code`, links), preserving the original line breaks and list layout
    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct APIKeySettingsView: View {
    @EnvironmentObject var chat: ChatState
    @EnvironmentObject var l10n: L10n
    @Binding var isPresented: Bool
    @State private var keys: [AIProvider: String] = [:]
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("API key", "API keys"))
                .font(.headline)
            ForEach(AIProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider == .anthropic ? "Claude（Anthropic）" : "GPT（OpenAI）")
                            .font(.callout.bold())
                        if chat.hasKey(for: provider) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button(tr("移除", "Remove"), role: .destructive) {
                                saveFailed = !chat.setAPIKey(nil, for: provider)
                            }
                            .controlSize(.small)
                        }
                    }
                    SecureField(chat.hasKey(for: provider)
                                ? tr("已設定（輸入新的可取代）", "Already set (type a new one to replace)")
                                : provider.keyPlaceholder,
                                text: Binding(get: { keys[provider] ?? "" }, set: { keys[provider] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Text(tr("到 \(provider.consoleHost) 建立；只會用來連線 \(provider.apiHost)。",
                            "Create one at \(provider.consoleHost); used only to call \(provider.apiHost)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(tr("Key 只存在這台 Mac 的鑰匙圈；費用由你自己的帳號計費。",
                    "Keys are stored only in this Mac's Keychain; usage is billed to your own account."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if saveFailed {
                Text(tr("寫入鑰匙圈失敗。", "Could not write to the Keychain."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { isPresented = false }
                Button(tr("儲存", "Save"), action: save)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func save() {
        saveFailed = false
        for (provider, key) in keys where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !chat.setAPIKey(key, for: provider) { saveFailed = true }
        }
        if !saveFailed { isPresented = false }
    }
}
