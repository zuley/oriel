import Foundation
import Combine

extension Notification.Name {
    /// Posted after the language changes so AppKit views built once (window chrome,
    /// tab strips) can re-apply their labels without being recreated.
    static let orielLanguageDidChange = Notification.Name("orielLanguageDidChange")
}

/// Languages Oriel can display. `system` follows the user's first preferred
/// language, falling back to English for anything other than Chinese.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    var id: String { rawValue }

    /// Shown in the settings picker. Each explicit language is written in its own
    /// script; "follow system" is translated like any other UI string.
    var displayName: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }
}

/// Resolves user-facing strings against a small in-app table.
///
/// Chinese literals are the keys (and the Chinese value), so every existing
/// string keeps working and stays readable in source. Adding a language only
/// means adding a table and a branch in `effective`. Interpolated strings use
/// `%@` placeholders in both the key and the translation; pass Swift `String`s
/// so `String(format:)` never has to guess about integer widths.
enum L10n {
    static let languageKey = "app.language"

    /// The persisted setting, and the single source of truth. Everything else
    /// derives from it, so no cached copy can drift out of sync.
    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system
    }

    /// The language actually used for display, after resolving `.system`.
    static var effective: AppLanguage {
        switch stored {
        case .zhHans: return .zhHans
        case .en: return .en
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .zhHans : .en
        }
    }

    /// The single lookup used by both the UI and the model layer.
    static func tr(_ key: String, arguments: [CVarArg]) -> String {
        let template = effective == .en ? (english[key] ?? key) : key
        return arguments.isEmpty ? template : String(format: template, arguments: arguments)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        tr(key, arguments: args)
    }

    /// Chinese uses one form for every count; English needs a singular variant for
    /// "1 book / 3 books" style strings. Only the four count keys opt in.
    static func plural(_ count: Int, _ key: String) -> String {
        if effective == .en, count == 1, let one = singular[key] {
            return String(format: one, arguments: ["\(count)"])
        }
        return tr(key, "\(count)")
    }

    static let singular: [String: String] = [
        "%@ 个小窗": "%@ mini window",
        "%@ 本": "%@ book",
        "%@ 张": "%@ note",
        "%@ 节": "%@ section"
    ]

    /// English translations keyed by the Chinese source string (or `%@` template).
    /// Proper nouns and stock names are intentionally absent: they are data, not
    /// UI, and stay in their original form in every language.
    static let english: [String: String] = [
        // MARK: App menu, window actions
        "打开 Oriel": "Open Oriel",
        "新建小窗": "New Mini Window",
        "恢复小窗": "Restore Mini Windows",
        "退出 Oriel": "Quit Oriel",
        "Oriel · 半窗": "Oriel · Mini Windows",
        "设置…": "Settings…",
        "小窗": "Mini Window",
        "锁定穿透": "Lock Click-Through",
        "悬停展开": "Expand on Hover",
        "边缘唤醒": "Edge Reveal",
        "在所有桌面显示": "Show on All Desktops",
        "关闭小窗": "Close Mini Window",
        "结束并退出": "End and Quit",
        "终端中有任务正在运行": "Tasks Are Running in Terminals",
        "终端页签「%@」中有任务正在运行，%@结束它。": "Terminal tab '%@' has a running task. %@ end it.",
        "%@ 个终端页签中有任务正在运行（%@），%@结束它们。":
            "%@ terminal tabs have running tasks (%@). %@ end them.",
        "关闭会": "Closing will",
        "退出 Oriel 会": "Quitting Oriel will",
        "、": ", ",
        "%@：%@": "%@: %@",

        // MARK: Management — sidebar, header, workspace
        "工作台": "Workspace",
        "设置": "Settings",
        "通用、新小窗默认值与本地数据": "General, new mini window defaults and local data",
        "关闭主界面，小窗仍可用": "Mini windows stay available after closing this window",
        "%@ 个小窗": "%@ mini windows",
        "还没有小窗": "No Mini Windows Yet",
        "创建小窗后，在小窗中添加和使用内容。": "Create a mini window to add and use content in it.",
        "隐藏": "Hide",
        "显示": "Show",
        "重命名": "Rename",
        "关闭": "Close",
        "%@ · 已隐藏": "%@ · Hidden",
        "%@，已隐藏": "%@, hidden",
        "关闭%@？": "Close %@?",
        "将关闭此窗口的所有页签并结束其中的终端会话，其他小窗不受影响。":
            "This closes every tab in the window and ends its terminal sessions. Other mini windows are unaffected.",
        "重命名小窗": "Rename Mini Window",
        "窗口名称": "Window name",
        "最多 32 个字": "Up to 32 characters",
        "取消": "Cancel",
        "保存": "Save",
        "移除": "Remove",
        "保留": "Keep",
        "好": "OK",
        "完成": "Done",
        "知道了": "Got It",

        // MARK: Settings
        "通用": "General",
        "语言": "Language",
        "跟随系统": "Follow System",
        "切换后立即生效，无需重启。": "Changes apply immediately, no restart needed.",
        "启动时打开主界面": "Open management window at launch",
        "新小窗默认值": "New Mini Window Defaults",
        "当前为自定义值": "Currently using custom values",
        "竖版": "Portrait",
        "横版": "Landscape",
        "正方形": "Square",
        "自定义": "Custom",
        "280 × 360 · 窄长": "280 × 360 · Tall",
        "480 × 300 · 宽扁": "480 × 300 · Wide",
        "360 × 360 · 方正": "360 × 360 · Square",
        "自定义尺寸与透明度": "Custom Size and Opacity",
        "尺寸": "Size",
        "宽": "Width",
        "高": "Height",
        "默认宽度": "Default width",
        "默认高度": "Default height",
        "背景": "Background",
        "内容": "Content",
        "默认%@透明度": "Default %@ opacity",
        "目标小窗": "Target Window",
        "选择小窗": "Choose a Window",
        "应用默认设置的目标小窗": "Target window for applying defaults",
        "应用到所选小窗": "Apply to Selected Window",
        "已应用到%@": "Applied to %@",
        "恢复默认": "Restore Defaults",
        "选择预设用于新建小窗；自定义可单独调整尺寸与透明度。":
            "Presets apply to new mini windows; Custom lets you tune size and opacity.",
        "本地数据": "Local Data",
        "便签、书架、自选股和阅读进度保存在本机。":
            "Notes, books, watchlists and reading progress are stored on this Mac.",
        "导出数据…": "Export Data…",
        "打开数据目录": "Open Data Folder",
        "正在导出…": "Exporting…",
        "导出为独立副本，含废纸篓；暂不支持一键恢复。":
            "Exports a standalone copy, including the trash. One-click restore is not available yet.",
        "查看": "Reveal",
        "恢复默认设置？": "Restore Default Settings?",
        "恢复": "Restore",
        "已恢复默认；现有小窗保持原样": "Defaults restored; existing mini windows are unchanged",
        "不影响便签、书架、自选股和现有小窗。":
            "Notes, books, watchlists and existing mini windows are unaffected.",
        "导出到此处": "Export Here",
        "将创建新的 Oriel 数据副本文件夹": "A new Oriel data copy folder will be created",
        "数据副本已导出": "Data copy exported",
        "请选择 Oriel 数据目录之外的位置。": "Choose a location outside the Oriel data folder.",
        "数据目录包含符号链接，导出已停止，原文件未改动。":
            "The data folder contains symbolic links; export was stopped and no files were changed.",
        "导出临时目录无效，请重新导出。": "The temporary export folder is invalid. Please export again.",
        "说明.txt": "README.txt",

        // MARK: Mini window chrome
        "Oriel 迷你窗": "Oriel Mini Window",
        "新建页签": "New Tab",
        "收起为横条": "Collapse to Bar",
        "窗口设置": "Window Settings",
        "更多窗口操作": "More Window Actions",
        "收起到菜单栏": "Collapse to Menu Bar",
        "结束并关闭": "End and Close",
        "关闭边缘唤醒": "Turn Off Edge Reveal",
        "开启边缘唤醒": "Turn On Edge Reveal",
        "边缘唤醒已开启": "Edge Reveal On",
        "边缘唤醒已关闭": "Edge Reveal Off",
        "保持展开": "Keep Expanded",
        "透明度设置": "Opacity Settings",
        "解除锁定穿透": "Unlock Click-Through",
        "仅在当前桌面显示": "Show on This Desktop Only",
        "所有桌面": "All Desktops",
        "当前桌面": "This Desktop",
        "收起窗口操作": "Collapse Window Actions",
        "关闭当前页签": "Close Current Tab",
        "未命名": "Untitled",
        "取消穿透": "Disable Click-Through",
        "内容透明度": "Content Opacity",
        "背景透明度": "Background Opacity",
        "向左变透明，向右变清晰": "More transparent to the left, more opaque to the right",
        "全部页签": "All Tabs",
        "切换页签": "Switch Tabs",
        "首页": "Home",
        "终端": "Terminal",
        "小说": "Novel",
        "自选股": "Stocks",
        "便签": "Notes",
        "浏览器": "Browser",
        "无法启动 Shell。返回首页后可重试。": "Could not start the shell. Go back to Home and try again.",

        // MARK: Resource readout
        "没有单独统计的资源占用": "No separately measured resource use",
        "内存 %@，CPU %@": "Memory %@, CPU %@",
        "没有可单独统计的终端或网页进程；主进程的共用开销不计入单窗。":
            "No separately measurable terminal or web processes; shared main-process cost is not assigned to a single window.",
        "终端 %@": "Terminal %@",
        "网页 %@": "Web %@",
        "正文约 %@": "Text approx. %@",
        "\n含后台页签；CPU 按单核 100% 计，只统计终端与网页进程。":
            "\nIncludes background tabs; CPU is measured against one core at 100% and covers only terminal and web processes.",

        // MARK: Notes
        "存储目录被同名文件占用，请检查便签的存储位置。":
            "A file occupies the notes folder. Check where notes are stored.",
        "没有访问便签目录的权限，请检查文件权限。":
            "No permission to access the notes folder. Check file permissions.",
        "磁盘空间不足，请腾出空间后重试。": "Not enough disk space. Free some space and try again.",
        "这张便签已达到 1 MiB 上限，请拆成多张。":
            "This note reached the 1 MiB limit. Split it into several notes.",
        "便签文件损坏，原件已保留。": "A note file is damaged; the original was kept.",
        "这张便签来自较新版本，文件已保留。": "This note is from a newer version; the file was kept.",
        "一张便签需要较新版本，原件已保留。": "A note needs a newer version; the original was kept.",
        "已恢复一张便签的上一份副本，损坏原件已保留。":
            "Restored the previous copy of a note; the damaged original was kept.",
        "一张便签无法读取，原件已保留，其余便签仍可使用。":
            "A note could not be read; the original was kept and other notes still work.",
        "回收站": "Trash",
        "便签菜单": "Notes Menu",
        "返回便签": "Back to Notes",
        "便签列表": "Notes List",
        "%@ 张": "%@ notes",
        "新建便签": "New Note",
        "便签操作": "Note Actions",
        "便签恢复提示": "Note Recovery Notice",
        "关闭便签列表": "Close Notes List",
        "清除搜索": "Clear Search",
        "有恢复提示 · 查看": "Recovery notice · View",
        "恢复：": "Recovered:",
        "取消置顶": "Unpin",
        "置顶": "Pin",
        "移到回收站": "Move to Trash",
        "回收站为空": "Trash Is Empty",
        "还没有便签": "No Notes Yet",
        "没有匹配的便签": "No Matching Notes",
        "第一行会作为标题，随手记下就好": "The first line becomes the title. Just start writing.",
        "已移到回收站": "Moved to Trash",
        "恢复后可以继续编辑": "You can keep editing after restoring",
        "恢复便签": "Restore Note",
        "空白便签": "Blank Note",
        "重试保存": "Retry Saving",
        "查看错误": "View Error",
        "未保存": "Unsaved",
        "操作未完成": "Action Incomplete",
        "列表与搜索": "List and Search",
        "返回正文": "Back to Text",
        "导出 TXT": "Export TXT",
        "复制全文": "Copy All",
        "全部便签": "All Notes",
        "查看恢复提示": "View Recovery Notice",
        "切换便签": "Switch Notes",
        "暂无便签": "No Notes",
        "打开存储目录": "Open Storage Folder",
        "尚未保存": "Not Saved Yet",
        "便签正文": "Note Text",
        "开始记录…": "Start writing…",
        "搜索便签": "Search Notes",
        "便签尚未保存": "Note Not Saved",
        "文字仍在小窗中。可以保留窗口后复制或导出，也可以修复磁盘问题后重试。\n\n":
            "The text is still in the mini window. Keep the window to copy or export it, or fix the disk problem and retry.\n\n",
        "保留窗口": "Keep Window",
        "导出失败：": "Export failed:",

        // MARK: Novel
        "重新导入": "Re-import",
        "重试": "Retry",
        "导入": "Import",
        "选择导入时的原文件以修复本书": "Choose the original file used at import to repair this book",
        "选择同版书籍的原始 TXT 文件": "Choose the original TXT file for this edition",
        "选择 TXT 或 EPUB 小说": "Choose a TXT or EPUB novel",
        "正在导入": "Importing",
        "已入架 %@ 本，%@ 份失败。%@ · %@": "Added %@ to shelf, %@ failed. %@ · %@",
        "已加入书架 · %@ 本": "Added %@ to shelf",
        "正在导入 %@ / %@": "Importing %@ / %@",
        "正在打开": "Opening",
        "正在移除": "Removing",
        "移除《%@》？": "Remove %@?",
        "关闭提示": "Dismiss",
        "已加书签": "Bookmark Added",
        "书架": "Shelf",
        "%@ 本": "%@ books",
        "导入 TXT 或 EPUB": "Import TXT or EPUB",
        "书架还是空的": "Your Shelf Is Empty",
        "把 TXT 或 EPUB 拖进来，或手动导入": "Drop a TXT or EPUB here, or import manually",
        "导入本地书": "Import a Local Book",
        "搜书名或作者": "Search title or author",
        "没有匹配的书": "No matching books",
        "%@ 节": "%@ sections",
        "读到 %@ / %@": "Read to %@ / %@",
        "从书架移除": "Remove from Shelf",
        "选书": "Choose a Book",
        "返回书架": "Back to Shelf",
        "章节目录": "Contents",
        "上一章": "Previous Chapter",
        "下一章": "Next Chapter",
        "查找正文": "Find in Text",
        "添加书签": "Add Bookmark",
        "查看书签": "View Bookmarks",
        "字号": "Font Size",
        "简体阅读": "Simplified Chinese",
        "阅读设置": "Reading Settings",
        "书签": "Bookmarks",
        "目录": "Contents",
        "添加当前位置": "Add Current Position",
        "收藏当前位置": "Bookmark Current Position",
        "移除书签": "Remove Bookmark",
        "查找章节": "Find Chapter",
        "没有匹配的章节": "No matching chapters",
        "正在查找…": "Searching…",
        "没有匹配": "No matches",
        "搜索结果": "Search Results",
        "前 80 处 · 可继续输入": "First 80 matches · keep typing",
        "没有找到匹配的文字": "No matching text found",

        // ReadingError (defined in the OrielReading package, mapped here so the
        // package stays independent of the app's language setting).
        "这本书没有可读正文": "This book has no readable text",
        "文字编码无法识别，请另存为 UTF-8 后导入": "Text encoding is unrecognised; save as UTF-8 and import again",
        "书籍太大，请选择 32 MB 以内的文字书": "The book is too large; choose a text book under 32 MB",
        "请选择 TXT 或无 DRM 的文字 EPUB": "Choose a TXT or a DRM-free text EPUB",
        "书籍结构不完整，请重新导入或选择原始文件修复":
            "The book is incomplete; re-import it or choose the original file to repair it",
        "请选择同版书籍的原始文件": "Choose the original file for this edition",

        // MARK: Browser
        "新页签": "New Tab",
        "必应": "Bing",
        "百度": "Baidu",
        "维基百科": "Wikipedia",
        "常用网站": "Frequent Sites",
        "收藏夹": "Bookmarks",
        "无法打开网页": "Unable to Open Page",
        #"<a class="retry" href="%@"><span>重试</span></a>"#:
            #"<a class="retry" href="%@"><span>Retry</span></a>"#,
        #"<h1>无法打开网页</h1><p>%@</p>%@"#: #"<h1>Unable to Open Page</h1><p>%@</p>%@"#,
        "每有会意，\n便欣然忘食。": "Lost in a good read,\nmeals are forgotten.",
        "后退": "Back",
        "前进": "Forward",
        "刷新": "Reload",
        "更多": "More",
        "搜索或输入网址": "Search or enter address",
        "地址栏": "Address bar",
        "安全连接": "Secure connection",
        "停止": "Stop",
        "无法收藏": "Can't Bookmark",
        "收藏夹最多 %@ 项，请先取消一些收藏。": "Bookmarks are limited to %@ items. Remove some first.",
        "取消收藏此页": "Remove Bookmark",
        "收藏此页": "Bookmark This Page",
        "暂无收藏": "No Bookmarks",
        "WebKit 默认": "WebKit Default",
        "自定义…": "Custom…",
        "放大": "Zoom In",
        "缩小": "Zoom Out",
        "实际大小（%@）": "Actual Size (%@)",
        "在默认浏览器中打开": "Open in Default Browser",
        "拷贝链接": "Copy Link",
        "清除浏览数据…": "Clear Browsing Data…",
        "自定义 User Agent": "Custom User Agent",
        "单行文本，最多 %@ 个字符。保存后当前页面会重新加载。":
            "Single line, up to %@ characters. The current page reloads after saving.",
        "清除浏览数据？": "Clear Browsing Data?",
        "将清除所有小窗中浏览器的登录状态、Cookie 和缓存，收藏夹不受影响。":
            "This clears sign-ins, cookies and caches for browsers in every mini window. Bookmarks are kept.",
        "清除": "Clear",
        "网页反复崩溃，已停止自动重新加载。": "The page kept crashing; automatic reload was stopped.",
        "网页": "Web",
        "下载失败": "Download Failed",
        "打开": "Open",

        // MARK: Stocks
        "分时": "Intraday",
        "日 K": "Daily K",
        "分时走势": "Intraday Trend",
        "日 K 线": "Daily Candles",
        "行情可能延时": "Quotes may be delayed",
        "部分行情缺失": "Some quotes are missing",
        "刷新失败 · 显示上次报价": "Refresh failed · showing last quote",
        "行情加载失败，请刷新": "Failed to load quotes, please refresh",
        "最新价": "Last",
        "涨跌额": "Change",
        "涨跌幅": "Change %",
        "代码 / 名称 / 拼音": "Code / Name / Pinyin",
        "搜索股票": "Search stocks",
        "刷新行情": "Refresh Quotes",
        "重新搜索": "Search Again",
        "我的自选": "My Watchlist",
        "管理自选股": "Manage Watchlist",
        "搜索股票以加入自选": "Search stocks to add to your watchlist",
        "腾讯财经": "Tencent Finance",
        "更新中…": "Updating…",
        "添加": "Add",
        "正在搜索…": "Searching…",
        "没有匹配的股票": "No matching stocks",
        "搜索失败，点刷新重试": "Search failed, tap refresh to retry",
    ]

    /// Multi-line export readme. Kept out of the literal table because a long
    /// multiline key would be easy to break with a stray whitespace change.
    static func exportReadme() -> String {
        effective == .en ? exportReadmeEN : exportReadmeZH
    }

    private static let exportReadmeZH = """
        Oriel 本地数据副本 · 格式 1
        Notes：便签、废纸篓及恢复副本。
        Books：书架元数据与章节，可从 chapters.json 读取正文。
        preferences.plist：默认窗口设置、界面语言、自选股、阅读位置与书签。
        各模块依次取有效快照，不保证同一瞬间状态。
        本版不支持一键恢复；请妥善保管此文件夹，不要在应用运行时直接覆盖数据。
        本导出不包含终端会话、临时页签、在线账号或系统设置。
        """

    private static let exportReadmeEN = """
        Oriel local data copy · format 1
        Notes: notes, trash and recovery copies.
        Books: shelf metadata and chapters; chapter text is in chapters.json.
        preferences.plist: default window settings, interface language, watchlist, reading positions and bookmarks.
        Each module takes a valid snapshot in turn, not one single instant.
        This version has no one-click restore. Keep this folder safe and do not overwrite
        the data while the app is running.
        This export excludes terminal sessions, temporary tabs, online accounts and system settings.
        """
}

// MARK: - Observable setting

/// Broadcasts language changes so every open SwiftUI view redraws immediately.
/// It holds no language state of its own: `language` reads `L10n.stored`, so the
/// picker and every `L(...)` call always agree. Views hold this singleton with
/// `@ObservedObject`; model-layer code uses `L10n.tr` / `L(...)` directly.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    var language: AppLanguage { L10n.stored }

    private var localeObserver: NSObjectProtocol?

    private init() {
        // "Follow system" has no stored value that changes, so a macOS language
        // change needs an explicit nudge to redraw and refresh AppKit labels.
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemLocaleDidChange() }
        }
    }

    /// Write the setting before notifying so a redraw always reads the new value.
    func setLanguage(_ newValue: AppLanguage) {
        UserDefaults.standard.set(newValue.rawValue, forKey: L10n.languageKey)
        objectWillChange.send()
        NotificationCenter.default.post(name: .orielLanguageDidChange, object: nil)
    }

    private func systemLocaleDidChange() {
        guard language == .system else { return }
        objectWillChange.send()
        NotificationCenter.default.post(name: .orielLanguageDidChange, object: nil)
    }

    func tr(_ key: String, _ args: CVarArg...) -> String {
        L10n.tr(key, arguments: args)
    }
}

/// Shorthand for model-layer and AppKit code that has no SwiftUI view.
@inline(__always)
func L(_ key: String, _ args: CVarArg...) -> String {
    L10n.tr(key, arguments: args)
}
