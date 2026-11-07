import Foundation

struct NoteRecord: Codable, Equatable, Identifiable {
    static let textLimit = 1_048_576
    var schema = 1
    let id: UUID
    var text: String
    let created: Date
    var updated: Date
    var pinned = false
    var deleted: Date?

    var title: String {
        var remaining = text[...]
        while !remaining.isEmpty {
            let end = remaining.firstIndex(where: \.isNewline) ?? remaining.endIndex
            let line = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                let prefix = line.prefix(41)
                return String(prefix.prefix(40)) + (prefix.count > 40 ? "…" : "")
            }
            guard end != remaining.endIndex else { break }
            remaining = remaining[remaining.index(after: end)...]
        }
        return "未命名"
    }
}

enum NotesError: LocalizedError {
    case tooLarge, invalidRecord, unsupportedVersion
    static func message(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteFileExists: return "存储目录被同名文件占用，请检查便签的存储位置。"
            case .fileWriteNoPermission, .fileReadNoPermission: return "没有访问便签目录的权限，请检查文件权限。"
            case .fileWriteOutOfSpace: return "磁盘空间不足，请腾出空间后重试。"
            default: break
            }
        }
        return error.localizedDescription
    }

    var errorDescription: String? {
        switch self {
        case .tooLarge: "这张便签已达到 1 MiB 上限，请拆成多张。"
        case .invalidRecord: "便签文件损坏，原件已保留。"
        case .unsupportedVersion: "这张便签来自较新版本，文件已保留。"
        }
    }
}

struct NotesStore {
    let root: URL
    private let files = FileManager.default

    struct Loaded {
        var records: [NoteRecord] = []
        var issues: [String] = []
    }

    func load() throws -> Loaded {
        guard files.fileExists(atPath: root.path) else { return Loaded() }
        let urls = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        var result = Loaded()
        for url in urls {
            let id = url.deletingPathExtension().lastPathComponent
            do { result.records.append(try read(url, id: id)) }
            catch NotesError.unsupportedVersion {
                result.issues.append("一张便签需要较新版本，原件已保留。")
            } catch {
                do {
                    let backup = url.appendingPathExtension("backup")
                    let record = try read(backup, id: id)
                    let recovery = root.appending(path: "Recovery")
                    try files.createDirectory(at: recovery, withIntermediateDirectories: true)
                    // Do not replace the primary unless preserving its exact bytes succeeds.
                    try files.copyItem(at: url, to: recovery.appending(path: id + "-" + UUID().uuidString + ".json"))
                    try Data(contentsOf: backup).write(to: url, options: .atomic)
                    result.records.append(record)
                    result.issues.append("已恢复一张便签的上一份副本，损坏原件已保留。")
                } catch { result.issues.append("一张便签无法读取，原件已保留，其余便签仍可使用。") }
            }
        }
        return result
    }

    private func read(_ url: URL, id: String) throws -> NoteRecord {
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let schema: Int }
        guard try JSONDecoder().decode(Header.self, from: data).schema == 1 else { throw NotesError.unsupportedVersion }
        let record = try JSONDecoder().decode(NoteRecord.self, from: data)
        guard record.id.uuidString == id else { throw NotesError.invalidRecord }
        guard record.text.utf8.count <= NoteRecord.textLimit else { throw NotesError.tooLarge }
        return record
    }

    func save(_ record: NoteRecord) throws {
        guard record.text.utf8.count <= NoteRecord.textLimit else { throw NotesError.tooLarge }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: record.id.uuidString + ".json")
        if files.fileExists(atPath: url.path) {
            _ = try read(url, id: record.id.uuidString)
            try Data(contentsOf: url).write(to: url.appendingPathExtension("backup"), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}
