import Darwin
import Foundation

/// WebKit streams into a directory owned by one download. Only complete files
/// acquire a user-visible name in Downloads.
struct BrowserDownloadFile {
    let temporaryURL: URL
    let filename: String
    private let folder: URL
    private let staging: URL

    init(in folder: URL, suggestedFilename: String) throws {
        self.folder = folder
        let component = (suggestedFilename as NSString).lastPathComponent
        filename = ["", ".", "..", "/"].contains(component) ? "download" : component
        staging = folder.appending(path: ".oriel-download-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        temporaryURL = staging.appending(path: filename, directoryHint: .notDirectory)
    }

    func publish() throws -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = filename
        var index = 0
        while true {
            let destination = folder.appending(path: candidate, directoryHint: .notDirectory)
            // Same-volume exclusive rename preserves WebKit's file metadata and
            // also respects files created outside Oriel while the download ran.
            if renamex_np(temporaryURL.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            index += 1
            candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        }
    }

    func discardStaging() {
        try? FileManager.default.removeItem(at: staging)
    }
}
