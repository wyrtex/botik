import SwiftUI

struct RootView: View {
    @Environment(ChatStore.self) private var store
    @State private var selection: UUID?
    @State private var showSettings = false
    @State private var search = ""
    @State private var renaming: Chat?
    @State private var renameText = ""

    private var filteredChats: [Chat] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.chats }
        return store.chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(q)
                || chat.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filteredChats) { chat in
                    NavigationLink(value: chat.id) {
                        ChatRow(chat: chat, generating: store.isGenerating(chat.id))
                    }
                    .contextMenu {
                        Button("Переименовать", systemImage: "pencil") {
                            renameText = chat.title
                            renaming = chat
                        }
                        Button("Удалить", systemImage: "trash", role: .destructive) {
                            delete(chat.id)
                        }
                    }
                    .swipeActions {
                        Button("Удалить", systemImage: "trash", role: .destructive) {
                            delete(chat.id)
                        }
                    }
                }
            }
            .overlay {
                if store.chats.isEmpty {
                    ContentUnavailableView("Нет чатов", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Нажмите ✎, чтобы начать новый диалог"))
                }
            }
            .searchable(text: $search, prompt: "Поиск по чатам")
            .navigationTitle("Botik")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selection = store.newChat().id } label: { Image(systemName: "square.and.pencil") }
                }
            }
        } detail: {
            if let id = selection, store.chat(id) != nil {
                ChatView(chatID: id, onNewChat: { selection = store.newChat().id })
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("Botik", systemImage: "sparkles")
                } description: {
                    Text("Выберите чат или создайте новый")
                } actions: {
                    Button("Новый чат") { selection = store.newChat().id }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Переименовать чат", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Готово") {
                if let chat = renaming { store.rename(chat.id, to: renameText) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
        .onAppear {
            if store.settings.providers.isEmpty { showSettings = true }
        }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        store.delete(id)
    }
}

private struct ChatRow: View {
    let chat: Chat
    let generating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(chat.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if generating { ProgressView().controlSize(.mini) }
            }
            HStack {
                Text(preview).lineLimit(1)
                Spacer()
                Text(chat.updatedAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        guard let last = chat.messages.last else { return chat.model ?? "Пусто" }
        if !last.content.isEmpty { return last.content.replacingOccurrences(of: "\n", with: " ") }
        if let e = last.error { return "⚠️ " + e }
        return last.attachments.first.map { "📎 " + $0.filename } ?? ""
    }
}
