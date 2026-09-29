import Foundation
import Testing

@testable import Awake

/// The one test that touches a file: FileHistoryStore against its own temporary
/// folder, removed afterwards. It never goes near the real history file.
@Suite("FileHistoryStore")
struct FileHistoryStoreTests {
    @Test("Saves and loads, and moves an unreadable file aside instead of overwriting it")
    func roundTripAndCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AwakeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/history.json")
        let store = FileHistoryStore(url: url)

        #expect(store.load().isEmpty) // no file yet

        store.save(["2026-10-07": 123.5, "2026-10-08": 60])
        #expect(store.load() == ["2026-10-07": 123.5, "2026-10-08": 60])

        try Data("not json".utf8).write(to: url)
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
    }
}
