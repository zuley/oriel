import Foundation

public struct NovelChapter: Codable, Equatable, Sendable {
    public let title: String
    public let text: String

    public func simplified() -> Self {
        let transform = StringTransform("Hant-Hans")
        let displayTitle = title.applyingTransform(transform, reverse: false) ?? title
        // The reader records UTF-16 positions in the original edition. Only apply
        // substitutions at matching character slots; leave exceptional lines intact.
        func aligned(_ source: String, _ converted: String) -> Bool {
            source.utf16.elementsEqual(converted.utf16) { lhs, rhs in
                lhs == rhs || ((0x3400...0x9fff).contains(lhs) && (0x3400...0x9fff).contains(rhs))
            }
        }
        guard let converted = text.applyingTransform(transform, reverse: false) else { return self }
        if aligned(text, converted) { return Self(title: displayTitle, text: converted) }
        let originalLines = text.components(separatedBy: "\n")
        let convertedLines = converted.components(separatedBy: "\n")
        guard originalLines.count == convertedLines.count else { return Self(title: displayTitle, text: text) }
        let lines = zip(originalLines, convertedLines).map { aligned($0, $1) ? $1 : $0 }
        return Self(title: displayTitle, text: lines.joined(separator: "\n"))
    }
}

public enum ReadingError: LocalizedError {
    case empty, unreadable, oversized, unsupported, damaged, online
    public var errorDescription: String? {
        switch self {
        case .empty: "这本书没有可读正文"
        case .unreadable: "文字编码无法识别，请另存为 UTF-8 后导入"
        case .oversized: "书籍太大，请选择 32 MB 以内的文字书"
        case .unsupported: "请选择 TXT 或无 DRM 的文字 EPUB"
        case .damaged: "书籍结构不完整，请重新获取文件"
        case .online: "暂时无法取书，请检查网络后重试"
        }
    }
}

public enum NovelText {
    static let limit = 32 * 1024 * 1024
    private enum Heading { case volume, chapter }
    private static let heading = try! NSRegularExpression(
        pattern: #"^(?:第[零〇○一二两兩三四五六七八九十百千万萬廿卅壹贰叁\d]{1,12}([回章卷节節篇集部])|(?:楔子|序章|尾声|尾聲|后记|後記)(?:\s|$)|Chapter\s+(?:\d+|[IVXLCDM]+)\b)"#,
        options: [.caseInsensitive])

    public static func chapters(data: Data, gutenberg: Bool = false) throws -> [NovelChapter] {
        guard data.count <= limit else { throw ReadingError.oversized }
        let decoded = try decode(data)
        var lines = decoded.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")[...]
        if gutenberg {
            guard let start = lines.firstIndex(where: { $0.hasPrefix("*** START OF") }),
                  let end = lines.lastIndex(where: { $0.hasPrefix("*** END OF") }), start < end else {
                throw ReadingError.damaged
            }
            let marker = lines[start]
            lines = lines[(start + 1)..<end]
            while let raw = lines.first {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let sourceCredit = line.hasPrefix("Produced by ") || line.hasPrefix("Language: ")
                let cover = !line.isEmpty && (marker.hasSuffix(line + " ***") || (line.count < 12 && line.hasSuffix("著")))
                guard line.isEmpty || sourceCredit || cover else { break }
                lines = lines.dropFirst()
            }
        }
        var chapters: [NovelChapter] = []
        var title: String?
        var volume: String?
        var body: [String] = []
        func finish() {
            let content = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeAll(keepingCapacity: true)
            guard !content.isEmpty else { return }
            if title == nil, ["目录", "目錄", "contents", "table of contents"].contains(content.lowercased()) { return }
            let name = title ?? "序言"
            let label = volume.map { $0 == name ? name : "\($0) · \(name)" } ?? name
            chapters.append(contentsOf: sections(title: label, text: content, size: title == nil || title == "正文" ? 16_000 : 100_000))
        }
        for (index, raw) in lines.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let kind = headingType(line) {
                finish()
                if kind == .volume { volume = line }
                title = line
            } else if gutenberg && !line.isEmpty {
                guard !(line.hasPrefix("---") && line.allSatisfy({ $0 == "-" })) else { continue }
                // Chinese Gutenberg editions hard-wrap print lines. Blank lines and indentation
                // mark paragraphs; remove only those print wraps from these known editions.
                if !body.isEmpty, body.last != "", raw.first?.isWhitespace != true {
                    body[body.count - 1].append(line)
                } else {
                    body.append(line)
                }
            } else if !line.isEmpty || body.last != "" {
                body.append(line)
            }
        }
        if title == nil { title = "正文" }
        finish()
        guard chapters.contains(where: { !$0.text.isEmpty }) else { throw ReadingError.empty }
        return chapters
    }

    private static func headingType(_ line: String) -> Heading? {
        guard !line.isEmpty, line.utf8.count <= 300,
              let match = heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        let tail = line[range.upperBound...]
        if let first = tail.first, !first.isWhitespace, !":：、.．—-".contains(first) {
            // Short unpunctuated chapter titles can immediately follow the number.
            guard tail.count <= 20, tail.rangeOfCharacter(from: .punctuationCharacters) == nil else { return nil }
        }
        if let unit = Range(match.range(at: 1), in: line), "卷部篇集".contains(line[unit]) { return .volume }
        return .chapter
    }

    static func sections(title: String, text: String, size: Int = 100_000) -> [NovelChapter] {
        guard text.utf8.count > size else { return [NovelChapter(title: title, text: text)] }
        var remainder = text[...]
        var result: [NovelChapter] = []
        while let boundary = remainder.index(remainder.startIndex, offsetBy: size, limitedBy: remainder.endIndex),
              boundary < remainder.endIndex {
            let nearEnd = remainder.index(boundary, offsetBy: -1000)
            let split = remainder[nearEnd..<boundary].lastIndex(of: "\n") ?? boundary
            let part = String(remainder[..<split])
            result.append(NovelChapter(title: result.isEmpty ? title : "\(title) · \(result.count + 1)", text: part))
            remainder = remainder[split...]
        }
        result.append(NovelChapter(title: result.isEmpty ? title : "\(title) · \(result.count + 1)", text: String(remainder)))
        return result
    }

    private static let binaryControls = CharacterSet(charactersIn: UnicodeScalar(0)!...UnicodeScalar(8)!)
        .union(CharacterSet(charactersIn: UnicodeScalar(14)!...UnicodeScalar(31)!))

    private static func decode(_ data: Data) throws -> String {
        let encoding: String.Encoding
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { encoding = .utf16 }
        else if let utf8 = String(data: data, encoding: .utf8) {
            guard utf8.rangeOfCharacter(from: binaryControls) == nil else { throw ReadingError.unreadable }
            return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
        } else {
            let gb = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            encoding = .init(rawValue: CFStringConvertEncodingToNSStringEncoding(gb))
        }
        guard let result = String(data: data, encoding: encoding), result.rangeOfCharacter(from: binaryControls) == nil else {
            throw ReadingError.unreadable
        }
        return result
    }
}
