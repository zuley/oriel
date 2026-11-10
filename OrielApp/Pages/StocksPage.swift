import AppKit

/// The watchlist. Quotes refresh only while this page is on screen in a visible window;
/// hovering a row shows its chart in a child panel.
@MainActor
final class StocksPage: TabPage {
    let kind = PageKind.stocks
    let view: NSView
    var title: String { "自选股" }
    private weak var host: PageHost?
    private let watchlist: StockWatchlist
    private let chart = StockChartHover()
    /// Each page reports its own visibility; the watchlist polls while any is visible.
    private let visibilityOwner = UUID().uuidString

    init(host: PageHost, watchlist: StockWatchlist) {
        self.host = host
        self.watchlist = watchlist
        let chart = self.chart
        weak var page: StocksPage?
        view = pageHostingView(StocksView(list: watchlist) { [weak host] symbol, inside in
            guard let host, let page, host.isPresenting(page) else { return }
            if !inside { chart.exit(symbol.id) }
            else if host.canManageTabs && !host.isGeometryInteracting {
                chart.enter(symbol, quote: watchlist.quotes[symbol.id], parent: host.hostWindow)
            }
        })
        page = self
    }

    func didActivate() { windowVisibilityChanged(host?.hostWindow.isVisible == true) }

    func willDeactivate() {
        chart.dismiss()
        watchlist.setVisible(false, owner: visibilityOwner)
    }

    func windowVisibilityChanged(_ visible: Bool) {
        watchlist.setVisible(visible, owner: visibilityOwner)
    }

    func windowWillConceal() { chart.dismiss() }
    func dismissPopovers() { chart.dismiss() }

    func hasEditingFocus(_ responder: NSResponder) -> Bool { responder is NSTextInputClient }
    var keepsWindowVisible: Bool { chart.containsPointer }

    func dispose() {
        chart.dismiss()
        watchlist.setVisible(false, owner: visibilityOwner)
        view.removeFromSuperview()
    }
}
