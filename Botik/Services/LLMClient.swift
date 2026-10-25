import Foundation

enum StreamEvent {
    case content(String)
    case reasoning(String)
    case usage(prompt: Int?, completion: Int?)
}

struct LLMError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct GenerationOptions {
    var model: String
    var temperature: Double?
    var maxTokens: Int?
    var extraBody: [String: Any] = [:]
}

/// Client for any OpenAI-compatible `/chat/completions` endpoint
/// (Ollama, LM Studio, llama.cpp, vLLM, OpenRouter, ...).
struct LLMClient {
    var provider: Provider

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: provider.normalizedBaseURL + path) else {
            throw LLMError(message: "Неверный адрес сервера: \(provider.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter attribution headers (ignored by everyone else).
        request.setValue("https://github.com/wyrtex/botik", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Botik", forHTTPHeaderField: "X-Title")
        return request
    }

    func listModels() async throws -> [String] {
        var request = try makeRequest(path: "/models")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError(message: Self.errorMessage(from: data, status: http.statusCode))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError(message: "Сервер вернул неожиданный ответ")
        }
        let items = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        let ids = items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) ?? ($0["model"] as? String) }
        return ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func stream(messages: [[String: Any]], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(path: "/chat/completions", method: "POST")
                    request.timeoutInterval = 600
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var body: [String: Any] = [
                        "model": options.model,
                        "messages": messages,
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    if let t = options.temperature { body["temperature"] = t }
                    if let m = options.maxTokens, m > 0 { body["max_tokens"] = m }
                    for (k, v) in options.extraBody { body[k] = v }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count > 64_000 { break }
                        }
                        throw LLMError(message: Self.errorMessage(from: data, status: http.statusCode))
                    }

                    var sawSSE = false
                    var plainBody = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed.hasPrefix(":") { continue }
                        guard trimmed.hasPrefix("data:") else {
                            // Some servers ignore `stream` and return a single JSON body.
                            if !sawSSE { plainBody += line + "\n" }
                            continue
                        }
                        sawSSE = true
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        try Self.handleChunk(json, continuation: continuation)
                    }

                    if !sawSSE, !plainBody.isEmpty,
                       let data = plainBody.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        try Self.handleChunk(json, continuation: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func handleChunk(_ json: [String: Any],
                                    continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws {
        if let error = json["error"] {
            if let dict = error as? [String: Any], let msg = dict["message"] as? String {
                throw LLMError(message: msg)
            }
            throw LLMError(message: "\(error)")
        }

        if let usage = json["usage"] as? [String: Any] {
            continuation.yield(.usage(prompt: usage["prompt_tokens"] as? Int,
                                      completion: usage["completion_tokens"] as? Int))
        }

        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else { return }
        // `delta` for streaming, `message` for non-streaming responses.
        let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]

        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let r = delta[key] as? String, !r.isEmpty {
                continuation.yield(.reasoning(r))
                break
            }
        }
        if let c = delta["content"] as? String, !c.isEmpty {
            continuation.yield(.content(c))
        } else if let parts = delta["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { continuation.yield(.content(text)) }
        }
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                return "Ошибка \(status): \(msg)"
            }
            if let msg = json["error"] as? String { return "Ошибка \(status): \(msg)" }
            if let msg = json["message"] as? String { return "Ошибка \(status): \(msg)" }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Ошибка сервера \(status)" : "Ошибка \(status): \(text.prefix(500))"
    }
}

/// Splits `<think>…</think>` blocks out of streamed content, even when tags are split across chunks.
struct ThinkTagSplitter {
    private(set) var inThink = false
    private var buffer = ""

    mutating func feed(_ chunk: String) -> (content: String, reasoning: String) {
        buffer += chunk
        var content = ""
        var reasoning = ""
        while true {
            let tag = inThink ? "</think>" : "<think>"
            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                if inThink { reasoning += before } else { content += before }
                buffer = String(buffer[range.upperBound...])
                inThink.toggle()
            } else {
                let keep = Self.partialSuffixLength(buffer, tag: tag)
                let cut = buffer.index(buffer.endIndex, offsetBy: -keep)
                let emit = String(buffer[..<cut])
                if inThink { reasoning += emit } else { content += emit }
                buffer = String(buffer[cut...])
                break
            }
        }
        return (content, reasoning)
    }

    mutating func flush() -> (content: String, reasoning: String) {
        defer { buffer = "" }
        return inThink ? ("", buffer) : (buffer, "")
    }

    private static func partialSuffixLength(_ s: String, tag: String) -> Int {
        let maxLen = min(tag.count - 1, s.count)
        guard maxLen > 0 else { return 0 }
        for k in stride(from: maxLen, through: 1, by: -1) where s.hasSuffix(String(tag.prefix(k))) {
            return k
        }
        return 0
    }
}
