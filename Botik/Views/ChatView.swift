import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    let chatID: UUID
    var onNewChat: () -> Void

    @State private var editing: Message?
    @State private var editText = ""
    @State private var showSystemPrompt = false
    @State private var exportURL: URL?

    private var chat: Chat? { store.chat(chatID) }

    var body: some View {
        if let chat {
            content(chat)
        }
    }

    @ViewBuilder
    private func content(_ chat: Chat) -> some View {
        let generating = store.isGenerating(chatID)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty {
                        EmptyChatView(model: store.model(for: chat))
                            .padding(.top, 80)
                    }
                    ForEach(chat.messages) { message in
                        MessageView(
                            message: message,
                            isStreaming: generating && message.id == chat.messages.last?.id,
                            onRegenerate: { store.regenerate(chatID, messageID: message.id) },
                            onEdit: {
                                editText = message.content
                                editing = message
                            },
                            onDelete: { store.deleteMessage(chatID, messageID: message.id) }
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.content) {
                if generating { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.messages.last?.reasoning) {
                if generating { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(
                    isGenerating: generating,
                    onSend: { text, attachments in
                        store.send(chatID, text: text, attachments: attachments)
                    },
                    onStop: { store.stop(chatID) }
                )
            }
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModelPickerButton(chatID: chatID)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Новый чат", systemImage: "square.and.pencil", action: onNewChat)
                    Button("Системный промпт чата", systemImage: "text.badge.star") { showSystemPrompt = true }
                    if let url = exportURL {
                        ShareLink(item: url) { Label("Экспорт в Markdown", systemImage: "square.and.arrow.up") }
                    }
                    Button("Повторить последний ответ", systemImage: "arrow.clockwise") {
                        store.regenerate(chatID)
                    }
                    .disabled(chat.messages.isEmpty || generating)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .onAppear { refreshExport(chat) }
                .onChange(of: generating) { refreshExport(chat) }
            }
        }
        .sheet(item: $editing) { message in
            EditMessageSheet(text: $editText) {
                store.editAndResend(chatID, messageID: message.id, newText: editText)
                editing = nil
            }
        }
        .sheet(isPresented: $showSystemPrompt) {
            ChatSystemPromptSheet(chatID: chatID)
        }
    }

    private func refreshExport(_ chat: Chat) {
        guard !chat.messages.isEmpty else { exportURL = nil; return }
        let safe = chat.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined()
        exportURL = Storage.exportFile(named: (safe.isEmpty ? "chat" : safe) + ".md",
                                       data: Data(store.markdown(for: chat).utf8))
    }
}

private struct EmptyChatView: View {
    let model: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Чем помочь?")
                .font(.title2.weight(.semibold))
            if !model.isEmpty {
                Text(model)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Можно прикреплять фото, PDF и текстовые файлы через «+».")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .navigationTitle("Изменить сообщение")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Отправить", action: onSave)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ChatSystemPromptSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let chatID: UUID
    @State private var text = ""
    @State private var useCustom = false

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Свой промпт для этого чата", isOn: $useCustom)
                if useCustom {
                    Section("Системный промпт") {
                        TextEditor(text: $text).frame(minHeight: 180)
                    }
                } else {
                    Section("Используется общий из настроек") {
                        Text(store.settings.systemPrompt.isEmpty ? "— пусто —" : store.settings.systemPrompt)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Системный промпт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        store.setSystemPrompt(chatID, useCustom ? text : nil)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let current = store.chat(chatID)?.systemPrompt
                useCustom = current != nil
                text = current ?? store.settings.systemPrompt
            }
        }
    }
}

struct ModelPickerButton: View {
    @Environment(ChatStore.self) private var store
    let chatID: UUID
    @State private var showCustom = false
    @State private var customModel = ""

    var body: some View {
        if let chat = store.chat(chatID) {
            let current = store.model(for: chat)
            let currentProvider = store.provider(for: chat)
            Menu {
                ForEach(store.settings.providers) { provider in
                    Section(provider.name) {
                        let models = provider.cachedModels.isEmpty ? [provider.defaultModel] : provider.cachedModels
                        ForEach(models.filter { !$0.isEmpty }, id: \.self) { model in
                            Button {
                                store.setModel(chatID, provider: provider, model: model)
                            } label: {
                                if provider.id == currentProvider?.id && model == current {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Ввести название модели…", systemImage: "keyboard") {
                    customModel = current
                    showCustom = true
                }
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 3) {
                        Text(current.isEmpty ? "Выбрать модель" : shortName(current))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    if let currentProvider {
                        Text(currentProvider.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: 220)
            }
            .alert("Модель", isPresented: $showCustom) {
                TextField("например huihui_ai/qwen3-abliterated:8b", text: $customModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Готово") {
                    if let p = currentProvider, !customModel.isEmpty {
                        store.setModel(chatID, provider: p, model: customModel.trimmingCharacters(in: .whitespaces))
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func shortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
