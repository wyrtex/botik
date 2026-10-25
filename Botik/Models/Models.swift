import Foundation

enum Role: String, Codable, Hashable {
    case system, user, assistant
}

struct Attachment: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case image, text, pdf
    }

    var id = UUID()
    var kind: Kind
    var filename: String
    var mimeType: String
    /// Name of the file inside `Storage.attachmentsDir`.
    var storedName: String
    /// Text content for text files and PDFs (sent to the model inline).
    var extractedText: String?
    var byteSize: Int

    var fileURL: URL { Storage.attachmentsDir.appendingPathComponent(storedName) }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    var iconName: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        }
    }
}

struct Message: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: Role
    var content: String = ""
    var reasoning: String = ""
    var attachments: [Attachment] = []
    var createdAt = Date()
    var model: String?
    var error: String?
    /// Seconds the model spent thinking (nil if it did not think or still thinking).
    var thinkingSeconds: Double?
    var promptTokens: Int?
    var completionTokens: Int?
}

struct Chat: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = "Новый чат"
    var messages: [Message] = []
    var createdAt = Date()
    var updatedAt = Date()
    var providerID: UUID?
    var model: String?
    /// Per-chat system prompt override (nil → global).
    var systemPrompt: String?
}

struct Provider: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var apiKey: String = ""
    var defaultModel: String = ""
    /// Models fetched from `/models`, cached for the picker.
    var cachedModels: [String] = []
    /// Extra JSON merged into each request body, e.g. {"top_k": 40}.
    var extraBody: String = ""

    var normalizedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") { s.removeLast("/chat/completions".count) }
        return s
    }
}

struct ProviderPreset: Identifiable {
    var id: String { name }
    var name: String
    var baseURL: String
    var model: String
    var note: String

    static let all: [ProviderPreset] = [
        ProviderPreset(name: "Ollama", baseURL: "http://192.168.1.10:11434/v1",
                       model: "huihui_ai/qwen3-abliterated:8b",
                       note: "Укажите IP компьютера с Ollama. На компьютере запустите: OLLAMA_HOST=0.0.0.0 ollama serve"),
        ProviderPreset(name: "LM Studio", baseURL: "http://192.168.1.10:1234/v1",
                       model: "", note: "Включите «Serve on Local Network» в LM Studio."),
        ProviderPreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                       model: "", note: "Нужен API-ключ с openrouter.ai."),
        ProviderPreset(name: "llama.cpp server", baseURL: "http://192.168.1.10:8080/v1",
                       model: "", note: "llama-server --host 0.0.0.0"),
        ProviderPreset(name: "Свой (OpenAI-совместимый)", baseURL: "https://",
                       model: "", note: "Любой сервер с /v1/chat/completions."),
    ]
}

struct AppSettings: Codable, Hashable {
    var providers: [Provider] = []
    var defaultProviderID: UUID?
    var systemPrompt: String = ""
    var temperature: Double = 0.7
    var useTemperature: Bool = true
    var maxTokens: Int = 0
    var contextMessages: Int = 0
    var expandReasoning: Bool = false
    var sendWithReturn: Bool = false
    var imageMaxDimension: Int = 1536

    var defaultProvider: Provider? {
        providers.first { $0.id == defaultProviderID } ?? providers.first
    }
}
