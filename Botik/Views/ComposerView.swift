import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(ChatStore.self) private var store
    let isGenerating: Bool
    var onSend: (String, [Attachment]) -> Void
    var onStop: () -> Void

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var loading = 0
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var canSend: Bool {
        loading == 0 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var maxDim: Int { store.settings.imageMaxDimension }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty || loading > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            ZStack(alignment: .topTrailing) {
                                if att.kind == .image {
                                    AttachmentThumbnail(attachment: att, size: 64)
                                } else {
                                    FileChip(attachment: att).frame(maxWidth: 220)
                                }
                                Button {
                                    attachments.removeAll { $0.id == att.id }
                                    try? FileManager.default.removeItem(at: att.fileURL)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(Color.white, Color.black.opacity(0.6))
                                        .font(.title3)
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                        if loading > 0 {
                            ProgressView().frame(width: 64, height: 64)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachMenu

                TextField("Сообщение", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .submitLabel(store.settings.sendWithReturn ? .send : .return)
                    .onSubmit { if store.settings.sendWithReturn { send() } }

                if isGenerating {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 34))
                    }
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .background(.bar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { loadPhotos() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach(addFile)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                add { try AttachmentLoader.image(image, filename: "photo.jpg", maxDimension: maxDim) }
            }
            .ignoresSafeArea()
        }
        .alert("Не удалось прикрепить", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Фото", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Камера", systemImage: "camera") { showCamera = true }
            }
            Button("Файл", systemImage: "doc") { showFileImporter = true }
            Button("Вставить из буфера", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
        }
    }

    private func send() {
        guard canSend, !isGenerating else { return }
        onSend(text, attachments)
        text = ""
        attachments = []
    }

    private func add(_ make: () throws -> Attachment) {
        do { attachments.append(try make()) } catch { errorMessage = error.localizedDescription }
    }

    private func addFile(_ url: URL) {
        add { try AttachmentLoader.file(at: url, maxDimension: maxDim) }
    }

    private func loadPhotos() {
        let items = photoItems
        guard !items.isEmpty else { return }
        photoItems = []
        for item in items {
            loading += 1
            Task {
                defer { loading -= 1 }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    add { try AttachmentLoader.imageData(data, filename: "image.\(ext)", maxDimension: maxDim) }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func pasteFromClipboard() {
        let pb = UIPasteboard.general
        if let images = pb.images, !images.isEmpty {
            for image in images {
                add { try AttachmentLoader.image(image, filename: "pasted.jpg", maxDimension: maxDim) }
            }
        } else if let url = pb.url, url.isFileURL {
            addFile(url)
        } else if let string = pb.string, !string.isEmpty {
            if string.count > 4000 {
                // Long text goes in as a file so the message stays readable.
                add { try AttachmentLoader.text(string, filename: "pasted.txt") }
            } else {
                text += string
            }
        } else {
            errorMessage = "Буфер обмена пуст"
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
