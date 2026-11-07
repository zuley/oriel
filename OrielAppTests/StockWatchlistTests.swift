import XCTest

private actor QuoteSource {
    var requests: [[String]] = []

    func load(_ symbols: [StockSymbol]) -> [String: StockQuote] {
        requests.append(symbols.map(\.id))
        let quote = StockQuote(providerCode: "000001", price: "10", change: "1", percent: "1", asOf: "20261106150000")
        return [StockSymbol.index.id: quote]
    }
}

@MainActor
final class StockWatchlistTests: XCTestCase {
    func testRapidRevealReusesSuccessfulQuoteWhileExplicitRefreshAndNewSymbolsFetch() async throws {
        let source = QuoteSource()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = StockWatchlist(defaults: defaults) { symbols in await source.load(symbols) }
        defer { list.setVisible(false) }
        list.setVisible(true)
        try await settled(list)
        for _ in 0..<12 { list.setVisible(false); list.setVisible(true) }
        try await settled(list)
        let afterReveals = await source.requests
        XCTAssertEqual(afterReveals.count, 1)

        list.refresh()
        try await settled(list)
        list.toggle(StockSymbol(id: "usAAPL", name: "Apple"))
        try await settled(list)
        let afterChanges = await source.requests
        XCTAssertEqual(afterChanges.count, 3)
        XCTAssertTrue(try XCTUnwrap(afterChanges.last).contains("usAAPL"))
    }

    private func settled(_ list: StockWatchlist) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while list.loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(list.loading)
    }
}
