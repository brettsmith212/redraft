import AppKit
import SwiftUI

enum RightPanel: String {
    case overflow, lab
}

struct LabFinding: Identifiable, Equatable {
    let id: String
    let quote: String
    let note: String
}

struct CutProposal: Identifiable, Equatable {
    let id: String
    let quote: String
    let reason: String
}

/// One window's editing state and every operation the writing tools perform.
/// The document owns the text; the session knows how to change it well.
@MainActor
final class EditorSession: NSObject, ObservableObject {
    let doc: WriterDocument
    weak var textView: EditorTextView?
    weak var overflowView: NSTextView?
    weak var undoManager: UndoManager?

    /// The writing tools. Every document opens with them on; hiding them is a
    /// choice for this window only, so it isn't remembered.
    @Published var featuresOn: Bool = true {
        didSet {
            guard oldValue != featuresOn else { return }
            textView?.featuresOn = featuresOn
            restyleAlternatives()
        }
    }
    /// True while typing with the tools hidden: their button fades away
    /// until the pointer moves.
    @Published var typingQuietly = false
    @Published var showAlternatives = false {
        didSet { if showAlternatives { AIClient.prewarm() } }
    }
    @Published var rightPanel: RightPanel? {
        didSet { if rightPanel == .lab { AIClient.prewarm() } }
    }
    @Published var previewing = false
    @Published var activeGroupID: String?
    @Published var wordCount = 0
    /// Words in the selection, while there is one.
    @Published var selectionWords: Int?
    /// TK placeholders still to fill in (not counting ghosted ones).
    @Published var placeholderCount = 0
    /// The length target's editor is open.
    @Published var editingTarget = false
    @Published var busy: String?
    @Published var errorMessage: String?
    @Published var aiLoadingGroup: String?
    @Published var findings: [LabFinding] = []
    @Published var cuts: [CutProposal] = []
    @Published var labNote: String?
    @Published var focusAddField = 0
    @Published var vimStatus: String?
    @Published var tourStep: Int?
    @Published var showShortcuts = false
    /// Show All Tabs: this window's overview of its tabs.
    @Published var showingTabs = false {
        didSet { if showingTabs, !oldValue { captureTabPictures() } }
    }
    /// Pictures of this window's tabs, taken as Show All Tabs opens.
    @Published private(set) var tabPictures: [ObjectIdentifier: NSImage] = [:]

    private func captureTabPictures() {
        guard let window = textView?.window else { return }
        var pictures: [ObjectIdentifier: NSImage] = [:]
        for tab in window.tabGroup?.windows ?? [window] {
            pictures[ObjectIdentifier(tab)] = WindowTabs.snapshot(of: tab)
        }
        tabPictures = pictures
    }
    @Published var zen: ZenState? {
        didSet { if (oldValue == nil) != (zen == nil) { applyZenWriting() } }
    }
    /// The paragraph zen keeps bright, while the rest is dimmed.
    var focusRange: NSRange?
    @Published var showAISetup = false
    /// Watches for leaving full screen while in zen.
    var zenObserver: ObserverBag?
    var positionSaveWork: DispatchWorkItem?
    /// False until the opening position is placed, so that placement isn't saved over the real one.
    var positionReady = false
    #if DEBUG
    @Published var debugShowFileTitle = false
    #endif

    private var isRestyling = false
    private var lastHidesMarkdown = EditorSession.hidesMarkdown
    /// Settings, zoom and quit notifications, removed when the window goes.
    private let observers = ObserverBag()
    /// Code fence lines at the last restyle; when an edit changes them, the
    /// text after it moves into or out of a code block.
    private var fenceCount = 0
    /// The paragraph the caret is in; its Markdown syntax stays visible.
    fileprivate var revealedRange = NSRange(location: NSNotFound, length: 0)

    static var hidesMarkdown: Bool {
        UserDefaults.standard.object(forKey: "hideMarkdownSyntax") as? Bool ?? true
    }

    init(doc: WriterDocument) {
        self.doc = doc
        super.init()
    }

    var storage: NSTextStorage { doc.storage }
    var fullRange: NSRange { NSRange(location: 0, length: storage.length) }
    var string: NSString { storage.string as NSString }

    // MARK: Wiring

    private static let all = NSHashTable<EditorSession>.weakObjects()

    /// The session of the window in front (key, else main).
    static var frontmost: EditorSession? {
        guard let front = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        // A sheet (like the shortcuts card) counts as its parent window.
        let window = front.sheetParent ?? front
        return all.allObjects.first { $0.textView?.window == window }
    }

    /// The session shown in a window.
    static func session(for window: NSWindow) -> EditorSession? {
        all.allObjects.first { $0.textView?.window === window }
    }

    func attach(_ tv: EditorTextView) {
        textView = tv
        Self.all.add(self)
        tv.session = self
        tv.delegate = self
        tv.featuresOn = featuresOn
        tv.layoutManager?.delegate = self
        storage.delegate = self
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textView?.vim.settingsChanged()
                self.applyZenWriting()
                guard Self.hidesMarkdown != self.lastHidesMarkdown else { return }
                self.lastHidesMarkdown = Self.hidesMarkdown
                self.refreshMarkdownVisibility()
            }
        })
        tv.vim.onStateChange = { [weak self, weak tv] in
            guard let self, let tv else { return }
            let status = tv.vim.statusText
            if self.vimStatus != status { self.vimStatus = status }
        }
        tv.vim.settingsChanged()
        vimStatus = tv.vim.statusText
        #if DEBUG
        DebugSnapshot.register(self)
        #endif
        observers.add(center.addObserver(forName: Zoom.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyZoom() }
        })
        observers.add(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        })
        restyleAll()
        updateTypingAttributes()
        updateWordCount()
    }

    func attachOverflow(_ tv: NSTextView) {
        overflowView = tv
        tv.delegate = self
        let o = doc.overflow
        if o.length > 0 { o.setAttributes(Theme.overflowAttributes, range: NSRange(location: 0, length: o.length)) }
        tv.typingAttributes = Theme.overflowAttributes
    }

    // MARK: Styling

    func restyleAll() {
        defer {
            textView?.needsDisplay = true
            textView?.scheduleCaretUpdate()
        }
        pendingRestyle = nil
        guard storage.length > 0 else { return }
        let blocks = MarkdownStyler.codeBlocks(in: string)
        fenceCount = Self.fences(in: blocks).count
        isRestyling = true
        storage.beginEditing()
        MarkdownStyler.apply(to: storage, in: fullRange, groups: doc.groups, showAlternates: featuresOn, codeBlocks: blocks)
        storage.endEditing()
        isRestyling = false
    }

    /// Restyles just the paragraphs holding alternatives (all of them, or
    /// one spot's). Showing or hiding the tools, or a spot gaining or losing
    /// an option, only changes the room left after it for its dots, so the
    /// rest of the page needn't be styled again.
    func restyleAlternatives(_ id: String? = nil) {
        defer {
            textView?.needsDisplay = true
            textView?.scheduleCaretUpdate()
        }
        var paragraphs: [NSRange] = []
        storage.enumerateAttribute(.variantGroup, in: fullRange) { value, r, _ in
            guard let value = value as? String, id == nil || value == id else { return }
            let paragraph = string.paragraphRange(for: r)
            if let last = paragraphs.last, NSMaxRange(last) >= paragraph.location {
                paragraphs[paragraphs.count - 1] = NSUnionRange(last, paragraph)
            } else {
                paragraphs.append(paragraph)
            }
        }
        guard !paragraphs.isEmpty else { return }
        let blocks = MarkdownStyler.codeBlocks(in: string)
        isRestyling = true
        storage.beginEditing()
        for paragraph in paragraphs {
            MarkdownStyler.restyle(storage, in: paragraph, groups: doc.groups, showAlternates: featuresOn, codeBlocks: blocks)
        }
        storage.endEditing()
        isRestyling = false
    }

    private static func fences(in blocks: [MarkdownStyler.CodeBlock]) -> [NSRange] {
        blocks.flatMap { [$0.open] + ($0.close.map { [$0] } ?? []) }
    }

    /// Text edited since the last restyle. Styling is applied *after* an
    /// edit completes, never inside it: restyling within the edit widens the
    /// range NSTextView thinks changed, and it then moves the caret to the end
    /// of that range (the end of the paragraph).
    private var pendingRestyle: NSRange?
    private var restyleFlushScheduled = false

    fileprivate func noteEdited(_ edited: NSRange, in ts: NSTextStorage) {
        let length = ts.length
        let location = min(edited.location, length)
        let r = NSRange(location: location, length: min(edited.length, length - location))
        if let pending = pendingRestyle {
            let clamped = NSRange(location: min(pending.location, length), length: 0)
            pendingRestyle = NSUnionRange(NSUnionRange(clamped, NSRange(location: clamped.location, length: min(pending.length, length - clamped.location))), r)
        } else {
            pendingRestyle = r
        }
        guard !restyleFlushScheduled else { return }
        restyleFlushScheduled = true
        // Edits that don't go through the text view (e.g. Lab marks) still get styled.
        DispatchQueue.main.async { [weak self] in self?.flushRestyle() }
    }

    func flushRestyle() {
        restyleFlushScheduled = false
        guard let pending = pendingRestyle else { return }
        pendingRestyle = nil
        isRestyling = true
        storage.beginEditing()
        restyleAround(pending, in: storage)
        storage.endEditing()
        isRestyling = false
        textView?.needsDisplay = true
    }

    private func restyleAround(_ edited: NSRange, in ts: NSTextStorage) {
        let ns = ts.string as NSString
        guard ns.length > 0 else { return }
        let location = min(edited.location, ns.length)
        var r = NSRange(location: location, length: min(edited.length, ns.length - location))
        let full = NSRange(location: 0, length: ns.length)
        for probe in [r.location - 1, r.location, NSMaxRange(r) - 1, NSMaxRange(r)] where probe >= 0 && probe < ns.length {
            var run = NSRange()
            if ts.attribute(.variantGroup, at: probe, longestEffectiveRange: &run, in: full) != nil {
                r = NSUnionRange(r, run)
            }
        }
        r = ns.paragraphRange(for: r)
        // Opening or closing a code block moves everything after it into or
        // out of code, so restyle to the end.
        let blocks = MarkdownStyler.codeBlocks(in: ns)
        let fences = Self.fences(in: blocks)
        if fences.count != fenceCount || fences.contains(where: { NSIntersectionRange($0, r).length > 0 }) {
            r = NSRange(location: r.location, length: ns.length - r.location)
        }
        fenceCount = fences.count
        MarkdownStyler.restyle(ts, in: r, groups: doc.groups, showAlternates: featuresOn, codeBlocks: blocks)
    }

    /// Kept from the text before the caret only by the rules below, or not at all.
    private static let notContinued: [NSAttributedString.Key] = [.variantGroup, .ghost, .markdownMarker, .placeholder, .labMark, .proposedCut, .kern]

    func updateTypingAttributes() {
        guard let tv = textView else { return }
        let loc = tv.selectedRange().location
        let len = storage.length
        var attrs = Theme.baseAttributes
        // New text continues the styling before it (a heading, bold, code…),
        // so the restyle after typing usually has nothing to change, which
        // keeps typing fast in a long document.
        if loc > 0, loc <= len, string.character(at: loc - 1) != 10 {
            var styled = storage.attributes(at: loc - 1, effectiveRange: nil)
            for key in Self.notContinued { styled[key] = nil }
            attrs.merge(styled) { _, before in before }
        }
        if loc > 0, loc < len {
            for key in [NSAttributedString.Key.variantGroup, .ghost] {
                if let a = storage.attribute(key, at: loc - 1, effectiveRange: nil) as? NSObject,
                   let b = storage.attribute(key, at: loc, effectiveRange: nil) as? NSObject,
                   a.isEqual(b) {
                    attrs[key] = a
                }
            }
        }
        if attrs[.ghost] != nil { attrs[.foregroundColor] = Theme.ghost }
        tv.typingAttributes = attrs
    }

    /// Shows Markdown syntax only in the paragraph being edited.
    func updateRevealedParagraph() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let length = storage.length
        let selection = tv.selectedRange()
        let new = length == 0 ? NSRange(location: 0, length: 0)
            : string.paragraphRange(for: NSRange(location: min(selection.location, length), length: min(selection.length, length - min(selection.location, length))))
        guard new != revealedRange else { return }
        let old = revealedRange
        revealedRange = new
        for r in [old, new] where r.location != NSNotFound && r.location < length {
            let clamped = NSRange(location: r.location, length: min(r.length, length - r.location))
            lm.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        }
        tv.needsDisplay = true
        textView?.scheduleCaretUpdate()
    }

    /// Re-applies hiding everywhere (after the setting changes).
    func refreshMarkdownVisibility() {
        guard let lm = textView?.layoutManager, storage.length > 0 else { return }
        lm.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        textView?.needsDisplay = true
        textView?.scheduleCaretUpdate()
    }

    func updateWordCount() {
        let count = words(in: fullRange)
        if wordCount != count { wordCount = count }
        let placeholders = placeholders().count
        if placeholderCount != placeholders { placeholderCount = placeholders }
        updateSelectionWords()
    }

    /// The TK placeholders a reader would see (ghosted ones left out), in order.
    func placeholders() -> [NSRange] {
        var found: [NSRange] = []
        let ts = storage
        storage.enumerateAttribute(.placeholder, in: fullRange) { value, r, _ in
            if value != nil, ts.attribute(.ghost, at: r.location, effectiveRange: nil) == nil { found.append(r) }
        }
        return found
    }

    /// Selects the next TK after the caret, starting over at the top.
    func goToNextPlaceholder() {
        guard let tv = textView else { return }
        let all = placeholders()
        let after = NSMaxRange(tv.selectedRange())
        guard let next = all.first(where: { $0.location >= after }) ?? all.first else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(next)
        tv.scrollRangeToVisible(next)
        tv.showFindIndicator(for: next)
    }

    /// Counts the selected words while there's a selection.
    func updateSelectionWords() {
        let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let count = selection.length > 0 && NSMaxRange(selection) <= storage.length ? words(in: selection) : nil
        if selectionWords != count { selectionWords = count }
    }

    /// The words a reader would read: ghosted text and Markdown syntax (a
    /// link's address, say) aren't counted.
    func words(in range: NSRange) -> Int {
        var count = 0
        let ns = string
        let ts = storage
        storage.enumerateAttribute(.ghost, in: range) { value, r, _ in
            guard (value as? Bool) != true else { return }
            ns.enumerateSubstrings(in: r, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
                if ts.attribute(.markdownMarker, at: word.location, effectiveRange: nil) == nil { count += 1 }
            }
        }
        return count
    }

    /// Sets (or, with nil, clears) the length target. Undoable, and saved
    /// with the document.
    func setTarget(_ target: Int?) {
        let old = doc.target
        guard target != old else { return }
        doc.target = target
        undoManager?.registerUndo(withTarget: self) { s in
            MainActor.assumeIsolated { s.setTarget(old) }
        }
        undoManager?.setActionName(target == nil ? "Clear Length Target" : "Length Target")
    }

    /// The text as a reader would get it: ghosted passages left out.
    func cleanText() -> String {
        var out = ""
        let ns = string
        storage.enumerateAttribute(.ghost, in: fullRange) { value, r, _ in
            if (value as? Bool) != true { out += ns.substring(with: r) }
        }
        return out
    }

    // MARK: Groups

    func groupID(near loc: Int) -> String? {
        let len = storage.length
        if loc < len, let id = storage.attribute(.variantGroup, at: loc, effectiveRange: nil) as? String { return id }
        if loc > 0, loc <= len, let id = storage.attribute(.variantGroup, at: loc - 1, effectiveRange: nil) as? String { return id }
        return nil
    }

    func range(of key: NSAttributedString.Key, id: String) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(key, in: fullRange) { value, r, stop in
            if (value as? String) == id { found = r; stop.pointee = true }
        }
        return found
    }

    /// Keeps each group's option list honest as the writer types inside it.
    func syncGroups() {
        var updated = doc.groups
        var seen = Set<String>()
        let ns = string
        storage.enumerateAttribute(.variantGroup, in: fullRange) { value, r, _ in
            guard let id = value as? String, !seen.contains(id), var g = updated[id] else { return }
            seen.insert(id)
            let text = ns.substring(with: r)
            if let i = g.options.firstIndex(where: { $0.text == text }) {
                g.selected = i
            } else if g.options.indices.contains(g.selected) {
                g.options[g.selected].text = text
            }
            updated[id] = g
        }
        if updated != doc.groups { doc.groups = updated }
    }

    private func trimmed(_ r: NSRange) -> NSRange {
        let ns = string
        var r = r
        let ws = CharacterSet.whitespacesAndNewlines
        while r.length > 0, let s = Unicode.Scalar(ns.character(at: r.location)), ws.contains(s) { r.location += 1; r.length -= 1 }
        while r.length > 0, let s = Unicode.Scalar(ns.character(at: NSMaxRange(r) - 1)), ws.contains(s) { r.length -= 1 }
        return r
    }

    private func wordRange(at loc: Int) -> NSRange? {
        guard let tv = textView, loc <= storage.length else { return nil }
        let r = trimmed(tv.selectionRange(forProposedRange: NSRange(location: loc, length: 0), granularity: .selectByWord))
        return r.length > 0 ? r : nil
    }

    /// Opens the side panel on the alternates for `range` (or the selection),
    /// creating the spot if it doesn't exist yet.
    func openAlternatives(for range: NSRange?) {
        guard let tv = textView else { return }
        featuresOn = true
        showAlternatives = true
        var r = range ?? tv.selectedRange()
        if let id = groupID(near: r.location) {
            activeGroupID = id
            focusAddField += 1
            return
        }
        if r.length == 0, let word = wordRange(at: r.location) { r = word }
        r = trimmed(r)
        guard r.length > 0 else { activeGroupID = nil; return }
        activeGroupID = createGroup(in: r)
        focusAddField += 1
    }

    @discardableResult
    private func createGroup(in r: NSRange) -> String? {
        guard let tv = textView else { return nil }
        var existing: String?
        storage.enumerateAttribute(.variantGroup, in: r) { value, _, stop in
            if let id = value as? String { existing = id; stop.pointee = true }
        }
        if let existing { return existing }
        let id = UUID().uuidString
        doc.groups[id] = VariantGroup(id: id, options: [VariantOption(text: string.substring(with: r), source: .human)])
        if tv.shouldChangeText(in: r, replacementString: nil) {
            storage.addAttribute(.variantGroup, value: id, range: r)
            tv.didChangeText()
        }
        undoManager?.setActionName("Alternatives")
        return id
    }

    /// One key for alternatives: a selection gets alternatives; a spot that
    /// already has them opens (or, if it's already showing, closes) the panel;
    /// otherwise the panel simply opens or closes.
    func alternativesShortcut() {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        if selection.length > 0 {
            openAlternatives(for: selection)
            return
        }
        if let id = groupID(near: selection.location) {
            if featuresOn && showAlternatives && activeGroupID == id {
                showAlternatives = false
            } else {
                activate(id)
            }
            return
        }
        featuresOn = true
        showAlternatives.toggle()
    }

    func activate(_ id: String) {
        featuresOn = true
        showAlternatives = true
        activeGroupID = id
    }

    func cycleAtCaret(_ delta: Int) {
        guard let tv = textView, let id = groupID(near: tv.selectedRange().location) else { return }
        cycle(groupID: id, by: delta)
    }

    func cycle(groupID id: String, by delta: Int) {
        guard let g = doc.groups[id], g.options.count > 1 else { return }
        let n = g.options.count
        select(groupID: id, index: ((g.selected + delta) % n + n) % n)
    }

    func select(groupID id: String, index: Int) {
        guard let tv = textView, var g = doc.groups[id], g.options.indices.contains(index),
              let r = range(of: .variantGroup, id: id) else { return }
        let changed = index != g.selected
        let text = g.options[index].text
        g.selected = index
        doc.groups[id] = g
        activeGroupID = id
        guard changed else { return }
        Sounds.shared.play(index == 0 ? .original : .alternate)

        var attrs = Theme.baseAttributes
        attrs[.variantGroup] = id
        if let ghost = storage.attribute(.ghost, at: r.location, effectiveRange: nil) { attrs[.ghost] = ghost }
        tv.breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: r, replacementString: text) {
            storage.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: attrs))
            tv.didChangeText()
        }
        fixArticle(before: r.location, followedBy: text)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Alternative")
    }

    private static let articlePattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(a|an|A|An|AN)[ \t]+$"#)

    /// Swapping "thumbtack" for "eraser" turns "a" into "an".
    private func fixArticle(before loc: Int, followedBy text: String) {
        guard let tv = textView, loc > 0 else { return }
        let start = max(0, loc - 8)
        let window = string.substring(with: NSRange(location: start, length: loc - start))
        guard let m = Self.articlePattern.firstMatch(in: window, range: NSRange(location: 0, length: (window as NSString).length)) else { return }
        let articleRange = NSRange(location: start + m.range(at: 1).location, length: m.range(at: 1).length)
        if articleRange.location == start, start > 0,
           let s = Unicode.Scalar(string.character(at: start - 1)), CharacterSet.letters.contains(s) { return }
        let current = string.substring(with: articleRange)
        var wanted = Article.wantsAn(text) ? "an" : "a"
        if current == current.uppercased() && current.count > 1 { wanted = wanted.uppercased() }
        else if current.first?.isUppercase == true { wanted = wanted.prefix(1).uppercased() + wanted.dropFirst() }
        guard wanted != current else { return }
        let attrs = storage.attributes(at: articleRange.location, effectiveRange: nil)
        if tv.shouldChangeText(in: articleRange, replacementString: wanted) {
            storage.replaceCharacters(in: articleRange, with: NSAttributedString(string: wanted, attributes: attrs))
            tv.didChangeText()
        }
    }

    func addOption(groupID id: String, text: String, source: OptionSource) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var g = doc.groups[id], !g.options.contains(where: { $0.text == text }) else { return }
        let option = VariantOption(text: text, source: source)
        g.options.append(option)
        doc.groups[id] = g
        undoManager?.registerUndo(withTarget: self) { s in
            MainActor.assumeIsolated { s.removeOption(groupID: id, optionID: option.id) }
        }
        undoManager?.setActionName("Add Alternative")
        restyleAlternatives(id)
    }

    func removeOption(groupID id: String, optionID: UUID) {
        guard var g = doc.groups[id], let index = g.options.firstIndex(where: { $0.id == optionID }) else { return }
        guard g.options.count > 1 else { return }
        undoManager?.beginUndoGrouping()
        if g.selected == index {
            select(groupID: id, index: index == 0 ? 1 : 0)
            g = doc.groups[id] ?? g
        }
        let option = g.options.remove(at: index)
        if g.selected > index { g.selected -= 1 }
        doc.groups[id] = g
        undoManager?.registerUndo(withTarget: self) { s in
            MainActor.assumeIsolated { s.restoreOption(groupID: id, option: option, at: index) }
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Delete Alternative")
        restyleAlternatives(id)
    }

    private func restoreOption(groupID id: String, option: VariantOption, at index: Int) {
        guard var g = doc.groups[id] else { return }
        g.options.insert(option, at: min(index, g.options.count))
        if g.selected >= index { g.selected += 1 }
        doc.groups[id] = g
        undoManager?.registerUndo(withTarget: self) { s in
            MainActor.assumeIsolated { s.removeOption(groupID: id, optionID: option.id) }
        }
        restyleAlternatives(id)
    }

    func clearAISuggestions(groupID id: String) {
        guard let g = doc.groups[id] else { return }
        undoManager?.beginUndoGrouping()
        for option in g.options.reversed() where option.source == .ai {
            removeOption(groupID: id, optionID: option.id)
        }
        undoManager?.endUndoGrouping()
    }

    /// Keeps the current wording and forgets the alternates.
    func dissolve(groupID id: String) {
        guard let tv = textView, let r = range(of: .variantGroup, id: id) else { return }
        // Removing the mark is an edit, so its paragraph is restyled (dots gone) with it.
        if tv.shouldChangeText(in: r, replacementString: nil) {
            storage.removeAttribute(.variantGroup, range: r)
            tv.didChangeText()
        }
        undoManager?.setActionName("Remove Alternatives")
        if activeGroupID == id { activeGroupID = nil }
    }

    // MARK: Ghost

    func ghostRun(at loc: Int) -> NSRange? {
        for probe in [loc, loc - 1] where probe >= 0 && probe < storage.length {
            var run = NSRange()
            if (storage.attribute(.ghost, at: probe, longestEffectiveRange: &run, in: fullRange) as? Bool) == true {
                return run
            }
        }
        return nil
    }

    /// The ghosted text that Ghost / Revive would bring back for a selection:
    /// the run the caret touches, or one the selection overlaps.
    func ghostToRevive(for r: NSRange) -> NSRange? {
        guard let run = ghostRun(at: r.location), r.length == 0 || NSIntersectionRange(run, r).length > 0 else { return nil }
        return run
    }

    func toggleGhost(range: NSRange?) {
        guard let tv = textView else { return }
        let r = range ?? tv.selectedRange()
        if let run = ghostToRevive(for: r) {
            revive(run)
        } else if r.length > 0 {
            ghost(r)
        }
    }

    func ghost(_ r: NSRange) {
        guard let tv = textView, r.length > 0 else { return }
        if tv.shouldChangeText(in: r, replacementString: nil) {
            storage.addAttribute(.ghost, value: true, range: r)
            tv.didChangeText()
        }
        undoManager?.setActionName("Ghost")
    }

    func revive(_ r: NSRange) {
        guard let tv = textView else { return }
        if tv.shouldChangeText(in: r, replacementString: nil) {
            storage.removeAttribute(.ghost, range: r)
            tv.didChangeText()
        }
        undoManager?.setActionName("Revive")
    }

    // MARK: Overflow

    func stash(range: NSRange?) {
        guard let tv = textView else { return }
        let r = range ?? tv.selectedRange()
        guard r.length > 0 else { return }
        let text = string.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        if tv.shouldChangeText(in: r, replacementString: "") {
            storage.replaceCharacters(in: r, with: "")
            tv.didChangeText()
        }
        appendToOverflow(text)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Stash in Overflow")
        featuresOn = true
        rightPanel = .overflow
    }

    private func appendToOverflow(_ text: String) {
        let existing = doc.overflow.string
        let separator = existing.isEmpty ? "" : existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        insertIntoOverflow(separator + text, at: doc.overflow.length)
    }

    /// Adds text to the overflow drawer. Undo takes it out again, and redo
    /// puts it back, as each registers the other.
    private func insertIntoOverflow(_ text: String, at location: Int) {
        let o = doc.overflow
        guard location <= o.length else { return }
        o.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: text, attributes: Theme.overflowAttributes))
        let added = NSRange(location: location, length: (text as NSString).length)
        undoManager?.registerUndo(withTarget: self) { s in
            MainActor.assumeIsolated { s.removeFromOverflow(added, expecting: text) }
        }
    }

    private func removeFromOverflow(_ r: NSRange, expecting text: String) {
        let o = doc.overflow
        // Leave the drawer alone if it has been edited since.
        guard NSMaxRange(r) <= o.length, o.attributedSubstring(from: r).string == text else { return }
        o.replaceCharacters(in: r, with: "")
        undoManager?.registerUndo(withTarget: self) { s in
            MainActor.assumeIsolated { s.insertIntoOverflow(text, at: r.location) }
        }
    }

    // MARK: Tour

    func startTour() {
        previewing = false
        tourStep = 0
        UserDefaults.standard.set(true, forKey: "tourSeen")
    }

    func advanceTour(by delta: Int) {
        guard let step = tourStep else { return }
        let next = step + delta
        guard TourStep.all.indices.contains(next) else { endTour(); return }
        if TourStep.all[next].needsTools { featuresOn = true }
        tourStep = next
    }

    func endTour() {
        tourStep = nil
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }

    // MARK: Sharing

    func copyCleanText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanText().trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }

    func postToX() {
        var components = URLComponents(string: "https://x.com/intent/post")!
        components.queryItems = [URLQueryItem(name: "text", value: plainText())]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Context menu

    func contextItems(clickIndex: Int?) -> [NSMenuItem] {
        guard let tv = textView else { return [] }
        let sel = tv.selectedRange()
        let loc = sel.length > 0 ? sel.location : (clickIndex ?? sel.location)
        var items: [NSMenuItem] = []

        if let id = groupID(near: loc) {
            items.append(ActionMenuItem("Show Alternatives") { [weak self] in self?.activate(id) })
            items.append(ActionMenuItem("AI Alternatives") { [weak self] in self?.aiAlternatives(groupID: id) })
        } else {
            let target: NSRange? = sel.length > 0 ? sel : wordRange(at: loc)
            if let target {
                let label = sel.length > 0 ? "selection" : "“\(string.substring(with: target))”"
                items.append(ActionMenuItem("Write Alternatives for \(label)…") { [weak self] in self?.openAlternatives(for: target) })
                items.append(ActionMenuItem("AI Alternatives for \(label)") { [weak self] in self?.aiAlternatives(for: target) })
            }
        }

        if let run = ghostToRevive(for: sel.length > 0 ? sel : NSRange(location: loc, length: 0)) {
            items.append(ActionMenuItem("Revive") { [weak self] in self?.revive(run) })
        } else if sel.length > 0 {
            items.append(ActionMenuItem("Ghost It") { [weak self] in self?.ghost(sel) })
        }
        if sel.length > 0 {
            items.append(ActionMenuItem("Stash in Overflow") { [weak self] in self?.stash(range: sel) })
        }
        return items
    }
}

// MARK: - Delegates

extension EditorSession: NSTextStorageDelegate {
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            guard !isRestyling, textStorage === doc.storage else { return }
            noteEdited(editedRange, in: textStorage)
        }
    }
}

extension EditorSession: NSLayoutManagerDelegate {
    /// Hides Markdown syntax characters outside the paragraph being edited by
    /// turning their glyphs into null glyphs (no width, nothing drawn).
    nonisolated func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        MainActor.assumeIsolated {
            guard Self.hidesMarkdown, let ts = layoutManager.textStorage else { return 0 }
            let revealed = revealedRange
            var changed = false
            var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
            for i in 0..<glyphRange.length {
                newProps[i] = props[i]
                let index = charIndexes[i]
                guard index < ts.length,
                      ts.attribute(.markdownMarker, at: index, effectiveRange: nil) != nil,
                      revealed.location == NSNotFound || !NSLocationInRange(index, revealed) else { continue }
                newProps[i].insert(.null)
                changed = true
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return glyphRange.length
        }
    }
}

extension EditorSession: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === textView else { return }
        flushRestyle()
        syncGroups()
        updateWordCount()
        updateFocus()
        textView?.needsDisplay = true
        if !featuresOn, !typingQuietly { typingQuietly = true }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        schedulePositionSave()
        updateTypingAttributes()
        updateRevealedParagraph()
        updateSelectionWords()
        updateFocus()
        if let id = groupID(near: tv.selectedRange().location), doc.groups[id] != nil, activeGroupID != id {
            activeGroupID = id
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager ?? view.window?.undoManager
    }

    /// Smart quotes and dashes are for prose. In code, and on Markdown lines
    /// of dashes (`---` rules and front matter, table dividers), they'd change
    /// what the Markdown means, so there the plain characters stay.
    func textView(
        _ view: NSTextView,
        didCheckTextIn range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:],
        results: [NSTextCheckingResult],
        orthography: NSOrthography,
        wordCount: Int
    ) -> [NSTextCheckingResult] {
        guard view === textView else { return results }
        let ns = string
        return results.filter { result in
            guard result.resultType == .dash || result.resultType == .quote else { return true }
            // Results are placed relative to the range that was checked.
            return !MarkdownStyler.wantsPlainPunctuation(at: range.location + result.range.location, in: ns)
        }
    }
}

/// Notification observers that are removed when their owner goes away.
final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// An `NSMenuItem` that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
    }

    @objc private func fire() { handler() }
}
