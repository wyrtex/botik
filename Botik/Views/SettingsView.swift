import SwiftUI

struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editingProvider: Provider?
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    ForEach(store.settings.providers) { provider in
                        Button {
                            editingProvider = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name).foregroundStyle(.primary)
                                    Text(provider.defaultModel.isEmpty ? provider.normalizedBaseURL : provider.defaultModel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if provider.id == store.settings.defaultProvider?.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Удалить", role: .destructive) {
                                store.settings.providers.removeAll { $0.id == provider.id }
                            }
                            Button("По умолчанию") {
                                store.settings.defaultProviderID = provider.id
                            }
                            .tint(.blue)
                        }
                    }
                    Menu {
                        ForEach(ProviderPreset.all) { preset in
                            Button(preset.name) {
                                editingProvider = Provider(name: preset.name, baseURL: preset.baseURL,
                                                           defaultModel: preset.model)
                            }
                        }
                    } label: {
                        Label("Добавить сервер", systemImage: "plus")
                    }
                } header: {
                    Text("Серверы с нейросетями")
                } footer: {
                    Text("Подходит любой OpenAI-совместимый API: Ollama (модели huihui_ai/…-abliterated), LM Studio, llama.cpp, vLLM, OpenRouter и т.п. Свайп влево — удалить / сделать по умолчанию.")
                }

                Section("Системный промпт (для всех чатов)") {
                    TextEditor(text: $store.settings.systemPrompt)
                        .frame(minHeight: 100)
                }

                Section("Генерация") {
                    Toggle("Задавать температуру", isOn: $store.settings.useTemperature)
                    if store.settings.useTemperature {
                        VStack(alignment: .leading) {
                            Text("Температура: \(store.settings.temperature, specifier: "%.2f")")
                            Slider(value: $store.settings.temperature, in: 0...2, step: 0.05)
                        }
                    }
                    Stepper(value: $store.settings.maxTokens, in: 0...131_072, step: 512) {
                        Text("Макс. токенов: \(store.settings.maxTokens == 0 ? "без лимита" : "\(store.settings.maxTokens)")")
                    }
                    Stepper(value: $store.settings.contextMessages, in: 0...200, step: 2) {
                        Text("Сообщений в контексте: \(store.settings.contextMessages == 0 ? "все" : "\(store.settings.contextMessages)")")
                    }
                }

                Section("Интерфейс") {
                    Toggle("Разворачивать размышления", isOn: $store.settings.expandReasoning)
                    Toggle("Отправка по Return", isOn: $store.settings.sendWithReturn)
                    Picker("Размер картинок", selection: $store.settings.imageMaxDimension) {
                        Text("1024 px").tag(1024)
                        Text("1536 px").tag(1536)
                        Text("2048 px").tag(2048)
                        Text("Оригинал").tag(100_000)
                    }
                }

                Section {
                    Button("Удалить все чаты", role: .destructive) { confirmDeleteAll = true }
                } footer: {
                    Text("Botik \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .sheet(item: $editingProvider) { provider in
                ProviderEditView(provider: provider)
            }
            .confirmationDialog("Удалить все чаты?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { store.deleteAll() }
            }
        }
    }
}

struct ProviderEditView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var provider: Provider
    @State private var loadingModels = false
    @State private var status: String?
    @State private var statusIsError = false

    private var isNew: Bool { !store.settings.providers.contains { $0.id == provider.id } }
    private var preset: ProviderPreset? { ProviderPreset.all.first { $0.name == provider.name } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $provider.name)
                    TextField("Адрес API", text: $provider.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API-ключ (если нужен)", text: $provider.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let note = preset?.note { Text(note) }
                }

                Section {
                    TextField("Модель", text: $provider.defaultModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await loadModels() }
                    } label: {
                        HStack {
                            Label("Загрузить список моделей", systemImage: "arrow.down.circle")
                            if loadingModels { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loadingModels)
                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? Color.red : Color.green)
                    }
                } header: {
                    Text("Модель")
                } footer: {
                    Text("Нажмите «Загрузить список» — заодно проверится подключение. Например: huihui_ai/qwen3-abliterated:8b, huihui_ai/gemma3-abliterated (видит картинки), huihui_ai/deepseek-r1-abliterated (размышляет).")
                }

                if !provider.cachedModels.isEmpty {
                    Section("Доступные модели (\(provider.cachedModels.count))") {
                        ForEach(provider.cachedModels, id: \.self) { model in
                            Button {
                                provider.defaultModel = model
                            } label: {
                                HStack {
                                    Text(model).font(.callout.monospaced()).foregroundStyle(.primary)
                                    Spacer()
                                    if model == provider.defaultModel {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $provider.extraBody)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 70)
                } header: {
                    Text("Доп. параметры запроса (JSON)")
                } footer: {
                    Text("Добавляются в тело запроса. Пример: {\"top_p\": 0.9, \"reasoning_effort\": \"high\"}")
                }
            }
            .navigationTitle(isNew ? "Новый сервер" : provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(provider.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let extra = provider.extraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            let valid = extra.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } != nil
            if !valid {
                status = "Доп. параметры — невалидный JSON-объект"
                statusIsError = true
                return
            }
        }
        if let i = store.settings.providers.firstIndex(where: { $0.id == provider.id }) {
            store.settings.providers[i] = provider
        } else {
            store.settings.providers.append(provider)
            if store.settings.providers.count == 1 { store.settings.defaultProviderID = provider.id }
        }
        dismiss()
    }

    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            let models = try await LLMClient(provider: provider).listModels()
            provider.cachedModels = models
            if provider.defaultModel.isEmpty, let first = models.first { provider.defaultModel = first }
            status = models.isEmpty ? "Подключено, но сервер не вернул моделей" : "Подключено ✓ Моделей: \(models.count)"
            statusIsError = models.isEmpty
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }
}
