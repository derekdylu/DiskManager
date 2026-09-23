import AppKit
import DiskManagerCore
import Foundation
import UniformTypeIdentifiers

struct ChatAttachment: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let text: String
    /// Explanation for when the content is not the complete raw data (e.g. only the largest N entries are listed)
    var note: String?

    var byteCount: Int { text.utf8.count }
}

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
        case notice     // Error or system notice; displayed only, never sent to the AI
    }

    let id = UUID()
    let role: Role
    var text: String
    var attachments: [ChatAttachment] = []
    /// Filled in on assistant replies once the stream ends
    var usage: ClaudeClient.TokenUsage?
    var model: String?
}

/// Which API the chat talks to; each provider keeps its own key and model
enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .anthropic: return "anthropic-api-key"
        case .openai: return "openai-api-key"
        }
    }

    var presetModels: [String] {
        switch self {
        case .anthropic: return ClaudeClient.models
        case .openai: return OpenAIClient.models
        }
    }

    var consoleHost: String {
        switch self {
        case .anthropic: return "console.anthropic.com"
        case .openai: return "platform.openai.com"
        }
    }

    var apiHost: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai: return "api.openai.com"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        }
    }
}

/// A model together with the provider it belongs to; only preset models are offered
struct ModelSelection: Hashable, RawRepresentable {
    let provider: AIProvider
    let model: String

    init(provider: AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    /// Persisted as "provider|model"; unknown models fall back to nothing so the default applies
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = AIProvider(rawValue: parts[0]),
              provider.presetModels.contains(parts[1]) else { return nil }
        self.init(provider: provider, model: parts[1])
    }

    var rawValue: String { "\(provider.rawValue)|\(model)" }
}

/// Right-hand AI chat panel: the user supplies their own API key and hands exported result files or the current on-screen results to the AI for analysis
@MainActor
final class ChatState: ObservableObject {
    /// Total attachment size limit per message. JSON is roughly one token per 3 bytes, so 1 MB ≈ 300k tokens
    static let attachmentByteLimit = 1_000_000
    /// Maximum number of list entries when "attaching the current result"; totals are unaffected
    static let currentResultItemLimit = 1000
    @Published var messages: [ChatMessage] = []
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var draft = ""
    @Published var isStreaming = false
    @Published var isPreparingAttachment = false
    @Published private(set) var hasAPIKey = false
    /// Sum over every reply in this conversation (cleared with the conversation)
    var sessionUsage: ClaudeClient.TokenUsage {
        messages.compactMap(\.usage).reduce(ClaudeClient.TokenUsage(), +)
    }
    /// One dropdown lists both providers' models; picking one also picks the provider (and therefore the key)
    @Published var selection: ModelSelection {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: "chatModelSelection")
            apiKey = KeychainStore.load(provider.keychainAccount)
            hasAPIKey = apiKey != nil
        }
    }
    var provider: AIProvider { selection.provider }
    var model: String { selection.model }

    private var apiKey: String?
    private var worker: Task<Void, Never>?

    init() {
        selection = UserDefaults.standard.string(forKey: "chatModelSelection")
            .flatMap(ModelSelection.init(rawValue:)) ?? ModelSelection(provider: .anthropic, model: ClaudeClient.defaultModel)
        apiKey = KeychainStore.load(selection.provider.keychainAccount)
        hasAPIKey = apiKey != nil
    }

    // MARK: - API key

    func hasKey(for provider: AIProvider) -> Bool {
        KeychainStore.load(provider.keychainAccount) != nil
    }

    /// Returns false if writing to the Keychain failed
    func setAPIKey(_ value: String?, for target: AIProvider) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeychainStore.save(trimmed, account: target.keychainAccount) else { return false }
        if target == provider {
            apiKey = (trimmed?.isEmpty ?? true) ? nil : trimmed
            hasAPIKey = apiKey != nil
        }
        return true
    }

    // MARK: - Attachments

    var pendingBytes: Int { pendingAttachments.reduce(0) { $0 + $1.byteCount } }

    /// Returns nil on success, otherwise the reason to show the user. Over the limit, the attachment is rejected rather than silently truncated.
    @discardableResult
    func attach(_ attachment: ChatAttachment) -> String? {
        let total = pendingBytes + attachment.byteCount
        if total > Self.attachmentByteLimit {
            return tr("「\(attachment.name)」有 \(formatBytes(Int64(attachment.byteCount)))，加上去會超過單次 \(formatBytes(Int64(Self.attachmentByteLimit))) 的附件上限（太大的清單 AI 讀不完、費用也高）。可以改用「附上目前結果」，它會保留完整總計、只列出最大的項目。",
                      "\"\(attachment.name)\" is \(formatBytes(Int64(attachment.byteCount))), which would exceed the \(formatBytes(Int64(Self.attachmentByteLimit))) per-message attachment limit (huge lists are slow and costly for the AI). Try \"Attach current result\" instead — it keeps full totals and lists only the largest items.")
        }
        pendingAttachments.append(attachment)
        return nil
    }

    func pickFiles() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .xml, .plainText, .tabSeparatedText, .commaSeparatedText]
        panel.message = tr("選擇要交給 AI 分析的結果檔（JSON／XML／TSV／TXT）",
                           "Choose result files for the AI to analyse (JSON / XML / TSV / TXT)")
        guard panel.runModal() == .OK else { return nil }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return tr("無法以 UTF-8 文字讀取「\(url.lastPathComponent)」。",
                          "Could not read \"\(url.lastPathComponent)\" as UTF-8 text.")
            }
            if let problem = attach(ChatAttachment(name: url.lastPathComponent, text: text)) {
                return problem
            }
        }
        return nil
    }

    /// Converts the on-screen sync plan / cleanup report directly into a JSON attachment, without saving to a file and picking it first
    func attachCurrentResult(from app: AppState) {
        let limit = Self.currentResultItemLimit
        let encode: @Sendable () throws -> ChatAttachment
        switch app.tab {
        case .sync:
            guard case .plan(let bundle) = app.phase else { return }
            let input = bundle.exportInput(aPath: app.sourceURL?.path ?? "", bPath: app.destURL?.path ?? "")
            let total = bundle.totalOperations
            let note = total > limit ? Self.truncationNote(listed: limit, total: total) : nil
            encode = {
                ChatAttachment(
                    name: "sync-plan.json",
                    text: try ReportJSONExporter.planJSON(input, itemLimit: limit, pretty: false),
                    note: note)
            }
        case .cleanup:
            guard case .report(let report) = app.junkPhase else { return }
            let root = app.junkTargetURL?.path ?? ""
            let largest = max(
                JunkCategory.allCases.reduce(0) { $0 + report.items(for: $1).count },
                report.duplicateGroups.count, report.similarFolderGroups.count)
            let note = largest > limit ? Self.truncationNote(listed: limit, total: largest) : nil
            encode = {
                ChatAttachment(
                    name: "junk-scan.json",
                    text: try ReportJSONExporter.junkJSON(
                        report: report, rootPath: root, itemLimit: limit, pretty: false),
                    note: note)
            }
        }

        isPreparingAttachment = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try encode() }
            await MainActor.run {
                self.isPreparingAttachment = false
                switch result {
                case .success(let attachment):
                    if let problem = self.attach(attachment) { self.appendNotice(problem) }
                case .failure(let error):
                    self.appendNotice(tr("產生結果失敗：", "Could not build the result: ") + error.localizedDescription)
                }
            }
        }
    }

    private static func truncationNote(listed: Int, total: Int) -> String {
        tr("清單只列出最大的 \(listed) 筆（共 \(total) 筆）；各資料夾／類別的總計是完整的",
           "Lists only the \(listed) largest of \(total) entries; folder/category totals are complete")
    }

    // MARK: - Conversation

    var canSend: Bool {
        hasAPIKey && !isStreaming && !isPreparingAttachment
            && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
    }

    func send() {
        guard canSend, let apiKey else { return }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = tr("請分析附上的結果，告訴我重點與建議。", "Please analyse the attached results and give me the highlights and recommendations.")
        }
        messages.append(ChatMessage(role: .user, text: text, attachments: pendingAttachments))
        draft = ""
        pendingAttachments = []

        let turns = messages.compactMap(Self.turn(for:))
        let reply = ChatMessage(role: .assistant, text: "")
        let replyID = reply.id
        messages.append(reply)
        isStreaming = true
        let model = model
        let provider = provider
        let system = Self.systemPrompt

        worker = Task {
            do {
                let onText: @Sendable (String) async -> Void = { chunk in
                    await MainActor.run { self.appendToMessage(replyID, chunk) }
                }
                let completion: ClaudeClient.Completion
                switch provider {
                case .anthropic:
                    completion = try await ClaudeClient.stream(
                        apiKey: apiKey, model: model, system: system, turns: turns, onText: onText)
                case .openai:
                    completion = try await OpenAIClient.stream(
                        apiKey: apiKey, model: model, system: system, turns: turns, onText: onText)
                }
                if let index = messages.lastIndex(where: { $0.id == replyID }) {
                    messages[index].usage = completion.usage.isEmpty ? nil : completion.usage
                    messages[index].model = completion.servedByModel ?? model
                }
                switch completion.stopReason {
                case "refusal":
                    appendNotice(tr("AI 拒絕回答這個請求。", "The AI declined this request."))
                case "max_tokens":
                    appendNotice(tr("回覆達到長度上限而中斷，可以請它「繼續」。",
                                    "The reply hit the length limit — ask it to \"continue\"."))
                default:
                    break
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                appendNotice(tr("請求失敗：", "Request failed: ") + error.localizedDescription)
            }
            // An empty reply that received no text must not stay in the history (sending an empty assistant message next turn is rejected by the API)
            messages.removeAll { $0.id == replyID && $0.text.isEmpty }
            isStreaming = false
        }
    }

    func stop() {
        worker?.cancel()
    }

    func clear() {
        stop()
        messages = []
        pendingAttachments = []
    }

    private func appendToMessage(_ id: UUID, _ chunk: String) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }

    private func appendNotice(_ text: String) {
        messages.append(ChatMessage(role: .notice, text: text))
    }

    private static func turn(for message: ChatMessage) -> ClaudeClient.Turn? {
        switch message.role {
        case .notice:
            return nil
        case .assistant:
            return message.text.isEmpty ? nil : .init(role: .assistant, blocks: [message.text])
        case .user:
            let files = message.attachments.map { attachment in
                var header = "<file name=\"\(attachment.name)\">"
                if let note = attachment.note { header += "\n<note>\(note)</note>" }
                return header + "\n" + attachment.text + "\n</file>"
            }
            return .init(role: .user, blocks: files + [message.text])
        }
    }

    private static let systemPrompt = """
    You are the analysis assistant inside DiskManager, a macOS app for comparing, syncing and cleaning up \
    storage spaces (external drives, local folders, or any two folders).

    The user attaches result files exported by the app, wrapped in <file name="..."> tags:
    - kind "sync_plan": a previewed (not yet executed) comparison between space A and space B. In "mirror" and \
    "difference" modes A is the target/reference space and is never modified; B is the working space that gets \
    modified. "mirror" updates B to match A (actions: copy, update, create_dir; "extra" = items only on B, handled \
    per the user's archive/trash/keep policy). "difference" only removes from B the items that do not exist on A. \
    "union" fills both sides (directions to_b and to_a); the newer file wins and "unresolved" conflicts are left alone.
    - kind "junk_scan": regenerable caches, system cruft, disk images, duplicate file groups (same size and content \
    fingerprint) and folder pairs with at least 80% identical content, all relative to "root".
    - Older exports may be TSV or plain text with the same information.
    When "truncated" is true (or a <note> says so) the item lists contain only the largest entries, while the \
    totals cover everything — say so when it limits your conclusions.

    Help the user understand what the result means, spot anything risky or surprising (for example a whole folder \
    showing up as extra, signs that the wrong folder was picked, or large files about to be overwritten), and suggest \
    what to review before acting. You cannot modify files; every deletion in the app goes through a preview and an \
    explicit confirmation, and the default is archiving or the Trash. Base size and count claims on the data, quoting \
    paths exactly. Reply in the language the user writes in (Traditional Chinese by default).
    """
}

extension PlanBundle {
    func exportInput(aPath: String, bPath: String) -> ReportJSONExporter.PlanInput {
        .init(mode: mode.rawValue, aPath: aPath, bPath: bPath,
              toB: forward, toA: reverse, unresolved: unresolved)
    }
}
