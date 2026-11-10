import XCTest
@testable import OrielReading

/// R00 baseline P6 (docs/plans/017-refactor-tasks.md): memory and time to decode every
/// chapter of a book close to the 32 MiB import limit. Each reading tab holds such an
/// array today, so two tabs on one book hold two copies.
final class ShelfMemoryBaselineTests: XCTestCase {
    func testP6DecodeLargeBook() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "oriel-shelf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paragraph = "風穿過岸邊的柳樹，水面起了一層細紋，遠處有人在唱歌，聲音順著河道慢慢飄過來。\n\n"
        var text = ""
        var number = 1
        while text.utf8.count < 30 * 1024 * 1024 {
            text += "第\(number)章 河岸\n" + String(repeating: paragraph, count: 120)
            number += 1
        }
        let source = root.appending(path: "large.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: source)
        text = ""

        let shelf = NovelShelf(root: root.appending(path: "Books"))
        let book = try await shelf.add(file: source)
        print("P6 book: \(book.chapterCount) chapters, source \(30) MiB")

        // Retained footprint while holding one, then two decoded copies (two tabs).
        let before = Self.footprintMiB()
        let clock = ContinuousClock()
        let start = clock.now
        let first = try await shelf.chapters(of: book)
        let decodeTime = clock.now - start
        let one = Self.footprintMiB()
        let second = try await shelf.chapters(of: book)
        let two = Self.footprintMiB()
        XCTAssertEqual(first.count, second.count)
        print(String(format: "P6 decode %.0f ms; footprint +%.0f MiB for one copy, +%.0f MiB for two",
                     Double(decodeTime.components.attoseconds) / 1e15 + Double(decodeTime.components.seconds) * 1000,
                     one - before, two - before))
    }

    private static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
