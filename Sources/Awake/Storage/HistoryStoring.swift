import Foundation

/// Where the per-day awake time lives between launches: a map of `yyyy-MM-dd`
/// to seconds. The app uses `FileHistoryStore`; tests use an in-memory double,
/// so no test ever touches the real file.
protocol HistoryStoring {
    /// Everything stored, or an empty map when there is nothing usable.
    func load() -> [String: TimeInterval]
    /// Replaces what is stored.
    func save(_ history: [String: TimeInterval])
}
