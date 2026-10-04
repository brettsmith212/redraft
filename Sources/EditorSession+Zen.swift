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
        let observer = ObserverBag()
        observer.add(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.exitZen(leaveFullScreen: false) }
        })
        zenObserver = observer
    }

    private func endZen() {
        zenObserver = nil
        zen = nil
    }

    // MARK: Writing in zen

    /// Zen dims all but the paragraph being written (Settings: zenFocus)…
    static var zenFocus: Bool { UserDefaults.standard.object(forKey: "zenFocus") as? Bool ?? true }
    /// …and keeps its line in the middle of the screen (zenTypewriter).
    static var zenTypewriter: Bool { UserDefaults.standard.object(forKey: "zenTypewriter") as? Bool ?? true }

    /// Turns focus and typewriter scrolling on or off to match zen and the settings.
    func applyZenWriting() {
        let typewriter = zen != nil && Self.zenTypewriter
        if let tv = textView, tv.typewriter != typewriter {
            tv.typewriter = typewriter
            if !typewriter { tv.scrollRangeToVisible(tv.selectedRange()) }
        }
        updateFocus()
    }

    /// Dims everything outside the paragraph being written, by drawing it
    /// in a fainter color (the text itself is untouched). Ghosted text keeps
    /// its own, fainter look.
    func updateFocus() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let full = fullRange
        guard zen != nil, Self.zenFocus, storage.length > 0 else {
            if focusRange != nil {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                focusRange = nil
                tv.needsDisplay = true
            }
            return
        }
        let selection = tv.selectedRange()
        let start = min(selection.location, storage.length)
        let focus = string.paragraphRange(for: NSRange(location: start, length: min(selection.length, storage.length - start)))
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        lm.addTemporaryAttribute(.foregroundColor, value: Theme.dimmed, forCharacterRange: full)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: focus)
        storage.enumerateAttribute(.ghost, in: full) { value, r, _ in
            if value != nil { lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r) }
        }
        focusRange = focus
        tv.needsDisplay = true
    }
}
