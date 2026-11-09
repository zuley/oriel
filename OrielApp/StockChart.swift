import SwiftUI

enum StockChartPeriod: String, CaseIterable { case intraday = "分时", daily = "日 K" }

@MainActor
final class StockChartHover: ObservableObject {
    enum Series { case intraday(IntradaySession), daily([DailyCandle]) }

    @Published private(set) var period = StockChartPeriod.intraday
    @Published private(set) var series: Series?
    @Published private(set) var failed = false
    private var symbol: StockSymbol?
    private var quote: StockQuote?
    private var task: Task<Void, Never>?
    private var insideRow = false
    private var leaveTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var cache: [String: (expires: Date, series: Series)] = [:]

    var containsPointer: Bool { panel?.frame.contains(NSEvent.mouseLocation) == true }

    func enter(_ symbol: StockSymbol, quote: StockQuote?, parent: NSPanel) {
        if containsPointer { return }
        leaveTask?.cancel()
        if self.symbol?.id == symbol.id { insideRow = true; return }
        dismiss()
        insideRow = true
        self.symbol = symbol
        self.quote = quote
        period = .intraday
        task = Task { [weak self, weak parent] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self, let parent, parent.isVisible, !parent.ignoresMouseEvents else { return }
            let popup = makePanel(parent: parent)
            popup.contentView = NSHostingView(rootView: StockChartView(symbol: symbol, chart: self))
            panel = popup
            parent.addChildWindow(popup, ordered: .above)
            popup.orderFrontRegardless()
            load(.intraday)
        }
    }

    func load(_ period: StockChartPeriod) {
        guard let symbol else { return }
        task?.cancel()
        self.period = period
        failed = false
        cache = cache.filter { $0.value.expires > Date() }
        let key = symbol.id + ":" + period.rawValue
        let cached = cache[key]
        series = cached?.series
        if cached != nil && period == .daily { return }
        task = Task { [weak self, quote] in
            var delay = cached?.expires.timeIntervalSinceNow ?? 0
            while !Task.isCancelled {
                do {
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    let result: Series
                    switch period {
                    case .intraday: result = .intraday(try await TencentMarket.intraday(for: symbol, quote: quote))
                    case .daily: result = .daily(try await TencentMarket.dailyCandles(for: symbol, quote: quote))
                    }
                    try Task.checkCancellation()
                    guard let self else { return }
                    delay = period == .intraday ? 30 : 300
                    self.cache[key] = (Date().addingTimeInterval(delay), result)
                    self.series = result
                    self.failed = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.series = nil
                    self?.failed = true
                    delay = 30
                }
                if period == .daily { return }
            }
        }
    }

    func exit(_ id: String) {
        guard symbol?.id == id else { return }
        insideRow = false
        guard panel != nil else { dismiss(); return }
        scheduleDismiss()
    }

    func popupHover(_ inside: Bool) {
        if inside {
            insideRow = false
            leaveTask?.cancel()
        } else if !insideRow {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            if self?.containsPointer == false { self?.dismiss() }
        }
    }

    func dismiss() {
        guard symbol != nil else { return }
        leaveTask?.cancel()
        task?.cancel()
        insideRow = false
        symbol = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            self.panel = nil
        }
        series = nil
        failed = false
    }

    private func makePanel(parent: NSPanel) -> NSPanel {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? parent.screen
        let visible = screen?.visibleFrame ?? parent.frame
        let size = CGSize(width: min(244, visible.width), height: min(126, visible.height))
        let right = pointer.x + 6
        let x = right + size.width <= visible.maxX ? right : pointer.x - 6 - size.width
        let y = pointer.y + 10 - size.height
        let frame = NSRect(x: min(max(x, visible.minX), visible.maxX - size.width),
                           y: min(max(y, visible.minY), visible.maxY - size.height),
                           width: size.width, height: size.height)
        let popup = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.level = parent.level
        popup.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = false
        popup.becomesKeyOnlyIfNeeded = true
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.appearance = parent.effectiveAppearance
        return popup
    }
}

struct StockChartView: View {
    let symbol: StockSymbol
    @ObservedObject var chart: StockChartHover

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                ForEach(StockChartPeriod.allCases, id: \.self) { period in
                    Button { chart.load(period) } label: {
                        Text(period.rawValue).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(chart.period == period ? Color(nsColor: OrielPalette.selection) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chart.period == period ? .isSelected : [])
                }
            }
            ZStack {
                switch chart.series {
                case .daily(let candles): daily(candles)
                case .intraday(let session): intraday(session)
                case nil:
                    if chart.failed {
                        Button { chart.load(chart.period) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).accessibilityLabel("重试")
                    } else { ProgressView().controlSize(.small) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(7)
        .foregroundStyle(OrielPalette.text)
        .tint(OrielPalette.tint)
        .background(Color(nsColor: OrielPalette.surface), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: OrielPalette.divider)) }
        .onHover { chart.popupHover($0) }
    }

    private func intraday(_ session: IntradaySession) -> some View {
        let points = session.points
        let low = points.map(\.price).min() ?? 0
        let high = points.map(\.price).max() ?? 0
        // Compress the scheduled lunch break on mainland and Hong Kong exchanges.
        let hk = symbol.market == "HK"
        let lunchStart = hk ? 720 : 690
        func tradingMinute(_ minute: Int) -> Int {
            guard symbol.market != "US" else { return minute }
            return minute - max(0, min(780, minute) - lunchStart)
        }
        let start = tradingMinute(min(570, points.first?.minute ?? 570))
        let end = tradingMinute(max(hk || symbol.market == "US" ? 960 : 900, points.last?.minute ?? 0))
        return priceChart(low: low, high: high, reference: session.previousClose) { context, size, y in
            var line = Path()
            var last = CGPoint.zero
            for (i, p) in points.enumerated() {
                let x = CGFloat(tradingMinute(p.minute) - start) / CGFloat(max(1, end - start))
                last = CGPoint(x: 1 + x * (size.width - 2), y: y(p.price))
                if i == 0 { line.move(to: last) } else { line.addLine(to: last) }
            }
            context.stroke(line, with: .color(OrielPalette.tint), lineWidth: 1.2)
            if points.count == 1 { context.fill(Path(ellipseIn: CGRect(x: last.x-1, y: last.y-1, width: 2, height: 2)), with: .color(OrielPalette.tint)) }
        }.accessibilityLabel(symbol.name + "分时走势")
    }

    private func daily(_ candles: [DailyCandle]) -> some View {
        let top = candles.map(\.high).max() ?? 0
        let bottom = candles.map(\.low).min() ?? 0
        return priceChart(low: bottom, high: top, reference: nil) { context, size, y in
            guard !candles.isEmpty else { return }
            let step = size.width / CGFloat(candles.count)
            let width = min(8, max(1, step * 0.68))
            for (i, bar) in candles.enumerated() {
                let x = (CGFloat(i) + 0.5) * step
                let color: Color = bar.close == bar.open ? .gray : (bar.close > bar.open ? .red : .green)
                var wick = Path()
                wick.move(to: .init(x: x, y: y(bar.high)))
                wick.addLine(to: .init(x: x, y: y(bar.low)))
                context.stroke(wick, with: .color(color), lineWidth: 1)
                let body = CGRect(x: x - width / 2, y: min(y(bar.open), y(bar.close)), width: width,
                                  height: max(1, abs(y(bar.open) - y(bar.close))))
                context.fill(Path(body), with: .color(color))
            }
        }
        .accessibilityLabel(symbol.name + "日 K 线")
    }

    private func priceChart(low: Double, high: Double, reference: Double?,
                            draw: @escaping (GraphicsContext, CGSize, (Double) -> CGFloat) -> Void) -> some View {
        var bottom = low
        var top = high
        if let reference {
            let radius = max(abs(high - reference), abs(low - reference))
            bottom = max(0, reference - radius)
            top = reference + radius
        }
        let span = top - bottom
        let ticks = span > 0 ? (0...4).map { top - span * Double($0) / 4 } : [top]
        let digits = max(symbol.market == "HK" ? 3 : 2, span > 0 ? min(8, Int(ceil(-log10(span / 4)))) : 0)
        let format = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(digits))
        return Canvas { context, size in
            let labels = ticks.map { price in
                let label = price.formatted(format)
                var color = Color.secondary
                if let reference, label != reference.formatted(format) {
                    color = price > reference ? .red : .green
                }
                return context.resolve(Text(label).font(.system(size: 9)).monospacedDigit().foregroundStyle(color))
            }
            let labelSizes = labels.map { $0.measure(in: size) }
            let inset = ceil((labelSizes.map(\.height).max() ?? 0) / 2)
            let width = max(0, size.width - (labelSizes.map(\.width).max() ?? 0) - 5)
            func y(_ price: Double) -> CGFloat {
                guard span > 0 else { return size.height / 2 }
                return inset + (top - price) / span * max(0, size.height - 2 * inset)
            }
            for (tick, label) in zip(ticks, labels) {
                let height = y(tick)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: height))
                grid.addLine(to: CGPoint(x: width, y: height))
                context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                context.draw(label, at: CGPoint(x: size.width, y: height), anchor: .trailing)
            }
            draw(context, CGSize(width: width, height: size.height), y)
        }
    }
}
