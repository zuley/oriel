import Foundation

public struct NovelHit: Identifiable, Sendable {
    public let chapter: Int
    public let offset: Int
    public let length: Int
    public let excerpt: String
    public var id: String { "\(chapter)-\(offset)" }
}

public struct NovelMatches: Sendable {
    public let hits: [NovelHit]
    public let hasMore: Bool
    public static let empty = Self(hits: [], hasMore: false)
}

public struct NovelQuery: Sendable {
    fileprivate let variants: Set<String>
    public init(_ string: String) {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        variants = term.isEmpty ? [] : Set([term, term.applyingTransform(.init("Hans-Hant"), reverse: false) ?? term,
                                           term.applyingTransform(.init("Hant-Hans"), reverse: false) ?? term])
    }
    public func matches(_ text: String) -> Bool {
        variants.isEmpty || variants.contains { text.range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
    }
}

public enum NovelSearch {
    public static func find(_ query: String, in chapters: [NovelChapter], limit: Int = 80) async throws -> NovelMatches {
        let variants = NovelQuery(query).variants
        guard !variants.isEmpty, limit > 0 else { return .empty }
        var hits: [NovelHit] = []
        for (index, chapter) in chapters.enumerated() {
            let text = chapter.text as NSString
            var start = 0
            while start < text.length {
                try Task.checkCancellation()
                let searchRange = NSRange(location: start, length: text.length - start)
                let match = variants.map { text.range(of: $0, options: [.caseInsensitive, .widthInsensitive], range: searchRange) }
                    .min { $0.location < $1.location }
                guard let match, match.location != NSNotFound, match.length > 0 else { break }
                if hits.count == limit { return NovelMatches(hits: hits, hasMore: true) }
                let left = max(0, match.location - 13)
                let right = min(text.length, NSMaxRange(match) + 25)
                let snippet = text.rangeOfComposedCharacterSequences(for: NSRange(location: left, length: right - left))
                let excerpt = text.substring(with: snippet).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                hits.append(NovelHit(chapter: index, offset: match.location, length: match.length, excerpt: excerpt))
                start = NSMaxRange(match)
            }
        }
        return NovelMatches(hits: hits, hasMore: false)
    }
}
