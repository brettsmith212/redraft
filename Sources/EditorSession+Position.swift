import AppKit

/// Remembers the cursor and scroll position per file, so a document reopens
/// where you left it (after ⌘Q, or from the welcome window's Recent list).
extension EditorSession {
    private static let key = "positions"
    private static let limit = 100

    private var documentURL: URL? {
        (textView?.window?.windowController?.document as? NSDocument)?.fileURL
    }

    /// Saves the position; called (debounced) as the cursor moves and on quit.
    func savePosition() {
        guard positionReady, let tv = textView, let url = documentURL else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        let scroll = tv.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        all[url.path] = [Double(tv.selectedRange().location), Double(scroll), Date().timeIntervalSince1970]
        if all.count > Self.limit {
            // Forget the least recently used files.
            let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(all.count - Self.limit)
            oldest.forEach { all[$0.key] = nil }
        }
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    func schedulePositionSave() {
        guard positionReady else { return }
        positionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePosition() }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Puts the cursor and scroll back once the window and its document
    /// exist; a file with no saved position (or a new document) starts at the end.
    func restorePosition(attempt: Int = 0) {
        guard let tv = textView else { return }
        guard let url = documentURL else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.restorePosition(attempt: attempt + 1) }
            } else {
                placeCaretAtEnd()
            }
            return
        }
        defer { positionReady = true }
        guard let saved = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [Double]])?[url.path],
              saved.count >= 2 else {
            placeCaretAtEnd()
            return
        }
        let location = min(max(0, Int(saved[0])), tv.string.utf16.count)
        tv.setSelectedRange(NSRange(location: location, length: 0))
        if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
        if let clip = tv.enclosingScrollView?.contentView {
            let maxY = max(0, tv.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: max(0, min(CGFloat(saved[1]), maxY))))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        // Keep the saved scroll unless it would leave the cursor off screen.
        tv.scrollRangeToVisible(tv.selectedRange())
        tv.scheduleCaretUpdate()
    }

    private func placeCaretAtEnd() {
        guard let tv = textView else { return }
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        positionReady = true
    }
}
