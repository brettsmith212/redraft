import AppKit

/// Native window tabs: ⌘T opens a new document as a tab of the front window,
/// and so does opening a file (⌘O); ⌘W (Close) closes the tab, and the window with its last tab. Redraft
/// draws its own tab strip and Show All Tabs, so the system's are never shown.
@MainActor
enum WindowTabs {
    #if DEBUG
    /// Whether the last new tab arrived already in the tab group (for tests).
    static var debugArrivedTabbed: Bool?
    #endif

    static func newTab() {
        // The front document window, even while the app isn't active.
        guard let host = frontDocumentWindow else {
            // No document window in front (e.g. the welcome window): a plain new document.
            NSDocumentController.shared.newDocument(nil)
            return
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        // The new window is handed to the tab group the moment it's about to
        // appear (see installHooks), so it never shows as a separate window,
        // and fades in over a picture of the page it replaces.
        pendingHost = host
        pendingCurtain = snapshot(of: host)
        NSDocumentController.shared.newDocument(nil)
        EditorSession.session(for: host)?.showingTabs = false
        adopt(into: host, excluding: existing, attempt: 0)
    }

    /// The front document window, even while the app isn't active.
    private static var frontDocumentWindow: NSWindow? {
        guard let front = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.windowController?.document != nil }) else { return nil }
        let host = front.sheetParent ?? front
        return host.windowController?.document != nil ? host : nil
    }

    // MARK: Opening files

    /// Blank tabs already on their way out, so two files opened at once don't
    /// both try to replace the same one.
    private static var replacing: Set<ObjectIdentifier> = []

    /// Opening a file (⌘O, Open Recent, the welcome window, `redraft file.md`)
    /// adds it as a tab of the front window. A file that's already open just
    /// comes to the front, and an untouched blank tab gives its place to the file.
    private static func open(_ url: URL, display: Bool, original: (@escaping (NSDocument?, Bool, Error?) -> Void) -> Void,
                             completion: @escaping (NSDocument?, Bool, Error?) -> Void) {
        if let document = NSDocumentController.shared.document(for: url),
           let window = document.windowControllers.first?.window {
            select(window)
            completion(document, true, nil)
            return
        }
        guard display, let host = frontDocumentWindow else { return original(completion) }
        let blank = host.windowController?.document as? NSDocument
        let replace = blank.map { isUntouchedBlank($0) && !replacing.contains(ObjectIdentifier($0)) } ?? false
        if replace, let blank { replacing.insert(ObjectIdentifier(blank)) }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        pendingHost = host
        pendingCurtain = snapshot(of: host)
        EditorSession.session(for: host)?.showingTabs = false
        original { document, alreadyOpen, error in
            MainActor.assumeIsolated {
                if document == nil {
                    pendingHost = nil
                    pendingCurtain = nil
                } else {
                    adopt(into: host, excluding: existing, attempt: 0)
                }
                if let blank, replace {
                    replacing.remove(ObjectIdentifier(blank))
                    if document != nil, isUntouchedBlank(blank) {
                        blank.close()
                        document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                        TabsModel.shared.refresh()
                    }
                }
            }
            completion(document, alreadyOpen, error)
        }
    }

    /// A new document nobody has typed in.
    private static func isUntouchedBlank(_ document: NSDocument) -> Bool {
        guard document.fileURL == nil, !document.isDocumentEdited,
              let window = document.windowControllers.first?.window,
              let session = EditorSession.session(for: window) else { return false }
        return session.storage.length == 0
    }

    /// Routes the document controller's file opening through open(_:…).
    private static func hookFileOpening() {
        let cls: AnyClass = type(of: NSDocumentController.shared)
        let selector = #selector(NSDocumentController.openDocument(withContentsOf:display:completionHandler:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Handler = @convention(block) (NSDocument?, Bool, NSError?) -> Void
        typealias Open = @convention(c) (NSDocumentController, Selector, NSURL, Bool, @escaping Handler) -> Void
        let originalOpen = unsafeBitCast(method_getImplementation(method), to: Open.self)
        let block: @convention(block) (NSDocumentController, NSURL, Bool, @escaping Handler) -> Void = { controller, url, display, handler in
            let callOriginal: (@escaping (NSDocument?, Bool, Error?) -> Void) -> Void = { done in
                originalOpen(controller, selector, url, display) { done($0, $1, $2) }
            }
            MainActor.assumeIsolated {
                open(url as URL, display: display, original: callOriginal) { handler($0, $1, $2 as NSError?) }
            }
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// Brings a tab to the front, fading from the tab that was showing.
    static func select(_ window: NSWindow) {
        guard let current = window.tabGroup?.selectedWindow, current !== window else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let picture = snapshot(of: current)
        window.makeKeyAndOrderFront(nil)
        fadeIn(window, over: picture)
    }

    /// Moves a tab to a new position in its window's tabs, keeping the
    /// current tab selected.
    static func move(_ window: NSWindow, to index: Int) {
        guard let group = window.tabGroup, let from = group.windows.firstIndex(of: window), from != index else { return }
        let selected = group.selectedWindow
        group.removeWindow(window)
        group.insertWindow(window, at: max(0, min(index, group.windows.count)))
        if let selected, group.windows.contains(selected) { group.selectedWindow = selected }
        TabsModel.shared.refresh()
    }

    /// The window a new tab should join, while one is being created.
    static var pendingHost: NSWindow?
    private static var pendingCurtain: NSImage?

    /// Called by the ordering hook as the new tab is first shown.
    fileprivate static func arrive(_ window: NSWindow, in host: NSWindow) {
        pendingHost = nil
        window.animationBehavior = .none
        host.addTabbedWindow(window, ordered: .above)
        fadeIn(window, over: pendingCurtain)
        pendingCurtain = nil
    }

    /// Waits for the new document's window, then tabs it into the host window
    /// (only needed if the ordering hook didn't catch it).
    private static func adopt(into host: NSWindow, excluding existing: Set<ObjectIdentifier>, attempt: Int) {
        if let window = NSApp.windows.first(where: {
            !existing.contains(ObjectIdentifier($0)) && $0.windowController?.document != nil
        }) {
            #if DEBUG
            debugArrivedTabbed = pendingHost == nil && window.tabGroup === host.tabGroup
            #endif
            if pendingHost != nil { arrive(window, in: host) }
            window.makeKeyAndOrderFront(nil)
            TabsModel.shared.refresh()
            return
        }
        guard attempt < 40 else { pendingHost = nil; pendingCurtain = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { adopt(into: host, excluding: existing, attempt: attempt + 1) }
    }

    // MARK: Crossfade

    /// A picture of a window as it looks now.
    static func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView?.superview, view.bounds.width > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Lays a picture over the window's page and fades it away, so switching
    /// tabs reads as one page dissolving into the next.
    static func fadeIn(_ window: NSWindow, over picture: NSImage?) {
        guard let picture, let content = window.contentView, let frameView = content.superview else { return }
        let curtain = Curtain(frame: content.frame)
        curtain.autoresizingMask = [.width, .height]
        curtain.wantsLayer = true
        curtain.layer?.contents = picture
        curtain.layer?.contentsGravity = .resize
        frameView.addSubview(curtain, positioned: .above, relativeTo: content)
        // A beat for the new page to lay out underneath, then dissolve.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                curtain.animator().alphaValue = 0
            } completionHandler: {
                curtain.removeFromSuperview()
            }
        }
    }

    /// Never takes clicks.
    private final class Curtain: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    // MARK: Hooks

    /// Installed once at launch:
    /// - new tab windows join their tab group as they're first shown;
    /// - opened files become tabs of the front window;
    /// - Show All Tabs (⇧⌘\) opens Redraft's own overview;
    /// - the system tab bar is hidden from the moment it's created, so it
    ///   never flashes. If a future macOS renames it, the only effect is that
    ///   the system bar shows again.
    static func installHooks() {
        exchange(#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.mw_order(_:relativeTo:)))
        exchange(#selector(NSWindow.toggleTabOverview(_:)), #selector(NSWindow.mw_toggleTabOverview(_:)))
        hideSystemTabBars()
        hookFileOpening()
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(NSWindow.self, original),
              let b = class_getInstanceMethod(NSWindow.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    private static func hideSystemTabBars() {
        guard let tabBar = NSClassFromString("NSTabBar") else { return }
        let setHidden = #selector(setter: NSView.isHidden)
        if let method = class_getInstanceMethod(tabBar, setHidden) {
            typealias SetHidden = @convention(c) (NSView, Selector, Bool) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: SetHidden.self)
            let block: @convention(block) (NSView, Bool) -> Void = { view, _ in original(view, setHidden, true) }
            class_replaceMethod(tabBar, setHidden, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let moved = #selector(NSView.viewDidMoveToWindow)
        if let method = class_getInstanceMethod(tabBar, moved) {
            typealias Moved = @convention(c) (NSView, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Moved.self)
            let block: @convention(block) (NSView) -> Void = { view in
                original(view, moved)
                view.isHidden = true
            }
            class_replaceMethod(tabBar, moved, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
    }

    static func showAllTabs() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        EditorSession.session(for: window.sheetParent ?? window)?.showingTabs = true
    }
}

/// Tells tab strips to redraw when windows open, close, change focus or are renamed.
@MainActor
final class TabsModel: ObservableObject {
    static let shared = TabsModel()
    @Published private(set) var tick = 0
    /// Per tab group: how far the tab strip is scrolled, so each tab's strip
    /// shows the same scroll.
    var stripScroll: [ObjectIdentifier: CGFloat] = [:]
    private var titleObservations: [NSKeyValueObservation] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TabsModel.shared.refresh() }
            }
        }
        // A closing window is still listed until the close finishes.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { TabsModel.shared.refresh() } }
        }
    }

    func refresh() {
        let documentWindows = NSApp.windows.filter { $0.windowController?.document != nil }
        titleObservations = documentWindows.map { window in
            window.observe(\.title) { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { TabsModel.shared.tick += 1 } }
            }
        }
        tick += 1
    }
}

extension NSWindow {
    /// Swapped with order(_:relativeTo:) by WindowTabs.installHooks.
    @objc func mw_order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        MainActor.assumeIsolated {
            if place != .out, let host = WindowTabs.pendingHost, host !== self,
               windowController?.document != nil, (tabGroup?.windows.count ?? 1) <= 1 {
                WindowTabs.arrive(self, in: host)
                makeKey()
                return
            }
            mw_order(place, relativeTo: otherWindow)  // the original
        }
    }

    /// Swapped with toggleTabOverview(_:) by WindowTabs.installHooks.
    @objc func mw_toggleTabOverview(_ sender: Any?) {
        MainActor.assumeIsolated {
            if let session = EditorSession.session(for: self) {
                session.showingTabs.toggle()
            } else {
                mw_toggleTabOverview(sender)  // the original
            }
        }
    }
}
