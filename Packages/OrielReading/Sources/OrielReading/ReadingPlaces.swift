import Foundation

public struct ReadingPlace: Sendable {
    public var chapter: Int
    public var offset: Int
    public var updated: Date?

    public init(chapter: Int, offset: Int, updated: Date?) {
        self.chapter = chapter
        self.offset = offset
        self.updated = updated
    }
}

public struct ReadingMark: Identifiable, Equatable, Codable, Sendable {
    public let chapter: Int
    public let offset: Int
    public let excerpt: String
    public var id: String { "\(chapter)-\(offset)" }
}

@MainActor
public struct ReadingPlaces {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func place(for book: String) -> ReadingPlace {
        let saved = defaults.dictionary(forKey: key(book))
        return ReadingPlace(chapter: max(0, saved?["chapter"] as? Int ?? 0),
                            offset: max(0, saved?["offset"] as? Int ?? 0), updated: saved?["updated"] as? Date)
    }

    public func save(book: String, chapter: Int, offset: Int) {
        defaults.set(["chapter": chapter, "offset": offset, "updated": Date()], forKey: key(book))
    }

    public func marks(for book: String) -> [ReadingMark] {
        guard let data = defaults.data(forKey: markKey(book)) else { return [] }
        return (try? JSONDecoder().decode([ReadingMark].self, from: data)) ?? []
    }

    public func addMark(book: String, chapter: Int, offset: Int, excerpt: String) {
        var saved = marks(for: book)
        guard !saved.contains(where: { $0.chapter == chapter && $0.offset == offset }) else { return }
        saved.insert(ReadingMark(chapter: chapter, offset: offset, excerpt: excerpt), at: 0)
        defaults.set(try? JSONEncoder().encode(saved), forKey: markKey(book))
    }

    public func removeMark(book: String, mark: ReadingMark) {
        let saved = marks(for: book).filter { $0.id != mark.id }
        defaults.set(try? JSONEncoder().encode(saved), forKey: markKey(book))
    }

    public func remove(book: String) {
        defaults.removeObject(forKey: key(book))
        defaults.removeObject(forKey: markKey(book))
    }
    private func markKey(_ book: String) -> String { "novel.marks.v1." + book }
    private func key(_ book: String) -> String { "novel.place.v1." + book }
}
