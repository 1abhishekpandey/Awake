import Foundation

/// Runs `body` on the main actor.
///
/// When called on the main thread it runs synchronously, so a handler for
/// "about to sleep" or "about to quit" finishes before the process goes away.
/// From any other thread (a C callback, say) it hops to the main actor.
func runOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        Task { @MainActor in body() }
    }
}
