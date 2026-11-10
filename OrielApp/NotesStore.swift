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

/// One JSON file per note plus `.backup`, the previous successful version.
/// Not thread-safe; the notes workspace uses it on the main actor.
final class NotesStore {
    let root: URL
    private let files = FileManager.default
    /// Size and modification date of each primary this store last read or wrote. A primary
    /// that still matches needs no read-back before it becomes the backup.
    private var known: [UUID: FileStamp] = [:]
    /// How many saves had to read and decode the existing primary (for tests).
    private(set) var verificationReads = 0

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date
    }

    init(root: URL) { self.root = root }

    private func stamp(_ url: URL) -> FileStamp? {
        guard let attributes = try? files.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: modified)
    }

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
            do {
                let record = try read(url, id: id)
                result.records.append(record)
                known[record.id] = stamp(url)
            }
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
                    known[record.id] = stamp(url)
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
        if let current = stamp(url) {
            // Never let a damaged or foreign primary replace the last good backup.
            if known[record.id] != current {
                verificationReads += 1
                _ = try read(url, id: record.id.uuidString)
            }
            try backUp(url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The atomic write replaces the primary with a new file; a backup linked to
        // the old file keeps the previous version.
        try encoder.encode(record).write(to: url, options: .atomic)
        known[record.id] = stamp(url)
    }

    /// Make `.backup` the current primary's content. A hard link moved over the old backup
    /// avoids copying the note; the primary exists throughout. Falls back to a copy.
    private func backUp(_ primary: URL) throws {
        let backup = primary.appendingPathExtension("backup")
        let link = root.appending(path: "." + primary.lastPathComponent + "." + UUID().uuidString)
        do {
            try files.linkItem(at: primary, to: link)
            guard Darwin.rename(link.path, backup.path) == 0 else {
                let code = errno
                try? files.removeItem(at: link)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        } catch {
            try Data(contentsOf: primary).write(to: backup, options: .atomic)
        }
    }
}
