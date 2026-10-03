import SwiftUI

/// Redraft's own tab strip, in the top row beside the window buttons: quiet
/// text tabs that match the page. Shown only when a window has two or more tabs.
///
/// - Tabs size to their names, up to a maximum; longer names are shortened in
///   the middle so the start and the extension stay ("The Case for…Slowly.md").
/// - When they don't all fit, the longest tabs shrink first, down to a minimum;
///   past that the strip scrolls sideways, with faded edges, keeping the
///   current tab in view. + stays at the end.
/// - Drag a tab sideways to reorder; the others slide out of its way.
struct TabStrip: View {
    let window: () -> NSWindow?
    let export: () -> Void
    @ObservedObject private var model = TabsModel.shared
    @State private var frames: [ObjectIdentifier: CGRect] = [:]
    @State private var drag: Drag?
    @StateObject private var scroller = TabScroller()

    private static let spacing: CGFloat = 2
    static let minTabWidth: CGFloat = 88
    static let maxTabWidth: CGFloat = 220
    private static let plusWidth: CGFloat = 22
    private static let fade: CGFloat = 20

    private struct Drag {
        let id: ObjectIdentifier
        let from: Int
        let start: [ObjectIdentifier: CGRect]
        let order: [ObjectIdentifier]
        var dx: CGFloat = 0
        var to: Int
        /// Set as the tab settles into its new place, after release.
        var settling = false
    }

    private var tabs: [TabInfo] {
        _ = model.tick
        guard let window = window(), let group = window.tabGroup, group.windows.count > 1 else { return [] }
        return group.windows.map(TabInfo.init)
    }

    var body: some View {
        GeometryReader { geometry in
            let tabs = tabs
            if !tabs.isEmpty {
                let current = window()
                let room = geometry.size.width - Self.plusWidth - 6
                // Sized as if bold, so every tab's strip lays out the same.
                let widths = Self.widths(for: tabs.map { TabItem.naturalWidth($0.title) }, room: room)
                let total = widths.reduce(0, +) + Self.spacing * CGFloat(max(0, tabs.count - 1))
                let overflowing = total > room + 0.5
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        row(tabs, widths: widths, current: current)
                            .background(ScrollBridge(scroller: scroller))
                    }
                    .scrollDisabled(!overflowing)
                    .frame(width: min(total, max(0, room)))
                    .mask(edgeFades(leading: overflowing && scroller.offset > 0.5,
                                    trailing: overflowing && scroller.offset < scroller.maxOffset - 0.5))
                    // Every tab of the window has its own strip: each picks up
                    // where the last one was scrolled, so switching tabs
                    // doesn't make the strip jump.
                    .onAppear { settle(tabs, widths: widths, animated: false) }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                        guard let current, note.object as? NSWindow === current else { return }
                        settle(tabs, widths: widths, animated: false)
                    }
                    .onChange(of: tabs.map(\.id)) { settle(tabs, widths: widths, animated: true) }
                    .onChange(of: scroller.offset) { rememberScroll() }
                    Button { WindowTabs.newTab() } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(IconButtonStyle(size: Self.plusWidth))
                    .pointingHandOnHover()
                    .help("New tab (⌘T)")
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .frame(height: 24)
    }

    private func row(_ tabs: [TabInfo], widths: [CGFloat], current: NSWindow?) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                TabItem(
                    title: tab.title,
                    fileURL: tab.fileURL,
                    selected: tab.window === current,
                    width: widths[safe: index] ?? Self.minTabWidth,
                    window: { tab.window },
                    export: export,
                    select: { WindowTabs.select(tab.window) },
                    close: { tab.window.performClose(nil) },
                    dragChanged: { dragChanged(tab.id, index: index, dx: $0.width, tabs: tabs) },
                    dragEnded: { dragEnded(tabs: tabs) }
                )
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named("tabstrip"))])
                })
                .offset(x: offset(for: tab.id, index: index))
                .zIndex(drag?.id == tab.id ? 1 : 0)
            }
        }
        .coordinateSpace(name: "tabstrip")
        .onPreferenceChange(TabFramesKey.self) { frames = $0 }
    }

    /// Fades the strip's edges where more tabs are scrolled out of sight.
    private func edgeFades(leading: Bool, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading ? Self.fade : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: trailing ? Self.fade : 0)
        }
        .animation(.easeOut(duration: 0.15), value: leading)
        .animation(.easeOut(duration: 0.15), value: trailing)
    }

    /// Notes how far the strip is scrolled, while this is the front tab.
    private func rememberScroll() {
        guard let window = window(), window.isKeyWindow, let group = window.tabGroup else { return }
        TabsModel.shared.stripScroll[ObjectIdentifier(group)] = scroller.offset
    }

    /// Scrolls to where the front tab's strip was, then just enough to show
    /// the current tab in full (clear of the edge fades).
    private func settle(_ tabs: [TabInfo], widths: [CGFloat], animated: Bool) {
        guard let current = window(), let index = tabs.firstIndex(where: { $0.window === current }),
              widths.indices.contains(index) else { return }
        // Positions come from the widths: a hidden tab's strip isn't laid out.
        let start = widths[..<index].reduce(0, +) + Self.spacing * CGFloat(index)
        let end = start + widths[index]
        // Read now: once this strip lays out it reports its own (stale) position.
        let saved = current.tabGroup.flatMap { TabsModel.shared.stripScroll[ObjectIdentifier($0)] }
        DispatchQueue.main.async {
            var x = animated ? scroller.offset : (saved ?? scroller.offset)
            let visible = scroller.visibleWidth
            let margin = start > 0 ? Self.fade : 0
            if start - margin < x { x = start - margin }
            if end + Self.fade > x + visible { x = end + Self.fade - visible }
            scroller.scroll(to: x, animated: animated)
        }
    }

    /// Each tab's width: its natural width up to the maximum. When they don't
    /// fit, the widest shrink first (to a shared cap), never below the minimum.
    static func widths(for natural: [CGFloat], room: CGFloat) -> [CGFloat] {
        let natural = natural.map { min(max($0, minTabWidth), maxTabWidth) }
        let available = room - spacing * CGFloat(max(0, natural.count - 1))
        guard natural.reduce(0, +) > available else { return natural }
        var remaining = available
        var cap = minTabWidth
        for (i, width) in natural.sorted().enumerated() {
            let share = remaining / CGFloat(natural.count - i)
            if width <= share {
                remaining -= width
            } else {
                cap = share
                break
            }
        }
        return natural.map { max(minTabWidth, min($0, cap)) }
    }
    /// Where a tab is drawn while one is being dragged: the dragged tab
    /// follows the pointer; the tabs it has passed shift over by its width.
    private func offset(for id: ObjectIdentifier, index: Int) -> CGFloat {
        guard let drag, let dragged = drag.start[drag.id] else { return 0 }
        if id == drag.id {
            guard drag.settling else { return drag.dx }
            return slotX(drag) - dragged.minX
        }
        let shift = dragged.width + Self.spacing
        if drag.from < drag.to, index > drag.from, index <= drag.to { return -shift }
        if drag.to < drag.from, index >= drag.to, index < drag.from { return shift }
        return 0
    }

    /// Where the dragged tab's left edge lands at its new position.
    private func slotX(_ drag: Drag) -> CGFloat {
        guard let dragged = drag.start[drag.id] else { return 0 }
        let target = drag.start[drag.order[drag.to]] ?? dragged
        return drag.to > drag.from ? target.maxX - dragged.width : target.minX
    }

    private func dragChanged(_ id: ObjectIdentifier, index: Int, dx: CGFloat, tabs: [TabInfo]) {
        if drag == nil || drag?.id != id {
            drag = Drag(id: id, from: index, start: frames, order: tabs.map(\.id), to: index)
        }
        guard var current = drag, !current.settling, let dragged = current.start[id] else { return }
        current.dx = dx
        // The new position: how many of the other tabs' centers the dragged
        // tab's center has passed.
        let center = dragged.midX + dx
        let others = current.order.filter { $0 != id }
        let to = others.filter { (current.start[$0]?.midX ?? 0) < center }.count
        if to != current.to {
            current.to = to
            withAnimation(.easeOut(duration: 0.16)) { drag = current }
        } else {
            drag = current
        }
    }

    private func dragEnded(tabs: [TabInfo]) {
        guard var current = drag else { return }
        let window = tabs.first { $0.id == current.id }?.window
        current.settling = true
        withAnimation(.easeOut(duration: 0.14)) { drag = current }
        // Once settled, make the move for real, without animation: the strip
        // is already drawn in its new order.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let window, current.to != current.from { WindowTabs.move(window, to: current.to) }
                drag = nil
            }
        }
    }
}

struct TabInfo: Identifiable {
    let window: NSWindow
    var id: ObjectIdentifier { ObjectIdentifier(window) }
    var title: String { window.title.isEmpty ? "Untitled" : window.title }
    var fileURL: URL? { (window.windowController?.document as? NSDocument)?.fileURL }
}

struct TabFramesKey: PreferenceKey {
    static let defaultValue: [ObjectIdentifier: CGRect] = [:]
    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TabItem: View {
    let title: String
    let fileURL: URL?
    let selected: Bool
    let width: CGFloat
    let window: () -> NSWindow?
    let export: () -> Void
    let select: () -> Void
    let close: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void
    @State private var hovering = false
    @State private var showDetails = false

    private static let fontSize: CGFloat = 11.5
    private static let closeSize: CGFloat = 15
    /// Room kept for the close button beside the name, when there's space.
    private static let closeRoom: CGFloat = closeSize + 4

    private static func textWidth(_ title: String, selected: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: selected ? .semibold : .medium)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    /// The width that shows the whole name (in bold, as when selected) with
    /// the close button beside it.
    static func naturalWidth(_ title: String) -> CGFloat {
        11 + textWidth(title, selected: true) + closeRoom + 4
    }

    /// At full width the close button has its own room; in a narrower tab the
    /// name gets the whole tab and the close button appears over its end.
    private var roomy: Bool { width >= Self.naturalWidth(title) - 0.5 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(title)
                .font(.system(size: Self.fontSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.ink : Color.inkSecondary)
                .lineLimit(1)
                // Long names keep their start and their extension.
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, roomy ? Self.closeRoom : 7)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: hovering && !roomy ? 26 : 0)
                    }
                )
                .allowsHitTesting(false)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: Self.closeSize))
            .opacity(hovering ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(width: width, height: 24)
        .background(
            // Only drawn: a filled shape would take the click from the mouse area below.
            Capsule().fill(selected ? Color.ink.opacity(0.07) : hovering ? Color.ink.opacity(0.04) : .clear)
                .allowsHitTesting(false)
        )
        // Clicks and drags are read by an AppKit view: in the title bar,
        // SwiftUI's own drag would move the whole window instead.
        .background(
            MouseArea(
                click: { if selected { if fileURL != nil { showDetails.toggle() } } else { select() } },
                dragChanged: dragChanged,
                dragEnded: dragEnded
            )
            .clipShape(Capsule())
        )
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        // The full name, since the tab may show it shortened.
        .help(selected && fileURL != nil ? "\(title) · click to show where it lives" : title)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            if let fileURL {
                FileDetails(fileURL: fileURL, window: window, close: { showDetails = false }, export: export)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The tab strip's scroll position, read from and set on the AppKit scroll
/// view under SwiftUI's ScrollView.
@MainActor
final class TabScroller: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var maxOffset: CGFloat = 0
    private(set) var visibleWidth: CGFloat = 0
    fileprivate weak var scrollView: NSScrollView?

    fileprivate func update() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let newOffset = clip.bounds.minX
        let newMax = max(0, document.frame.width - clip.bounds.width)
        visibleWidth = clip.bounds.width
        if abs(newOffset - offset) > 0.1 { offset = newOffset }
        if abs(newMax - maxOffset) > 0.1 { maxOffset = newMax }
        NotificationCenter.default.post(name: MouseArea.reposition, object: nil)
    }

    func scroll(to x: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        update()
        let target = min(max(0, x), maxOffset)
        guard abs(target - offset) > 0.5 else { return }
        let clip = scrollView.contentView
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// Finds the scroll view around the tab row and reports its position.
private struct ScrollBridge: NSViewRepresentable {
    let scroller: TabScroller

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.scroller = scroller }

    final class Probe: NSView {
        weak var scroller: TabScroller?
        private var observer: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil, let scrollView = enclosingScrollView else { return }
            scroller?.scrollView = scrollView
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scroller?.update() }
            }
            scroller?.update()
        }

        override func layout() {
            super.layout()
            scroller?.update()
        }
    }
}

/// Reads clicks and drags with AppKit, and never lets a drag move the window.
/// A press that moves more than a few points is a drag; otherwise a click.
struct MouseArea: NSViewRepresentable {
    var click: () -> Void
    var dragChanged: (CGSize) -> Void
    var dragEnded: () -> Void

    /// Posted when tabs scroll, so the window-frame marks follow them.
    static let reposition = Notification.Name("MouseArea.reposition")

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.click = click
        view.dragChanged = dragChanged
        view.dragEnded = dragEnded
    }

    final class Surface: NSView {
        var click: () -> Void = {}
        var dragChanged: (CGSize) -> Void = { _ in }
        var dragEnded: () -> Void = {}
        private var start: NSPoint?
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // MARK: Keeping the window still

        /// In a window whose content runs under the title bar, macOS moves the
        /// window from a press in the title bar before the app sees it, and
        /// SwiftUI's hosting view decides which of its areas count. So each tab
        /// keeps a companion view directly in the window frame, over the tab,
        /// that marks the spot as not for moving the window and lets every
        /// click through.
        private var shield: Shield?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            shield?.removeFromSuperview()
            shield = nil
            guard let content = window?.contentView, let frameView = content.superview else { return }
            let shield = Shield()
            frameView.addSubview(shield, positioned: .above, relativeTo: content)
            self.shield = shield
            placeShield()
            if repositionObserver == nil {
                repositionObserver = NotificationCenter.default.addObserver(forName: MouseArea.reposition, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeShield() }
                }
            }
        }

        private var repositionObserver: Any?

        deinit {
            if let repositionObserver { NotificationCenter.default.removeObserver(repositionObserver) }
        }

        override func removeFromSuperview() {
            shield?.removeFromSuperview()
            shield = nil
            super.removeFromSuperview()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            placeShield()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            placeShield()
        }

        override func layout() {
            super.layout()
            placeShield()
        }

        private func placeShield() {
            guard let shield, let frameView = shield.superview else { return }
            // Only the part of the tab that's showing (the strip may be scrolled).
            let visible = visibleRect
            let rect = visible.isEmpty ? .zero : convert(visible, to: frameView)
            if shield.frame != rect { shield.frame = rect }
        }

        private final class Shield: NSView {
            override var mouseDownCanMoveWindow: Bool { false }
            /// Clicks pass through to the tab underneath.
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            /// Undocumented AppKit hook (Firefox uses it for its tabs too): the
            /// part of this view that must not move the window. If a future
            /// macOS drops it, dragging a tab moves the window again.
            @objc(_opaqueRectForWindowMoveWhenInTitlebar)
            func opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            // Window coordinates run bottom-up; SwiftUI's run top-down.
            let delta = CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y)
            if !dragging, hypot(delta.width, delta.height) > 4 { dragging = true }
            if dragging { dragChanged(delta) }
        }

        override func mouseUp(with event: NSEvent) {
            if dragging { dragEnded() } else if start != nil { click() }
            start = nil
            dragging = false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
