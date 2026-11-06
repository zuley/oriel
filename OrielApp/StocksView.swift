import SwiftUI

struct StocksView: View {
    @ObservedObject var list: StockWatchlist
    var onStockHover: (StockSymbol, Bool) -> Void = { _, _ in }
    @State private var query = ""
    @State private var matches: [StockSymbol] = []
    @State private var searchStatus = ""
    @State private var editing = false
    @State private var sort: Column?
    @State private var ascending = false

    private enum Column: String, CaseIterable {
        case price = "最新价", change = "涨跌额", percent = "涨跌幅"

        func number(_ quote: StockQuote?) -> Double? {
            guard let quote else { return nil }
            switch self {
            case .price: return Double(quote.price)
            case .change: return Double(quote.change)
            case .percent: return Double(quote.percent)
            }
        }
    }

    private let up = Color(red: 0.86, green: 0.18, blue: 0.23)
    private let down = Color(red: 0.03, green: 0.55, blue: 0.28)
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sorted: [StockSymbol] {
        guard let sort else { return list.symbols }
        return list.symbols.sorted { lhs, rhs in
            guard let l = sort.number(list.quotes[lhs.id]) else { return false }
            guard let r = sort.number(list.quotes[rhs.id]) else { return true }
            return ascending ? l < r : l > r
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("代码 / 名称 / 拼音", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("搜索股票")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 7).frame(height: 25).background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                Button { list.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 25)
                        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
                .disabled(list.loading).help("刷新行情").accessibilityLabel("刷新行情")
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            if term.isEmpty {
                GeometryReader { area in
                    ScrollView(area.size.height < 120 ? [.horizontal, .vertical] : .horizontal, showsIndicators: false) {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                Button { editing.toggle() } label: {
                                    HStack(spacing: 3) {
                                        Text(editing ? "完成" : "我的自选")
                                        Image(systemName: editing ? "checkmark" : "chevron.down").font(.system(size: 8))
                                    }
                                }.help("管理自选股").frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(Column.allCases, id: \.self) { col in
                                    Button {
                                        if sort == col { ascending.toggle() } else { sort = col; ascending = false }
                                    } label: {
                                        HStack(spacing: 2) {
                                            Text(col.rawValue)
                                            Image(systemName: sort == col ? (ascending ? "chevron.up" : "chevron.down") : "arrow.up.arrow.down")
                                                .font(.system(size: 7))
                                        }
                                    }
                                    .foregroundStyle(sort == col ? Color.primary : Color.secondary)
                                    .frame(width: col == .percent ? 58 : 52, alignment: .trailing)
                                }
                            }
                            .font(.system(size: 10)).padding(.horizontal, 7).frame(height: 26)
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(sorted) { symbol in
                                        quoteRow(symbol)
                                            .background(StockRowHoverArea { onStockHover(symbol, $0) })
                                            .onDisappear { onStockHover(symbol, false) }
                                    }
                                    if sorted.isEmpty { Text("搜索股票以加入自选").foregroundStyle(.secondary).padding(.vertical) }
                                }
                            }
                            HStack {
                                Text("腾讯财经").fontWeight(.medium)
                                Spacer()
                                Text(list.loading ? "更新中…" : list.status)
                            }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 7).frame(height: 20)
                            Divider()
                            quoteRow(.index, index: true).help(list.quotes[StockSymbol.index.id]?.asOf ?? "上证指数").background(Color.gray.opacity(0.06))
                        }
                        .frame(width: max(area.size.width, 246), height: max(area.size.height, 120))
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { symbol in
                            let added = list.symbols.contains(where: { $0.id == symbol.id })
                            Button {
                                list.toggle(symbol)
                            } label: {
                                HStack(spacing: 5) {
                                    badge(symbol)
                                    Text(symbol.name).foregroundStyle(Color.primary).lineLimit(1)
                                    Text(symbol.code).foregroundStyle(.secondary).font(.caption2)
                                    Spacer()
                                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(Color.accentColor)
                                }.padding(.horizontal, 7).frame(height: 28).contentShape(Rectangle())
                            }
                            .accessibilityLabel((added ? "移除" : "添加") + symbol.name)
                            .background(StockRowHoverArea { onStockHover(symbol, $0) })
                            .onDisappear { onStockHover(symbol, false) }
                        }
                        if matches.isEmpty { Text(searchStatus).foregroundStyle(.secondary).padding(.top, 10) }
                    }
                }
            }
        }
        .font(.system(size: 12)).buttonStyle(.plain)
        .task(id: term) {
            let input = term
            matches = []
            guard !input.isEmpty else { return }
            searchStatus = "正在搜索…"
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await TencentMarket.search(input)
                try Task.checkCancellation()
                matches = result
                searchStatus = "没有匹配的股票"
            } catch {
                if !Task.isCancelled { searchStatus = "搜索失败，请重新输入" }
            }
        }
    }

    private func badge(_ symbol: StockSymbol) -> some View {
        Text(symbol.market).font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white).padding(.horizontal, 2).padding(.vertical, 1)
            .background(symbol.market == "HK" ? Color.orange : symbol.market == "US" ? Color.blue : up,
                        in: RoundedRectangle(cornerRadius: 2))
    }

    private func quoteRow(_ symbol: StockSymbol, index: Bool = false) -> some View {
        let quote = list.quotes[symbol.id]
        let move = Double(quote?.change ?? "") ?? 0
        let ink = move > 0 ? up : (move < 0 ? down : .primary)
        return HStack(spacing: 2) {
            HStack(spacing: 3) {
                if !index {
                    if editing {
                        Button { list.toggle(symbol) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(up) }
                            .accessibilityLabel("移除" + symbol.name)
                    } else { badge(symbol) }
                }
                Text(symbol.name).foregroundStyle(Color.primary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(quote?.price ?? "—").frame(width: 52, alignment: .trailing)
            Text(signed(quote?.change)).frame(width: 52, alignment: .trailing)
            Text(quote.map { signed($0.percent) + "%" } ?? "—").frame(width: 58, alignment: .trailing)
        }
        .monospacedDigit().foregroundStyle(ink)
        .padding(.horizontal, 7).frame(height: index ? 24 : 28)
        .accessibilityHint(symbol.code + (quote.map { " · " + $0.asOf } ?? ""))
    }

    private func signed(_ value: String?) -> String {
        guard let value, let number = Double(value) else { return "—" }
        return number > 0 && !value.hasPrefix("+") ? "+" + value : value
    }
}

/// Track the whole row even when another app owns keyboard focus.
private struct StockRowHoverArea: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: view, userInfo: nil))
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
    }
}
