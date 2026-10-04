import SwiftUI

@main
struct RedraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
        ShellCommand.setUpOnLaunch()
        Zoom.shared.installPlusKey()
        Updates.shared.start()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { WriterDocument() }) { file in
            // Reloading a file changed on disk replaces the document object;
            // rebuild the editor for the new one, or it would keep editing the old.
            ContentView(doc: file.document, fileURL: file.fileURL)
                .id(ObjectIdentifier(file.document))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 760)
        .commands { WriterCommands() }

        Settings {
            SettingsView()
        }
    }
}

struct EditorSessionKey: FocusedValueKey {
    typealias Value = EditorSession
}

extension FocusedValues {
    var editorSession: EditorSession? {
        get { self[EditorSessionKey.self] }
        set { self[EditorSessionKey.self] = newValue }
    }
}

struct WriterCommands: Commands {
    @FocusedValue(\.editorSession) private var focused
    /// The window being worked in. Falls back to the key window's session when
    /// SwiftUI hasn't reported focus, so menu shortcuts always reach it.
    private var session: EditorSession? { focused ?? EditorSession.frontmost }
    /// Read so the menus rebuild when the shortcut style changes.
    @AppStorage("shortcutStyle") private var shortcutStyle = AppShortcut.Style.command.rawValue

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            item("Show All Tabs", .allTabs)
            Divider()
            Button("Actual Size") { Zoom.shared.reset() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") { Zoom.shared.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { Zoom.shared.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") { WindowTabs.newTab() }
                .keyboardShortcut("t", modifiers: .command)
        }

        CommandGroup(replacing: .appInfo) {
            // The standard About, showing "Version 0.2.4" without the build
            // number (which only Sparkle needs).
            Button("About Redraft") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: version, .version: ""])
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.shared.checkForUpdates() }
        }

        CommandGroup(after: .appSettings) {
            Button("Install Shell Command…") { ShellCommand.installWithAlert() }
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Group {
                Button("Export Clean Copy…") { session?.exportCleanCopy() }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                item("Copy Clean Text", .copyClean)
                Button("Copy Rich Text") { session?.copyRichText() }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                Button("Post to X…") { session?.postToX() }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Take the Tour") { session?.startTour() }
            item("Keyboard Shortcuts", .shortcutsCard)
            Divider()
            Button("Open Practice Document") { PracticeDocument.open() }
            Divider()
            Button("Send Feedback…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/brettsmith212/redraft/issues/new")!)
            }
        }

        CommandMenu("Write") {
            Group {
                item("Toggle Writing Tools", .toggleTools)
                item("Preview Markdown", .preview)
                item("Zen Mode", .zen)
                Divider()
                Button("Bold") { session?.toggleEmphasis(bold: true) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { session?.toggleEmphasis(bold: false) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Link") { session?.insertLink() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                item("Alternatives", .alternatives)
                item("AI Alternatives for Selection", .aiAlternatives)
                item("Next Alternative", .nextAlternative)
                item("Previous Alternative", .previousAlternative)
                Divider()
                item("Ghost / Revive", .ghost)
                item("Stash in Overflow", .stash)
                Divider()
                item("Move Paragraph Up", .moveUp)
                item("Move Paragraph Down", .moveDown)
                Divider()
                Button("Length Target…") { session?.editingTarget = true }
            }
            Divider()
            Group {
                item("Overflow", .overflowPanel)
                item("Lab", .labPanel)
            }
        }
    }

    private func item(_ title: String, _ shortcut: AppShortcut) -> some View {
        Button(title) { session?.perform(shortcut) }
            .keyboardShortcut(shortcut)
    }
}
