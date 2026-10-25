import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    var chats: [Chat] = []
    var settings: AppSettings {
        didSet { Storage.save(settings) }
    }
    /// Chats with a generation in progress.
    private(set) var generating: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    init() {
        Storage.prepare()
        settings = Storage.loadSettings() ?? AppSettings()
        chats = Storage.loadChats()
    }

    // MARK: - Chats

    func chat(_ id: UUID?) -> Chat? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        chats.firstIndex { $0.id == id }
    }

    @discardableResult
    func newChat() -> Chat {
        // Reuse an existing empty chat instead of piling them up.
        if let empty = chats.first(where: { $0.messages.isEmpty }) { return empty }
        var chat = Chat()
        chat.providerID = settings.defaultProvider?.id
        chat.model = settings.defaultProvider?.defaultModel
        chats.insert(chat, at: 0)
        return chat
    }

    func delete(_ id: UUID) {
        stop(id)
        guard let i = index(of: id) else { return }
        Storage.delete(chats[i])
        chats.remove(at: i)
    }

    func deleteAll() {
        for chat in chats { stop(chat.id); Storage.delete(chat) }
        chats.removeAll()
    }

    func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    func setModel(_ id: UUID, provider: Provider, model: String) {
        update(id) {
            $0.providerID = provider.id
            $0.model = model
        }
        settings.defaultProviderID = provider.id
        if let p = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[p].defaultModel = model
        }
    }

    func setSystemPrompt(_ id: UUID, _ prompt: String?) {
        update(id) { $0.systemPrompt = prompt }
    }

    func provider(for chat: Chat) -> Provider? {
        settings.providers.first { $0.id == chat.providerID } ?? settings.defaultProvider
    }

    func model(for chat: Chat) -> String {
        if let m = chat.model, !m.isEmpty { return m }
        return provider(for: chat)?.defaultModel ?? ""
    }

    private func update(_ id: UUID, save: Bool = true, _ change: (inout Chat) -> Void) {
        guard let i = index(of: id) else { return }
        change(&chats[i])
        if save {
            chats[i].updatedAt = Date()
            Storage.save(chats[i])
        }
    }

    // MARK: - Messages

    func send(_ chatID: UUID, text: String, attachments: [Attachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        update(chatID) { chat in
            chat.messages.append(Message(role: .user, content: trimmed, attachments: attachments))
            if chat.messages.count == 1 {
                chat.title = Self.makeTitle(from: trimmed, attachments: attachments)
            }
        }
        // Move to top of the list.
        if let i = index(of: chatID), i != 0 {
            let moved = chats.remove(at: i)
            chats.insert(moved, at: 0)
        }
        generate(chatID)
    }

    func editAndResend(_ chatID: UUID, messageID: UUID, newText: String) {
        update(chatID) { chat in
            guard let i = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
            chat.messages[i].content = newText
            chat.messages.removeSubrange((i + 1)...)
        }
        generate(chatID)
    }

    /// Regenerates the assistant reply `messageID` (or the last one).
    func regenerate(_ chatID: UUID, messageID: UUID? = nil) {
        stop(chatID)
        update(chatID) { chat in
            if let messageID, let i = chat.messages.firstIndex(where: { $0.id == messageID }) {
                chat.messages.removeSubrange(i...)
            } else if chat.messages.last?.role == .assistant {
                chat.messages.removeLast()
            }
        }
        generate(chatID)
    }

    func deleteMessage(_ chatID: UUID, messageID: UUID) {
        update(chatID) { chat in
            chat.messages.removeAll { $0.id == messageID }
        }
    }

    func stop(_ chatID: UUID) {
        tasks[chatID]?.cancel()
        tasks[chatID] = nil
    }

    func isGenerating(_ chatID: UUID) -> Bool { generating.contains(chatID) }

    private func generate(_ chatID: UUID) {
        guard let chat = chat(chatID) else { return }
        guard let provider = provider(for: chat) else {
            appendError(chatID, "Сначала добавьте сервер с нейросетью в Настройках.")
            return
        }
        let model = model(for: chat)
        guard !model.isEmpty else {
            appendError(chatID, "Не выбрана модель. Нажмите на название модели сверху и выберите её.")
            return
        }

        let payload = buildMessages(for: chat)
        var options = GenerationOptions(model: model)
        options.temperature = settings.useTemperature ? settings.temperature : nil
        options.maxTokens = settings.maxTokens > 0 ? settings.maxTokens : nil
        if let extra = provider.extraBody.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: extra) as? [String: Any] {
            options.extraBody = dict
        }

        let assistantID = UUID()
        update(chatID) { $0.messages.append(Message(id: assistantID, role: .assistant, model: model)) }
        generating.insert(chatID)

        let client = LLMClient(provider: provider)
        tasks[chatID] = Task { [weak self] in
            var splitter = ThinkTagSplitter()
            var content = ""
            var reasoning = ""
            var thinkStart: Date?
            var thinkSeconds: Double?
            var promptTokens: Int?
            var completionTokens: Int?
            var errorText: String?
            var lastFlush = Date.distantPast

            func markThinking(_ isThinkingNow: Bool) {
                if isThinkingNow, thinkStart == nil { thinkStart = Date() }
                if !isThinkingNow, let start = thinkStart, thinkSeconds == nil {
                    thinkSeconds = Date().timeIntervalSince(start)
                }
            }

            do {
                for try await event in client.stream(messages: payload, options: options) {
                    switch event {
                    case .reasoning(let r):
                        markThinking(true)
                        reasoning += r
                    case .content(let c):
                        let parts = splitter.feed(c)
                        if !parts.reasoning.isEmpty { markThinking(true); reasoning += parts.reasoning }
                        if !parts.content.isEmpty {
                            if !splitter.inThink { markThinking(false) }
                            content += parts.content
                        }
                    case .usage(let p, let c):
                        promptTokens = p ?? promptTokens
                        completionTokens = c ?? completionTokens
                    }
                    // Throttle UI updates to ~20 fps.
                    if Date().timeIntervalSince(lastFlush) > 0.05 {
                        lastFlush = Date()
                        let (c, r) = (content, reasoning)
                        self?.update(chatID, save: false) { chat in
                            guard let i = chat.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                            chat.messages[i].content = c
                            chat.messages[i].reasoning = r
                        }
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }

            let rest = splitter.flush()
            content += rest.content
            reasoning += rest.reasoning
            // Models whose template opens <think> implicitly emit only the closing tag.
            if let r = content.range(of: "</think>"), !content[..<r.lowerBound].contains("<think>") {
                reasoning += content[..<r.lowerBound]
                content = String(content[r.upperBound...])
            }
            markThinking(false)
            if reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { thinkSeconds = nil }

            let finalContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalThink = thinkSeconds
            let (pt, ct, err) = (promptTokens, completionTokens, errorText)
            guard let self else { return }
            self.update(chatID) { chat in
                guard let i = chat.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                chat.messages[i].content = finalContent
                chat.messages[i].reasoning = finalReasoning
                chat.messages[i].thinkingSeconds = finalThink
                chat.messages[i].promptTokens = pt
                chat.messages[i].completionTokens = ct
                chat.messages[i].error = err
            }
            self.generating.remove(chatID)
            self.tasks[chatID] = nil
        }
    }

    private func appendError(_ chatID: UUID, _ text: String) {
        update(chatID) { $0.messages.append(Message(role: .assistant, error: text)) }
    }

    private func buildMessages(for chat: Chat) -> [[String: Any]] {
        var result: [[String: Any]] = []
        let system = (chat.systemPrompt ?? settings.systemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            result.append(["role": "system", "content": system])
        }

        var history = chat.messages.filter { message in
            // Skip failed/empty assistant turns.
            !(message.role == .assistant && message.content.isEmpty)
        }
        if settings.contextMessages > 0, history.count > settings.contextMessages {
            history = Array(history.suffix(settings.contextMessages))
        }

        for message in history {
            switch message.role {
            case .assistant:
                result.append(["role": "assistant", "content": message.content])
            case .system:
                result.append(["role": "system", "content": message.content])
            case .user:
                var text = message.content
                for att in message.attachments where att.kind != .image {
                    let body = att.extractedText ?? ""
                    text += "\n\n[Файл: \(att.filename)]\n```\n\(body)\n```"
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let images = message.attachments.filter { $0.kind == .image }
                if images.isEmpty {
                    result.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                    for img in images {
                        guard let data = try? Data(contentsOf: img.fileURL) else { continue }
                        let url = "data:\(img.mimeType);base64,\(data.base64EncodedString())"
                        parts.append(["type": "image_url", "image_url": ["url": url]])
                    }
                    result.append(["role": "user", "content": parts])
                }
            }
        }
        return result
    }

    private static func makeTitle(from text: String, attachments: [Attachment]) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if firstLine.isEmpty { return attachments.first?.filename ?? "Новый чат" }
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    // MARK: - Export

    func markdown(for chat: Chat) -> String {
        var out = "# \(chat.title)\n\n"
        for m in chat.messages {
            switch m.role {
            case .user: out += "## 🧑 Вы\n\n"
            case .assistant: out += "## 🤖 \(m.model ?? "Ассистент")\n\n"
            case .system: out += "## Система\n\n"
            }
            if !m.reasoning.isEmpty {
                out += "<details><summary>Размышления</summary>\n\n\(m.reasoning)\n\n</details>\n\n"
            }
            for a in m.attachments { out += "📎 \(a.filename)\n\n" }
            out += m.content + "\n\n"
            if let e = m.error { out += "> ⚠️ \(e)\n\n" }
        }
        return out
    }
}
