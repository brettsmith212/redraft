import AppKit

/// Zen mode: the window goes full screen and its tab strip steps aside.
/// Everything else (tools, panels, the Lab, ⌃Tab, Show All Tabs) works as
/// usual. A window's tabs share the full screen, so they're in zen together.
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
        let state = ZenState(enteredFullScreen: !wasFullScreen)
        WindowTabs.collapseSystemTabBarInFullScreen(window)
        if !wasFullScreen { window.toggleFullScreen(nil) }
        for session in tabSessions { session.beginZen(state) }
    }

    func exitZen(leaveFullScreen: Bool = true) {
        guard let state = zen else { return }
        for session in tabSessions { session.endZen() }
        if leaveFullScreen, state.enteredFullScreen, let window = textView?.window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// A tab joining a window in zen (⌘T, or opening a file) is in zen too.
    func joinZen(of host: NSWindow) {
        guard let state = EditorSession.session(for: host)?.zen else { return }
        beginZen(state)
    }

    /// The sessions of this window's tabs, this one included.
    private var tabSessions: [EditorSession] {
        guard let window = textView?.window else { return [self] }
        return (window.tabGroup?.windows ?? [window]).compactMap { EditorSession.session(for: $0) }
    }

    private func beginZen(_ state: ZenState) {
        guard zen == nil, let window = textView?.window else { return }
        zen = state
        // Leaving full screen another way (green button, menu) ends zen too.
        zenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.exitZen(leaveFullScreen: false) }
        }
    }

    private func endZen() {
        if let zenObserver { NotificationCenter.default.removeObserver(zenObserver) }
        zenObserver = nil
        zen = nil
    }
}
