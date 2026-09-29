import AppKit
import SwiftUI

/// Reports whether the window hosting this view is actually on screen.
///
/// The popover's window is hidden, not destroyed, when it closes, and
/// `onAppear`/`onDisappear` are not reliable for that. Watching the window's
/// occlusion state is, and it lets the per-second `TimelineView` run only
/// while the popover is open.
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportCurrent() }
                }
            }
            reportCurrent()
        }

        private func reportCurrent() {
            report(window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
