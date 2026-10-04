#if DEBUG
import AppKit
import SwiftUI
import Markdown

/// Debug-only automation so the UI can be exercised and checked from the
/// command line without synthetic input or screen-recording access.
///
/// Launch with `REDRAFT_SCRIPT=/path/to/script` (via `open --env`). Each
/// line is one step, run in order on the frontmost document's session:
///
///     wait 0.5              pause
///     snap /tmp/shot.png    write the window to a PNG
///     features on|off       writing tools
///     hover <group-id>      pretend the pointer rests on a group
///     cycle <group-id> <n>  arrow through alternates
///     activate <group-id>   open the alternatives panel on a group
///     add <group-id> text   add a written alternative
///     panel overflow|lab|none
///     alternatives on|off
///     preview on|off
///     select <start> <len>  set the selection
///     ghost | stash         act on the selection
///     insert <text>         type into the page
///     undo | redo           Edit → Undo / Redo
///     shortcut <name>       an app shortcut's command, e.g. `shortcut moveUp`
///     menu <title>          choose a main menu item by its title
///     watchedits <path>     log each edit to the text from then on
///     newline | tab | backtab   Return, Tab, Shift-Tab in the page
///     link [address] | pastelink <address>   ⌘K, or paste an address over the selection
///     revert                reload the file from disk
///     dump /tmp/out.md      write what Save would write
///     ai <group-id>         ask AI for alternatives
///     trim 10|20|30|50      run a Lab trim
///     review convoluted|tone
///     idle <max-seconds>    wait until AI work finishes
///     log /tmp/state.txt    write AI results and errors
///     vim <keys>            type Vim keys, e.g. `vim dw` or `vim A more<Esc>`
///     text <path> <label>   append the text, mode and caret to a file
@MainActor private func allText(in view: NSView) -> [String] {
    var result: [String] = []
    if let field = view as? NSTextField, !field.stringValue.isEmpty { result.append(field.stringValue) }
    for sub in view.subviews { result += allText(in: sub) }
    return result
}

/// Frame-by-frame capture of this app's windows only, for checking transitions.
@MainActor enum Recorder {
    private typealias FromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    private static var frames: [CGImage] = []

    static func start(dir: String, frame: NSRect, seconds: Double) {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImageFromArray") else { return }
        let capture = unsafeBitCast(symbol, to: FromArray.self)
        // Screen coordinates for CoreGraphics run top-down from the main screen's top.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: frame.minX, y: screenH - frame.maxY, width: frame.width, height: frame.height)
        frames = []
        let end = Date().addingTimeInterval(seconds)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let ids = NSApp.orderedWindows.filter { $0.isVisible }.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
                var pointers = ids
                let array = CFArrayCreate(nil, &pointers, pointers.count, nil)!
                if let image = capture(rect, array, 1 << 0 /* boundsIgnoreFraming */)?.takeRetainedValue() { frames.append(image) }
                if Date() > end {
                    timer.invalidate()
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    for (i, image) in frames.enumerated() {
                        let rep = NSBitmapImageRep(cgImage: image)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/%03d.png", dir, i)))
                    }
                    frames = []
                }
            }
        }
    }
}

enum DebugSnapshot {
    private static var sessions = NSHashTable<EditorSession>.weakObjects()
    private static var watcher: NSObjectProtocol?

    @MainActor static func register(_ session: EditorSession) {
        sessions.add(session)
    }

    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let prefix = env["REDRAFT_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                    snap(window, to: "\(prefix)-\(i).png")
                }
            }
        }
        if let path = env["REDRAFT_SCRIPT"], let script = try? String(contentsOfFile: path, encoding: .utf8) {
            let steps = script.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { run(steps[...]) }
        }
    }

    @MainActor private static func run(_ steps: ArraySlice<String>, waited: Int = 0) {
        guard let step = steps.first else { return }
        // Wait (up to ~15s) for a document window before running steps, so a
        // slow launch doesn't silently skip them.
        if sessions.allObjects.first(where: { $0.textView?.window?.isVisible == true }) == nil, waited < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(steps, waited: waited + 1) }
            return
        }
        let rest = steps.dropFirst()
        let parts = step.split(separator: " ", maxSplits: 2).map(String.init)
        var delay = 0.35
        if let session = sessions.allObjects.first(where: { $0.textView?.window?.isVisible == true }) {
            switch parts[0] {
            case "wait": delay = Double(parts[safe: 1] ?? "") ?? 0.5
            case "snap": if let w = NSApp.keyWindow ?? session.textView?.window { snap(w, to: parts[1]) }
            case "features": session.featuresOn = parts[safe: 1] == "on"
            case "zen": session.toggleZen()
            case "newdoc": NSDocumentController.shared.newDocument(nil)
            case "exportclean":
                // exportclean <path>: write what Export Clean Copy writes (Markdown and HTML).
                let md = session.exportMarkdown()
                try? md.write(toFile: parts[1], atomically: true, encoding: .utf8)
                try? MarkdownPreview.page(HTMLFormatter.format(md), title: "Test").write(toFile: parts[1] + ".html", atomically: true, encoding: .utf8)
            case "copyrich":
                // copyrich <path>: copy rich text to a private pasteboard and write what's on it
                // (<path>.html, <path>.rtf, <path>.txt), leaving the real clipboard alone.
                let board = NSPasteboard(name: NSPasteboard.Name("com.brettsmith.Redraft.debug"))
                session.copyRichText(to: board)
                try? board.string(forType: .html)?.write(toFile: parts[1] + ".html", atomically: true, encoding: .utf8)
                try? board.data(forType: .rtf)?.write(to: URL(fileURLWithPath: parts[1] + ".rtf"))
                try? board.string(forType: .string)?.write(toFile: parts[1] + ".txt", atomically: true, encoding: .utf8)
                board.releaseGlobally()
            case "plaintext":
                // plaintext <path>: write what Post to X would post.
                try? session.plainText().write(toFile: parts[1], atomically: true, encoding: .utf8)
            case "filetitle": session.debugShowFileTitle = parts[safe: 1] != "off"
            case "rename":
                // rename <new file name>: move the document like the popover does.
                if let document = session.textView?.window?.windowController?.document as? NSDocument, let url = document.fileURL {
                    let target = url.deletingLastPathComponent().appendingPathComponent(step.dropFirst(7).description)
                    document.move(to: target) { error in if let error { NSLog("rename failed: \(error)") } }
                }
            case "zoom":
                switch parts[safe: 1] {
                case "in": Zoom.shared.zoomIn()
                case "out": Zoom.shared.zoomOut()
                default: Zoom.shared.reset()
                }
            case "snapall":
                // snapall <prefix>: every visible window, as <prefix>-<title>.png
                for window in NSApp.windows where window.isVisible {
                    snap(window, to: "\(parts[1])-\(window.title.replacingOccurrences(of: " ", with: "_")).png")
                }
            case "windows":
                // windows <path>: list windows, sheets and alerts.
                var out = ""
                for w in NSApp.windows where w.isVisible {
                    out += "\(type(of: w)) '\(w.title)' sheet=\(w.isSheet) attached=\(w.attachedSheet.map { String(describing: type(of: $0)) } ?? "-")\n"
                    if let sheet = w.attachedSheet {
                        let texts = sheet.contentView.map { allText(in: $0) } ?? []
                        out += "   sheet text: \(texts.joined(separator: " | "))\n"
                    }
                }
                try? out.write(toFile: parts[1], atomically: true, encoding: .utf8)
            case "hover": session.textView?.debugHover(parts[safe: 1])
            case "cycle": session.cycle(groupID: parts[1], by: Int(parts[safe: 2] ?? "1") ?? 1)
            case "activate": session.activate(parts[1])
            case "add": session.addOption(groupID: parts[1], text: parts[safe: 2] ?? "", source: .human)
            case "panel": session.rightPanel = RightPanel(rawValue: parts[safe: 1] ?? "")
            case "alternatives": session.showAlternatives = parts[safe: 1] == "on"
            case "preview": session.previewing = parts[safe: 1] == "on"
            case "select":
                // select <start> <len>, or `select end` for the caret at the end.
                let start = parts[1] == "end" ? session.storage.length : Int(parts[1]) ?? 0
                session.textView?.setSelectedRange(NSRange(location: start, length: Int(parts[safe: 2] ?? "0") ?? 0))
            case "ghost": session.toggleGhost(range: nil)
            case "stash": session.stash(range: nil)
            case "insert":
                // insert <text>: type into this document's page, even while Redraft isn't in front.
                if let tv = session.textView { tv.insertText(step.dropFirst(7).description, replacementRange: tv.selectedRange()) }
            case "shortcut":
                // shortcut <name>: what an app shortcut does, e.g. `shortcut moveUp`.
                if let shortcut = AppShortcut.allCases.first(where: { "\($0)" == parts[safe: 1] }) { session.perform(shortcut) }
            case "target":
                // target <words|none>: set or clear the length target.
                session.setTarget(Int(parts[safe: 1] ?? ""))
            case "counts":
                // counts <path> <label>: append the word, selection and target counts and reading time.
                let line = "\(parts[safe: 2] ?? ""): words=\(session.wordCount) selected=\(session.selectionWords.map(String.init) ?? "-") target=\(session.doc.target.map(String.init) ?? "-") reading=\(ReadingTime.label(words: session.wordCount))\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
            case "menu":
                // menu <title>: choose a main menu item, e.g. `menu Length Target…`.
                let title = step.dropFirst(5).description
                func choose(in menu: NSMenu?) -> Bool {
                    for (i, item) in (menu?.items ?? []).enumerated() {
                        if item.title == title { menu?.performActionForItem(at: i); return true }
                        if choose(in: item.submenu) { return true }
                    }
                    return false
                }
                if !choose(in: NSApp.mainMenu) { NSLog("Redraft script: no menu item \(title)") }
            case "link", "pastelink":
                // link [address] / pastelink <address>: ⌘K, or pasting over the selection,
                // with the address on a private pasteboard (the real clipboard is left alone).
                let board = NSPasteboard(name: NSPasteboard.Name("com.brettsmith.Redraft.debug"))
                board.clearContents()
                if let address = parts[safe: 1] { board.setString(address, forType: .string) }
                if parts[0] == "link" { session.insertLink(from: board) } else if !session.pasteLink(from: board) { NSLog("Redraft script: pasted as usual") }
                board.releaseGlobally()
            case "placeholders":
                // placeholders <path> <label>: append the TK count and where each one is.
                let line = "\(parts[safe: 2] ?? ""): count=\(session.placeholderCount) at=\(session.placeholders().map(\.location)) selection=\(session.textView?.selectedRange() ?? NSRange())\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
            case "nexttk": session.goToNextPlaceholder()
            case "zenwriting":
                // zenwriting on|off: zen's focus and typewriter scrolling, without going full screen.
                session.zen = parts[safe: 1] == "off" ? nil : ZenState(enteredFullScreen: false)
            case "caretheight":
                // caretheight <path> <label>: append where the caret sits on the screen (0 top, 1 bottom).
                if let tv = session.textView, let clip = tv.enclosingScrollView?.contentView {
                    let caret = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
                    let window = tv.window?.convertFromScreen(caret) ?? .zero
                    let inClip = clip.convert(window, from: nil)
                    let line = String(format: "%@: caret at %.2f of the screen, scrolled %.0f, focus %@\n", parts[safe: 2] ?? "",
                                      (inClip.midY - clip.bounds.minY) / clip.bounds.height, clip.bounds.minY,
                                      session.focusRange.map { NSStringFromRange($0) } ?? "none")
                    if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
                }
            case "watchedits":
                // watchedits <path>: from now on, append each edit to the text (what and where).
                let path = parts[1]
                FileManager.default.createFile(atPath: path, contents: nil)
                watcher = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: session.storage, queue: nil) { note in
                    guard let ts = note.object as? NSTextStorage else { return }
                    let what = ts.editedMask.contains(.editedCharacters) ? "characters" : "attributes"
                    let line = "\(what) \(NSStringFromRange(ts.editedRange)) change \(ts.changeInLength)\n"
                    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                }
            case "newline": session.textView?.insertNewline(nil)
            case "tab": session.textView?.insertTab(nil)
            case "backtab": session.textView?.insertBacktab(nil)
            case "undo": session.undoManager?.undo()
            case "redo": session.undoManager?.redo()
            case "revert":
                // Reload the file from disk, as when another app changed it.
                if let document = session.textView?.window?.windowController?.document as? NSDocument,
                   let url = document.fileURL, let type = document.fileType {
                    do { try document.revert(toContentsOf: url, ofType: type) } catch { NSLog("revert failed: \(error)") }
                }
            case "dump":
                let text = MarkdownCodec.encode(storage: session.doc.storage, groups: session.doc.groups,
                                                overflow: session.doc.overflow.string, target: session.doc.target)
                try? text.write(toFile: parts[1], atomically: true, encoding: .utf8)
            case "ai": session.aiAlternatives(groupID: parts[1])
            case "trim": session.runLabTool(LabToolStore.shared.tools.first { $0.id == "trim\(parts[safe: 1] ?? "10")" } ?? LabTool.presets[2])
            case "review": session.runLabTool(LabToolStore.shared.tools.first { $0.id == (parts[safe: 1] == "tone" ? "tone" : "convoluted") }!)
            case "labeditor":
                // labeditor <tool-id|new> <path>: render the tool editor offscreen.
                if let which = parts[safe: 1], let path = parts[safe: 2] {
                    let tool = LabToolStore.shared.tools.first { $0.id == which } ?? .blank()
                    let host = NSHostingView(rootView: LabToolEditor(tool: tool, onRun: { _ in }).background(Color(nsColor: .windowBackgroundColor)))
                    host.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
                    host.appearance = session.textView?.effectiveAppearance
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            case "idle":
                let deadline = Date().addingTimeInterval(Double(parts[safe: 1] ?? "") ?? 120)
                waitIdle(session, until: deadline) { run(rest) }
                return
            case "textchecks":
                let on = parts[safe: 1] == "on"
                session.textView?.isAutomaticTextReplacementEnabled = on
                session.textView?.isAutomaticSpellingCorrectionEnabled = on
                session.textView?.isContinuousSpellCheckingEnabled = on
                session.textView?.isAutomaticQuoteSubstitutionEnabled = on
                session.textView?.isAutomaticDashSubstitutionEnabled = on
                session.textView?.isAutomaticTextCompletionEnabled = on
                session.textView?.smartInsertDeleteEnabled = on
            case "undoinfo":
                if let um = session.textView?.undoManager {
                    let line = "\(parts[safe: 2] ?? ""): groupsByEvent=\(um.groupsByEvent) level=\(um.groupingLevel) canUndo=\(um.canUndo)\n"
                    if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
                }
            case "tour":
                if let n = Int(parts[safe: 1] ?? "") {
                    if n < 0 { session.endTour() } else {
                        if TourStep.all.indices.contains(n), TourStep.all[n].needsTools { session.featuresOn = true }
                        session.tourStep = n
                    }
                }
            case "cmdkey", "optcmdkey":
                // cmdkey <char> / optcmdkey <char>: send ⌘<char> or ⌥⌘<char> through the main menu.
                if let tv = session.textView, let char = parts[safe: 1],
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: parts[0] == "optcmdkey" ? [.command, .option] : [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: tv.window?.windowNumber ?? 0, context: nil,
                                                characters: char, charactersIgnoringModifiers: char,
                                                isARepeat: false, keyCode: 44) {
                    _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
                }
            case "shortcutsopen":
                // shortcutsopen <path> <label>: append whether the shortcuts card is showing.
                let line = "\(parts[safe: 2] ?? ""): showShortcuts=\(session.showShortcuts)\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            case "hideshortcuts": session.showShortcuts = false
            case "rec":
                // rec <dir> <seconds>: capture Redraft's own windows (over the
                // front window's frame) about 60 times a second, as <dir>/NNN.png.
                if let dir = parts[safe: 1], let frame = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame {
                    Recorder.start(dir: dir, frame: frame, seconds: Double(parts[safe: 2] ?? "") ?? 1)
                }
            case "viewtree":
                // viewtree <path>: the front window's frame view hierarchy, by class.
                var out = ""
                func walk(_ v: NSView, _ depth: Int) {
                    out += String(repeating: "  ", count: depth) + "\(type(of: v)) hidden=\(v.isHidden) \(v.frame)\n"
                    if depth < 6 { v.subviews.forEach { walk($0, depth + 1) } }
                }
                if let frameView = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView?.superview { walk(frameView, 0) }
                try? out.write(toFile: parts[1], atomically: true, encoding: .utf8)
            case "mouse":
                // mouse down|drag|up <x> <y>: a left-button event at a point in the
                // front window, measured from its top-left corner.
                let bits = step.split(separator: " ").map(String.init)
                if let w = NSApp.keyWindow ?? NSApp.mainWindow, bits.count >= 4, let x = Double(bits[2]), let y = Double(bits[3]) {
                    let type: NSEvent.EventType = bits[1] == "down" ? .leftMouseDown : bits[1] == "up" ? .leftMouseUp : .leftMouseDragged
                    let point = NSPoint(x: x, y: w.frame.height - y)
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        w.sendEvent(event)
                    }
                }
                delay = 0.03
            case "winframe":
                let line = "\(parts[safe: 2] ?? ""): \(NSStringFromRect((NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? .zero)) overview=\(session.showingTabs)\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
            case "key":
                // key <keyCode> <chars> [cmd][shift][opt]: a key press through the
                // app, as if typed (menus and key monitors see it).
                let bits = step.split(separator: " ").map(String.init)
                if let w = NSApp.keyWindow ?? NSApp.mainWindow, bits.count >= 3, let code = UInt16(bits[1]) {
                    let mods = bits.count > 3 ? bits[3] : ""
                    var flags: NSEvent.ModifierFlags = []
                    if mods.contains("cmd") { flags.insert(.command) }
                    if mods.contains("shift") { flags.insert(.shift) }
                    if mods.contains("opt") { flags.insert(.option) }
                    let chars = bits[2] == "esc" ? "\u{1b}" : bits[2] == "ret" ? "\r" : bits[2]
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                    context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.sendEvent(event)
                    }
                }
            case "quit": NSApp.terminate(nil)
            case "newtab": WindowTabs.newTab()
            case "nexttab": (NSApp.keyWindow ?? NSApp.mainWindow)?.selectNextTab(nil)
            case "zenstate":
                // zenstate <path> <label>: each tab's zen and full screen state.
                var line = "\(parts[safe: 2] ?? ""):"
                for w in NSApp.windows where w.windowController?.document != nil {
                    line += " ['\(w.title)' zen=\(EditorSession.session(for: w)?.zen != nil) full=\(w.styleMask.contains(.fullScreen)) key=\(w.isKeyWindow) accessoriesHidden=\(w.titlebarAccessoryViewControllers.map(\.isHidden))]"
                }
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
            case "geom":
                // geom <path> <label>: the page's frame, scroll and first line.
                if let tv = session.textView, let lm = tv.layoutManager, let clip = tv.enclosingScrollView?.contentView {
                    let line = lm.numberOfGlyphs > 0 ? lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil) : .zero
                    let text = "\(parts[safe: 2] ?? ""): frame=\(NSStringFromRect(tv.frame)) clip=\(NSStringFromRect(clip.bounds)) inset=\(NSStringFromSize(tv.textContainerInset)) line0=\(NSStringFromRect(line))\n"
                    if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
                }
            case "open":
                // open <path>: what ⌘O does once a file is chosen.
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: step.dropFirst(5).description), display: true) { _, _, _ in }
            case "type":
                // type <text>: insert text at the caret, as typing would.
                if let tv = EditorSession.frontmost?.textView { tv.insertText(step.dropFirst(5).description, replacementRange: tv.selectedRange()) }
            case "movetab":
                // movetab <from> <to>: reorder tabs of the front window's group.
                if let group = (NSApp.keyWindow ?? NSApp.mainWindow)?.tabGroup,
                   let from = Int(parts[safe: 1] ?? ""), let to = Int(parts[safe: 2] ?? ""), group.windows.indices.contains(from) {
                    WindowTabs.move(group.windows[from], to: to)
                }
            case "taborder":
                let group = (NSApp.keyWindow ?? NSApp.mainWindow)?.tabGroup
                let line = "\(parts[safe: 2] ?? ""): \(group?.windows.map(\.title) ?? []) selected=\(group?.selectedWindow?.title ?? "-") visibleWindows=\(NSApp.windows.filter { $0.isVisible && $0.windowController?.document != nil }.count)\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            case "arrived":
                let line = "\(parts[safe: 2] ?? ""): arrivedTabbed=\(String(describing: WindowTabs.debugArrivedTabbed))\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            case "overview":
                session.showingTabs = parts[safe: 1] != "off"
            case "newdocplain": NSDocumentController.shared.newDocument(nil)
            case "overviewplus":
                // What the + in Show All Tabs sends.
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            case "tabstate":
                // tabstate <path> <label>: the tab group's bar state for each document window.
                var line = "\(parts[safe: 2] ?? ""):"
                for w in NSApp.windows where w.windowController?.document != nil {
                    line += " ['\(w.title)' tabs=\(w.tabGroup?.windows.count ?? 0) barVisible=\(w.tabGroup?.isTabBarVisible ?? false) layoutH=\(Int(w.contentLayoutRect.height)) contentH=\(Int(w.contentView?.bounds.height ?? 0))]"
                }
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
            case "togglebar": (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleTabBar(nil)
            case "parseopenai":
                // parseopenai <in.json> <out>: run the model filter on a saved /v1/models response.
                if let data = FileManager.default.contents(atPath: parts[1]),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ids = OpenAIModels.parse(json).map(\.id).joined(separator: "\n")
                    try? (ids + "\n").write(toFile: parts[safe: 2] ?? "/dev/null", atomically: true, encoding: .utf8)
                }
            case "anthropicraw":
                // anthropicraw <path>: the model list's field names and entries (never the key).
                let path = parts[1]
                Task {
                    guard let key = APIKeyStore.anthropic.key else { try? "no key\n".write(toFile: path, atomically: true, encoding: .utf8); return }
                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
                    request.setValue(key, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    let (data, response) = (try? await URLSession.shared.data(for: request)) ?? (Data(), URLResponse())
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                    let list = json["data"] as? [[String: Any]] ?? []
                    var out = "status: \((response as? HTTPURLResponse)?.statusCode ?? 0)\nerror: \((json["error"] as? [String: Any])?["message"] ?? "-")\ntop-level keys: \(json.keys.sorted())\ncount: \(list.count)\n"
                    if let first = list.first { out += "fields: \(first.keys.sorted())\nfirst: \(first)\n" }
                    out += list.map { "\($0["id"] ?? "?")  |  \($0["display_name"] ?? "")" }.joined(separator: "\n") + "\n"
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            case "loadmodels":
                Task { await AnthropicModels.shared.load(); await OpenAIModels.shared.load() }
            case "openaimodels":
                // openaimodels <path>: load the OpenAI key's models and write the parsed list.
                let path = parts[1]
                Task {
                    await OpenAIModels.shared.load()
                    let m = OpenAIModels.shared
                    let out = "error: \(m.lastError ?? "none")\ncount: \(m.models.count)\n" + m.models.map { "\($0.id)  levels=\($0.levels)" }.joined(separator: "\n") + "\n"
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            case "topchar":
                // topchar <path> <label>: append the character at the top of the page and the scroll offset.
                if let tv = session.textView {
                    let line = "\(parts[safe: 2] ?? ""): top=\(tv.debugTopCharacter()) y=\(Int(tv.visibleRect.minY)) view=\(UInt(bitPattern: ObjectIdentifier(tv).hashValue) % 100000) caret=\(tv.selectedRange().location)\n"
                    if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                }
            case "scrollto":
                // scrollto <character>: put that character's line at the top of the page.
                if let tv = session.textView, let lm = tv.layoutManager, let loc = Int(parts[safe: 1] ?? "") {
                    let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: loc), effectiveRange: nil)
                    tv.scroll(NSPoint(x: 0, y: rect.minY + tv.textContainerOrigin.y))
                }
            case "bgcheck": Updates.shared.updater.checkForUpdatesInBackground()
            case "checkupdates": Updates.shared.checkForUpdates()
            case "closeall":
                for window in NSApp.windows where window.windowController?.document != nil { window.performClose(nil) }
            case "docs":
                // docs <path> <label>: append open documents, their caret and the windows.
                var line = "\(parts[safe: 2] ?? ""):"
                for s in sessions.allObjects where s.textView?.window?.isVisible == true {
                    let name = (s.textView?.window?.windowController?.document as? NSDocument)?.fileURL?.lastPathComponent ?? "untitled"
                    line += " [\(name) caret=\(s.textView?.selectedRange().location ?? -1)]"
                }
                line += " windows=\(NSApp.windows.filter(\.isVisible).map(\.title))\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            case "appfront": NSApp.activate(ignoringOtherApps: true)
            case "front":
                NSApp.activate(ignoringOtherApps: true)
                session.textView?.window?.makeKeyAndOrderFront(nil)
            case "menuitem":
                // menuitem <path> <title>: append a menu item's key equivalent and state.
                let title = step.split(separator: " ", maxSplits: 2).dropFirst(2).joined()
                func find(_ menu: NSMenu?) -> NSMenuItem? {
                    for item in menu?.items ?? [] {
                        if item.title == title { return item }
                        if let hit = find(item.submenu) { return hit }
                    }
                    return nil
                }
                let item = find(NSApp.mainMenu)
                let line = "\(title): key='\(item?.keyEquivalent ?? "-")' mods=\(item?.keyEquivalentModifierMask.rawValue ?? 0) enabled=\(item?.isEnabled ?? false) key-window=\(NSApp.keyWindow?.title ?? "none")\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            case "ctrlshift":
                // ctrlshift <letter|up|down>: send ⌃⇧<key> through the editor's keyDown.
                let arrows = ["up": ("\u{F700}", UInt16(126)), "down": ("\u{F701}", UInt16(125))]
                if let tv = session.textView, let name = parts[safe: 1],
                   case let (letter, code) = arrows[name] ?? (name, 0),
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: tv.window?.windowNumber ?? 0, context: nil,
                                                characters: letter, charactersIgnoringModifiers: letter,
                                                isARepeat: false, keyCode: code) {
                    tv.keyDown(with: event)
                }
            case "state":
                // state <path> <label>: append tools/panel/vim state and text length.
                let line = "\(parts[safe: 2] ?? ""): tools=\(session.featuresOn) alts=\(session.showAlternatives) right=\(session.rightPanel?.rawValue ?? "none") preview=\(session.previewing) setup=\(session.showAISetup) error=\(session.errorMessage ?? "-") busy=\(session.busy ?? "-") zen=\(session.zen != nil) full=\(session.textView?.window?.styleMask.contains(.fullScreen) == true) vim=\(session.vimStatus ?? "off") len=\(session.storage.length)\n"
                if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
            case "modelsraw":
                let path = parts[1]
                Task { await ChatGPTAuth.shared.debugDumpModels(to: path) }
            case "rendersounds":
                Sounds.shared.debugRenderAll(to: parts[1])
            case "snapview":
                // snapview settings <path>: render a view offscreen.
                if let named = parts[safe: 1], let path = parts[safe: 2] {
                    // A "-light" or "-dark" suffix picks the appearance.
                    let which = named.replacingOccurrences(of: "-light", with: "").replacingOccurrences(of: "-dark", with: "")
                    let root = which == "aisetup" ? AnyView(AISetupSheet()) : which == "filedetails"
                        ? AnyView(FileDetails(fileURL: URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Writing/Essays/The Case for Writing Slowly.md"), window: { nil }, close: {}, export: {}))
                        : AnyView(SettingsView())
                    let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
                    host.frame = which == "aisetup" ? NSRect(x: 0, y: 0, width: 380, height: 360) : which == "filedetails" ? NSRect(x: 0, y: 0, width: 420, height: 130) : NSRect(x: 0, y: 0, width: 540, height: 530)
                    host.appearance = named.hasSuffix("-light") ? NSAppearance(named: .aqua)
                        : named.hasSuffix("-dark") ? NSAppearance(named: .darkAqua) : session.textView?.effectiveAppearance
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            case "screenline":
                // screenline <path>: record where the first screen line ends for the caret's paragraph.
                if let tv = session.textView, let lm = tv.layoutManager {
                    var range = NSRange()
                    _ = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: tv.selectedRange().location), effectiveRange: &range)
                    let chars = lm.characterRange(forGlyphRange: range, actualGlyphRange: nil)
                    let line = "screen line chars \(chars.location)..<\(NSMaxRange(chars)) caret \(tv.selectedRange().location)\n"
                    if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
                }
            case "caret":
                // caret <path> <location> <label>
                if let tv = session.textView, let loc = Int(parts[safe: 2]?.split(separator: " ").first ?? "") {
                    let label = parts[safe: 2]?.split(separator: " ").dropFirst().joined(separator: " ") ?? ""
                    let line = "\(label) @\(loc): \(tv.debugCaretGeometry(at: loc))\n"
                    if let h = FileHandle(forWritingAtPath: parts[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[1], atomically: true, encoding: .utf8) }
                }
            case "log": writeLog(session, to: parts[1])
            case "vim":
                if let vim = session.textView?.vim {
                    vim.debugType(step.dropFirst(4).description) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { run(rest) }
                    }
                    return
                }
            case "text":
                // text <path> <label>: append label, mode, caret and the document text.
                if let tv = session.textView {
                    let entry = "== \(parts[safe: 2] ?? "")  [\(tv.vim.mode.rawValue) @\(tv.selectedRange().location)/\(tv.selectedRange().length)]\n\(tv.string)\n"
                    if let handle = FileHandle(forWritingAtPath: parts[1]) {
                        handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
                    } else {
                        try? entry.write(toFile: parts[1], atomically: true, encoding: .utf8)
                    }
                }
            default: NSLog("Redraft script: unknown step \(step)")
            }
        }
        // Real input arrives as events; post one so per-event behavior (like
        // automatic undo grouping) matches actual use.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(rest) }
    }

    @MainActor private static func waitIdle(_ session: EditorSession, until deadline: Date, then next: @escaping @MainActor () -> Void) {
        if (session.busy == nil && session.aiLoadingGroup == nil) || Date() > deadline {
            next()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitIdle(session, until: deadline, then: next) }
        }
    }

    @MainActor private static func writeLog(_ session: EditorSession, to path: String) {
        let auth = ChatGPTAuth.shared
        var lines = [
            "provider: \(AIClient.provider.rawValue)",
            "chatgpt connected: \(auth.isConnected) email: \(auth.connection?.email ?? "-")",
            "chatgpt models: \(auth.models.map(\.slug).joined(separator: ", "))",
            "chatgpt model: \(auth.currentModel ?? "-") effort: \(AISettings.effort(.chatGPT).isEmpty ? "automatic" : AISettings.effort(.chatGPT))",
            "last timing: first \(ResponsesStream.lastTiming?.first.map { String(format: "%.2fs", $0) } ?? "-") total \(ResponsesStream.lastTiming.map { String(format: "%.2fs", $0.total) } ?? "-")",
            "chatgpt lastError: \(auth.lastError ?? "-")",
            "chatgpt structured output: \(auth.structuredOutputUnsupported ? "fallback (prompted JSON)" : "strict json_schema")",
            "error: \(session.errorMessage ?? "-")",
            "labNote: \(session.labNote ?? "-")",
        ]
        for group in session.doc.groups.values.sorted(by: { $0.id < $1.id }) {
            lines.append("group \(group.id): " + group.options.map { "\($0.source == .ai ? "✦" : "•") \($0.text)" }.joined(separator: " | "))
        }
        for cut in session.cuts { lines.append("cut: \(cut.quote) — \(cut.reason)") }
        for finding in session.findings { lines.append("finding: \(finding.quote) — \(finding.note)") }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func snap(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
