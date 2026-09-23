import Foundation

/// Minimal streaming client for the Claude Messages API (there is no official Swift SDK, so it goes straight over HTTPS + SSE)
enum ClaudeClient {
    struct Turn: Sendable {
        enum Role: String, Sendable {
            case user
            case assistant
        }
        let role: Role
        /// Text blocks sent in order (attachments first, the user's question last)
        let blocks: [String]
    }

    /// Token counts for one exchange; cache figures are Anthropic prompt-cache reads/writes (OpenAI reports cached prompt tokens as reads)
    struct TokenUsage: Sendable, Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0

        var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }

        static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
            TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                       cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
        }
    }

    struct Completion: Sendable {
        var stopReason: String?
        var servedByModel: String?
        var usage = TokenUsage()
    }

    struct APIError: LocalizedError {
        let status: Int?
        let message: String
        var errorDescription: String? {
            status.map { "HTTP \($0)：\(message)" } ?? message
        }
    }

    static let defaultModel = "claude-opus-5"
    static let models = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5-1"]

    /// These two models' safety classifiers may refuse; enable server-side fallback so Anthropic automatically switches to the suggested alternative model on refusal
    private static let fallbackCapableModels: Set<String> = ["claude-opus-5", "claude-fable-5-1"]

    static func stream(
        apiKey: String,
        model: String,
        system: String,
        turns: [Turn],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> Completion {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "system": system,
            // Attachments are usually large and resent every turn: automatic caching means follow-up questions only pay the cache-read price
            "cache_control": ["type": "ephemeral"],
            "messages": turns.map { turn in
                [
                    "role": turn.role.rawValue,
                    "content": turn.blocks.map { ["type": "text", "text": $0] },
                ] as [String: Any]
            },
        ]
        if fallbackCapableModels.contains(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError(status: status, message: errorMessage(from: data))
        }

        var completion = Completion()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "message_start":
                let message = event["message"] as? [String: Any]
                completion.servedByModel = message?["model"] as? String
                if let usage = message?["usage"] as? [String: Any] {
                    completion.usage.input = usage["input_tokens"] as? Int ?? 0
                    completion.usage.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    completion.usage.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    await onText(text)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    completion.stopReason = reason
                }
                if let usage = event["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    completion.usage.output = output
                }
            case "error":
                let detail = (event["error"] as? [String: Any])?["message"] as? String
                throw APIError(status: nil, message: detail ?? payload)
            default:
                break
            }
        }
        return completion
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(500), as: UTF8.self)
    }
}
