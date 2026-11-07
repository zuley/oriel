import Foundation

public struct CatalogPage: Sendable {
    public let books: [CatalogNovel]
    public let next: Int?
}

public enum CatalogSearch {
    public static func search(_ term: String, start: Int = 1) async throws -> CatalogPage {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .init(books: [], next: nil) }
        let query = String(cleaned.prefix(120)).applyingTransform(.init("Hans-Hant"), reverse: false) ?? cleaned
        var components = URLComponents(string: "https://www.gutenberg.org/ebooks/search.opds/")!
        components.queryItems = [URLQueryItem(name: "query", value: "l.zh " + query)]
        if start > 1 { components.queryItems?.append(URLQueryItem(name: "start_index", value: String(start))) }
        guard let url = components.url else { throw ReadingError.online }
        let response = try await NovelCatalogLoader.download(url)
        try Task.checkCancellation()
        return try parse(response)
    }

    public static func parse(_ data: Data) throws -> CatalogPage {
        guard data.count <= 2 * 1024 * 1024, let xml = String(data: data, encoding: .utf8),
              !xml.contains("<!ENTITY") else { throw ReadingError.damaged }
        let document = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        guard let feed = document.rootElement(), feed.localName == "feed" else { throw ReadingError.damaged }
        var books: [CatalogNovel] = []
        var seen = Set<Int>()
        for case let entry as XMLElement in feed.children ?? [] where entry.localName == "entry" {
            guard let identity = entry.elements(forName: "id").first?.stringValue,
                  let url = URL(string: identity), url.host == "www.gutenberg.org",
                  url.pathComponents.count == 3, url.pathComponents[1] == "ebooks", url.pathExtension == "opds",
                  let id = Int(url.deletingPathExtension().lastPathComponent), id > 0, seen.insert(id).inserted,
                  let title = entry.elements(forName: "title").first?.stringValue else { continue }
            if let known = CatalogNovel.all.first(where: { $0.id == id }) { books.append(known); continue }
            let original = title.hasSuffix(" (Chinese)") ? String(title.dropLast(" (Chinese)".count)) : title
            let readable = original.applyingTransform(.init("Hant-Hans"), reverse: false) ?? original
            let author = entry.elements(forName: "content").first?.stringValue ?? ""
            books.append(CatalogNovel(id: id, title: readable, author: author, originalTitle: original))
        }
        let nextLink = feed.elements(forName: "link").first { $0.attribute(forName: "rel")?.stringValue == "next" }
        let next = nextLink?.attribute(forName: "href")?.stringValue
            .flatMap { URLComponents(string: $0) }?.queryItems?.first(where: { $0.name == "start_index" })?.value.flatMap(Int.init)
        return .init(books: books, next: next)
    }
}
