import Foundation

/// Every kind of content a window tab can show. Adding one means a case here, one
/// `TabPage` class, and one line in `PageFactory`; the home screen, tab strip and
/// shortcuts all read this list.
enum PageKind: CaseIterable, Hashable {
    case terminal, novel, stocks, notes, browser

    var title: String {
        switch self {
        case .terminal: return "终端"
        case .novel: return "小说"
        case .stocks: return "自选股"
        case .notes: return "便签"
        case .browser: return "浏览器"
        }
    }

    /// SF Symbol used in tabs and home tiles. Stocks keeps its own drawn symbol.
    var symbolName: String? {
        switch self {
        case .terminal: return "terminal"
        case .novel: return "book"
        case .stocks: return nil
        case .notes: return "note.text"
        case .browser: return "globe"
        }
    }
}
