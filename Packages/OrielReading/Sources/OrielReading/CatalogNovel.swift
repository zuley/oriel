import Foundation

public struct CatalogNovel: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let author: String
    public let originalTitle: String
    public static func edition(of book: ShelfBook) -> Self? {
        guard let id = book.sourceID else { return nil }
        return all.first(where: { $0.id == id }) ?? Self(id: id, title: book.title, author: book.author ?? "", originalTitle: book.title)
    }
    public var mirrors: [URL] {
        ["https://gutenberg.pglaf.org/cache/epub", "https://mirror.cs.odu.edu/gutenberg-epub"].map {
            URL(string: "\($0)/\(id)/pg\(id).txt")!
        }
    }
    public static let all = [
        Self(id: 24264, title: "红楼梦", author: "曹雪芹", originalTitle: "紅樓夢"),
        Self(id: 23962, title: "西游记", author: "吴承恩", originalTitle: "西遊記"),
        Self(id: 23950, title: "三国演义", author: "罗贯中", originalTitle: "三國志演義"),
        Self(id: 23863, title: "水浒传", author: "施耐庵", originalTitle: "水滸傳"),
        Self(id: 24273, title: "西湖佳话", author: "古吴墨浪子", originalTitle: "西湖佳話"),
        Self(id: 25297, title: "狂人日记", author: "鲁迅", originalTitle: "狂人日記"),
        Self(id: 25332, title: "阿Q正传", author: "鲁迅", originalTitle: "阿Ｑ正傳"),
        Self(id: 23850, title: "老残游记", author: "刘鹗", originalTitle: "老殘遊記"),
        Self(id: 25376, title: "三侠五义", author: "石玉昆", originalTitle: "三俠五義"),
        Self(id: 24141, title: "警世通言", author: "冯梦龙", originalTitle: "警世通言"),
        Self(id: 24239, title: "醒世恒言", author: "冯梦龙", originalTitle: "醒世恆言"),
        Self(id: 25128, title: "孽海花", author: "曾朴", originalTitle: "孽海花"),
        Self(id: 23835, title: "隋唐演义", author: "褚人获", originalTitle: "隋唐演義"),
        Self(id: 24051, title: "李娃传", author: "白行简", originalTitle: "李娃傳"),
        Self(id: 24138, title: "官场现形记", author: "李伯元", originalTitle: "官場現形記")
    ]
}
