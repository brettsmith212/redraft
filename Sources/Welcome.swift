import SwiftUI
import UniformTypeIdentifiers

/// App-level launch behavior:
/// - Quitting (⌘Q) reopens the windows you had, whatever the system's
///   "Close windows when quitting" setting; closing a window means it won't.
/// - With nothing to reopen, Redraft shows its welcome window instead of
///   the Finder open panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        // Set in the app's own domain so they win over the global settings.
        defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")
        defaults.set(false, forKey: "NSShowAppCentricOpenPanelInsteadOfUntitledFile")
        Self.routeEmptyLaunchesToWelcome()
        MainActor.assumeIsolated {
            WindowTabs.installHooks()
            AppearanceSetting.apply()
        }
    }

    /// SwiftUI's document apps answer "open a blank document?" themselves and
    /// don't forward it here, so give its app delegate our answer: with
    /// nothing to show (launch with nothing restored, or a Dock click with no
    /// windows), open the welcome window instead.
    private static func routeEmptyLaunchesToWelcome() {
        guard let delegate = NSApp.delegate else { return }
        let cls: AnyClass = type(of: delegate)

        let untitled: @convention(block) (AnyObject, NSApplication) -> Bool = { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { WelcomeWindow.show() } }
            return false
        }
        class_replaceMethod(cls, #selector(NSApplicationDelegate.applicationShouldOpenUntitledFile(_:)),
                            imp_implementationWithBlock(untitled), "B@:@")

        let reopen: @convention(block) (AnyObject, NSApplication, Bool) -> Bool = { _, _, hasVisibleWindows in
            if hasVisibleWindows { return true }
            DispatchQueue.main.async { MainActor.assumeIsolated { WelcomeWindow.show() } }
            return false
        }
        class_replaceMethod(cls, #selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)),
                            imp_implementationWithBlock(reopen), "B@:@B")

        // The + in Show All Tabs asks for a new tab; if the page didn't take
        // the request, answer it here too, so it's a tab, not a window.
        let newTab: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
            MainActor.assumeIsolated { WindowTabs.newTab() }
        }
        class_replaceMethod(cls, #selector(NSResponder.newWindowForTab(_:)),
                            imp_implementationWithBlock(newTab), "v@:@")
    }
}

/// The welcome window: new, open, and recent documents.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    private static var observer: NSObjectProtocol?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: WelcomeView())
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Redraft"
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 680, height: 420))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // Step aside as soon as a document window appears.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let other = note.object as? NSWindow, other !== WelcomeWindow.window,
                      other.windowController?.document != nil else { return }
                WelcomeWindow.close()
            }
        }
    }

    static func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window?.close()
        window = nil
    }
}

private struct RecentFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    var edited: Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}

struct WelcomeView: View {
    @State private var recents: [RecentFile] = []
    @State private var selection: URL?
    @State private var dropTargeted = false
    @FocusState private var listFocused: Bool
    private let firstRun = !UserDefaults.standard.bool(forKey: "tourSeen")

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
                .frame(maxHeight: .infinity)
                .background(Color.panel)
            Rectangle().fill(Color.hairline).frame(width: 1)
            recentList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.paper)
        }
        .frame(width: 680, height: 420)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in open(url) }
                }
            }
            return true
        }
        .onAppear(perform: loadRecents)
    }

    // MARK: Left: identity and actions

    private var sidebar: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 34)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Redraft")
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(Color.ink)
                .padding(.top, 10)
            Text(versionText)
                .font(.system(size: 11))
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 2)

            VStack(spacing: 6) {
                WelcomeAction(title: "New Document", icon: "square.and.pencil", keys: "⌘N") {
                    NSDocumentController.shared.newDocument(nil)
                }
                WelcomeAction(title: "Open…", icon: "folder", keys: "⌘O") {
                    NSDocumentController.shared.openDocument(nil)
                }
                if firstRun {
                    WelcomeAction(title: "Take the Tour", icon: "sparkles", keys: nil) {
                        PracticeDocument.open()
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            Spacer()
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty ? "" : "Version \(version)"
    }

    // MARK: Right: recent documents

    @ViewBuilder
    private var recentList: some View {
        if recents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color.inkSecondary.opacity(0.7))
                Text(firstRun ? "Welcome. Start a new document, or take the tour." : "No recent documents")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSecondary)
                Text("You can also drop a Markdown file here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.inkSecondary.opacity(0.8))
            }
            .padding(30)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 30)
                    .padding(.bottom, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(recents) { file in
                                RecentRow(file: file, selected: selection == file.url)
                                    .id(file.url)
                                    .onTapGesture(count: 2) { open(file.url) }
                                    .onTapGesture { selection = file.url }
                                    .contextMenu {
                                        Button("Open") { open(file.url) }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .onKeyPress(.downArrow) { move(1, proxy); return .handled }
                    .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
                    .onKeyPress(.return) {
                        if let selection { open(selection) }
                        return .handled
                    }
                }
            }
        }
    }

    private func loadRecents() {
        let fm = FileManager.default
        recents = NSDocumentController.shared.recentDocumentURLs
            .filter { fm.fileExists(atPath: $0.path) }
            .prefix(10)
            .map(RecentFile.init)
        selection = recents.first?.url
        listFocused = !recents.isEmpty
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) {
        guard !recents.isEmpty else { return }
        let index = recents.firstIndex { $0.url == selection } ?? 0
        let next = recents[min(max(index + step, 0), recents.count - 1)].url
        selection = next
        proxy.scrollTo(next)
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}

private struct RecentRow: View {
    let file: RecentFile
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(file.folder)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let edited = file.edited {
                Text(edited, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accent.opacity(0.16) : hovering ? Color.ink.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .help("Double-click or press Return to open")
    }
}

private struct WelcomeAction: View {
    let title: String
    let icon: String
    let keys: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accent)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                Spacer()
                if let keys {
                    Text(keys)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.ink.opacity(0.06) : Color.ink.opacity(0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
    }
}
