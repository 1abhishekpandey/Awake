import Foundation
import os

/// The real history store: a JSON file, by default
/// `~/Library/Application Support/Awake/history.json`.
///
/// Writes are atomic (a crash or power loss mid-write never leaves half a file),
/// and a file that cannot be read is moved aside rather than overwritten.
struct FileHistoryStore: HistoryStoring {
    let url: URL

    private static let log = Logger(subsystem: "com.abhishek.awake", category: "history")

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Awake/history.json")
    }

    init(url: URL = FileHistoryStore.defaultURL) {
        self.url = url
    }

    func load() -> [String: TimeInterval] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            return try JSONDecoder().decode([String: TimeInterval].self, from: data)
        } catch {
            // Keep the unreadable file around instead of overwriting it on the next save.
            Self.log.error("history.json unreadable, moving aside: \(error.localizedDescription)")
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return [:]
        }
    }

    func save(_ history: [String: TimeInterval]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(history).write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not save history: \(error.localizedDescription)")
        }
    }
}
