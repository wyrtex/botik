import SwiftUI

struct MessageView: View {
    @Environment(ChatStore.self) private var store
    let message: Message
    let isStreaming: Bool
    var onRegenerate: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: userBubble
        default: assistantBody
        }
    }

    // MARK: User

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                AttachmentGrid(attachments: message.attachments, alignment: .trailing)
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        Button("Копировать", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                        Button("Изменить и отправить", systemImage: "pencil", action: onEdit)
                        Button("Удалить", systemImage: "trash", role: .destructive, action: onDelete)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    // MARK: Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.reasoning.isEmpty || (isStreaming && message.content.isEmpty && message.reasoning.isEmpty) {
                ThinkingView(
                    reasoning: message.reasoning,
                    seconds: message.thinkingSeconds,
                    isThinking: isStreaming && message.content.isEmpty,
                    startExpanded: store.settings.expandReasoning
                )
            }

            if !message.content.isEmpty {
                MarkdownView(text: message.content)
            }

            if let error = message.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Повторить", systemImage: "arrow.clockwise", action: onRegenerate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            if !isStreaming && (!message.content.isEmpty || !message.reasoning.isEmpty) {
                actionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = message.content
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            ShareLink(item: message.content) { Image(systemName: "square.and.arrow.up") }
            Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
            Menu {
                Button("Выделить текст", systemImage: "selection.pin.in.out") { showSelectable = true }
                Button("Удалить", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            Spacer()
            if let model = message.model {
                Text(statsLine(model: model))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .sheet(isPresented: $showSelectable) {
            SelectableTextSheet(text: message.content)
        }
    }

    @State private var showSelectable = false

    private func statsLine(model: String) -> String {
        var parts = [model.split(separator: "/").last.map(String.init) ?? model]
        if let c = message.completionTokens { parts.append("\(c) ток.") }
        return parts.joined(separator: " · ")
    }
}

struct ThinkingView: View {
    let reasoning: String
    let seconds: Double?
    let isThinking: Bool
    let startExpanded: Bool
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? (startExpanded || isThinking) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, isActive: isThinking)
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded && !reasoning.isEmpty {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
            }
        }
    }

    private var title: String {
        if isThinking { return "Думает…" }
        if let seconds { return "Думал \(Self.format(seconds))" }
        return "Размышления"
    }

    private static func format(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded())) с" }
        return "\(Int(s) / 60) мин \(Int(s) % 60) с"
    }
}

struct SelectableTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .padding(.horizontal, 8)
                .navigationTitle("Выделение текста")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                }
        }
    }
}

/// UITextView gives proper partial text selection, unlike SwiftUI `Text`.
struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.text = text
    }
}
