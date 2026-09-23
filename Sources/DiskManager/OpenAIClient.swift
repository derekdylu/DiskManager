import Foundation

/// Minimal streaming client for the OpenAI Chat Completions API (same shape as `ClaudeClient` so `ChatState` can switch providers)
enum OpenAIClient {
    static let defaultModel = "gpt-5"
    static let models = ["gpt-5", "gpt-5-mini", "gpt-4.1"]

    static func stream(
        apiKey: String,
        model: String,
        system: String,
        turns: [ClaudeClient.Turn],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ClaudeClient.Completion {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            messages.append(["role": turn.role.rawValue, "content": turn.blocks.joined(separator: "\n\n")])
        }
        // No max_tokens / temperature: newer models reject non-default sampling and use max_completion_tokens instead
        let body: [String: Any] = [
            "model": model, "stream": true, "messages": messages,
            // Ask for the usage chunk at the end of the stream
            "stream_options": ["include_usage": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw ClaudeClient.APIError(status: status, message: errorMessage(from: data))
        }

        var completion = ClaudeClient.Completion()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let error = event["error"] as? [String: Any] {
                throw ClaudeClient.APIError(status: nil, message: error["message"] as? String ?? payload)
            }
            completion.servedByModel = event["model"] as? String ?? completion.servedByModel
            if let usage = event["usage"] as? [String: Any] {
                let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                completion.usage.input = (usage["prompt_tokens"] as? Int ?? 0) - cached
                completion.usage.cacheRead = cached
                completion.usage.output = usage["completion_tokens"] as? Int ?? 0
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                await onText(text)
            }
            // Map onto Claude's stop reasons so the caller handles both providers the same way
            switch choice["finish_reason"] as? String {
            case "length": completion.stopReason = "max_tokens"
            case "content_filter": completion.stopReason = "refusal"
            case "stop": completion.stopReason = "end_turn"
            default: break
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
