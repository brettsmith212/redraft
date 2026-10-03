import AppKit

/// Zen mode: the window goes full screen. Everything else (tools, panels,
/// the Lab) works as usual.
struct ZenState {
    /// Whether zen made the window full screen (and so should undo it).
    var enteredFullScreen: Bool
}

extension EditorSession {
    func toggleZen() {
        if zen == nil { enterZen() } else { exitZen() }
    }

    func enterZen() {
        guard zen == nil, let window = textView?.window else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        zen = ZenState(enteredFullScreen: !wasFullScreen)
        if !wasFullScreen { window.toggleFullScreen(nil) }

        // Leaving full screen another way (green button, menu) ends zen too.
        zenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.exitZen(leaveFullScreen: false) }
        }
    }

    func exitZen(leaveFullScreen: Bool = true) {
        guard let state = zen else { return }
        if let zenObserver { NotificationCenter.default.removeObserver(zenObserver) }
        zenObserver = nil
        zen = nil
        if leaveFullScreen, state.enteredFullScreen, let window = textView?.window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }
}
