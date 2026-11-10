import Foundation

/// Closing a tab, a mini window or the app ends its terminals. Ask first only while a
/// command is running there; an idle shell prompt closes without a question (Spec 007).
enum CloseGuard {
    struct Terminal: Equatable {
        let title: String
        let busy: Bool
    }

    static func busyTitles(_ terminals: [Terminal]) -> [String] {
        terminals.filter(\.busy).map(\.title)
    }

    /// nil when nothing is running.
    static func message(busy titles: [String]) -> String? {
        switch titles.count {
        case 0: return nil
        case 1: return "终端页签「\(titles[0])」中有任务正在运行，关闭会结束它。"
        default:
            return "\(titles.count) 个终端页签中有任务正在运行（\(titles.joined(separator: "、"))），关闭会结束它们。"
        }
    }
}
