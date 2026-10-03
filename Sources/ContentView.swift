import SwiftUI

/// One writing window. With writing tools off it's just a page and a word
/// count. Click the word count to bring the tools in.
struct ContentView: View {
    @ObservedObject var doc: WriterDocument
    /// Where the document lives on disk; nil until a new document is first saved.
    let fileURL: URL?
    @StateObject private var session: EditorSession
    @Environment(\.undoManager) private var undoManager
    @State private var showZenHint = false
    @State private var showFileTitle = false
    @State private var toolsHovered = false
    @State private var wordCountHovered = false
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var zoom = Zoom.shared
    @State private var showZoomHint = false
    @State private var zoomHintToken = 0
    @State private var tabHint: String?
    @State private var tabHintToken = 0

    init(doc: WriterDocument, fileURL: URL?) {
        self.doc = doc
        self.fileURL = fileURL
        _session = StateObject(wrappedValue: EditorSession(doc: doc))
    }

    var body: some View {
        HStack(spacing: 0) {
            if session.featuresOn && session.showAlternatives {
                AlternativesPanel(session: session)
                    .frame(width: 272)
                    .transition(.opacity)
                Rectangle().fill(Color.hairline).frame(width: 1)
            }

            ZStack {
                EditorView(session: session)
                    .opacity(session.previewing ? 0 : 1)
                    .allowsHitTesting(!session.previewing)
                if session.previewing {
                    MarkdownPreview(markdown: session.cleanText(), zoom: zoom.scale)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                // Text fades out under the top bar instead of colliding with it.
                LinearGradient(
                    stops: [
                        .init(color: Color.paper, location: 0),
                        .init(color: Color.paper, location: 0.55),
                        .init(color: Color.paper.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 58)
                .allowsHitTesting(false)
                .opacity(session.previewing ? 0 : 1)
            }
            .overlay(alignment: .top) {
                if !hasTabs {
                FileTitle(fileURL: fileURL, window: { session.textView?.window }, export: { session.exportCleanCopy() }, visible: $showFileTitle)
                    .padding(.top, 8)
                }
            }
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .top) { zenHint }
            .overlay(alignment: .top) { zoomHint }
            .overlay(alignment: .top) { tabHintView }
            .overlay(alignment: .bottom) { errorToast }
            // The page changes width in one step when a panel opens or closes,
            // so the text re-wraps once (no flicker) and keeps its place.
            .transaction { $0.animation = nil }
            // After the line above, so the tools can animate open and closed.
            .overlay(alignment: .bottomTrailing) { toolBar }
            .onContinuousHover { phase in
                if session.typingQuietly { session.typingQuietly = false }
                // Reveal the file name while the pointer is in the top strip. Applied
                // after the overlays so being over the name itself still counts.
                let near: Bool
                if case .active(let point) = phase { near = point.y < 44 } else { near = false }
                if near != showFileTitle { showFileTitle = near }
            }

            if session.featuresOn, let panel = session.rightPanel {
                Rectangle().fill(Color.hairline).frame(width: 1)
                Group {
                    switch panel {
                    case .overflow: OverflowPanel(session: session)
                    case .lab: LabPanel(session: session)
                    }
                }
                .frame(width: 300)
                .transition(.opacity)
            }
        }
        .background(Color.paper)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 520, minHeight: 380)
        .animation(.easeOut(duration: 0.2), value: session.featuresOn)
        .animation(.easeOut(duration: 0.2), value: session.showAlternatives)
        .animation(.easeOut(duration: 0.2), value: session.rightPanel)
        .animation(.easeOut(duration: 0.15), value: session.previewing)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourOverlay(session: session, anchors: anchors)
        }
        .overlay {
            if session.showShortcuts {
                ZStack {
                    // Click anywhere outside the card to close it.
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { session.showShortcuts = false }
                        .arrowCursorOnHover()
                    ShortcutsSheet { session.showShortcuts = false }
                        .arrowCursorOnHover()
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: session.showShortcuts)
        .overlay {
            if session.showingTabs, let window = session.textView?.window {
                TabOverview(session: session, window: window)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.showingTabs)
        .sheet(isPresented: $session.showAISetup) { AISetupSheet() }
        .focusedSceneValue(\.editorSession, session)
        .onAppear {
            session.undoManager = undoManager
            // Write edits to disk within a couple of seconds instead of the
            // system default, so there's never much unsaved work. (Set here:
            // the document controller isn't ready while the app launches.)
            NSDocumentController.shared.autosavingDelay = 2
            if !UserDefaults.standard.bool(forKey: "tourSeen") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { session.startTour() }
            }
        }
        .onChange(of: undoManager) { _, manager in session.undoManager = manager }
        .task(id: fileURL) {
            // List the file under File → Open Recent and on the welcome window.
            if let fileURL { NSDocumentController.shared.noteNewRecentDocumentURL(fileURL) }
        }
        #if DEBUG
        .onChange(of: session.debugShowFileTitle) { _, show in showFileTitle = show }
        #endif
        .onChange(of: zoom.scale) { _, _ in
            guard session.textView?.window?.isKeyWindow == true else { return }
            zoomHintToken += 1
            let token = zoomHintToken
            withAnimation(.easeOut(duration: 0.15)) { showZoomHint = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard token == zoomHintToken else { return }
                withAnimation(.easeOut(duration: 0.5)) { showZoomHint = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TabsModel.tabSwitched)) { note in
            // In zen the tab strip is hidden: name the tab ⌃Tab landed on.
            guard session.zen != nil, let window = session.textView?.window, note.object as? NSWindow === window,
                  let tabs = window.tabGroup?.windows, let index = tabs.firstIndex(of: window) else { return }
            tabHintToken += 1
            let token = tabHintToken
            withAnimation(.easeOut(duration: 0.15)) { tabHint = "\(TabInfo(window: window).title) · \(index + 1) of \(tabs.count)" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard token == tabHintToken else { return }
                withAnimation(.easeOut(duration: 0.5)) { tabHint = nil }
            }
        }
        .onChange(of: session.zen != nil) { _, inZen in
            withAnimation(.easeOut(duration: 0.3)) { showZenHint = inZen }
            if inZen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    withAnimation(.easeOut(duration: 0.8)) { showZenHint = false }
                }
            }
        }
        .onChange(of: session.previewing) { _, previewing in
            if previewing {
                session.textView?.window?.makeFirstResponder(nil)
            } else if let tv = session.textView {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    /// The zoom level, shown briefly after ⌘+ / ⌘- / ⌘0.
    @ViewBuilder
    private var zoomHint: some View {
        if showZoomHint {
            Text("\(zoom.percent)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.panel))
                .overlay(Capsule().strokeBorder(Color.hairline))
                .padding(.top, 48)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// The tab you switched to, shown briefly in zen (where the tab strip is hidden).
    @ViewBuilder
    private var tabHintView: some View {
        if let tabHint {
            Text(tabHint)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.panel))
                .overlay(Capsule().strokeBorder(Color.hairline))
                .padding(.top, 18)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// A brief "how to leave" note when zen starts, then nothing.
    @ViewBuilder
    private var zenHint: some View {
        if showZenHint {
            Text("Zen · \(AppShortcut.zen.label) to return")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.panel))
                .overlay(Capsule().strokeBorder(Color.hairline))
                .padding(.top, 18)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// True when this window shows Redraft's tab strip (two or more tabs).
    private var hasTabs: Bool {
        _ = tabs.tick
        return (session.textView?.window?.tabGroup?.windows.count ?? 0) > 1
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // The tabs take whatever room the status items on the right leave.
            // In zen the tabs step aside; ⌃Tab and Show All Tabs still reach them.
            TabStrip(window: { session.textView?.window }, export: { session.exportCleanCopy() })
                .padding(.leading, 66)  // clear of the window buttons
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(session.zen == nil ? 1 : 0)
                .allowsHitTesting(session.zen == nil)
            HStack(spacing: 12) {
                if let busy = session.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(busy)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.inkSecondary)
                }
                UpdatePill()
                if fileURL == nil {
                    Button {
                        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color.inkSecondary.opacity(0.7)).frame(width: 5, height: 5)
                            Text("Not saved")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("This document isn't saved to a file yet. Click to choose a name and folder (⌘S).")
                }
                if let vim = session.vimStatus, !session.previewing {
                    Text(vim)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(vim.hasPrefix("INSERT") ? Color.inkSecondary.opacity(0.6) : Color.accent)
                }
                if session.previewing {
                    Text("Preview")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
                Button {
                    session.featuresOn.toggle()
                } label: {
                    Text("\(session.wordCount) \(session.wordCount == 1 ? "word" : "words")")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(session.featuresOn ? Color.accent : wordCountHovered ? Color.ink : Color.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        // A soft fill on hover shows it's a button.
                        .background(Capsule().fill(
                            session.featuresOn ? Color.accent.opacity(wordCountHovered ? 0.17 : 0.1)
                                : Color.ink.opacity(wordCountHovered ? 0.07 : 0)
                        ))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { wordCountHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: wordCountHovered)
                .pointingHandOnHover()
                .tourAnchor(.wordCount)
                .help(session.featuresOn ? "Hide writing tools (\(AppShortcut.toggleTools.label))" : "Show writing tools (\(AppShortcut.toggleTools.label))")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// The writing tools, in the bottom-right corner. The last button opens
    /// and closes them; with the tools hidden it's all that shows, faint, and
    /// it fades away while you type until the pointer moves.
    private var toolBar: some View {
        HStack(spacing: 4) {
            if session.featuresOn {
                tools
                Rectangle().fill(Color.hairline).frame(width: 1, height: 16)
                    .transition(.opacity)
            }
            ToolButton(
                icon: session.featuresOn ? "chevron.right" : "pencil",
                active: false,
                help: session.featuresOn ? "Hide writing tools · \(AppShortcut.toggleTools.label)" : "Show writing tools · \(AppShortcut.toggleTools.label)"
            ) {
                session.featuresOn.toggle()
            }
            .tourAnchor(.toolsToggle)
        }
        .padding(4)
        .background(Capsule().fill(Color.panel.opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.hairline))
        .onHover { toolsHovered = $0 }
        .opacity(session.featuresOn || toolsHovered ? 1 : session.typingQuietly ? 0 : 0.55)
        .allowsHitTesting(session.featuresOn || !session.typingQuietly)
        .padding(14)
        .animation(.easeOut(duration: 0.22), value: session.featuresOn)
        .animation(.easeOut(duration: 0.3), value: session.typingQuietly)
        .animation(.easeOut(duration: 0.15), value: toolsHovered)
    }

    @ViewBuilder
    private var tools: some View {
        ToolButton(icon: "text.badge.plus", active: session.showAlternatives, help: "Alternatives · \(AppShortcut.alternatives.label)") {
            session.showAlternatives.toggle()
        }
        .tourAnchor(.alternativesButton)
        ToolButton(icon: "tray", active: session.rightPanel == .overflow, help: "Overflow drawer · \(AppShortcut.overflowPanel.label)") {
            session.rightPanel = session.rightPanel == .overflow ? nil : .overflow
        }
        .tourAnchor(.overflowButton)
        ToolButton(icon: "flask", active: session.rightPanel == .lab, help: "Lab: AI editing · \(AppShortcut.labPanel.label)") {
            session.rightPanel = session.rightPanel == .lab ? nil : .lab
        }
        .tourAnchor(.labButton)
        ToolButton(icon: "eye", active: session.previewing, help: "Preview · \(AppShortcut.preview.label)") {
            session.previewing.toggle()
        }
        .tourAnchor(.previewButton)
    }

    @ViewBuilder
    private var errorToast: some View {
        if let message = session.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.accent)
                Text(message).font(.system(size: 12)).foregroundStyle(Color.ink)
                SettingsLink { Text("Settings").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(ToastButtonStyle(tint: Color.accent))
                    .simultaneousGesture(TapGesture().onEnded { SettingsView.showAITab() })
                    .pointingHandOnHover()
                Button { session.errorMessage = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(ToastButtonStyle(tint: Color.inkSecondary))
                    .pointingHandOnHover()
                    .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.panel))
            .overlay(Capsule().strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            .padding(.bottom, 64)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// A small text or icon button in a toast: a soft highlight on hover, a
/// little darker when pressed.
private struct ToastButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(tint: tint, pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverHighlight<Label: View>: View {
        let tint: Color
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hovering = false

        var body: some View {
            label()
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(pressed ? 0.22 : hovering ? 0.12 : 0)))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct ToolButton: View {
    let icon: String
    let active: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(active ? Color.accent : Color.inkSecondary)
                .frame(width: 28, height: 26)
                .background(Circle().fill(active ? Color.accent.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLabel(help)
    }
}

/// An instant label above a control while the pointer is over it, with a
/// small arrow pointing at the control. Labels sit centered above their
/// control and slide inward just enough to stay inside the window; the arrow
/// keeps pointing at the control. `extendsLeft` grows one leftward instead.
private struct HoverLabel: ViewModifier {
    let text: String
    let extendsLeft: Bool
    @State private var hovering = false
    @State private var controlFrame: CGRect = .zero
    @State private var labelWidth: CGFloat = 0

    /// Debug builds: REDRAFT_SHOW_HOVER_LABELS shows every label, for layout checks.
    private static var debugShowAll: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["REDRAFT_SHOW_HOVER_LABELS"] != nil
        #else
        false
        #endif
    }

    /// How far to slide the capsule so it fits inside the window (8pt margin).
    private var shift: CGFloat {
        guard !extendsLeft, labelWidth > 0,
              let windowWidth = NSApp.keyWindow?.contentLayoutRect.width else { return 0 }
        let center = controlFrame.midX
        let overRight = center + labelWidth / 2 - (windowWidth - 8)
        let overLeft = 8 - (center - labelWidth / 2)
        if overRight > 0 { return -overRight }
        if overLeft > 0 { return overLeft }
        return 0
    }

    func body(content: Content) -> some View {
        content
            .background(Circle().fill(hovering ? Color.ink.opacity(0.06) : .clear))
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { controlFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, frame in controlFrame = frame }
            })
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
            .pointingHandOnHover()
            .overlay(alignment: extendsLeft ? .topTrailing : .top) {
                if hovering || Self.debugShowAll {
                    VStack(alignment: extendsLeft ? .trailing : .center, spacing: 0) {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.panel))
                            .overlay(Capsule().strokeBorder(Color.hairline))
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { labelWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { _, width in labelWidth = width }
                            })
                            .offset(x: shift)
                        Arrow()
                            .fill(Color.panel)
                            .overlay(Arrow().stroke(Color.hairline, lineWidth: 1))
                            .frame(width: 10, height: 5)
                            // Under the control's center (controls are 28pt wide).
                            .padding(.trailing, extendsLeft ? 9 : 0)
                            .offset(y: -1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .fixedSize()
                    .offset(y: -36)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .allowsHitTesting(false)
                }
            }
    }
}

/// The small downward pointer under a hover label.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

extension View {
    func hoverLabel(_ text: String, extendsLeft: Bool = false) -> some View {
        modifier(HoverLabel(text: text, extendsLeft: extendsLeft))
    }
}

/// Views floating over the text view would otherwise inherit its I-beam
/// cursor. While the pointer is over one, the text view shows this instead.
/// A button inside an arrow region (e.g. Next on the tour card) wins.
enum PointerOverride {
    fileprivate static var handRegions = 0
    fileprivate static var arrowRegions = 0

    static var cursor: NSCursor? {
        handRegions > 0 ? .pointingHand : arrowRegions > 0 ? .arrow : nil
    }

    fileprivate static func apply() {
        (cursor ?? .arrow).set()
    }
}

private struct CursorOnHover: ViewModifier {
    let hand: Bool
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !inside {
                        inside = true
                        if hand { PointerOverride.handRegions += 1 } else { PointerOverride.arrowRegions += 1 }
                    }
                    PointerOverride.apply()
                case .ended:
                    leave()
                }
            }
            .onDisappear { leave() }
    }

    private func leave() {
        guard inside else { return }
        inside = false
        if hand { PointerOverride.handRegions -= 1 } else { PointerOverride.arrowRegions -= 1 }
        PointerOverride.apply()
    }
}

extension View {
    /// A pointing hand over buttons that float above the text.
    func pointingHandOnHover() -> some View { modifier(CursorOnHover(hand: true)) }
    /// The plain arrow over non-text overlays (like the tour's backdrop).
    func arrowCursorOnHover() -> some View { modifier(CursorOnHover(hand: false)) }
}
