import SwiftUI

/// Show All Tabs (⇧⌘\ or a pinch on the page): every tab of the window as a
/// card. Click a card to open it, drag cards to reorder, + for a new tab.
/// Esc, a click on the background or a pinch out closes it.
struct TabOverview: View {
    @ObservedObject var session: EditorSession
    let window: NSWindow
    @ObservedObject private var model = TabsModel.shared
    @State private var frames: [ObjectIdentifier: CGRect] = [:]
    /// The card order while a drag is rearranging them.
    @State private var order: [ObjectIdentifier] = []
    @State private var drag: Drag?
    @State private var highlighted: ObjectIdentifier?
    @State private var appeared = false
    @State private var keyMonitor: Any?

    private struct Drag {
        let id: ObjectIdentifier
        let start: CGRect
        var translation: CGSize = .zero
        var settling = false
    }

    private var tabs: [TabInfo] {
        _ = model.tick
        let all = (window.tabGroup?.windows ?? [window]).map(TabInfo.init)
        guard !order.isEmpty else { return all }
        return order.compactMap { id in all.first { $0.id == id } }
    }

    private var aspect: CGFloat {
        let size = window.contentView?.bounds.size ?? CGSize(width: 4, height: 3)
        return size.width / max(1, size.height)
    }

    var body: some View {
        let tabs = tabs
        ZStack(alignment: .topLeading) {
            Color.panel
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .arrowCursorOnHover()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 30)], spacing: 26) {
                    ForEach(tabs) { tab in
                        card(tab, picture: session.tabPictures[tab.id])
                            .opacity(drag?.id == tab.id ? 0 : 1)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named("overview"))])
                            })
                    }
                    NewTabCard(aspect: aspect) { newTab() }
                }
                .padding(.horizontal, 48)
                .padding(.top, 72)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
            if let drag, let tab = tabs.first(where: { $0.id == drag.id }) {
                // The dragged card floats above the grid, following the pointer.
                let target = drag.settling ? (frames[drag.id] ?? drag.start) : drag.start
                let offset = drag.settling ? .zero : drag.translation
                card(tab, picture: session.tabPictures[tab.id], lifted: !drag.settling)
                    .frame(width: drag.start.width, height: drag.start.height)
                    .position(x: target.midX + offset.width, y: target.midY + offset.height)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "overview")
        .onPreferenceChange(TabFramesKey.self) { frames = $0 }
        .scaleEffect(appeared ? 1 : 1.04)
        .gesture(MagnifyGesture().onEnded { if $0.magnification > 1.15 { dismiss() } })
        .onAppear {
            highlighted = ObjectIdentifier(window)
            withAnimation(.easeOut(duration: 0.22)) { appeared = true }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handleKey(event) ? nil : event }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private func card(_ tab: TabInfo, picture: NSImage?, lifted: Bool = false) -> some View {
        TabCard(
            title: tab.title,
            picture: picture,
            aspect: aspect,
            current: tab.window === window,
            highlighted: highlighted == tab.id,
            lifted: lifted,
            open: { if let tab = tab.window { open(tab) } },
            close: { if let tab = tab.window { close(tab) } },
            dragChanged: { dragChanged(tab.id, translation: $0) },
            dragEnded: { dragEnded() }
        )
    }

    // MARK: Actions

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) { session.showingTabs = false }
    }

    private func open(_ tab: NSWindow) {
        guard tab !== window else { return dismiss() }
        WindowTabs.select(tab)
        // This window is now behind the chosen tab; reset it quietly.
        session.showingTabs = false
    }

    private func newTab() {
        WindowTabs.newTab()
    }

    private func close(_ tab: NSWindow) {
        guard tab === window, let group = window.tabGroup, group.windows.count > 1 else {
            tab.performClose(nil)
            return
        }
        // Closing the tab that shows this overview: carry on in the tab that takes its place.
        window.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !window.isVisible, let next = group.selectedWindow ?? group.windows.first else { return }
            EditorSession.session(for: next)?.showingTabs = true
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        // Menu shortcuts (⇧⌘\, ⌘T, ⌘W…) still work.
        if event.modifierFlags.contains(.command) { return false }
        let ids = tabs.map(\.id)
        let index = highlighted.flatMap { ids.firstIndex(of: $0) } ?? 0
        switch event.keyCode {
        case 53: dismiss()                                                      // Esc
        case 123: if !ids.isEmpty { highlighted = ids[max(0, index - 1)] }       // ←
        case 124: if !ids.isEmpty { highlighted = ids[min(ids.count - 1, index + 1)] }  // →
        case 36, 76, 49:                                                        // Return, Enter, Space
            if let tab = tabs.first(where: { $0.id == highlighted })?.window { open(tab) }
        default: break
        }
        // Typing never reaches the page underneath.
        return true
    }

    // MARK: Reordering

    private func dragChanged(_ id: ObjectIdentifier, translation: CGSize) {
        if drag?.id != id {
            guard let start = frames[id] else { return }
            order = tabs.map(\.id)
            drag = Drag(id: id, start: start)
        }
        guard var current = drag, !current.settling else { return }
        current.translation = translation
        drag = current
        // Take the place of whichever card the pointer is over.
        let point = CGPoint(x: current.start.midX + translation.width, y: current.start.midY + translation.height)
        guard let over = order.first(where: { $0 != id && (frames[$0]?.contains(point) ?? false) }),
              let from = order.firstIndex(of: id), let to = order.firstIndex(of: over) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            order.remove(at: from)
            order.insert(id, at: to)
        }
    }

    private func dragEnded() {
        guard var current = drag else { return }
        // Glide into the card's new place, then make the order real.
        current.settling = true
        withAnimation(.easeOut(duration: 0.18)) { drag = current }
        let final = order
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let group = window.tabGroup {
                for (index, id) in final.enumerated() {
                    if let tab = group.windows.first(where: { ObjectIdentifier($0) == id }) { WindowTabs.move(tab, to: index) }
                }
            }
            drag = nil
            order = []
        }
    }
}

private struct TabCard: View {
    let title: String
    let picture: NSImage?
    let aspect: CGFloat
    let current: Bool
    let highlighted: Bool
    var lifted = false
    let open: () -> Void
    let close: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Color.paper
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(current ? Color.accent.opacity(0.85) : Color.hairline, lineWidth: current ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.25), lineWidth: 1.5)
                    .padding(-4)
                    .opacity(highlighted && !current ? 1 : 0)
            )
            .shadow(color: .black.opacity(lifted ? 0.22 : hovering ? 0.14 : 0.08),
                    radius: lifted ? 18 : hovering ? 12 : 6, y: lifted ? 8 : 3)
            .scaleEffect(lifted ? 1.03 : hovering ? 1.015 : 1)
            .allowsHitTesting(false)
            Text(TabCard.shortened(title))
                .font(.system(size: 12, weight: current ? .semibold : .medium))
                .foregroundStyle(current ? Color.ink : Color.inkSecondary)
                .lineLimit(1)
                .allowsHitTesting(false)
        }
        .background(MouseArea(click: open, dragChanged: dragChanged, dragEnded: dragEnded))
        .overlay(alignment: .topLeading) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .background(Circle().fill(Color.panel))
            .overlay(Circle().strokeBorder(Color.hairline))
            .offset(x: -8, y: -8)
            .opacity(hovering && !lifted ? 1 : 0)
            .pointingHandOnHover()
            .help("Close tab")
        }
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: lifted)
    }

    static func shortened(_ title: String, limit: Int = 34) -> String {
        guard title.count > limit else { return title }
        return "\(title.prefix(limit / 2))…\(title.suffix(limit / 2 - 1))"
    }
}

private struct NewTabCard: View {
    let aspect: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.ink.opacity(hovering ? 0.28 : 0.14), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink.opacity(hovering ? 0.04 : 0)))
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(hovering ? Color.ink : Color.inkSecondary)
                    )
                Text("New Tab")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .help("New tab (⌘T)")
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}
