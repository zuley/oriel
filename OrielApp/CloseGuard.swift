import Foundation

/// Closing a tab, a mini window or the app ends its terminals. Ask first only while a
/// command is running there; an idle shell prompt closes without a question (Spec 007).
enum CloseGuard {
    struct Terminal: Equatable {
        let title: String
        let busy: Bool
    }

    /// The verb differs between closing one window and quitting the whole app, so
    /// it is passed in rather than patched into the sentence with a string replace.
    enum Intent {
        case closing
        case quitting

        var action: String {
            switch self {
            case .closing: L("关闭会")
            case .quitting: L("退出 Oriel 会")
            }
        }
    }

    static func busyTitles(_ terminals: [Terminal]) -> [String] {
        terminals.filter(\.busy).map(\.title)
    }

    /// nil when nothing is running.
    static func message(busy titles: [String], intent: Intent = .closing) -> String? {
        switch titles.count {
        case 0: return nil
        case 1:
            return L("终端页签「%@」中有任务正在运行，%@结束它。", titles[0], intent.action)
        default:
            return L("%@ 个终端页签中有任务正在运行（%@），%@结束它们。",
                     "\(titles.count)", titles.joined(separator: L("、")), intent.action)
        }
    }
}
