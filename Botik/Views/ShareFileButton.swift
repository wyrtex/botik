import SwiftUI

/// Writes text to a temp file only when tapped, then opens the system share sheet
/// (which offers "Save to Files", AirDrop, other apps…).
struct ShareFileButton<Label: View>: View {
    let filename: String
    let text: () -> String
    @ViewBuilder var label: () -> Label
    @State private var item: SharedFile?

    init(filename: String, text: @autoclosure @escaping () -> String, @ViewBuilder label: @escaping () -> Label) {
        self.filename = filename
        self.text = text
        self.label = label
    }

    var body: some View {
        Button {
            if let url = Storage.exportFile(named: filename, data: Data(text().utf8)) {
                item = SharedFile(url: url)
            }
        } label: {
            label()
        }
        .sheet(item: $item) { file in
            ActivityView(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
