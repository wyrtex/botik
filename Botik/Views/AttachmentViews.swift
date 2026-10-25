import QuickLook
import SwiftUI

struct AttachmentGrid: View {
    let attachments: [Attachment]
    var alignment: HorizontalAlignment = .leading
    @State private var previewURL: URL?
    @State private var viewing: Attachment?

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            let images = attachments.filter { $0.kind == .image }
            let files = attachments.filter { $0.kind != .image }
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { att in
                        AttachmentThumbnail(attachment: att, size: images.count == 1 ? 200 : 110)
                            .onTapGesture { viewing = att }
                    }
                }
            }
            ForEach(files) { att in
                FileChip(attachment: att)
                    .onTapGesture { previewURL = att.fileURL }
            }
        }
        .fullScreenCover(item: $viewing) { att in
            ImageViewer(attachment: att)
        }
        .quickLookPreview($previewURL)
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: attachment.fileURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct FileChip: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .padding(.trailing, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var detail: String {
        var s = attachment.sizeLabel
        if let t = attachment.extractedText { s += " · \(t.count) симв." }
        return s
    }
}

struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: Attachment
    @State private var scale: CGFloat = 1
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: attachment.fileURL.path) {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: UIScreen.main.bounds.width * scale)
                            .gesture(MagnifyGesture().onChanged { scale = max(1, min(5, $0.magnification)) })
                            .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
                    }
                    .defaultScrollAnchor(.center)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                    ShareLink(item: attachment.fileURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .alert(savedMessage ?? "", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
                Button("OK") {}
            }
        }
    }

    private func save() {
        guard let image = UIImage(contentsOfFile: attachment.fileURL.path) else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        savedMessage = "Сохранено в Фото"
    }
}
