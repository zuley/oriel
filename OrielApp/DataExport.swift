import Foundation

struct DataExport {
    let source: URL
    private let files = FileManager.default

    enum ExportError: LocalizedError {
        case insideSource, symbolicLink, invalidStaging
        var errorDescription: String? {
            switch self {
            case .insideSource: L("请选择 Oriel 数据目录之外的位置。")
            case .symbolicLink: L("数据目录包含符号链接，导出已停止，原文件未改动。")
            case .invalidStaging: L("导出临时目录无效，请重新导出。")
            }
        }
    }

    func prepare(in destination: URL, preferences: [String: Any]) throws -> URL {
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else { throw ExportError.insideSource }
        let staging = destination.appending(path: ".oriel-export-" + UUID().uuidString)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
            try data.write(to: staging.appending(path: "preferences.plist"), options: .atomic)
            return staging
        } catch { try? files.removeItem(at: staging); throw error }
    }

    func copyNotes(to staging: URL) throws {
        let notes = source.appending(path: "Notes")
        guard files.fileExists(atPath: notes.path) else { return }
        try Self.checkLinks(notes)
        try files.copyItem(at: notes, to: staging.appending(path: "Notes"))
    }

    func finish(_ staging: URL) throws -> URL {
        guard staging.lastPathComponent.hasPrefix(".oriel-export-") else { throw ExportError.invalidStaging }
        try Data(L10n.exportReadme().utf8).write(to: staging.appending(path: L("说明.txt")))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let output = staging.deletingLastPathComponent().appending(path: "Oriel-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))")
        try files.moveItem(at: staging, to: output)
        return output
    }

    static func preferences(_ defaults: UserDefaults) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix("window.defaults.") || key == "management.openAtLaunch" ||
            key.hasPrefix("novel.") || key == "watchlist.symbols.v1" ||
            key == L10n.languageKey
        }
    }

    private static func checkLinks(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        let value = try url.resourceValues(forKeys: keys)
        guard value.isSymbolicLink != true else { throw ExportError.symbolicLink }
        if value.isDirectory == true {
            for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) {
                try checkLinks(item)
            }
        }
    }
}
