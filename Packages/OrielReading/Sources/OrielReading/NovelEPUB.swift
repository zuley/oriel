import Foundation
import ZIPFoundation

public struct ParsedNovel: Sendable {
    public var title: String?
    public var author: String?
    public let chapters: [NovelChapter]
}

public enum NovelEPUB {
    public static func read(_ data: Data) throws -> ParsedNovel {
        guard data.count <= NovelText.limit else { throw ReadingError.oversized }
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw ReadingError.damaged }
        var entries: [String: Entry] = [:]
        for (index, entry) in archive.enumerated() {
            guard index < 10_000 else { throw ReadingError.oversized }
            if entry.type == .file { entries[entry.path] = entry }
        }
        var remaining = NovelText.limit
        func document(_ path: String) throws -> XMLDocument {
            try Task.checkCancellation()
            guard let entry = entries[path] else { throw ReadingError.damaged }
            let limit = min(remaining, 8 * 1024 * 1024)
            guard entry.uncompressedSize <= limit else { throw ReadingError.oversized }
            var bytes = Data()
            let crc = try archive.extract(entry) { chunk in
                guard chunk.count <= limit - bytes.count else { throw ReadingError.oversized }
                bytes.append(chunk)
            }
            guard crc == entry.checksum else { throw ReadingError.damaged }
            remaining -= bytes.count
            // EPUB XML is UTF-8 or UTF-16. External DTDs are unnecessary for reflow.
            let isUTF16 = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
            guard var xml = String(data: bytes, encoding: isUTF16 ? .utf16 : .utf8),
                  !xml.contains("\0"), !xml.contains("<!ENTITY") else { throw ReadingError.damaged }
            xml = xml.replacingOccurrences(of: "&nbsp;", with: "&#160;")
            return try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        }
        let container = try document("META-INF/container.xml")
        guard let packagePath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw ReadingError.damaged
        }
        let package = try document(packagePath)
        let title = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue
        let author = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']").first?.stringValue
        var manifest: [String: String] = [:]
        var nonReadingItems = Set<String>()
        var navigation: String?
        var ncx: String?
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue,
                  let target = target(href, relativeTo: packagePath) else { continue }
            let type = item.attribute(forName: "media-type")?.stringValue
            if item.attribute(forName: "properties")?.stringValue?.split(separator: " ").contains("nav") == true {
                navigation = target.path
                nonReadingItems.insert(id)
            } else if type == "application/x-dtbncx+xml" {
                ncx = target.path
                nonReadingItems.insert(id)
            } else if type == "application/xhtml+xml" || type == "text/html" {
                manifest[id] = target.path
            } else {
                nonReadingItems.insert(id)
            }
        }
        var toc: [String: [String: String]] = [:]
        if let path = navigation ?? ncx, let index = try? document(path) {
            let isNCX = navigation == nil
            let query = isNCX ? "//*[local-name()='navPoint']" :
                "//*[local-name()='nav'][@*[local-name()='type']='toc']//*[local-name()='a']"
            for case let node as XMLElement in try index.nodes(forXPath: query) {
                let href = isNCX ? try node.nodes(forXPath: "./*[local-name()='content']/@src").first?.stringValue :
                    node.attribute(forName: "href")?.stringValue
                let label = isNCX ? try node.nodes(forXPath: "./*[local-name()='navLabel']").first?.stringValue : node.stringValue
                guard let href, let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                      let link = target(href, relativeTo: path) else { continue }
                toc[link.path, default: [:]][link.fragment] = label
            }
        }
        var chapters: [NovelChapter] = []
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard item.attribute(forName: "linear")?.stringValue != "no" else { continue }
            guard let id = item.attribute(forName: "idref")?.stringValue else { throw ReadingError.damaged }
            if nonReadingItems.contains(id) { continue }
            guard let path = manifest[id] else { throw ReadingError.damaged }
            let page = try document(path)
            chapters += try readPage(page, targets: toc[path] ?? [:], number: chapters.count + 1)
        }
        guard !chapters.isEmpty else { throw ReadingError.unsupported }
        return ParsedNovel(title: title, author: author, chapters: chapters)
    }

    private static func target(_ href: String, relativeTo document: String) -> (path: String, fragment: String)? {
        let parts = href.components(separatedBy: "#")
        guard let path = parts[0].removingPercentEncoding, !path.hasPrefix("/"), !path.contains(":") else { return nil }
        var components = document.split(separator: "/").map(String.init)
        if !path.isEmpty {
            _ = components.popLast()
            for component in path.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    guard components.popLast() != nil else { return nil }
                } else { components.append(String(component)) }
            }
        }
        return (components.joined(separator: "/"), parts.dropFirst().first?.removingPercentEncoding ?? "")
    }

    private static func readPage(_ page: XMLDocument, targets: [String: String], number: Int) throws -> [NovelChapter] {
        guard let body = try page.nodes(forXPath: "//*[local-name()='body']").first else { return [] }
        let firstHeading = try body.nodes(forXPath: ".//*[local-name()='h1' or local-name()='h2' or local-name()='h3']").first
        let head = try page.nodes(forXPath: "//*[local-name()='head']/*[local-name()='title']").first?.stringValue
        var title = [targets[""], firstHeading?.stringValue, head].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "第 \(number) 节"
        var chapters: [NovelChapter] = []
        var blocks: [String] = []
        var line = ""
        func flushLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            line = ""
        }
        func finish() {
            flushLine()
            if !blocks.isEmpty { chapters += NovelText.sections(title: title, text: blocks.joined(separator: "\n\n")) }
            blocks.removeAll(keepingCapacity: true)
        }
        func visit(_ node: XMLNode) {
            if node.kind == .text {
                line += (node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                return
            }
            guard let element = node as? XMLElement else { return }
            let name = element.localName?.lowercased() ?? ""
            if ["script", "style", "svg", "noscript"].contains(name) { return }
            if let id = element.attribute(forName: "id")?.stringValue, let nextTitle = targets[id] {
                finish()
                title = nextTitle
            }
            if ["h1", "h2", "h3"].contains(name), blocks.isEmpty,
               element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == title { return }
            if name == "pre" {
                flushLine()
                line = element.stringValue ?? ""
                flushLine()
                return
            }
            let block = ["p", "div", "section", "li", "blockquote", "br", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name)
            if block { flushLine() }
            element.children?.forEach(visit)
            if block { flushLine() }
        }
        visit(body)
        finish()
        return chapters
    }
}
