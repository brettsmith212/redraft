import AppKit

/// ⌘+ / ⌘- / ⌘0 zoom for the writing in every window. It isn't saved, so
/// each launch starts at actual size.
@MainActor
final class Zoom: ObservableObject {
    static let shared = Zoom()
    static let changed = Notification.Name("RedraftZoomChanged")
    static let steps: [CGFloat] = [0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2, 2.4]

    @Published private(set) var scale: CGFloat = 1

    var percent: Int { Int((scale * 100).rounded()) }
    var canZoomIn: Bool { scale < Self.steps.last! }
    var canZoomOut: Bool { scale > Self.steps.first! }

    func zoomIn() { set(Self.steps.first { $0 > scale + 0.001 } ?? scale) }
    func zoomOut() { set(Self.steps.last { $0 < scale - 0.001 } ?? scale) }
    func reset() { set(1) }

    private func set(_ value: CGFloat) {
        guard value != scale else { return }
        scale = value
        Theme.setZoom(value)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private var monitor: Any?

    /// ⌘+ is typed as ⌘= on most keyboards; the menu item uses "=", and this
    /// catches the shifted "+" too.
    func installPlusKey() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard flags == .command, event.charactersIgnoringModifiers == "+" else { return event }
            MainActor.assumeIsolated { Zoom.shared.zoomIn() }
            return nil
        }
    }
}

extension EditorSession {
    /// Re-lays out the page at the new zoom: text, overflow, column width and caret.
    func applyZoom() {
        guard let tv = textView else { return }
        restyleAll()
        updateTypingAttributes()
        tv.setFrameSize(tv.frame.size)
        if let overflow = overflowView {
            let o = doc.overflow
            if o.length > 0 { o.setAttributes(Theme.overflowAttributes, range: NSRange(location: 0, length: o.length)) }
            overflow.typingAttributes = Theme.overflowAttributes
        }
        tv.scrollRangeToVisible(tv.selectedRange())
    }
}
