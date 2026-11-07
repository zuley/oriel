import Foundation
import Combine

struct StockSymbol: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String

    var market: String { String(id.prefix(2)).uppercased() }
    var code: String { String(id.dropFirst(2)) }

    static let index = StockSymbol(id: "sh000001", name: "上证指数")
    static let initial = [
        StockSymbol(id: "sz300502", name: "新易盛"), StockSymbol(id: "hk02636", name: "传音控股"),
        StockSymbol(id: "sh600183", name: "生益科技"), StockSymbol(id: "usSPCX", name: "SpaceX"),
        StockSymbol(id: "hk02513", name: "智谱"), StockSymbol(id: "sz002400", name: "省广集团")
    ]
}

struct StockQuote: Sendable {
    let providerCode: String
    let price: String
    let change: String
    let percent: String
    let asOf: String
}

struct DailyCandle: Sendable {
    let date: String
    let open, close, high, low: Double

    static func parse(_ data: Data, key: String) throws -> [Self] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["code"] as? Int == 0, let markets = envelope["data"] as? [String: Any],
              let series = markets[key] as? [String: Any],
              let rows = (series["qfqday"] ?? series["day"]) as? [[Any]] else {
            throw URLError(.cannotParseResponse)
        }
        // Some rows carry a corporate-action object after the OHLC and volume fields.
        let candles = rows.compactMap { row -> Self? in
            guard row.count >= 5, let date = row[0] as? String,
                  let fields = Array(row[1...4]) as? [String] else { return nil }
            let prices = fields.compactMap(Double.init)
            guard prices.count == 4, prices.allSatisfy(\.isFinite),
                  prices[2] >= max(prices[0], prices[1]), prices[3] <= min(prices[0], prices[1]) else { return nil }
            return Self(date: date, open: prices[0], close: prices[1], high: prices[2], low: prices[3])
        }
        guard !candles.isEmpty else { throw URLError(.cannotParseResponse) }
        return Array(candles.sorted { $0.date < $1.date }.suffix(60))
    }
}

struct IntradaySession: Sendable {
    let points: [MinutePrice]
    let previousClose: Double?
}

struct MinutePrice: Sendable {
    let minute: Int
    let price: Double
}

enum TencentMarket {
    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func quotes(for symbols: [StockSymbol]) async throws -> [String: StockQuote] {
        let ids = symbols.map(\.id)
        var quotes: [String: StockQuote] = [:]
        for start in stride(from: 0, to: ids.count, by: 40) {
            let batch = ids[start..<min(start + 40, ids.count)]
            guard let url = URL(string: "https://qt.gtimg.cn/q=" + batch.joined(separator: ",")) else {
                throw URLError(.badURL)
            }
            let bytes = try await fetch(url)
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            guard let text = String(data: bytes, encoding: .init(rawValue: encoding)) else {
                throw URLError(.cannotDecodeContentData)
            }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.components(separatedBy: "=\"")
                guard parts.count == 2, parts[0].hasPrefix("v_") else { continue }
                let id = String(parts[0].dropFirst(2))
                let fields = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\";")).components(separatedBy: "~")
                guard batch.contains(id), fields.count > 32, let price = Double(fields[3]), price.isFinite, price > 0,
                      Double(fields[31])?.isFinite == true, Double(fields[32])?.isFinite == true else { continue }
                quotes[id] = StockQuote(providerCode: fields[2], price: fields[3], change: fields[31], percent: fields[32], asOf: fields[30])
            }
        }
        guard !quotes.isEmpty else { throw URLError(.cannotParseResponse) }
        return quotes
    }

    private static func chartKey(for symbol: StockSymbol, quote: StockQuote?) async throws -> String {
        guard symbol.market == "US" else { return symbol.id }
        // US charts require the exchange suffix, e.g. AAPL.OQ.
        let code: String?
        if let quote { code = quote.providerCode }
        else { code = try await quotes(for: [symbol])[symbol.id]?.providerCode }
        guard let code, !code.isEmpty else { throw URLError(.cannotParseResponse) }
        return "us" + code
    }

    static func intraday(for symbol: StockSymbol, quote: StockQuote?) async throws -> IntradaySession {
        let key = try await chartKey(for: symbol, quote: quote)
        let feed = symbol.market == "US" ? "UsMinute" : "minute"
        var url = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/" + feed + "/query")!
        url.queryItems = [.init(name: "code", value: key)]
        guard let requestURL = url.url else { throw URLError(.badURL) }
        let data = try await fetch(requestURL)
        struct Envelope: Decodable {
            struct Series: Decodable {
                struct Session: Decodable { let data: [String] }
                let qt: [String: [String]]?
                let data: Session
            }
            let code: Int
            let data: [String: Series]
        }
        let result = try JSONDecoder().decode(Envelope.self, from: data)
        guard result.code == 0, let session = result.data[key] else { throw URLError(.cannotParseResponse) }
        let points = session.data.data.compactMap { row -> MinutePrice? in
            let fields = row.split(separator: " ")
            guard fields.count >= 2, fields[0].count == 4,
                  let hour = Int(fields[0].prefix(2)), (0..<24).contains(hour),
                  let minute = Int(fields[0].suffix(2)), (0..<60).contains(minute),
                  let price = Double(fields[1]), price.isFinite, price > 0 else { return nil }
            return MinutePrice(minute: hour * 60 + minute, price: price)
        }
        guard !points.isEmpty else { throw URLError(.cannotParseResponse) }
        let previousClose = session.qt?[key].flatMap { fields -> Double? in
            guard fields.count > 4, let close = Double(fields[4]), close.isFinite, close > 0 else { return nil }
            return close
        }
        return IntradaySession(points: points.sorted { $0.minute < $1.minute }, previousClose: previousClose)
    }

    static func dailyCandles(for symbol: StockSymbol, quote: StockQuote?) async throws -> [DailyCandle] {
        let key = try await chartKey(for: symbol, quote: quote)
        let feed = symbol.market == "US" ? "usfqkline" : "fqkline"
        var url = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/" + feed + "/get")!
        url.queryItems = [.init(name: "param", value: key + ",day,,,60,qfq")]
        guard let requestURL = url.url else { throw URLError(.badURL) }
        return try DailyCandle.parse(try await fetch(requestURL), key: key)
    }

    static func search(_ query: String) async throws -> [StockSymbol] {
        var components = URLComponents(string: "https://smartbox.gtimg.cn/s3/")!
        components.queryItems = [.init(name: "t", value: "all"), .init(name: "q", value: query)]
        guard let url = components.url else { throw URLError(.badURL) }
        let data = try await fetch(url)
        guard let raw = String(data: data, encoding: .utf8), let first = raw.firstIndex(of: "\""),
              let last = raw.lastIndex(of: "\""), first < last else { throw URLError(.cannotParseResponse) }
        let payload = try JSONDecoder().decode(String.self, from: Data(raw[first...last].utf8))
        var seen = Set<String>()
        return payload.split(separator: "^").compactMap { row in
            let fields = row.components(separatedBy: "~")
            guard fields.count >= 3 else { return nil }
            let market = fields[0]
            var code = fields[1].uppercased()
            switch market {
            case "sh", "sz", "hk":
                guard code.allSatisfy(\.isNumber) else { return nil }
            case "us":
                if let dot = code.lastIndex(of: "."), ["N","OQ","O","A","PS","AM"].contains(String(code[code.index(after: dot)...])) {
                    code = String(code[..<dot])
                }
            default: return nil
            }
            guard !code.isEmpty, code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }),
                  seen.insert(market + code).inserted else { return nil }
            return StockSymbol(id: market + code, name: fields[2])
        }
    }
}

@MainActor
final class StockWatchlist: ObservableObject {
    @Published private(set) var symbols: [StockSymbol]
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var status = "行情可能延时"
    @Published private(set) var loading = false
    private let defaults: UserDefaults
    private let fetchQuotes: @Sendable ([StockSymbol]) async throws -> [String: StockQuote]
    private let key = "watchlist.symbols.v1"
    private var ticker: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var lastQuoteUpdate: ContinuousClock.Instant?
    private static let interval: Duration = .seconds(30)

    init(defaults: UserDefaults = .standard,
         fetchQuotes: @escaping @Sendable ([StockSymbol]) async throws -> [String: StockQuote] = TencentMarket.quotes(for:)) {
        self.defaults = defaults
        self.fetchQuotes = fetchQuotes
        symbols = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([StockSymbol].self, from: $0) } ?? StockSymbol.initial
    }

    func setVisible(_ visible: Bool) {
        guard visible != (ticker != nil) else { return }
        if visible {
            let remaining = lastQuoteUpdate.map { Self.interval - $0.duration(to: .now) } ?? .zero
            if remaining <= .zero { refresh() }
            ticker = Task { [weak self] in
                var delay = remaining > .zero ? remaining : Self.interval
                while !Task.isCancelled {
                    do { try await Task.sleep(for: delay) } catch { return }
                    if self?.loading == false { self?.refresh() }
                    delay = Self.interval
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
            request?.cancel()
            loading = false
        }
    }

    func toggle(_ symbol: StockSymbol) {
        if symbols.contains(where: { $0.id == symbol.id }) {
            symbols.removeAll { $0.id == symbol.id }
        } else {
            symbols.append(symbol)
        }
        defaults.set(try? JSONEncoder().encode(symbols), forKey: key)
        lastQuoteUpdate = nil
        refresh()
    }

    func refresh() {
        request?.cancel()
        loading = true
        var items = symbols.filter { $0.id != StockSymbol.index.id }
        items.append(.index)
        request = Task { [weak self, items, fetchQuotes] in
            do {
                let result = try await fetchQuotes(items)
                try Task.checkCancellation()
                self?.quotes = result
                self?.lastQuoteUpdate = .now
                self?.status = result.count < items.count ? "部分行情缺失" : "行情可能延时"
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = self?.quotes.isEmpty == false ? "刷新失败 · 显示上次报价" : "行情加载失败，请刷新"
            }
            self?.loading = false
        }
    }
}
