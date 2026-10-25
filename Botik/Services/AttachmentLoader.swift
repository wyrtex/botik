import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum AttachmentLoader {
    /// Max characters of text taken from a single file (keeps requests sane).
    static let maxTextLength = 400_000

    static func image(_ image: UIImage, filename: String = "image.jpg", maxDimension: Int) throws -> Attachment {
        let resized = image.downscaled(maxDimension: CGFloat(maxDimension))
        guard let data = resized.jpegData(compressionQuality: 0.85) else {
            throw LLMError(message: "Не удалось обработать изображение")
        }
        var name = (filename as NSString).deletingPathExtension
        if name.isEmpty { name = "image" }
        return try store(data: data, filename: name + ".jpg", kind: .image, mimeType: "image/jpeg", text: nil)
    }

    static func imageData(_ data: Data, filename: String, maxDimension: Int) throws -> Attachment {
        guard let uiImage = UIImage(data: data) else {
            throw LLMError(message: "Не удалось открыть изображение \(filename)")
        }
        return try image(uiImage, filename: filename, maxDimension: maxDimension)
    }

    static func file(at url: URL, maxDimension: Int) throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let filename = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)

        if let type, type.conforms(to: .image) {
            return try imageData(data, filename: filename, maxDimension: maxDimension)
        }

        if let type, type.conforms(to: .pdf) {
            guard let doc = PDFDocument(data: data) else {
                throw LLMError(message: "Не удалось открыть PDF \(filename)")
            }
            var text = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let pageText = page.string {
                    text += "--- Страница \(i + 1) ---\n\(pageText)\n"
                }
                if text.count > maxTextLength { break }
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw LLMError(message: "В PDF «\(filename)» нет текстового слоя (это скан). Отправьте страницы как картинки.")
            }
            return try store(data: data, filename: filename, kind: .pdf, mimeType: "application/pdf",
                             text: String(text.prefix(maxTextLength)))
        }

        if let text = decodeText(data) {
            return try store(data: data, filename: filename, kind: .text,
                             mimeType: type?.preferredMIMEType ?? "text/plain",
                             text: String(text.prefix(maxTextLength)))
        }

        throw LLMError(message: "Формат файла «\(filename)» не поддерживается. Можно отправлять картинки, PDF и любые текстовые файлы (код, txt, md, json, csv…).")
    }

    static func text(_ text: String, filename: String) throws -> Attachment {
        try store(data: Data(text.utf8), filename: filename, kind: .text, mimeType: "text/plain", text: text)
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        // Reject obvious binaries (NUL bytes in the first 8 KB).
        if data.prefix(8192).contains(0) { return nil }
        for encoding: String.Encoding in [.utf8, .utf16, .windowsCP1251, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return nil
    }

    private static func store(data: Data, filename: String, kind: Attachment.Kind,
                              mimeType: String, text: String?) throws -> Attachment {
        Storage.prepare()
        let stored = UUID().uuidString + "-" + filename.replacingOccurrences(of: "/", with: "_")
        try data.write(to: Storage.attachmentsDir.appendingPathComponent(stored))
        return Attachment(kind: kind, filename: filename, mimeType: mimeType, storedName: stored,
                          extractedText: text, byteSize: data.count)
    }
}

extension UIImage {
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, maxDimension > 0 else { return normalizedOrientation() }
        let scale = maxDimension / longest
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
