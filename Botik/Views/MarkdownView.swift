import SwiftUI

enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case code(language: String, code: String)
    case listItem(marker: String, text: String, indent: Int)
    case quote(String)
    case table([[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }
        func flushAll() { flushParagraph(); flushQuote(); flushTable() }

        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .init(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(next)
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushAll(); continue }

            if trimmed.hasPrefix("|") {
                flushParagraph(); flushQuote()
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { "-:".contains($0) }
                }
                if !isSeparator { table.append(cells) }
                continue
            } else { flushTable() }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else { flushQuote() }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level, String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> MDBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count / 2
        let s = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            var text = String(s.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑︎"; text.removeFirst(4) }
            return .listItem(marker: marker, text: text, indent: indent)
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(marker: String(digits) + ".", text: String(rest.dropFirst(2)), indent: indent)
            }
        }
        return nil
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownParser.inline(s))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .textSelection(.enabled)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .listItem(let marker, let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(MarkdownParser.inline(s))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            Text(MarkdownParser.inline(s))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 3)
                }
        case .table(let rows):
            TableBlockView(rows: rows)
        case .rule:
            Divider()
        }
    }
}

struct TableBlockView: View {
    let rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            Text(MarkdownParser.inline(col < row.count ? row[col] : ""))
                                .font(index == 0 ? .subheadline.bold() : .subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: 60, maxWidth: 280, maxHeight: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(index == 0 ? Color.secondary.opacity(0.15) : index % 2 == 0 ? Color.secondary.opacity(0.05) : Color.clear)
                        }
                    }
                    if index < rows.count - 1 { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(language.isEmpty ? "код" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                ShareFileButton(filename: "code." + Self.fileExtension(for: language), text: code) {
                    Image(systemName: "square.and.arrow.down")
                }
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.15))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    static func fileExtension(for language: String) -> String {
        let map: [String: String] = [
            "python": "py", "py": "py", "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts",
            "swift": "swift", "kotlin": "kt", "java": "java", "c": "c", "cpp": "cpp", "c++": "cpp",
            "csharp": "cs", "cs": "cs", "go": "go", "rust": "rs", "rs": "rs", "ruby": "rb", "php": "php",
            "html": "html", "css": "css", "json": "json", "yaml": "yaml", "yml": "yml", "xml": "xml",
            "bash": "sh", "sh": "sh", "shell": "sh", "zsh": "sh", "sql": "sql", "markdown": "md", "md": "md",
            "lua": "lua", "dart": "dart", "toml": "toml", "ini": "ini", "csv": "csv", "powershell": "ps1",
        ]
        let key = language.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return map[key] ?? "txt"
    }
}
