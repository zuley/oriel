import Foundation
import XCTest

private struct FormatCall {
    let key: String
    let argumentCount: Int
}

/// Finds `L("...", ...)`, `L10n.tr(...)` and `l10n.tr(...)` calls by matching
/// parentheses. String contents (including `\(...)` interpolation) are ignored,
/// so a `)` inside an argument does not end the call early. Raw-string calls
/// (`L(#"...")`) are skipped — the two HTML templates are covered separately.
/// The format argument count is the number of top-level commas after the key.
private func formatCalls(in source: String) -> [FormatCall] {
    let chars = Array(source)
    var calls: [FormatCall] = []
    var index = 0
    while index < chars.count {
        guard chars[index] == "(" else { index += 1; continue }
        let prefix = String(chars[max(0, index - 10)..<index])
        let boundaryOK = index < 2 || !(chars[index - 2].isLetter || chars[index - 2].isNumber || chars[index - 2] == "_")
        let isCall = prefix.hasSuffix("L10n.tr") || prefix.hasSuffix(".tr")
            || (prefix.hasSuffix("L") && boundaryOK)
        guard isCall else { index += 1; continue }

        var first = index + 1
        while first < chars.count && chars[first].isWhitespace { first += 1 }
        guard first < chars.count, chars[first] != "#" else { index += 1; continue }

        var depth = 0
        var inString = false
        var escaped = false
        var key = ""
        var keyCaptured = false
        var commas = 0
        var closed = false
        var cursor = index + 1
        while cursor < chars.count {
            let ch = chars[cursor]
            if inString {
                if escaped { escaped = false; if !keyCaptured { key.append(ch) } }
                else if ch == "\\" { escaped = true; if !keyCaptured { key.append(ch) } }
                else if ch == "\"" { inString = false; keyCaptured = true }
                else if !keyCaptured { key.append(ch) }
                cursor += 1
                continue
            }
            if ch == "\"" { inString = true; cursor += 1; continue }
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                if depth == 0 { closed = true; break }
                depth -= 1
            } else if ch == "," && depth == 0 && keyCaptured { commas += 1 }
            cursor += 1
        }
        if closed && keyCaptured && !key.isEmpty {
            calls.append(FormatCall(key: key, argumentCount: commas))
        }
        index = max(index + 1, cursor + 1)
    }
    return calls
}

/// The language table is the single source of UI copy: Chinese literals are keys,
/// English is the translation. These tests lock down the resolver, the change
/// notification and the format templates so a missing translation or a broken
/// `%@` template fails before it reaches the UI.
final class LocalizationTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: L10n.languageKey)
    }

    override func tearDown() {
        if let savedLanguage { UserDefaults.standard.set(savedLanguage, forKey: L10n.languageKey) }
        else { UserDefaults.standard.removeObject(forKey: L10n.languageKey) }
    }

    private func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: L10n.languageKey)
    }

    func testChineseIsTheSourceLanguage() {
        set(.zhHans)
        XCTAssertEqual(L10n.effective, .zhHans)
        XCTAssertEqual(L10n.tr("新建小窗"), "新建小窗")
        XCTAssertEqual(L10n.tr("设置"), "设置")
    }

    func testEnglishSwitchRewritesTheSameKey() {
        set(.en)
        XCTAssertEqual(L10n.effective, .en)
        XCTAssertEqual(L10n.tr("新建小窗"), "New Mini Window")
        XCTAssertEqual(L10n.tr("设置"), "Settings")
    }

    func testUnknownKeyFallsBackToTheKeyInBothLanguages() {
        set(.zhHans)
        XCTAssertEqual(L10n.tr("没有这条文案"), "没有这条文案")
        set(.en)
        XCTAssertEqual(L10n.tr("没有这条文案"), "没有这条文案")
    }

    func testFormatArgumentsAreSubstitutedInBothLanguages() {
        set(.zhHans)
        XCTAssertEqual(L10n.tr("%@ 个小窗", "3"), "3 个小窗")
        set(.en)
        XCTAssertEqual(L10n.tr("%@ 个小窗", "3"), "3 mini windows")
        XCTAssertEqual(L10n.tr("已入架 %@ 本，%@ 份失败。%@ · %@", "2", "1", "a.txt", "格式错误"),
                       "Added 2 to shelf, 1 failed. a.txt · 格式错误")
    }

    func testEnglishUsesSingularForOneItem() {
        set(.en)
        XCTAssertEqual(L10n.plural(1, "%@ 本"), "1 book")
        XCTAssertEqual(L10n.plural(3, "%@ 本"), "3 books")
        XCTAssertEqual(L10n.plural(1, "%@ 个小窗"), "1 mini window")
        set(.zhHans)
        XCTAssertEqual(L10n.plural(1, "%@ 本"), "1 本")
        XCTAssertEqual(L10n.plural(3, "%@ 本"), "3 本")
    }

    func testSystemLanguageResolvesToAConcreteLanguage() {
        set(.system)
        XCTAssertTrue([.zhHans, .en].contains(L10n.effective))
    }

    func testExplicitLanguagesBeatSystem() {
        set(.en)
        XCTAssertEqual(L10n.effective, .en)
        set(.zhHans)
        XCTAssertEqual(L10n.effective, .zhHans)
    }

    func testEveryTranslationIsNonEmptyAndNotASelfReference() {
        for (key, value) in L10n.english {
            XCTAssertFalse(key.isEmpty)
            XCTAssertFalse(value.isEmpty, "空翻译：\(key)")
            XCTAssertNotEqual(key, value, "无意义的自映射：\(key)")
        }
    }

    func testTemplatesKeepTheSameNumberOfPlaceholders() {
        for (key, value) in L10n.english where key.contains("%@") {
            XCTAssertEqual(key.components(separatedBy: "%@").count - 1,
                           value.components(separatedBy: "%@").count - 1,
                           "占位符数量不匹配：\(key)")
        }
    }

    /// The singular table is separate from `english`; keep the two in sync so a
    /// wording change cannot produce "1 book" next to "3 volumes".
    func testSingularFormsHaveMatchingPluralSources() {
        XCTAssertFalse(L10n.singular.isEmpty)
        for (key, one) in L10n.singular {
            guard let many = L10n.english[key] else {
                XCTFail("单数模板缺少复数翻译：\(key)")
                continue
            }
            XCTAssertEqual(one.components(separatedBy: "%@").count - 1, 1, "\(key)")
            XCTAssertEqual(many.components(separatedBy: "%@").count - 1, 1, "\(key)")
        }
    }

    /// A template given exactly its placeholder count must never leak `%@` or
    /// produce `(null)` in either language. The two raw-string HTML templates
    /// are covered here too (the call-site scan below only sees plain strings).
    func testEveryTemplateFormatsWithoutLeftovers() {
        for key in L10n.english.keys where key.contains("%@") {
            let count = key.components(separatedBy: "%@").count - 1
            let args = Array(repeating: "x" as CVarArg, count: count)
            set(.zhHans)
            let zh = L10n.tr(key, arguments: args)
            set(.en)
            let en = L10n.tr(key, arguments: args)
            for text in [zh, en] {
                XCTAssertFalse(text.contains("%@"), "\(key) → \(text)")
                XCTAssertFalse(text.contains("(null)"), "\(key) → \(text)")
            }
        }
        set(.en)
        let retry = L10n.tr(#"<a class="retry" href="%@"><span>重试</span></a>"#, "u")
        XCTAssertTrue(retry.contains("Retry"))
        XCTAssertFalse(retry.contains("%@"))
        let failure = L10n.tr(#"<h1>无法打开网页</h1><p>%@</p>%@"#, "why", retry)
        XCTAssertTrue(failure.contains("Unable to Open Page"))
        XCTAssertFalse(failure.contains("%@"))
    }

    /// Static check of every `L("...%@...", ...)` call site: a missing argument
    /// would only surface at runtime as `(null)`, so pin the count to the table.
    /// The scanner matches parentheses (ignoring string contents) rather than
    /// stopping at the first `)`, which appears inside interpolated arguments.
    func testFormatCallSitesSupplyTheRightNumberOfArguments() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrielAppTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("OrielApp")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw XCTSkip("源码目录不在测试机上，跳过调用点扫描")
        }
        var checked = 0
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
            XCTFail("无法遍历 OrielApp 源码目录")
            return
        }
        for case let url as URL in enumerator
            where url.pathExtension == "swift" && url.lastPathComponent != "Localization.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for call in formatCalls(in: source) where call.key.contains("%@") {
                let expected = call.key.components(separatedBy: "%@").count - 1
                XCTAssertEqual(call.argumentCount, expected,
                               "\(url.lastPathComponent): \(call.key) 需要 \(expected) 个参数")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10, "扫描到的模板调用过少，扫描器可能已失效")
    }

    func testExportReadmeFollowsTheLanguage() {
        set(.zhHans)
        XCTAssertTrue(L10n.exportReadme().contains("格式 1"))
        set(.en)
        XCTAssertTrue(L10n.exportReadme().contains("format 1"))
        XCTAssertFalse(L10n.exportReadme().contains("格式 1"))
    }

    func testExportIncludesTheLanguageSetting() {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        suite.set("en", forKey: L10n.languageKey)
        suite.set(280.0, forKey: "window.defaults.width")
        suite.set("other", forKey: "unrelated.setting")
        let exported = DataExport.preferences(suite)
        XCTAssertEqual(exported[L10n.languageKey] as? String, "en")
        XCTAssertEqual(exported["window.defaults.width"] as? Double, 280)
        XCTAssertNil(exported["unrelated.setting"])
    }

    @MainActor
    func testSetLanguagePostsChangeNotification() {
        let expectation = expectation(forNotification: .orielLanguageDidChange, object: nil)
        Localization.shared.setLanguage(.en)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(Localization.shared.language, .en)
        XCTAssertEqual(L10n.effective, .en)
    }

    @MainActor
    func testSettingPersistsAndNotifies() {
        let localization = Localization.shared
        let original = localization.language
        defer { localization.setLanguage(original) }
        localization.setLanguage(.en)
        XCTAssertEqual(UserDefaults.standard.string(forKey: L10n.languageKey), "en")
        XCTAssertEqual(L10n.effective, .en)
        XCTAssertEqual(localization.language, .en)
        localization.setLanguage(.zhHans)
        XCTAssertEqual(UserDefaults.standard.string(forKey: L10n.languageKey), "zhHans")
    }

    /// `language` is computed from the stored setting, so an external write is
    /// visible immediately — there is no second cached copy to drift.
    @MainActor
    func testLanguageAlwaysReflectsStoredSetting() {
        set(.en)
        XCTAssertEqual(Localization.shared.language, .en)
        set(.zhHans)
        XCTAssertEqual(Localization.shared.language, .zhHans)
    }

    func testDisplayNameOfExplicitLanguagesIsStable() {
        XCTAssertEqual(AppLanguage.zhHans.displayName, "简体中文")
        XCTAssertEqual(AppLanguage.en.displayName, "English")
    }
}
