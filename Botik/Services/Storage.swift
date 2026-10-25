import Foundation

enum Storage {
    static let rootDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Botik", isDirectory: true)
    }()

    static let chatsDir = rootDir.appendingPathComponent("chats", isDirectory: true)
    static let attachmentsDir = rootDir.appendingPathComponent("attachments", isDirectory: true)
    static let settingsURL = rootDir.appendingPathComponent("settings.json")
    static let exportsDir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)

    static func prepare() {
        for dir in [chatsDir, attachmentsDir, exportsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func loadChats() -> [Chat] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Chat.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ chat: Chat) {
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: chatsDir.appendingPathComponent("\(chat.id.uuidString).json"), options: .atomic)
    }

    static func delete(_ chat: Chat) {
        try? FileManager.default.removeItem(at: chatsDir.appendingPathComponent("\(chat.id.uuidString).json"))
        for message in chat.messages {
            for attachment in message.attachments {
                try? FileManager.default.removeItem(at: attachment.fileURL)
            }
        }
    }

    static func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? decoder.decode(AppSettings.self, from: data)
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsURL, options: [.atomic, .completeFileProtection])
    }

    /// Writes `data` to a temp file with the given name so it can be shared / saved via the share sheet.
    static func exportFile(named name: String, data: Data) -> URL? {
        let dir = exportsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
